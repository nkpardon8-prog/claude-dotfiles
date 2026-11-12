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
  6 relay output; "<nonce> STATUS" lines on stderr are ours (WAIT/BUSY/UNAVAIL/READY/STARTED/KEPT);
    on READY we write "GO\\n" and only then does the runner start the command
  7 rc = ssh's exit status; GO never written => the command never ran: 255 => local fallback,
    other rc = the runner's (73 busy, 78 deps, ...); GO written => 255 = the link was lost: the
    worker runs the command on detached (header run_id, a uuid4; rr_detach_hb_s 180 without us), so
    reattach() reconnects (fresh ssh, no shared master; rr_reattach_tries in rr_reattach_window_s),
    resumes the spooled output at the bytes we have and returns the real rc; NORUN there = it never
    started (a loss before the start). Every reconnect failed => exit 75 (never run twice).
Eligibility (rd_pool.eligibility, fleet.json classes / max_cost_s / cold_ok): a worker that may not
take the job is never tried; none may => exit 75 at once, naming each worker's reason.
Pool (rd_pool): with 2+ enabled fleet workers, each job is placed on the best worker right now
and the hosts are tried in that order: a worker lost before GO, or one that had no free slot after
all (73 from a short race wait), moves the job to the next one. After GO a lost worker means exit 75
- except for jobs that are safe to repeat (tsc/typecheck, lint, vitest/jest, builds; never DB
tests), which run once more on the next worker. In a pool, heavy and DB jobs never fall back to
this machine (exit 75 instead); light jobs (lint, check scripts) run here when every worker stayed
busy for rr_local_after_s. No fleet / one worker: one host, exactly as before.
Shards (run_shards): a `vitest run` rd_pool.shardable() accepts, with 2+ free workers, runs as
vitest --shard=i/n on several workers at once (threads; signals forwarded from the main thread to
every LIVE session), each with its own failover list, output prefixed "[shard i/n host]", rc = the
highest, a merged summary at the end; RRUN_SHARD=0 off, =n forced. Hedge (default off, RRUN_HEDGE=1):
a tsc/lint/vitest run past 2x its expected time gets one duplicate on a free worker with a 3x better
eta; the first to finish wins, the other is stopped. A second concurrent run of ours on one worker
uses its own lane mirror (Lane), so runs never share a checkout.
Builds (`npm run build` in a package dir mapped by rr_outputs) copy their outputs back: after a
successful run a second ssh streams `tar` of the outputs from the worker's mirror, extracted into
the worktree (staged, then renamed into place) while the worktree lock is still held.
Hangs / waits (2026-11-11): the runner relays the command's output through its own pipes, so when the
main process exits the leftovers get rr_exit_grace_s, then the group is TERMed / KILLed and the run
ends with the main's rc. A hard cap per job class (rr_timeout_min; RRUN_TIMEOUT=<min|0>) ends a run
with exit 124; silence only prints "no output for N min" (rr_silent_min; RRUN_SILENT_MIN). A slot
wait on one worker lasts rr_slot_wait_s, then host_loop re-plans (rr_wait_min in all -> 73); the
worktree lock waits at most the job's cap (-> 72). Slot / lock waits print a line every
rr_status_every_s. Every job carries owner_info() (session id / parent pid, /line caption, host):
`rrun --jobs` / `--mine` list them from every worker's slots/<i>.own.
Config: rr_* keys in rd_common.DEFAULTS. Env: RRUN_STRICT=1, RRUN_TIMING=1, RRUN=0 (run locally),
RRUN_TIMEOUT=<minutes|0>, RRUN_SILENT_MIN=<minutes|0>,
RRUN_GIT_URL (tests only: push URL override). Flags (the `rrun` wrapper turns them into env):
--where (RRUN_WHERE=1: print the placement, run nothing), --bench (RRUN_BENCH=1), --host NAME
(RRUN_HOST: only that worker), --outputs a,b (RRUN_OUTPUTS: build outputs, relative to the cwd).
Cache (rd_cache): a one-shot tsc / eslint / vitest / jest run or a known test / typecheck / lint npm
script whose shipped code + command match a recent run replays that run's output and exit code
(passes 24 h, failures 20 min); RRUN_CACHE=0 always runs (and saves the fresh result). Looked up
under the worktree lock, so a second identical run waiting on the first gets its result.
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
import socket
import subprocess
import sys
import tarfile
import threading
import time
import uuid

import rd_cache
import rd_common
import rd_pool

HEARTBEAT_S = 15
# rr ssh keepalives (all rrun ssh share one rr-%C master, so these are the master's): a worker that
# vanishes (lid closed, Wi-Fi gone) is noticed after ~15-20 s instead of ~45. sshd answers them from
# its own process, so a worker busy at 100% CPU still answers; a relayed (DERP) link adds ~0.3 s.
ALIVE_INTERVAL_S, ALIVE_COUNT = 5, 3
CONNECT_TIMEOUT_S = 6          # a cold master over a DERP relay connects in ~1.5-2.5 s
OVERLAY_WARN_BYTES = 5 * 1024 * 1024
EXIT_LOST = 75                 # EX_TEMPFAIL: lost the mini mid-run / strict mode and the mini is out
PUSH_TIMEOUT_S = 300            # rr_push_timeout_s: a git push that hangs longer = that worker is out
EXIT_WT_BUSY = 72              # another rrun from this worktree held its lock past our wait
EXIT_TIMEOUT = 124             # like timeout(1): the command ran past its wall-clock cap and was killed
# the runner's own cap is what ends a run; this side only steps in (kills ssh, exit 124) when the
# worker has said nothing about it this long after the cap, e.g. a wedged runner
TIMEOUT_MARGIN_S = 90
# the runner prints "<nonce> EXIT <rc>" only after the command's leftovers are gone (rr_exit_grace_s,
# then TERM/KILL of its group); if ssh is still open this long after that, we stop waiting for it
EXIT_BACKSTOP_S = 45
NAME_RE = re.compile(r"[^A-Za-z0-9._-]")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
HELD_LOCKS = []                # worktree lock fds: made inheritable only for a local-fallback exec
LIVE, LIVE_LOCK = set(), threading.Lock()   # running Sessions (shard mode forwards signals to them)
STOP_SIG = [0]                 # shard mode: the first INT/TERM/HUP (later sessions start stopped)
ABORT_KILL_S = 15              # an aborted session's ssh is killed if still there after this
LOST_MSG ="rrun: lost the Mac mini mid-run - not re-running on the laptop (could run twice); retry"

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


def ssh_opts(mux=True):
    """Options for every rrun ssh (runner session AND git, via GIT_SSH_COMMAND): our own rr-%C
    master, never rdocker's fwd.sock (a bulk push would starve its liveness checks). mux=False (a
    reattach after a lost link): a connection of its own - the shared master is what just died, and
    it takes every session on it down together."""
    share = ["-o", "ControlPath=~/.ssh/rr-%C", "-o", "ControlMaster=auto", "-o", "ControlPersist=30m"] if mux \
        else ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
    return share + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=%d" % CONNECT_TIMEOUT_S,
            "-o", "ServerAliveInterval=%d" % ALIVE_INTERVAL_S, "-o", "ServerAliveCountMax=%d" % ALIVE_COUNT]


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


class WorktreeBusy(Exception):
    """Another rrun from this worktree kept the worktree lock past our wait (exit EXIT_WT_BUSY)."""


def take_wt_lock(wt12, wait_s=None, cfg=None):
    """flock rrun-<wt12>.lock for the whole run. The fd is not inheritable, so the ssh master that
    git's ssh may fork (ControlPersist) never holds it; run_local makes it inheritable for exec.
    Waits at most wait_s (None = forever), saying who holds it every rr_status_every_s; then raises
    WorktreeBusy. The lock file is never unlinked (a waiter would lock a deleted inode)."""
    import fcntl
    rd_common.ensure_dirs()
    fd = os.open(wt_lock_path(wt12), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        note("another rrun from this worktree is running%s; waiting for it to finish%s..."
             % (wt_holder(wt12), " (at most %s)" % fmt_wait(wait_s) if wait_s else ""))
        every = float((cfg or rd_common.load_cfg()).get("rr_status_every_s", 60) or 60)
        t0 = last = time.monotonic()
        while True:
            time.sleep(0.25)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                pass
            if wait_s is not None and time.monotonic() - t0 >= wait_s:
                os.close(fd)
                raise WorktreeBusy("another rrun from this worktree still holds its lock after %s%s"
                                   % (fmt_wait(wait_s), wt_holder(wt12)))
            if time.monotonic() - last >= every:
                last = time.monotonic()
                note("still waiting for the other rrun from this worktree (%s so far)%s"
                     % (fmt_wait(last - t0), wt_holder(wt12)))
    HELD_LOCKS.append(fd)
    return fd


# ---------------------------------------------------------------------------- push

def push(cfg, wt):
    """Force-push HEAD to refs/rrun/<wt12> of the per-repo bare repo on the mini. The remote
    receive-pack command first creates the bare repo if it is missing (same round trip), and runs
    with hooks disabled, so a tampered bare-repo config cannot run code. RunError on failure.
    -> the base-branch refspecs pushed ("+<sha>:<ref>", part of the result cache's content id)."""
    root = rr_root(cfg)
    bare = "~/%s/git/%s.git" % (root, wt["slug"])
    recv = ("umask 077; mkdir -p ~/{root}/git && {{ [ -d {bare} ] || {{ git init --bare -q {bare} && "
            "git -C {bare} config receive.fsckObjects true && "
            "git -C {bare} config core.hooksPath /dev/null; }}; }} && "
            "git -c core.hooksPath=/dev/null receive-pack").format(root=root, bare=bare)
    url = os.environ.get("RRUN_GIT_URL") or "ssh://%s/%s" % (cfg["host"], bare)
    env = dict(os.environ, GIT_SSH_COMMAND=" ".join(shlex.quote(a) for a in ["ssh"] + ssh_opts()),
               GIT_TERMINAL_PROMPT="0")
    base = base_refspecs(cfg, wt["top"])
    limit = float(cfg.get("rr_push_timeout_s", PUSH_TIMEOUT_S) or PUSH_TIMEOUT_S)
    try:
        p = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "push.recurseSubmodules=no",
                            "push", "--no-verify", "-q", "-f", "--receive-pack=" + recv, url,
                            "%s:refs/rrun/%s" % (wt["sha"], wt["wt12"])] + base,
                           cwd=wt["top"], env=env, stdin=subprocess.DEVNULL, capture_output=True,
                           timeout=limit)
    except subprocess.TimeoutExpired:
        # nothing ran there yet: the job moves on to the next worker like any unreachable one
        raise RunError("git push did not finish in %d s" % limit)
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip()
        why = push_refused_why(wt["top"], err)
        if why:
            raise PushRefused(why)
        raise RunError("git push to the mini failed: %s" % err.replace("\n", " | ")[-300:])
    return base


def base_refspecs(cfg, top):
    """Also mirror the shared base branches (origin/dev, origin/main, ...) that exist locally, so
    `git diff origin/dev...HEAD` / merge-base guards work on the mini too (2026-10-15: a guard tier
    failed there with "could not resolve a diff base"). After the first push they cost ~nothing.
    Each is pushed as the commit it resolves to now ("+<sha>:<ref>"), so what reaches the worker is
    exactly what the result cache keyed on."""
    out = []
    for name in cfg.get("rr_base_branches") or ():
        ref = "refs/remotes/origin/%s" % name
        if NAME_RE.search(name) is not None:
            continue
        sha = git_out(["rev-parse", "-q", "--verify", ref + "^{commit}"], top, check=False).strip()
        if re.match(rb"^[0-9a-f]{40}$", sha):
            out.append("+%s:%s" % (sha.decode(), ref))
    return out


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


def env_dirs_for(wt, deps):
    """Where env files are picked up for a run: the repo root, the cwd and the deps dirs."""
    return list(dict.fromkeys([""] + ([wt["relcwd"]] if wt["relcwd"] else []) + list(deps)))


def ship_env(cfg, env_pairs):
    """The env dict a runner header carries: rr_env_pass matches from our env, then -e pairs."""
    env = {k: v for k, v in os.environ.items()
           if any(fnmatch.fnmatchcase(k, g) for g in cfg.get("rr_env_pass") or [])}
    env.update(env_pairs)
    return env


def shipped_reader(wt, tar, deleted):
    """-> read(rel): a file's bytes exactly as the worker will have it (the overlay's copy, else
    the pushed commit's; None when deleted / absent)."""
    over = {n: d for n, _m, d in rd_cache.tar_members(tar)}
    gone = set(deleted)

    def read(rel):
        if rel in over:
            return over[rel]
        if rel in gone:
            return None
        p = subprocess.run(["git", "cat-file", "blob", "%s:%s" % (wt["sha"], rel)], cwd=wt["top"],
                           capture_output=True)
        return p.stdout if p.returncode == 0 else None
    return read


def cache_prepare(cfg, wt, argv, env_pairs, deps, job, outputs):
    """-> (rd_cache.Run, None) for a cacheable run (its key = what would ship + the command), else
    (None, why not). Builds the same overlay and env attempt() ships."""
    env = ship_env(cfg, env_pairs)
    why = rd_cache.why_not_static(argv, job, outputs, env)
    if why:
        return None, why
    try:
        base = base_refspecs(cfg, wt["top"])
        tar, _files, envs, deleted = build_overlay(cfg, wt["top"], env_dirs_for(wt, deps))
    except (RunError, OSError) as e:
        return None, "could not list the worktree (%s)" % e
    why = rd_cache.env_files_why(tar, envs) or \
        rd_cache.why_not_script(argv, wt["relcwd"], shipped_reader(wt, tar, deleted))
    if why:
        return None, why
    cid = rd_cache.content_id(wt["sha"], base, tar, envs, deleted, env, deps)
    return rd_cache.Run(rd_cache.key(cid, argv, wt["relcwd"], job["cls"]), cid), None


# ---------------------------------------------------------------------------- deps dirs

def has_lock(d):
    return any(os.path.isfile(os.path.join(d, n)) for n in ("package-lock.json", "npm-shrinkwrap.json"))


def deps_dirs(top, relcwd, argv):
    """Lockfile dirs the runner keeps installed: the nearest lockfile dir at or above relcwd and any
    `--prefix X` in argv (relative to cwd). Not the repo root by default: a monorepo root's lockfile
    can be out of sync (npm ci refuses) and the command never loads its packages (2026-10-15)."""
    out = []
    if not relcwd:
        # a repo-root command (`release:rehearse:migrations` -> a node script) can load a subproject's
        # packages without naming it: keep every first-level subdir that has a lockfile AND is
        # installed on the laptop (node_modules there = this checkout uses it) - dso-ui-ref, 2026-10-15
        try:
            subs = sorted(os.listdir(top))
        except OSError:
            subs = []
        for d in subs:
            p = os.path.join(top, d)
            if not d.startswith(".") and d != "node_modules" and not os.path.islink(p) \
                    and has_lock(p) and os.path.isdir(os.path.join(p, "node_modules")):
                out.append(d)
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


# ---------------------------------------------------------------------------- sinks / lanes

OUT_LOCK = threading.Lock()    # one writer at a time on our stdout/stderr (shards interleave lines)
TAIL_BYTES = 65536


class Sink:
    """A byte stream for one run's stdout or stderr when several share the terminal: whole lines go
    out with `prefix` ("[shard 2/5 hp] "), or are held (a hedge: printed only if it wins). Keeps
    the last TAIL_BYTES (the vitest summary is parsed from it)."""

    def __init__(self, stream, prefix="", hold=False):
        self.stream, self.prefix, self.hold = stream, prefix, hold
        self.buf, self.kept, self.tail = b"", [], b""

    def _out(self, data):
        if not self.prefix:
            with OUT_LOCK:
                self.stream.write(data)
                self.stream.flush()
            return
        self.buf += data
        lines = self.buf.split(b"\n")
        self.buf = lines.pop()
        if lines:
            pre = self.prefix.encode("utf-8", "replace")
            with OUT_LOCK:
                self.stream.write(b"".join(pre + ln + b"\n" for ln in lines))
                self.stream.flush()

    def write(self, data):
        self.tail = (self.tail + data)[-TAIL_BYTES:]
        if self.hold:
            self.kept.append(data)
        else:
            self._out(data)

    def flush(self):
        pass

    def close(self):
        """End a last line that had no newline."""
        if self.buf:
            self._out(b"\n")

    def release(self):
        """A held sink's output, now (the hedge won)."""
        self.hold = False
        data, self.kept = b"".join(self.kept), []
        if data:
            self._out(data)
        self.close()


def std_stream(name):
    s = getattr(sys, name)
    return getattr(s, "buffer", s)


class Lane:
    """Where one attempt's output goes and which worker mirror it uses. Lane 0 on a worker is the
    worktree's own mirror (<slug>-<wt12>); a second run of ours on the same worker at the same time
    (another shard, a hedge) gets lane 1, 2, ...: its own mirror <slug>-<sha(wt12:laneN)[:12]> (the
    shape the janitor reaps), packages cloned from the worker's store. out/err None = our own."""

    def __init__(self, out=None, err=None, wt12=None):
        self.out, self.err, self.wt12 = out, err, wt12
        self.session, self.cancelled = None, False
        self.tag = ""                    # message prefix of its session ("[shard 2/5 hp] ")
        self.lock = threading.Lock()

    def bind(self, sess):
        """attempt(): the session about to run -> False when the lane was cancelled first."""
        with self.lock:
            if self.cancelled:
                return False
            self.session = sess
            return True

    def cancel(self):
        """Never start a session on this lane; abort the one running. -> True when one was."""
        with self.lock:
            self.cancelled = True
            sess = self.session
        if sess is not None:
            sess.abort()
        return sess is not None


_LANES, _LANES_LOCK = {}, threading.Lock()
_HOST_LOCKS = {}


def take_lane(host_key):
    with _LANES_LOCK:
        used = _LANES.setdefault(host_key, set())
        n = next(k for k in range(len(used) + 1) if k not in used)
        used.add(n)
        return n


def drop_lane(host_key, n):
    with _LANES_LOCK:
        _LANES.get(host_key, set()).discard(n)


def host_lock(host_key):
    """One push at a time per worker (parallel pushes of the same refs would fail on ref locks)."""
    with _LANES_LOCK:
        return _HOST_LOCKS.setdefault(host_key, threading.Lock())


# ---------------------------------------------------------------------------- remote session

class StatusFilter:
    """Remote stderr -> our stderr, minus our own "<nonce> STATUS" lines. The tag is recognised
    anywhere, also glued to the end of a stderr line that had no newline (the nonce is 128 secret
    bits the tested code never sees, so it cannot be forged or hit by chance). Only a tail that
    could still be the start of the tag is held back, so progress output streams."""

    def __init__(self, nonce, out, on_status, on_data=None, on_bytes=None):
        self.tag = (nonce + " ").encode()
        self.out, self.on_status, self.on_data, self.on_bytes = out, on_status, on_data, on_bytes
        self.buf, self.mid_line = b"", False

    def _emit(self, data, own=True):
        """own: bytes the remote side sent (counted: a reattach resumes the spool after them);
        False for the newline we add to end a line a status was glued to."""
        if data:
            self.out.write(data)
            self.out.flush()
            self.mid_line = not data.endswith(b"\n")
            if own and self.on_bytes is not None:
                self.on_bytes(len(data))
            if self.on_data is not None:
                self.on_data()

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
                self._emit(b"\n", own=False)          # end the line the status was glued to
            line = self.buf[i + len(self.tag):nl].decode("utf-8", "replace")
            self.buf = self.buf[nl + 1:]
            self.on_status(line)

    resumable = False    # a detached run's stream: a reattach re-sends from the spool what we did not count

    def close(self):
        """The stream ended. A held tail that starts with our tag is a status line cut by the lost
        link: protocol, never output, never counted. A shorter held tail (it matched the start of
        the tag) cannot be told from output: for a resumable stream it is neither shown nor counted
        - the spool still has it and a reattach sends it again from the counted offset."""
        buf, self.buf = self.buf, b""
        if buf.startswith(self.tag) or (self.resumable and self.tag.startswith(buf)):
            return
        self._emit(buf)


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

    def __init__(self, cfg, frames, nonce, timing, give_up_s=None):
        self.cfg, self.frames, self.nonce, self.timing = cfg, frames, nonce, timing
        self.give_up_s = give_up_s           # stop waiting for a slot after this (=> run locally)
        self.wait_since = None               # monotonic time the runner first reported WAIT
        self.gave_up = False
        self.started = None                  # monotonic time "<nonce> STARTED" arrived
        self.ready = False                   # "<nonce> READY" arrived: the runner waits for GO
        self.go_sent = False
        self.first_sig = 0                   # the first INT/TERM/HUP we got (0 = none)
        self.go_lock = threading.Lock()      # orders go_sent against `done` (the ssh exited)
        self.ints = 0
        self.wake = threading.Event()
        self.done = threading.Event()
        self.unavail = None                  # "<nonce> UNAVAIL <why>": the worker refused (share off / no docker)
        self.exit_rc = None                  # "<nonce> EXIT <rc>": the command's own exit code
        self.used_docker = False             # "<nonce> DOCKER": the command called docker (cache: never saved)
        self.on_ready = None                 # called on READY, before GO (cache: drop the prepare's output)
        self.waits = 0                       # WAIT lines seen (the runner repeats one every rr_status_every_s)
        self.timed_out = False               # "<nonce> TIMEOUT <s>" (or our own backstop): exit 124
        self.exit_at = None                  # monotonic time "<nonce> EXIT" arrived
        self.last_out = None                 # monotonic time of the command's last output
        self.silent_said = 0                 # "no output" lines printed for the current silence
        self.run_id = None                   # header run_id: the run survives a lost link (reattach())
        self.out_off = self.err_off = 0      # bytes of the command's stdout / stderr received so far
        self.norun = False                   # (reattach) "<nonce> NORUN": the command never started
        self.gone = None                     # (reattach) "<nonce> GONE <why>": its result is lost
        self.attached = False                # (reattach) "<nonce> ATTACHED"
        self.mux = True                      # False: an ssh connection of its own (no shared master)

    host_name = None     # the worker's name, for messages
    tag = ""             # shards: "[shard i/n host] "
    wait_eta_s = None    # the scheduler's expected slot wait on this worker (s) when it was planned
    timeout_s = 0.0      # the command's wall-clock cap (the runner enforces it; we back it up)
    silent_s = 0.0       # "no output for N min" after this many s of silence (0 = off)

    def where(self):
        return "the Mac mini" if self.host_name in (None, "mini") else self.host_name

    def wait_note(self, rest):
        """One line per runner WAIT: what the slot wait is for, how long it should take."""
        kv = dict(x.split("=", 1) for x in rest.split() if "=" in x)
        waited = time.monotonic() - self.wait_since
        parts = []
        if kv.get("busy") and kv.get("slots"):
            parts.append("%s of %s slots busy" % (kv["busy"], kv["slots"]))
        gate = {"heavy": "every heavy-job slot is taken", "mem": "not enough free memory for this job"}
        if kv.get("gate") in gate:
            parts.append(gate[kv["gate"]])
        if kv.get("holder", "?") != "?":
            parts.append("held longest by %s%s for %ss" % (kv["holder"], " (%s)" % kv["howner"]
                                                           if kv.get("howner") else "", kv.get("age", "?")))
        try:
            ahead = int(kv.get("ahead", 0))
        except ValueError:
            ahead = 0
        parts.append("%d other run%s waiting ahead of this one" % (ahead, "" if ahead == 1 else "s")
                     if ahead else "next in line")
        if self.wait_eta_s is not None:
            left = self.wait_eta_s - waited
            parts.append("expected wait ~%s" % fmt_wait(left) if left >= 1
                         else "a slot is due any moment (past the scheduler's estimate)")
        lead = ("waiting for a slot on %s" % self.where() if self.waits == 1 else
                "still waiting for a slot on %s (%s so far)" % (self.where(), fmt_wait(waited)))
        note("%s%s: %s; tries elsewhere after %s" % (self.tag, lead, "; ".join(parts),
                                                     fmt_wait(slot_wait_min(self.cfg) * 60)))

    def saw_output(self):
        self.last_out = time.monotonic()
        self.silent_said = 0

    def watchdog(self, now):
        """A silent command gets a stderr line (never killed for it); a command past its cap
        that the worker has not reported on (TIMEOUT_MARGIN_S later) is stopped from here."""
        if self.started is None or self.exit_rc is not None:
            return
        ran = now - self.started
        if self.silent_s:
            quiet = now - max(self.last_out or self.started, self.started)
            # first line after silent_s, then every 5 x silent_s (1 min, 6 min, 11 min, ...)
            k = 0 if quiet < self.silent_s else 1 + int((quiet - self.silent_s) // (5 * self.silent_s))
            if k > self.silent_said:
                self.silent_said = k
                note("%sno output for %s (worker %s, running %s)"
                     % (self.tag, fmt_min(quiet), self.host_name or "mini", fmt_min(ran)))
        if self.timeout_s and not self.timed_out and ran > self.timeout_s + TIMEOUT_MARGIN_S:
            self.timed_out = True
            note("%s%s did not stop the command at its %s cap; closing the session (exit %d)"
                 % (self.tag, self.where(), fmt_min(self.timeout_s), EXIT_TIMEOUT))
            self.abort()

    def on_status(self, line):
        word, _, rest = line.partition(" ")
        if word == "READY":
            self.timing.mark("remote prepare (checkout, overlay, deps, slot)")
            if self.on_ready is not None:
                self.on_ready()
            self.ready = True
            self.wake.set()
        elif word == "STARTED":
            self.started = time.monotonic()
        elif word == "DOCKER":
            self.used_docker = True
        elif word == "EXIT":
            try:
                self.exit_rc = int(rest.strip())  # the command ended with this; a later drop is no loss
                self.exit_at = time.monotonic()
            except ValueError:
                pass
        elif word == "TIMEOUT":
            self.timed_out = True
            note("%sthe command ran past its %s wall-clock cap on %s; killed it and everything it started "
                 "(exit %d). RRUN_TIMEOUT=<minutes> sets another cap for one run, 0 = no cap"
                 % (self.tag, fmt_min(self.timeout_s or float(rest.strip() or 0)), self.where(), EXIT_TIMEOUT))
        elif word == "WAIT":
            if self.wait_since is None:
                self.wait_since = time.monotonic()
                self.wake.set()
            self.waits += 1
            self.wait_note(rest)
        elif word == "UNAVAIL":
            self.unavail = rest.strip() or "unavailable"
        elif word == "ATTACHED":
            self.attached = True
            if self.started is None:         # the first link died before STARTED: it runs, so count from here
                self.started = time.monotonic()
            note("%sreconnected to %s; the output goes on from where it broke off" % (self.tag, self.where()))
        elif word == "NORUN":
            self.norun = True
        elif word == "GONE":
            self.gone = rest.strip() or "its result is lost"
        elif word == "BUSY":
            note("%sno slot on %s within %s" % (self.tag, self.where(), fmt_wait(slot_wait_min(self.cfg) * 60)))
        elif word == "KEPT":
            note("the run failed; its containers stay on the Mac mini for inspection: %s "
                 "(docker ps / docker logs reach them; the janitor reaps them after 3 h idle)" % rest)

    def on_signal(self, signum, _frame):
        self.first_sig = self.first_sig or signum
        self.ints += 1 if signum != signal.SIGHUP else 2
        if self.ints >= 3 and self.proc.poll() is None:
            self.proc.kill()
        self.wake.set()

    aborted = False

    def abort(self):
        """Stop this run from our side (a hedge's other copy won): no GO if not yet sent; after GO
        the writer closes stdin, and the runner kills the command group. ssh is killed if it is
        still there after ABORT_KILL_S."""
        self.aborted = True
        self.ints = max(self.ints, 2)
        self.wake.set()
        proc = getattr(self, "proc", None)
        if proc is not None:
            t = threading.Timer(ABORT_KILL_S, lambda: proc.poll() is None and proc.kill())
            t.daemon = True
            t.start()

    def claim_go(self):
        """-> True when GO may be written now (and records that it was), False otherwise."""
        with self.go_lock:
            if self.done.is_set() or not self.ready or self.go_sent or self.ints or self.gave_up:
                return False
            self.go_sent = True              # from here on, any loss is ambiguous => 75
            return True

    def give_up_left(self):
        """Seconds until we stop waiting for a slot (None = never); 0 marks gave_up (no GO after)."""
        if self.give_up_s is None or self.wait_since is None:
            return None
        with self.go_lock:
            if self.ready or self.go_sent:
                return None
            left = self.give_up_s - (time.monotonic() - self.wait_since)
            if left <= 0:
                self.gave_up = True
                return 0
            return left

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
                    if self.go_sent:         # a detached run outlives our stdin: say it is a stop
                        w.write(b"KILL\n")
                        w.flush()
                    break
                left = self.give_up_left()
                if left == 0:
                    break                    # closing stdin: the runner gives up its slot wait
                if self.ints > sent_int:
                    w.write(b"INT\n")
                    sent_int = self.ints
                elif self.claim_go():
                    w.write(b"GO\n")
                else:
                    w.write(b".")
                w.flush()
                self.wake.wait(HEARTBEAT_S if left is None else min(HEARTBEAT_S, left))
        except (BrokenPipeError, OSError, ValueError):
            pass
        finally:
            try:
                w.close()
            except (BrokenPipeError, OSError):
                pass

    stderr_out = None    # where the remote stderr goes (None = our stderr; rd_warm keeps a tail)
    stdout_out = None    # where the remote stdout goes (None = straight to our stdout; shards: a Sink)

    def relay_stdout(self):
        fd = self.proc.stdout.fileno()
        while True:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            self.stdout_out.write(data)
            self.out_off += len(data)        # (the runner writes nothing but the command's on stdout)
            self.saw_output()
        self.stdout_out.flush()

    def relay(self):
        filt = StatusFilter(self.nonce, self.stderr_out or getattr(sys.stderr, "buffer", sys.stderr),
                            self.on_status, self.saw_output, self.count_err)
        filt.resumable = self.run_id is not None
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

    def count_err(self, n):
        """The command's stderr bytes (after STARTED; before it, the runner's own prepare notes)."""
        if self.started is not None:
            self.err_off += n

    def wait_proc(self):
        """ssh's exit status. Normally ssh ends right after the runner; if it stays open long after
        the command's exit code arrived (EXIT_BACKSTOP_S), it is killed - the result is known."""
        while True:
            try:
                return self.proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                pass
            now = time.monotonic()
            if self.exit_at is not None and now - self.exit_at > EXIT_BACKSTOP_S:
                note("%sthe command ended there (exit %d) but the session stayed open %ds; closing it"
                     % (self.tag, self.exit_rc, EXIT_BACKSTOP_S))
                self.proc.kill()
                return self.proc.wait()
            self.watchdog(now)

    def run(self):
        cmd = ["ssh", "-T"] + ssh_opts(self.mux) + [self.cfg["host"], remote_command(self.cfg)]
        sys.stdout.flush()
        if self.stdout_out is None:          # relayed too, so the silence watchdog sees stdout
            self.stdout_out = std_stream("stdout")
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE,
                                     stdout=subprocess.PIPE, start_new_session=True)
        # signal handlers can only be set from the main thread: a session in a worker thread (a
        # shard, a hedge) gets its signals forwarded from LIVE by whoever owns the main thread
        main = threading.current_thread() is threading.main_thread()
        old = {s: signal.signal(s, self.on_signal) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)} \
            if main else {}
        with LIVE_LOCK:
            LIVE.add(self)
        if STOP_SIG[0]:
            self.on_signal(STOP_SIG[0], None)    # stopped while this one was still being set up
        tw = threading.Thread(target=self.writer, daemon=True)
        tr = threading.Thread(target=self.relay, daemon=True)
        to = threading.Thread(target=self.relay_stdout, daemon=True)
        tw.start()
        tr.start()
        if to:
            to.start()
        try:
            rc = self.wait_proc()
        finally:
            with self.go_lock:
                self.done.set()              # no GO after this point
            self.wake.set()
            for s, h in old.items():
                signal.signal(s, h)
            with LIVE_LOCK:
                LIVE.discard(self)
        tr.join(5)       # a persisting ssh master could hold the pipe; never hang on it
        if to:
            to.join(5)
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


def record(target, argv, rc, secs, wt12=None, start=False, cap=None):
    """route.log line + rrun.json (last result, runs in flight: argv, worker, owner, start, cap) for
    `rdocker status` and the worktree-lock wait line."""
    pid = str(os.getpid())

    def apply(cur):
        cur = cur if isinstance(cur, dict) else {}
        active = {k: v for k, v in (cur.get("active") or {}).items() if k != pid and alive_pid(k)}
        if start:
            o = owner_info()
            active[pid] = {"ts": time.time(), "argv": short_argv(argv), "wt12": wt12, "host": target,
                           "owner": o["id"], "name": o["name"], "cap_s": cap, "cwd": os.getcwd()}
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


def active_runs(now=None):
    """This machine's rrun runs in flight (rrun.json, live pids only) -> [(pid, entry)], oldest first."""
    st = rd_common.load_json(rd_common.RRUN_STATE, {})
    act = (st.get("active") if isinstance(st, dict) else None) or {}
    out = [(k, v) for k, v in act.items() if isinstance(v, dict) and alive_pid(k)]
    return sorted(out, key=lambda kv: kv[1].get("ts") or 0)


def owner_label(entry):
    """'window name (session:abcd1234)' / 'pid:123' for a job entry (rrun.json or a worker .own)."""
    oid = str(entry.get("owner") or entry.get("id") or "?")
    short = oid[:16] if oid.startswith("session:") else oid
    return "%s (%s)" % (entry["name"], short) if entry.get("name") else short


def job_rows(now):
    """`rdocker status` rows: one per rrun of this machine in flight - worker, owner, start, command."""
    mine = owner_info()["id"]
    rows = []
    for pid, a in active_runs(now):
        ts = a.get("ts") if isinstance(a.get("ts"), (int, float)) else now
        rows.append((True, "rrun job", "%s on %s, started %s (%s), owner %s%s, pid %s: %s" % (
            "running", a.get("host") or "?", time.strftime("%H:%M", time.localtime(ts)), _ago(ts, now),
            owner_label(a), " = you" if a.get("owner") == mine else "", pid, a.get("argv"))))
    if rows:
        rows.append((True, "rrun jobs", "this machine's only; `rrun --jobs` lists every worker's "
                     "(`rrun --mine`: just yours)"))
    return rows


def wt_holder(wt12, now=None):
    """' (<argv> on <worker>, running 4 min, owner X, capped at 30 min)' for the run of ours that
    holds this worktree's lock, '' when rrun.json does not say."""
    now = time.time() if now is None else now
    for _pid, a in active_runs(now):
        if a.get("wt12") == wt12:
            ts = a.get("ts") if isinstance(a.get("ts"), (int, float)) else now
            cap = a.get("cap_s")
            return " (%s on %s, running %s, owner %s%s)" % (
                a.get("argv"), a.get("host") or "?", fmt_min(max(0, now - ts)), owner_label(a),
                ", its cap ends it within %s" % fmt_min(max(0, cap - (now - ts))) if cap else "")
    return ""


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


def fallback(argv, env_pairs, why, t0, job=None, pool=False):
    if os.environ.get("RRUN_STRICT") == "1":
        note("%s (RRUN_STRICT=1: not running on the laptop)" % why)
        record("mini", argv, EXIT_LOST, time.monotonic() - t0)
        return EXIT_LOST
    if pool and job and job.get("never_local"):
        note("%s - not running a %s job on this machine (it is what the worker pool keeps off "
             "agent machines); retry when a worker is back (exit 75)" % (why, job["cls"]))
        record("none", argv, EXIT_LOST, time.monotonic() - t0)
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


# ---------------------------------------------------------------------------- owner / limits

_OWNER_RE = re.compile(r"[^A-Za-z0-9 ._:@/+-]")


def _clean(v, n):
    return _OWNER_RE.sub("", v or "").strip()[:n]


def owner_info(environ=None):
    """Who is asking -> {"id", "name", "client"}: id = "session:<CLAUDE_CODE_SESSION_ID>" when set,
    else "pid:<parent pid>" (the shell that ran rrun); name = that session's /line window caption
    (the first line of ~/.claude/session-status/<id>.txt, the file `line-agent-communicator.py card`
    reads; one small file read, no subprocess); client = this machine's short host name. Every job
    carries it (the runner's slots/<i>.own, its process title, RRUN_OWNER in the command's env), so
    `rrun --jobs` / `rdocker status` tell one agent's runs from another's."""
    env = os.environ if environ is None else environ
    sid = re.sub(r"[^A-Za-z0-9-]", "", env.get("CLAUDE_CODE_SESSION_ID") or "")[:64]
    name = ""
    if sid:
        try:
            with open(os.path.join(rd_common.HOME, ".claude", "session-status", sid + ".txt"), "rb") as f:
                name = f.read(512).decode("utf-8", "replace").splitlines()[0]
        except (OSError, IndexError):
            name = ""
    return {"id": "session:" + sid if sid else "pid:%d" % os.getppid(), "name": _clean(name, 48),
            "client": _clean(socket.gethostname().split(".")[0], 48)}


TIMEOUT_MIN = {"light": 30, "normal": 30, "heavy": 60, "db": 90, "build": 60}


def timeout_s(cfg, cls, environ=None):
    """The command's wall-clock cap in seconds (0 = none): RRUN_TIMEOUT=<minutes> for this run, else
    rr_timeout_min[cls] (light/normal 30, heavy 60, db 90, build 60)."""
    v = (os.environ if environ is None else environ).get("RRUN_TIMEOUT")
    if v is not None and v.strip():
        try:
            return max(0.0, float(v) * 60.0)
        except ValueError:
            note("RRUN_TIMEOUT=%r is not a number of minutes; using the default cap" % v)
    table = cfg.get("rr_timeout_min") if isinstance(cfg.get("rr_timeout_min"), dict) else {}
    try:
        return max(0.0, float(table.get(cls, TIMEOUT_MIN.get(cls, 30))) * 60.0)
    except (TypeError, ValueError):
        return TIMEOUT_MIN.get(cls, 30) * 60.0


def slot_wait_min(cfg):
    """Minutes one runner waits for a slot before answering busy (73): rr_slot_wait_s (120 s), never
    more than rr_wait_min. A busy answer re-plans (host_loop), so a job never sits 30 min on one
    worker while another frees up; rr_wait_min bounds the whole search."""
    try:
        return min(float(cfg.get("rr_wait_min", 30)), float(cfg.get("rr_slot_wait_s", 120)) / 60.0)
    except (TypeError, ValueError):
        return 2.0


def wt_wait_s(cfg, job, environ=None):
    """How long a run waits for its worktree's lock: rr_wt_wait_min, else the job's own cap (the
    holder is capped too), else 90 min."""
    v = cfg.get("rr_wt_wait_min")
    try:
        if v is not None:
            return max(1.0, float(v) * 60.0)
    except (TypeError, ValueError):
        pass
    return timeout_s(cfg, job["cls"], environ) or 90 * 60.0


def silent_s(cfg, environ=None):
    """Seconds without output before the first "no output for N min" line (0 = never; later lines
    every 5x that): RRUN_SILENT_MIN, else rr_silent_min (1). Silence never kills: only the cap does."""
    v = (os.environ if environ is None else environ).get("RRUN_SILENT_MIN")
    for x in (v, cfg.get("rr_silent_min", 1)):
        try:
            if x is not None and str(x).strip():
                return max(0.0, float(x) * 60.0)
        except ValueError:
            continue
    return 60.0


def fmt_min(secs):
    return "%d min" % (secs // 60) if secs >= 60 else "%d s" % secs


# ---------------------------------------------------------------------------- reconnect

RECONNECT_TRIES = 3      # attempts on the mini after the first one lost it before GO


class _Stopped(Exception):
    def __init__(self, signum):
        Exception.__init__(self, signum)
        self.signum = signum


def _stop(signum, _frame):
    raise _Stopped(signum)


def reconnect_wait_s(cfg):
    """Seconds to wait for an unreachable mini; RRUN_RECONNECT_WAIT (seconds) overrides the config."""
    v = os.environ.get("RRUN_RECONNECT_WAIT")
    try:
        return max(0.0, float(v if v is not None else 60 * float(cfg.get("rr_reconnect_wait_min", 10))))
    except (TypeError, ValueError):
        return 600.0


def fmt_wait(secs):
    return "%d min" % round(secs / 60.0) if secs >= 90 else "%d s" % round(secs)


def mini_answers(cfg):
    """One quick ssh round trip on rrun's own master: True when the mini answers right now."""
    try:
        p = subprocess.run(["ssh"] + ssh_opts() + [cfg["host"], "true"], stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return p.returncode == 0


def wait_for_mini(cfg, why):
    """Poll until the mini answers (-> True) or the reconnect wait runs out (-> False). INT/TERM/HUP
    while waiting raise _Stopped: the caller ends the run without starting it anywhere."""
    limit = reconnect_wait_s(cfg)
    if limit <= 0:
        return False
    poll = float(os.environ.get("RRUN_RECONNECT_POLL") or 10)
    note("%s - waiting up to %s for it to come back (nothing has run yet; Ctrl-C stops)"
         % (why, fmt_wait(limit)))
    old = {s: signal.signal(s, _stop) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        deadline = time.monotonic() + limit
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            time.sleep(min(poll, left))
            if mini_answers(cfg):
                note("the Mac mini is back - trying there again")
                return True
    finally:
        for sig, h in old.items():
            signal.signal(sig, h)


# Exit codes the runner uses when the command was never started (GO not sent), with what they mean.
INFRA_EXIT = {
    65: "the Mac mini runner refused the request (bad input or an unsafe path; see above)",
    69: "the repo is missing on the Mac mini (the push should have created it); retry",
    70: "the Mac mini runner failed (see above)",
    78: "installing dependencies on the Mac mini failed (npm ci / prisma generate, see above)",
}


class Opts:
    """rrun's own flags, handed over by the `rrun` wrapper as env (popped: never reach the command)."""

    def __init__(self, environ=None):
        environ = os.environ if environ is None else environ
        self.where = environ.pop("RRUN_WHERE", "") == "1"
        self.bench = environ.pop("RRUN_BENCH", "") == "1"
        self.host = environ.pop("RRUN_HOST", "") or None
        raw = environ.pop("RRUN_OUTPUTS", "")
        self.outputs = [o.strip() for o in raw.split(",") if o.strip()]
        self.cache = environ.pop("RRUN_CACHE", "").strip() != "0"   # 0: run even with a cached result
        self.jobs = environ.pop("RRUN_JOBS", "")                    # "all" (--jobs) / "mine" (--mine)


def resolve_outputs(cfg, wt, argv, opts):
    """-> repo-relative build outputs: --outputs (relative to the cwd), else rr_outputs for a
    `npm run build` in a mapped package dir, else []. SystemExit on an unsafe --outputs path."""
    if not wt:
        return []
    if opts.outputs:
        out = []
        for o in opts.outputs:
            rel = os.path.normpath(os.path.join(wt["relcwd"], o)).replace(os.sep, "/")
            if os.path.isabs(o) or not sane_rel(rel) or rel == ".":
                raise SystemExit("rrun: --outputs %r is not a path inside this worktree" % o)
            out.append(rel)
        return list(dict.fromkeys(out))
    if rd_pool.is_build(argv):
        return rd_pool.outputs_for(cfg, wt["slug"], rd_pool.build_pkg_dir(wt["relcwd"], argv))
    return []


def label(h):
    return "the Mac mini" if h.name == "mini" else h.name


def next_host(hosts, skip):
    return next((k for k in range(len(hosts)) if k not in skip), None)


def rrun(argv, env_args=()):
    """`rrun [-e NAME[=VALUE]]... [--] <cmd...>` -> exit code (the remote command's, or 75/73/...)."""
    opts = Opts()
    if argv and argv[0] == "--":
        argv = argv[1:]
    if opts.bench:
        return rd_pool.bench(rd_common.load_cfg(), opts.host)
    if opts.jobs:
        return list_jobs(opts.jobs == "mine", opts.host)
    if not argv and not opts.where:
        sys.stderr.write("usage: rrun [-e NAME[=VALUE]]... [--where] [--host NAME] [--outputs a,b] "
                         "[--] <command> [args...]\n       rrun --bench [--host NAME]\n"
                         "       rrun --jobs | --mine [--host NAME]\n")
        return 2
    env_pairs = parse_env(env_args)
    t0 = time.monotonic()
    if not opts.where and (os.environ.get("RRUN_REMOTE") or os.environ.get("RRUN") == "0"):
        return run_local(argv, env_pairs)        # already on the mini / opted out: plain run
    cfg = rd_common.load_cfg()
    timing = Timing(os.environ.get("RRUN_TIMING") == "1")
    try:
        wt = resolve_worktree(os.getcwd())
    except (RunError, OSError) as e:
        if opts.where:
            wt = None
        else:
            return fallback(argv, env_pairs, "cannot use the Mac mini here (%s)" % str(e).strip(), t0)
    outputs = resolve_outputs(cfg, wt, argv, opts)
    if not opts.where and rd_pool.is_build(argv) and not outputs:
        # builds go to the pool only with known outputs (rr_outputs): any other build (the npm
        # shim sends every top-level `npm run build` here) runs on this machine, silently
        return run_local(argv, env_pairs)
    job = rd_pool.classify(argv, outputs)
    deps = deps_dirs(wt["top"], wt["relcwd"], argv) if wt else []
    if not opts.where:
        timing.mark("resolve")
        try:                         # fd stays open (and locked) until we exit or exec
            take_wt_lock(wt["wt12"], wt_wait_s(cfg, job), cfg)
        except WorktreeBusy as e:
            note("%s; not running it (exit %d). Check `rrun --mine`; rerun when it is done"
                 % (e, EXIT_WT_BUSY))
            return EXIT_WT_BUSY
        timing.mark("worktree lock")
    crun, cache_why = cache_prepare(cfg, wt, argv, env_pairs, deps, job, outputs) if wt \
        else (None, "not in a git worktree")
    hit = rd_cache.lookup(crun.key) if crun is not None and opts.cache and not opts.host else None
    if hit is not None and not opts.where:
        return replay_hit(hit, argv, t0)
    try:
        plan = rd_pool.plan(cfg, job, wt["slug"] if wt else "",
                            rd_pool.deps_shas(wt["top"], deps) if wt else [],
                            force=opts.host, probe=opts.where)
    except ValueError as e:
        note(str(e))
        return 2
    if not plan.hosts and not opts.where:
        # fleet.json's classes / max_cost_s / cold_ok leave no worker for this job: say so now
        # (waiting would not change it) - never a slot wait, never this machine
        note("%s; not running it (exit %d)" % (rd_pool.no_eligible_msg(job, plan.ineligible), EXIT_LOST))
        record("none", argv, EXIT_LOST, time.monotonic() - t0)
        return EXIT_LOST
    smode = rd_pool.shard_mode(cfg)
    shards, why_not = None, None
    if smode and plan.pool and not opts.host:
        ok, why_not = rd_pool.shardable(argv, job, os.getcwd(), forced=smode != "auto")
        shards = rd_pool.shard_assign(cfg, plan, job, None if smode == "auto" else smode) if ok else None
        if ok and not shards:
            why_not = "fewer than 2 free workers would help"
        shards = shards if shards and len(shards) >= 2 else None
    if opts.where:
        print("\n".join([cache_where(crun, cache_why, hit, opts)]
                        + rd_pool.where_report(cfg, job, plan, shards or why_not)))
        return 0
    ctx = Ctx(cfg, wt, env_pairs, timing, t0, job, plan, outputs, deps, crun)
    ctx.force = opts.host
    if shards:
        return cache_save(ctx, run_shards(ctx, shards, argv), argv)
    out = err = None
    if crun is not None:         # the output is recorded (and still printed live) for the cache
        out = Sink(rd_cache.Tee(std_stream("stdout"), crun.rec, 1))
        err = Sink(rd_cache.Tee(std_stream("stderr"), crun.rec, 2))
    kind, val = host_loop(ctx, plan.hosts, argv, give_up=plan.local_after_s, out=out, err=err)
    if kind == "local":
        return fallback(argv, env_pairs, val, t0, job, plan.pool)
    return cache_save(ctx, val, argv)


def list_jobs(mine_only, force=None, out=None):
    """`rrun --jobs` (every running rrun job on every worker) / `rrun --mine` (only the caller's:
    same CLAUDE_CODE_SESSION_ID, else same parent pid). One probe round; reads each worker's
    slots/<i>.own. -> 0, or 1 when no worker answered."""
    out = out or sys.stdout
    cfg = rd_common.load_cfg()
    me = owner_info()["id"]
    try:
        p = rd_pool.plan(cfg, rd_pool.classify(["true"]), force=force, probe=True)
    except ValueError as e:
        note(str(e))
        return 2
    now = time.time()
    rows, down = [], []
    hosts = p.hosts + [h for h, _ in p.ineligible]    # a worker that would not take `true` runs jobs too
    for h in hosts:
        if h.probe is None:
            down.append(h.name)
            continue
        for j in h.probe.get("jobs") or []:
            if not isinstance(j, dict) or (mine_only and j.get("id") != me):
                continue
            st = j.get("start") if isinstance(j.get("start"), (int, float)) else None
            rows.append((st or 0, h.name, time.strftime("%H:%M", time.localtime(st)) if st else "?",
                         fmt_min(now - st) if st else "?",
                         owner_label(j) + (" = you" if j.get("id") == me else ""),
                         j.get("client") or "?", j.get("cmd") or "?"))
    rows.sort()
    if rows:
        out.write("%-10s %-6s %-8s %-40s %-14s %s\n" % ("WORKER", "START", "RUNNING", "OWNER", "FROM", "COMMAND"))
        for _, *r in rows:
            out.write("%-10s %-6s %-8s %-40s %-14s %s\n" % tuple(r))
    else:
        out.write("no %srrun jobs running on %s\n" % ("of your " if mine_only else "",
                                                     ", ".join(h.name for h in hosts if h.probe) or "any worker"))
    if down:
        out.write("not answering (their jobs are not listed): %s\n" % ", ".join(down))
    if mine_only:
        out.write("you = %s\n" % me)
    return 0 if len(down) < len(hosts) else 1


def replay_hit(hit, argv, t0):
    """A cached result: its output in the original order, one stderr line, its exit code."""
    meta, frames = hit
    sys.stdout.flush()
    rd_cache.replay(frames, std_stream("stdout"), std_stream("stderr"))
    note(rd_cache.hit_line(meta))
    record("cache", argv, meta["rc"], time.monotonic() - t0)
    return meta["rc"]


def cache_save(ctx, rc, argv):
    """Store the finished run's result when it may be replayed (rd_cache.Run.save decides)."""
    if ctx.cache is not None:
        ctx.cache.save(rc, time.monotonic() - ctx.t0, short_argv(argv))
    return rc


def cache_where(crun, why, hit, opts):
    """`rrun --where`: would the result come from the cache?"""
    if crun is None:
        return "cache: not cached (%s)" % why
    if not opts.cache:
        return "cache: off (RRUN_CACHE=0): runs, then saves the fresh result"
    if opts.host:
        return "cache: not used with --host (runs there, then saves the result)"
    if hit is not None:
        return "cache: hit - replays the result from %s ago on %s (exit %d); RRUN_CACHE=0 runs it again" % (
            rd_cache.fmt_age(time.time() - hit[0]["ts"]), hit[0].get("worker") or "a worker", hit[0]["rc"])
    return "cache: miss - runs, then saves the result (a pass for 24 h, a failure for 20 min)"


class Ctx:
    """Everything one rrun invocation's attempts share."""

    def __init__(self, cfg, wt, env_pairs, timing, t0, job, plan, outputs, deps, cache=None):
        self.cfg, self.wt, self.env_pairs, self.timing, self.t0 = cfg, wt, env_pairs, timing, t0
        self.job, self.plan, self.outputs, self.deps = job, plan, outputs, deps
        self.cache = cache           # rd_cache.Run for a cacheable run, else None
        self.force = None            # --host NAME: re-plans keep to that worker


def host_loop(ctx, hosts, argv, give_up=None, out=None, err=None, threaded=False, tag="", frac=1.0,
              on_host=None):
    """Try `hosts` in order -> ("done", rc) | ("local", why: run it on this machine). Lost before
    GO / no slot after a race wait -> the next host; lost after GO -> once more on the next host
    for a job that is safe to repeat, else exit 75. threaded (a shard): no reconnect wait (it
    needs the main thread's signals) - "local" once every host failed. frac: the share of the
    whole job this run is (a shard: 1/n), for the hedge's expected time."""
    job, t0 = ctx.job, ctx.t0
    i, tries, retried, failed = 0, 0, False, set()
    busy_t0 = round_t0 = time.monotonic()
    slot_busy = False
    total = 60.0 * float(ctx.cfg.get("rr_wait_min", 30))
    while True:
        if threaded and STOP_SIG[0]:
            return "done", 128 + STOP_SIG[0]
        h = hosts[i]
        if on_host:
            on_host(h)
        g = give_up if i == 0 else None    # set only when all were busy: hosts[0] = wait host
        kind, val = attempt_on(ctx, h, argv, g, out, err, tag, frac)
        if kind == "done":
            return "done", val
        if kind == "local":
            return "local", val
        failed.add(i)
        nxt = next_host(hosts, failed)
        if kind == "busy" and "not taking jobs" not in val:
            slot_busy = True                    # a real slot wait (not a refusal): worth a re-plan
        if kind == "lost_go":
            # lost_go = the connection died before the command's exit code arrived (the worker went
            # away: ssh died, no keepalive answer, host down). A command that exited with a real code
            # is "done", never retried. DB jobs may repeat too: each run gets its own throwaway
            # database on the worker (the runner's docker shim, labelled and removed per run).
            if (job["retry_ok"] or job["db"]) and not retried and nxt is not None:
                note("%s%s went away mid-run (lost connection); re-running once on %s"
                     % (tag, h.name, hosts[nxt].name))
                if threaded and ctx.cache is not None:   # the lost part's output is mixed in
                    ctx.cache.taint("a shard re-ran after a lost worker")
                retried, i = True, nxt
                continue
            sys.stderr.write(tag + LOST_MSG + "\n")
            record(h.name, argv, EXIT_LOST, time.monotonic() - t0)
            return "done", EXIT_LOST
        if nxt is not None:
            note("%s%s - trying %s" % (tag, val, hosts[nxt].name))
            i = nxt
            continue
        if kind == "busy":
            if "not taking jobs" in val:
                note(tag + val)
            waited = time.monotonic() - busy_t0
            if slot_busy and waited < total and not (threaded and STOP_SIG[0]):
                # every worker said busy: probe again (one may have freed up, or come online) and
                # go round once more, until rr_wait_min in all
                try:
                    if time.monotonic() - round_t0 < 20:          # they refused at once: do not spin
                        time.sleep(min(30.0, total - waited))
                except KeyboardInterrupt:
                    return "done", 130
                note("%severy worker is busy (%s waited so far, gives up after %s); re-planning"
                     % (tag, fmt_wait(time.monotonic() - busy_t0), fmt_wait(total)))
                hosts = replan(ctx, hosts) if not threaded else hosts
                if not hosts:
                    note("%s%s; not running it (exit %d)"
                         % (tag, rd_pool.no_eligible_msg(job, ctx.plan.ineligible), EXIT_LOST))
                    record("none", argv, EXIT_LOST, time.monotonic() - t0)
                    return "done", EXIT_LOST
                i, failed, round_t0, slot_busy = 0, set(), time.monotonic(), False
                continue
            note("%sno worker had a free slot%s; giving up (exit 73)"
                 % (tag, " for %s" % fmt_wait(total) if slot_busy else ""))
            return "done", 73
        if threaded or tries >= RECONNECT_TRIES:
            return "local", val
        tries += 1
        i, failed, h = 0, set(), hosts[0]
        # Nothing has started anywhere yet. A mini that answers right away (a blip, or a failure
        # that is not about reachability) gets one immediate retry; one that does not answer is
        # waited for (rr_reconnect_wait_min), so a short outage never moves a heavy run here.
        if mini_answers(h.cfg):
            if tries > 1:
                return "local", val
            continue
        try:
            back = wait_for_mini(h.cfg, val)
        except _Stopped as e:
            note("stopped while waiting for the Mac mini - not running it anywhere")
            return "done", 128 + e.signum
        if not back:
            return "local", "%s, and it did not come back within %s" % (val, fmt_wait(reconnect_wait_s(h.cfg)))


def replan(ctx, hosts):
    """A fresh plan's host order (the probe sees who freed up); the old list if planning fails. A
    plan that worked but left no eligible worker (fleet.json changed, packages gone) -> [] (the
    caller ends with exit 75 and plan.ineligible's reasons): never the stale list."""
    try:
        p = rd_pool.plan(ctx.cfg, ctx.job, ctx.wt["slug"], rd_pool.deps_shas(ctx.wt["top"], ctx.deps),
                         force=ctx.force)
    except Exception:            # a fleet that changed under us: keep trying the old list
        return hosts
    ctx.plan = p
    return p.hosts


def attempt_on(ctx, h, argv, give_up=None, out=None, err=None, tag="", frac=1.0):
    """attempt() on a free lane of h, with a hedge watching it when hedging is on for this job."""
    key = h.cfg["host"]
    n = take_lane(key)
    lane = Lane(out, err, None if n == 0 else short_hash("%s:lane%d" % (ctx.wt["wt12"], n), 12))
    lane.tag = tag
    hedge = Hedge(ctx, h, argv, lane, tag, frac, out, err) if hedge_on(ctx) else None
    try:
        if hedge:
            hedge.start()
        kind, val = attempt(h, ctx.wt, argv, ctx.env_pairs, ctx.timing, ctx.t0, ctx.job, ctx.plan.pool,
                            ctx.outputs, ctx.deps, give_up, lane, cache=ctx.cache)
    finally:
        drop_lane(key, n)
    if hedge:
        won = hedge.finish(primary_lost=kind == "lost_go")
        if won is not None:
            return "done", won
    return kind, val


# ---------------------------------------------------------------------------- hedge

HEDGE_FACTOR = 2.0       # a run past this many x its expected time is a straggler...
HEDGE_GAIN = 3.0         # ...worth a duplicate on a free worker whose eta is at least this many x better
HEDGE_POLL_S = 15.0      # how often a straggler looks for such a worker (one probe round each time)


def hedge_on(ctx, environ=None):
    """RRUN_HEDGE=1 / rr_hedge (default off) - and only in a pool, only for jobs safe to run twice
    at once: tsc, lint, vitest/jest (never DB tests, never builds: they copy outputs back)."""
    v = (os.environ if environ is None else environ).get("RRUN_HEDGE")
    on = (v.strip() not in ("", "0")) if v is not None else bool(ctx.cfg.get("rr_hedge", False))
    job = ctx.job
    return bool(on and ctx.plan.pool and job["retry_ok"] and not job["db"] and job["cls"] != "build")


class Hedge:
    """Watches one attempt; once it has run HEDGE_FACTOR x its expected time and a probe finds a
    free worker HEDGE_GAIN x better, starts ONE duplicate there (output held). The first to finish
    wins: the duplicate's win stops the original (its output so far stays on screen; the
    duplicate's follows, marked); the original's win stops the duplicate (its output is dropped)."""

    def __init__(self, ctx, h, argv, lane, tag, frac, out, err):
        self.ctx, self.h, self.argv, self.lane, self.tag = ctx, h, argv, lane, tag
        cost = h.run_s if h.run_s is not None else rd_pool.job_cost(ctx.cfg, ctx.job["cls"]) / max(0.01, h.speed)
        self.expect = cost * frac
        self.frac = frac
        self.ref = (h.cold_s or 0.0) + min(h.rtt or 0.0, rd_pool.RTT_CAP_S) + self.expect
        self.out_stream = out.stream if out is not None else std_stream("stdout")
        self.err_stream = err.stream if err is not None else std_stream("stderr")
        self.prefix = out.prefix if out is not None else ""
        self.poll = float(ctx.cfg.get("rr_hedge_poll_s", HEDGE_POLL_S))
        self.primary_done = threading.Event()
        self.lock = threading.Lock()
        self.decided, self.rc, self.dup, self.dup_lane, self.thread = False, None, None, None, None

    def start(self):
        self.thread = threading.Thread(target=self.watch, daemon=True)
        self.thread.start()

    def eta(self, c):
        return (c.cold_s or 0.0) + min(c.rtt or 0.0, rd_pool.RTT_CAP_S) + (c.run_s or 0.0) * self.frac

    def candidate(self):
        ctx = self.ctx
        try:
            p = rd_pool.plan(ctx.cfg, ctx.job, ctx.wt["slug"], rd_pool.deps_shas(ctx.wt["top"], ctx.deps),
                             probe=True)
        except Exception:            # a fleet that changed under us: no hedge, the run goes on
            return None
        for c in p.hosts:            # fresh: a worker that just came online counts
            if c.state == "free" and c.name != self.h.name and c.run_s is not None \
                    and HEDGE_GAIN * self.eta(c) <= self.ref:
                return c
        return None

    def watch(self):
        while not self.primary_done.wait(self.poll):
            s = self.lane.session
            if s is None or s.started is None or s.aborted:
                continue
            ran = time.monotonic() - s.started
            if ran < HEDGE_FACTOR * self.expect:
                continue
            c = self.candidate()
            if c is None or self.primary_done.is_set():
                continue
            note("%s%s has run %s, over %gx the %s expected there; starting a duplicate on %s (eta %s) - "
                 "the first to finish wins" % (self.tag, self.h.name, rd_pool.fmt_s(ran), HEDGE_FACTOR,
                                               rd_pool.fmt_s(self.expect), c.name, rd_pool.fmt_s(self.eta(c))))
            self.run_dup(c)
            return

    def run_dup(self, c):
        ctx = self.ctx
        key = c.cfg["host"]
        out = Sink(self.out_stream, "", hold=True)
        err = Sink(self.err_stream, "", hold=True)
        with self.lock:
            if self.decided:
                return               # the original finished while we probed
            n = take_lane(key)
            self.dup = c.name
            if ctx.cache is not None:    # two runs' output on one screen: not replayable
                ctx.cache.taint("a hedged duplicate ran")
            self.dup_lane = Lane(out, err, None if n == 0 else short_hash("%s:lane%d" % (ctx.wt["wt12"], n), 12))
        try:
            kind, val = attempt(c, ctx.wt, self.argv, ctx.env_pairs, Timing(False), ctx.t0, ctx.job,
                                ctx.plan.pool, ctx.outputs, ctx.deps, None, self.dup_lane)
        finally:
            drop_lane(key, n)
        s = self.dup_lane.session
        with self.lock:
            if self.decided or kind != "done" or s is None or not s.go_sent or s.aborted:
                return               # the original finished first, or the duplicate never really ran
            self.decided, self.rc = True, val
        prim = self.lane.session
        if prim is not None:
            prim.abort()

    def finish(self, primary_lost=False):
        """The original attempt returned -> the duplicate's rc when it won (its held output is
        printed now), else None (the duplicate, if any, is stopped). An original lost after GO
        waits for a running duplicate instead of re-running the job."""
        self.primary_done.set()
        with self.lock:
            dup_lane = self.dup_lane
        if primary_lost and dup_lane is not None and self.thread.is_alive():
            note("%slost %s mid-run; the duplicate on %s is still running - waiting for it"
                 % (self.tag, self.h.name, self.dup))
            self.thread.join()
        with self.lock:
            won = self.rc is not None
            self.decided = True
            dup_lane = self.dup_lane
        if not won:
            if dup_lane is not None and dup_lane.cancel():
                note("%s%s finished first; stopped the duplicate on %s" % (self.tag, self.h.name, self.dup))
            if self.thread is not None:
                self.thread.join(ABORT_KILL_S + 5)
            return None
        note("%sthe duplicate on %s finished first (rc=%s); stopped the run on %s - the duplicate's "
             "output follows" % (self.tag, self.dup, self.rc, self.h.name))
        for s in (self.dup_lane.out, self.dup_lane.err):
            if self.prefix:
                s.prefix = self.prefix.replace(self.h.name + "]", self.dup + " hedge]")
            s.release()
        return self.rc


# ---------------------------------------------------------------------------- shards

def shard_argv(argv, i, n):
    """argv with --shard=i/n right after `vitest run` (never after a `--`)."""
    k = next(j for j, a in enumerate(argv[:-1]) if os.path.basename(a) == "vitest" and argv[j + 1] == "run")
    return argv[:k + 2] + ["--shard=%d/%d" % (i, n)] + argv[k + 2:]


def run_local_shard(ctx, argv, out, err, why):
    """A shard no worker could take: on this machine (subprocess, output prefixed like the rest),
    unless RRUN_STRICT=1 / a never-local job in the pool (exit 75)."""
    if os.environ.get("RRUN_STRICT") == "1" or ctx.job.get("never_local"):
        note("%s - not running this shard on this machine (exit 75)" % why)
        return EXIT_LOST
    note("%s - running this shard on this machine (RDOCKER_MODE=local)" % why)
    env = dict(os.environ, RDOCKER_MODE="local", RRUN="0")
    env.update(ctx.env_pairs)
    try:
        p = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
    except OSError as e:
        note("%s: %s" % (argv[0], e))
        return 127
    with LIVE_LOCK:
        LOCAL_PROCS.add(p)

    def pump(src, sink):
        for chunk in iter(lambda: os.read(src.fileno(), 65536), b""):
            sink.write(chunk)
    ts = [threading.Thread(target=pump, args=(p.stdout, out), daemon=True),
          threading.Thread(target=pump, args=(p.stderr, err), daemon=True)]
    for t in ts:
        t.start()
    rc = p.wait()
    for t in ts:
        t.join(5)
    with LIVE_LOCK:
        LOCAL_PROCS.discard(p)
    record("local", argv, rc, time.monotonic() - ctx.t0)
    return rc if rc >= 0 else 128 - rc


LOCAL_PROCS = set()


def run_shards(ctx, assign, argv):
    """Split a `vitest run` into len(assign) shards (vitest --shard=i/n), shard i on assign[i-1]
    first and the rest of the plan as its failover, all at once. Output lines are prefixed
    "[shard i/n host] "; exit code = the highest shard rc; a merged vitest summary at the end."""
    n = len(assign)
    plan = ctx.plan
    cnt = {}
    for h in assign:
        cnt[h.name] = cnt.get(h.name, 0) + 1
    note("splitting `vitest run` into %d shards: %s (RRUN_SHARD=0: one run)"
         % (n, ", ".join("%s %d" % kv for kv in cnt.items())))
    rcs, outs, errs = [None] * n, [], []
    so, se = std_stream("stdout"), std_stream("stderr")
    if ctx.cache is not None:        # one cache entry for the whole sharded run
        ctx.cache.sharded, ctx.cache.expect = True, n
        so, se = rd_cache.Tee(so, ctx.cache.rec, 1), rd_cache.Tee(se, ctx.cache.rec, 2)

    def one(i, home):
        out = Sink(so, "[shard %d/%d %s] " % (i + 1, n, home.name))
        err = Sink(se, out.prefix)
        outs.append(out)
        errs.append(err)
        tag = "[shard %d/%d] " % (i + 1, n)

        def on_host(h):
            out.prefix = err.prefix = "[shard %d/%d %s] " % (i + 1, n, h.name)
        # failover: never a worker that takes no shards (fleet.json "shards": false)
        hosts = [home] + [h for h in plan.hosts if h is not home and rd_pool.takes_shards(h)]
        sargv = shard_argv(argv, i + 1, n)
        try:
            kind, val = host_loop(ctx, hosts, sargv, out=out, err=err, threaded=True, tag=tag,
                                  frac=1.0 / n, on_host=on_host)
            if kind == "local":
                out.prefix = err.prefix = "[shard %d/%d local] " % (i + 1, n)
                if ctx.cache is not None:
                    ctx.cache.taint("a shard ran on this machine")
                val = run_local_shard(ctx, sargv, out, err, tag + val)
        except Exception as e:       # one shard's bug must not hang the others
            note("%sfailed: %s" % (tag, e))
            val = 70
        finally:
            out.close()
            err.close()
        rcs[i] = val

    def forward(signum, frame):
        STOP_SIG[0] = STOP_SIG[0] or signum
        with LIVE_LOCK:
            live, local = list(LIVE), list(LOCAL_PROCS)
        for s in live:
            s.on_signal(signum, frame)
        for p in local:
            if p.poll() is None:
                p.send_signal(signum)
    old = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        ts = [threading.Thread(target=one, args=(i, h), daemon=True) for i, h in enumerate(assign)]
        for t in ts:
            t.start()
        while any(t.is_alive() for t in ts):
            for t in ts:
                t.join(0.2)
    finally:
        for s, h in old.items():
            signal.signal(s, h)
    rc = max(r if isinstance(r, int) else 70 for r in rcs)
    summary = rd_pool.shard_summary([o.tail.decode("utf-8", "replace") for o in outs])
    note("%d shards done: exit %d (%s)" % (n, rc, ", ".join("%d/%d rc=%s" % (i + 1, n, r)
                                                            for i, r in enumerate(rcs))))
    if summary:
        with OUT_LOCK:
            out = so
            out.write(("\n".join(["", " rrun: merged summary of %d shards" % n] + summary) + "\n").encode())
            out.flush()
    return rc


def runner_frames(h, wt, argv, env, deps, tar, envs, deleted, job, pool, outputs=(), **extra):
    """-> (stdin frames for the loader: runner script, JSON header, overlay tar; the nonce). The one
    place a runner header is built (rrun's attempt and rd_warm's prepare-only session); `extra`
    overrides header keys (rd_warm: wait_min=0, never queue for a slot)."""
    cfg = h.cfg
    nonce = secrets.token_hex(16)
    header = {"nonce": nonce, "repo_slug": wt["slug"], "wt12": wt["wt12"], "sha": wt["sha"],
              "relcwd": wt["relcwd"], "argv": argv, "env": env, "deleted": deleted,
              "tar_len": len(tar), "env_files": envs,
              "stamps": {"dirs": deps, "npm_args": []},
              "slots": cfg.get("rr_slots", 1), "wait_min": slot_wait_min(cfg),
              "slots_base": cfg.get("rr_slots_base", cfg.get("rr_slots", 1)),
              "spare_min_free_pct": cfg.get("rr_spare_min_free_pct", 25),
              "spare_max_load": cfg.get("rr_spare_max_load", 1.5),
              "hb_timeout": cfg.get("rr_hb_timeout", 60), "keep_containers_on_fail": True,
              "owner": owner_info(), "timeout_s": int(timeout_s(cfg, job["cls"])),
              "exit_grace": cfg.get("rr_exit_grace_s", 10),
              "wait_every": cfg.get("rr_status_every_s", 60),
              # detached run: survives a lost link (reattach()); uuid4 = unguessable
              "run_id": str(uuid.uuid4()), "detach_hb_s": cfg.get("rr_detach_hb_s", 180),
              "job_cls": job["cls"]}
    if outputs:
        header["outputs"] = list(outputs)
    if pool:                     # pool-only gates (a lone host keeps the plain slot logic)
        header.update(cls=job["cls"], need_gb=job["need_gb"])
        hs = rd_pool._f(h.entry, "heavy_slots") if h.entry is not None else None
        if isinstance(hs, int) and hs >= 0:
            header["heavy_slots"] = hs
    header.update(extra)
    with open(rd_common.RUNNER_SRC, "rb") as f:
        script = f.read()
    hjs = json.dumps(header).encode("utf-8")
    return [b"%d\n" % len(script), script, b"%d\n" % len(hjs), hjs, tar], nonce


def attempt(h, wt, argv, env_pairs, timing, t0, job, pool, outputs=(), deps=None, give_up_s=None,
            lane=None, cache=None):
    """One try on host h -> ("done", rc) | ("lost", why: dropped before the command started) |
    ("busy", why: a race-wait host had no slot after all) | ("lost_go", why: dropped after GO -
    the command may have run) | ("local", why: run it on the laptop now, waiting would not help).
    lane (shards, hedges): output sinks + a per-lane mirror id; lane.session is set once it runs.
    cache (rd_cache.Run): told what this attempt shipped and how its command ended."""
    cfg = h.cfg
    if lane is not None and lane.wt12:
        wt = dict(wt, wt12=lane.wt12)
    try:
        with host_lock(cfg["host"]):
            base = push(cfg, wt) or []
    except PushRefused as e:
        return "local", "cannot send this repo to %s: %s" % (label(h), e)
    except RunError as e:
        return "lost", "%s unreachable (%s)" % ("Mac mini" if h.name == "mini" else h.name, e)
    timing.mark("push")
    deps = deps_dirs(wt["top"], wt["relcwd"], argv) if deps is None else deps
    try:
        tar, files, envs, deleted = build_overlay(cfg, wt["top"], env_dirs_for(wt, deps))
    except RunError as e:
        return "local", "could not list the worktree (%s)" % e
    if len(tar) > OVERLAY_WARN_BYTES:
        note("sending %.1f MB of uncommitted/untracked files" % (len(tar) / 1048576.0))
    timing.mark("overlay (%d files, %d env, %d deleted, %d bytes)" % (len(files), len(envs),
                                                                     len(deleted), len(tar)))
    env = ship_env(cfg, env_pairs)
    if cache is not None:            # what this attempt really sends must be what the key hashed
        cache.shipped(rd_cache.content_id(wt["sha"], base, tar, envs, deleted, env, deps))
    run_id = str(uuid.uuid4())
    frames, nonce = runner_frames(h, wt, argv, env, deps, tar, envs, deleted, job, pool, outputs,
                                  run_id=run_id, waited_s=round(time.monotonic() - t0, 1))
    cap = timeout_s(cfg, job["cls"])
    record(h.name, argv, None, 0, wt12=wt["wt12"], start=True, cap=cap)
    sess = Session(cfg, frames, nonce, timing, give_up_s)
    sess.host_name, sess.timeout_s, sess.silent_s = h.name, cap, silent_s(cfg)
    sess.run_id = run_id
    sess.tag = lane.tag if lane is not None else ""
    if h.queue_s is not None and h.state == "busy":
        sess.wait_eta_s = h.queue_s      # the scheduler's estimate of this worker's slot wait
    if cache is not None and not cache.sharded:
        sess.on_ready = cache.rec.reset      # keep only the command's own output (+ this attempt's)
    if lane is not None:
        sess.stdout_out, sess.stderr_out = lane.out, lane.err
        if not lane.bind(sess):
            return "busy", "%s: cancelled before it started" % h.name
    rc = sess.run()
    if sess.go_sent and sess.exit_rc is None and rc == 255 and not sess.timed_out:
        att = reattach(h, sess, lane)
        if (att is None or att.exit_rc is None) and (getattr(sess, "reattach_stopped", False) or sess.first_sig):
            # the caller signalled (Ctrl-C, a tool's TERM) and no result came back: it wanted the run
            # to end - never re-run it anywhere
            record(h.name, argv, 128 + sess.first_sig, time.monotonic() - t0)
            return "done", 128 + sess.first_sig      # the caller wants it to end: never re-run it
        if att is not None and att.norun:
            record(h.name, argv, rc, time.monotonic() - t0)
            timing.report()
            return "lost", "lost %s before the command started (it never ran there)" % label(h)
        if att is not None:
            rc = att.final_rc
            for k in ("exit_rc", "exit_at", "used_docker", "timed_out", "gone"):
                setattr(sess, k, getattr(att, k))
    secs = time.monotonic() - t0
    if not sess.go_sent:
        # GO was never written, so the runner never started the command: running it here is
        # safe when the connection dropped; any other rc is the runner's own (73, 78, ...).
        record(h.name, argv, rc, secs)     # clears the in-flight entry before a local exec
        timing.report()
        if sess.first_sig:
            # stopped (Ctrl-C, or a tool's timeout sent TERM) while the mini was still preparing:
            # the caller wants it to end - never start it here instead (2026-10-15: a 10-min tool
            # timeout during a slot wait turned into a full local run)
            note("stopped before the command started on the Mac mini - not running it anywhere")
            return "done", 128 + sess.first_sig
        if sess.gave_up:
            return "local", "every worker stayed busy for %d s" % round(give_up_s)
        if rc == 255:
            return "lost", "lost %s before the command started" % label(h)
        if rc == 73 and sess.unavail:      # refused before anything ran: always safe to move on
            why = {"share=off": "its owner turned sharing off",
                   "docker": "its Docker engine did not start"}.get(sess.unavail, sess.unavail)
            return "busy", "%s is not taking jobs (%s)" % (h.name, why)
        if rc == 73:                       # no slot within the runner's wait: re-plan (host_loop)
            return "busy", "%s had no free slot after %s" % (h.name, fmt_wait(slot_wait_min(cfg) * 60))
        if rc in INFRA_EXIT:
            note("%s - exit %d; the command did not run" % (INFRA_EXIT[rc], rc))
        return "done", rc
    timing.mark("command")
    if sess.timed_out and sess.exit_rc is None:
        rc = sess.exit_rc = EXIT_TIMEOUT     # our backstop closed it: the cap was hit, never re-run
    if sess.exit_rc is not None:
        if rc != sess.exit_rc and rc == 255:
            note("the link to %s dropped after the command finished there (exit %d); that is the result"
                 % (label(h), sess.exit_rc))
        rc = sess.exit_rc
        if cache is not None:
            cache.attempt_done(h.name, rc, sess.used_docker, bool(sess.ints or sess.first_sig))
    elif sess.gone:
        # the worker says the run's result is lost and cannot prove it never ran: it may have run,
        # so it is never re-run (not even a job safe to repeat)
        note("%s: the run's result is lost there (%s); not re-running it (exit %d)"
             % (label(h), sess.gone, EXIT_LOST))
        record(h.name, argv, EXIT_LOST, secs)
        timing.report()
        return "done", EXIT_LOST
    elif rc == 255:
        return "lost_go", "lost %s mid-run" % label(h)
    if rc == 0 and outputs:
        why = copy_back(cfg, wt, outputs)
        timing.mark("copy-back")
        if why:
            note("the build ran on %s but its outputs could not be copied back (%s); run it again "
                 "(exit 75)" % (h.name, why))
            rc = EXIT_LOST
    record(h.name, argv, rc, secs)
    timing.report()
    return "done", rc


# ---------------------------------------------------------------------------- reattach

def attach_frames(run_id, nonce, out_off, err_off):
    """Loader frames for a session that follows a running detached run from these offsets."""
    with open(rd_common.RUNNER_SRC, "rb") as f:
        script = f.read()
    hjs = json.dumps({"nonce": nonce, "attach": run_id, "out_off": out_off, "err_off": err_off}).encode()
    return [b"%d\n" % len(script), script, b"%d\n" % len(hjs), hjs]


def _cfg_list(v, default):
    try:
        return [max(0.0, float(x)) for x in v] if isinstance(v, (list, tuple)) and v else default
    except (TypeError, ValueError):
        return default


REATTACH_MAX = 10       # reconnects per run in all (each one that made progress opens a new window)


def reattach(h, sess, lane=None):
    """The link to h died after GO and before the command's exit code arrived. The worker runs a
    detached command on for rr_detach_hb_s without us (output spooled), so connect again - a fresh
    ssh each time, never the shared master that just failed - and follow it from the bytes we have:
    up to rr_reattach_tries tries within rr_reattach_window_s (a reattach that moved the output on
    and dropped again starts a new window; REATTACH_MAX in all), waiting rr_reattach_backoff_s
    before each.
    -> the attach Session that saw the end (exit_rc, or norun: the command never started there;
    gone: its result is lost; final_rc: that ssh's status), or None when reattaching is not possible
    or failed - the caller then applies the lost-worker rules (re-run once if safe to repeat, else 75)."""
    cfg = h.cfg
    if not sess.run_id or sess.aborted or sess.ints >= 2 or (lane is not None and lane.cancelled):
        return None
    try:
        tries = int(cfg.get("rr_reattach_tries", 3))
        window = float(cfg.get("rr_reattach_window_s", 120))
    except (TypeError, ValueError):
        tries, window = 3, 120.0
    backoff = _cfg_list(cfg.get("rr_reattach_backoff_s"), [0.0, 10.0, 30.0])
    prev, n, total, deadline = sess, 0, 0, time.monotonic() + window
    while n < tries and time.monotonic() < deadline:
        pause = min(backoff[min(n, len(backoff) - 1)], max(0.0, deadline - time.monotonic()))
        end = time.monotonic() + pause
        main = threading.current_thread() is threading.main_thread()
        old = {g: signal.signal(g, _stop) for g in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)} if main else {}
        try:
            while time.monotonic() < end:
                if STOP_SIG[0] or (lane is not None and lane.cancelled):
                    return None
                time.sleep(min(0.2, end - time.monotonic()))
        except _Stopped as e:
            sess.first_sig, sess.reattach_stopped = sess.first_sig or e.signum, True
            note("%sstopped while reconnecting to %s; the command there is cancelled within %s"
                 % (sess.tag, label(h), fmt_wait(float(cfg.get("rr_detach_hb_s", 180)))))
            return None
        finally:
            for g, hd in old.items():
                signal.signal(g, hd)
        n += 1
        note("%slost the link to %s mid-run; reconnecting (%d of %d) - the command keeps running there"
             % (sess.tag, label(h), n, tries))
        a = Session(cfg, attach_frames(sess.run_id, sess.nonce, prev.out_off, prev.err_off), sess.nonce,
                    sess.timing)
        for k in ("host_name", "tag", "timeout_s", "silent_s", "stdout_out", "stderr_out", "run_id",
                  "out_off", "err_off", "started", "last_out"):
            setattr(a, k, getattr(prev, k))
        a.ready = a.go_sent = True           # GO went long ago: never again
        a.mux = False
        if lane is not None and not lane.bind(a):
            return None
        a.final_rc = a.run()
        if a.first_sig and a.exit_rc is None:   # cancelled while attached (checked before NORUN):
            sess.first_sig, sess.reattach_stopped = sess.first_sig or a.first_sig, True   # a stop
            return None
        if a.exit_rc is not None or a.norun or a.gone or a.timed_out:
            return a
        if a.aborted:
            return None
        total += 1
        if a.attached and a.out_off + a.err_off > prev.out_off + prev.err_off and total < REATTACH_MAX:
            n, deadline = 0, time.monotonic() + window   # it moved the output on, then dropped again
        prev = a
    return None


# ---------------------------------------------------------------------------- copy-back

COPY_BACK_TIMEOUT_S = 600


def copy_back(cfg, wt, outputs):
    """Fetch the build outputs from the worker's mirror (a second ssh: tar on stdout) and swap
    them into the worktree. -> None on success, else why it failed (the worktree is untouched).
    COPYFILE_DISABLE: a macOS worker's bsdtar would add AppleDouble ._ members (GNU tar ignores it)."""
    mirror = "%s/w2/%s-%s" % (rr_root(cfg), wt["slug"], wt["wt12"])   # rr_runner.pl prepare_mirror
    script = ('cd "$HOME"/%s || exit 66; set --; for p in %s; do '
              '[ -e "$p" ] && [ ! -L "$p" ] && set -- "$@" "$p"; done; '
              '[ $# -gt 0 ] || exit 67; COPYFILE_DISABLE=1 exec tar -cf - -- "$@"'
              % (shlex.quote(mirror), " ".join(shlex.quote(o) for o in outputs)))
    try:
        p = subprocess.run(["ssh", "-T"] + ssh_opts() + [cfg["host"], script], stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=COPY_BACK_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as e:
        return str(e)
    if p.returncode == 67:
        note("the build produced none of %s; nothing copied back" % ", ".join(outputs))
        return None
    if p.returncode != 0:
        return p.stderr.decode("utf-8", "replace").strip()[-200:] or "exit %d" % p.returncode
    try:
        n = extract_outputs(wt["top"], p.stdout, outputs)
    except (RunError, OSError, tarfile.TarError) as e:
        return str(e)
    note("copied back %s (%d files)" % (", ".join(outputs), n))
    return None


def extract_outputs(top, data, outputs):
    """Unpack a tar of `outputs` into a staging dir inside the worktree, then rename each output
    into place (the old one is moved aside first and deleted). Only regular files and dirs under a
    declared output are accepted; anything else refuses the whole copy. -> files written."""
    import shutil
    import tempfile
    rtop = os.path.realpath(top)
    for o in outputs:            # the destination's parents must be real dirs inside the worktree
        parent = os.path.realpath(os.path.join(top, os.path.dirname(o)))
        if not inside(parent, rtop):
            raise RunError("output %s resolves outside this worktree" % o)
    stage = tempfile.mkdtemp(prefix=".rrun-out-", dir=top)
    n = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as t:
            for m in t:
                name = m.name[2:] if m.name.startswith("./") else m.name
                name = name.rstrip("/")
                if not sane_rel(name) or not any(name == o or name.startswith(o + "/") for o in outputs):
                    raise RunError("unexpected path in the outputs: %r" % m.name)
                dest = os.path.join(stage, name)
                if m.isdir():
                    os.makedirs(dest, exist_ok=True)
                elif m.isreg():
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    with open(dest, "wb") as f:
                        shutil.copyfileobj(t.extractfile(m), f)
                    os.chmod(dest, 0o755 if m.mode & 0o100 else 0o644)
                    n += 1
                else:
                    raise RunError("refusing %s in the outputs (only files and dirs)" % m.name)
        for k, o in enumerate(outputs):
            new, dst = os.path.join(stage, o), os.path.join(top, o)
            if not os.path.lexists(new):
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.lexists(dst):
                os.rename(dst, os.path.join(stage, ".old-%d" % k))
            os.rename(new, dst)
    finally:
        shutil.rmtree(stage, True)
    return n
