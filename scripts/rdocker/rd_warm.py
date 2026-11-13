"""rdocker rd_warm: `rdocker warm [--once] [--repo PATH]` - pre-warm the rrun worker pool.

A cold worker spends 90-140 s on a repo's first job (the whole git history, npm ci, prisma
generate). The warmer does that work ahead of time, for the repos THIS client ran `rrun` in lately,
so the job that needs a worker finds it ready. Workers come and go (a MacBook sleeps and wakes), so
it keeps looking. Nothing here installs packages or touches git on a worker by itself - every step
is the real rrun path:

  discover  repos with an rrun line in route.log (+ route.log.1) in the last rr_warm_window_h, one
            per repo slug (its most recently used worktree), newest first, at most
            rr_warm_max_repos per pass; deps dirs = rd_run.deps_dirs() of each logged cwd + argv
  probe     rd_pool's PROBE (slots, load, memory, share switch, warm_git, warm_deps), fresh
            right before each worker's turn
  push      rd_run.push() when the worker's mirror has no refs/rrun/<wt12> at this HEAD
  prepare   a real runner session (rd_run.runner_frames + rd_run.Session) that never sends GO:
            the runner takes a slot, checks out, applies the overlay and installs deps (npm ci or
            a store clone, prisma generate) exactly as for a job, prints READY; we close stdin and
            it exits 130 having started nothing. The packages land in the worktree's mirror and in
            the worker's shared store (~/rr/deps).

Slow workers (2026-11-11): warmed too - they need it most. A warm-only worker (cold_ok: false, or a
measured cold-setup p75 over rr_cold_budget_s: the 5400 rpm minis) takes only jobs whose packages
it already has, so background warming is what lets it take work at all; a detached prepare now
survives a long npm ci. The runner runs a warm (header warm) at nice 19 and the idle I/O class.
Triggers: this loop (com.rdocker.warm), and rrun itself (rd_run.trigger_warm: `rdocker warm --once
--repo <worktree>` in the background when a worker is cold for the job it just placed).
Politeness: workers are warmed one at a time (a pass is sequential, and a ~/rr/state/warm.lock dir
on the worker keeps two clients from warming it together); only a worker running NO job (every slot
free) with load1/ncpu below rr_warm_max_load; never queued for a slot (wait_min 0: busy => 73 => skip); never
a worker whose fleet entry (share) or share switch says off; never a db job class, so the runner
never starts Docker (not on the home machine, not anywhere) and no command ever runs; none of the
allowlisted env files (rr_env_allow) rrun would add - the overlay is only what git shows as changed
or untracked-and-not-ignored, as for any rrun; no route.log rrun line (a warm is not usage, so
discovery never feeds itself).
A repo whose worktree lane 0 is held (rrun-<wt12>.lock: an rrun in flight on lane 0, the mirror a warm
prepares) is skipped; an rrun started during a warm takes another lane of its worktree (rd_run
take_wt_lanes), or waits for lane 0 when it writes into the worktree (the gate exclusive + lane 0). Its push shares rd_run.push_lock with
every rrun push from this Mac (the base-branch refs are the same).

Loop: a pass every rr_warm_interval_s; in between, a cheap `ssh true` per worker every
rr_warm_tick_s, and a worker that went down -> up starts a pass at once ("just came online").
Log: warm.log, one line per action (repeated skips are logged when their reason changes).
"""
import fcntl
import os
import re
import shlex
import subprocess
import sys
import threading
import time

import rd_common
import rd_pool
import rd_run

WARM_ARGV = ["true"]                 # the runner wants an argv; it never runs (no GO is ever sent)
WARM_JOB = rd_pool.classify(WARM_ARGV)    # "normal": never db, so the runner never starts Docker
REMOTE_LOCK_STALE_MIN = 30           # a warm.lock on a worker older than this was left by a dead client
TAIL_BYTES = 4096                    # remote stderr kept for the log when a prepare fails
PASS_LOCK = os.path.join(rd_common.STATE_DIR, "warm-pass.lock")   # one pass at a time on this client

# route.log rrun line (rd_run.record): "<date> <time> <target> rrun <argv> rc=<rc> <secs>s | <cwd>"
# (since 2026-11-11 followed by a tab and the client's stage timings: not part of the cwd)
_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) +\S+ +rrun +(.*) rc=\S* [0-9.]+s \| ([^\t]+)(?:\t.*)?$")

_last_skip = {}                      # (worker, slug) -> reason last logged (repeats are not)


def wlog(msg):
    rd_common.log(msg, rd_common.WARM_LOG)
    if sys.stderr.isatty():          # interactive `rdocker warm --once`: show it too
        sys.stderr.write("warm: " + msg + "\n")


def _cfg_num(cfg, key, default):
    try:
        return float(cfg.get(key, default))
    except (TypeError, ValueError):
        return float(default)


# ---------------------------------------------------------------------------- discovery

def split_argv(s):
    """route.log argv text -> argv list (short_argv quoted it and may have cut it at 120 chars)."""
    if s.endswith("..."):
        s = s[:-3]
    try:
        return shlex.split(s)
    except ValueError:
        return s.split()


def parse_route(lines, since):
    """-> [(epoch, cwd, argv)] for the rrun lines at or after `since`."""
    out = []
    for line in lines:
        m = _LINE.match(line.rstrip("\n"))
        if not m:
            continue
        try:
            ts = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
        except ValueError:
            continue
        if ts >= since:
            out.append((ts, m.group(3), split_argv(m.group(2))))
    return out


def worktree(path):
    """rd_run.resolve_worktree(path), or None when path is gone / not a git worktree with a commit."""
    if not os.path.isdir(path):
        return None
    try:
        return rd_run.resolve_worktree(path)
    except (rd_run.RunError, OSError):
        return None


def discover(cfg, now=None, paths=None):
    """-> repos this client ran rrun in within rr_warm_window_h, newest first, one per slug:
    dicts of resolve_worktree() (top, relcwd, slug, wt12, sha) + ts + deps (repo-relative dirs)."""
    now = time.time() if now is None else now
    since = now - 3600.0 * _cfg_num(cfg, "rr_warm_window_h", 48)
    entries = []
    for p in paths or (rd_common.ROUTE_LOG + ".1", rd_common.ROUTE_LOG):
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                entries += parse_route((line for line in f if " rrun " in line), since)
        except OSError:
            continue
    seen, repos = {}, {}
    for ts, cwd, argv in sorted(entries, key=lambda e: -e[0]):
        if cwd not in seen:
            seen[cwd] = worktree(cwd)
        wt = seen[cwd]
        if wt is None:
            continue
        # relcwd "": nothing runs, and the runner refuses a relcwd that is not a dir in the commit
        r = repos.setdefault(wt["slug"], dict(wt, ts=ts, deps=[], relcwd=""))
        if r["top"] != wt["top"]:
            continue                 # another worktree of the same repo, used less recently
        r["deps"] = list(dict.fromkeys(r["deps"] + rd_run.deps_dirs(wt["top"], wt["relcwd"], argv)))
    return sorted(repos.values(), key=lambda r: -r["ts"])


def repo_at(path):
    """--repo PATH -> the same repo dict as discover() (deps dirs as rrun would pick at PATH)."""
    wt = worktree(os.path.abspath(path))
    if wt is None:
        raise SystemExit("rdocker warm: %s is not a git worktree with a commit" % path)
    return dict(wt, ts=time.time(), deps=rd_run.deps_dirs(wt["top"], wt["relcwd"], []), relcwd="")


# ---------------------------------------------------------------------------- workers

def worker_hosts(cfg):
    """Enabled fleet workers as rd_pool Hosts (none without a fleet: nothing to warm)."""
    return [rd_pool.host_for(cfg, w) for w in rd_pool.load_workers(cfg) or []]


def fleet_off(h):
    """The fleet entry's share field says off (a missing field = on)."""
    return str(rd_pool._f(h.entry, "share", "on")).strip().lower() == "off"


def warmable(h):
    """Workers the warmer visits: every one not shared off in fleet.json - slow and warm-only ones
    included (a warm is how a warm-only worker gets jobs at all; its job class does not matter, a
    warm runs no command)."""
    return not fleet_off(h)


def probe(h, repo, cfg):
    """rd_pool's PROBE for one host and repo; sets h.probe / h.rtt / h.why."""
    req = {"slug": repo["slug"], "deps": [list(d) for d in rd_pool.deps_shas(repo["top"], repo["deps"])],
           "slots": h.cfg.get("rr_slots", 1)}
    hs = rd_pool._f(h.entry, "heavy_slots") if h.entry is not None else None
    if isinstance(hs, int) and hs >= 0:
        req["heavy_slots"] = hs
    for a in ("probe", "rtt", "why"):
        h.__dict__.pop(a, None)
    rd_pool.probe_all([h], lambda _h: req, _cfg_num(cfg, "rr_probe_timeout_s", rd_pool.PROBE_TIMEOUT_S))


def refusal(h, cfg):
    """-> why h must not be warmed right now (None = go). Reads h.probe."""
    if fleet_off(h):
        return "share off (fleet.json)"
    rd_pool.score(h, WARM_JOB)       # sets h.state: down / off / busy / low-mem / free
    if h.state == "down":
        return "down (%s)" % (getattr(h, "why", None) or "no answer")
    if h.state == "off":
        return "share off (owner's switch)"
    if h.state != "free":
        return "no free slot" if h.state == "busy" else h.state
    p = h.probe
    if rd_pool._num(p.get("slots_busy"), 0) > 0:
        return "running a job (warms only an idle worker)"
    per_cpu = rd_pool._num(p.get("load1"), 0.0) / (rd_pool._num(p.get("ncpu"), 1.0) or 1.0)
    limit = _cfg_num(cfg, "rr_warm_max_load", 0.7)
    if per_cpu >= limit:
        return "load %.2f/cpu (warms below %.2f)" % (per_cpu, limit)
    return None


def remote(h, script, timeout=30):
    """One ssh round trip on rrun's own master -> (rc or None when it never answered, stdout)."""
    try:
        p = subprocess.run(rd_pool.ssh_base() + [h.cfg["host"], script], stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return p.returncode, p.stdout.decode("utf-8", "replace")


def mirror_sha(h, repo):
    """The commit the worker's bare mirror holds for this worktree (refs/rrun/<wt12>), or None."""
    bare = '"$HOME"/%s/git/%s.git' % (rd_run.rr_root(h.cfg), shlex.quote(repo["slug"]))
    rc, out = remote(h, "git --git-dir %s rev-parse -q --verify %s 2>/dev/null"
                     % (bare, shlex.quote("refs/rrun/%s^{commit}" % repo["wt12"])))
    out = out.strip()
    return out if rc == 0 and re.match(r"^[0-9a-f]{40}$", out) else None


def remote_lock(h, take):
    """Take (-> True when we got it) or release the worker's warm.lock dir (one warmer per worker,
    across clients; one left behind by a client that died is taken over after 30 min)."""
    d = '"$HOME"/%s/state' % rd_run.rr_root(h.cfg)
    if not take:
        remote(h, 'rmdir %s/warm.lock 2>/dev/null; true' % d, timeout=15)
        return True
    rc, _ = remote(h, ('mkdir -p {d} || exit 1; L={d}/warm.lock; '
                       '[ -n "$(find "$L" -maxdepth 0 -mmin +{stale} 2>/dev/null)" ] && rmdir "$L"; '
                       'mkdir "$L" 2>/dev/null').format(d=d, stale=REMOTE_LOCK_STALE_MIN), timeout=15)
    return rc == 0


def reachable(hosts):
    """{name: answers `ssh true` right now} for every host, in parallel (the cheap 60 s check:
    unlike the PROBE it has no side effects on the worker)."""
    out = {}

    def one(h):
        out[h.name] = rd_run.mini_answers(h.cfg)
    ts = [threading.Thread(target=one, args=(h,), daemon=True) for h in hosts]
    for t in ts:
        t.start()
    for t in ts:
        t.join(25)
    return {h.name: out.get(h.name, False) for h in hosts}


def came_up(prev, cur):
    """Workers that were seen down and answer now."""
    return sorted(n for n, ok in cur.items() if ok and prev.get(n) is False)


# ---------------------------------------------------------------------------- prepare

class _Tail:
    """A file-like sink that keeps the last TAIL_BYTES of the runner's stderr."""

    def __init__(self):
        self.buf = b""

    def write(self, data):
        self.buf = (self.buf + data)[-TAIL_BYTES:]

    def flush(self):
        pass

    def last_line(self):
        lines = [x for x in self.buf.decode("utf-8", "replace").splitlines() if x.strip()]
        return lines[-1].strip()[:200] if lines else ""


class PrepareSession(rd_run.Session):
    """A runner session that never releases the command. The runner does everything a job's
    prepare does (slot, checkout, overlay, deps) and announces READY; we then stop writing, the
    writer closes stdin, and the runner exits 130 ("laptop went away before GO") without spawning
    anything. Statuses are kept, not printed."""

    def __init__(self, cfg, frames, nonce):
        rd_run.Session.__init__(self, cfg, frames, nonce, rd_run.Timing(False))
        self.stderr_out = _Tail()

    def claim_go(self):
        return False                 # never: the command must not start

    def on_status(self, line):
        word, _, rest = line.partition(" ")
        if word == "READY":
            self.ready = True
            self.done.set()          # ends the writer loop, which closes the runner's stdin
            self.wake.set()
        elif word == "UNAVAIL":
            self.unavail = rest.strip() or "unavailable"


class Stopped(Exception):
    """A signal (launchd stop, Ctrl-C) arrived during a prepare: end the warmer."""


def prepare(h, repo):
    """Run the runner's prepare for repo on h -> (outcome, detail). outcome: warmed / busy / lost
    / deps-failed / error."""
    try:
        tar, _files, envs, deleted = rd_run.build_overlay(h.cfg, repo["top"], env_dirs=())
    except rd_run.RunError as e:
        return "error", "could not list the worktree (%s)" % e
    frames, nonce = rd_run.runner_frames(h, repo, WARM_ARGV, {}, repo["deps"], tar, envs, deleted,
                                         WARM_JOB, True, wait_min=0, warm=1)
    sess = PrepareSession(h.cfg, frames, nonce)
    rc = sess.run()
    if sess.first_sig:
        raise Stopped(sess.first_sig)
    if sess.ready:
        return "warmed", ""
    tail = sess.stderr_out.last_line()
    if rc == 73:
        return "busy", sess.unavail or "no free slot"
    if rc == 255:
        return "lost", tail or "connection lost"
    if rc == 78:
        return "deps-failed", tail
    return "error", "rc=%s %s" % (rc, tail)


# ---------------------------------------------------------------------------- pass

def skip(h, repo, why):
    key = (h.name, repo["slug"])
    if _last_skip.get(key) != why:
        _last_skip[key] = why
        wlog("skip %s %s: %s" % (h.name, repo["slug"], why))


def warm_one(h, repo, cfg):
    """Bring one worker up to date for one repo -> "warm" (already), "pushed", "prepared",
    "pushed+prepared", "skipped" or "failed"."""
    probe(h, repo, cfg)
    why = refusal(h, cfg)
    if why:
        skip(h, repo, why)
        return "skipped"
    p = h.probe
    need_push = not p.get("warm_git") or mirror_sha(h, repo) != repo["sha"]
    need_deps = not p.get("warm_deps")
    if not (need_push or need_deps):
        _last_skip.pop((h.name, repo["slug"]), None)
        return "warm"
    if not remote_lock(h, True):
        skip(h, repo, "another client is warming it")
        return "skipped"
    _last_skip.pop((h.name, repo["slug"]), None)
    done = []
    try:
        if need_push:
            t = time.monotonic()
            try:
                rd_run.push(h.cfg, repo)
            except rd_run.RunError as e:
                wlog("push %s %s %s failed: %s" % (h.name, repo["slug"], repo["sha"][:12], str(e)[:200]))
                return "failed"
            wlog("push %s %s %s ok %.1fs" % (h.name, repo["slug"], repo["sha"][:12], time.monotonic() - t))
            done.append("pushed")
        if need_deps:
            t = time.monotonic()
            outcome, detail = prepare(h, repo)
            wlog("prepare %s %s deps=%s %s %.1fs%s" % (h.name, repo["slug"],
                                                     ",".join(d or "." for d in repo["deps"]) or "-",
                                                     outcome, time.monotonic() - t,
                                                     (": " + detail) if detail else ""))
            if outcome != "warmed":
                return "failed" if outcome != "busy" else "skipped"
            done.append("prepared")
    finally:
        remote_lock(h, False)
    return "+".join(done)


def take_flock(path):
    """Non-blocking exclusive flock on path -> fd, or None when someone holds it."""
    rd_common.ensure_dirs()
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def wait_flock(path, timeout, sleep=time.sleep, clock=time.monotonic):
    """take_flock, retried every second for up to `timeout` s -> fd, or None."""
    end = clock() + max(0.0, timeout)
    while True:
        fd = take_flock(path)
        if fd is not None or clock() >= end:
            return fd
        sleep(min(1.0, max(0.0, end - clock())))


def queued(cfg):
    """Repos rrun queued (rd_run.trigger_warm: a pending marker holding the cwd) that are still to warm:
    [(repo, stamp, pending)], oldest first. A marker whose path is gone is dropped."""
    out = []
    d = rd_common.STATE_DIR
    names = sorted(n for n in (os.listdir(d) if os.path.isdir(d) else [])
                   if n.startswith("warm-trigger-") and n.endswith(".pending"))
    for n in names:
        pending = os.path.join(d, n)
        stamp = pending[:-len(".pending")]
        try:
            with open(pending) as f:
                path = f.read().strip()
        except OSError:
            continue
        wt = worktree(path) if path else None
        if wt is None:
            _unlink(pending)
            continue
        out.append((dict(wt, ts=time.time(), deps=rd_run.deps_dirs(wt["top"], wt["relcwd"], []), relcwd=""),
                    stamp, pending))
    return out


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def run_pass(cfg, repo_path=None, after_lock=None, trigger=None):
    """One warm pass -> {worker name: answered} (the down->up trigger's baseline).
    trigger (rrun's background request, rd_run.trigger_warm; key of its stamp + pending marker): wait
    up to after_lock s for the repo's worktree lock FIRST - the triggering job holds it until it ends -
    and only then take the machine's pass lock, so a long job never stalls other repos' warming. Pass
    lock busy -> the request stays queued (its marker is kept) and the next pass warms it. The stamp
    (the trigger's throttle) is set only when its warm really starts. A plain pass also warms every
    queued request, first."""
    if not trigger:
        return _run_pass(cfg, repo_path)
    stamp, pending = rd_run.warm_trigger_paths(trigger)
    repo = repo_at(repo_path)
    wl = wait_flock(rd_run.wt_lock_path(repo["wt12"]), after_lock or 0)
    if wl is None:
        wlog("trigger %s: its worktree stayed busy for %ds; dropped (scheduled passes still warm it)"
             % (repo["slug"], after_lock or 0))
        _unlink(pending)
        return {}
    try:
        return _run_pass(cfg, None, [(repo, stamp, pending)], {repo["wt12"]: wl}, queue_only=True)
    finally:
        os.close(wl)


def _run_pass(cfg, repo_path, items=None, held=None, queue_only=False):
    """items: [(repo, stamp, pending)] to warm first (queued requests); held: {wt12: fd} worktree locks
    the caller already holds. queue_only: warm just the items (a trigger)."""
    lk = take_flock(PASS_LOCK)
    if lk is None:
        wlog("pass skipped: another warm pass is running on this machine%s"
             % ("; the request stays queued for the next pass" if queue_only else ""))
        return {}
    held = held or {}
    try:
        hosts = [h for h in worker_hosts(cfg) if warmable(h)]
        if not hosts:
            return {}
        if items is None:
            items = queued(cfg)
        work = list(items)
        if not queue_only:
            plain = [repo_at(repo_path)] if repo_path else \
                discover(cfg)[:max(0, int(_cfg_num(cfg, "rr_warm_max_repos", 2)))]
            have = set(r["slug"] for r, _s, _p in work)
            work += [(r, None, None) for r in plain if r["slug"] not in have]
        if not work:
            return reachable(hosts)
        up, counts = {}, {}
        for repo, stamp, pending in work:
            wl = held.get(repo["wt12"])
            own = wl is None
            if own:
                wl = take_flock(rd_run.wt_lock_path(repo["wt12"]))
            if wl is None:
                wlog("skip %s: an rrun from %s is in flight" % (repo["slug"], repo["top"]))
                continue
            if stamp:
                with open(stamp, "w"):  # a triggered warm really starts: its throttle starts now
                    pass
            try:
                for h in hosts:
                    res = warm_one(h, repo, cfg)
                    counts[res] = counts.get(res, 0) + 1
                    up[h.name] = up.get(h.name, False) or h.probe is not None
            finally:
                if own:
                    os.close(wl)
                if pending:
                    _unlink(pending)
        acted = {k: v for k, v in counts.items() if k not in ("warm", "skipped")}
        if acted:
            wlog("pass: %s x %s: %s" % (",".join(r["slug"] for r, _s, _p in work), ",".join(h.name for h in hosts),
                                        ", ".join("%s %d" % kv for kv in sorted(counts.items()))))
        return up
    finally:
        os.close(lk)


# ---------------------------------------------------------------------------- loop

def loop(once=False, repo_path=None, sleep=time.sleep, clock=time.monotonic, max_passes=None):
    """`rdocker warm`: passes forever (or once); returns the exit code."""
    passes = 0
    while True:
        cfg = rd_common.load_cfg()
        try:
            up = run_pass(cfg, repo_path)
            rc = 0
        except Stopped:
            wlog("stopped by a signal during a prepare")
            return 1
        except Exception as e:       # a bad pass must not end the agent: log it, try next time
            wlog("pass error: %s: %s" % (type(e).__name__, str(e)[:300]))
            up, rc = {}, 1
        passes += 1
        if once or (max_passes is not None and passes >= max_passes):
            return rc
        deadline = clock() + _cfg_num(cfg, "rr_warm_interval_s", 300)
        tick = max(1.0, _cfg_num(cfg, "rr_warm_tick_s", 60))
        prev = dict(up)
        while clock() < deadline:
            sleep(min(tick, max(0.0, deadline - clock())))
            if clock() >= deadline:
                break
            try:
                cur = reachable([h for h in worker_hosts(cfg) if warmable(h)])
            except Exception as e:
                wlog("reachability check error: %s: %s" % (type(e).__name__, str(e)[:200]))
                continue
            back = came_up(prev, cur)
            prev.update(cur)
            if back:
                wlog("%s came online: warming now" % ", ".join(back))
                break


def main(once=False, repo=None, after_lock=None, trigger=None):
    if after_lock is not None or trigger:
        return 0 if run_pass(rd_common.load_cfg(), repo, after_lock, trigger) is not None else 1
    return loop(once=once, repo_path=repo)
