"""rdocker rd_pool: per-job placement of `rrun` jobs on the worker pool (fleet.json workers).

rd_run asks `plan()` for an ordered list of hosts to try. With no fleet (or no rd_fleet module)
the list is cfg["host"] alone and nothing is probed: the single-host rrun of before. With exactly
one enabled worker it is that worker alone, also unprobed (same behaviour as before, on its
alias). With two or more, every worker is probed in parallel over its own rr-%C ssh master with a
small `perl -e` snippet (PROBE; nothing is installed on the worker) and scored:

    score = speed * free / (1 + load1 / ncpu) * warm - rtt_s
    free  = free slots (heavy jobs: min(free slots, free heavy slots)); slots capped by ~/rr/slots.cap
            and by the owner's share switch (some = half the slots and heavy slots; off = state "off",
            no score, tried last; no share file = max - see rr_runner.pl share_level)
    warm  = 0.6 when the repo's bare git mirror is missing  x  0.5 when its packages are not there
    speed = ~/rr/speed on the worker (written by `rrun --bench`), else the fleet entry's speed

A worker is skipped when it has no free slot or less available memory than the job needs. The
order is: free workers by score (ties: lower rtt), then busy ones by slots*speed (the first one
is the "wait host": the job queues there), then the ones that did not answer. Free candidates get
a short slot wait so a lost race (another client took the slot) moves on quickly; the wait host
gets the full rr_wait_min.

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
COLD_GIT, COLD_DEPS = 0.6, 0.5
NEED_GB = {"heavy": 6, "build": 3, "normal": 2, "light": 1, "db": 2}
# rr_outputs: {"<repo name or slug>": {"<package dir relative to the repo>": ["dist", ...]}}
# Builds are only sent to the pool for a mapped package dir; outputs are copied back.
DEFAULT_OUTPUTS = {"dentall": {"server": ["dist"], "client": ["dist"], "admin-client": ["dist"]}}
BENCH_REF_S = 4.0            # bench seconds that score speed 1.0 (rr_bench_ref_s overrides)

_DB_RE = re.compile(r"(^|\s)(test:db(:rls)?|release:rehearse:migrations|check:db-all)(\s|$)"
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
            "local_ok": cls == "light", "never_local": cls in ("db", "heavy")}


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
        self.probe, self.score, self.state, self.short = None, None, "-", False

    @property
    def speed(self):
        p = self.probe or {}
        try:
            return float(p.get("speed")) if p.get("speed") not in (None, "") else float(_f(self.entry, "speed", 1.0))
        except (TypeError, ValueError):
            return 1.0


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
$o{slots_cap} = $n; $o{slots_busy} = 0; $o{slots_busy} += busy("$R/slots/$_") for 0 .. $n - 1;
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
    my @mine = $slug eq "" ? () : map { slurp($_) } glob("$R/w/$slug-*$sub/node_modules/.rr-deps-stamp");
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


def score(host, job):
    """-> (score or None when the host cannot take the job now, free slots). Sets host.state."""
    p = host.probe
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
    if free <= 0:
        host.state = "busy"
        return None, free
    if mem is not None and mem < job["need_gb"] * 1024:
        host.state = "low-mem"
        return None, free
    load, ncpu = _num(p.get("load1"), 0.0), _num(p.get("ncpu"), 1.0) or 1.0
    warm = (1.0 if p.get("warm_git") else COLD_GIT) * (1.0 if p.get("warm_deps") else COLD_DEPS)
    host.state = "free"
    # rtt penalty capped: a cold ssh master's one-off handshake (~2 s over a relay) is not the link's latency
    return host.speed * free / (1.0 + load / ncpu) * warm - min(host.rtt or 0.0, RTT_CAP_S), free


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
    def __init__(self, hosts, pool, local_after_s=None):
        self.hosts, self.pool, self.local_after_s = hosts, pool, local_after_s


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
        return Plan(hosts, False)
    req = {"slug": slug, "deps": [list(d) for d in deps]}

    def req_for(h):
        r = dict(req, slots=h.cfg.get("rr_slots", 1))
        hs = _f(h.entry, "heavy_slots") if h.entry is not None else None
        if isinstance(hs, int) and hs >= 0:
            r["heavy_slots"] = hs
        return r
    probe_all(hosts, req_for, float(cfg.get("rr_probe_timeout_s", PROBE_TIMEOUT_S)))
    free, busy, down, off = [], [], [], []
    for h in hosts:
        h.score, _ = score(h, job)
        (free if h.score is not None else down if h.probe is None else off if h.state == "off"
         else busy).append(h)
    free.sort(key=lambda h: (-h.score, h.rtt or 0))
    cap = lambda h: _num((h.probe or {}).get("slots_cap"), h.cfg.get("rr_slots", 1)) * h.speed  # noqa: E731
    busy.sort(key=lambda h: -cap(h))
    down.sort(key=lambda h: -(h.cfg.get("rr_slots", 1) * h.speed))
    order = free + busy + down + off      # off last: its runner refuses at once (73 UNAVAIL) anyway
    if pool:
        for h in order[:-1]:
            if h in free:
                h.short = True
                h.cfg = dict(h.cfg, rr_wait_min=float(cfg.get("rr_race_wait_min", RACE_WAIT_MIN)))
    local_after = None
    if pool and not free and job.get("local_ok"):
        lf = local_free_gb()
        if lf is not None and lf > float(cfg.get("rr_local_min_free_gb", LOCAL_MIN_FREE_GB)):
            local_after = float(cfg.get("rr_local_after_s", LOCAL_AFTER_S))
    return Plan(order, pool, local_after)


def where_report(cfg, job, p):
    """Lines for `rrun --where`."""
    lines = ["job class: %s (needs %s GB%s%s)" % (job["cls"], job["need_gb"],
                                                  ", safe to repeat" if job["retry_ok"] else "",
                                                  ", never local" if job["never_local"] else "")]
    lines.append("%-10s %-16s %-7s %5s %9s %8s %5s %5s %6s %7s %5s" % (
        "worker", "ssh", "state", "free", "load/cpu", "mem GB", "git", "deps", "speed", "score", "share"))
    for h in p.hosts:
        pr = h.probe or {}
        free = "-" if not pr else "%d/%d" % (_num(pr.get("slots_cap"), 0) - _num(pr.get("slots_busy"), 0),
                                              _num(pr.get("slots_cap"), 0))
        load = "-" if not pr else "%.2f" % (_num(pr.get("load1"), 0) / (_num(pr.get("ncpu"), 1) or 1))
        mem = "-" if pr.get("mem_avail_mb") is None else "%.1f" % (_num(pr["mem_avail_mb"]) / 1024)
        yn = lambda k: "-" if not pr else ("warm" if pr.get(k) else "cold")  # noqa: E731
        lines.append("%-10s %-16s %-7s %5s %9s %8s %5s %5s %6.2f %7s %5s%s" % (
            h.name[:10], str(h.cfg.get("host"))[:16], h.state, free, load, mem, yn("warm_git"),
            yn("warm_deps"), h.speed, "-" if h.score is None else "%.2f" % h.score,
            str(pr.get("share") or "-")[:5],
            "" if h.probe is not None or not getattr(h, "why", None) else "  (%s)" % h.why))
    first = p.hosts[0]
    if p.local_after_s is not None:
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
