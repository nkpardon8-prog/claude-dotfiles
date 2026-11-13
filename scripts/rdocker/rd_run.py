"""rdocker rd_run: `rrun <cmd...>` - run a heavy job (test runner + its DB) ON the Mac mini.

Laptop side of the rrun plan (Revision 3/3.1); the mini side is rr_runner.pl, which this module
SENDS with every run (nothing trusted is kept on the mini). One run:
  1 resolve the git worktree of cwd: repo slug (from the git common dir), wt12, relcwd, HEAD sha
  2 hold the worktree (take_wt_lanes): the gate STATE_DIR/rrun-<wt12>.gate shared + the first free lane
    k = flock STATE_DIR/rrun-<wt12>[.<k>].lock, so up to fleet.json wt_lanes (3) runs of one laptop
    worktree go at once, each with its own worker mirror and push ref (lane_mirror_id); more poll for a
    lane (exit 72 past the wait). Builds with copy-back and every local run (fallback exec, local shard)
    write into the worktree: they hold the gate exclusive and run alone. The mode is chosen once per run;
    a shared run never runs a shard locally (exit 75 for that shard instead)
  3 git push HEAD -> ~/<rr_root>/git/<slug>.git refs/rrun/<lane id> over the rr-%C ssh master (one push
    per worker at a time from this Mac: push_lock, cross-process - the base refs are shared); the
    remote receive-pack creates the bare repo the first time. Push fails => the mini is out =>
    run locally (RDOCKER_MODE=local), unless RRUN_STRICT=1 (exit 75: infra, never ran)
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
    started (a loss before the start). Every reconnect failed => exit 76 (may have run; never run twice).
Result contract (2026-11-11): every job's result is one class - pass / fail / infra / needs-human -
named by ONE `rrun:` line after the command's output (rrun() / result_line); rrun's own codes are
EXIT_CODES (72 / 73 / 75 never ran, 76 may have run, 77 config, 124 cap, the runner's 65 / 69 / 70 /
78). A run whose output shows a missing test DB is infra (75), not a test failure.
Eligibility (rd_pool.eligibility, fleet.json classes / max_cost_s / cold_ok): a worker that may not
take the job is never tried; none may => exit 77 at once, naming each worker's reason.
Pool (rd_pool): with 2+ enabled fleet workers, each job is placed on the best worker right now
and the hosts are tried in that order: a worker lost before GO, or one that had no free slot after
all (73 from a short race wait), moves the job to the next one. After GO a lost worker means exit 76
- except for jobs that are safe to repeat (tsc/typecheck, lint, vitest/jest, builds; never DB
tests), which run once more on the next worker. In a pool, heavy and DB jobs never fall back to
this machine (exit 75 instead); light jobs (lint, check scripts) run here when every worker stayed
busy for rr_local_after_s. No fleet / one worker: one host, exactly as before.
Shards (run_shards): a `vitest run` rd_pool.shardable() accepts, with 2+ free workers, runs as
vitest --shard=i/n on several workers at once (threads; signals forwarded from the main thread to
every LIVE session), each with its own failover list, output prefixed "[shard i/n host]", rc =
shards_rc() (the test result when every shard ran), a merged summary at the end; RRUN_SHARD=0 off, =n forced. Hedge (default off, RRUN_HEDGE=1):
a tsc/lint/vitest run past 2x its expected time gets one duplicate on a free worker with a 3x better
eta; the first to finish wins, the other is stopped. A second concurrent run of ours on one worker
uses its own lane mirror (Lane), so runs never share a checkout.
Builds (`npm run build` in a package dir mapped by rr_outputs) copy their outputs back: after a
successful run a second ssh streams `tar` of the outputs from the worker's mirror, extracted into
the worktree (staged, then renamed into place) while the worktree's gate is still held exclusive.
Hangs / waits (2026-11-11): the runner relays the command's output through its own pipes, so when the
main process exits the leftovers get rr_exit_grace_s, then the group is TERMed / KILLed and the run
ends with the main's rc. A hard cap per job class (rr_timeout_min; RRUN_TIMEOUT=<min|0>) ends a run
with exit 124; silence only prints "no output for N min" with the last test file the output named
(rr_silent_min; RRUN_SILENT_MIN). A slot
wait on one worker lasts rr_slot_wait_s, then host_loop re-plans (rr_wait_min in all -> 73); the
worktree-lane wait is at most the job's cap (-> 72). Slot / lane waits print a line every
rr_status_every_s. Every job carries owner_info() (session id / parent pid, /line caption, host):
`rrun --jobs` / `--mine` list them from every worker's slots/<i>.own.
Fast start: route.log gets every job's client stage timings (Timing / STAGES: cache plan push overlay
remote start), pred_s and the client sha; a worker cold for the job triggers one background warm
(trigger_warm). Version (VERSION / version_seen): the runner's first status, before any prepare, is the
worker's pool_version (PV, "?" = unknown); newer or unknown never blocks the job: it runs and ends with
one line saying this Mac is behind (the 2-minute dotfiles autopull updates it).
Config: rr_* keys in rd_common.DEFAULTS. Env: RRUN_STRICT=1, RRUN_TIMING=1, RRUN=0 (run locally),
RRUN_TIMEOUT=<minutes|0>, RRUN_SILENT_MIN=<minutes|0>,
RRUN_GIT_URL (tests only: push URL override). Flags (the `rrun` wrapper turns them into env):
--where (RRUN_WHERE=1: print the placement, run nothing), --bench (RRUN_BENCH=1), --host NAME
(RRUN_HOST: only that worker), --outputs a,b (RRUN_OUTPUTS: build outputs, relative to the cwd).
Cache (rd_cache): a one-shot tsc / eslint / vitest / jest run or a known test / typecheck / lint npm
script whose shipped code + command match a recent run replays that run's output and exit code
(passes 24 h, failures 20 min); RRUN_CACHE=0 always runs (and saves the fresh result). Looked up
after a worktree lane is taken: a run that waited for a lane gets the result of one that finished
meanwhile (two identical runs on two lanes at once both miss this tier; the pool tier's singleflight
below still makes the second wait for the first when the pool key is set). Then the
pool tier (rd_cache, home worker): looked up through the placement probe; an identical run in flight
elsewhere is waited for (wait_inflight) and replayed; a result is shared after it is printed
(share_after). RRUN_CACHE=0 skips the pool tier entirely.
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
import rd_pnpm
import rd_pool

HEARTBEAT_S = 15
# rr ssh keepalives (all rrun ssh share one rr-%C master, so these are the master's): a worker that
# vanishes (lid closed, Wi-Fi gone) is noticed after ~15-20 s instead of ~45. sshd answers them from
# its own process, so a worker busy at 100% CPU still answers; a relayed (DERP) link adds ~0.3 s.
ALIVE_INTERVAL_S, ALIVE_COUNT = 5, 3
CONNECT_TIMEOUT_S = 6          # a cold master over a DERP relay connects in ~1.5-2.5 s
OVERLAY_WARN_BYTES = 5 * 1024 * 1024
# ---- the agent contract (2026-11-11): every rrun result is exactly one class, named by the first
# `rrun:` line after the command's output: pass / fail (the command's own result: fix the code) /
# infra (rerun, never debug) / needs-human (who and why). rrun's own exit codes (EXIT_CODES below;
# docs: commands/docker.md "Exit codes", tests/test_contract.py checks both ways):
EXIT_NEVER_RAN = 75            # infra: the command never started anywhere (no worker, lost before GO, strict)
EXIT_MAY_HAVE_RUN = 76         # infra: it started, then its result was lost (link, spool, copy-back)
EXIT_CONFIG = 77               # needs-human: no worker may take it (fleet.json)
EXIT_BUSY = 73                 # infra: every worker stayed busy (never ran)
PUSH_TIMEOUT_S = 300            # rr_push_timeout_s: a git push that hangs longer = that worker is out
EXIT_WT_BUSY = 72              # this worktree stayed busy (lanes / its gate) past our wait
EXIT_TIMEOUT = 124             # like timeout(1): the command ran past its wall-clock cap and was killed
EXIT_CODES = {                 # code -> (class, meaning): the one table the docs and the test follow
    EXIT_WT_BUSY: ("infra", "this worktree stayed busy (its lanes, or a run writing into it) past the wait; never ran"),
    EXIT_BUSY: ("infra", "every worker stayed busy; never ran"),
    EXIT_NEVER_RAN: ("infra", "never ran: no worker reachable / lost before the start / RRUN_STRICT"),
    EXIT_MAY_HAVE_RUN: ("infra", "may have run: the link or the result was lost after the start"),
    EXIT_CONFIG: ("needs-human", "no worker may take this job (fleet.json)"),
    EXIT_TIMEOUT: ("infra", "hit its wall-clock cap (RRUN_TIMEOUT) and was killed"),
    65: ("needs-human", "the worker refused the request (bad input or an unsafe path)"),
    69: ("infra", "the repo was missing on the worker; never ran"),
    70: ("infra", "the worker's runner failed; never ran"),
    78: ("infra", "installing dependencies on the worker failed; never ran"),
    79: ("fail", "the DB lane's setup step (migrate / provision) failed on the worker; the command was not started"),
}
NEXT = {"pass": "", "fail": "the command's own result: fix the code",
        "infra": "rerun it; never debug it", "needs-human": "tell the owner; rerunning will not help"}


class Rc(int):
    """An exit code rrun decided itself (not the command's), with its contract class and why."""

    def __new__(cls, code, klass=None, why="", nxt=None):
        o = int.__new__(cls, code)
        o.klass = klass or EXIT_CODES.get(code, ("infra", ""))[0]
        o.why = why or EXIT_CODES.get(code, ("", ""))[1]
        o.next = nxt if nxt is not None else NEXT[o.klass]
        return o


def infra(code, why, nxt=None):
    return Rc(code, "infra", why, nxt)


def stopped(sig):
    return Rc(128 + sig, "infra", "stopped by signal %d before it finished" % sig,
              "rerun it if you still need the result")


RESULT = {"job": False, "host": None, "secs": None, "after": []}   # for result_line()


def result_class(rc):
    """-> (class, why, next) of a finished rrun: Rc carries its own; a plain int is the command's."""
    if isinstance(rc, Rc):
        return rc.klass, rc.why, rc.next
    return ("pass" if rc == 0 else "fail"), "", NEXT["pass" if rc == 0 else "fail"]


def result_line(rc):
    """The one line that classifies the result (printed first after the command's output)."""
    klass, why, nxt = result_class(rc)
    where = (" from the cache" if RESULT.get("host") == "cache" else " from the pool cache"
             if RESULT.get("host") == "pcache" else
             " on %s" % RESULT["host"] if RESULT.get("host") not in (None, "none") else "")
    secs = ", %.0fs" % RESULT["secs"] if isinstance(RESULT.get("secs"), (int, float)) else ""
    head = "rrun: %s (exit %d%s%s%s)" % (klass, int(rc), where, secs, "; " + why if why else "")
    return head + (" - " + nxt if nxt else "")
# the runner's own cap is what ends a run; this side only steps in (kills ssh, exit 124) when the
# worker has said nothing about it this long after the cap, e.g. a wedged runner
TIMEOUT_MARGIN_S = 90
# the runner prints "<nonce> EXIT <rc>" only after the command's leftovers are gone (rr_exit_grace_s,
# then TERM/KILL of its group); if ssh is still open this long after that, we stop waiting for it
EXIT_BACKSTOP_S = 45
NAME_RE = re.compile(r"[^A-Za-z0-9._-]")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
HELD_LOCKS = []                # worktree lane fds: made inheritable only for a local-fallback exec
LIVE, LIVE_LOCK = set(), threading.Lock()   # running Sessions (shard mode forwards signals to them)
STOP_SIG = [0]                 # shard mode: the first INT/TERM/HUP (later sessions start stopped)
ABORT_KILL_S = 15              # an aborted session's ssh is killed if still there after this

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


class PolicyRefused(RunError):
    """A policy repo (rd_pnpm.repo_policy) would ship an env file with this push => needs-human, never local."""


# ---------------------------------------------------------------------------- small helpers

def note(msg):
    sys.stderr.write("rrun: " + msg + "\n")
    sys.stderr.flush()


def git_out(args, cwd, check=True):
    """-> stdout bytes of `git <args>` in cwd (RunError when check and git fails). Read-only: with
    GIT_OPTIONAL_LOCKS=0 git never takes the worktree's index.lock to refresh the index, so concurrent
    rruns of one worktree (lanes) and the agent's own `git add` / `commit` never trip on each other."""
    p = subprocess.run(["git"] + list(args), cwd=cwd, capture_output=True,
                       env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
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


def wt_lock_path(wt12, k=0):
    """Worktree lane k's lock file. Lane 0 keeps the pre-lanes name rrun-<wt12>.lock (rd_warm waits on /
    skips it; an older client still running during a rollout locks only that one)."""
    return os.path.join(rd_common.STATE_DIR, "rrun-%s.lock" % wt12 if k == 0 else "rrun-%s.%d.lock" % (wt12, k))




def lane_mirror_id(wt12, k, n=0):
    """The worker mirror / push-ref id (12 hex, the shape rd_janitor reaps: mirror <slug>-<id> and its
    ref refs/rrun/<id>) of worktree lane k (concurrent rruns of one worktree, take_wt_lanes) and process
    lane n (a second run of this process on one worker: a shard, a hedge; take_lane). (0, 0) is the
    worktree's own mirror; (0, n) keeps the pre-lanes shard shape. Every pair gets its own id, so no two
    runs ever share a checkout, an env list or a ref."""
    if k == 0:
        return wt12 if n == 0 else short_hash("%s:lane%d" % (wt12, n), 12)
    return short_hash("%s:wt%d" % (wt12, k) if n == 0 else "%s:wt%d:lane%d" % (wt12, k, n), 12)


class WorktreeBusy(Exception):
    """Other rruns from this worktree kept its lanes past our wait (exit EXIT_WT_BUSY)."""


# This process's hold on its worktree (one rrun per process; shard threads share it): wt12, the gate fd and
# its mode (None = not held / "sh" / "ex"), the lane fds {k: fd}, the lane count, the wait budget and config.
# The mode is set ONLY by take_wt_lanes, once per run, and never converted while held: no downgrade, no
# in-place upgrade, no "temporarily unlocked" state while work is in flight. A sharded run in "sh" never runs
# a shard on this machine (run_local_shard); the one hand-over is own_worktree (see there).
WT = {"wt12": None, "gate": None, "mode": None, "held": {}, "n": 1, "wait_s": None, "cfg": None}
_WT_LOCK = threading.RLock()


def wt_gate_path(wt12):
    """The worktree's gate: every pool job holds it shared (LOCK_SH) for its whole run; a run that writes
    into the worktree (a build that copies outputs back, any local fallback) holds it exclusive. Separate
    from the lanes, so exclusivity never depends on fleet.json wt_lanes (which may change mid-run)."""
    return os.path.join(rd_common.STATE_DIR, "rrun-%s.gate" % wt12)


def _flock_nb(fd, how):
    import fcntl
    try:
        fcntl.flock(fd, how | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def _hold(fd):
    HELD_LOCKS.append(fd)
    return fd


def _drop(fd):
    if fd in HELD_LOCKS:
        HELD_LOCKS.remove(fd)
    try:
        os.close(fd)
    except OSError:
        pass


def lanes_busy(wt12, n):
    """How many of the worktree's n lanes are held right now (a probe: take and drop each free one)."""
    import fcntl
    busy = 0
    for k in range(n):
        fd = os.open(wt_lock_path(wt12, k), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            if _flock_nb(fd, fcntl.LOCK_EX):
                fcntl.flock(fd, fcntl.LOCK_UN)
            else:
                busy += 1
        finally:
            os.close(fd)
    return busy


def _wait_line(wt12, n, exclusive, writer, waited):
    if exclusive:
        why = "this run writes into the worktree (a build copying outputs back, or a run on this machine), so " \
              "it waits until no other rrun from this worktree runs"
    elif writer:
        why = "another rrun is writing into this worktree (a build copying outputs back, or a run on this " \
              "machine) and runs alone"
    else:
        why = "this worktree runs at most %d rrun job%s at once (fleet.json wt_lanes); %d running" % (
            n, "" if n == 1 else "s", lanes_busy(wt12, n))
    return "%s; waited %s%s" % (why, fmt_wait(waited), wt_holder(wt12))


def take_wt_lanes(wt12, wait_s=None, cfg=None, exclusive=False):
    """Hold this worktree for one run. A pool job: the gate shared + the first free lane of fleet.json
    wt_lanes (default 3) - nonblocking flocks, polled with backoff (0.1 s up to 1 s), so up to that many
    runs of one worktree go at once, each with its own worker mirror and push ref (lane_mirror_id). An
    exclusive run (it writes into the worktree): the gate exclusive + lane 0 (the lock rd_warm and an older
    client take; its mirror is the one used). A waiting run says why, how many run and how long it has
    waited, every rr_status_every_s (quiet for the first second). No queue: a writer can be starved by a
    stream of jobs - bounded by wait_s, then WorktreeBusy (exit 72). Locks die with the process; lock files
    are never unlinked (a waiter would lock a deleted inode). The fds are not inheritable (git's ssh may
    fork a ControlPersist master); run_local makes them inheritable for its exec. -> the lanes held."""
    import fcntl
    import rd_fleet
    cfg = cfg or rd_common.load_cfg()
    n = rd_fleet.wt_lanes(cfg)
    rd_common.ensure_dirs()
    with _WT_LOCK:
        if WT["mode"] is not None:       # a held gate is never converted (see WT)
            raise RuntimeError("take_wt_lanes: this process already holds its worktree (%s)" % WT["mode"])
        WT.update(wt12=wt12, n=n, wait_s=wait_s, cfg=cfg)
    every = float(cfg.get("rr_status_every_s", 60) or 60)
    t0 = time.monotonic()
    said, nap = None, 0.1
    while True:
        gate = os.open(wt_gate_path(wt12), os.O_RDWR | os.O_CREAT, 0o600)
        writer = False
        if _flock_nb(gate, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH):
            lanes = [0] if exclusive else range(n)
            for k in lanes:
                fd = os.open(wt_lock_path(wt12, k), os.O_RDWR | os.O_CREAT, 0o600)
                if _flock_nb(fd, fcntl.LOCK_EX):
                    with _WT_LOCK:
                        WT.update(gate=_hold(gate), mode="ex" if exclusive else "sh")
                        WT["held"][k] = _hold(fd)
                    return sorted(WT["held"])
                os.close(fd)
        else:
            writer = not exclusive
        os.close(gate)                   # never wait while holding the gate: a writer must get in
        now = time.monotonic()
        if wait_s is not None and now - t0 >= wait_s:
            raise WorktreeBusy("%s after %s%s" % (
                "other rruns from this worktree kept running" if exclusive else
                "a run writing into this worktree kept it" if writer else
                "other rruns from this worktree kept all %d of its lanes" % n, fmt_wait(wait_s), wt_holder(wt12)))
        if (said is None and now - t0 >= 1.0) or (said is not None and now - said >= every):
            note("%s for this worktree: %s; gives up after %s (exit 72)" % (
                "waiting" if said is None else "still waiting", _wait_line(wt12, n, exclusive, writer, now - t0),
                fmt_wait(wait_s) if wait_s else "never"))
            said = now
        time.sleep(nap)
        nap = min(1.0, nap * 1.5)


def release_wt_lanes():
    """Drop this process's gate and lanes."""
    with _WT_LOCK:
        for fd in WT["held"].values():
            _drop(fd)
        WT["held"].clear()
        if WT["gate"] is not None:
            _drop(WT["gate"])
        WT.update(gate=None, mode=None)


def wt_lane():
    """The worktree lane this process runs on (0 when none is held)."""
    return min(WT["held"]) if WT["held"] else 0


def own_worktree(argv, t0):
    """Before the local fallback exec (it writes into the worktree): hold the gate exclusive. Not a mode
    change of a running run but a hand-over between two runs: it is called only from the main thread once
    the pool attempt is over (host_loop returned; no session in flight - else refused), the pool run's lane
    and shared gate are released, and the local run takes the exclusive gate from scratch (wait_s, as any
    run) and keeps it until exec ends. Nothing reads or ships the worktree in between. -> None when held
    (or no worktree is held at all), else Rc: 72 (logged to route.log with its wait in lock_s, never as a
    local exec), or 75 when sessions still run."""
    with _WT_LOCK:
        if WT["mode"] in (None, "ex"):
            return None
        with LIVE_LOCK:
            live = bool(LIVE)
        if live or threading.current_thread() is not threading.main_thread():
            record("none", argv, EXIT_NEVER_RAN, time.monotonic() - t0)
            return infra(EXIT_NEVER_RAN, "a run of this invocation is still in flight; not running it on this "
                         "machine as well")
        wt12, wait_s, cfg = WT["wt12"], WT["wait_s"], WT["cfg"]
        release_wt_lanes()
    t = time.monotonic()
    try:
        take_wt_lanes(wt12, wait_s, cfg, exclusive=True)
    except WorktreeBusy as e:
        add_stage("lock_s", time.monotonic() - t)
        record("none", argv, EXIT_WT_BUSY, time.monotonic() - t0)
        return infra(EXIT_WT_BUSY, "%s; running it on this machine needs the worktree to itself; never ran" % e,
                     "check `rrun --mine`; rerun when it is done")
    add_stage("lock_s", time.monotonic() - t)
    return None


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
    env_file_guard(cfg, wt, base)        # rrun and rd_warm both push here: nothing ships past it
    limit = float(cfg.get("rr_push_timeout_s", PUSH_TIMEOUT_S) or PUSH_TIMEOUT_S)
    try:
        with push_lock(cfg["host"], limit):
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
    file inside the worktree (e.g. a symlink to ~/secrets/.env) is skipped with a notice; 0600.
    A repo under an rr_pg_lanes policy (rd_pnpm.repo_policy) ships NO env file at all, allowlisted or
    not: every .env* path (rd_pnpm.is_env_file) is left out of the overlay here, the one place rrun,
    the cache key and rd_warm all build it (a tracked one is refused at the push: env_file_guard)."""
    policy = rd_pnpm.repo_policy(cfg, top)
    if policy:
        env_dirs = ()
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
    if policy:
        files = [f for f in files if not rd_pnpm.is_env_file(f)]
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
    """Where env files are picked up for a run: the repo root, the cwd and the deps dirs (none in a
    policy repo: build_overlay)."""
    return list(dict.fromkeys([""] + ([wt["relcwd"]] if wt["relcwd"] else []) + list(deps)))


_DROP_NOTED = set()


def ship_env(cfg, env_pairs, top=None):
    """The env dict a runner header carries: rr_env_pass matches from our env, then -e pairs. In a
    policy repo (rd_pnpm.repo_policy) no *DATABASE_URL* / PG* name and no strip_env glob ever leaves
    this machine (only the runner sets the DB URLs); the dropped NAMES are noted, never the values."""
    env = {k: v for k, v in os.environ.items()
           if any(fnmatch.fnmatchcase(k, g) for g in cfg.get("rr_env_pass") or [])}
    env.update(env_pairs)
    policy = rd_pnpm.repo_policy(cfg, top) if top else None
    if policy:
        drop = sorted(k for k in env if policy_drops(policy, k))
        if drop and tuple(drop) not in _DROP_NOTED:
            _DROP_NOTED.add(tuple(drop))                       # once per run (the cache key builds it too)
            note("not forwarding %s: this repo's database URLs are set by rrun only, and its provider "
                 "secrets never leave this machine" % ", ".join(drop))
        env = {k: v for k, v in env.items() if k not in drop}
    return env


def policy_drops(policy, name):
    """A name the repo policy never forwards (the runner applies the same rule: rr_runner.pl policy_env)."""
    return bool(re.search(r"DATABASE_URL", name, re.I) or re.match(r"^PG", name, re.I)
                or any(fnmatch.fnmatchcase(name, g) for g in policy.get("strip_env") or []))


def env_file_guard(cfg, wt, base):
    """Raise PolicyRefused before a policy repo's push when an env file (rd_pnpm.is_env_file) is in the
    index, in the commit being pushed (`git ls-tree -r`) or in any base commit pushed with it. The
    working tree's untracked / ignored ones never ship (build_overlay). Limit, documented: older commits
    reachable from those are not scanned - their blobs can reach our own worker's bare repo; the
    guarantee is that no env file is ever in a worker's checkout or sourced there."""
    if not rd_pnpm.repo_policy(cfg, wt["top"]):
        return
    where = {}
    for f in zsplit(git_out(["ls-files", "-z", "--", ":(glob)**/.env*"], wt["top"])):
        where.setdefault(f, "the index")
    for rev in [wt["sha"]] + [spec.lstrip("+").split(":", 1)[0] for spec in base]:
        for f in zsplit(git_out(["ls-tree", "-r", "-z", "--name-only", rev], wt["top"])):
            where.setdefault(f, rev[:12])
    bad = sorted(f for f in where if rd_pnpm.is_env_file(f))
    if bad:
        raise PolicyRefused("this repo tracks env file(s) %s (%s); its pool runs never ship one (rr_pg_lanes "
                            "policy)" % (", ".join(bad[:5]), ", ".join(sorted({where[f] for f in bad}))))


def argv_refusal(cfg, wt, argv):
    """-> Rc 65 (needs-human) when a policy repo's argv carries, ANYWHERE inside any token, an assignment
    to a name the policy never forwards (`env -S 'X=1 DATABASE_URL=...'`, `sh -c "TWILIO_X=..."`), or an
    `env` wrapper with any option; else None. Only names are printed."""
    policy = rd_pnpm.repo_policy(cfg, wt["top"]) if wt else None
    if not policy:
        return None
    globs = "|".join(re.escape(g).replace(r"\*", r"\w*") for g in policy.get("strip_env") or [])
    rx = re.compile(r"(^|[\s'\"])(\w*DATABASE_URL\w*|PG\w*|TWILIO_\w*|RETELL_\w*|OPENROUTER_\w*|SEED_ALLOW_REMOTE"
                    + ("|" + globs if globs else "") + r")=", re.I)
    names = sorted({m.group(2) for a in argv for m in rx.finditer(a)})
    env_opt = any(os.path.basename(a) == "env" and argv[i + 1:i + 2] and argv[i + 1].startswith("-")
                  for i, a in enumerate(argv))
    if not names and not env_opt:
        return None
    what = ("sets %s" % ", ".join(names)) if names else "runs `env` with an option"
    return Rc(65, "needs-human", "the command %s; in this repo only rrun sets database URLs and no provider "
              "secret is sent to a worker; not run" % what, "drop it from the command; rerunning as is will "
              "not help")


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
    env = ship_env(cfg, env_pairs, wt["top"])
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
    """npm's lockfile, or pnpm's (the runner installs that with pnpm via corepack, rr_runner.pl deps)."""
    return any(os.path.isfile(os.path.join(d, n)) for n in ("package-lock.json", "npm-shrinkwrap.json", rd_pnpm.LOCK))


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


def take_lane(host_key):
    with _LANES_LOCK:
        used = _LANES.setdefault(host_key, set())
        n = next(k for k in range(len(used) + 1) if k not in used)
        used.add(n)
        return n


def drop_lane(host_key, n):
    with _LANES_LOCK:
        _LANES.get(host_key, set()).discard(n)


class push_lock:
    """One git push at a time per worker from this Mac, across processes and threads (a flock on
    STATE_DIR/push-<host>.lock; flock binds the open file, so two fds of one process exclude each other
    too). Concurrent worktree lanes, shards, hedges and rd_warm all push the same base-branch refs, and
    parallel pushes of one ref fail on its ref lock. Waits at most wait_s (the push timeout), then raises
    RunError - never a push without the lock: the attempt fails like an unreachable worker (next worker,
    or infra) instead."""

    def __init__(self, host_key, wait_s=PUSH_TIMEOUT_S):
        self.path = os.path.join(rd_common.STATE_DIR, "push-%s.lock" % NAME_RE.sub("_", str(host_key))[:80])
        self.host, self.wait_s, self.fd = host_key, wait_s, None

    def __enter__(self):
        import fcntl
        rd_common.ensure_dirs()
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        end = time.monotonic() + self.wait_s
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.monotonic() >= end:
                    os.close(self.fd)
                    raise RunError("another push to %s from this Mac did not finish in %d s"
                                   % (self.host, self.wait_s))
                time.sleep(0.05)

    def __exit__(self, *exc):
        os.close(self.fd)
        return False


# ---------------------------------------------------------------------------- remote session

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
# a test file the output names (vitest / jest per-file lines and any *.test.* / *.spec.* path)
TEST_FILE_RE = re.compile(r"(?:^|[\s(])((?:[\w@.-]+/)*[\w@.-]+\.(?:test|spec)\.[cm]?[jt]sx?)\b", re.M)
# the run had no test database (2026-11-11: a sharded server vitest run on workers without one -
# 2,500 of 2,868 "failures" were this): Prisma's / a setup's missing DATABASE_URL, or a refused
# connection to a Postgres / MySQL port
NO_DB_RE = re.compile(r"Environment variable not found: (?:TEST_)?DATABASE_URL|(?:TEST_)?DATABASE_URL (?:is )?"
                      r"not (?:found|set|defined)|ECONNREFUSED (?:127\.0\.0\.1|::1|\[::1\]|localhost|0\.0\.0\.0)"
                      r":(?:5432|54\d\d|55\d\d\d|3306)\b")


class StatusFilter:
    """Remote stderr -> our stderr, minus our own "<nonce> STATUS" lines. The tag is recognised
    anywhere, also glued to the end of a stderr line that had no newline (the nonce is 128 secret
    bits the tested code never sees, so it cannot be forged or hit by chance). Only a tail that
    could still be the start of the tag is held back, so progress output streams."""

    on_text = None       # the command's own bytes, for Session.scan (set after construction)

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
            if own and self.on_text is not None:
                self.on_text(data)
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
        self.last_file = None                # the last test file the output named (silence line)
        self.last_file_at = None             # monotonic time it was named
        self.scan_tail = {}                  # per stream: a line cut by a read boundary
        self.no_db_n = 0                     # lines of the command's output with the missing-test-DB signature
        self.worker_pv = None                # "<nonce> PV <n>": the worker's pool_version (before any prepare)
        self.node_major = None               # "<nonce> NODE <major|?>": the node this run really uses
        self.outdated = None                 # that version, when it is newer than ours: never GO

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
        if self.waits > 1:                  # one short line a minute after the first: no repeated banner
            short = [x for x in parts if x.startswith(("next in line", "expected wait", "a slot is due"))
                     or " waiting ahead" in x]
            note("%sstill waiting for a slot on %s (%s so far; %s)" % (self.tag, self.where(), fmt_wait(waited),
                                                                     "; ".join(short)))
            return
        note("%swaiting for a slot on %s: %s; tries elsewhere after %s" % (self.tag, self.where(), "; ".join(parts),
                                                                          fmt_wait(slot_wait_min(self.cfg) * 60)))

    def saw_output(self):
        self.last_out = time.monotonic()
        self.silent_said = 0

    def scan(self, data, key="out", final=False):
        """The command's output -> the last test file it named (vitest/jest per-file lines: "✓ path",
        "❯ path", "× path", "RUN path", "PASS path", "FAIL path", or any *.test.* / *.spec.* path) and
        how many lines carry the missing-test-DB signature (an advisory hint at the end, never a
        verdict). stdout is only ever the command's (the runner writes nothing there), so it is
        scanned from its first byte, whatever order STARTED arrives in on stderr; stderr only after
        STARTED (before it: the runner's own prepare notes - same stream, so in order). final: the
        stream ended - its last line, even without a newline, counts too."""
        if key == "err" and self.started is None:
            return
        text = (self.scan_tail.get(key, b"") + (data or b""))[-65536:]
        cut = len(text) - 1 if final else text.rfind(b"\n")
        self.scan_tail[key] = b"" if final else (text[cut + 1:][-4096:] if cut >= 0 else text[-4096:])
        chunk = text[:cut + 1] if cut >= 0 else b""
        if not chunk:
            return
        s = _ANSI_RE.sub("", chunk.decode("utf-8", "replace"))
        files = TEST_FILE_RE.findall(s)
        if files:
            self.last_file, self.last_file_at = files[-1], time.monotonic()
        self.no_db_n += sum(1 for ln in s.splitlines() if NO_DB_RE.search(ln))

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
                last = (("; last test file %s, named %s ago" % (self.last_file, fmt_min(now - self.last_file_at)))
                        if self.last_file else "")
                note("%sno output for %s (worker %s, running %s%s)"
                     % (self.tag, fmt_min(quiet), self.host_name or "mini", fmt_min(ran), last))
        if self.timeout_s and not self.timed_out and ran > self.timeout_s + TIMEOUT_MARGIN_S:
            self.timed_out = True
            note("%s%s did not stop the command at its %s cap; closing the session (exit %d)"
                 % (self.tag, self.where(), fmt_min(self.timeout_s), EXIT_TIMEOUT))
            self.abort()

    def on_status(self, line):
        word, _, rest = line.partition(" ")
        if word == "READY":
            self.timing.mark("remote prepare (checkout, overlay, deps, slot)", "remote_s")
            if self.on_ready is not None:
                self.on_ready()
            self.ready = True
            self.wake.set()
        elif word == "STARTED":
            self.started = time.monotonic()
            self.timing.started()
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
        elif word == "SLOT":             # the runner's own slot wait (taken, or given up: BUSY follows)
            try:
                add_stage("slot_s", float(rest.strip()))
            except ValueError:
                pass
        elif word == "UNAVAIL":
            self.unavail = rest.strip() or "unavailable"
        elif word == "NODE":
            v = rest.strip()
            self.node_major = v if v.isdigit() else None
        elif word == "PV":
            v = rest.strip()
            self.worker_pv = int(v) if v.isdigit() else None       # "?" = unknown: proceed, warn at the end
            if version_seen(self.worker_pv):
                with self.go_lock:
                    self.outdated = self.worker_pv                 # claim_go refuses: the invocation restarts
                self.wake.set()
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
            if self.done.is_set() or not self.ready or self.go_sent or self.ints or self.gave_up \
                    or self.outdated is not None:
                return False
            self.go_sent = True              # from here on, any loss is ambiguous => 75
            mark_started()
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
                    elif self.aborted:       # our own decision (a hedge / shard went elsewhere): runs.log "moved"
                        w.write(b"MOVE\n")
                        w.flush()
                    break
                if self.outdated is not None and not self.go_sent:
                    break                    # closing stdin before GO: the runner starts nothing
                left = self.give_up_left()
                if left == 0:
                    w.write(b"MOVE\n")      # re-planned (another worker / this machine): "moved", not abandoned
                    w.flush()
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
            self.scan(data)
        self.scan(b"", "out", final=True)
        self.stdout_out.flush()

    def relay(self):
        filt = StatusFilter(self.nonce, self.stderr_out or getattr(sys.stderr, "buffer", sys.stderr),
                            self.on_status, self.saw_output, self.count_err)
        filt.on_text = lambda d: self.scan(d, "err")
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
        self.scan(b"", "err", final=True)

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

STAGES = {}      # client-side start timings of this rrun (route.log, always): lock_s cache_s plan_s push_s overlay_s
#                 slot_s remote_s start_s. lock_s = the wait for a worktree lane (this Mac); slot_s = the wait
#                 for a worker slot (the runners' SLOT statuses, summed over attempts / shards). Both are
#                 also inside start_s; route.log readers must not add them to it.
_STAGES_LOCK = threading.Lock()


def add_stage(key, secs):
    with _STAGES_LOCK:
        STAGES[key] = round(STAGES.get(key, 0.0) + secs, 2)

ROUTE_EXTRA = {}  # more route.log fields of this rrun: pred_s (the placement's run estimate), client (code sha)


class Timing:
    def __init__(self, on):
        self.on, self.t0, self.last, self.parts = on, time.monotonic(), time.monotonic(), []

    def mark(self, label, key=None):
        now = time.monotonic()
        self.parts.append("%s %.2fs" % (label, now - self.last))
        if key:
            STAGES[key] = round(STAGES.get(key, 0.0) + now - self.last, 2)
        self.last = now

    def started(self):
        """The command started on the worker: rrun's whole time-to-start (the SLO's number)."""
        STAGES.setdefault("start_s", round(time.monotonic() - self.t0, 2))

    def report(self):
        if self.on:
            note("timing: " + ", ".join(self.parts) + ", total %.2fs" % (time.monotonic() - self.t0))


def short_argv(argv):
    """The argv as logged (route.log, rrun.json, cache meta): any URL userinfo redacted."""
    s = re.sub(r"([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@'\"]*@", r"\1****@", " ".join(shlex.quote(a) for a in argv))
    return s if len(s) <= 120 else s[:117] + "..."


def record(target, argv, rc, secs, wt12=None, start=False, cap=None, pred=None):
    """route.log line + rrun.json (last result, runs in flight: argv, worker, owner, start, cap, the
    placement's run estimate) for `rdocker status` and the worktree-lane wait line."""
    pid = str(os.getpid())

    def apply(cur):
        cur = cur if isinstance(cur, dict) else {}
        active = {k: v for k, v in (cur.get("active") or {}).items() if k != pid and alive_pid(k)}
        if start:
            o = owner_info()
            active[pid] = {"ts": time.time(), "argv": short_argv(argv), "wt12": wt12, "host": target,
                           "owner": o["id"], "name": o["name"], "cap_s": cap, "cwd": os.getcwd(),
                           "pred_s": pred}
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
        RESULT["host"], RESULT["secs"] = target, secs
        extra = " ".join("%s=%s" % kv for kv in list(STAGES.items()) + list(ROUTE_EXTRA.items()))
        rd_common.log("%-5s %-8s %s rc=%s %.1fs | %s%s" % (target, "rrun", short_argv(argv), int(rc) if isinstance(
            rc, int) else rc, secs, os.getcwd(), "\t" + extra if extra else ""), rd_common.ROUTE_LOG)


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


def wt_holder_text(a, now):
    """'<argv> on <worker>, running 4 min, owner X, its cap ends it within 26 min' for one rrun.json entry."""
    ts = a.get("ts") if isinstance(a.get("ts"), (int, float)) else now
    cap = a.get("cap_s")
    return "%s on %s, running %s, owner %s%s" % (
        a.get("argv"), a.get("host") or "?", fmt_min(max(0, now - ts)), owner_label(a),
        ", its cap ends it within %s" % fmt_min(max(0, cap - (now - ts))) if cap else "")


def wt_holder(wt12, now=None):
    """' (<holder>; <holder>)' for the runs of ours that hold this worktree's lanes, '' when rrun.json
    does not say."""
    now = time.time() if now is None else now
    held = [wt_holder_text(a, now) for _pid, a in active_runs(now) if a.get("wt12") == wt12]
    return " (%s)" % "; ".join(held) if held else ""


def _ago(ts, now):
    d = max(0, int(now - ts)) if isinstance(ts, (int, float)) else 0
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if d >= size:
            return "%d%s ago" % (d // size, unit)
    return "%ds ago" % d


# ---------------------------------------------------------------------------- entry

def run_local(argv, env_pairs, why=None):
    """exec the command on the laptop (RDOCKER_MODE=local: its containers stay on the laptop too)."""
    mark_started()
    if why:
        note("%s - running on the laptop instead (RDOCKER_MODE=local)" % why)
    env = dict(os.environ, RDOCKER_MODE="local", RRUN="0")   # RRUN=0: the npm shim must not re-route
    env.update(env_pairs)
    share_after()                  # a held pool-cache lease is dropped before exec (nothing to share)
    for line in version_lines():   # exec replaces this process: say it now, not at the end
        note(line[len("rrun: "):] if line.startswith("rrun: ") else line)
    sys.stdout.flush()
    sys.stderr.flush()
    for fd in HELD_LOCKS:          # the local run keeps holding the worktree (the gate exclusive + lane 0)
        os.set_inheritable(fd, True)
    try:
        os.execvpe(argv[0], argv, env)
    except OSError as e:
        note("%s: %s" % (argv[0], e))
        return 127


def fallback(argv, env_pairs, why, t0, job=None, pool=False):
    if os.environ.get("RRUN_STRICT") == "1":
        record("mini", argv, EXIT_NEVER_RAN, time.monotonic() - t0)
        return infra(EXIT_NEVER_RAN, "%s; RRUN_STRICT=1: not running it on this machine" % why)
    if pool and job and job.get("never_local"):
        record("none", argv, EXIT_NEVER_RAN, time.monotonic() - t0)
        return infra(EXIT_NEVER_RAN, "%s; a %s job never runs on this machine (the pool keeps it off "
                     "agent machines)" % (why, job["cls"]), "rerun it when a worker is back")
    busy = own_worktree(argv, t0)    # it writes into the worktree: it runs alone (or 72, logged as such)
    if busy is not None:
        return busy
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


def classify_job(cfg, wt, argv, outputs, cwd):
    """-> (job, wt): rd_pool.classify, plus the repo policy (rd_pnpm.repo_policy -> wt["policy"], sent on
    every command of that repo) and its Postgres lane (rd_pnpm.needs_pg -> job["pg"], a db job): every
    command there gets it unless it provably runs only tsc / eslint."""
    policy = rd_pnpm.repo_policy(cfg, wt["top"]) if wt else None
    pg = policy if policy and rd_pnpm.needs_pg(wt["top"], cwd, argv) else None
    if policy:
        wt = dict(wt, policy=policy)
    return rd_pool.classify(argv, outputs, cwd, pg=pg), wt


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
    """`rrun [-e NAME[=VALUE]]... [--] <cmd...>` -> exit code (the command's own, or one of
    EXIT_CODES). A job's result ends with ONE class line (result_line: pass / fail / infra /
    needs-human, its why and the next action), then any detail lines (RESULT["after"])."""
    environ0 = dict(os.environ)          # before Opts pops rrun's own flags: a re-exec needs them back
    ENVIRON0.clear()
    ENVIRON0.update(environ0)
    try:
        rc = _rrun(argv, env_args, environ0)
        if RESULT["job"]:
            sys.stdout.flush()
            sys.stderr.write("\n".join([result_line(rc)] + RESULT["after"] + version_lines()) + "\n")
            sys.stderr.flush()
    finally:
        share_after()                    # after the result is out: never delays it
    return int(rc)


def _rrun(argv, env_args, environ0):
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
    RESULT["job"] = not opts.where
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
    job, wt = classify_job(cfg, wt, argv, outputs, os.getcwd())
    refused = argv_refusal(cfg, wt, argv)
    if refused is not None:
        return refused
    deps = deps_dirs(wt["top"], wt["relcwd"], argv) if wt else []
    if not opts.where:
        timing.mark("resolve")
        try:                         # fds stay open (and locked) until we exit or exec
            # a build that copies outputs back writes into the worktree: it runs alone (the gate exclusive)
            take_wt_lanes(wt["wt12"], wt_wait_s(cfg, job), cfg, exclusive=bool(outputs))
        except WorktreeBusy as e:
            timing.mark("worktree lock", "lock_s")
            record("none", argv, EXIT_WT_BUSY, time.monotonic() - t0)
            return infra(EXIT_WT_BUSY, "%s; never ran" % e, "check `rrun --mine`; rerun when it is done")
        timing.mark("worktree lock", "lock_s")
    crun, cache_why = cache_prepare(cfg, wt, argv, env_pairs, deps, job, outputs) if wt \
        else (None, "not in a git worktree")
    hit = rd_cache.lookup(crun.key) if crun is not None and opts.cache and not opts.host else None
    timing.mark("cache", "cache_s")
    if hit is not None and not opts.where:
        return replay_hit(hit, argv, t0)
    dshas = rd_pool.deps_shas(wt["top"], deps) if wt else []
    shared = pool_cache_for(cfg, crun, opts, job) if hit is None else None
    try:
        plan = rd_pool.plan(cfg, job, wt["slug"] if wt else "", dshas, force=opts.host, probe=opts.where,
                            rcache=shared.req(lease=not opts.where) if shared else None)
    except ValueError as e:
        note(str(e))
        RESULT["job"] = False
        return 2
    timing.mark("plan", "plan_s")
    pans = pool_answer(shared, plan)
    where_pool = pool_where(shared, pans, plan) if opts.where else []
    if pans is None:
        shared = None                    # no home worker answered: this Mac's tier only, as before
    if shared is not None and not opts.where:
        SHARE["sh"] = shared
        ROUTE_EXTRA["pcache"] = pans["st"]
        if pans["st"] == "inflight":
            got = wait_inflight(cfg, shared, pans, timeout_s(cfg, job["cls"]) or rd_cache.LEASE_NOCAP_S)
            if isinstance(got, Rc):
                return got               # a cancelled waiter just exits
            pans = got
            ROUTE_EXTRA["pcache"] = "waited-" + got["st"]
            ROUTE_EXTRA["pwait_s"] = "%.1f" % got["waited"]
            if not (got["st"] == "hit" and pool_hit_ok(got["meta"], shared)):
                plan = rd_pool.plan(cfg, job, wt["slug"], dshas, force=opts.host)   # time passed: place it afresh
        if pans["st"] == "hit" and pool_hit_ok(pans["meta"], shared):
            return replay_pool_hit(pans["meta"], pans["frames"], argv, t0)
        if shared.leased:
            shared.start_refresh()
    ROUTE_EXTRA["client"] = client_sha() or "-"
    if not opts.where:
        trigger_warm(cfg, plan, wt, dshas, job)
    if not plan.hosts and not opts.where:
        # fleet.json's classes / max_cost_s / cold_ok leave no worker for this job: say so now
        # (waiting would not change it) - never a slot wait, never this machine
        record("none", argv, EXIT_CONFIG, time.monotonic() - t0)
        return Rc(EXIT_CONFIG, "needs-human", rd_pool.no_eligible_msg(job, plan.ineligible) + "; not run",
                  "tell the owner (fleet.json); rerunning will not help")
    smode = rd_pool.shard_mode(cfg)
    shards, why_not = None, None
    if smode and plan.pool and not opts.host:
        ok, why_not = rd_pool.shardable(argv, job, os.getcwd(), forced=smode != "auto")
        shards = rd_pool.shard_assign(cfg, plan, job, None if smode == "auto" else smode) if ok else None
        if ok and not shards:
            why_not = "fewer than 2 free workers would help"
        shards = shards if shards and len(shards) >= 2 else None
    if opts.where:
        print("\n".join([cache_where(crun, cache_why, hit, opts)] + where_pool
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


_SHA = []


def client_sha():
    """This client's code version (the dotfiles commit rd_run runs from), or None outside a git
    checkout. Once per process; logged per job (route.log client=, runs.log client=)."""
    if not _SHA:
        try:
            p = subprocess.run(["git", "-C", rd_common.HERE, "rev-parse", "--short=12", "HEAD"],
                               capture_output=True, text=True, timeout=3)
            v = p.stdout.strip()
            _SHA.append(v if p.returncode == 0 and re.match(r"^[0-9a-f]{7,40}$", v) else None)
        except (OSError, subprocess.TimeoutExpired):
            _SHA.append(None)
    return _SHA[0]


ENVIRON0 = {}                    # rrun's environment before Opts popped its flags
# Version check, layer 2: warning only. Layer 1 (the 2-min dotfiles autopull) keeps Macs current and
# the owner's rule is that agents are never blocked, so a newer or unknown worker version never stops
# or restarts a job; the invocation ends with one line saying so (version_lines).
VERSION = {"started": False, "tried": False, "behind": 0, "why": None, "unknown": False}
_VERSION_LOCK = threading.Lock()


def mark_started():
    """Something of this invocation started (GO sent, or a local run): never re-exec from now on."""
    with _VERSION_LOCK:
        VERSION["started"] = True


def version_seen(pv):
    """A runner's PV status -> True when THIS session must not send GO because the invocation will
    update itself and start again (see VERSION); False = go on (noting a newer or unknown version)."""
    with _VERSION_LOCK:
        if pv is None:
            VERSION["unknown"] = True
            return False
        if pv <= rd_common.POOL_VERSION:
            return False
        VERSION["behind"] = max(VERSION["behind"], pv)
        # warning only (owner policy: never block or restart an agent's job). The 2-minute dotfiles
        # autopull is what updates this Mac; a self-update + re-exec here was dropped after review:
        # every safe trigger point raced shards/hedges or never fired.
        return False


def version_lines():
    """The end-of-invocation lines about versions (none when all was current)."""
    out = []
    if VERSION["behind"] > rd_common.POOL_VERSION:
        out.append("rrun: this Mac's pool code is behind (v%d < v%d); it updates itself within 2 min%s"
                   % (rd_common.POOL_VERSION, VERSION["behind"],
                      ""))
    if VERSION["unknown"]:
        out.append("rrun: a worker could not report its pool version; ran anyway")
    return out


def warm_trigger_paths(key):
    """(stamp, pending) for one repo + lockfiles: stamp's mtime = when a triggered warm last STARTED
    (the throttle); pending = a triggered warm is waiting for the worktree's lane 0."""
    base = os.path.join(rd_common.STATE_DIR, "warm-trigger-%s" % key)
    return base, base + ".pending"


def trigger_warm(cfg, plan, wt, dshas, job=None):
    """Fast start: a worker that may take this job but lacks its packages (probe warm_deps 0) gets
    them in the background - one detached `rdocker warm --once --repo <cwd> --after-lock S --trigger K`
    (rd_warm: idle priority, only on workers running no job). It waits for the worktree's lane 0 (its
    mirror is the one it warms; at most the job's cap + a minute) - held by THIS rrun when it runs on lane
    0, so it starts once the foreground job is done; on lane 1+ it may warm meanwhile - never skipping
    the repo; the throttle (rr_warm_trigger_every_s) starts only when a warm really starts. -> True
    when a waiting warm was spawned."""
    if not (plan.pool and wt and dshas and cfg.get("rr_warm_trigger", True)):
        return False
    cold = [h for h in plan.hosts + [h for h, _ in plan.ineligible]
            if h.probe is not None and not h.probe.get("warm_deps")]
    if not cold:
        return False
    key = hashlib.sha256(("%s %s" % (wt["slug"], dshas)).encode()).hexdigest()[:16]
    stamp, pending = warm_trigger_paths(key)
    wait_s = int((timeout_s(cfg, job["cls"]) if job else 3600) or 3600) + 60
    now = time.time()
    try:
        if now - os.path.getmtime(stamp) < float(cfg.get("rr_warm_trigger_every_s", 600)):
            return False                 # a triggered warm started lately
    except OSError:
        pass
    try:
        rd_common.ensure_dirs()
        try:
            if now - os.path.getmtime(pending) < wait_s:
                return False             # one is already waiting for the lock
            os.unlink(pending)           # a waiter that died long ago
        except OSError:
            pass
        # the queued request (where to warm; rd_warm.queued) appears complete or not at all: written
        # to a private temp file, then hard-linked into place (fails if a request is already queued),
        # so a concurrent scan never sees - and deletes - a half-written marker
        tmp = "%s.%d.tmp" % (pending, os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "w") as f:
                f.write(os.getcwd() + "\n")
            os.link(tmp, pending)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    except OSError:
        return False                     # another rrun just queued one
    try:
        with open(os.devnull, "rb") as dn_in, open(os.devnull, "wb") as dn_out:
            subprocess.Popen([sys.executable, "-I", rd_common.ENTRY, "warm", "--once", "--repo", os.getcwd(),
                              "--after-lock", str(wait_s), "--trigger", key],
                             stdin=dn_in, stdout=dn_out, stderr=dn_out, start_new_session=True,
                             env=dict(os.environ, RRUN="0"), preexec_fn=lambda: os.nice(10))
    except OSError:
        try:
            os.unlink(pending)
        except OSError:
            pass
        return False
    return True


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
    RESULT["after"].append("rrun: " + rd_cache.hit_line(meta))
    record("cache", argv, meta["rc"], time.monotonic() - t0)
    return meta["rc"]


def cache_save(ctx, rc, argv):
    """Store the finished run's result when it may be replayed (rd_cache.Run.save decides): this
    Mac's tier now; the pool tier gets it from share_after(), once the result is printed - only when
    every attempt's runner really ran fleet.json's pool_node_major."""
    if ctx.cache is not None:
        node = producer_node(ctx)
        oi = owner_info()
        extra = {"agent": owner_label({"owner": oi["id"], "name": oi["name"]}), "client": client_sha() or "-",
                 "host": oi["client"]}
        if node is not None:
            extra["node"] = node
        meta = ctx.cache.save(rc, time.monotonic() - ctx.t0, short_argv(argv), extra)
        sh = SHARE["sh"]
        if meta is not None and sh is not None and node is not None and node == sh.pool_node:
            SHARE["entry"] = (meta, list(ctx.cache.rec.frames))
    return rc


# ---- the pool tier of the result cache (rd_cache "pool tier": the home worker, singleflight)
SHARE = {"sh": None, "entry": None, "done": False}   # this invocation's rd_cache.Shared + its entry


def pool_cache_for(cfg, crun, opts, job):
    """-> rd_cache.Shared for a cacheable run that may use the pool tier, else None (RRUN_CACHE=0
    bypasses both tiers; --host runs only there; rr_pool_cache false turns the tier off; no
    pool-cache key on this Mac (`rdocker pool-cache-key init`) = off; no pool_node_major in
    fleet.json = off)."""
    if crun is None or not opts.cache or opts.host or not cfg.get("rr_pool_cache", True):
        return None
    secret = rd_cache.load_key()
    pnm = rd_pool.pool_node_major(cfg) if secret is not None else None
    if pnm is None:
        return None
    oi = owner_info()
    return rd_cache.Shared(crun.key, owner_label({"owner": oi["id"], "name": oi["name"]}), oi["client"],
                           timeout_s(cfg, job["cls"]), cfg, secret, pool_node=str(pnm))


def pool_answer(shared, plan):
    """The home worker's answer from the placement probe (zero extra round trip) -> rd_cache.Shared
    .answer(), or None when there is no home worker or it did not answer."""
    if shared is None or plan.home is None or plan.home.probe is None:
        return None
    shared.attach(plan.home.name, rd_pool.ssh_base() + [plan.home.cfg["host"]], rd_pool.remote_env(plan.home.cfg))
    return shared.answer(plan.rcache)


def pool_hit_ok(meta, shared):
    """A pool entry is replayed only when its (signed) node tag is fleet.json's pool_node_major."""
    return shared.pool_node is not None and meta.get("node") == shared.pool_node


def producer_node(ctx):
    """The node major every attempt of this run really used (the runner's NODE status), else None."""
    if ctx.cache is None:
        return None
    majors = set(ctx.cache.nodes)
    return majors.pop() if ctx.cache.nodes and len(majors) == 1 and None not in majors else None


def wait_inflight(cfg, shared, ans, budget_s):
    """An identical run holds the lease: wait for its result (polling the home worker, at most
    rd_cache POLL_MAX_S apart; a status line every rr_status_every_s), for at most budget_s (this
    job's own cap: one monotonic deadline, whoever holds the lease meanwhile; every sleep and poll
    fits in what is left). -> {"st": "hit", "meta", "frames", "waited"} | {"st": "miss", "waited"}
    (its lease expired, its owner ended without a result or went quiet - this run took the lease when
    it could - the home worker stopped answering, or the budget ran out) | stopped() when this waiter
    was cancelled (it just exits)."""
    who = "%s on %s" % (ans["owner"], ans["host"])
    note("identical run in flight by %s; waiting for its result" % who)
    sig = []
    ev = threading.Event()

    def _stop(signum, _frame):
        sig.append(signum)
        ev.set()
    old = {s: signal.signal(s, _stop) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    t0 = last = time.monotonic()
    deadline = t0 + max(0.0, float(budget_s))
    every = float(cfg.get("rr_status_every_s", 60))
    delay, fails = 0.5, 0
    try:
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                note("waited %s (this job's cap) for the identical run; running it now" % fmt_min(budget_s))
                return {"st": "miss", "waited": time.monotonic() - t0}
            if ev.wait(min(delay, left)):
                return stopped(sig[0])
            delay = min(delay * 1.5, shared.poll_max)
            left = deadline - time.monotonic()
            if left <= 0:
                continue
            a = shared.poll(timeout=left)
            waited = time.monotonic() - t0
            if a is None:
                fails += 1
                if fails >= rd_cache.POLL_FAILS:
                    note("the pool cache (%s) stopped answering; running it now" % shared.home)
                    return {"st": "miss", "waited": waited}
                continue
            fails = 0
            if a["st"] == "hit":
                return dict(a, waited=waited)
            if a["st"] == "miss":
                note("the identical run ended, expired or went quiet without a result to share; running it now")
                return {"st": "miss", "waited": waited}
            if time.monotonic() - last >= every:
                last = time.monotonic()
                note("still waiting for the identical run by %s (%s so far; its lease ends in %s at most)"
                     % (who, fmt_min(waited), fmt_min(a["left"])))
    finally:
        for s_, h in old.items():
            signal.signal(s_, h)


def replay_pool_hit(meta, frames, argv, t0):
    """A pool-cache result: its output, the class line, one stderr line naming the worker and agent
    that produced it. Never copied into this Mac's tier: that tier has no toolchain check, so the next
    repeat goes through the probe (and its node check) again."""
    sys.stdout.flush()
    rd_cache.replay(frames, std_stream("stdout"), std_stream("stderr"))
    RESULT["after"].append("rrun: " + rd_cache.pool_hit_line(meta))
    record("pcache", argv, meta["rc"], time.monotonic() - t0)
    return meta["rc"]


def share_after():
    """Once, after the result is printed (or before a local exec): hand the pool tier this run's
    entry and drop our lease, in one detached ssh (rd_cache.Shared.finish). Never waited on."""
    sh = SHARE["sh"]
    if sh is None or SHARE["done"]:
        return
    SHARE["done"] = True
    meta, frames = SHARE["entry"] or (None, None)
    sh.finish(meta, frames)


def pool_where(shared, pans, plan):
    """`rrun --where`: what the pool tier would do (no lease is taken)."""
    home = getattr(plan, "home", None)
    if shared is None or home is None:
        return []
    if pans is None:
        return ["pool cache (%s): did not answer - this Mac's cache only" % home.name]
    if pans["st"] == "hit":
        m = pans["meta"]
        if not pool_hit_ok(m, shared):
            return ["pool cache (%s): a result made with node %s, but the pool runs node %s (fleet.json "
                    "pool_node_major) - runs" % (home.name, m.get("node") or "?", shared.pool_node)]
        return ["pool cache (%s): hit - replays the result from %s ago on %s%s (exit %d)" % (
            home.name, rd_cache.fmt_age(time.time() - m["ts"]), m.get("worker") or "a worker",
            " by %s" % m["agent"] if m.get("agent") else "", m["rc"])]
    if pans["st"] == "inflight":
        return ["pool cache (%s): an identical run is in flight by %s on %s - would wait for its result"
                % (home.name, pans["owner"], pans["host"])]
    return ["pool cache (%s): miss - runs, then shares the result" % home.name]


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
            return "done", stopped(STOP_SIG[0])
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
            record(h.name, argv, EXIT_MAY_HAVE_RUN, time.monotonic() - t0)
            return "done", infra(EXIT_MAY_HAVE_RUN, "%slost %s mid-run and could not reconnect; it may have "
                                 "run there, so it is not re-run automatically" % (tag, h.name),
                                 "rerun it (a DB job: check its side effects first)")
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
                    return "done", stopped(2)
                note("%severy worker is busy (%s waited so far, gives up after %s); re-planning"
                     % (tag, fmt_wait(time.monotonic() - busy_t0), fmt_wait(total)))
                hosts = replan(ctx, hosts) if not threaded else hosts
                if not hosts:
                    record("none", argv, EXIT_CONFIG, time.monotonic() - t0)
                    return "done", Rc(EXIT_CONFIG, "needs-human", tag + rd_pool.no_eligible_msg(job, ctx.plan.ineligible),
                                      "tell the owner (fleet.json); rerunning will not help")
                i, failed, round_t0, slot_busy = 0, set(), time.monotonic(), False
                continue
            return "done", infra(EXIT_BUSY, "%sno worker had a free slot%s; never ran"
                                 % (tag, " for %s" % fmt_wait(total) if slot_busy else ""))
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
            return "done", Rc(128 + e.signum, "infra", "stopped while waiting for a worker; not running it "
                              "anywhere", "rerun it if you still need the result")
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
    mid = lane_mirror_id(ctx.wt["wt12"], wt_lane(), n)
    lane = Lane(out, err, None if mid == ctx.wt["wt12"] else mid)
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
        cost = h.run_s if h.run_s is not None else rd_pool.default_cost(ctx.cfg, ctx.job["cls"]) / max(0.01, h.speed)
        self.expect = cost * frac
        self.frac = frac
        self.ref = (h.setup_s or 0.0) + min(h.rtt or 0.0, rd_pool.RTT_CAP_S) + self.expect
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
        return (c.setup_s or 0.0) + min(c.rtt or 0.0, rd_pool.RTT_CAP_S) + (c.run_s or 0.0) * self.frac

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
            mid = lane_mirror_id(ctx.wt["wt12"], wt_lane(), n)
            self.dup_lane = Lane(out, err, None if mid == ctx.wt["wt12"] else mid)
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
    """A shard no worker could take: on this machine (subprocess, output prefixed like the rest) - only
    when this run holds the worktree's gate exclusive (it may write there) or none at all; a run holding
    it shared, RRUN_STRICT=1 and a never-local job in the pool end the shard with exit 75."""
    if os.environ.get("RRUN_STRICT") == "1" or ctx.job.get("never_local"):
        return infra(EXIT_NEVER_RAN, "%s - not running this shard on this machine" % why)
    if WT["mode"] == "sh":
        # it would write into the worktree while other runs of it share it; the gate is never switched
        # mid-run (see WT), so a shared run never runs a shard here: it ends like an unreachable shard
        return infra(EXIT_NEVER_RAN, "%s - a shard runs on this machine only in a run that holds the worktree "
                     "alone (a build with --outputs); not running it here" % why, "rerun it when a worker is free")
    mark_started()
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
    "[shard i/n host] "; exit code = shards_rc(); a merged vitest summary at the end."""
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
            val = infra(EXIT_MAY_HAVE_RUN, "%srrun failed: %s" % (tag, e))
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
    rc = shards_rc(rcs)
    summary = rd_pool.shard_summary([o.tail.decode("utf-8", "replace") for o in outs])
    RESULT["after"].append("rrun: %d shards: %s" % (n, ", ".join(
        "%d/%d %s" % (i + 1, n, ("rc=%d" % r) if not isinstance(r, Rc) else "%s %d" % (r.klass, r))
        for i, r in enumerate(rcs))))
    if summary:
        with OUT_LOCK:
            out = so
            out.write(("\n".join(["", " rrun: merged summary of %d shards" % n] + summary) + "\n").encode())
            out.flush()
    return rc


def shards_rc(rcs):
    """One result for a sharded run. A shard whose command ran gives a real test result (a plain
    int); one that rrun ended (Rc: lost, never ran, cap) gives none. Any real failure IS the result
    (fail: the code is broken whatever the other shards did); every shard ran and passed -> 0; else
    the run is incomplete -> infra (may-have-run when any shard may have, else never-ran / its code)."""
    ran = [r for r in rcs if isinstance(r, int) and not isinstance(r, Rc)]
    lost = [r for r in rcs if isinstance(r, Rc)] + [infra(EXIT_MAY_HAVE_RUN, "a shard gave no result")
                                                   for r in rcs if not isinstance(r, int)]
    fails = [r for r in ran if r != 0]
    if fails:
        return max(fails)
    if not lost:
        return 0
    worst = next((r for r in lost if r.klass == "needs-human"), None) or \
        next((r for r in lost if int(r) == EXIT_MAY_HAVE_RUN), None) or lost[0]
    return Rc(int(worst), worst.klass, "%d of %d shards gave no test result (%s)%s"
              % (len(lost), len(rcs), worst.why, "; the others passed" if ran else ""), worst.next)


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
              "job_cls": job["cls"], "pool_version": rd_common.POOL_VERSION}
    if client_sha():
        header["client"] = client_sha()
    if outputs:
        header["outputs"] = list(outputs)
    policy = wt.get("policy") or (rd_pnpm.repo_policy(cfg, wt["top"]) if wt.get("top") else None)   # rd_warm's too
    if policy:                       # the repo policy, on every command (rr_runner.pl policy_env / policy_files)
        header["repo_policy"] = policy
    if job.get("pg"):                # the run-local Postgres lane (rr_runner.pl pg_up)
        header["pg_lane"] = True
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
    wt12 = wt["wt12"]                # the worktree's own id: rrun.json, the lane wait line
    if lane is not None and lane.wt12:
        wt = dict(wt, wt12=lane.wt12)
    try:
        base = push(cfg, wt) or []
    except PolicyRefused as e:
        return "done", Rc(65, "needs-human", "%s; not run" % e,
                          "tell the owner: untrack it (git rm --cached + commit) or rename it to *.example")
    except PushRefused as e:
        return "local", "cannot send this repo to %s: %s" % (label(h), e)
    except RunError as e:
        return "lost", "%s unreachable (%s)" % ("Mac mini" if h.name == "mini" else h.name, e)
    timing.mark("push", "push_s")
    deps = deps_dirs(wt["top"], wt["relcwd"], argv) if deps is None else deps
    try:
        tar, files, envs, deleted = build_overlay(cfg, wt["top"], env_dirs_for(wt, deps))
    except RunError as e:
        return "local", "could not list the worktree (%s)" % e
    if len(tar) > OVERLAY_WARN_BYTES:
        note("sending %.1f MB of uncommitted/untracked files" % (len(tar) / 1048576.0))
    timing.mark("overlay (%d files, %d env, %d deleted, %d bytes)" % (len(files), len(envs),
                                                                     len(deleted), len(tar)), "overlay_s")
    env = ship_env(cfg, env_pairs, wt["top"])
    if cache is not None:            # what this attempt really sends must be what the key hashed
        cache.shipped(rd_cache.content_id(wt["sha"], base, tar, envs, deleted, env, deps))
    run_id = str(uuid.uuid4())
    pred = round(h.run_s, 1) if isinstance(h.run_s, (int, float)) else None
    if pred is not None:
        ROUTE_EXTRA["pred_s"] = pred
    frames, nonce = runner_frames(h, wt, argv, env, deps, tar, envs, deleted, job, pool, outputs,
                                  run_id=run_id, waited_s=round(time.monotonic() - t0, 1), pred_s=pred,
                                  lock_s=STAGES.get("lock_s", 0.0),
                                  **({"node_id": 1} if cache is not None else {}))
    cap = timeout_s(cfg, job["cls"])
    record(h.name, argv, None, 0, wt12=wt12, start=True, cap=cap, pred=pred)
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
    # after GO only an authenticated "<nonce> EXIT" is the command's verdict: any other end (the link,
    # or the runner dying after GO - a full disk while it made the spool) is followed up by a reattach
    if sess.go_sent and sess.exit_rc is None and not sess.timed_out:
        att = reattach(h, sess, lane)
        if (att is None or att.exit_rc is None) and (getattr(sess, "reattach_stopped", False) or sess.first_sig):
            # the caller signalled (Ctrl-C, a tool's TERM) and no result came back: it wanted the run
            # to end - never re-run it anywhere
            record(h.name, argv, 128 + sess.first_sig, time.monotonic() - t0)
            return "done", stopped(sess.first_sig)   # the caller wants it to end: never re-run it
        if att is not None and att.norun:
            record(h.name, argv, rc, time.monotonic() - t0)
            timing.report()
            return "lost", "lost %s before the command started (it never ran there)" % label(h)
        if att is not None:
            rc = att.final_rc
            for k in ("exit_rc", "exit_at", "used_docker", "timed_out", "gone", "no_db_n"):
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
            return "done", Rc(128 + sess.first_sig, "infra", "stopped by signal %d before the command started; "
                              "not running it anywhere" % sess.first_sig, "rerun it if you still need the result")
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
        if rc in EXIT_CODES:             # the runner's own code (65 / 69 / 70 / 78): the command never ran
            return "done", Rc(rc, None, "%s on %s" % (EXIT_CODES[rc][1], h.name))
        return "done", infra(rc if 0 < rc < 256 else EXIT_NEVER_RAN,
                             "the runner on %s ended with %s before the command started" % (h.name, rc))
    timing.mark("command")
    if sess.timed_out and sess.exit_rc is None:
        rc = sess.exit_rc = EXIT_TIMEOUT     # our backstop closed it: the cap was hit, never re-run
    if sess.exit_rc is not None:
        if rc != sess.exit_rc and rc == 255:
            note("the link to %s dropped after the command finished there (exit %d); that is the result"
                 % (label(h), sess.exit_rc))
        rc = sess.exit_rc
        if cache is not None:
            cache.attempt_done(h.name, rc, sess.used_docker, bool(sess.ints or sess.first_sig), sess.node_major)
        if sess.timed_out and rc == EXIT_TIMEOUT:
            rc = infra(EXIT_TIMEOUT, "hit its %s wall-clock cap on %s and was killed with everything it started"
                       % (fmt_min(sess.timeout_s), h.name),
                       "rerun it (RRUN_TIMEOUT=<minutes> for a longer cap); a hang that repeats is a code bug")
        elif rc != 0 and (sess.first_sig or sess.ints):
            rc = Rc(rc, "infra", "stopped by signal %d while it ran on %s" % (sess.first_sig or 2, h.name),
                    "rerun it if you still need the result")
        if rc != 0 and sess.no_db_n:
            # advisory only (the exit and its class stay the command's: a real failure must never be
            # hidden behind a DB message); the fix is placement - a DB-needing suite is a db job
            if cache is not None:
                cache.taint("its output mentions a missing test DB")
            one = sess.no_db_n == 1
            RESULT["after"].append("rrun: %s%d failure%s mention%s DATABASE_URL - likely no test DB on %s; rerun "
                                   "with npm run test:db" % (sess.tag, sess.no_db_n, "" if one else "s",
                                                             "s" if one else "", h.name))
    elif sess.gone:
        # the worker says the run's result is lost and cannot prove it never ran: it may have run,
        # so it is never re-run (not even a job safe to repeat)
        record(h.name, argv, EXIT_MAY_HAVE_RUN, secs)
        timing.report()
        return "done", infra(EXIT_MAY_HAVE_RUN, "%s: the run's result is lost there (%s); it may have run, "
                             "so it is not re-run automatically" % (label(h), sess.gone),
                             "rerun it (a DB job: check its side effects first)")
    elif rc == 255:
        return "lost_go", "lost %s mid-run" % label(h)
    elif sess.exit_rc is None:
        # the runner ended after GO with its own code and no EXIT status, and no reattach found the
        # result: the command may have run - never a test verdict, never re-run automatically
        record(h.name, argv, EXIT_MAY_HAVE_RUN, secs)
        timing.report()
        return "done", infra(EXIT_MAY_HAVE_RUN, "the runner on %s ended (exit %s) after the start without the "
                             "command's result; it may have run" % (label(h), rc),
                             "rerun it (a DB job: check its side effects first)")
    if rc == 0 and outputs:
        why = copy_back(cfg, wt, outputs)
        timing.mark("copy-back")
        if why:
            rc = infra(EXIT_MAY_HAVE_RUN, "the build ran on %s but its outputs could not be copied back (%s)"
                       % (h.name, why))
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
                  "out_off", "err_off", "started", "last_out", "last_file", "last_file_at", "no_db_n"):
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
