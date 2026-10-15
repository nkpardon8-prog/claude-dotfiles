"""rdocker rd_run: `rrun <cmd...>` - run a heavy job (test runner + its DB) ON the Mac mini.

Laptop side of the rrun plan (Revision 3/3.1); the mini side is rr_runner.pl, which this module
SENDS with every run (nothing trusted is kept on the mini). One run:
  1 resolve the git worktree of cwd: repo slug (from the git common dir), wt12, relcwd, HEAD sha
  2 flock STATE_DIR/rrun-<wt12>.lock      (one run at a time per laptop worktree)
  3 git push HEAD -> ~/<rr_root>/git/<slug>.git refs/rrun/<wt12> over the rr-%C ssh master; the
    remote receive-pack creates the bare repo the first time. Push fails => the mini is out =>
    run locally (RDOCKER_MODE=local), unless RRUN_STRICT=1 (exit 75)
  4 overlay tar = tracked files changed vs HEAD + untracked (not ignored) + allowlisted env files
    from the repo root, the cwd and the deps dirs only; deleted = tracked files changed vs HEAD
    that no longer exist
  5 ssh -T host /usr/bin/perl -e <loader>; stdin = runner script frame, header frame, tar, then a
    heartbeat byte every 15 s ("INT\\n" on Ctrl-C; a second Ctrl-C closes stdin = kill)
  6 relay output; "<nonce> STATUS" lines on stderr are ours (WAIT/BUSY/READY/STARTED/KEPT);
    on READY we write "GO\\n" and only then does the runner start the command
  7 rc = ssh's exit status; GO never written => the command never ran: 255 => local fallback,
    other rc = the runner's (73 busy, 78 deps, ...); GO written => 255 = exit 75 (never run twice).
Config: rr_* keys in rd_common.DEFAULTS. Env: RRUN_STRICT=1, RRUN_TIMING=1, RRUN=0 (run locally),
RRUN_GIT_URL (tests only: push URL override).
"""
import fnmatch
import hashlib
import io
import json
import os
import re
import secrets
import shlex
import signal
import subprocess
import sys
import tarfile
import threading
import time

import rd_common

HEARTBEAT_S = 15
OVERLAY_WARN_BYTES = 5 * 1024 * 1024
EXIT_LOST = 75                 # EX_TEMPFAIL: lost the mini mid-run / strict mode and the mini is out
NAME_RE = re.compile(r"[^A-Za-z0-9._-]")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
HELD_LOCKS = []                # worktree lock fds: made inheritable only for a local-fallback exec
LOST_MSG = "rrun: lost the Mac mini mid-run - not re-running on the laptop (could run twice); retry"

# The mini-side loader (perl -e): read our own script frame ("<len>\n" + runner source) with
# sysread - never buffered reads, the runner sysreads the header that follows - then eval it.
# The runner always exits itself; reaching the end means it failed to compile.
LOADER = ('my($l,$c,$s)=("");while($l!~/\\n\\z/){sysread(STDIN,$c,1) or exit 65;$l.=$c;'
          'exit 65 if length($l)>12}$l=~/^(\\d+)\\n\\z/ or exit 65;my $n=$1;$s="";'
          'while(length($s)<$n){sysread(STDIN,$s,$n-length($s),length($s)) or exit 65}'
          '$0="rrun-runner";eval "#line 1 rr_runner.pl\\n".$s;'
          'print STDERR "rrun-runner: $@";exit 70')


class RunError(Exception):
    """Something failed before the remote command could start (=> local fallback)."""


class PushRefused(RunError):
    """The mini answered but refused this repo's history (shallow clone, fsck) => local, with why."""


# ---------------------------------------------------------------------------- small helpers

def note(msg):
    sys.stderr.write("rrun: " + msg + "\n")
    sys.stderr.flush()


def git_out(args, cwd, check=True):
    """-> stdout bytes of `git <args>` in cwd (RunError when check and git fails)."""
    p = subprocess.run(["git"] + list(args), cwd=cwd, capture_output=True)
    if check and p.returncode != 0:
        raise RunError("git %s: %s" % (args[0], p.stderr.decode("utf-8", "replace").strip()[-300:]))
    return p.stdout


def zsplit(raw):
    """NUL-separated git output -> list of str paths (paths that are not UTF-8 are dropped: they
    cannot travel in the JSON header)."""
    out = []
    for b in raw.split(b"\0"):
        if not b:
            continue
        try:
            out.append(b.decode("utf-8"))
        except UnicodeDecodeError:
            note("skipping a path that is not UTF-8: %r" % b)
    return out


def short_hash(s, n):
    return hashlib.sha256(s.encode("utf-8", "surrogateescape")).hexdigest()[:n]


def sane_rel(p):
    """A repo-relative path the runner will accept: no absolute, '..', '.git' component, NUL."""
    parts = p.split("/")
    return bool(p) and not p.startswith("/") and "\0" not in p \
        and not any(c in ("..", ".git") for c in parts)


def ssh_opts():
    """Options for every rrun ssh (runner session AND git, via GIT_SSH_COMMAND): our own rr-%C
    master, never rdocker's fwd.sock (a bulk push would starve its liveness checks)."""
    return ["-o", "ControlPath=~/.ssh/rr-%C", "-o", "ControlMaster=auto", "-o", "ControlPersist=30m",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3"]


def rr_root(cfg):
    root = str(cfg.get("rr_root") or "rr").strip("/")
    if not root or not all(c and not c.startswith(".") and not NAME_RE.search(c) for c in root.split("/")):
        raise RunError("bad rr_root %r in config" % root)
    return root


# ---------------------------------------------------------------------------- worktree

def resolve_worktree(cwd):
    """-> dict(top, relcwd, slug, wt12, sha). RunError outside a git worktree / without a commit."""
    raw = git_out(["rev-parse", "--show-toplevel", "--git-common-dir", "--show-prefix", "HEAD"], cwd)
    lines = raw.decode("utf-8", "surrogateescape").split("\n")
    if len(lines) < 4 or not re.match(r"^[0-9a-f]{40}$", lines[3]):
        raise RunError("no commit at HEAD yet")
    top, common, prefix, sha = lines[0], lines[1], lines[2], lines[3]
    common = os.path.realpath(os.path.join(cwd, common))
    # repo name: the dir holding .git (or a bare "<name>.git"), + a hash of the common dir so two
    # clones with the same name never share a bare repo on the mini
    base = os.path.basename(common)
    name = os.path.basename(os.path.dirname(common)) if base == ".git" else re.sub(r"\.git$", "", base)
    name = NAME_RE.sub("-", name).lstrip(".")[:40] or "repo"
    return {"top": top, "relcwd": prefix.rstrip("/"), "sha": sha,
            "slug": "%s.%s" % (name, short_hash(common, 8)),
            "wt12": short_hash(os.path.realpath(top), 12)}


def wt_lock_path(wt12):
    return os.path.join(rd_common.STATE_DIR, "rrun-%s.lock" % wt12)


def take_wt_lock(wt12):
    """flock rrun-<wt12>.lock for the whole run. The fd is not inheritable, so the ssh master that
    git's ssh may fork (ControlPersist) never holds it; run_local makes it inheritable for exec."""
    import fcntl
    rd_common.ensure_dirs()
    fd = os.open(wt_lock_path(wt12), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        note("another rrun from this worktree is running; waiting for it to finish...")
        fcntl.flock(fd, fcntl.LOCK_EX)
    HELD_LOCKS.append(fd)
    return fd


# ---------------------------------------------------------------------------- push

def push(cfg, wt):
    """Force-push HEAD to refs/rrun/<wt12> of the per-repo bare repo on the mini. The remote
    receive-pack command first creates the bare repo if it is missing (same round trip), and runs
    with hooks disabled, so a tampered bare-repo config cannot run code. RunError on failure."""
    root = rr_root(cfg)
    bare = "~/%s/git/%s.git" % (root, wt["slug"])
    recv = ("umask 077; mkdir -p ~/{root}/git && {{ [ -d {bare} ] || {{ git init --bare -q {bare} && "
            "git -C {bare} config receive.fsckObjects true && "
            "git -C {bare} config core.hooksPath /dev/null; }}; }} && "
            "git -c core.hooksPath=/dev/null receive-pack").format(root=root, bare=bare)
    url = os.environ.get("RRUN_GIT_URL") or "ssh://%s/%s" % (cfg["host"], bare)
    env = dict(os.environ, GIT_SSH_COMMAND=" ".join(shlex.quote(a) for a in ["ssh"] + ssh_opts()),
               GIT_TERMINAL_PROMPT="0")
    p = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "push.recurseSubmodules=no",
                        "push", "--no-verify", "-q", "-f", "--receive-pack=" + recv, url,
                        "%s:refs/rrun/%s" % (wt["sha"], wt["wt12"])],
                       cwd=wt["top"], env=env, stdin=subprocess.DEVNULL, capture_output=True)
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip()
        why = push_refused_why(wt["top"], err)
        if why:
            raise PushRefused(why)
        raise RunError("git push to the mini failed: %s" % err.replace("\n", " | ")[-300:])


def push_refused_why(top, err):
    """-> a plain reason when the mini is fine but this repo cannot be pushed, else None."""
    shallow = git_out(["rev-parse", "--is-shallow-repository"], top, check=False).strip() == b"true"
    if shallow or "shallow update not allowed" in err:
        return ("this clone is shallow (a partial history cannot be pushed to the Mac mini; "
                "`git fetch --unshallow` fixes it)")
    low = err.lower()
    if "fsck" in low or "unpacker error" in low or "abnormal exit" in low:
        return ("the Mac mini's git rejected objects in this repo's history (git fsck "
                "checks on the mini)")
    return None


# ---------------------------------------------------------------------------- overlay

def env_file_candidates(top, allow, dirs):
    """Allowlisted env files (basename globs) directly in `dirs` only - the repo root, the
    command's cwd and the dependency dirs the runner installs - never at any other depth. Files
    tracked by git are skipped: they are already in the checkout."""
    out = []
    for d in dirs:
        try:
            names = sorted(os.listdir(os.path.join(top, d) if d else top))
        except OSError:
            continue
        out += [(d + "/" + n if d else n) for n in names if any(fnmatch.fnmatchcase(n, g) for g in allow)]
    out = [e for e in dict.fromkeys(out) if sane_rel(e)]
    if not out:
        return []
    tracked = set(zsplit(git_out(["--literal-pathspecs", "ls-files", "-z", "--"] + out, top)))
    return sorted(e for e in out if e not in tracked)


def inside(path, rtop):
    return path == rtop or path.startswith(rtop + os.sep)


def regular_file(path, follow):
    """-> os.stat_result for a regular file (following a symlink only when `follow`), else None."""
    try:
        st = os.stat(path) if follow else os.lstat(path)
    except OSError:
        return None
    import stat as st_mod
    return st if st_mod.S_ISREG(st.st_mode) else None


def build_overlay(cfg, top, env_dirs=("",)):
    """-> (tar bytes, files, env_files, deleted). files = tracked files changed vs HEAD that exist
    + untracked not-ignored files (regular files only; symlinks are never followed). env files =
    rr_env_allow matches in env_dirs (see env_file_candidates); one whose realpath is not a regular
    file inside the worktree (e.g. a symlink to ~/secrets/.env) is skipped with a notice; 0600."""
    changed = zsplit(git_out(["diff", "-z", "--name-only", "--no-renames", "HEAD", "--"], top))
    untracked = zsplit(git_out(["ls-files", "-z", "-o", "--exclude-standard"], top))
    rtop = os.path.realpath(top)
    envs = []
    for e in env_file_candidates(top, cfg.get("rr_env_allow") or [], env_dirs):
        if not inside(os.path.realpath(os.path.join(top, e)), rtop):
            note("not copying %s: it resolves outside this worktree (a symlink?)" % e)
            continue
        envs.append(e)
    deleted, files = [], []
    for rel in changed:
        if not sane_rel(rel):
            continue
        if os.path.lexists(os.path.join(top, rel)):
            files.append(rel)
        else:
            deleted.append(rel)
    files += [u for u in untracked if sane_rel(u) and not u.endswith("/")]
    env_set = set(envs)
    files = [f for f in dict.fromkeys(files) if f not in env_set]
    buf = io.BytesIO()
    shipped, shipped_env = [], []
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for rel, is_env in [(f, False) for f in files] + [(e, True) for e in envs]:
            path = os.path.join(top, rel)
            st = regular_file(path, follow=is_env)
            if st is None:
                continue
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError as e:
                note("skipping %s: %s" % (rel, e))
                continue
            ti = tarfile.TarInfo(rel)
            ti.size, ti.mtime = len(data), int(st.st_mtime)
            ti.mode = 0o600 if is_env else (0o700 if st.st_mode & 0o100 else 0o600)
            t.addfile(ti, io.BytesIO(data))
            (shipped_env if is_env else shipped).append(rel)
    return (buf.getvalue() if shipped or shipped_env else b""), shipped, shipped_env, deleted


# ---------------------------------------------------------------------------- deps dirs

def has_lock(d):
    return any(os.path.isfile(os.path.join(d, n)) for n in ("package-lock.json", "npm-shrinkwrap.json"))


def deps_dirs(top, relcwd, argv):
    """Lockfile dirs the runner keeps installed: the nearest lockfile dir at or above relcwd and any
    `--prefix X` in argv (relative to cwd). Not the repo root by default: a monorepo root's lockfile
    can be out of sync (npm ci refuses) and the command never loads its packages (2026-10-15)."""
    out = []
    parts = relcwd.split("/") if relcwd else []
    for i in range(len(parts), -1, -1):
        rel = "/".join(parts[:i])
        if has_lock(os.path.join(top, rel)):
            out.append(rel)
            break
    cwd = os.path.join(top, relcwd)
    rtop = os.path.realpath(top)
    for i, a in enumerate(argv):
        val = argv[i + 1] if a == "--prefix" and i + 1 < len(argv) else \
            a[len("--prefix="):] if a.startswith("--prefix=") else None
        if not val:
            continue
        d = os.path.realpath(os.path.join(cwd, val))
        if d == rtop or d.startswith(rtop + os.sep):
            out.append(os.path.relpath(d, rtop).replace(os.sep, "/") if d != rtop else "")
    return list(dict.fromkeys(out))


# ---------------------------------------------------------------------------- remote session

class StatusFilter:
    """Remote stderr -> our stderr, minus our own "<nonce> STATUS" lines. The tag is recognised
    anywhere, also glued to the end of a stderr line that had no newline (the nonce is 128 secret
    bits the tested code never sees, so it cannot be forged or hit by chance). Only a tail that
    could still be the start of the tag is held back, so progress output streams."""

    def __init__(self, nonce, out, on_status):
        self.tag = (nonce + " ").encode()
        self.out, self.on_status = out, on_status
        self.buf, self.mid_line = b"", False

    def _emit(self, data):
        if data:
            self.out.write(data)
            self.out.flush()
            self.mid_line = not data.endswith(b"\n")

    def feed(self, data):
        self.buf += data
        while self.buf:
            i = self.buf.find(self.tag)
            if i < 0:
                k = min(len(self.tag) - 1, len(self.buf))
                while k and not self.tag.startswith(self.buf[-k:]):
                    k -= 1
                self._emit(self.buf[:len(self.buf) - k])
                self.buf = self.buf[len(self.buf) - k:]
                return
            nl = self.buf.find(b"\n", i)
            self._emit(self.buf[:i])
            if nl < 0:
                self.buf = self.buf[i:]                # wait for the rest of the status line
                return
            if self.mid_line:
                self._emit(b"\n")                     # end the line the status was glued to
            line = self.buf[i + len(self.tag):nl].decode("utf-8", "replace")
            self.buf = self.buf[nl + 1:]
            self.on_status(line)

    def close(self):
        self._emit(self.buf)
        self.buf = b""


def remote_command(cfg):
    root = rr_root(cfg)
    env = "" if root == "rr" else "RR_ROOT=\"$HOME\"/%s " % root
    return "%sexec /usr/bin/perl -e %s" % (env, shlex.quote(LOADER))


class Session:
    """One `ssh -T host perl -e <loader>` run: frames + heartbeat on stdin (a writer thread owns
    stdin; signal handlers only set flags), stderr filtered for status lines.

    Exactly-once handshake: the runner prints "<nonce> READY" when everything but the command is
    done and waits; the writer answers "GO\n" (unless Ctrl-C was pressed) and only then does the
    runner spawn the command. `go_sent` turns True BEFORE that write is attempted, so after any
    loss it is True whenever the command might have started: False => it certainly did not run
    (safe to run it on the laptop), True => never run it again (exit 75)."""

    def __init__(self, cfg, frames, nonce, timing):
        self.cfg, self.frames, self.nonce, self.timing = cfg, frames, nonce, timing
        self.started = None                  # monotonic time "<nonce> STARTED" arrived
        self.ready = False                   # "<nonce> READY" arrived: the runner waits for GO
        self.go_sent = False
        self.go_lock = threading.Lock()      # orders go_sent against `done` (the ssh exited)
        self.ints = 0
        self.wake = threading.Event()
        self.done = threading.Event()
        self.said_wait = False

    def on_status(self, line):
        word, _, rest = line.partition(" ")
        if word == "READY":
            self.timing.mark("remote prepare (checkout, overlay, deps, slot)")
            self.ready = True
            self.wake.set()
        elif word == "STARTED":
            self.started = time.monotonic()
        elif word == "WAIT":
            if not self.said_wait:
                kv = dict(x.split("=", 1) for x in rest.split() if "=" in x)
                note("waiting for a Mac mini slot (held by %s for %ss; gives up after %s min)..."
                     % (kv.get("holder", "?"), kv.get("age", "?"), self.cfg.get("rr_wait_min")))
                self.said_wait = True
        elif word == "BUSY":
            note("the Mac mini slot stayed busy for %s min; giving up (exit 73)"
                 % self.cfg.get("rr_wait_min"))
        elif word == "KEPT":
            note("the run failed; its containers stay on the Mac mini for inspection: %s "
                 "(docker ps / docker logs reach them; the janitor reaps them after 3 h idle)" % rest)

    def on_signal(self, signum, _frame):
        self.ints += 1 if signum != signal.SIGHUP else 2
        if self.ints >= 3 and self.proc.poll() is None:
            self.proc.kill()
        self.wake.set()

    def claim_go(self):
        """-> True when GO may be written now (and records that it was), False otherwise."""
        with self.go_lock:
            if self.done.is_set() or not self.ready or self.go_sent or self.ints:
                return False
            self.go_sent = True              # from here on, any loss is ambiguous => 75
            return True

    def writer(self):
        """Owns ssh's stdin: the frames, then a heartbeat every HEARTBEAT_S, "GO\n" once the
        runner is READY, "INT\n" after the first Ctrl-C, close (= the runner kills the command
        group, or gives up before starting it) after the second."""
        w = self.proc.stdin
        sent_int = 0
        try:
            for fr in self.frames:
                w.write(fr)
            w.flush()
            while not self.done.is_set():
                self.wake.clear()            # before reading the flags: a later set() is never lost
                if self.ints >= 2:
                    break
                if self.ints > sent_int:
                    w.write(b"INT\n")
                    sent_int = self.ints
                elif self.claim_go():
                    w.write(b"GO\n")
                else:
                    w.write(b".")
                w.flush()
                self.wake.wait(HEARTBEAT_S)
        except (BrokenPipeError, OSError, ValueError):
            pass
        finally:
            try:
                w.close()
            except (BrokenPipeError, OSError):
                pass

    def relay(self):
        filt = StatusFilter(self.nonce, getattr(sys.stderr, "buffer", sys.stderr), self.on_status)
        fd = self.proc.stderr.fileno()
        while True:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            filt.feed(data)
        filt.close()

    def run(self):
        cmd = ["ssh", "-T"] + ssh_opts() + [self.cfg["host"], remote_command(self.cfg)]
        sys.stdout.flush()
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=True)
        old = {s: signal.signal(s, self.on_signal) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        tw = threading.Thread(target=self.writer, daemon=True)
        tr = threading.Thread(target=self.relay, daemon=True)
        tw.start()
        tr.start()
        try:
            rc = self.proc.wait()
        finally:
            with self.go_lock:
                self.done.set()              # no GO after this point
            self.wake.set()
            for s, h in old.items():
                signal.signal(s, h)
        tr.join(5)       # a persisting ssh master could hold the pipe; never hang on it
        tw.join(1)
        return rc


# ---------------------------------------------------------------------------- timing / state

class Timing:
    def __init__(self, on):
        self.on, self.t0, self.last, self.parts = on, time.monotonic(), time.monotonic(), []

    def mark(self, label):
        now = time.monotonic()
        self.parts.append("%s %.2fs" % (label, now - self.last))
        self.last = now

    def report(self):
        if self.on:
            note("timing: " + ", ".join(self.parts) + ", total %.2fs" % (time.monotonic() - self.t0))


def short_argv(argv):
    s = " ".join(shlex.quote(a) for a in argv)
    return s if len(s) <= 120 else s[:117] + "..."


def record(target, argv, rc, secs, wt12=None, start=False):
    """route.log line + rrun.json (last result, runs in flight) for `rdocker status`."""
    pid = str(os.getpid())

    def apply(cur):
        cur = cur if isinstance(cur, dict) else {}
        active = {k: v for k, v in (cur.get("active") or {}).items() if k != pid and alive_pid(k)}
        if start:
            active[pid] = {"ts": time.time(), "argv": short_argv(argv), "wt12": wt12}
        else:
            cur["last"] = {"ts": time.time(), "rc": rc, "target": target, "secs": round(secs, 1),
                           "argv": short_argv(argv)}
        cur["active"] = active
        return cur
    try:
        rd_common.update_json(rd_common.RRUN_STATE, apply, default={})
    except OSError:
        pass
    if not start:
        rd_common.log("%-5s %-8s %s rc=%s %.1fs | %s" % (target, "rrun", short_argv(argv), rc, secs,
                                                       os.getcwd()), rd_common.ROUTE_LOG)


def alive_pid(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def status_row(now):
    """-> (ok, label, detail) for `rdocker status` (from rrun.json only; no ssh)."""
    st = rd_common.load_json(rd_common.RRUN_STATE, {})
    st = st if isinstance(st, dict) else {}
    last = st.get("last") if isinstance(st.get("last"), dict) else None
    d = "never run" if not last else "last run %s rc=%s (%s, %ss: %s)" % (
        _ago(last.get("ts", now), now), last.get("rc"), last.get("target"), last.get("secs"),
        last.get("argv"))
    active = [v for k, v in (st.get("active") or {}).items() if isinstance(v, dict) and alive_pid(k)]
    d += "; mini slot " + ("busy (%s)" % ", ".join("%s, %s" % (a.get("argv"), _ago(a.get("ts", now), now))
                                                   for a in active) if active
                           else "free as far as this laptop knows")
    return True, "rrun", d


def _ago(ts, now):
    d = max(0, int(now - ts)) if isinstance(ts, (int, float)) else 0
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if d >= size:
            return "%d%s ago" % (d // size, unit)
    return "%ds ago" % d


# ---------------------------------------------------------------------------- entry

def run_local(argv, env_pairs, why=None):
    """exec the command on the laptop (RDOCKER_MODE=local: its containers stay on the laptop too)."""
    if why:
        note("%s - running on the laptop instead (RDOCKER_MODE=local)" % why)
    env = dict(os.environ, RDOCKER_MODE="local", RRUN="0")   # RRUN=0: the npm shim must not re-route
    env.update(env_pairs)
    sys.stdout.flush()
    sys.stderr.flush()
    for fd in HELD_LOCKS:          # the local run keeps holding the worktree lock
        os.set_inheritable(fd, True)
    try:
        os.execvpe(argv[0], argv, env)
    except OSError as e:
        note("%s: %s" % (argv[0], e))
        return 127


def fallback(argv, env_pairs, why, t0):
    if os.environ.get("RRUN_STRICT") == "1":
        note("%s (RRUN_STRICT=1: not running on the laptop)" % why)
        record("mini", argv, EXIT_LOST, time.monotonic() - t0)
        return EXIT_LOST
    record("local", argv, "exec", time.monotonic() - t0)
    return run_local(argv, env_pairs, why)


def parse_env(pairs, environ=None):
    """`-e NAME=VALUE` sets a value; `-e NAME` forwards NAME's value from our own environment (so
    `FOO=secret rrun -e FOO cmd` keeps the value out of argv / ps). An unset bare NAME is skipped
    with a notice (docker run -e semantics)."""
    environ = os.environ if environ is None else environ
    out = {}
    for p in pairs or ():
        k, sep, v = p.partition("=")
        if not ENV_NAME_RE.match(k):
            raise SystemExit("rrun: -e wants NAME or NAME=VALUE, got %r" % p)
        if sep:
            out[k] = v
        elif k in environ:
            out[k] = environ[k]
        else:
            note("-e %s: not set here, not passed" % k)
    return out


# Exit codes the runner uses when the command was never started (GO not sent), with what they mean.
INFRA_EXIT = {
    65: "the Mac mini runner refused the request (bad input or an unsafe path; see above)",
    69: "the repo is missing on the Mac mini (the push should have created it); retry",
    70: "the Mac mini runner failed (see above)",
    78: "installing dependencies on the Mac mini failed (npm ci / prisma generate, see above)",
}


def rrun(argv, env_args=()):
    """`rrun [-e NAME[=VALUE]]... [--] <cmd...>` -> exit code (the remote command's, or 75/73/...)."""
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        sys.stderr.write("usage: rrun [-e NAME[=VALUE]]... [--] <command> [args...]\n")
        return 2
    env_pairs = parse_env(env_args)
    t0 = time.monotonic()
    if os.environ.get("RRUN_REMOTE") or os.environ.get("RRUN") == "0":
        return run_local(argv, env_pairs)        # already on the mini / opted out: plain run
    cfg = rd_common.load_cfg()
    timing = Timing(os.environ.get("RRUN_TIMING") == "1")
    try:
        wt = resolve_worktree(os.getcwd())
    except (RunError, OSError) as e:
        return fallback(argv, env_pairs, "cannot use the Mac mini here (%s)" % str(e).strip(), t0)
    timing.mark("resolve")
    take_wt_lock(wt["wt12"])     # fd stays open (and locked) until we exit or exec
    timing.mark("worktree lock")
    try:
        push(cfg, wt)
    except PushRefused as e:
        return fallback(argv, env_pairs, "cannot send this repo to the Mac mini: %s" % e, t0)
    except RunError as e:
        return fallback(argv, env_pairs, "Mac mini unreachable (%s)" % e, t0)
    timing.mark("push")
    deps = deps_dirs(wt["top"], wt["relcwd"], argv)
    env_dirs = list(dict.fromkeys([""] + ([wt["relcwd"]] if wt["relcwd"] else []) + deps))
    try:
        tar, files, envs, deleted = build_overlay(cfg, wt["top"], env_dirs)
    except RunError as e:
        return fallback(argv, env_pairs, "could not list the worktree (%s)" % e, t0)
    if len(tar) > OVERLAY_WARN_BYTES:
        note("sending %.1f MB of uncommitted/untracked files" % (len(tar) / 1048576.0))
    timing.mark("overlay (%d files, %d env, %d deleted, %d bytes)" % (len(files), len(envs),
                                                                     len(deleted), len(tar)))
    env = {k: v for k, v in os.environ.items()
           if any(fnmatch.fnmatchcase(k, g) for g in cfg.get("rr_env_pass") or [])}
    env.update(env_pairs)
    nonce = secrets.token_hex(16)
    header = {"nonce": nonce, "repo_slug": wt["slug"], "wt12": wt["wt12"], "sha": wt["sha"],
              "relcwd": wt["relcwd"], "argv": argv, "env": env, "deleted": deleted,
              "tar_len": len(tar), "env_files": envs,
              "stamps": {"dirs": deps, "npm_args": []},
              "slots": cfg.get("rr_slots", 1), "wait_min": cfg.get("rr_wait_min", 30),
              "hb_timeout": cfg.get("rr_hb_timeout", 60), "keep_containers_on_fail": True}
    with open(rd_common.RUNNER_SRC, "rb") as f:
        script = f.read()
    hjs = json.dumps(header).encode("utf-8")
    frames = [b"%d\n" % len(script), script, b"%d\n" % len(hjs), hjs, tar]
    record("mini", argv, None, 0, wt12=wt["wt12"], start=True)
    sess = Session(cfg, frames, nonce, timing)
    rc = sess.run()
    secs = time.monotonic() - t0
    if not sess.go_sent:
        # GO was never written, so the runner never started the command: running it here is
        # safe when the connection dropped; any other rc is the runner's own (73, 78, ...).
        record("mini", argv, rc, secs)     # clears the in-flight entry before a local exec
        timing.report()
        if rc == 255:
            return fallback(argv, env_pairs, "lost the Mac mini before the command started", t0)
        if rc in INFRA_EXIT:
            note("%s - exit %d; the command did not run" % (INFRA_EXIT[rc], rc))
        return rc
    timing.mark("command")
    if rc == 255:
        sys.stderr.write(LOST_MSG + "\n")
        rc = EXIT_LOST
    record("mini", argv, rc, secs)
    timing.report()
    return rc
