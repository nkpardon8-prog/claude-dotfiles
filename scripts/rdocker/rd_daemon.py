"""rdocker rd_daemon: launchd forwarder daemon loop, tailscale kick, global docker context.

Split out of rdocker.py; see rdocker.py for the overview.
"""
import glob
import json
import os
import select
import subprocess
import sys
import time

import rd_common
import rd_tunnel
import rd_route
import rd_janitor

TS_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"


def tailscale_running():
    rc, out, _ = rd_common.run([TS_CLI, "status", "--json"], timeout=8)
    try:
        return json.loads(out).get("BackendState") == "Running"
    except ValueError:
        return False


def tailscale_up():
    """Start laptop Tailscale if it is installed but stopped. True if we changed something."""
    if not os.path.exists(TS_CLI) or tailscale_running():
        return False
    rd_common.run(["open", "-ga", "Tailscale"], timeout=10)
    time.sleep(3)
    rd_common.run([TS_CLI, "up"], timeout=20)
    return tailscale_running()


# ---------------------------------------------------------------------------- daemon

def set_global_context(cfg, target):
    want = cfg["remote_context"] if target == "mini" else cfg["local_context"]
    rc, out, _ = rd_common.run([rd_common.real_docker(), "context", "show"], timeout=10)
    if rc == 0 and out.strip() != want:
        rd_common.run([rd_common.real_docker(), "context", "use", want], timeout=10)
        rd_common.log("global docker context -> " + want)


# Scheduling uses time.monotonic(): a wall-clock jump (NTP step, manual change) must neither fire
# every job at once nor starve them. Wall-clock time is only for persisted timestamps (local-last).
TS_KICK_EVERY = 300          # seconds between laptop Tailscale start attempts
ENGINE_KICK_EVERY = 600      # seconds between mini engine (colima) start attempts
JANITOR_FIRST_DELAY = 60     # first janitor run this long after daemon start
EVENTS_BACKOFF_MAX = 300     # events watcher restart backoff cap (seconds)
EVENTS_HEALTHY_AFTER = 60    # a watcher that lived this long resets the backoff
SYNC_ACTIONS = ("start", "die", "destroy", "stop", "kill", "unpause", "restart")
MODULES = ("rd_common", "rd_args", "rd_tunnel", "rd_route", "rd_janitor", "rd_daemon", "rd_setup")


def due(last_mono, interval, now_mono):
    """A job last run at `last_mono` (None = never) is due again `interval` seconds later."""
    return last_mono is None or now_mono - last_mono >= interval


def count_engine_failures(prev, h):
    """Consecutive ENGINE probe failures (live tunnel, silent engine). A success or a tunnel-class
    failure breaks the run: a flaky network must never restart the mini's Colima."""
    return prev + 1 if not h.get("docker_ok") and h.get("failure") == "engine" else 0


def kick_args(engine_fails, last_kick, now):
    """-> argv extras for a kick job if one is due now, else None. Due every ENGINE_KICK_EVERY, and
    once immediately when the failure run reaches ENGINE_RESTART_AFTER (restart without a 10-min
    wait). `--restart-ok` lets the job restart a VM-up/docker-dead engine (rate-limited there)."""
    threshold = rd_janitor.ENGINE_RESTART_AFTER
    if not (due(last_kick, ENGINE_KICK_EVERY, now) or engine_fails == threshold):
        return None
    return ["--restart-ok"] if engine_fails >= threshold else []


# ---------------------------------------------------------------------------- detached jobs

def spawn_job(name, jobs, extra=()):
    """Start `rdocker <name> [extra...]` (janitor-run / kick) detached, so a hung job never blocks
    the loop. The job takes its own non-blocking lock, so a still-running previous one exits 0."""
    try:
        jobs[name] = subprocess.Popen([sys.executable, "-I", rd_common.ENTRY, name] + list(extra),
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        rd_common.log("cannot start %s: %s" % (name, e))


def reap_jobs(jobs):
    """poll() finished jobs (no zombies); also reap children a pre-reload daemon image started."""
    for name, child in list(jobs.items()):
        rc = child.poll()
        if rc is not None:
            del jobs[name]
            if rc:
                rd_common.log("%s exited rc=%s" % (name, rc))
    try:
        while os.waitpid(-1, os.WNOHANG)[0] > 0:
            pass
    except ChildProcessError:
        pass


# ---------------------------------------------------------------------------- Docker Desktop idle-quit

def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def live_local_markers():
    """Count `local-active/<pid>` markers whose pid is alive; delete the dead/garbage ones."""
    live = 0
    try:
        names = os.listdir(rd_common.LOCAL_ACTIVE_DIR)
    except OSError:
        return 0
    for n in names:
        if n.isdigit() and int(n) > 0 and pid_alive(int(n)):
            live += 1
            continue
        try:
            os.unlink(os.path.join(rd_common.LOCAL_ACTIVE_DIR, n))
        except OSError:
            pass
    return live


def last_local_route():
    """Wall-clock time the shim last routed a command to the laptop (None = never)."""
    try:
        return os.path.getmtime(rd_common.LOCAL_LAST_PATH)
    except OSError:
        return None


def desktop_idle(running_local, markers_alive, last_route_wall, now_wall, quiet_s):
    """Docker Desktop is idle only when no laptop container runs, no shim is running a laptop
    command, and nothing was routed to the laptop for `quiet_s`. A future `last_route_wall` (wall
    clock stepped back) counts as recent."""
    if running_local or markers_alive:
        return False
    return last_route_wall is None or now_wall - last_route_wall >= quiet_s


def snapshot_local_pins(cfg):
    """Fallback-pin every laptop container (and compose project) so that after Desktop quits, a
    command naming one starts Desktop and runs there instead of "not found" on the mini.
    -> True when the pins are saved (or there is nothing to pin)."""
    rc, out, _ = rd_common.dk(cfg["local_context"], "ps", "-a", "--format",
                              '{{.Names}}\t{{.Label "com.docker.compose.project"}}', timeout=15)
    if rc != 0:
        return False
    have = {"container": rd_route.pin_names(cfg, "container"),
            "compose": rd_route.pin_names(cfg, "compose")}
    entries = []
    for line in out.splitlines():
        name, _, proj = line.strip().partition("\t")
        for n, kind in ((name, "container"), (proj, "compose")):
            if n and n not in have[kind] and (n, kind) not in entries:
                entries.append((n, kind))
    try:
        rd_route.add_fallback_pins(entries)
    except (rd_common.ConfigWriteError, OSError) as e:
        rd_common.log("laptop pins snapshot not saved (%s) - keeping Docker Desktop up" % e)
        return False
    if entries:
        rd_common.log("pinned laptop containers before quitting Desktop: %s"
                      % ", ".join("%s/%s" % (k, n) for n, k in entries))
    return True


def idle_step(cfg, target, st, now_mono, now_wall):
    """Quit an idle laptop engine (that's the RAM we came here to free). st["idle_since"] is the
    monotonic time the idle condition started holding."""
    quiet = cfg["local_idle_stop_min"] * 60
    if not (quiet and target == "mini" and rd_tunnel.local_engine_up(cfg)):
        st["idle_since"] = None
        return False
    rc, out, _ = rd_common.dk(cfg["local_context"], "ps", "-q", timeout=10)
    if rc != 0 or not desktop_idle(bool(out.strip()), live_local_markers(), last_local_route(),
                                   now_wall, quiet):
        st["idle_since"] = None
        return False
    if st.get("idle_since") is None:
        st["idle_since"] = now_mono
    if now_mono - st["idle_since"] < quiet:
        return False
    st["idle_since"] = None
    if not snapshot_local_pins(cfg):
        return False
    rd_common.log("local engine idle %d min -> quitting Docker Desktop" % cfg["local_idle_stop_min"])
    rd_common.run(["osascript", "-e", 'quit app "Docker Desktop"'], timeout=20)
    return True


# ---------------------------------------------------------------------------- self-reload

def module_mtimes():
    paths = [rd_common.ENTRY] + sorted(glob.glob(os.path.join(rd_common.HERE, "rd_*.py")))
    out = {}
    for p in paths:
        try:
            out[p] = os.stat(p).st_mtime
        except OSError:
            out[p] = None
    return out


def code_mtime(mtimes):
    """Newest mtime of the rdocker code files (None when none could be read)."""
    vals = [m for m in mtimes.values() if m is not None]
    return max(vals) if vals else None


def import_check():
    """-> (ok, error text): do the modules on disk import cleanly in a fresh interpreter?"""
    code = "import sys; sys.path.insert(0, %r); import %s" % (rd_common.HERE, ", ".join(MODULES))
    rc, out, err = rd_common.run([sys.executable, "-I", "-c", code], timeout=30)
    return rc == 0, (err or out).strip()[-300:]


def should_reload(old_mtimes, new_mtimes, import_ok):
    return new_mtimes != old_mtimes and bool(import_ok)


def reload_step(st, before_exec=None):
    """Re-exec the daemon when its code changed on disk - only if the new code imports cleanly;
    otherwise log once per changed mtime set and keep running the old code."""
    now = module_mtimes()
    if now == st["mtimes"] or now == st.get("reload_failed"):
        return False
    ok, err = import_check()
    if not should_reload(st["mtimes"], now, ok):
        rd_common.log("code changed but does not import - keeping the running daemon: %s" % err)
        st["reload_failed"] = now
        return False
    rd_common.log("code changed -> reloading daemon")
    if before_exec:
        before_exec()
    os.execv(sys.executable, [sys.executable, "-I", rd_common.ENTRY, "daemon"])
    return True


# ---------------------------------------------------------------------------- mini events

def parse_event(line):
    """`docker events --format '{{json .}}'` line -> container action ('start', 'die', ...) or None
    for anything malformed."""
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    if not isinstance(ev, dict):
        return None
    action = ev.get("Action") or ev.get("status")
    return action if isinstance(action, str) else None


def start_events(cfg):
    try:
        p = subprocess.Popen(
            [rd_common.real_docker(), "--context", cfg["remote_context"], "events",
             "--filter", "type=container", "--format", "{{json .}}"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError as e:
        rd_common.log("cannot start events watcher: %s" % e)
        return None
    rd_common.log("watching mini container events")
    return p


def stop_child(p):
    if p is not None and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()


# ---------------------------------------------------------------------------- loop

def daemon():
    rd_common.log("daemon start pid=%d" % os.getpid())
    start = time.monotonic()
    st = {"idle_since": None, "mtimes": module_mtimes(), "reload_failed": None,
          "engine_fails": 0}
    rd_common.write_state(rd_common.DAEMON_PATH, {"pid": os.getpid(), "started": time.time(),
                                                  "code_mtime": code_mtime(st["mtimes"])})
    jobs = {}
    ev = {"p": None, "started": None, "next": start, "backoff": 5}
    last = {"tick": None, "ts_kick": None, "engine_kick": None,
            # first janitor JANITOR_FIRST_DELAY after start, whatever the interval
            "janitor": start - rd_common.load_cfg()["janitor_interval_min"] * 60 + JANITOR_FIRST_DELAY}
    while True:
        cfg = rd_common.load_cfg()
        now = time.monotonic()
        if due(last["tick"], rd_common.PERIODIC, now):
            last["tick"] = now
            reap_jobs(jobs)
            reload_step(st, before_exec=lambda: stop_child(ev["p"]))
            if cfg["mode"] == "off":
                time.sleep(rd_common.PERIODIC)
                continue
            h = rd_tunnel.refresh_health(cfg)
            if not h["reachable"] and due(last["ts_kick"], TS_KICK_EVERY, now):
                last["ts_kick"] = now
                if tailscale_up():
                    rd_common.log("mini unreachable and laptop Tailscale was stopped -> started it")
                    h = rd_tunnel.refresh_health(cfg)
            healthy = h["reachable"] and h.get("docker_ok")
            st["engine_fails"] = count_engine_failures(st["engine_fails"], h)
            if h["reachable"] and not h.get("docker_ok"):
                extra = kick_args(st["engine_fails"], last["engine_kick"], now)
                if extra is not None:
                    last["engine_kick"] = now
                    spawn_job("kick", jobs, extra)
            target, why = rd_tunnel.resolve_target(cfg)
            set_global_context(cfg, target)
            if healthy:
                rd_tunnel.sync_forwards(cfg)
                if due(last["janitor"], cfg["janitor_interval_min"] * 60, now):
                    last["janitor"] = now
                    spawn_job("janitor-run", jobs)
            idle_step(cfg, target, st, now, time.time())
            p = ev["p"]
            if p is not None and p.poll() is not None:     # watcher died: back off, then restart
                lived = now - ev["started"]
                ev["backoff"] = 5 if lived >= EVENTS_HEALTHY_AFTER else min(ev["backoff"] * 2,
                                                                            EVENTS_BACKOFF_MAX)
                ev["next"] = now + ev["backoff"]
                ev["p"] = None
                rd_common.log("events watcher exited rc=%s; restart in %ds" % (p.returncode, ev["backoff"]))
            if ev["p"] is None and healthy and now >= ev["next"]:
                ev["p"], ev["started"] = start_events(cfg), now
        wait = max(0.5, last["tick"] + rd_common.PERIODIC - time.monotonic())
        p = ev["p"]
        if p is not None and p.poll() is None:
            r, _, _ = select.select([p.stdout], [], [], wait)
            if r:
                line = p.stdout.readline()
                if not line:
                    p.wait()
                    continue        # the tick handles the restart backoff
                action = parse_event(line)
                if action and action.startswith(SYNC_ACTIONS):
                    time.sleep(0.3)      # debounce bursts (compose up of N services)
                    rd_tunnel.sync_forwards(cfg)
        else:
            time.sleep(wait)
