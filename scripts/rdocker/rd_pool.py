"""rdocker rd_pool: per-job placement of `rrun` jobs on the worker pool (fleet.json workers).

rd_run asks `plan()` for an ordered list of hosts to try. With no fleet (or no rd_fleet module)
the list is cfg["host"] alone and nothing is probed: the single-host rrun of before. With exactly
one enabled worker it is that worker alone, also unprobed (same behaviour as before, on its
alias). With two or more, every worker is probed in parallel over its own rr-%C ssh master with a
small `perl -e` snippet (PROBE; nothing is installed on the worker) and given an estimated
completion time (score(); lower is better):

    eta  = cold + queue + job_cost / eff + rtt          (rtt capped at RTT_CAP_S)
    eff  = speed * cpu_share * mem_factor               (mem_factor: 0.1 at need_gb .. 1.0 from 1.5x)
    cold = COLD_GIT_S without the bare git mirror + COLD_DEPS_S without the packages
    queue = 0 with a free slot, else when the first slot holder should be done (holders' ages)
    job_cost = median of this worker's last runs of the class (runs.log tail, >= HIST_MIN), else the
               pool's, else JOB_COST_S / rr_job_cost_s - raised to the median of earlier runs of the
               SAME command (runs.log argv; this worker's, else the pool's) when those took longer;
               speed = ~/rr/speed, else fleet.json's
    queue (busy) = when its first holder should end: from that holder's own command (slots/<i>.own)
               when it ran before, else the worker's median run
    free = free slots (heavy jobs: min with free heavy slots); capped by ~/rr/slots.cap and the
           owner's share switch (some = half; off = state "off", no eta, tried last)
    overload: load1 / ncpu >= rr_overload_ratio (1.5) at probe time => "busy" even with a free
           slot, and run x= load1 / ncpu (a worker already oversubscribed is held off, not piled on)

Eligibility (eligibility(); fleet.json per worker, a missing field = no limit) is decided BEFORE any
of that and is hard: a worker whose `classes` leave out the job's class, whose `max_cost_s` is below the
job's expected command time there (expected_cost: job_cost / speed, no momentary load factor), or that
says `cold_ok: false` while it lacks the packages for this lockfile, is no candidate at all - not
ranked, not a wait host, no shard, no hedge, no warm. Unprobed plans (one worker, --host) check the
class only. Nothing eligible at all: plan.hosts is empty and plan.ineligible says why (rd_run: exit 75).
A worker with less memory than the job needs is "low-mem" (no eta). Order: free workers by eta, then
busy ones by eta (the first is the "wait host" when nothing is free), then low-mem, down, off. A busy
worker whose eta is <= PROMOTE_RATIO (0.5) x the best free one, and at least PROMOTE_MIN_GAIN_S
(120 s) sooner, goes first, with a slot wait that ends when
the best free worker would have finished. Free candidates get a short slot wait so a lost race moves
on quickly; the wait host gets the full rr_wait_min. Nothing is cached between plan() calls: every
job sees workers that just went away or came back. shardable() / shard_assign() split a `vitest run`
across the free workers (rd_run.run_shards runs them); a worker with "shards": false in fleet.json
(a slow machine whose long prepare would straggle the run) never gets a shard, only whole jobs.

Job classes (classify): db (test:db & friends: never re-run after GO, never local in a pool),
heavy (tsc / typecheck: ~6 GB, never local in a pool), build (declared outputs, copied back),
normal (vitest / jest / test scripts), light (lint, check / verify scripts: may run on the laptop
when every worker is busy for rr_local_after_s and the laptop has > 4 GB free).
"""
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time

import rd_common

RTT_CAP_S = 0.5
PROBE_TIMEOUT_S = 4.0   # covers a cold ssh master over a DERP relay (~1.5-2.5 s); warm probes answer in ~0.3 s
RACE_WAIT_MIN = 0.5          # slot wait on a worker the probe saw free (a lost race moves on)
LOCAL_AFTER_S = 20           # light jobs: run locally after waiting this long for any worker
LOCAL_MIN_FREE_GB = 4
COLD_GIT_S, COLD_DEPS_S = 30.0, 90.0   # eta: no bare git mirror yet / packages not installed there
NEED_GB = {"heavy": 6, "build": 3, "normal": 2, "light": 1, "db": 2}
# seconds a job class takes at speed 1.0 until the workers' runs.log teaches better (rr_job_cost_s)
JOB_COST_S = {"heavy": 60.0, "normal": 60.0, "db": 120.0, "light": 30.0, "build": 90.0}
JOB_CPUS = {"heavy": 2, "normal": 4, "db": 2, "light": 1, "build": 2}   # cores a job keeps busy
MIN_RUN_S = 1.0              # a finished run's cost is never below this (ssh + spawn alone take that)
HIST_MIN = 3                 # runs of a class before its median replaces the default cost
HOLDER_COST_S = 60.0         # a slot holder's run at speed 1.0 when the worker has no history (queue wait)
# a busy worker goes first when its eta (queue included) <= this x the best free one (0 = never):
# a quick job still spreads to an idle machine; this is for "free" workers that would be about 2x
# or more slower (hp swapping on a tsc: 26 min vs 77 s on nickmbp; 2026-11-11 a whole vitest suite
# ran 66-80 min on the free rd-mini-a while faster workers would have freed up sooner). Was 0.25.
PROMOTE_RATIO = 0.5
# ...and only when that saves at least this much (rr_queue_promote_min_gain_s): a quick job's queue
# estimate is too rough to make it wait on a busy worker for a few seconds' gain
PROMOTE_MIN_GAIN_S = 120.0
# a worker whose 1-min load per CPU thread is at least this at probe time counts as busy (its free
# slot notwithstanding) and its run estimate grows by load/ncpu (rr_overload_ratio; 0 = off).
# 2026-11-10: the WSL laptop (8 threads, 4 slots) reached load1 19 while still being sent jobs
OVERLOAD_RATIO = 1.5
_SHARD_ARG_RE = re.compile(r"(?:^|\s)--shard[= ]?(\d+)/(\d+)(?:\s|$)")
# rr_outputs: {"<repo name or slug>": {"<package dir relative to the repo>": ["dist", ...]}}
# Builds are only sent to the pool for a mapped package dir; outputs are copied back.
DEFAULT_OUTPUTS = {"dentall": {"server": ["dist"], "client": ["dist"], "admin-client": ["dist"]}}
BENCH_REF_S = 4.0            # bench seconds that score speed 1.0 (rr_bench_ref_s overrides)

# test:db and every test:db:<x> variant (test:db:rls, test:db:migrated: 30 runs on 2026-11-11 were
# classed "normal" - no DB placement, a 30-min cap instead of 90)
_DB_RE = re.compile(r"(^|\s)(test:db(:[\w.-]+)*|release:rehearse:migrations|check:db-all)(\s|$)"
                    r"|(^|[\s/])(test-with-db|run-guard-tier)\.mjs(\s|$)")
_TYPECHECK_RE = re.compile(r"(^|[\s/])tsc(\s|$)|(^|\s)(typecheck|type-check)(:[\w:.-]*)?(\s|$)"
                           r"|(^|\s)check:server-test-typecheck(\s|$)")
_BIGHEAP_RE = re.compile(r"--max-old-space-size=[0-9]{4,}")
_LINT_RE = re.compile(r"(^|[\s/])eslint(\s|$)|(^|\s)lint(:[\w:.-]*)?(\s|$)")
_CHECK_RE = re.compile(r"(^|\s)(check|verify)(:[\w:.-]*)?(\s|$)")
_SUITE_RE = re.compile(r"(^|[\s/])(vitest|jest)(\s|$)")
# `npm run build` (also run-script / --prefix X / pnpm|yarn|bun run build): the only build shape
# routed; its outputs come from rr_outputs, so nothing else ever copies back.
BUILD_RE = re.compile(r"(^|[\s/])(npm|pnpm|yarn|bun)(\s+(--prefix(=|\s+)\S+|-\S+))*\s+"
                      r"(run|run-script)(\s+-\S+)*\s+build(\s|$)")


def note(msg):
    sys.stderr.write("rrun: " + msg + "\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------- job class

def classify(argv, outputs=None):
    """-> job dict: cls, db, need_gb, retry_ok (safe to repeat after a lost worker), local_ok."""
    s = " ".join(argv)
    db = bool(_DB_RE.search(s))
    if db:
        cls = "db"
    elif outputs:
        cls = "build"
    elif _TYPECHECK_RE.search(s) or _BIGHEAP_RE.search(s):
        cls = "heavy"
    elif _LINT_RE.search(s) or _CHECK_RE.search(s):
        cls = "light"
    else:
        cls = "normal"
    retry_ok = not db and (cls == "build" or bool(_TYPECHECK_RE.search(s) or _LINT_RE.search(s)
                                                   or _SUITE_RE.search(s)))
    return {"cls": cls, "db": db, "need_gb": NEED_GB[cls], "retry_ok": retry_ok,
            "local_ok": cls == "light", "never_local": cls in ("db", "heavy"), "sig": run_sig(argv)}


_CPU_NOTE_RE = re.compile(r" \[cpu_share=[^\]]*\]$")


def run_sig(argv):
    """The argv as the runner's runs.log writes it (rr_runner.pl redact_argv: env-looking values
    redacted, control chars -> space, cut at 120 chars + "..."), so a job can be matched to earlier
    runs of the SAME command in the workers' history, not just of its class."""
    out, val = [], False
    for a in argv:
        if val:
            out.append("<redacted>")
            val = False
        elif a in ("-e", "--env"):
            out.append(a)
            val = True
        elif re.match(r"^(--env=|-e)(?=.*=)", a, re.S):
            out.append(re.match(r"^(--env=|-e)", a).group(1) + "<redacted>")
        elif re.match(r"^(-*[A-Za-z_][A-Za-z0-9_-]*=)", a):
            out.append(re.match(r"^(-*[A-Za-z_][A-Za-z0-9_-]*=)", a).group(1) + "<redacted>")
        else:
            out.append(a)
    s = re.sub(r"[\x00-\x1f\x7f]", " ", " ".join(out))
    return s[:120] + "..." if len(s) > 120 else s


def is_build(argv):
    return bool(BUILD_RE.search(" ".join(argv)))


def build_pkg_dir(relcwd, argv):
    """Repo-relative package dir a `npm run build` argv builds (relcwd + --prefix), or None."""
    d = relcwd
    for i, a in enumerate(argv):
        val = argv[i + 1] if a == "--prefix" and i + 1 < len(argv) else \
            a[len("--prefix="):] if a.startswith("--prefix=") else None
        if val:
            d = os.path.normpath(os.path.join(relcwd or ".", val)).replace(os.sep, "/")
    d = "" if d in (".", "") else d
    return None if d.startswith("../") or d == ".." or d.startswith("/") else d


def outputs_for(cfg, slug, pkg_dir):
    """rr_outputs lookup -> repo-relative output paths for a build in pkg_dir, or []. The repo key
    is the full rrun slug (<name>.<hash8>) or just <name>."""
    table = cfg.get("rr_outputs")
    table = table if isinstance(table, dict) else DEFAULT_OUTPUTS
    name = slug.rsplit(".", 1)[0] if "." in slug else slug
    per = table.get(slug) if isinstance(table.get(slug), dict) else table.get(name)
    if not isinstance(per, dict) or pkg_dir is None:
        return []
    outs = per.get(pkg_dir) or []
    res = []
    for o in outs if isinstance(outs, list) else []:
        p = os.path.normpath(os.path.join(pkg_dir, o)).replace(os.sep, "/") if pkg_dir else os.path.normpath(o)
        if p and not p.startswith(("../", "/")) and p not in (".", "..") and ".git" not in p.split("/"):
            res.append(p)
    return res


# ---------------------------------------------------------------------------- fleet

def _f(entry, key, default=None):
    v = entry.get(key) if isinstance(entry, dict) else getattr(entry, key, None)
    return default if v is None else v


def load_workers(cfg):
    """-> enabled worker entries from fleet.json, or None (no fleet: single-host rrun as before)."""
    path = cfg.get("fleet_path") or getattr(rd_common, "FLEET_PATH", None)
    if not path or not os.path.exists(path):
        return None                 # no registry here (yet): the configured host, as before
    try:
        import rd_fleet
    except ImportError:
        return None
    try:
        fleet = rd_fleet.load(cfg)
        ws = list(rd_fleet.workers(fleet))
    except Exception as e:          # an unusable fleet.json must never stop a run: say so, use cfg host
        note("fleet.json unusable (%s) - using %s" % (str(e).strip()[:200], cfg.get("host")))
        return None
    if os.path.realpath(path) == os.path.realpath(getattr(rd_common, "FLEET_PATH", "") or "/nonexistent"):
        ensure_ssh_blocks(fleet, ws, cfg)   # only the real registry may rewrite the real ssh blocks
    return ws or None


def ensure_ssh_blocks(fleet, ws, cfg, path=None):
    """Self-heal deploy order: a Mac that pulled a new fleet.json but never ran `sync-fleet` has no
    `Host <alias>` for some worker, and every probe would fail -> silent local runs. Rewrite the
    blocks once when any worker alias is missing. Never raises."""
    path = path or getattr(rd_common, "FLEET_SSH_PATH", None)
    if not path:
        return False
    try:
        with open(path) as f:
            have = set(l.split()[1] for l in f if l.startswith("Host ") and len(l.split()) > 1)
    except OSError:
        have = set()
    want = [_f(e, "alias") for e in ws if _f(e, "alias") and _f(e, "ip")]
    if all(a in have for a in want):
        return False
    try:
        import rd_fleet
        changed = rd_fleet.ssh_blocks(fleet, None, path)
        if changed:
            note("ssh blocks refreshed from fleet.json (missing: %s)" % ", ".join(a for a in want if a not in have))
        return changed
    except Exception as e:
        note("could not refresh ssh blocks (%s) - run `rdocker sync-fleet`" % str(e).strip()[:200])
        return False


class Host:
    """One place to run: name (route.log target), cfg (host + slots for rd_run), fleet entry."""

    def __init__(self, name, cfg, entry=None):
        self.name, self.cfg, self.entry = name, cfg, entry
        self.probe, self.state, self.short = None, "-", False
        self.eta = self.run_s = self.cold_s = self.queue_s = self.eff = None   # set by score()
        self.overloaded = False                                                  # set by score()

    @property
    def speed(self):
        p = self.probe or {}
        try:
            return float(p.get("speed")) if p.get("speed") not in (None, "") else float(_f(self.entry, "speed", 1.0))
        except (TypeError, ValueError):
            return 1.0


def takes_shards(h):
    """False for a worker whose fleet entry says "shards": false (whole jobs only)."""
    return _f(h.entry, "shards", True) is not False


def host_for(cfg, entry):
    """Fleet entry -> Host whose cfg points rd_run at the worker (its ssh alias and slot count)."""
    alias = _f(entry, "alias") or _f(entry, "name")
    hc = dict(cfg, host=alias)
    ms = _f(entry, "max_slots")
    if isinstance(ms, int) and ms >= 1:
        hc["rr_slots"] = ms
        hc["rr_slots_base"] = max(1, min(int(cfg.get("rr_slots_base", ms)), ms))
    return Host(_f(entry, "name") or alias, hc, entry)


# ---------------------------------------------------------------------------- probe

# Read-only snapshot of a worker, one JSON line. stdin: {"slots", "heavy_slots", "slug",
# "deps": [[rel, sha], ...]}. RR_ROOT / RR_PROC / RR_SYS: same overrides as the runner (tests).
PROBE = r'''
use strict; use warnings; use JSON::PP; use POSIX (); use Fcntl qw(:flock O_RDONLY O_RDWR O_NOFOLLOW);
my $R = $ENV{RR_ROOT} || "$ENV{HOME}/rr";
my $q = eval { local $/; JSON::PP->new->decode(<STDIN> // "{}") } || {};
sub slurp { open(my $f, "<", $_[0]) or return ""; local $/; <$f> // "" }
sub sc { my $v = `/usr/sbin/sysctl -n $_[0] 2>/dev/null`; defined $v ? $v : "" }
my %o = (os => ($ENV{RR_OS} || $^O));
if ($o{os} eq "linux") {
    my $p = $ENV{RR_PROC} // "/proc";
    my $mi = slurp("$p/meminfo");
    my ($av) = $mi =~ /^MemAvailable:\s*(\d+)/m; my ($t) = $mi =~ /^MemTotal:\s*(\d+)/m;
    if ($t && defined $av) { $o{mem_free_pct} = int($av * 100 / $t); $o{mem_avail_mb} = int($av / 1024) }
    ($o{load1}) = slurp("$p/loadavg") =~ /^([\d.]+)/;
    $o{ncpu} = () = slurp("$p/cpuinfo") =~ /^processor\s*:/mg;
    my $max;
    for (glob(($ENV{RR_SYS} // "/sys") . "/class/thermal/thermal_zone*/temp")) {
        my ($v) = slurp($_) =~ /^(\d+)/; $max = $v if defined $v && (!defined $max || $v > $max) }
    $o{temp} = $max / 1000 if defined $max;
} else {
    my ($lvl) = sc("kern.memorystatus_level") =~ /^(\d+)/; my ($tot) = sc("hw.memsize") =~ /^(\d+)/;
    if (defined $lvl && $tot) { $o{mem_free_pct} = $lvl + 0; $o{mem_avail_mb} = int($tot / 1048576 * $lvl / 100) }
    ($o{load1}) = sc("vm.loadavg") =~ /([\d.]+)/; ($o{ncpu}) = sc("hw.ncpu") =~ /^(\d+)/;
}
sub busy { my ($f) = @_; sysopen(my $h, $f, O_RDONLY | O_NOFOLLOW) or return 0;
    return 0 if flock($h, LOCK_SH | LOCK_NB); 1 }
# the owner's share switch (same rule as rr_runner.pl share_level): no file = max; off/some/max; else off
my $shf = $ENV{RR_SHARE_FILE} || ($o{os} eq "darwin" ? "/Users/Shared/rdocker/share" : "$R/share");
my $share = "max";
if (-e $shf || -l $shf) { ($share) = slurp($shf) =~ /^\s*(off|some|max)\s*$/; $share //= "off" }
$o{share} = $share;
sub half { my ($v) = @_; $share eq "some" && $v > 0 ? (int($v / 2) || 1) : $v }
my $n = half(($q->{slots} // 1) =~ /^(\d+)$/ ? $1 : 1);
my ($cap) = -l "$R/slots.cap" ? () : slurp("$R/slots.cap") =~ /^\s*(\d+)/;
$n = $cap if defined $cap && $cap < $n;
$o{slots_cap} = $n; $o{slots_busy} = 0; my @ages;
for my $i (0 .. $n - 1) {
    next unless busy("$R/slots/$i");
    $o{slots_busy}++;
    # how long each holder has run (<i>.who = "<slug> <epoch> <pid> <wt12>"): rd_pool's queue wait
    my (undef, $t) = split ' ', slurp("$R/slots/$i.who");
    push @ages, time - $t if defined $t && $t =~ /^\d+$/ && $t <= time;
}
$o{ages} = \@ages;
# who runs what (<i>.own = tab-separated id= name= client= start= pid= cmd=, written by the runner
# beside <i>.who): only for a held slot whose .who names the same pid (never a leftover's)
my @jobs;
for my $f (glob("$R/slots/*.own")) {
    my ($i) = $f =~ m{/(\d+)\.own$} or next;
    next if -l $f || !busy("$R/slots/$i");
    my %j = map { /^([a-z]+)=(.*)$/ ? ($1 => $2) : () } split /\t/, ((slurp($f) =~ /^([^\n]*)/)[0] // "");
    my (undef, undef, $wpid) = split ' ', slurp("$R/slots/$i.who");
    next unless defined $j{pid} && defined $wpid && $j{pid} eq $wpid;
    $j{slot} = $i + 0;
    $j{start} = ($j{start} // "") =~ /^\d+$/ ? $j{start} + 0 : undef;
    push @jobs, \%j;
}
$o{jobs} = \@jobs;
# the last finished commands (runs.log tail, 24 KB at most): [cmd_s, argv] for rd_pool's job cost
my @hist;
if (sysopen(my $lf, "$R/log/runs.log", O_RDONLY | O_NOFOLLOW)) {
    my $sz = -s $lf || 0;
    seek($lf, $sz > 24576 ? $sz - 24576 : 0, 0);
    my @l = do { local $/ = "\n"; <$lf> };
    shift @l if $sz > 24576;
    # a run killed at its wall-clock cap ("timeout rc=124") counts too: it took at least that long
    # runs.log v2 appends "\t<run= owner= cls= wait_s= exit_reason=>" after argv: not part of the command
    for (@l) { s/\t[^\n]*//; push @hist, [$1 + 0, $2] if /\soutcome=(?:timeout )?rc=\d+ prepare_s=\S+ cmd_s=(\d+(?:\.\d+)?) argv=(.*?)\n?$/ }
    splice(@hist, 0, @hist - 40) if @hist > 40;
}
$o{hist} = \@hist;
if (($q->{heavy_slots} // "") =~ /^(\d+)$/) {
    my $hc = half($1);
    $o{heavy_cap} = $hc; $o{heavy_busy} = 0; $o{heavy_busy} += busy("$R/slots/heavy-$_") for 0 .. $hc - 1 }
# Mac worker, share off, no slot held at all: stop its Colima in the background (rr_runner.pl's
# colima_stop_if_off does the same at job end). Never on Linux, never without colima installed.
my $col = $ENV{RR_COLIMA} || "/opt/homebrew/bin/colima";
my $mark = "$R/state/colima.started";
if ($share eq "off" && $o{os} ne "linux" && -x $col
        && ((-f $mark && !-l $mark) || -S ($ENV{RR_COLIMA_SOCK} || "$ENV{HOME}/.colima/default/docker.sock"))
        && !grep { busy($_) } grep { !/\.who$/ } glob("$R/slots/*")) {
    my $L = "$R/colima.lock";
    rmdir $L if -d $L && time - (stat $L)[9] > 900;
    if (mkdir $L) {
        my $pid = fork;
        if (!defined $pid) { rmdir $L }
        elsif (!$pid) {
            eval {
                POSIX::setsid(); $SIG{$_} = "IGNORE" for qw(HUP INT TERM);
                open STDIN, "<", "/dev/null"; mkdir "$R/log", 0700;
                open(STDOUT, ">>", "$R/log/colima.log") or open(STDOUT, ">", "/dev/null");
                open STDERR, ">&", \*STDOUT;
                $ENV{PATH} = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
                system($col, "stop"); unlink $mark;
            };
            rmdir $L; POSIX::_exit(0);
        }
        $o{docker} = "stopping" if $pid;
    }
}
my ($sp) = -l "$R/speed" ? () : slurp("$R/speed") =~ /^\s*(\d+(?:\.\d+)?)\s*$/;
$o{speed} = $sp + 0 if defined $sp;
my $slug = $q->{slug} // ""; $slug = "" unless $slug =~ /^(?!\.)[A-Za-z0-9._-]+$/;
$o{warm_git} = $slug ne "" && -d "$R/git/$slug.git" ? 1 : 0;
my @deps = grep { ref eq "ARRAY" && ($_->[1] // "") =~ /^[0-9a-f]{64}$/ && ($_->[0] // "") !~ m{(^|/)\.\.(/|$)} } @{ $q->{deps} || [] };
my @stamps = map { slurp($_) } glob("$R/deps/*/node_modules/.rr-deps-stamp");
my $warm = 1;
for my $d (@deps) {
    my ($rel, $sha) = @$d; my $sub = $rel eq "" ? "" : "/$rel";
    my @mine = $slug eq "" ? () : map { slurp($_) } glob("$R/w{,2}/$slug-*$sub/node_modules/.rr-deps-stamp");
    $warm = 0 unless grep { index($_, "$sha ") == 0 } @stamps, @mine;
}
$o{warm_deps} = $warm;
print JSON::PP->new->canonical->encode(\%o), "\n";
'''


def remote_env(cfg):
    root = str(cfg.get("rr_root") or "rr").strip("/")
    return "" if root == "rr" else "RR_ROOT=\"$HOME\"/%s " % shlex.quote(root)


def ssh_base():
    import rd_run
    return ["ssh", "-T"] + rd_run.ssh_opts()


def probe_one(host, req, timeout):
    """ssh the PROBE to host -> (dict, rtt_s) or (None, why)."""
    cmd = ssh_base() + [host.cfg["host"], "%sexec /usr/bin/perl -e %s" % (remote_env(host.cfg), shlex.quote(PROBE))]
    t = time.monotonic()
    try:
        p = subprocess.run(cmd, input=json.dumps(req).encode(), capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "no answer in %.1f s" % timeout
    except OSError as e:
        return None, str(e)
    rtt = time.monotonic() - t
    if p.returncode != 0:
        return None, (p.stderr.decode("utf-8", "replace").strip().splitlines() or ["exit %d" % p.returncode])[-1][:160]
    try:
        out = json.loads(p.stdout.decode("utf-8", "replace").strip().splitlines()[-1])
    except (ValueError, IndexError):
        return None, "unreadable probe output"
    return (out, rtt) if isinstance(out, dict) else (None, "unreadable probe output")


def probe_all(hosts, req_for, timeout):
    """Probe every host in parallel; sets host.probe / host.rtt / host.why."""
    def run(h):
        h.probe, x = probe_one(h, req_for(h), timeout)
        h.rtt, h.why = (x, None) if h.probe is not None else (None, x)
    ts = [threading.Thread(target=run, args=(h,), daemon=True) for h in hosts]
    for t in ts:
        t.start()
    for t in ts:
        t.join(timeout + 1)
    for h in hosts:
        if not hasattr(h, "rtt"):
            h.probe, h.rtt, h.why = None, None, "no answer"


def _num(v, default=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _median(xs):
    xs = sorted(xs)
    n = len(xs)
    return None if not n else xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def history_costs(host):
    """The worker's recent finished commands (probe "hist": [[cmd_s, argv], ...]) -> {cls: [cost in
    seconds at speed 1.0]}. A shard's time counts as the whole job's (x n), so sharded and whole
    runs teach the same number."""
    out = {}
    for row in (host.probe or {}).get("hist") or []:
        if not isinstance(row, list) or len(row) != 2 or not isinstance(row[1], str):
            continue
        secs, words = _num(row[0]), row[1].split()
        if secs is None or secs < 0:
            continue
        m = _SHARD_ARG_RE.search(row[1])
        n = int(m.group(2)) if m and int(m.group(2)) >= 1 else 1
        cls = "build" if is_build(words) else classify(words)["cls"]
        # never under MIN_RUN_S: a sub-second fake/no-op run must not make a job look free
        out.setdefault(cls, []).append(max(MIN_RUN_S, secs) * n * host.speed)
    return out


def history_sig_costs(host):
    """The worker's recent finished commands -> {run_sig: [cost in seconds at speed 1.0]}: the same
    command (as runs.log writes it) run before. Shard rows keep their own "--shard=<redacted>" sig,
    so they never stand in for a whole run."""
    out = {}
    for row in (host.probe or {}).get("hist") or []:
        if not isinstance(row, list) or len(row) != 2 or not isinstance(row[1], str):
            continue
        secs = _num(row[0])
        if secs is None or secs < 0:
            continue
        out.setdefault(_CPU_NOTE_RE.sub("", row[1]), []).append(max(MIN_RUN_S, secs) * host.speed)
    return out


def job_cost(cfg, cls, own=None, pooled=None, own_sig=None, pooled_sig=None):
    """Seconds the job takes at speed 1.0: this worker's history of the class (median of its last
    runs, >= HIST_MIN of them), else the whole pool's, else the per-class default (rr_job_cost_s) -
    raised to the median of earlier runs of the SAME command (this worker's, else the pool's; one
    is enough) when those took longer.
    The command comes first because a class median mixes a 30 s one-file vitest with a 20-min whole
    suite: 2026-11-11 a whole `npx vitest run` was costed like the one-file runs, the slow free
    rd-mini-a (speed 0.42) won the placement and it ran 66-80 min there."""
    base = None
    for xs in (own, pooled):
        if xs and len(xs) >= HIST_MIN:
            base = _median(xs)
            break
    if base is None:
        table = cfg.get("rr_job_cost_s") if isinstance(cfg.get("rr_job_cost_s"), dict) else {}
        base = float(_num(table.get(cls), JOB_COST_S.get(cls, 60)))
    for xs in (own_sig, pooled_sig):
        if xs:
            # only ever raises the estimate: one quick (e.g. instantly failing) earlier run must not
            # make a long command look cheap
            return max(base, _median(xs))
    return base


def expected_cost(cfg, host, job, pooled=None):
    """Seconds the job's command should take on this worker at its own speed (eligibility's
    max_cost_s). The same command's history (this worker's, else the pool's) when it ran at least
    twice, or when it says longer than the class figure; else job_cost() (the class median /
    default). Unlike job_cost (placement), the command's own record may LOWER the estimate here: a
    class median that mixes 20-min suites with 20-s files must not shut a slow worker out of the
    short ones. No load or memory factor: eligibility must not flap with a momentary load spike."""
    sig = job.get("sig")
    xs = (history_sig_costs(host).get(sig) or (pooled or {}).get(("sig", sig))) if sig else None
    base = job_cost(cfg, job["cls"], history_costs(host).get(job["cls"]), (pooled or {}).get(job["cls"]))
    if xs and (len(xs) >= 2 or _median(xs) > base):
        base = _median(xs)
    return base / max(0.01, host.speed)


def eligibility(host, job, cost_s=None, probed=False):
    """-> None when the worker may take this job, else why not. Hard rules from its fleet entry (a
    missing field = no limit, i.e. today's behaviour):
      classes     the job classes it takes (light / normal / heavy / db / build)
      max_cost_s  the longest expected command it takes, in seconds on this worker (cost_s)
      cold_ok     false = only jobs whose packages it already has (probe warm_deps): a cold npm ci
                  never holds one of its slots
    cost / cold need a probe (probed=True); an unprobed plan (one worker, --host) checks the class only.
    A worker that did not answer the probe is judged on its class and cost (cold unknown)."""
    classes = _f(host.entry, "classes")
    if isinstance(classes, list) and job["cls"] not in classes:
        return "takes only %s jobs (this is %s)" % ("/".join(classes), job["cls"])
    if not probed:
        return None
    mc = _num(_f(host.entry, "max_cost_s"))
    if mc is not None and cost_s is not None and cost_s > mc:
        return "expected ~%s there, over its max_cost_s %s" % (fmt_s(cost_s), fmt_s(mc))
    if _f(host.entry, "cold_ok", True) is False and host.probe is not None and not host.probe.get("warm_deps"):
        return "its packages for this lockfile are not prepared yet (cold_ok: false)"
    return None


def no_eligible_msg(job, ineligible):
    """Why no worker may take the job (plan.hosts empty): rd_run prints it and exits 75."""
    what = "class " + job["cls"]
    costs = [h.cost_s * h.speed for h, _ in ineligible if getattr(h, "cost_s", None) is not None]
    if costs:
        what += ", expected ~%s at speed 1.0" % fmt_s(min(costs))
    return ("no eligible worker for this job (%s): %s - each worker's classes / max_cost_s / cold_ok are "
            "set in fleet.json" % (what, "; ".join("%s %s" % (h.name, why) for h, why in ineligible)))


def mem_factor(avail_mb, need_gb):
    """1.0 with >= 1.5x the job's memory free; falls steeply (to 0.1 at exactly need) below that,
    because a worker that starts swapping is many times slower (hp: tsc 26 min vs 77 s)."""
    if avail_mb is None or not need_gb:
        return 1.0
    r = max(0.0, min(1.0, (avail_mb / 1024.0 - need_gb) / (0.5 * need_gb)))
    return 0.1 + 0.9 * r * r


def cpu_share(load, ncpu, cls):
    """Fraction of the cores the job wants (JOB_CPUS) it would get: all of them when that many are
    idle, else its processor-sharing slice of the machine."""
    want = JOB_CPUS.get(cls, 2)
    idle = max(0.0, ncpu - load)
    return min(1.0, max(idle, ncpu * want / (load + want)) / want)


def score(host, job, cfg=None, pooled=None):
    """-> (eta seconds or None when the host cannot take the job at all now, free slots). Lower is
    better. Sets host.state (down/off/busy/low-mem/free) and, with an eta, host.eta and its parts:

        eta = cold + queue + run + rtt;  run = job_cost / eff;  eff = speed * cpu_share * mem_factor
        cold  = COLD_GIT_S without the bare repo + COLD_DEPS_S without the packages
        queue = 0 with a free slot, else when the first holder should finish (busy: still ranked)
        overloaded (load1 / ncpu >= rr_overload_ratio): busy with queue 0, run x= load1 / ncpu
    """
    cfg = cfg or {}
    p = host.probe
    host.eta = host.run_s = host.cold_s = host.queue_s = host.eff = None
    host.overloaded = False
    if p is None:
        host.state = "down"
        return None, 0
    if p.get("share") == "off":          # the owner paused this worker: no new jobs
        host.state = "off"
        return None, 0
    free = int(_num(p.get("slots_cap"), 1) - _num(p.get("slots_busy"), 0))
    if job["cls"] == "heavy" and p.get("heavy_cap") is not None:
        free = min(free, int(_num(p.get("heavy_cap"), 0) - _num(p.get("heavy_busy"), 0)))
    mem = _num(p.get("mem_avail_mb"))
    if mem is not None and mem < job["need_gb"] * 1024:
        host.state = "low-mem" if free > 0 else "busy"
        return None, free
    load, ncpu = _num(p.get("load1"), 0.0), _num(p.get("ncpu"), 1.0) or 1.0
    own = history_costs(host)
    sig = job.get("sig")
    own_sig = history_sig_costs(host).get(sig) if sig else None
    pooled_sig = (pooled or {}).get(("sig", sig)) if sig else None
    host.eff = max(0.01, host.speed * cpu_share(load, ncpu, job["cls"]) * mem_factor(mem, job["need_gb"]))
    host.run_s = job_cost(cfg, job["cls"], own.get(job["cls"]), (pooled or {}).get(job["cls"]),
                          own_sig, pooled_sig) / host.eff
    host.cold_s = (0.0 if p.get("warm_git") else COLD_GIT_S) + (0.0 if p.get("warm_deps") else COLD_DEPS_S)
    per_cpu = load / ncpu
    over = _num(cfg.get("rr_overload_ratio"), OVERLOAD_RATIO)
    if free > 0 and over > 0 and per_cpu >= over:
        # oversubscribed: held off like a busy worker (ranked after the free ones), its compute
        # slower in proportion to the overload, so it only gets a job when it still finishes first
        host.overloaded = True
        host.run_s *= per_cpu
        host.state, host.queue_s = "busy", 0.0
    elif free > 0:
        host.state, host.queue_s = "free", 0.0
    else:
        # the holders' typical run here (any class: they are not ours to know), minus how long they
        # have run; without ages, the first of k busy slots frees after about T / (k + 1)
        allc = [c for cs in own.values() for c in cs]
        typ = (_median(allc) if len(allc) >= HIST_MIN else HOLDER_COST_S) / max(0.01, host.speed)
        ages = [a for a in (_num(x) for x in p.get("ages") or []) if a is not None]
        busy = max(1, int(_num(p.get("slots_busy"), 1)))
        host.state = "busy"
        host.queue_s = (min(max(0.2 * typ, typ - a) for a in ages) if ages else typ / (busy + 1))
        # holders whose command ran here before (slots/<i>.own): their own expected end, not the median
        sigs, now, known = history_sig_costs(host), time.time(), []
        for j in p.get("jobs") or []:
            xs = sigs.get(j.get("cmd")) or (pooled or {}).get(("sig", j.get("cmd"))) if isinstance(j, dict) else None
            st = _num(j.get("start")) if isinstance(j, dict) else None
            if xs and st is not None:
                c = _median(xs) / max(0.01, host.speed)
                known.append(max(0.2 * c, c - max(0.0, now - st)))
        if known and len(known) >= busy:
            host.queue_s = min(known)
    # rtt capped: a cold ssh master's one-off handshake (~2 s over a relay) is not the link's latency
    host.eta = host.cold_s + host.queue_s + host.run_s + min(host.rtt or 0.0, RTT_CAP_S)
    return host.eta, free


# ---------------------------------------------------------------------------- deps stamps

def deps_shas(top, dirs):
    """[[rel, sha]] per deps dir: the same digest rr_runner.pl's sha_files() puts first in a deps
    stamp (lockfile + package.json + .npmrc, names relative to the repo), so the probe can tell
    whether a worker already has these packages."""
    import hashlib
    out = []
    for rel in dirs:
        d = os.path.join(top, rel) if rel else top
        lock = next((n for n in ("npm-shrinkwrap.json", "package-lock.json") if os.path.isfile(os.path.join(d, n))), None)
        if not lock or not os.path.isfile(os.path.join(d, "package.json")):
            continue
        h = hashlib.sha256()
        for n in (lock, "package.json", ".npmrc"):
            h.update(((rel + "/" + n) if rel else n).encode("utf-8", "surrogateescape") + b"\0")
            p = os.path.join(d, n)
            if os.path.isfile(p):
                with open(p, "rb") as f:
                    h.update(f.read())
        out.append([rel, h.hexdigest()])
    return out


# ---------------------------------------------------------------------------- local memory

def local_free_gb():
    """Available memory on this machine in GB (None when unknown)."""
    try:
        if sys.platform.startswith("linux"):
            with open("/proc/meminfo") as f:
                m = re.search(r"^MemAvailable:\s*(\d+)", f.read(), re.M)
            return int(m.group(1)) / 1048576.0 if m else None
        lvl = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.memorystatus_level", "hw.memsize"],
                             capture_output=True, text=True, timeout=5).stdout.split()
        return int(lvl[1]) / 1073741824.0 * int(lvl[0]) / 100.0 if len(lvl) == 2 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


# ---------------------------------------------------------------------------- plan

class Plan:
    def __init__(self, hosts, pool, local_after_s=None, ineligible=()):
        self.hosts, self.pool, self.local_after_s = hosts, pool, local_after_s
        self.promoted = None         # a busy worker put first (its eta beat every free one)
        self.ineligible = list(ineligible)   # [(Host, why)]: never tried (eligibility())


def pick_hosts(cfg, force=None):
    """-> (hosts, pool): every candidate Host (unordered) and whether this is a real pool (2+)."""
    workers = load_workers(cfg)
    if not workers:
        hosts = [Host("mini", dict(cfg))]
    else:
        hosts = [host_for(cfg, w) for w in workers]
    if force:
        sel = [h for h in hosts if force in (h.name, h.cfg.get("host"))]
        if not sel:
            raise ValueError("no worker named %r (have: %s)" % (force, ", ".join(h.name for h in hosts)))
        return sel, False
    return hosts, len(hosts) >= 2


def plan(cfg, job, slug="", deps=(), force=None, probe=None):
    """-> Plan with hosts in the order rd_run should try them. Probes only in a real pool (or when
    probe=True, for `rrun --where`)."""
    hosts, pool = pick_hosts(cfg, force)
    if not (pool or probe):
        bad = [(h, why) for h, why in ((h, eligibility(h, job)) for h in hosts) if why]
        return Plan([h for h in hosts if h not in dict(bad)], False, ineligible=bad)
    req = {"slug": slug, "deps": [list(d) for d in deps]}

    def req_for(h):
        r = dict(req, slots=h.cfg.get("rr_slots", 1))
        hs = _f(h.entry, "heavy_slots") if h.entry is not None else None
        if isinstance(hs, int) and hs >= 0:
            r["heavy_slots"] = hs
        return r
    probe_all(hosts, req_for, float(cfg.get("rr_probe_timeout_s", PROBE_TIMEOUT_S)))
    # what the whole pool has learned per class (a worker with no history of its own uses this)
    pooled = {}
    for h in hosts:
        for cls, xs in history_costs(h).items():
            pooled.setdefault(cls, []).extend(xs)
        for sig, xs in history_sig_costs(h).items():
            pooled.setdefault(("sig", sig), []).extend(xs)
    bad = []
    for h in hosts:
        score(h, job, cfg, pooled)
        h.cost_s = expected_cost(cfg, h, job, pooled)
        why = eligibility(h, job, h.cost_s, probed=True)
        if why:
            bad.append((h, why))
    hosts = [h for h in hosts if h not in dict(bad)]   # never a candidate: not ranked, not a wait host
    by_eta = lambda h: (h.eta, h.rtt or 0)                                     # noqa: E731
    free = sorted((h for h in hosts if h.state == "free"), key=by_eta)
    queued = sorted((h for h in hosts if h.state == "busy" and h.eta is not None), key=by_eta)
    cap = lambda h: _num((h.probe or {}).get("slots_cap"), h.cfg.get("rr_slots", 1)) * h.speed  # noqa: E731
    full = sorted((h for h in hosts if h.state in ("busy", "low-mem") and h.eta is None), key=lambda h: -cap(h))
    down = sorted((h for h in hosts if h.state == "down"), key=lambda h: -(h.cfg.get("rr_slots", 1) * h.speed))
    off = [h for h in hosts if h.state == "off"]
    # finish time, not just "free first": a busy worker whose eta (its queue wait included) is far
    # better than every free one goes first, but waits for its slot only while that still pays off
    # (until the best free worker would have finished), then the job moves on to the free ones
    promoted = None
    ratio = float(cfg.get("rr_queue_promote_ratio", PROMOTE_RATIO))
    gain = float(cfg.get("rr_queue_promote_min_gain_s", PROMOTE_MIN_GAIN_S))
    if pool and free and queued and ratio > 0 and queued[0].eta <= ratio * free[0].eta \
            and free[0].eta - queued[0].eta >= gain:
        promoted = queued.pop(0)
        budget = max(RACE_WAIT_MIN * 60, free[0].eta - (promoted.eta - promoted.queue_s))
        promoted.short = True
        promoted.cfg = dict(promoted.cfg, rr_wait_min=min(float(cfg.get("rr_wait_min", 30)), budget / 60.0))
    order = ([promoted] if promoted else []) + free + queued + full + down + off   # off last: refuses (73)
    if pool:
        for h in order[:-1]:
            if h in free:
                h.short = True
                h.cfg = dict(h.cfg, rr_wait_min=float(cfg.get("rr_race_wait_min", RACE_WAIT_MIN)))
    local_after = None
    if pool and order and not free and job.get("local_ok"):
        lf = local_free_gb()
        if lf is not None and lf > float(cfg.get("rr_local_min_free_gb", LOCAL_MIN_FREE_GB)):
            local_after = float(cfg.get("rr_local_after_s", LOCAL_AFTER_S))
    p = Plan(order, pool, local_after, bad)
    p.promoted = promoted
    p.req = req
    return p


# ---------------------------------------------------------------------------- shards

SHARD_MAX = 8                # at most this many vitest shards per run (rr_shard_max)
# vitest flags that take a separate value (`--project x`): the value is not a file filter
_VITEST_VALUE_FLAGS = {"-c", "--config", "-r", "--root", "--dir", "-t", "--testNamePattern", "--project",
                       "--environment", "--pool", "--mode", "--exclude", "--maxWorkers", "--minWorkers",
                       "--retry", "--bail", "--testTimeout", "--hookTimeout", "--reporter",
                       "--sequence.seed"}


def shard_mode(cfg, environ=None):
    """RRUN_SHARD: "0" = never, n >= 2 = force n shards, unset/other = auto (rr_shard, default on)."""
    environ = os.environ if environ is None else environ
    v = (environ.get("RRUN_SHARD") or "").strip()
    if v.isdigit():
        return 0 if int(v) <= 1 else int(v)
    return "auto" if cfg.get("rr_shard", True) else 0


def shardable(argv, job, cwd=None, forced=False):
    """-> (True, "") when `argv` is a `vitest run` that vitest's own --shard=i/n can split, else
    (False, why). Never: db jobs, --watch, --ui, --coverage, --shard already, a json/junit reporter or
    --outputFile (machine-read output). Auto (not forced) also needs no file arguments, or only
    dirs / globs: a run of named files is small, not worth n checkouts."""
    if job.get("db") or job.get("cls") == "db":
        return False, "a DB job"
    i = next((k for k, a in enumerate(argv[:-1]) if os.path.basename(a) == "vitest" and argv[k + 1] == "run"), None)
    if i is None:
        return False, "not a `vitest run`"
    rest, files, flags_done, k = argv[i + 2:], [], False, 0
    while k < len(rest):
        a = rest[k]
        k += 1
        if a == "--" and not flags_done:
            flags_done = True
            continue
        if not a.startswith("-") or flags_done:
            files.append(a)
            continue
        name, eq, val = a.partition("=")
        if name in ("-w", "--watch", "--ui", "--outputFile", "--merge-reports", "--standalone") \
                or name.startswith(("--coverage", "--shard", "--outputFile.")):
            return False, "%s is set" % name
        if name in _VITEST_VALUE_FLAGS and not eq and k < len(rest):
            val, k = rest[k], k + 1                       # `--project x`: x is no file filter
        if name == "--reporter" and re.search(r"json|junit|blob", val):
            return False, "a machine-read reporter"
    if forced:
        return True, ""
    for f in files:
        glob = any(c in f for c in "*?[{")
        isdir = f.endswith("/") or (cwd is not None and os.path.isdir(os.path.join(cwd, f)))
        if not (glob or isdir):
            return False, "names files / filters (%s)" % f
    return True, ""


def shard_assign(cfg, plan, job, n=None):
    """Free workers -> [host per shard] (shard i/n runs on result[i-1]), or None when sharding would
    not help. Auto: every free worker that can start before the best one would have FINISHED the
    whole job alone takes round(eff / lower-median eff) shards (>= 1, <= its free slots): faster machines
    get more (e.g. eff 3 / 1.2 / 0.45 -> 3 + 1 + 1). Forced n: one per worker by eta, the rest to
    whichever would then finish its share soonest. A "shards": false worker never gets one."""
    if not plan.pool:
        return None
    cands = [h for h in plan.hosts if takes_shards(h)]   # never a "shards": false worker
    free = [h for h in cands if h.state == "free" and h.eta is not None]
    free.sort(key=lambda h: h.eta)
    if not free:
        if not n:
            return None
        free = [h for h in cands if h.eta is not None][:1] or cands[:1]
        if not free:
            return None
    best = free[0].eta if free[0].eta is not None else 0
    elig = [h for h in free if h is free[0] or (h.cold_s or 0) + min(h.rtt or 0, RTT_CAP_S) < best]
    eff = lambda h: h.eff or h.speed or 1.0                                     # noqa: E731
    slots = lambda h: max(1, int(_num((h.probe or {}).get("slots_cap"), 1)      # noqa: E731
                                 - _num((h.probe or {}).get("slots_busy"), 0)))
    if n:
        k = {h.name: 0 for h in elig[:n]}
        hs = elig[:n]
        for h in hs:
            k[h.name] = 1
        for _ in range(n - len(hs)):
            h = min(hs, key=lambda x: (k[x.name] + 1) / eff(x))
            k[h.name] += 1
    else:
        if len(elig) < 2:
            return None
        med = sorted(eff(h) for h in elig)[(len(elig) - 1) // 2]   # lower median: 2 hosts -> the slower
        hs = elig
        k = {h.name: max(1, min(slots(h), int(eff(h) / med + 0.5))) for h in hs}
        mx = int(cfg.get("rr_shard_max", SHARD_MAX))
        while sum(k.values()) > max(2, mx):
            h = max((x for x in hs if k[x.name] > 1), key=lambda x: (k[x.name], -eff(x)), default=None)
            if h is None:
                hs = hs[:-1]
                k = {x.name: k[x.name] for x in hs}
                continue
            k[h.name] -= 1
        if len(hs) < 2:
            return None
    return [h for h in hs for _ in range(k[h.name])]


def shard_summary(texts):
    """vitest summaries ("Test Files  1 failed | 3 passed (4)", "Tests  ...") of each shard's
    output -> merged lines in the same shape ([] when no shard printed one)."""
    tot = {}
    ansi = re.compile(r"\x1b\[[0-9;]*m")
    for t in texts:
        seen = set()
        for line in reversed(ansi.sub("", t).splitlines()):    # the last summary of each shard
            m = re.match(r"^\s*(Test Files|Tests)\s+(.*?)\s*\((\d+)\)\s*$", line)
            if not m or m.group(1) in seen:
                continue
            seen.add(m.group(1))
            d = tot.setdefault(m.group(1), {"total": 0})
            d["total"] += int(m.group(3))
            for cnt, word in re.findall(r"(\d+)\s+([a-z]+)", m.group(2)):
                d[word] = d.get(word, 0) + int(cnt)
    out = []
    for key, pad in (("Test Files", " "), ("Tests", "      ")):
        d = tot.get(key)
        if d:
            parts = ["%d %s" % (d[w], w) for w in ("failed", "passed", "skipped", "todo") if d.get(w)]
            parts += ["%d %s" % (v, w) for w, v in sorted(d.items())
                      if w not in ("failed", "passed", "skipped", "todo", "total")]
            out.append("%s%s  %s (%d)" % (pad, key, " | ".join(parts), d["total"]))
    return out


def fmt_s(s):
    if s is None:
        return "-"
    return "%ds" % round(s) if s < 600 else "%dm" % round(s / 60.0)


def where_report(cfg, job, p, shards=None):
    """Lines for `rrun --where` (shards: shard_assign()'s list, or a why-not string, or None)."""
    lines = ["job class: %s (needs %s GB%s%s)" % (job["cls"], job["need_gb"],
                                                  ", safe to repeat" if job["retry_ok"] else "",
                                                  ", never local" if job["never_local"] else "")]
    lines.append("%-10s %-16s %-7s %5s %9s %8s %5s %5s %6s %7s %5s" % (
        "worker", "ssh", "state", "free", "load/cpu", "mem GB", "git", "deps", "speed", "eta", "share"))
    for h in p.hosts:
        pr = h.probe or {}
        free = "-" if not pr else "%d/%d" % (_num(pr.get("slots_cap"), 0) - _num(pr.get("slots_busy"), 0),
                                              _num(pr.get("slots_cap"), 0))
        load = "-" if not pr else "%.2f" % (_num(pr.get("load1"), 0) / (_num(pr.get("ncpu"), 1) or 1))
        mem = "-" if pr.get("mem_avail_mb") is None else "%.1f" % (_num(pr["mem_avail_mb"]) / 1024)
        yn = lambda k: "-" if not pr else ("warm" if pr.get(k) else "cold")  # noqa: E731
        lines.append("%-10s %-16s %-7s %5s %9s %8s %5s %5s %6.2f %7s %5s%s" % (
            h.name[:10], str(h.cfg.get("host"))[:16], h.state, free, load, mem, yn("warm_git"),
            yn("warm_deps"), h.speed, fmt_s(h.eta), str(pr.get("share") or "-")[:5],
            "  (overloaded: held off)" if h.overloaded
            else "" if h.probe is not None or not getattr(h, "why", None) else "  (%s)" % h.why))
    for h, why in p.ineligible:
        lines.append("%-10s %-16s %-7s  %s" % (h.name[:10], str(h.cfg.get("host"))[:16], "never", why))
    if not p.hosts:
        lines.append("pick: none - " + no_eligible_msg(job, p.ineligible) + " (rrun exits 75)")
        return lines
    if isinstance(shards, list):
        cnt = {}
        for h in shards:
            cnt[h.name] = cnt.get(h.name, 0) + 1
        lines.append("shards: %d (%s)" % (len(shards), ", ".join("%s %d" % kv for kv in cnt.items())))
    elif shards:
        lines.append("shards: no (%s)" % shards)
    first = p.hosts[0]
    if p.promoted is first:
        lines.append("pick: %s (busy, but its eta beats every free worker: waits for a slot up to %s, "
                     "then moves on)" % (first.name, fmt_s(60 * first.cfg["rr_wait_min"])))
    elif p.local_after_s is not None:
        lines.append("pick: %s (all busy: queues there; runs on this machine after %d s of waiting)"
                     % (first.name, p.local_after_s))
    else:
        lines.append("pick: %s%s" % (first.name, " (its owner turned sharing off: nothing runs there now)"
                                     if first.state == "off"
                                     else "" if p.pool or first.probe is None or first.state == "free"
                                     else " (only host: queues there)" if first.state != "down"
                                     else " (only host)"))
    return lines


# ---------------------------------------------------------------------------- bench

# Fixed single-thread CPU workload (perl, no deps); prints seconds, writes ~/rr/speed when asked.
BENCH = r'''
use strict; use warnings; use Time::HiRes qw(time); use Digest::SHA qw(sha256);
my $R = $ENV{RR_ROOT} || "$ENV{HOME}/rr";
my ($ref, $iters) = @ARGV;
my $t = time; my $x = "rrun-bench" x 100; my %h;
for my $i (1 .. $iters) { $x = sha256($x . $i); $h{$i % 4096} = substr($x, 0, 8); if ($i % 20000 == 0) { my @s = sort keys %h } }
my $s = time - $t;
my $speed = sprintf("%.3f", $ref / ($s || 0.001));
mkdir $R, 0700 unless -e $R || -l $R;    # a fresh worker (a new Mac) has no ~/rr until its first run
if (-d $R && !-l $R) { my $tmp = "$R/.speed.$$"; if (open(my $f, ">", $tmp)) { print $f "$speed\n"; close $f; rename $tmp, "$R/speed" } }
printf "%.3f %s\n", $s, $speed;
'''
BENCH_ITERS = 4000000


def bench(cfg, force=None):
    """`rrun --bench`: run the CPU benchmark on every worker (or --host), store ~/rr/speed there."""
    try:
        hosts, _ = pick_hosts(cfg, force)
    except ValueError as e:
        note(str(e))
        return 2
    ref = float(cfg.get("rr_bench_ref_s", BENCH_REF_S))
    rc = 0
    for h in hosts:
        cmd = ssh_base() + [h.cfg["host"], "%sexec /usr/bin/perl -e %s %s %d" % (
            remote_env(h.cfg), shlex.quote(BENCH), shlex.quote(str(ref)),
            int(cfg.get("rr_bench_iters", BENCH_ITERS)))]
        try:
            p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, timeout=600)
            out = p.stdout.decode().split() if p.returncode == 0 else []
        except (OSError, subprocess.TimeoutExpired):
            out = []
        if len(out) == 2:
            print("%-10s %8ss  speed %s" % (h.name, out[0], out[1]))
        else:
            print("%-10s unreachable / failed" % h.name)
            rc = 1
    return rc
