"""rdocker rd_cache: rrun's result cache (on the agent Mac, ~/.local/state/rdocker/cache/).

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
INFRA_RC = frozenset({65, 69, 70, 73, 75, 78})

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
        self.lock = threading.Lock()

    def taint(self, why):
        with self.lock:
            self.bad = self.bad or why

    def shipped(self, cid):
        if cid != self.cid:
            self.taint("the files changed while it ran")

    def attempt_done(self, host, rc, docker=False, interrupted=False):
        """A command that really ran on a worker ended with rc (the runner's EXIT status)."""
        if docker:
            self.taint("it used docker on the worker")
        if interrupted:
            self.taint("it was interrupted")
        with self.lock:
            self.finished.append((host, rc))

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

    def save(self, rc, secs, argv_text):
        if self.why_not_save(rc) is not None:
            return False
        workers = ", ".join(dict.fromkeys(h for h, _r in self.finished))
        meta = {"v": FORMAT, "rc": rc, "ts": time.time(), "worker": workers, "secs": round(secs, 1),
                "argv": argv_text}
        return store(self.key, meta, self.rec.frames)


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
    body = b"".join(b"%d %d\n" % (fd, len(d)) + d for fd, d in frames)
    try:
        _ensure_dir()
        tmp = os.path.join(CACHE_DIR, ".%s.%d.tmp" % (k, os.getpid()))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(json.dumps(meta).encode("utf-8") + b"\n" + body)
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
