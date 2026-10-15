"""rdocker rd_common: paths, DEFAULTS, config/state files + locks, logging, subprocess + docker helpers.

Split out of rdocker.py; see rdocker.py for the overview.
"""
import copy
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

# Root of every laptop-side path below (config, state, ~/.local/bin, the LaunchAgent plist).
# RDOCKER_HOME overrides it; the test harness (tests/rdmods.py) points it at a temp dir so no
# test can write the real ~/.config/rdocker or ~/.local/state/rdocker.
HOME = os.path.abspath(os.path.expanduser(os.environ.get("RDOCKER_HOME") or "~"))
CFG_DIR = os.path.join(HOME, ".config", "rdocker")
CFG_PATH = os.path.join(CFG_DIR, "config.json")
STATE_DIR = os.path.join(HOME, ".local", "state", "rdocker")
HEALTH_PATH = os.path.join(STATE_DIR, "health.json")
HEALTH_LOCK = os.path.join(STATE_DIR, "health.lock")   # one inline health probe at a time
FORWARDS_PATH = os.path.join(STATE_DIR, "forwards.json")
LOCK_PATH = os.path.join(STATE_DIR, "sync.lock")
MASTER_LOCK = os.path.join(STATE_DIR, "master.lock")   # serializes ssh master (re)creation, all processes
FWD_SOCK = os.path.join(STATE_DIR, "fwd.sock")
MINI_SOCK = os.path.join(STATE_DIR, "mini-docker.sock")   # laptop end of the mini docker socket
LOG_PATH = os.path.join(STATE_DIR, "daemon.log")
ROUTE_LOG = os.path.join(STATE_DIR, "route.log")
JANITOR_PATH = os.path.join(STATE_DIR, "janitor.json")
LAPTOP_JANITOR_PATH = os.path.join(STATE_DIR, "laptop_janitor.json")   # laptop janitor state
# Stamped by the shim on every throwaway-shaped container it creates on the laptop engine; the laptop
# janitor only ever looks at containers carrying it.
PLACED_LABEL = "rdocker.placed=laptop-throwaway"
# Stamped (=<run nonce>) by the mini-side rrun docker shim on every container an rrun job creates.
# Those DBs are used on the mini only: the forwarder never mirrors their ports to the laptop.
RRUN_LABEL = "rdocker.rrun"
DAEMON_PATH = os.path.join(STATE_DIR, "daemon.json")   # running daemon: pid, start time, code mtime
# Laptop-engine activity (read by the daemon's Docker Desktop idle-quit): one file per shim process
# that is running a docker command on the laptop engine (named by its pid), and a file whose mtime
# is the last time the shim routed a command to the laptop.
LOCAL_ACTIVE_DIR = os.path.join(STATE_DIR, "local-active")
LOCAL_LAST_PATH = os.path.join(STATE_DIR, "local-last")
BIN_DIR = os.path.join(HOME, ".local", "bin")
HERE = os.path.dirname(os.path.realpath(__file__))
SHIM_SRC = os.path.join(HERE, "docker-shim")
ENTRY = os.path.join(HERE, "rdocker.py")   # the CLI entry point (launchd plist, ~/.local/bin/rdocker)
RRUN_SRC = os.path.join(HERE, "rrun")      # the `rrun` wrapper (~/.local/bin/rrun links here)
RUNNER_SRC = os.path.join(HERE, "rr_runner.pl")   # the mini-side runner, sent with every rrun
RRUN_STATE = os.path.join(STATE_DIR, "rrun.json")  # last rrun result + runs in flight (status row)
# rrun-<wt12>.lock in STATE_DIR serialises rrun runs from one laptop worktree (rd_run.wt_lock_path)
PLIST_LABEL = "com.rdocker.forwarder"
PLIST_PATH = os.path.join(HOME, "Library", "LaunchAgents", PLIST_LABEL + ".plist")

DEFAULTS = {
    "host": "macmini-docker",          # ssh Host alias (see ~/.ssh/config.d/rdocker)
    "host_ip": "",                     # tailnet IP (informational; health uses the ssh master)
    "remote_context": "mini",
    "remote_socket": "",               # mini docker socket, streamed over the SSH master
    "local_context": "desktop-linux",
    "local_socket": os.path.join(HOME, ".docker", "run", "docker.sock"),
    "mode": "auto",                    # auto | mini | local | off
    "max_rtt_ms": 300,                 # auto mode: /_ping round-trip slower -> new throwaways on laptop
    "blip_wait_s": 30,                 # mini state unknown -> wait this long for it before refusing
    "local_idle_stop_min": 15,         # quit Docker Desktop after N idle minutes (0 = never)
    # laptop-resident (sticky local); fallback = [{"name", "kind": container|compose, "ts"}]
    "pins": {"containers": [], "compose_projects": [], "fallback": []},
    "ephemeral_port_range": [20000, 29999],   # host ports the shim picks for `-p <ctr-port>`
    # Janitor (mini only). Labels: rdocker.keep=<anything but 0/false/no> exempts containers,
    # volumes and images; rdocker.ttl=<30m|2h|1d> hard lifetime.
    "janitor_interval_min": 10,
    "idle_stop_hours": 3,              # running, no net traffic + no TCP connections this long -> stop
    "exited_rm_hours": 24,             # stopped this long -> rm -v (plain rm if it mounts a kept volume)
    "image_unused_days": 14,           # no container used the image for this long -> image rm
    "disk_high_pct": 80,               # VM disk above this -> rm unused images oldest-use first + cache
    "disk_critical_pct": 90,           # ...above this also remove every stopped container now
    "volume_unused_days": 30,          # named volume unused this long -> removed (rdocker.keep exempts)
    "host_log_max_mb": 50,             # mini-side colima/lima log files are truncated past this
    "host_min_free_gb": 8,             # mini macOS disk free below this -> aggressive prune + warning
    # rrun: heavy jobs (test runner + its DB) run ON the mini (rd_run.py + rr_runner.pl).
    "rr_root": "rr",                   # mini dir under ~ (git/, w/, slots/, ...)
    "rr_slots": 1,                     # concurrent rrun commands on the mini
    "rr_wait_min": 30,                 # give up waiting for a free mini slot after this
    "rr_hb_timeout": 60,               # mini kills the run after this many s without a laptop heartbeat
    # untracked/ignored env files copied for a run (basename globs), looked up ONLY in the repo
    # root, the command's cwd and the deps (lockfile) dirs; a symlink resolving outside the
    # worktree is skipped. 0600 on the mini and deleted when the run ends
    "rr_env_allow": [".env", ".env.test*", ".env.local"],
    # laptop env vars passed through to the remote command (fnmatch); `rrun -e K[=V]` adds more
    "rr_env_pass": ["CI", "DEBUG", "TEST_DB_*", "VITEST_*", "RR_NODE"],
    # heavy commands (re.search on a command line or an npm_lifecycle_event) that belong on the mini
    "rr_route_patterns": [r"(^|\s)test:db(:rls)?(\s|$)",
                          r"(^|\s)release:rehearse:migrations(\s|$)",
                          r"(^|[\s/])test-with-db\.mjs(\s|$)"],
}

HEALTH_TTL = 30          # seconds a health reading stays fresh for the shim
PERIODIC = 15            # daemon full reconcile / health interval


# ---------------------------------------------------------------------------- utilities

def ensure_dirs():
    for d in (CFG_DIR, STATE_DIR):
        os.makedirs(d, exist_ok=True)


class ConfigWriteError(RuntimeError):
    """config.json could not be locked or written. Config writes fail closed (state writes don't)."""


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    """Atomic write: unique temp file in the same dir, fsync, rename. Never leaves a torn file."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


@contextmanager
def file_lock(lock_path, fail_closed=False):
    """Exclusive advisory flock on `lock_path` for the duration of the block.

    fail_closed=False (state files): if the lock cannot be taken, log and proceed unlocked - the
    write itself is still atomic. fail_closed=True (config): raise ConfigWriteError instead."""
    fh = None
    try:
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        fh = open(lock_path, "a+")
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    except OSError as e:
        if fh is not None:
            fh.close()
            fh = None
        if fail_closed:
            raise ConfigWriteError("cannot lock %s: %s" % (lock_path, e))
        log("lock %s unavailable (%s); writing unlocked" % (lock_path, e))
    try:
        yield
    finally:
        if fh is not None:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            finally:
                fh.close()


def update_json(path, fn, default=None, fail_closed=False):
    """Read-modify-write `path` under its sidecar `<path>.lock`; fn(current) returns the new data."""
    with file_lock(path + ".lock", fail_closed=fail_closed):
        cur = load_json(path, default)
        new = fn(copy.deepcopy(cur) if cur is not None else cur)
        try:
            save_json(path, new)
        except OSError as e:
            if fail_closed:
                raise ConfigWriteError("cannot write %s: %s" % (path, e))
            raise
        return new


def write_state(path, data):
    """Whole-file state write (health/forwards) that never raises - a full disk must not kill the
    daemon or break a docker call."""
    try:
        save_json(path, data)
    except OSError as e:
        log("state write %s failed: %s" % (os.path.basename(path), e))


# ---------------------------------------------------------------------------- janitor stop record
# Both janitors record the containers they idle-stopped: state file "stopped_by_janitor" =
# {container id: {"name", "ts" (wall), "idle_h"}}. The shim auto-starts such a container before an
# exec/cp/attach/top/port/logs -f at it; a user `stop`/`rm` of the name clears its entry, so a
# container the USER stopped is never auto-started.
STOPPED_KEY = "stopped_by_janitor"
STOPPED_KEEP_S = 7 * 86400      # entries older than this are dropped (the janitor rm's at 24 h)


def janitor_state_path(target):
    """'mini' -> janitor.json, 'local' -> laptop_janitor.json."""
    return JANITOR_PATH if target == "mini" else LAPTOP_JANITOR_PATH


def record_janitor_stops(path, stops, now=None):
    """Merge {cid: {"name", "ts", "idle_h"}} into the record at `path`, dropping old entries."""
    if not stops:
        return
    now = time.time() if now is None else now

    def apply(st):
        cur = st.get(STOPPED_KEY) if isinstance(st.get(STOPPED_KEY), dict) else {}
        cur = {k: v for k, v in cur.items() if isinstance(v, dict)
               and isinstance(v.get("ts"), (int, float)) and now - v["ts"] < STOPPED_KEEP_S}
        cur.update(stops)
        return {**st, STOPPED_KEY: cur}
    update_state(path, apply)


def janitor_stops(path):
    rec = (load_json(path, {}) or {})
    rec = rec.get(STOPPED_KEY) if isinstance(rec, dict) else None
    return {k: v for k, v in rec.items() if isinstance(v, dict)} if isinstance(rec, dict) else {}


_ID_PREFIX = re.compile(r"^[0-9a-f]{12,64}$")


def stop_matches(cid, rec, ref):
    """Does a user reference name this recorded container? Exact name, or an id prefix of >= 12 hex
    chars (a short name must never hit another container's record by id prefix)."""
    ref = (ref or "").lstrip("/")
    return bool(ref) and (rec.get("name") == ref
                          or (bool(_ID_PREFIX.match(ref)) and cid.startswith(ref)))


def find_janitor_stop(stops, ref):
    """-> (cid, rec) for `ref` in a stopped_by_janitor map: an exact name match wins over an id-prefix
    match; None when neither."""
    ref = (ref or "").lstrip("/")
    by_name = [(c, r) for c, r in stops.items() if r.get("name") == ref]
    if by_name:
        return max(by_name, key=lambda cr: cr[1].get("ts") or 0)
    return next(((c, r) for c, r in stops.items() if stop_matches(c, r, ref)), None)


def drop_janitor_stops_ids(path, ids):
    """A janitor pass saw these containers running: they are no longer janitor-stopped."""
    ids = set(ids)
    if not ids or not ids & set(janitor_stops(path)):
        return

    def apply(st):
        rec = st.get(STOPPED_KEY) if isinstance(st.get(STOPPED_KEY), dict) else {}
        return {**st, STOPPED_KEY: {c: r for c, r in rec.items() if c not in ids}}
    update_state(path, apply)


def clear_janitor_stops(refs, paths=None):
    """Drop record entries named by `refs` (from both state files unless `paths`). No write unless
    something matches. Never raises."""
    for path in paths or (JANITOR_PATH, LAPTOP_JANITOR_PATH):
        cur = janitor_stops(path)
        if not any(stop_matches(c, r, ref) for c, r in cur.items() for ref in refs):
            continue

        def apply(st):
            rec = st.get(STOPPED_KEY) if isinstance(st.get(STOPPED_KEY), dict) else {}
            return {**st, STOPPED_KEY: {c: r for c, r in rec.items() if not (
                isinstance(r, dict) and any(stop_matches(c, r, ref) for ref in refs))}}
        update_state(path, apply)


def update_state(path, fn):
    """Fail-soft read-modify-write of a state file (janitor ledger). Returns the new data or None."""
    try:
        return update_json(path, lambda cur: fn(cur if isinstance(cur, dict) else {}), default={})
    except OSError as e:
        log("state update %s failed: %s" % (os.path.basename(path), e))
        return None


MIGRATIONS = ("rtt300",)   # recorded in config["migrated"] so each runs exactly once


def migrate_cfg(user):
    """-> (user', changed). rtt300: max_rtt_ms 150 measured raw TCP; the probe is now a docker
    round-trip (~2 RTT), so a stored 150 becomes 300."""
    done = set(user.get("migrated") or [])
    out = dict(user)
    changed = False
    if "rtt300" not in done:
        if out.get("max_rtt_ms") == 150:
            out["max_rtt_ms"] = 300
            changed = True
        done.add("rtt300")
    out["migrated"] = sorted(done)
    return out, changed


def merge_cfg(user):
    """DEFAULTS deep-merged with the stored (non-default) keys, migrations applied."""
    user, _ = migrate_cfg(user if isinstance(user, dict) else {})
    cfg = copy.deepcopy(DEFAULTS)
    cfg.update({k: copy.deepcopy(v) for k, v in user.items() if k != "pins"})
    cfg["pins"].update(copy.deepcopy(user.get("pins") or {}))
    return cfg


def cfg_diff(cfg):
    """Only the keys whose value differs from DEFAULTS, so later default changes take effect."""
    out = {k: v for k, v in cfg.items() if k != "pins" and (k not in DEFAULTS or v != DEFAULTS[k])}
    pins = {k: v for k, v in (cfg.get("pins") or {}).items() if DEFAULTS["pins"].get(k) != v}
    if pins:
        out["pins"] = pins
    out["migrated"] = sorted(set(cfg.get("migrated") or []) | set(MIGRATIONS))
    return out


def update_cfg(fn):
    """Locked read-modify-write of config.json (fail closed). fn(merged cfg) -> new merged cfg."""
    def apply(stored):
        return cfg_diff(fn(merge_cfg(stored if isinstance(stored, dict) else {})))
    return merge_cfg(update_json(CFG_PATH, apply, default={}, fail_closed=True))


def save_cfg(cfg):
    """Replace the stored config with `cfg` (non-default keys only), under the config lock."""
    return update_cfg(lambda _cur: cfg)


def load_cfg():
    user = load_json(CFG_PATH, {})
    if not isinstance(user, dict):
        user = {}
    if migrate_cfg(user)[1]:
        try:
            update_cfg(lambda c: c)          # persist the migration once; memory is right anyway
        except (ConfigWriteError, OSError) as e:
            log("config migration not persisted: %s" % e)
    return merge_cfg(user)


def say(msg):
    sys.stderr.write("rdocker: " + msg + "\n")


LOG_MAX = 2_000_000      # bytes; a log past this is rotated to <log>.1 (one generation kept)


def log(msg, path=LOG_PATH):
    """Append one line to `path` (daemon.log / route.log). Many shim processes write route.log at
    once, so the size check + rotation + append run under the sidecar flock `<path>.lock`: exactly
    one writer rotates, and no line lands in a file that is being renamed away. The line goes out as
    a single O_APPEND write. If the lock cannot be taken the line is still appended, unrotated.
    Never raises (deliberately not file_lock(): that logs its own failures through here)."""
    line = (time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n").encode("utf-8", "replace")
    lk = None
    try:
        ensure_dirs()
        try:
            lk = os.open(path + ".lock", os.O_RDWR | os.O_CREAT, 0o644)
            fcntl.flock(lk, fcntl.LOCK_EX)
        except OSError:
            if lk is not None:
                os.close(lk)
            lk = None
        if lk is not None:
            try:
                if os.path.getsize(path) > LOG_MAX:
                    os.replace(path, path + ".1")
            except OSError:
                pass
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line)
        finally:
            os.close(fd)
    except OSError:
        pass
    finally:
        if lk is not None:
            os.close(lk)      # closing releases the flock


def real_docker():
    """The actual docker CLI: first `docker` on PATH (plus known spots) that is not our shim."""
    shim = os.path.realpath(SHIM_SRC)
    dirs = os.environ.get("PATH", "").split(":") + [
        "/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin"]
    for d in dirs:
        p = os.path.join(d, "docker")
        rp = os.path.realpath(p)
        # skip our shim wherever it lives (repo, staging copy, a backup) - exec-ing it would loop
        if os.path.isfile(p) and os.access(p, os.X_OK) and rp != shim \
                and os.path.basename(rp) != "docker-shim":
            return p
    raise SystemExit("rdocker: no real docker CLI found (install Docker Desktop or `brew install docker`)")


def run(cmd, timeout=30, input_=None):
    """Run a command quietly; return (rc, stdout, stderr). Never raises on failure. `input_` may be
    bytes (replayed verbatim, e.g. a buffered `compose -f -` file); output is still returned as str."""
    raw = isinstance(input_, bytes)
    try:
        p = subprocess.run(cmd, capture_output=True, text=not raw, timeout=timeout, input=input_)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 124, "", str(e)
    if raw:
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    return p.returncode, p.stdout, p.stderr


# The shim's stdin, read once when a command needs it replayed to more than one docker process
# (`compose -f -`: the model render and the user's real command both read the compose file from
# stdin). None until buffer_stdin() runs; afterwards every docker the shim starts gets these bytes.
STDIN_REPLAY = {"data": None}


def buffer_stdin():
    if STDIN_REPLAY["data"] is None:
        stream = getattr(sys.stdin, "buffer", None)
        STDIN_REPLAY["data"] = stream.read() if stream is not None else b""
    return STDIN_REPLAY["data"]


def dk(ctx, *args, timeout=30):
    return run([real_docker(), "--context", ctx] + list(args), timeout=timeout)


# ---------------------------------------------------------------------------- attention (walk-away)

# Conditions a human must look at, kept while they hold: [{"key", "msg", "since"}] in attention.json
# (read-modify-write under its sidecar lock; one entry per key). Producers set a key when the
# condition appears and clear it when it resolves. `rdocker status` lists them as WARN rows; the
# shim prints one stderr line per item at most once per ATTENTION_NOTIFY_EVERY (attention-shown.json).
ATTENTION_PATH = os.path.join(STATE_DIR, "attention.json")
ATTENTION_SHOWN_PATH = os.path.join(STATE_DIR, "attention-shown.json")   # {key: wall time shown}
ATTENTION_NOTIFY_EVERY = 3600


def attention_items():
    """Current attention items (well-formed entries only)."""
    cur = load_json(ATTENTION_PATH, [])
    return [i for i in (cur if isinstance(cur, list) else [])
            if isinstance(i, dict) and isinstance(i.get("key"), str) and i.get("msg")]


def _attention_update(fn):
    """Fail-soft locked update of attention.json; fn(list) -> list. Writes only when it changed."""
    try:
        with file_lock(ATTENTION_PATH + ".lock"):
            cur = attention_items()
            new = fn([dict(i) for i in cur])
            if new != cur:
                save_json(ATTENTION_PATH, new)
            return new
    except OSError as e:
        log("attention update failed: %s" % e)
        return None


def attention_set(key, msg, now=None):
    """Raise (or re-word) attention item `key`. `since` is kept while the key stays set."""
    now = time.time() if now is None else now

    def apply(items):
        for i in items:
            if i["key"] == key:
                i["msg"] = msg
                return items
        return items + [{"key": key, "msg": msg, "since": now}]
    if not any(i["key"] == key and i["msg"] == msg for i in attention_items()):
        _attention_update(apply)


def attention_clear(*keys):
    """Drop the items whose key is in `keys` (no write when none of them is set)."""
    if any(i["key"] in keys for i in attention_items()):
        _attention_update(lambda items: [i for i in items if i["key"] not in keys])


def attention_notify(now=None):
    """Shim side: one stderr line per attention item not shown in the last ATTENTION_NOTIFY_EVERY
    seconds (any shim on this laptop). Never stdout, never raises, never changes the exit code."""
    try:
        items = attention_items()
        if not items:
            return []
        now = time.time() if now is None else now

        def stale(shown, i):
            t = shown.get(i["key"]) if isinstance(shown, dict) else None
            return not isinstance(t, (int, float)) or not 0 <= now - t < ATTENTION_NOTIFY_EVERY

        if not any(stale(load_json(ATTENTION_SHOWN_PATH, {}), i) for i in items):
            return []
        out = []

        def apply(shown):
            shown = {k: v for k, v in shown.items() if any(i["key"] == k for i in items)}
            for i in items:
                if stale(shown, i):        # re-checked under the lock: parallel shims print once
                    out.append(i["msg"])
                    shown[i["key"]] = now
            return shown
        update_state(ATTENTION_SHOWN_PATH, apply)
        for msg in out:
            say("needs attention: %s (run rdocker status)" % msg)
        return out
    except Exception as e:      # a notice must never break a docker call
        log("attention notice failed: %r" % e, path=ROUTE_LOG)
        return []
