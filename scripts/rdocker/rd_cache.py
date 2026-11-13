"""rdocker rd_cache: rrun's result cache (on the agent Mac, ~/.local/state/rdocker/cache/), plus its
pool tier on the fleet's home worker (~rd/rr/rcache/, shared by every agent Mac, with singleflight
leases: see "pool tier" below).

Agents often rerun the same check on the same code. When the code a worker would get and the
command are both identical to a recent run, rrun replays that run's output and exits with its code
instead of running it again (stderr: "rrun: cached result (...); RRUN_CACHE=0 to run again").

What is cacheable (why_not_static / why_not_script; anything else is never cached):
  * a one-shot tsc / vue-tsc / eslint (no --fix) / `vitest run` / jest (no watch), directly, via
    npx, or `node [--max-old-space-size=N] <path to one of them>`;
  * `npm test` / `npm run <test|typecheck|type-check|lint|tsc>[:sub]` whose script body (read from
    the package.json rrun ships, pre/post scripts included) is only those tools joined by `&&` (or
    `npm run` of another such script): no env assignments, no other program, no shell syntax.
  Never: DB jobs (rd_pool's db class, or a DB-looking variable in the env sent / the env files
  shipped), builds (outputs come back), --host runs (lookup only), local runs, a run that called
  docker on the worker (the runner reports it), was interrupted, retried after a lost worker in a
  sharded run, hedged, or whose files changed while it ran.

The key (key()) = sha256 over content_id + argv + relcwd + job class. content_id() hashes exactly
what a worker receives for the run: HEAD sha (the commit pushed), the base branches pushed (as
shas), every overlay member (path, exec bit, sha256 of the bytes) plus which are env files, the
deleted list, the env dict of the runner header (rr_env_pass + -e, values included), the deps dirs,
and the runner script itself. The worker's mirror is `git checkout -f <sha>` + `git clean -fd`,
then the overlay and deletes: its tracked/untracked tree is a function of exactly these inputs.
Every real attempt recomputes content_id from what it shipped; a result is saved only when each
attempt's id equals the key's, so a file edited mid-run can never be saved under the old key.

Entries: <key>.entry = one JSON line (v, rc, ts, worker, secs, argv) + the output as frames
"<fd> <len>\\n<bytes>" in the order it was printed. Passes live PASS_TTL_S, failures FAIL_TTL_S;
the store is capped at MAX_BYTES (least recently used first out). 0700 dir, 0600 files.
"""
import hashlib
import hmac
import json
import os
import re
import shlex
import tarfile
import io
import threading
import time

import rd_common

CACHE_DIR = os.path.join(rd_common.STATE_DIR, "cache")
FORMAT = 1
PASS_TTL_S = 24 * 3600
FAIL_TTL_S = 20 * 60
MAX_BYTES = 200 * 1024 * 1024
ENTRY_MAX_BYTES = 16 * 1024 * 1024
# rrun's / the runner's own exit codes (never a tool's verdict worth replaying) and signals
INFRA_RC = frozenset({65, 69, 70, 72, 73, 75, 76, 77, 78, 79, 124, 127, 132})   # rd_run.EXIT_CODES   # 124: hit its wall-clock cap (rd_run.EXIT_TIMEOUT); 132: SIGILL (rd_run.EXIT_SIGILL)

TOOLS = {"tsc", "vue-tsc", "eslint", "vitest", "jest"}
SCRIPT_NAME_RE = re.compile(r"^(test|typecheck|type-check|lint|tsc)(:[A-Za-z0-9_.-]+)*$")
NPX_FLAGS = {"-y", "--yes", "--no", "--no-install", "-q", "--quiet", "--offline", "--prefer-offline"}
NPM_FLAGS = {"-s", "--silent", "-q", "--quiet", "--if-present"}
NODE_FLAG_RE = re.compile(r"^--(max-old-space-size|max-semi-space-size|stack-size)=\d+$")
# a variable that points the run at a database (sent env, -e, shipped env files)
DB_NAME_RE = re.compile(r"(^|_)(DB|DATABASE|PG|POSTGRES|POSTGRESQL|MYSQL|MONGO|MONGODB|REDIS|NEON|SUPABASE)"
                        r"(_|$)|^PG[A-Z]+$|DATABASE_URL", re.I)
SHELL_RE = re.compile(r"[;|<>`$()\\&\n]")   # globs are fine: the same files expand the same way


# ---------------------------------------------------------------------------- what is cacheable

def _tool_why(words):
    """words = [program, args...] -> None when it is a known one-shot check, else why not."""
    if not words:
        return "an empty command"
    prog, args = os.path.basename(words[0]), list(words[1:])
    if prog in ("npx", "bunx"):
        while args and args[0] in NPX_FLAGS:
            args.pop(0)
        return _tool_why(args) if args and os.path.basename(args[0]) in TOOLS else \
            "npx runs something other than tsc / eslint / vitest / jest"
    if prog == "node":
        while args and NODE_FLAG_RE.match(args[0]):
            args.pop(0)
        if not args or args[0].startswith("-"):
            return "node with flags or code rrun does not know"
        name = re.sub(r"\.(c|m)?js$", "", os.path.basename(args[0]))
        if name not in TOOLS:
            return "node runs %s, not a known check" % os.path.basename(args[0])
        return _tool_why([name] + args[1:])
    if prog not in TOOLS:
        return "%s is not tsc / eslint / vitest / jest" % prog
    flags = set(a.split("=", 1)[0] for a in args if a.startswith("-"))
    if prog in ("tsc", "vue-tsc") and flags & {"-w", "--watch"}:
        return "tsc --watch"
    if prog == "eslint" and flags & {"--fix", "--fix-type"}:
        return "eslint --fix changes files"
    if prog == "vitest":
        if not (args and args[0] == "run") and "--run" not in flags:
            return "vitest without `run`"
        if flags & {"-w", "--watch", "--ui", "-u", "--update"}:
            return "vitest watch / ui / snapshot update"
    if prog == "jest" and flags & {"--watch", "--watchAll", "-u", "--updateSnapshot"}:
        return "jest watch / snapshot update"
    return None


def _npm_parse(words):
    """`npm ...` words -> (script name, prefix or None, None) or (None, None, why not)."""
    rest, prefix, name = list(words[1:]), None, None
    while rest:
        a = rest.pop(0)
        if a == "--":
            break
        if a == "--prefix" and rest:
            prefix = rest.pop(0)
        elif a.startswith("--prefix="):
            prefix = a[len("--prefix="):]
        elif a in NPM_FLAGS:
            continue
        elif a.startswith("-"):
            return None, None, "npm flag %s" % a
        elif name is None:
            if a in ("test", "t", "tst"):
                name = "test"
            elif a in ("run", "run-script", "rum", "urn"):
                name = ""
            else:
                return None, None, "npm %s" % a
        elif name == "":
            name = a
        # later bare words are the script's own arguments (part of the key)
    if not name:
        return None, None, "npm without a script"
    if not SCRIPT_NAME_RE.match(name):
        return None, None, "the %r script is not a test / typecheck / lint script" % name
    return name, prefix, None


def why_not_static(argv, job, outputs, env):
    """-> None when argv can be cached as far as argv / class / env tell, else why not. `env` =
    the env dict the runner header would carry."""
    if outputs or job.get("cls") == "build":
        return "a build (its outputs are copied back)"
    if job.get("db") or job.get("cls") == "db":
        return "a DB job"
    bad = sorted(k for k in env if DB_NAME_RE.search(k))
    if bad:
        return "it is sent a database setting (%s)" % ", ".join(bad)
    if argv and os.path.basename(argv[0]) == "npm":
        _name, _prefix, why = _npm_parse(argv)
        return why
    return _tool_why(argv)


def npm_pkg_dir(argv, relcwd):
    """Repo-relative dir whose package.json an `npm` argv runs (relcwd + --prefix), or None."""
    _name, prefix, why = _npm_parse(argv)
    if why:
        return None
    d = os.path.normpath(os.path.join(relcwd or ".", prefix or ".")).replace(os.sep, "/")
    d = "" if d == "." else d
    return None if d == ".." or d.startswith(("../", "/")) else d


def _script_why(scripts, name, depth=0):
    body = scripts.get(name)
    if not isinstance(body, str) or not body.strip():
        return "no %r script" % name
    if depth > 4:
        return "scripts nested too deep"
    for hook in ("pre" + name, "post" + name):
        if hook in scripts:
            why = _script_why(scripts, hook, depth + 1)
            if why:
                return "%s: %s" % (hook, why)
    if SHELL_RE.search(body.replace("&&", " ")):
        return "the %r script uses shell syntax" % name
    for seg in body.split("&&"):
        try:
            words = shlex.split(seg)
        except ValueError:
            return "the %r script does not parse" % name
        if not words:
            return "the %r script has an empty step" % name
        if "=" in words[0] or words[0] == "cross-env":
            return "the %r script sets env vars (it may reach a database)" % name
        if words[0] == "npm":
            sub, prefix, why = _npm_parse(words)
            if why or prefix:
                return "the %r script runs %s" % (name, why or "npm --prefix")
            why = _script_why(scripts, sub, depth + 1)
        else:
            why = _tool_why(words)
        if why:
            return "the %r script: %s" % (name, why)
    return None


def why_not_script(argv, relcwd, read_file):
    """npm argv -> None when its script (and pre/post) are known checks only, else why not.
    read_file(repo-relative path) -> bytes or None: the file exactly as rrun ships it."""
    if not argv or os.path.basename(argv[0]) != "npm":
        return None
    name, _prefix, why = _npm_parse(argv)
    if why:
        return why
    d = npm_pkg_dir(argv, relcwd)
    if d is None:
        return "npm --prefix outside the repo"
    raw = read_file((d + "/" if d else "") + "package.json")
    try:
        scripts = json.loads(raw.decode("utf-8")).get("scripts") if raw else None
    except (ValueError, UnicodeDecodeError, AttributeError):
        scripts = None
    if not isinstance(scripts, dict):
        return "no readable package.json scripts in ./%s" % d
    return _script_why(scripts, name)


def env_files_why(tar, env_files):
    """-> why not when an env file in the overlay (rrun ships some, rr_env_allow) sets a DB variable."""
    names = set(env_files)
    for name, _mode, data in tar_members(tar):
        if name not in names:
            continue
        for line in data.decode("utf-8", "replace").splitlines():
            m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
            if m and DB_NAME_RE.search(m.group(1)):
                return "%s sets a database variable (%s)" % (name, m.group(1))
    return None


# ---------------------------------------------------------------------------- identity

def tar_members(tar):
    """Overlay tar bytes -> [(name, mode, data)] in tar order."""
    if not tar:
        return []
    out = []
    with tarfile.open(fileobj=io.BytesIO(tar), mode="r:") as t:
        for m in t:
            data = t.extractfile(m).read() if m.isreg() else b""
            out.append((m.name, m.mode, data))
    return out


def runner_digest():
    try:
        with open(rd_common.RUNNER_SRC, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return "-"


def content_id(sha, base_specs, tar, env_files, deleted, env, deps):
    """sha256 of everything a worker receives that decides its files and environment."""
    h = hashlib.sha256()
    head = {"v": FORMAT, "sha": sha, "base": sorted(base_specs), "env_files": sorted(env_files),
            "deleted": sorted(deleted), "env": sorted(env.items()), "deps": list(deps),
            "runner": runner_digest()}
    h.update(json.dumps(head, sort_keys=True).encode("utf-8", "surrogateescape") + b"\0")
    for name, mode, data in sorted(tar_members(tar), key=lambda m: m[0]):
        h.update(("%s\0%d\0%s\0" % (name, 1 if mode & 0o100 else 0,
                                     hashlib.sha256(data).hexdigest())).encode("utf-8", "surrogateescape"))
    return h.hexdigest()


def key(cid, argv, relcwd, cls):
    raw = json.dumps({"v": FORMAT, "content": cid, "argv": list(argv), "relcwd": relcwd, "cls": cls})
    return hashlib.sha256(raw.encode("utf-8", "surrogateescape")).hexdigest()


# ---------------------------------------------------------------------------- capture

class Recorder:
    """The output of one rrun as (fd, bytes) frames in print order; drops all once over the cap."""

    def __init__(self, cap=ENTRY_MAX_BYTES):
        self.cap, self.lock = cap, threading.Lock()
        self.frames, self.size, self.over = [], 0, False

    def add(self, fd, data):
        with self.lock:
            if self.over or not data:
                return
            self.size += len(data)
            if self.size > self.cap:
                self.over, self.frames = True, []
                return
            if self.frames and self.frames[-1][0] == fd:
                self.frames[-1] = (fd, self.frames[-1][1] + data)
            else:
                self.frames.append((fd, data))

    def reset(self):
        with self.lock:
            if not self.over:
                self.frames, self.size = [], 0


class Tee:
    """A byte stream that also records what it writes (fd 1 = stdout, 2 = stderr)."""

    def __init__(self, stream, rec, fd):
        self.stream, self.rec, self.fd = stream, rec, fd

    def write(self, data):
        self.stream.write(data)
        self.rec.add(self.fd, data)

    def flush(self):
        self.stream.flush()


class Run:
    """One cacheable rrun in flight: what it must have shipped (content id), what it printed, how
    each attempt ended. save() stores it only when every check passed."""

    def __init__(self, k, cid):
        self.key, self.cid = k, cid
        self.rec = Recorder()
        self.sharded, self.expect = False, 1
        self.finished, self.bad = [], None
        self.nodes = []              # per finished attempt: the node major it ran with
        self.lock = threading.Lock()

    def taint(self, why):
        with self.lock:
            self.bad = self.bad or why

    def shipped(self, cid):
        if cid != self.cid:
            self.taint("the files changed while it ran")

    def attempt_done(self, host, rc, docker=False, interrupted=False, node=None):
        """A command that really ran on a worker ended with rc (the runner's EXIT status); node = the
        node major it ran with (the runner's NODE status; None = unknown: never shared)."""
        if docker:
            self.taint("it used docker on the worker")
        if interrupted:
            self.taint("it was interrupted")
        with self.lock:
            self.finished.append((host, rc))
            self.nodes.append(node)

    def why_not_save(self, rc):
        if self.bad:
            return self.bad
        if self.rec.over:
            return "its output is over %d MB" % (ENTRY_MAX_BYTES // 1048576)
        if len(self.finished) != self.expect:
            return "not every part ran to its end on a worker"
        if rc != max(r for _h, r in self.finished):
            return "the exit code did not come from the command"
        if not isinstance(rc, int) or rc < 0 or rc >= 128 or rc in INFRA_RC:
            return "exit %s is not a test verdict" % rc
        return None

    def save(self, rc, secs, argv_text, extra=None):
        """-> the saved entry's meta (extra: more meta fields, e.g. the pool tier's node / agent),
        else None when this run may not be replayed. The local tier is written here; the pool tier
        is the caller's (Shared.finish, after the result is printed)."""
        if self.why_not_save(rc) is not None:
            return None
        workers = ", ".join(dict.fromkeys(h for h, _r in self.finished))
        meta = dict(extra or {}, v=FORMAT, rc=rc, ts=time.time(), worker=workers, secs=round(secs, 1),
                    argv=argv_text)
        store(self.key, meta, self.rec.frames)
        return meta


# ---------------------------------------------------------------------------- store

def _path(k):
    return os.path.join(CACHE_DIR, k + ".entry")


def _ensure_dir():
    os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)
    os.chmod(CACHE_DIR, 0o700)


def store(k, meta, frames):
    """Write one entry atomically (tmp + rename), then prune. -> True when written."""
    if not re.match(r"^[0-9a-f]{64}$", k):
        return False
    try:
        _ensure_dir()
        tmp = os.path.join(CACHE_DIR, ".%s.%d.tmp" % (k, os.getpid()))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(entry_bytes(meta, frames))
        os.replace(tmp, _path(k))
    except OSError:
        return False
    prune()
    return True


def ttl(rc):
    return PASS_TTL_S if rc == 0 else FAIL_TTL_S


def _read(path):
    """-> (meta, frames) of a valid entry file, else None."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return None
    return parse_entry(raw)


def entry_bytes(meta, frames):
    """The one entry format, local and shared: a JSON meta line + "<fd> <len>\\n<bytes>" frames."""
    return json.dumps(meta).encode("utf-8") + b"\n" + b"".join(b"%d %d\n" % (fd, len(d)) + d for fd, d in frames)


def parse_entry(raw):
    """Entry bytes -> (meta, frames), else None (damaged, other format). Data only: never executed."""
    line, nl, body = raw.partition(b"\n")
    try:
        meta = json.loads(line.decode("utf-8")) if nl else None
    except (ValueError, UnicodeDecodeError):
        meta = None
    if not isinstance(meta, dict) or meta.get("v") != FORMAT or not isinstance(meta.get("rc"), int) \
            or not isinstance(meta.get("ts"), (int, float)):
        return None
    frames, i = [], 0
    while i < len(body):
        j = body.find(b"\n", i)
        m = re.match(rb"^([12]) (\d+)$", body[i:j]) if j >= 0 else None
        if not m or j + 1 + int(m.group(2)) > len(body):
            return None
        n = int(m.group(2))
        frames.append((int(m.group(1)), body[j + 1:j + 1 + n]))
        i = j + 1 + n
    return meta, frames


def lookup(k, now=None):
    """-> (meta, frames) of a fresh entry for key k (touched: recently used), else None. A stale
    or unreadable entry is removed."""
    now = time.time() if now is None else now
    p = _path(k)
    got = _read(p) if re.match(r"^[0-9a-f]{64}$", k) else None
    if got is None:
        if os.path.exists(p):
            _unlink(p)
        return None
    age = now - got[0]["ts"]
    if age < -60 or age > ttl(got[0]["rc"]):
        _unlink(p)
        return None
    try:
        os.utime(p, None)
    except OSError:
        pass
    return got


def _unlink(p):
    try:
        os.unlink(p)
    except OSError:
        pass


def prune(now=None, cap=None):
    """Drop expired entries and stale temp files, then the least recently used until under cap."""
    now = time.time() if now is None else now
    cap = MAX_BYTES if cap is None else cap
    try:
        names = os.listdir(CACHE_DIR)
    except OSError:
        return
    live = []
    for n in names:
        p = os.path.join(CACHE_DIR, n)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if n.endswith(".tmp"):
            if now - st.st_mtime > 3600:
                _unlink(p)
            continue
        if not n.endswith(".entry"):
            continue
        got = _read(p)
        if got is None or now - got[0]["ts"] > ttl(got[0]["rc"]):
            _unlink(p)
            continue
        live.append((st.st_mtime, st.st_size, p))
    total = sum(s for _m, s, _p in live)
    for _m, size, p in sorted(live):
        if total <= cap:
            break
        _unlink(p)
        total -= size


def fmt_age(secs):
    secs = max(0, int(secs))
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if secs >= size:
            return "%d%s" % (secs // size, unit)
    return "%ds" % secs


def hit_line(meta, now=None):
    now = time.time() if now is None else now
    return ("cached result (same code + command, %s ago on %s); RRUN_CACHE=0 to run again"
            % (fmt_age(now - meta["ts"]), meta.get("worker") or "a worker"))


def replay(frames, out, err):
    """Print a cached run's output in its original order to the byte streams out / err."""
    for fd, data in frames:
        s = out if fd == 1 else err
        s.write(data)
        s.flush()


# ---------------------------------------------------------------------------- pool tier (the home worker)
#
# The same entries, shared by every agent Mac: ~rd/rr/rcache/ on the fleet's home worker (hp, always
# on). Local tier first, then this one. The lookup rides on the placement PROBE rd_pool already sends
# the home worker (rd_pool.plan(rcache=Shared.req())): no extra round trip. It answers
#   hit       the entry (base64), when it is fresh (PASS_TTL_S / FAIL_TTL_S, as locally);
#   inflight  an identical run holds a live lease (owner, how long it may still run): wait for it;
#   miss      nothing; with lease 1 this run now holds the lease (singleflight).
# A lease (<key>.lease: owner, host, pid, token, t, exp = the job's cap + LEASE_MARGIN_S) is live while
# exp is ahead and its owner refreshed it (mtime) within LEASE_STALE_S: the owner's rrun refreshes it
# every LEASE_REFRESH_S, so a killed owner frees it within LEASE_STALE_S. After the result is printed
# the owner stores the entry (when it may be replayed) and drops the lease in one detached ssh (store);
# a run that ends without a replayable result only drops it. Entries are data, never executed; an
# entry over SHARED_MAX is not shared.
# Integrity: every shared entry carries an HMAC-SHA256 ("mac" in its meta) made on the agent Mac with
# KEY_PATH, a secret that exists only on agent Macs (never on a worker, never in git): it binds the cache
# key, every meta field and the exact output bytes, so a job running as rd on the home worker cannot
# forge a verdict. Unsigned or bad-MAC entries are misses. No key file = the pool tier is off here.
# Toolchain: fleet.json's top-level "pool_node_major" is the one declared node major of the pool (no
# value = the pool tier is off). A producer shares only when its runner's actual node major (its
# "NODE <major>" status) equals it; a consumer replays only an entry whose signed node tag equals it.
# A worker on another major therefore never shares (bump the value when the workers are upgraded).
# A pool hit is replayed, never copied into this Mac's tier (that tier has no toolchain check).
# Pruning: rd-tune's prune pass (expired first, then least recently used over its size cap).
SHARED_MAX = 1024 * 1024        # bytes of one shared entry (meta line + frames); a hit carries it in the probe
LEASE_MARGIN_S = 600            # a lease outlives the job's cap by this much (slot wait, prepare)
LEASE_NOCAP_S = 4 * 3600        # ...for a job with no cap (RRUN_TIMEOUT=0)
LEASE_STALE_S = 90              # a lease its owner has not refreshed this long: the owner is gone
LEASE_REFRESH_S = 30
POLL_MAX_S = 5.0                # a waiter polls the home worker at most this far apart
OP_TIMEOUT_S = 10.0             # one poll / refresh ssh
POLL_FAILS = 3                  # a waiter that cannot reach the home worker this many times in a row runs
KEY_PATH = os.path.join(rd_common.CFG_DIR, "pool-cache.key")   # agent Macs only: 64 hex chars, 0600
MAC_CONTEXT = b"rrun-pool-cache-v1\0"
MAC_RE = re.compile(r"\A[0-9a-f]{64}\Z")

RCACHE_PL = r'''
use JSON::PP (); use MIME::Base64 (); use Fcntl qw(:flock O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);
sub rc_ttl { $_[0] == 0 ? 86400 : 1200 }
sub rc_slurp {
    my ($p, $max) = @_;
    return undef if -l $p || !sysopen(my $f, $p, O_RDONLY | O_NOFOLLOW);
    my $b = "";
    while (1) {
        my $n = sysread($f, $b, 65536, length $b);
        return undef unless defined $n;
        last unless $n;
        return undef if length($b) > $max;
    }
    $b
}
sub rc_meta {
    my ($raw) = @_;
    my ($line) = $raw =~ /\A([^\n]*)\n/ or return undef;
    my $m = eval { JSON::PP->new->decode($line) };
    return undef unless ref $m eq "HASH" && ($m->{v} // "") eq "1" && ($m->{rc} // "") =~ /^\d+$/
        && ($m->{ts} // "") =~ /^\d+(\.\d+)?$/;
    $m
}
sub rc_put {
    my ($p, $data) = @_;
    my $t = "$p.$$.tmp";
    unlink $t;
    sysopen(my $f, $t, O_WRONLY | O_CREAT | O_EXCL, 0600) or return 0;
    my $ok = print {$f} $data;
    $ok = close($f) && $ok;
    return 1 if $ok && rename($t, $p);
    unlink $t;
    0
}
sub rc_dir {
    mkdir $_[0], 0700 unless -e $_[0] || -l $_[0];
    my $d = "$_[0]/rcache";
    mkdir $d, 0700 unless -e $d || -l $d;
    (-l $d || !-d $d) ? undef : $d
}
sub rc_lock {
    sysopen(my $l, "$_[0]/.lock", O_WRONLY | O_CREAT | O_NOFOLLOW, 0600) or return undef;
    flock($l, LOCK_EX) ? $l : undef
}
sub rc_lease { my $raw = rc_slurp($_[0], 4096); my $ls = defined $raw ? eval { JSON::PP->new->decode($raw) } : undef; ref $ls eq "HASH" ? $ls : undef }
# $c = {key, max, stale, lease: {owner, host, pid, token, ttl} | absent} -> {st: hit|inflight|miss|bad, ...}
sub rcache {
    my ($R, $c) = @_;
    my $k = $c->{key} // "";
    return { st => "bad" } unless $k =~ /^[0-9a-f]{64}$/;
    my $d = rc_dir($R) or return { st => "bad" };
    my $now = time;
    my $max = ($c->{max} // "") =~ /^(\d+)$/ ? $1 : 1048576;
    my $e = "$d/$k.entry";
    if (-e $e || -l $e) {
        my $raw = rc_slurp($e, $max);
        my $m = defined $raw ? rc_meta($raw) : undef;
        if ($m && $now - $m->{ts} >= -60 && $now - $m->{ts} <= rc_ttl($m->{rc})) {
            utime(undef, undef, $e);                       # recently used: the prune keeps it longer
            return { st => "hit", entry => MIME::Base64::encode_base64($raw, "") };
        }
        unlink $e;
    }
    my $lk = rc_lock($d) or return { st => "miss" };      # check + take the lease is one step
    my $l = "$d/$k.lease";
    my $stale = ($c->{stale} // "") =~ /^(\d+)$/ ? $1 : 90;
    my $mine = ref $c->{lease} eq "HASH" ? $c->{lease} : undef;
    if (-e $l || -l $l) {
        my $ls = rc_lease($l);
        my $mt = (lstat $l)[9] // 0;
        if ($ls && ($ls->{exp} // "") =~ /^\d+(\.\d+)?$/ && $ls->{exp} > $now && $now - $mt <= $stale
                && !($mine && ($ls->{token} // "") eq ($mine->{token} // ""))) {
            my $t = ($ls->{t} // "") =~ /^\d+$/ ? $ls->{t} : $now;
            return { st => "inflight", owner => "" . ($ls->{owner} // "?"), host => "" . ($ls->{host} // "?"),
                     age => $now - $t, left => int($ls->{exp} - $now) };
        }
        unlink $l;                                        # expired, or its owner stopped refreshing it
    }
    return { st => "miss" } unless $mine;
    my $ttl = ($mine->{ttl} // "") =~ /^(\d+)$/ ? $1 : 3600;
    my %ls = (owner => "" . ($mine->{owner} // "?"), host => "" . ($mine->{host} // "?"),
              pid => (($mine->{pid} // "") =~ /^(\d+)$/ ? $1 + 0 : 0), token => "" . ($mine->{token} // ""),
              t => $now, exp => $now + $ttl);
    return { st => "miss", lease => (rc_put($l, JSON::PP->new->canonical->encode(\%ls)) ? 1 : 0) };
}
'''

# The op script (`perl -e RCACHE_OP <op>`, stdin): check = the JSON request -> the answer (a waiter's
# poll); touch = header {key, token}: refresh our lease; store = header {key, token, max} + entry bytes
# (none = only drop the lease): write it atomically, then drop our lease. Bounded by alarm.
RCACHE_OP = RCACHE_PL + r'''
alarm 30;
my $R = $ENV{RR_ROOT} || "$ENV{HOME}/rr";
my $op = $ARGV[0] // "";
binmode STDIN; binmode STDOUT;
if ($op eq "check") {
    my $c = eval { JSON::PP->new->decode(do { local $/; <STDIN> } // "{}") };
    print JSON::PP->new->canonical->encode(rcache($R, ref $c eq "HASH" ? $c : {})), "\n";
    exit 0;
}
exit 2 unless $op eq "touch" || $op eq "store";
my $c = eval { JSON::PP->new->decode(scalar(<STDIN>) // "") };
exit 2 unless ref $c eq "HASH" && ($c->{key} // "") =~ /^([0-9a-f]{64})$/;
my $k = $1;
my $tok = ($c->{token} // "") =~ /^([0-9a-f]{16,64})$/ ? $1 : "";
my $d = rc_dir($R) or exit 2;
my $l = "$d/$k.lease";
my $ours = sub { my $ls = rc_lease($l); $tok ne "" && $ls && ($ls->{token} // "") eq $tok };
if ($op eq "touch") {
    my $lk = rc_lock($d) or exit 1;
    exit($ours->() && utime(undef, undef, $l) ? 0 : 1);
}
my $max = ($c->{max} // "") =~ /^(\d+)$/ ? $1 : 1048576;
my ($body, $chunk) = ("", "");
while (read(STDIN, $chunk, 65536)) { $body .= $chunk; exit 3 if length($body) > $max }
my $ok = !length($body) || (rc_meta($body) && rc_put("$d/$k.entry", $body));
my $lk = rc_lock($d);
unlink $l if $lk && $ours->();
exit($ok ? 0 : 1);
'''


def remote_op(env_prefix, op):
    """The remote command line of one op on the home worker (env_prefix: rd_pool.remote_env)."""
    return "%sexec /usr/bin/perl -e %s %s" % (env_prefix, shlex.quote(RCACHE_OP), op)


def load_key(path=None):
    """The pool-cache secret (bytes) from KEY_PATH, else None (missing, unreadable, a symlink, not ours,
    readable by others, or not 64 hex chars): no key = no pool tier on this Mac."""
    path = path or KEY_PATH
    try:
        st = os.lstat(path)
        if not stat_ok(st):
            return None
        with open(path, "rb") as f:
            raw = f.read(200).strip()
        return bytes.fromhex(raw.decode("ascii")) if re.match(rb"^[0-9a-f]{64}$", raw) else None
    except (OSError, ValueError):
        return None


def stat_ok(st):
    import stat as st_mod
    return st_mod.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and not st.st_mode & 0o077


def key_init(path=None):
    """`rdocker pool-cache-key init`: create the secret if missing (0600, atomically). -> (created, fp);
    raises OSError when a file is there but unusable (fix it by hand: never overwritten)."""
    path = path or KEY_PATH
    if os.path.lexists(path):
        k = load_key(path)
        if k is None:
            raise OSError("%s exists but is not a usable key (a regular 0600 file of 64 hex chars, "
                          "owned by you); not touching it" % path)
        return False, fingerprint(k)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    k = os.urandom(32)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(k.hex() + "\n")
        os.link(tmp, path)               # fails if another init won the race: theirs stays
    finally:
        os.unlink(tmp)
    return True, fingerprint(load_key(path) or k)


def fingerprint(secret):
    """A short hash that names the secret without revealing it (compare it across Macs)."""
    return hashlib.sha256(b"rrun-pool-cache-fingerprint\0" + secret).hexdigest()[:16]


def entry_mac(secret, k, meta, frames):
    """HMAC-SHA256 binding the cache key, every meta field (but "mac") and the exact output bytes."""
    canon = json.dumps({n: v for n, v in meta.items() if n != "mac"}, sort_keys=True, separators=(",", ":"))
    body = b"".join(b"%d %d\n" % (fd, len(d)) + d for fd, d in frames)
    return hmac.new(secret, MAC_CONTEXT + k.encode() + b"\0" + canon.encode("utf-8") + b"\0" + body,
                    hashlib.sha256).hexdigest()


class Shared:
    """The pool tier for one rrun (key k; owner / host: who holds a lease, for a waiter's line;
    ttl_s: the job's cap). attach() names the home worker once the plan found it. leased = this
    run holds the key's lease."""

    def __init__(self, k, owner, host, ttl_s, cfg=None, secret=None, pool_node=None):
        cfg = cfg or {}
        self.key, self.owner, self.host, self.secret = k, owner, host, secret
        self.pool_node = pool_node   # fleet.json pool_node_major (str): the only node shared or replayed
        self.home, self.ssh, self.env_prefix = None, [], ""
        self.ttl = int(ttl_s) + LEASE_MARGIN_S if ttl_s else LEASE_NOCAP_S
        self.stale = int(cfg.get("rr_pool_cache_stale_s", LEASE_STALE_S))
        self.refresh_s = float(cfg.get("rr_pool_cache_refresh_s", LEASE_REFRESH_S))
        self.poll_max = float(cfg.get("rr_pool_cache_poll_s", POLL_MAX_S))
        self.token = os.urandom(12).hex()
        self.leased = False
        self.done = threading.Event()

    def attach(self, home, ssh_argv, env_prefix):
        """home = its name; ssh_argv = the ssh command up to its host; env_prefix = rd_pool.remote_env."""
        self.home, self.ssh, self.env_prefix = home, list(ssh_argv), env_prefix

    def req(self, lease=True):
        r = {"key": self.key, "max": SHARED_MAX, "stale": self.stale}
        if lease:
            r["lease"] = {"owner": self.owner, "host": self.host, "pid": os.getpid(), "token": self.token,
                          "ttl": self.ttl}
        return r

    def answer(self, raw):
        """A probe's / poll's "rcache" dict -> {"st": "hit", "meta", "frames"} | {"st": "inflight",
        "owner", "host", "left"} | {"st": "miss"} | None (no usable answer). A miss with lease 1
        marks this run as the lease holder."""
        if not isinstance(raw, dict):
            return None
        st = raw.get("st")
        if st == "hit":
            try:
                import base64
                got = parse_entry(base64.b64decode(raw.get("entry") or "", validate=True))
            except (ValueError, TypeError):
                got = None
            if got is None or len(raw.get("entry") or "") > SHARED_MAX * 4 // 3 + 8 or not self.signed(*got):
                return {"st": "miss"}            # damaged, oversized, unsigned or forged: never replayed
            age = time.time() - got[0]["ts"]
            if age < -60 or age > ttl(got[0]["rc"]):
                return {"st": "miss"}
            return {"st": "hit", "meta": got[0], "frames": got[1]}
        if st == "inflight":
            left = raw.get("left") if isinstance(raw.get("left"), (int, float)) else 0
            return {"st": "inflight", "owner": str(raw.get("owner") or "?")[:80],
                    "host": str(raw.get("host") or "?")[:48], "left": max(0, left)}
        if st == "miss":
            if raw.get("lease") == 1:
                self.leased = True
            return {"st": "miss"}
        return None

    def signed(self, meta, frames):
        """True only for a well-formed MAC (exactly 64 lowercase hex chars) that matches; anything
        else - a missing, non-string, short, uppercase or non-ASCII MAC - is simply unsigned."""
        mac = meta.get("mac")
        if not self.secret or not isinstance(mac, str) or not MAC_RE.match(mac):
            return False
        want = bytes.fromhex(entry_mac(self.secret, self.key, meta, frames))
        return hmac.compare_digest(bytes.fromhex(mac), want)

    def _argv(self, op):
        return self.ssh + [remote_op(self.env_prefix, op)]

    def poll(self, lease=True, timeout=None):
        """One check over ssh (a waiter): -> answer(), or None when the home worker did not answer
        within timeout (at most OP_TIMEOUT_S)."""
        import subprocess
        try:
            p = subprocess.run(self._argv("check"), input=json.dumps(self.req(lease)).encode(),
                               capture_output=True, timeout=max(0.1, min(OP_TIMEOUT_S, timeout or OP_TIMEOUT_S)))
            raw = json.loads(p.stdout.decode("utf-8", "replace").strip().splitlines()[-1]) \
                if p.returncode == 0 else None
        except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
            raw = None
        return self.answer(raw)

    def start_refresh(self):
        """Keep the lease alive while this process runs (a daemon thread: it dies with us, and the
        lease goes stale LEASE_STALE_S later - a killed owner never holds waiters for its cap)."""
        import subprocess

        def loop():
            while not self.done.wait(self.refresh_s):
                try:
                    subprocess.run(self._argv("touch"), input=json.dumps({"key": self.key, "token": self.token}).encode()
                                   + b"\n", capture_output=True, timeout=OP_TIMEOUT_S)
                except (OSError, subprocess.TimeoutExpired):
                    pass
        threading.Thread(target=loop, daemon=True, name="rcache-lease").start()

    def finish(self, meta=None, frames=None):
        """After the result is printed: one detached ssh stores the entry (when given and small
        enough) and drops our lease. Never waited on; its failure only costs the share. -> True when
        an upload was started (False: nothing to do, or it could not even start)."""
        import subprocess
        import tempfile
        self.done.set()
        body = b""
        if meta is not None and self.secret:
            body = entry_bytes(dict(meta, mac=entry_mac(self.secret, self.key, meta, frames)), frames)
        if len(body) > SHARED_MAX:
            body = b""
        if not body and not self.leased:
            return False
        head = json.dumps({"key": self.key, "token": self.token if self.leased else "", "max": SHARED_MAX})
        try:
            with tempfile.TemporaryFile() as f:      # a file, not a pipe: we never block on a slow link
                f.write(head.encode() + b"\n" + body)
                f.seek(0)
                with open(os.devnull, "wb") as dn:
                    subprocess.Popen(self._argv("store"), stdin=f, stdout=dn, stderr=dn, start_new_session=True,
                                     close_fds=True)
        except OSError:
            return False
        return True


def pool_hit_line(meta, now=None):
    now = time.time() if now is None else now
    by = " by %s" % meta["agent"] if meta.get("agent") else ""
    return ("cached result from the pool cache (same code + command, %s ago on %s%s); RRUN_CACHE=0 to run again"
            % (fmt_age(now - meta["ts"]), meta.get("worker") or "a worker", by))
