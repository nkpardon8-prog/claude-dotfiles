#!/usr/bin/python3
"""rdocker - run Docker on the always-on Mac mini, transparently.

The laptop's `docker` (via the shim in ~/.local/bin) is routed per call:
  * normal work (test databases, builds, compose stacks) -> the mini over SSH/Tailscale;
  * commands that need the laptop's own files or network (bind mounts of laptop paths,
    --network host) and containers pinned as laptop-resident -> the local Docker Desktop;
  * mini unreachable (mode=auto) -> local, with a one-line notice; a slow mini (round-trip >
    max_rtt_ms) only sends NEW throwaway containers to the laptop.
Published ports of mini containers are mirrored onto the laptop's 127.0.0.1 through one SSH
ControlMaster, so `localhost:<port>` keeps working (same port number on both sides).

Stdlib only; runs on the system /usr/bin/python3 (3.9). See commands/docker.md for the playbook.
"""
import copy
import errno
import fcntl
import json
import os
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager

HOME = os.path.expanduser("~")
CFG_DIR = os.path.join(HOME, ".config", "rdocker")
CFG_PATH = os.path.join(CFG_DIR, "config.json")
STATE_DIR = os.path.join(HOME, ".local", "state", "rdocker")
HEALTH_PATH = os.path.join(STATE_DIR, "health.json")
HEALTH_LOCK = os.path.join(STATE_DIR, "health.lock")   # one inline health probe at a time
FORWARDS_PATH = os.path.join(STATE_DIR, "forwards.json")
LOCK_PATH = os.path.join(STATE_DIR, "sync.lock")
FWD_SOCK = os.path.join(STATE_DIR, "fwd.sock")
MINI_SOCK = os.path.join(STATE_DIR, "mini-docker.sock")   # laptop end of the mini docker socket
LOG_PATH = os.path.join(STATE_DIR, "daemon.log")
ROUTE_LOG = os.path.join(STATE_DIR, "route.log")
JANITOR_PATH = os.path.join(STATE_DIR, "janitor.json")
BIN_DIR = os.path.join(HOME, ".local", "bin")
HERE = os.path.dirname(os.path.realpath(__file__))
SHIM_SRC = os.path.join(HERE, "docker-shim")
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
    "local_idle_stop_min": 15,         # quit Docker Desktop after N idle minutes (0 = never)
    # laptop-resident (sticky local); fallback = [{"name", "kind": container|compose, "ts"}]
    "pins": {"containers": [], "compose_projects": [], "fallback": []},
    "ephemeral_port_range": [20000, 29999],   # host ports the shim picks for `-p <ctr-port>`
    # Janitor (mini only). Labels: rdocker.keep=<anything but 0/false/no> exempts containers,
    # volumes and images; rdocker.ttl=<30m|2h|1d> hard lifetime.
    "janitor_interval_min": 10,
    "idle_stop_hours": 12,             # running, no net traffic + no TCP connections this long -> stop
    "exited_rm_hours": 24,             # stopped this long -> rm -v (plain rm if it mounts a kept volume)
    "image_unused_days": 14,           # no container used the image for this long -> image rm
    "disk_high_pct": 80,               # VM disk above this -> rm unused images oldest-use first + cache
    "disk_critical_pct": 90,           # ...above this also remove every stopped container now
    "volume_unused_days": 30,          # named volume unused this long -> removed (rdocker.keep exempts)
    "host_log_max_mb": 50,             # mini-side colima/lima log files are truncated past this
    "host_min_free_gb": 8,             # mini macOS disk free below this -> aggressive prune + warning
}

HEALTH_TTL = 30          # seconds a health reading stays fresh for the shim
PERIODIC = 15            # daemon full reconcile / health interval
START_LIKE = {"run", "start", "restart", "unpause"}
STOP_LIKE = {"stop", "rm", "kill", "pause"}
COMPOSE_START = {"up", "start", "restart", "run", "create"}
COMPOSE_STOP = {"down", "stop", "rm", "kill", "pause"}
# Subcommands whose first positional is a container (or name:path for cp).
CONTAINER_TARGETED = {
    "exec", "logs", "rm", "stop", "start", "restart", "inspect", "port", "cp", "kill",
    "wait", "top", "attach", "pause", "unpause", "rename", "update", "commit", "diff",
    "export", "stats",
}
MULTI_TARGET = {"rm", "stop", "kill", "start", "restart", "pause", "unpause", "inspect", "wait"}
# Targeted subcommands that only read: when the mini is unreachable and the container is found only on
# the laptop, these may still run there (with a notice); every other targeted subcommand refuses.
READ_ONLY_TARGETED = {"logs", "inspect", "port", "top", "stats", "diff", "wait", "export"}
# `docker <group> <sub>`: only `container` keeps container semantics; image/volume/... inspect/rm
# are not container commands and are never located.
MGMT_GROUPS = {"container", "image", "volume", "network", "system", "builder"}
COMPOSE_TARGETED = {"down", "stop", "start", "restart", "rm", "exec", "logs", "ps", "kill",
                    "pause", "unpause", "top", "port"}
COMPOSE_READ_ONLY = {"ps", "logs", "top", "port"}
COMPOSE_CREATING = {"up", "run", "create"}
# Value-taking flags per container subcommand (docs/docker-cli-semantics.md Q2). Every other flag of
# these subcommands is boolean; short booleans may cluster (-it); a value may be attached (-n5, --tail=5).
_STOP_VALUES = {"-s", "--signal", "-t", "--timeout"}
VALUE_FLAGS_BY_SUB = {
    "exec": {"--detach-keys", "-e", "--env", "--env-file", "-u", "--user", "-w", "--workdir"},
    "logs": {"--since", "-n", "--tail", "--until"},
    "rm": set(),
    "stop": _STOP_VALUES,
    "restart": _STOP_VALUES,
    "start": {"--checkpoint", "--checkpoint-dir", "--detach-keys"},
    "kill": {"-s", "--signal"},
    "inspect": {"-f", "--format", "--type"},
    "cp": set(),
    "attach": {"--detach-keys"},
    "stats": {"--format"},
    "update": {"--blkio-weight", "--cpu-period", "--cpu-quota", "--cpu-rt-period",
               "--cpu-rt-runtime", "-c", "--cpu-shares", "--cpus", "--cpuset-cpus",
               "--cpuset-mems", "-m", "--memory", "--memory-reservation", "--memory-swap",
               "--pids-limit", "--restart"},
    "commit": {"-a", "--author", "-c", "--change", "-m", "--message"},
    "export": {"-o", "--output"},
    "top": set(), "port": set(), "wait": set(), "pause": set(), "unpause": set(),
    "rename": set(), "diff": set(),
}
RUN_LIKE = {"run", "create"}
# run/create short flags that take a value; every other short run flag (-d -i -P -q -t) is boolean.
RUN_SHORT_VALUES = {"-a", "-c", "-e", "-h", "-l", "-m", "-p", "-u", "-v", "-w"}
NAMED_VOLUME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
RAW_PASSTHRU = {"context", "login", "logout", "help", "completion", "--help", "-h",
                "--version", "-v", "version", "plugin", "trust", "scout", "init", "desktop",
                "debug", "extension", "sbom", "mcp", "model", "ai", "offload"}
# docker global flags that take a value
GLOBAL_VALUE_FLAGS = {"--config", "-c", "--context", "-H", "--host", "-l", "--log-level",
                      "--tlscacert", "--tlscert", "--tlskey"}
# long boolean flags of run/create, plus the legacy heuristic for subcommands without a table
# (anything else starting with '--' is assumed to take a value there)
BOOL_FLAGS = {"-d", "--detach", "-i", "--interactive", "-t", "--tty", "--rm", "--privileged",
              "--init", "-P", "--publish-all", "--read-only", "--no-healthcheck",
              "--oom-kill-disable", "-q", "--quiet", "--help", "-a", "--all", "-f",
              "--force", "--follow", "--timestamps", "-s", "--size", "--no-trunc",
              "--details", "-n", "--no-stream", "--no-color", "--use-api-socket"}
SHORT_BOOL_CHARS = set("ditPqafs")
COMPOSE_VALUE_FLAGS = {"-f", "--file", "-p", "--project-name", "--project-directory",
                       "--env-file", "--profile", "--ansi", "--progress", "--parallel"}


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


def log(msg, path=LOG_PATH):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n"
    try:
        ensure_dirs()
        if os.path.exists(path) and os.path.getsize(path) > 2_000_000:
            os.replace(path, path + ".1")
        with open(path, "a") as f:
            f.write(line)
    except OSError:
        pass


def real_docker():
    """The actual docker CLI: first `docker` on PATH (plus known spots) that is not our shim."""
    shim = os.path.realpath(SHIM_SRC)
    dirs = os.environ.get("PATH", "").split(":") + [
        "/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin"]
    for d in dirs:
        p = os.path.join(d, "docker")
        if os.path.isfile(p) and os.access(p, os.X_OK) and os.path.realpath(p) != shim:
            return p
    raise SystemExit("rdocker: no real docker CLI found (install Docker Desktop or `brew install docker`)")


def run(cmd, timeout=30, input_=None):
    """Run a command quietly; return (rc, stdout, stderr). Never raises on failure."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=input_)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 124, "", str(e)


def dk(ctx, *args, timeout=30):
    return run([real_docker(), "--context", ctx] + list(args), timeout=timeout)


# ---------------------------------------------------------------------------- health

def local_engine_up(cfg):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.5)
    try:
        s.connect(cfg["local_socket"])
        return True
    except OSError:
        return False
    finally:
        s.close()


PROBE_TIMEOUT = 4        # seconds per raw-socket health request to the mini engine
HEALTH_WAIT = 5          # seconds a shim waits for another process's in-flight probe


class ProbeError(Exception):
    """The docker engine API did not give a usable HTTP answer over the forwarded socket."""


def _dechunk(body):
    """Decode an HTTP/1.1 chunked body (trailers ignored)."""
    out, i = b"", 0
    while True:
        j = body.find(b"\r\n", i)
        if j < 0:
            raise ProbeError("truncated chunked body")
        size = int(body[i:j].split(b";")[0].strip() or b"0", 16)
        if size == 0:
            return out
        out += body[j + 2:j + 2 + size]
        i = j + 2 + size + 2


def http_unix(path, req_path, timeout=PROBE_TIMEOUT):
    """-> (status, body bytes): one `GET req_path` (Connection: close) to the docker API on the unix
    socket at `path`. Raises ProbeError/OSError (incl. socket.timeout) on any failure; the whole
    exchange must finish within `timeout` seconds."""
    deadline = time.time() + timeout
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(timeout)
        s.connect(path)
        s.sendall(("GET %s HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n"
                   % req_path).encode())
        data = b""
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise socket.timeout("probe deadline exceeded")
            s.settimeout(left)
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
            if len(data) > 1 << 20:
                raise ProbeError("oversized response")
    finally:
        s.close()
    head, sep, body = data.partition(b"\r\n\r\n")
    if not sep:
        raise ProbeError("no HTTP header terminator")
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split(" ", 2)
    if len(parts) < 2 or not parts[0].startswith("HTTP/") or not parts[1].isdigit():
        raise ProbeError("bad status line %r" % lines[0][:80])
    hdrs = {}
    for line in lines[1:]:
        k, _, v = line.partition(":")
        hdrs[k.strip().lower()] = v.strip()
    if "chunked" in hdrs.get("transfer-encoding", "").lower():
        body = _dechunk(body)
    elif hdrs.get("content-length", "").isdigit():
        body = body[:int(hdrs["content-length"])]
    return int(parts[1]), body


def docker_probe(cfg):
    """-> (ok, server_version, elapsed_ms) by speaking HTTP straight to the forwarded mini socket.

    ok = `GET /_ping` answered 200 "OK"; elapsed_ms times only that request (no docker CLI start-up,
    which used to add ~250 ms and push a ~75 ms link over max_rtt_ms). server_version comes from a
    follow-up `GET /version` and is "" when that one fails (the engine is still up)."""
    ensure_mini_socket(cfg)
    t0 = time.time()
    try:
        status, body = http_unix(MINI_SOCK, "/_ping", PROBE_TIMEOUT)
    except (OSError, ProbeError, ValueError):
        return False, "", round((time.time() - t0) * 1000, 1)
    ms = round((time.time() - t0) * 1000, 1)
    if status != 200 or body.strip() != b"OK":
        return False, "", ms
    ver = ""
    try:
        status, body = http_unix(MINI_SOCK, "/version", PROBE_TIMEOUT)
        if status == 200:
            ver = str(json.loads(body.decode("utf-8", "replace")).get("Version") or "")
    except (OSError, ProbeError, ValueError, AttributeError):
        pass
    return True, ver, ms


def reset_master(cfg):
    """Drop a possibly-wedged SSH master (e.g. after a network change) and rebuild it."""
    ensure_dirs()
    with file_lock(LOCK_PATH):
        ssh_ctl(cfg, "-O", "exit", timeout=5)
        ensure_master(cfg)


def tunnel_alive(cfg):
    """Cheap authenticated liveness check over the EXISTING master (a session channel, no new TCP).

    Only meaningful while a master exists: with no master, ssh -S would fall back to a fresh
    connection, so callers check master_pid first."""
    rc, _, _ = run(["ssh", "-S", FWD_SOCK, "-o", "BatchMode=yes", cfg["host"], "true"], timeout=5)
    return rc == 0


def classify_probe_failure(docker_ok, ssh_ok):
    """Why the docker probe failed -> 'engine' (tunnel fine: keep master + mirrors) or 'tunnel'
    (stale master: exit + rebuild + retry). None when the docker probe succeeded."""
    if docker_ok:
        return None
    return "engine" if ssh_ok else "tunnel"


def probe_health(cfg):
    """Authenticated health reading - no raw TCP to the mini's sshd (OpenSSH PerSourcePenalties).

    docker_ok = the mini engine answered `GET /_ping` on the forwarded socket within PROBE_TIMEOUT;
    rtt_ms = that request's round-trip; reachable = engine answered or the ssh master is up and live.
    On failure with a master present, `ssh ... true` over the master decides: live -> engine
    problem (slow/down docker), the master and every port mirror are left alone; dead/timeout ->
    stale tunnel, so exit + rebuild the master and retry the probe once. With no master at all the
    mini is simply unreachable (ensure_mini_socket already tried to connect) - no second attempt."""
    ok, ver, ms = docker_probe(cfg)
    if not ok and master_pid(cfg):
        if classify_probe_failure(ok, tunnel_alive(cfg)) == "engine":
            return {"ts": time.time(), "reachable": True, "docker_ok": False,
                    "rtt_ms": None, "server_version": ""}
        log("ssh master stale (liveness check failed) -> rebuilding")
        reset_master(cfg)
        ok, ver, ms = docker_probe(cfg)
    reachable = ok or master_pid(cfg) is not None
    return {"ts": time.time(), "reachable": reachable, "docker_ok": ok,
            "rtt_ms": ms if ok else None, "server_version": ver}


def health_fresh(h, now=None):
    """A reading is usable iff 0 <= age < HEALTH_TTL (future-dated readings are rejected)."""
    if not isinstance(h, dict) or not isinstance(h.get("ts"), (int, float)):
        return False
    age = (time.time() if now is None else now) - h["ts"]
    return 0 <= age < HEALTH_TTL


def _flock_wait(fh, wait):
    deadline = time.time() + wait
    while True:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.time() >= deadline:
                return False
            time.sleep(0.1)
        except OSError:
            return False


def refresh_health(cfg, reuse_fresh=False):
    """Probe under HEALTH_LOCK and write health.json. If another process is already probing, wait
    up to HEALTH_WAIT for it; with reuse_fresh, use its reading when it is fresh."""
    fh = None
    try:
        ensure_dirs()
        fh = open(HEALTH_LOCK, "a+")
    except OSError as e:
        log("health lock unavailable (%s); probing unlocked" % e)
    try:
        if fh is not None:
            _flock_wait(fh, HEALTH_WAIT)
        if reuse_fresh:
            h = load_json(HEALTH_PATH, None)
            if health_fresh(h):
                return h
        h = probe_health(cfg)
        write_state(HEALTH_PATH, h)
        return h
    finally:
        if fh is not None:
            fh.close()      # closing releases the flock


def health(cfg, force=False):
    if not force:
        h = load_json(HEALTH_PATH, None)
        if health_fresh(h):
            return h
    return refresh_health(cfg, reuse_fresh=not force)


def resolve_target(cfg):
    """-> ('mini'|'local', reason)."""
    mode = os.environ.get("RDOCKER_MODE") or cfg["mode"]
    if mode in ("mini", "local"):
        return mode, "mode=" + mode
    h = health(cfg)
    if not h.get("reachable"):
        return "local", "mini unreachable"
    if h.get("docker_ok") is False:
        return "local", "mini docker engine not responding"
    return "mini", "ok"     # RTT only steers new throwaway containers (route_creating), not this


def ensure_local_running(cfg):
    if local_engine_up(cfg):
        return True
    say("starting local Docker Desktop (needed for this command)...")
    run(["open", "-ga", "Docker"], timeout=10)
    for _ in range(90):
        time.sleep(1)
        if local_engine_up(cfg) and dk(cfg["local_context"], "info", "--format", "x",
                                       timeout=5)[0] == 0:
            return True
    say("local Docker Desktop did not come up within 90s")
    return False


# ---------------------------------------------------------------------------- arg parsing

def split_global(argv):
    """-> (global_flags, rest). rest[0] is the subcommand (if any)."""
    i = 0
    while i < len(argv):
        a = argv[i]
        if not a.startswith("-") or a == "-":
            break
        if a in GLOBAL_VALUE_FLAGS:
            i += 2
            continue
        i += 1
    return argv[:i], argv[i:]


def flag_width(args, i, sub=None):
    """How many argv slots the flag at args[i] occupies (1, or 2 when its value is the next arg).

    Subcommands with a VALUE_FLAGS_BY_SUB table: listed flags take a value, everything else is
    boolean. run/create: RUN_SHORT_VALUES + "long flags not in BOOL_FLAGS take a value". Other
    subcommands keep the old heuristic. A short cluster is boolean up to its first value char;
    anything after that char is the attached value (-it, -n5, -p5432:5432, -itv/x:/y)."""
    a = args[i]
    values = VALUE_FLAGS_BY_SUB.get(sub)
    if a.startswith("--"):
        if "=" in a:
            return 1
        if values is not None:
            return 2 if a in values else 1
        return 1 if a in BOOL_FLAGS else 2
    if values is None and sub in RUN_LIKE:
        values = RUN_SHORT_VALUES
    if values is None:
        return 1 if (a in BOOL_FLAGS or set(a[1:]) <= SHORT_BOOL_CHARS or len(a) > 2) else 2
    for j in range(1, len(a)):
        if "-" + a[j] in values:
            return 1 if j < len(a) - 1 else 2
    return 1


def short_bools(a, sub=None):
    """Boolean letters of a short-flag cluster (those before its first value-taking letter)."""
    if a.startswith("--") or not a.startswith("-"):
        return ""
    values = VALUE_FLAGS_BY_SUB.get(sub)
    if values is None and sub in RUN_LIKE:
        values = RUN_SHORT_VALUES
    if values is None:
        return a[1:] if set(a[1:]) <= SHORT_BOOL_CHARS else ""
    out = ""
    for ch in a[1:]:
        if "-" + ch in values:
            break
        out += ch
    return out


def positionals(args, sub=None):
    """Positional args of `sub` (everything after '--' is positional)."""
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            out.extend(args[i + 1:])
            break
        if a.startswith("-") and len(a) > 1:
            i += flag_width(args, i, sub)
            continue
        out.append(a)
        i += 1
    return out


def skip_flag(args, i, sub="run"):
    """Index after the flag at args[i] (and its value, if it takes one)."""
    return i + flag_width(args, i, sub)


def positionals_index(args, sub="run"):
    """Index of the first positional (the image for run) - flags before it belong to docker."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--" or a == "-" or not a.startswith("-"):
            return i
        i = skip_flag(args, i, sub)
    return i


def is_detached(args, sub="run"):
    """-d/--detach among the flags BEFORE the first positional (after the image it is the
    container's own argument)."""
    i, end = 0, positionals_index(args, sub)
    while i < end:
        a = args[i]
        if a in ("-d", "--detach", "--detach=true") or "d" in short_bools(a, sub):
            return True
        i = skip_flag(args, i, sub)
    return False


def flag_values(args, names, sub="run"):
    """Values of the given flags (`--x v`, `--x=v`, `-xv`) before the first positional (the image)."""
    vals, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--" or a == "-" or not a.startswith("-"):
            break
        if a in names:
            if i + 1 < len(args):
                vals.append(args[i + 1])
            i += 2
            continue
        m = next((n for n in names if n.startswith("--") and a.startswith(n + "=")), None)
        if m is None:
            m = next((n for n in names if not n.startswith("--") and a.startswith(n)
                      and len(a) > len(n)), None)
            if m is not None:
                vals.append(a[len(m):])
                i += 1
                continue
        else:
            vals.append(a[len(m) + 1:])
            i += 1
            continue
        i = skip_flag(args, i, sub)
    return vals


def is_bind_source(src):
    if src in ("/var/run/docker.sock", "/run/docker.sock"):
        return False
    return src.startswith(("/", ".", "~", "$"))


def run_needs_local(args):
    """run/create: bind mounts of laptop paths or host networking must run on the laptop."""
    for v in flag_values(args, ["-v", "--volume"]):
        if ":" in v and is_bind_source(v.split(":", 1)[0]):
            return "bind mount " + v.split(":", 1)[0]
    for v in flag_values(args, ["--mount"]):
        if "type=bind" in v:
            return "bind mount (--mount)"
    for v in flag_values(args, ["--network", "--net"]):
        if v == "host":
            return "--network host"
    return None


def run_named_volumes(args):
    """Named volumes mounted by run/create flags (bind paths and anonymous volumes excluded)."""
    vols = []
    for v in flag_values(args, ["-v", "--volume"]):
        src = v.split(":", 1)[0] if ":" in v else ""
        if src and NAMED_VOLUME_RE.match(src):
            vols.append(src)
    for v in flag_values(args, ["--mount"]):
        kv = dict(p.split("=", 1) for p in v.split(",") if "=" in p)
        src = kv.get("source") or kv.get("src") or ""
        if kv.get("type", "volume") == "volume" and NAMED_VOLUME_RE.match(src):
            vols.append(src)
    return vols


def run_not_throwaway(args):
    """None when a run/create is throwaway (--rm, or no named volume and no rdocker.keep label);
    otherwise the reason it must not silently land on the laptop."""
    head = args[:positionals_index(args)]
    if "--rm" in head or "--rm=true" in head:
        return None
    vols = run_named_volumes(args)
    if vols:
        return "it mounts named volume %s" % vols[0]
    if any(lbl.split("=", 1)[0] == "rdocker.keep"
           for lbl in flag_values(args, ["-l", "--label"])):
        return "it carries the rdocker.keep label"
    return None


def compose_split(args):
    """compose args -> (compose_global_flags, compose_subcommand, rest)."""
    i = 0
    while i < len(args):
        a = args[i]
        if not a.startswith("-"):
            break
        i += 1 if ("=" in a or a not in COMPOSE_VALUE_FLAGS) else 2
    sub = args[i] if i < len(args) else ""
    return args[:i], sub, args[i + 1:]


_COMPOSE_MODELS = {}


def compose_model(cflags):
    """The compose model rendered client-side (`compose config --format json`, no daemon needed);
    None when unreadable. Rendered once per shim call."""
    key = tuple(cflags)
    if key not in _COMPOSE_MODELS:
        rc, out, _ = run([real_docker(), "compose"] + cflags + ["config", "--format", "json"],
                         timeout=20)
        model = None
        if rc == 0:
            try:
                model = json.loads(out)
            except ValueError:
                model = None
        _COMPOSE_MODELS[key] = model if isinstance(model, dict) else None
    return _COMPOSE_MODELS[key]


def compose_inspect(cflags):
    """-> (project, needs_local_reason, named_volumes) from the compose model. named_volumes is None
    if the model is unreadable."""
    model = compose_model(cflags)
    if not isinstance(model, dict):
        given = flag_values(cflags, ["-p", "--project-name"], sub=None)
        return (given[-1] if given else None), None, None
    project = model.get("name")
    named = sorted((model.get("volumes") or {}).keys())
    for name, svc in (model.get("services") or {}).items():
        if svc.get("network_mode") == "host":
            return project, "service %s uses network_mode: host" % name, named
        for vol in svc.get("volumes") or []:
            if not isinstance(vol, dict):
                continue
            if vol.get("type") == "bind" and is_bind_source(vol.get("source", "")):
                return project, "service %s bind-mounts %s" % (name, vol.get("source")), named
            if vol.get("type") == "volume" and vol.get("source") and vol["source"] not in named:
                named.append(vol["source"])
    return project, None, named


def container_targets(sub, args):
    pos = positionals(args, sub)
    if not pos:
        return []
    if sub == "cp":
        return [p.split(":", 1)[0] for p in pos if ":" in p and not p.startswith(("/", "."))][:1]
    if sub in MULTI_TARGET:
        return pos
    return pos[:1]       # top: the rest is opaque ps args; exec/run-like: the rest is the command


def exists_on(cfg, ctx_key, name):
    """Tri-state: True (exists), False (engine answered "No such ..."), None (could not tell)."""
    rc, out, err = dk(cfg[ctx_key], "container", "inspect", "--format", "{{.Id}}", name, timeout=12)
    if rc == 0:
        return True
    return False if "no such" in (err + out).lower() else None


def project_on(cfg, ctx_key, project):
    """Tri-state: does compose project `project` have any container (any state) on this engine?"""
    rc, out, _ = dk(cfg[ctx_key], "ps", "-a", "-q", "--filter",
                    "label=com.docker.compose.project=" + project, timeout=12)
    if rc != 0:
        return None
    return bool(out.strip())


# ---------------------------------------------------------------------------- port mirroring

# Laptop mirrors bind 127.0.0.1:<p> and [::1]:<p> and forward to the mini's 127.0.0.1:<p>, so only
# bindings the mini serves on loopback/any are mirrored (HostIp as `docker inspect` reports it).
MIRROR_IPS = ("", "0.0.0.0", "127.0.0.1", "::")
PORTS_LOCK = os.path.join(STATE_DIR, "ports.lock")       # guards reserved.json
RESERVED_PATH = os.path.join(STATE_DIR, "reserved.json")  # {"<port>": expiry_epoch}
CID_DIR = os.path.join(STATE_DIR, "cid")
RESERVE_TTL = 120        # seconds a laptop port stays reserved for a shim that is creating a container
BIG_RANGE = 1000         # a single container publishing more ports than this is logged
ALLOC_TEXT = "port is already allocated"


class PortRefuse(Exception):
    """A publish cannot be honoured on the laptop; printed and the shim exits 125 (docker's own
    code for a failed run/create) without running docker."""


def laptop_free(p):
    """True iff laptop port `p` is free the way `ssh -L` will need it: 127.0.0.1:p and [::1]:p both
    bind with SO_REUSEADDR (an unavailable IPv6 stack counts as fine) and nothing answers a connect
    on either (SO_REUSEADDR alone would let us bind next to a wildcard listener)."""
    for fam, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            s = socket.socket(fam, socket.SOCK_STREAM)
        except OSError:
            if fam == socket.AF_INET6:
                continue
            return False
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((addr, p))
        except OSError as e:
            if not (fam == socket.AF_INET6 and e.errno in (errno.EADDRNOTAVAIL, errno.EAFNOSUPPORT)):
                return False
        finally:
            s.close()
    for fam, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            s = socket.socket(fam, socket.SOCK_STREAM)
        except OSError:
            continue
        s.settimeout(0.3)
        try:
            if s.connect_ex((addr, p)) == 0:
                return False
        except OSError:
            pass
        finally:
            s.close()
    return True


def _port_range(text):
    """'5432' -> (5432, 5432); '8000-8010' -> (8000, 8010); '' -> None. ValueError on junk."""
    if text == "":
        return None
    lo, _, hi = text.partition("-")
    lo, hi = int(lo), int(hi) if hi else int(lo)
    if not (0 < lo <= hi <= 65535):
        raise ValueError(text)
    return lo, hi


def parse_publish(value):
    """A `-p` value -> {"ip", "host": (lo, hi)|None, "cport": (lo, hi), "proto", "proto_given"};
    None when unparsable (docker then reports it). Forms: cport, cport/tcp, hp:cp, ip:hp:cp,
    ip::cp, [v6]:hp:cp, and ranges h1-h2:c1-c2 / c1-c2."""
    v, proto, given = value, "tcp", False
    if "/" in v:
        v, proto = v.rsplit("/", 1)
        given = True
    ip = ""
    try:
        if v.startswith("["):
            close = v.index("]")
            ip, rest = v[1:close], v[close + 1:]
            if not rest.startswith(":"):
                return None
            parts = rest[1:].split(":")
            if len(parts) != 2:
                return None
            host, cport = parts
        else:
            parts = v.split(":")
            if len(parts) == 1:
                host, cport = "", parts[0]
            elif len(parts) == 2:
                host, cport = parts
            elif len(parts) == 3:
                ip, host, cport = parts
            else:
                return None
        h, c = _port_range(host), _port_range(cport)
    except ValueError:
        return None
    if c is None:
        return None
    return {"ip": ip, "host": h, "cport": c, "proto": proto.lower() or "tcp", "proto_given": given}


def format_publish(s):
    ip = ("[%s]:" % s["ip"] if ":" in s["ip"] else s["ip"] + ":") if s["ip"] else ""
    rng = lambda r: str(r[0]) if r[0] == r[1] else "%d-%d" % r  # noqa: E731
    host = rng(s["host"]) if s["host"] else ""
    out = "%s%s:%s" % (ip, host, rng(s["cport"])) if (ip or host) else rng(s["cport"])
    return out + ("/" + s["proto"] if s["proto_given"] else "")


def mirrored_spec(s):
    return s["ip"] in MIRROR_IPS


def _load_reserved(now):
    out, cur = {}, load_json(RESERVED_PATH, {})
    for k, v in (cur.items() if isinstance(cur, dict) else []):
        try:
            if float(v) > now:
                out[int(k)] = float(v)
        except (TypeError, ValueError):
            continue
    return out


def mirrored_ports():
    """Laptop ports that are currently our own mirrors (owned by mini containers)."""
    st = load_json(FORWARDS_PATH, {})
    return set(st.get("tcp4") or []) if isinstance(st, dict) else set()


def _alloc_msg(p):
    return ("docker: Error response from daemon: driver failed programming external connectivity: "
            "Bind for 127.0.0.1:%d failed: %s (on the laptop - rdocker)" % (p, ALLOC_TEXT))


def reserve_ports(cfg, specs, exclude=()):
    """Preflight + reserve the laptop side of TCP publishes, under ports.lock.

    specs: parse_publish() dicts (None entries pass through). Ephemeral host ports (host None) get
    the first free port/contiguous block from ephemeral_port_range and are filled in; fixed ports
    must be free on the laptop and not reserved by another shim. A fixed port that already is one
    of our mirrors is left to the mini (which reports its own "already allocated"). Raises PortRefuse.
    -> (specs', reserved_ports)."""
    lo, hi = (cfg.get("ephemeral_port_range") or DEFAULTS["ephemeral_port_range"])[:2]
    ours = mirrored_ports()
    ensure_dirs()
    with file_lock(PORTS_LOCK):
        now = time.time()
        res = _load_reserved(now)
        taken = set(res) | set(exclude)
        out, mine = [], []
        for s in specs:
            if s is None:
                out.append(s)
                continue
            if s["proto"] != "tcp":
                raise PortRefuse("UDP publishes are not mirrored to the laptop" if s["proto"] == "udp"
                                 else "%s publishes are not mirrored to the laptop" % s["proto"].upper())
            if not mirrored_spec(s):
                out.append(s)
                continue
            n = s["cport"][1] - s["cport"][0] + 1
            if s["host"] is None or (n == 1 and s["host"][0] != s["host"][1]):
                # ephemeral (or docker's "any port of this host range" for one container port)
                a, b = (lo, hi) if s["host"] is None else s["host"]
                start = None
                for p in range(a, b - n + 2):
                    block = range(p, p + n)
                    if any(q in taken or q in ours for q in block):
                        continue
                    if all(laptop_free(q) for q in block):
                        start = p
                        break
                if start is None:
                    raise PortRefuse("no free laptop port for -p %s in %d-%d"
                                     % (format_publish(s), a, b))
                s = dict(s, host=(start, start + n - 1))
            else:
                for p in range(s["host"][0], s["host"][1] + 1):
                    if p in ours and p not in res:
                        continue
                    if p in taken or not laptop_free(p):
                        raise PortRefuse(_alloc_msg(p))
            block = list(range(s["host"][0], s["host"][1] + 1))
            taken.update(block)
            mine.extend(p for p in block if p not in ours)
            out.append(s)
        for p in mine:
            res[p] = now + RESERVE_TTL
        try:
            save_json(RESERVED_PATH, {str(p): t for p, t in sorted(res.items())})
        except OSError as e:
            log("port reservation not saved: %s" % e)
    return out, mine


def release_ports(ports):
    if not ports:
        return
    try:
        with file_lock(PORTS_LOCK):
            res = _load_reserved(time.time())
            for p in ports:
                res.pop(p, None)
            save_json(RESERVED_PATH, {str(p): t for p, t in sorted(res.items())})
    except OSError as e:
        log("port reservation not released: %s" % e)


def publish_slots(args):
    """run/create `-p` occurrences before the image -> [(argv index, prefix, value)], so a value can
    be rewritten in place as args[index] = prefix + new_value. Handles -p v, -pv, -dp v, --publish v,
    --publish=v."""
    out, i, end = [], 0, positionals_index(args)
    while i < end:
        a = args[i]
        if a in ("-p", "--publish"):
            if i + 1 < len(args):
                out.append((i + 1, "", args[i + 1]))
            i += 2
            continue
        if a.startswith("--publish="):
            out.append((i, "--publish=", a[len("--publish="):]))
            i += 1
            continue
        if a.startswith("-") and not a.startswith("--"):
            j = 1 + len(short_bools(a, "run"))
            if j < len(a) and a[j] == "p":
                if j + 1 < len(a):
                    out.append((i, a[:j + 1], a[j + 1:]))
                    i += 1
                elif i + 1 < len(args):
                    out.append((i + 1, "", args[i + 1]))
                    i += 2
                else:
                    i += 1
                continue
        i = skip_flag(args, i, "run")
    return out


def publishes_all(args):
    head = args[:positionals_index(args)]
    return any(a in ("--publish-all", "--publish-all=true") or "P" in short_bools(a, "run")
               for a in head)


def mirror_ports_of(netports):
    """NetworkSettings.Ports -> set of host ports a laptop mirror should exist for (tcp only)."""
    out = set()
    for key, binds in (netports or {}).items():
        if not str(key).endswith("/tcp"):
            continue
        for b in binds or []:
            if isinstance(b, dict) and b.get("HostIp", "") in MIRROR_IPS \
                    and str(b.get("HostPort", "")).isdigit():
                out.add(int(b["HostPort"]))
    return out


def inspect_containers(cfg, ids):
    """`docker inspect` of mini containers -> list of dicts. Uses stdout even when rc != 0 (one id
    vanished); None when nothing parsable came back."""
    if not ids:
        return []
    rc, out, err = dk(cfg["remote_context"], "inspect", *ids, timeout=30)
    try:
        data = json.loads(out) if out.strip() else None
    except ValueError:
        data = None
    if not isinstance(data, list):
        log("docker inspect on mini failed (rc=%s): %s" % (rc, err.strip()[:200]))
        return None
    return [d for d in data if isinstance(d, dict)]


def published_ports(cfg, ids):
    """{container id: mirrorable ports} for those of `ids` that are running now."""
    out = {}
    for d in inspect_containers(cfg, list(ids)) or []:
        if (d.get("State") or {}).get("Running"):
            out[d.get("Id", "")] = mirror_ports_of((d.get("NetworkSettings") or {}).get("Ports"))
    return out


def remote_ports(cfg):
    """Every laptop-mirrorable published TCP port of the mini's running containers."""
    rc, out, err = dk(cfg["remote_context"], "ps", "-q", "--no-trunc", timeout=20)
    if rc != 0:
        raise RuntimeError("docker ps on mini failed: " + err.strip()[:200])
    ids = out.split()
    data = inspect_containers(cfg, ids)
    if data is None:
        raise RuntimeError("docker inspect on mini returned nothing parsable")
    ports = set()
    for d in data:
        if not (d.get("State") or {}).get("Running", True):
            continue
        mine = mirror_ports_of((d.get("NetworkSettings") or {}).get("Ports"))
        if len(mine) > BIG_RANGE:
            log("container %s publishes %d ports - mirroring all of them"
                % (d.get("Name", d.get("Id", "?")[:12]), len(mine)))
        ports |= mine
    return ports


def ssh_ctl(cfg, *args, timeout=10):
    return run(["ssh", "-S", FWD_SOCK] + list(args) + [cfg["host"]], timeout=timeout)


def master_pid(cfg):
    rc, _, err = ssh_ctl(cfg, "-O", "check", timeout=5)
    m = re.search(r"pid=(\d+)", err)
    return int(m.group(1)) if rc == 0 and m else None


def unix_alive(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect(path)
        return True
    except OSError:
        return False
    finally:
        s.close()


def ensure_master(cfg):
    """One SSH ControlMaster carries both the mini docker socket and every port mirror.

    Docker traffic rides it as stream channels (not SSH sessions), so parallel agents never hit
    sshd's MaxSessions, and no ssh process / remote `docker dial-stdio` is spawned per command."""
    pid = master_pid(cfg)
    if not pid:
        for f in (FWD_SOCK, MINI_SOCK):
            try:
                os.unlink(f)
            except OSError:
                pass
        rc, _, err = run(["ssh", "-S", FWD_SOCK, "-M", "-N", "-f", "-o", "ControlPersist=yes",
                          "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ExitOnForwardFailure=no",
                          "-o", "StreamLocalBindUnlink=yes", cfg["host"]], timeout=20)
        if rc != 0:
            log("ssh master start failed: " + err.strip()[:200])
            return None
        pid = master_pid(cfg)
        log("ssh master up pid=%s" % pid)
    if pid and cfg["remote_socket"] and not unix_alive(MINI_SOCK):
        try:
            os.unlink(MINI_SOCK)
        except OSError:
            pass
        rc, _, err = ssh_ctl(cfg, "-O", "forward", "-L", MINI_SOCK + ":" + cfg["remote_socket"])
        if rc != 0:
            log("docker socket forward failed: " + err.strip()[:200])
    return pid


def ensure_mini_socket(cfg):
    """Fast path for the shim: socket answers -> done; else (re)build the master under the lock."""
    if unix_alive(MINI_SOCK):
        return True
    ensure_dirs()
    with open(LOCK_PATH, "w") as lockf:
        fcntl.flock(lockf, fcntl.LOCK_EX)
        ensure_master(cfg)
    return unix_alive(MINI_SOCK)


def sync_forwards(cfg, verbose=False, want=()):
    """Make laptop 127.0.0.1:<p> and [::1]:<p> forward to mini 127.0.0.1:<p> for every published TCP
    port of a running mini container. -> (ok, missing, conflicts):
      missing   = ports in `want` (what the caller just published) with no live IPv4 mirror after
                  this sync (all of `want` when the master or the mini could not be read);
      conflicts = every port whose mirror failed because the laptop port is busy;
      ok        = master + mini answered and nothing in `want` is missing.
    IPv4 and IPv6 mirrors are tracked separately (forwards.json tcp4/tcp6); a missing IPv6 mirror is
    retried on every sync."""
    want = set(want)
    ensure_dirs()
    with open(LOCK_PATH, "w") as lockf:
        fcntl.flock(lockf, fcntl.LOCK_EX)
        pid = ensure_master(cfg)
        if not pid:
            if verbose:
                say("cannot open the SSH control connection to " + cfg["host"])
            return False, sorted(want), []
        state = load_json(FORWARDS_PATH, {})
        same = isinstance(state, dict) and state.get("master_pid") == pid
        legacy = state.get("ports") if same else None     # pre-1.6 format: one list, v4+v6 tried
        cur4 = set(state.get("tcp4", legacy) or []) if same else set()
        cur6 = set(state.get("tcp6", legacy) or []) if same else set()
        conflicts = set(state.get("conflicts") or []) if same else set()
        try:
            desired = remote_ports(cfg)
        except RuntimeError as e:
            log(str(e))
            if verbose:
                say(str(e))
            return False, sorted(want - cur4), sorted(conflicts)
        for p in sorted(desired - cur4):
            rc, _, err = ssh_ctl(cfg, "-O", "forward", "-L", "127.0.0.1:%d:127.0.0.1:%d" % (p, p))
            if rc == 0:
                cur4.add(p)
                conflicts.discard(p)
                log("forward +%d" % p)
            else:
                if p not in conflicts:
                    msg = ("port %d is busy on the laptop; mini container on %d is not mirrored "
                           "(free the laptop port or reach it via %s:%d)" % (p, p, cfg["host"], p))
                    log(msg)
                    if verbose:
                        say(msg)
                conflicts.add(p)
        for p in sorted((cur4 & desired) - cur6):      # IPv6 mirror: best effort, retried each sync
            if ssh_ctl(cfg, "-O", "forward", "-L", "[::1]:%d:127.0.0.1:%d" % (p, p))[0] == 0:
                cur6.add(p)
        for p in sorted(cur4 - desired):
            ssh_ctl(cfg, "-O", "cancel", "-L", "127.0.0.1:%d:127.0.0.1:%d" % (p, p))
            if p in cur6:
                ssh_ctl(cfg, "-O", "cancel", "-L", "[::1]:%d:127.0.0.1:%d" % (p, p))
            cur4.discard(p)
            log("forward -%d" % p)
        cur6 &= cur4
        conflicts &= desired
        write_state(FORWARDS_PATH, {"master_pid": pid, "tcp4": sorted(cur4), "tcp6": sorted(cur6),
                                    "conflicts": sorted(conflicts), "ts": time.time()})
        missing = want - cur4
        return not missing, sorted(missing), sorted(conflicts)


def spawn_bg_sync(repeat=6, interval=1.5):
    """Detached sync loop - for foreground `docker run -p` and async cleanup after stop/rm."""
    try:
        subprocess.Popen([sys.executable, "-I", os.path.realpath(__file__), "sync",
                          "--repeat", str(repeat), "--interval", str(interval)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


# ---------------------------------------------------------------------------- the shim

# Execute-once bookkeeping: set right before docker runs, so main()'s catch-all never re-runs a
# command (a second `run -d`) when routing code fails AFTER docker already ran. The single explicit
# exception is mini_run's one retry after the mini reports an ephemeral port as already allocated:
# that first attempt left only a Created container (removed by cid) and nothing running.
INVOKED = {"invoked": False, "rc": None}


class Refuse(Exception):
    """The shim cannot route safely; the message is printed and the shim exits 1 without docker."""


def exec_real(args):
    d = real_docker()
    prev = INVOKED["invoked"]
    INVOKED["invoked"] = True
    try:
        os.execv(d, [d] + args)
    except OSError:
        INVOKED["invoked"] = prev       # docker never started
        raise


def call_docker(cmd):
    prev = INVOKED["invoked"]
    INVOKED["invoked"] = True
    try:
        rc = subprocess.call(cmd)
    except OSError:
        INVOKED["invoked"] = prev
        raise
    INVOKED["rc"] = rc
    return rc


def cwd():
    try:
        return os.getcwd()
    except OSError:             # the working directory was deleted under us
        return "?"


def port_refuse_exit(e):
    msg = str(e)
    sys.stderr.write((msg if msg.startswith("docker:") else "rdocker: " + msg) + "\n")
    log("port refuse: %s | %s" % (msg, cwd()), ROUTE_LOG)
    sys.exit(125)


def call_docker_capture(cmd):
    """Run docker with stdin/stdout inherited and stderr teed: re-emitted to our stderr unchanged as
    it arrives, and returned so the shim can recognise "port is already allocated". -> (rc, stderr)."""
    prev = INVOKED["invoked"]
    INVOKED["invoked"] = True
    try:
        child = subprocess.Popen(cmd, stderr=subprocess.PIPE)
    except OSError:
        INVOKED["invoked"] = prev
        raise
    chunks = []
    out = getattr(sys.stderr, "buffer", None)
    while True:
        b = os.read(child.stderr.fileno(), 65536)
        if not b:
            break
        chunks.append(b)
        if out is not None:
            out.write(b)
            out.flush()
    child.stderr.close()
    rc = child.wait()
    INVOKED["rc"] = rc
    return rc, b"".join(chunks).decode("utf-8", "replace")


def run_watched(cmd, watch):
    """Foreground docker (run without -d, compose up/run attached): a child with inherited
    stdin/stdout/stderr - never os.execv, so the shim can act afterwards. `watch(child)` runs in a
    thread (mirror sync + cleanup); if it returns False the shim exits 1 once docker returns.
    SIGTERM/SIGHUP are forwarded to the child; SIGINT too unless it came from the child's terminal
    (then the child already received it)."""
    prev = INVOKED["invoked"]
    INVOKED["invoked"] = True
    try:
        child = subprocess.Popen(cmd)
    except OSError:
        INVOKED["invoked"] = prev
        raise
    result = {"ok": True}

    def body():
        try:
            result["ok"] = watch(child) is not False
        except Exception as e:      # a watcher bug must not turn into a second docker run
            log("foreground watcher error: %r" % e)

    def forward(signum, _frame):
        if signum == signal.SIGINT:
            try:
                if os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
                    return
            except OSError:
                pass
        try:
            child.send_signal(signum)
        except OSError:
            pass

    old = {}
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            old[sig] = signal.signal(sig, forward)
        except (OSError, ValueError):
            pass
    t = threading.Thread(target=body, daemon=True)
    t.start()
    try:
        rc = child.wait()
        t.join(timeout=60)
    finally:
        for sig, h in old.items():
            signal.signal(sig, h)
    INVOKED["rc"] = rc
    return rc if result["ok"] else 1


def read_cid(path):
    try:
        with open(path) as f:
            return f.read().strip() or None
    except OSError:
        return None


def rm_created(cfg, ids, why):
    for cid in ids:
        rc, _, err = dk(cfg["remote_context"], "rm", "-f", cid, timeout=60)
        if rc == 0:
            say("removed container %s (just created by this command): %s" % (cid[:12], why))
            log("removed just-created %s: %s" % (cid[:12], why))
        else:
            say("could not remove container %s: %s" % (cid[:12], err.strip()[:200]))


def post_check(cfg, ids, created):
    """After containers `ids` started on the mini: sync mirrors and require a live laptop mirror for
    every TCP port they publish. On failure print which ports failed and why, `rm -f` the containers
    of `created` (made by this invocation; pre-existing ones keep running) and return False."""
    want_by = published_ports(cfg, ids)
    want = set().union(*want_by.values()) if want_by else set()
    ok, missing, conflicts = sync_forwards(cfg, verbose=False, want=want)
    if ok or not want:
        return True
    # A container that stopped on its own meanwhile has nothing to mirror - not a failure.
    still = published_ports(cfg, list(want_by))
    alive = set().union(*still.values()) if still else set()
    bad = sorted(set(missing) & alive)
    if not bad:
        return True
    for p in bad:
        if p in conflicts:
            say("port %d is not mirrored to the laptop: laptop port %d is busy (another process "
                "holds it)" % (p, p))
        else:
            say("port %d is not mirrored to the laptop: the SSH mirror could not be set up "
                "(see rdocker logs)" % p)
    owners = [cid for cid, ps in still.items() if ps & set(bad)]
    mine = [c for c in owners if any(c.startswith(x) or x.startswith(c) for x in created)]
    rm_created(cfg, mine, "its published port has no laptop mirror")
    for c in owners:
        if c not in mine:
            say("container %s existed before this command - left running" % c[:12])
    return False


def wait_running(cfg, child, cid):
    """Poll until container `cid` runs or the foreground child exits -> True if running."""
    while child.poll() is None:
        d = inspect_containers(cfg, [cid])
        if d and (d[0].get("State") or {}).get("Running"):
            return True
        if d and (d[0].get("State") or {}).get("Status") in ("exited", "dead"):
            return False
        time.sleep(0.3)
    return False


def project_ids(cfg, project, all_=True):
    rc, out, _ = dk(cfg["remote_context"], "ps", "-q", "--no-trunc", *(["-a"] if all_ else []),
                    "--filter", "label=com.docker.compose.project=" + project, timeout=20)
    return set(out.split()) if rc == 0 else set()


def mini_run(cfg, base, prefix, sub, args, detached):
    """docker run/create on the mini: laptop port preflight + reservation, --cidfile, one retry when
    the mini reports an ephemeral port as already allocated, then mirror post-check. Exits."""
    slots = publish_slots(args)
    specs = [parse_publish(v) for _, _, v in slots]

    def rewrite(cur_args, new_specs):
        a = list(cur_args)
        for (i, pre, _), old, new in zip(slots, specs, new_specs):
            if old is not None and new is not None and new != old:
                a[i] = pre + format_publish(new)
        return a

    try:
        new_specs, reserved = reserve_ports(cfg, specs)
    except PortRefuse as e:
        port_refuse_exit(e)
    user_cid = (flag_values(args, ["--cidfile"]) or [None])[-1]
    ours = []

    def with_cidfile(a):
        if user_cid:
            return a, user_cid
        os.makedirs(CID_DIR, exist_ok=True)
        path = os.path.join(CID_DIR, uuid.uuid4().hex)
        ours.append(path)
        return ["--cidfile", path] + a, path

    try:
        run_args, cidpath = with_cidfile(rewrite(args, new_specs))
        if sub == "run" and not detached:
            def watch(child):
                cid = None
                while child.poll() is None and not cid:
                    cid = read_cid(cidpath)
                    if not cid:
                        time.sleep(0.2)
                if not cid or not wait_running(cfg, child, cid):
                    return True
                ok = post_check(cfg, [cid], [cid])
                release_ports(reserved)
                return ok
            sys.exit(run_watched(base + prefix + run_args, watch))
        rc, err = call_docker_capture(base + prefix + run_args)
        cid = read_cid(cidpath)
        if rc == 125 and ALLOC_TEXT in err:
            # Execute-once exception (documented): the mini refused the port, so the first attempt left
            # only a Created container - removed here - and nothing running. One retry, ephemeral only.
            if cid:
                rm_created(cfg, [cid], "the mini reported its port as already allocated")
            m = re.search(r":(\d+) failed: port is already allocated", err)
            bad = int(m.group(1)) if m else None
            eph = [s for o, s in zip(specs, new_specs) if o is not None and s != o]
            eph_ports = {p for s in eph for p in range(s["host"][0], s["host"][1] + 1)}
            if not eph or (bad is not None and bad not in eph_ports):
                release_ports(reserved)
                sys.exit(rc)
            release_ports(reserved)
            picked = eph_ports if bad is None else {bad}
            if user_cid and read_cid(user_cid) == cid:
                os.unlink(user_cid)
            try:
                new_specs, reserved = reserve_ports(cfg, specs, exclude=picked)
            except PortRefuse as e:
                port_refuse_exit(e)
            run_args, cidpath = with_cidfile(rewrite(args, new_specs))
            say("mini reported port %s as allocated - retrying once with another port"
                % (bad if bad is not None else "?"))
            rc, err = call_docker_capture(base + prefix + run_args)
            cid = read_cid(cidpath)
            if rc == 125 and ALLOC_TEXT in err and cid:
                rm_created(cfg, [cid], "the mini reported its port as already allocated")
        if rc != 0 or sub == "create":
            if rc != 0:
                release_ports(reserved)
            sys.exit(rc)     # create: reservations simply expire (nothing is bound until start)
        ok = post_check(cfg, [cid] if cid else [], [cid] if cid else [])
        release_ports(reserved)
        sys.exit(rc if ok else 1)
    finally:
        if sub == "run":            # create keeps its reservation until the TTL (bound at start)
            release_ports(reserved)
        for path in ours:
            try:
                os.unlink(path)
            except OSError:
                pass


COMPOSE_SUB_VALUES = {
    "up": {"--attach", "--no-attach", "--exit-code-from", "--pull", "--scale", "-t", "--timeout",
           "--wait-timeout"},
    "create": {"--pull", "--scale"},
    "run": {"-e", "--env", "--env-from-file", "-l", "--label", "-p", "--publish", "-u", "--user",
            "-v", "--volume", "-w", "--workdir", "--name", "--entrypoint", "--cap-add", "--cap-drop",
            "--pull"},
}


def compose_sub_parse(csub, crest):
    """-> (positionals, {flag: [values]}) for compose up/create/run (values of COMPOSE_SUB_VALUES)."""
    values = COMPOSE_SUB_VALUES.get(csub, set())
    pos, vals, i = [], {}, 0
    while i < len(crest):
        a = crest[i]
        if a == "--":
            pos.extend(crest[i + 1:])
            break
        if a.startswith("--") and "=" in a:
            k, v = a.split("=", 1)
            vals.setdefault(k, []).append(v)
        elif a in values:
            vals.setdefault(a, []).append(crest[i + 1] if i + 1 < len(crest) else "")
            i += 1
        elif a.startswith("-") and len(a) > 2 and not a.startswith("--") and a[:2] in values:
            vals.setdefault(a[:2], []).append(a[2:])
        elif not a.startswith("-"):
            pos.append(a)
            if csub == "run":          # after the service name comes the container's command
                pos.extend(crest[i + 1:])
                break
        i += 1
    return pos, vals


def compose_port_specs(model, csub, crest):
    """Published ports a compose up/create/run will bind on the mini (parse_publish-shaped dicts,
    always with a host port: entries without a published port get no preflight - the post-check
    covers them)."""
    services = (model or {}).get("services") or {}
    pos, vals = compose_sub_parse(csub, crest)
    specs = []
    if csub == "run":
        for v in vals.get("-p", []) + vals.get("--publish", []):
            specs.append(parse_publish(v))
        wanted = pos[:1] if "--service-ports" in crest else []
        deps = False
    else:
        wanted = [p for p in pos if p in services] or list(services)
        deps = "--no-deps" not in crest
    seen, todo = set(), list(wanted)
    while todo:
        name = todo.pop()
        if name in seen or name not in services:
            continue
        seen.add(name)
        svc = services[name] or {}
        if deps:
            d = svc.get("depends_on") or {}
            todo.extend(d.keys() if isinstance(d, dict) else d)
        for p in svc.get("ports") or []:
            if isinstance(p, dict):
                try:
                    host = _port_range(str(p.get("published") or ""))
                    tgt = int(p.get("target"))
                except (TypeError, ValueError):
                    continue
                specs.append({"ip": p.get("host_ip") or "", "host": host, "cport": (tgt, tgt),
                              "proto": (p.get("protocol") or "tcp").lower(), "proto_given": True})
            else:
                specs.append(parse_publish(str(p)))
    return [s for s in specs if s is not None and (s["host"] is not None or s["proto"] != "tcp")]


def mini_compose(cfg, base, rest, compose_sub, crest, project, model, detached):
    """compose up/run/create (+start/restart) on the mini: preflight + reservation of the model's
    published ports, then mirror post-check; containers this invocation created are removed when
    their mirror fails. Exits."""
    reserved = []
    if compose_sub in COMPOSE_CREATING:
        try:
            _, reserved = reserve_ports(cfg, compose_port_specs(model, compose_sub, crest))
        except PortRefuse as e:
            port_refuse_exit(e)
    before = project_ids(cfg, project) if project else set()
    try:
        if compose_sub in ("up", "run") and not detached:
            def watch(child):
                stable, last = 0, None
                while child.poll() is None and stable < 3:
                    time.sleep(2)
                    ids = project_ids(cfg, project, all_=False) if project else set()
                    if ids and ids == last:
                        stable += 1
                        continue
                    stable, last = 0, ids
                    if ids and not post_check(cfg, ids, project_ids(cfg, project) - before):
                        return False
                release_ports(reserved)
                return True
            sys.exit(run_watched(base + rest, watch))
        rc = call_docker(base + rest)
        if rc != 0 or compose_sub == "create":
            if rc != 0:
                release_ports(reserved)
            sys.exit(rc)
        ok = True
        if project:
            after = project_ids(cfg, project)
            ok = post_check(cfg, project_ids(cfg, project, all_=False), after - before)
        else:
            sync_forwards(cfg, verbose=True)
        release_ports(reserved)
        sys.exit(rc if ok else 1)
    except Exception:
        release_ports(reserved)
        raise


def pin_names(cfg, kind):
    """Names the config hints live on the laptop: explicit pins + fallback pins of this kind."""
    pins = cfg.get("pins") or {}
    explicit = pins.get("containers" if kind == "container" else "compose_projects") or []
    fb = [p.get("name") for p in pins.get("fallback") or []
          if isinstance(p, dict) and p.get("kind") == kind]
    return set(explicit) | {n for n in fb if n}


def add_fallback_pin(name, kind):
    def apply(cur):
        pins = dict(cur["pins"])
        fb = [p for p in pins.get("fallback") or []
              if not (isinstance(p, dict) and p.get("name") == name and p.get("kind") == kind)]
        pins["fallback"] = fb + [{"name": name, "kind": kind, "ts": time.time()}]
        return {**cur, "pins": pins}
    try:
        update_cfg(apply)
    except (ConfigWriteError, OSError) as e:
        log("fallback pin %s/%s not saved: %s" % (kind, name, e))


def drop_fallback_pins(cfg, names, kind):
    if not any(isinstance(p, dict) and p.get("kind") == kind and p.get("name") in names
               for p in cfg["pins"].get("fallback") or []):
        return

    def apply(cur):
        pins = dict(cur["pins"])
        pins["fallback"] = [p for p in pins.get("fallback") or []
                            if not (isinstance(p, dict) and p.get("kind") == kind
                                    and p.get("name") in names)]
        return {**cur, "pins": pins}
    try:
        update_cfg(apply)
    except (ConfigWriteError, OSError) as e:
        log("fallback pins %s not dropped: %s" % (names, e))


class Engines:
    """Lazily measured engine state for one shim call."""

    def __init__(self, cfg, mode):
        self.cfg, self.mode = cfg, mode
        self._mini = None
        self._laptop = None

    def mini(self):
        """-> (usable, reason): the mini engine answers over a working tunnel (speed not considered)."""
        if self._mini is None:
            h = health(self.cfg)
            if not h.get("reachable"):
                self._mini = (False, "mini unreachable")
            elif h.get("docker_ok") is False:
                self._mini = (False, "mini docker engine not responding")
            else:
                try:
                    ok = ensure_mini_socket(self.cfg)
                except OSError as e:
                    log("ensure_mini_socket: %s" % e)
                    ok = False
                self._mini = (True, "ok") if ok else (False, "cannot open the SSH tunnel to the mini")
        return self._mini

    def slow(self):
        """Reason string when the (usable) mini is slower than max_rtt_ms, else None. Consulted ONLY
        for new throwaway containers (route_creating); every other command ignores RTT."""
        h = health(self.cfg)
        rtt = h.get("rtt_ms") or 0
        if self.cfg["max_rtt_ms"] and rtt > self.cfg["max_rtt_ms"]:
            return "mini round-trip %sms > %sms" % (rtt, self.cfg["max_rtt_ms"])
        return None

    def laptop_up(self):
        if self._laptop is None:
            self._laptop = local_engine_up(self.cfg)
        return self._laptop

    def start_laptop(self):
        self._laptop = ensure_local_running(self.cfg)
        return self._laptop

    def default(self):
        """Engine for commands that are not about an existing container: mini whenever usable (RTT is
        ignored here); auto mode falls back to the laptop with a notice when it is not; mode=mini
        refuses instead."""
        if self.mode == "local":
            return "local", "mode=local"
        ok, why = self.mini()
        if self.mode == "mini":
            if not ok:
                raise Refuse("RDOCKER_MODE=mini but %s - not falling back to the laptop" % why)
            return "mini", "mode=mini"
        if ok:
            return "mini", "ok"
        say("running on the laptop (%s)" % why)
        return "local", why


def locate(eng, names, probe, hinted, readonly, what):
    """-> {name: 'mini'|'local'|'none'}; raises Refuse when any target's location is unknown.

    The mini is asked only over a usable tunnel. The laptop is asked when Docker Desktop is up; if it
    is down and a pin/fallback pin names a target, Desktop is started first. Otherwise a down laptop
    engine counts as "not there". Pins are hints only: the actual location wins."""
    cfg = eng.cfg
    mini_ok, mini_why = eng.mini()
    laptop_known = True
    if not eng.laptop_up() and any(n in hinted for n in names):
        laptop_known = eng.start_laptop()
    owners = {}
    for n in names:
        m = probe(cfg, "remote_context", n) if mini_ok else None
        if not laptop_known:
            lap = None
        else:
            lap = probe(cfg, "local_context", n) if eng.laptop_up() else False
        if m is True and lap is True:
            owners[n] = "local" if n in hinted else "mini"
        elif m is True:
            owners[n] = "mini"
        elif lap is True and m is False:
            owners[n] = "local"
        elif lap is True:       # mini could not answer: it may hold a same-named one
            if not readonly:
                raise Refuse("cannot tell where %s %s lives (%s; found on the laptop, but the mini "
                             "may hold one with the same name) - refusing to guess"
                             % (what, n, mini_why if not mini_ok else "mini did not answer"))
            say("%s %s found only on the laptop (%s) - showing the laptop's"
                % (what, n, mini_why if not mini_ok else "mini did not answer"))
            owners[n] = "local"
        elif m is False and lap is False:
            owners[n] = "none"
        else:
            why = (mini_why if not mini_ok else "mini did not answer") if m is None \
                else "laptop engine did not answer"
            raise Refuse("cannot tell where %s %s lives (%s) - refusing to guess" % (what, n, why))
    return owners


def route_targeted(eng, sub, names, hinted, readonly, what):
    """-> (target, why) or ('split', {'mini': [...], 'local': [...]})."""
    if not names:
        return eng.default()
    if eng.mode == "mini":
        ok, why = eng.mini()
        if not ok:
            raise Refuse("RDOCKER_MODE=mini but %s - not falling back to the laptop" % why)
        return "mini", "mode=mini"
    owners = locate(eng, names, exists_on if what == "container" else project_on,
                    hinted, readonly, what)
    found = {o for o in owners.values() if o != "none"}
    if not found:
        return eng.default()            # nowhere: docker prints its normal "No such" error
    if len(found) == 1:
        target = found.pop()
        return target, "%s %s lives on the %s" % (
            what, next(n for n, o in owners.items() if o == target),
            "laptop" if target == "local" else "mini")
    groups = {"mini": [n for n, o in owners.items() if o in ("mini", "none")],
              "local": [n for n, o in owners.items() if o == "local"]}
    return "split", groups


def route_creating(eng, need_local, not_throwaway, hinted_local):
    """Creating commands (run/create/compose up|run|create) -> (target, why, fell_back)."""
    if need_local:
        return "local", need_local, False
    if hinted_local:
        return "local", hinted_local, False
    if eng.mode == "mini":
        ok, why = eng.mini()
        if not ok:
            raise Refuse("RDOCKER_MODE=mini but %s - not falling back to the laptop" % why)
        return "mini", "mode=mini", False
    ok, why = eng.mini()
    if ok:
        slow = eng.slow()
        if not slow or not_throwaway:   # a slow mini still beats putting kept data on the laptop
            return "mini", "ok", False
        why = slow
    elif not_throwaway:
        raise Refuse("%s, and this is not a throwaway container (%s), so it will not be created on "
                     "the laptop. Retry when the mini is back, add --rm, or force the laptop with "
                     "RDOCKER_MODE=local" % (why, not_throwaway))
    say("running on the laptop (%s)" % why)
    return "local", why, True


def shim(argv):
    cfg = load_cfg()
    mode = os.environ.get("RDOCKER_MODE") or cfg["mode"]
    gflags, rest = split_global(argv)
    explicit = any(f in ("-c", "--context", "-H", "--host") or f.startswith(("--context=", "--host="))
                   for f in gflags) or os.environ.get("DOCKER_HOST") or os.environ.get("DOCKER_CONTEXT")
    if mode == "off" or explicit or os.environ.get("RDOCKER_BYPASS") or not rest \
            or rest[0] in RAW_PASSTHRU:
        exec_real(argv)

    sub, args = rest[0], rest[1:]
    group = None
    if sub in MGMT_GROUPS and args:
        group, sub, args = sub, args[0], args[1:]
    container_cmd = group in (None, "container")
    if container_cmd and sub == "inspect" and group is None:
        types = flag_values(args, ["--type"], sub="inspect")
        container_cmd = not types or types[-1] == "container"

    eng = Engines(cfg, mode)
    compose_sub = compose_project = None
    rm_names = []
    try:
        if sub == "compose" and group is None:
            cflags, compose_sub, crest = compose_split(args)
        if mode == "local":
            target, why = "local", "mode=local"
        elif container_cmd and sub in CONTAINER_TARGETED:
            names = container_targets(sub, args)
            target, why = route_targeted(eng, sub, names, pin_names(cfg, "container"),
                                         sub in READ_ONLY_TARGETED, "container")
            if target == "split":
                groups = why
                opts = [a for a in args if a not in names]
                rc1 = call_docker([real_docker(), "--context", cfg["remote_context"]]
                                  + gflags + [sub] + opts + groups["mini"]) if groups["mini"] else 0
                rc2 = 0
                if groups["local"] and ensure_local_running(cfg):
                    rc2 = call_docker([real_docker(), "--context", cfg["local_context"]]
                                      + gflags + [sub] + opts + groups["local"])
                    if sub == "rm" and rc2 == 0:
                        drop_fallback_pins(cfg, groups["local"], "container")
                elif groups["local"]:
                    rc2 = 1
                log("split %-8s mini=%s laptop=%s | %s" % (sub, groups["mini"], groups["local"], cwd()),
                    ROUTE_LOG)
                if sub in STOP_LIKE and groups["mini"]:
                    spawn_bg_sync(repeat=1)
                sys.exit(rc1 or rc2)
            if sub == "rm":
                rm_names = names
        elif sub == "compose" and compose_sub in COMPOSE_TARGETED:
            compose_project, _, _ = compose_inspect(cflags)
            target, why = route_targeted(eng, "compose " + compose_sub,
                                         [compose_project] if compose_project else [],
                                         pin_names(cfg, "compose"),
                                         compose_sub in COMPOSE_READ_ONLY, "compose project")
        elif container_cmd and sub in RUN_LIKE:
            name = (flag_values(args, ["--name"]) or [None])[-1]
            target, why, fell_back = route_creating(eng, run_needs_local(args),
                                                    run_not_throwaway(args), None)
            if fell_back and name:
                add_fallback_pin(name, "container")
        elif sub == "compose" and compose_sub in COMPOSE_CREATING:
            compose_project, need_local, named = compose_inspect(cflags)
            hinted = None
            if compose_project and compose_project in cfg["pins"]["compose_projects"]:
                hinted = "compose project %s is pinned to the laptop" % compose_project
            elif compose_project and compose_project in pin_names(cfg, "compose") \
                    and eng.laptop_up() and project_on(cfg, "local_context", compose_project):
                hinted = "compose project %s lives on the laptop" % compose_project
            if named is None:
                blocker = "the compose model could not be read"
            else:
                blocker = ("it uses named volume %s" % named[0]) if named else None
            target, why, fell_back = route_creating(eng, need_local, blocker, hinted)
            if fell_back and compose_project:
                add_fallback_pin(compose_project, "compose")
        else:
            target, why = eng.default()
    except Refuse as e:
        say(str(e))
        log("refuse %-8s %s | %s" % (sub, e, cwd()), ROUTE_LOG)
        sys.exit(1)

    if target == "local" and os.environ.get("RDOCKER_VERBOSE"):
        say("running locally: " + why)
    ctx = cfg["remote_context"] if target == "mini" else cfg["local_context"]
    log("%-5s %-8s %s | %s" % (target, sub, why, cwd()), ROUTE_LOG)
    if target == "local" and not ensure_local_running(cfg):
        sys.exit(1)

    base = [real_docker(), "--context", ctx] + gflags

    # Laptop removal of a fallback-created container/project drops its fallback pin.
    if target == "local":
        if rm_names and any(n in pin_names(cfg, "container") for n in rm_names):
            rc = call_docker(base + rest)
            drop_fallback_pins(cfg, rm_names if rc == 0 else
                               [n for n in rm_names if exists_on(cfg, "local_context", n) is False],
                               "container")
            sys.exit(rc)
        if compose_sub == "down" and compose_project \
                and compose_project in pin_names(cfg, "compose"):
            rc = call_docker(base + rest)
            if rc == 0:
                drop_fallback_pins(cfg, [compose_project], "compose")
            sys.exit(rc)

    # `ps`: while the laptop engine still holds containers, show both engines.
    if sub == "ps" and container_cmd and target == "mini" and local_engine_up(cfg):
        rc = call_docker(base + rest)
        out = run([real_docker(), "--context", cfg["local_context"]] + gflags + rest, timeout=20)[1]
        lines = out.splitlines()
        tabular = not any(a in ("-q", "--quiet") or a.startswith("--format") for a in args)
        if tabular and lines:
            lines = lines[1:]
        if lines:
            sys.stdout.write("\n".join(lines) + "\n")
        sys.exit(rc)

    if target == "mini":
        if sub == "compose":
            detached = is_detached(crest, sub=None)
        else:
            detached = is_detached(args, sub)
        if container_cmd and sub in RUN_LIKE:
            mini_run(cfg, base, rest[:len(rest) - len(args)], sub, args, detached)
        if sub == "compose" and compose_sub in COMPOSE_START:
            if compose_project is None:
                compose_project = compose_inspect(cflags)[0]
            mini_compose(cfg, base, rest, compose_sub, crest, compose_project,
                         compose_model(cflags), detached)
        if container_cmd and sub in START_LIKE:
            rc = call_docker(base + rest)
            if rc == 0 and not post_check(cfg, container_targets(sub, args), []):
                sys.exit(1)
            sys.exit(rc)
        if (container_cmd and sub in STOP_LIKE) or (sub == "compose" and compose_sub in COMPOSE_STOP):
            rc = call_docker(base + rest)
            spawn_bg_sync(repeat=1)
            sys.exit(rc)

    exec_real(["--context", ctx] + gflags + rest)



# ---------------------------------------------------------------------------- janitor (mini)

KEEP_LABEL = "rdocker.keep"
KEEP_OFF = ("0", "false", "no")      # rdocker.keep=<any other value, incl. empty> protects
_RFC3339 = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:?\d\d)?$")


def parse_ts(s):
    """Docker RFC3339 (nanoseconds, Z or +-HH:MM offset) -> whole epoch seconds; 0 for the zero
    time or anything unparsable."""
    m = _RFC3339.match((s or "").strip())
    if not m or s.startswith("0001-"):
        return 0.0
    import calendar
    t = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    tz = m.group(2)
    if tz and tz != "Z":
        off = int(tz[1:3]) * 3600 + int(tz[-2:]) * 60
        t -= off if tz[0] == "+" else -off
    return float(t)


def parse_ttl(v):
    m = re.match(r"^\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*$", v or "")
    if not m:
        return None
    return float(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def keep_label(labels):
    """rdocker.keep present with any value except 0/false/no (case-insensitive) -> protected.
    An empty value protects too, matching the `label!=rdocker.keep` prune filter (key-only)."""
    if not isinstance(labels, dict) or KEEP_LABEL not in labels:
        return False
    return str(labels[KEEP_LABEL]).strip().lower() not in KEEP_OFF


def has_keep(info):
    """Keep label on a container/image (Config.Labels) or volume (Labels) inspect record."""
    labels = dict((info.get("Config") or {}).get("Labels") or {})
    labels.update(info.get("Labels") or {})
    return keep_label(labels)


def has_connections(cfg, cid):
    """True if the container has an ESTABLISHED TCP connection; None if it can't be read."""
    rc, out, _ = dk(cfg["remote_context"], "exec", cid, "cat", "/proc/net/tcp", "/proc/net/tcp6",
                    timeout=15)
    if rc != 0 and not out:
        return None
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) > 3 and f[3] == "01":
            return True
    return False


def vm_now(ctx):
    """The mini engine's clock (container timestamps are VM time); laptop time if unreadable."""
    rc, out, err = dk(ctx, "info", "--format", "{{.SystemTime}}", timeout=20)
    t = parse_ts(out.strip()) if rc == 0 else 0.0
    if not t:
        log("janitor: cannot read mini SystemTime (%s); using laptop clock"
            % (out.strip() or err.strip())[:100])
        return time.time()
    return t


def inspect_all(ctx, ids):
    """-> (infos, complete). `docker container inspect a b` exits 1 when one vanished but still
    prints JSON for the rest: use it. infos=None when stdout is not a JSON list (phase must skip)."""
    if not ids:
        return [], True
    rc, out, _ = dk(ctx, "container", "inspect", *ids, timeout=30)
    try:
        infos = json.loads(out)
    except ValueError:
        return None, False
    if not isinstance(infos, list) or not all(isinstance(c, dict) and c.get("Id") for c in infos):
        return None, False
    return infos, rc == 0


def netio_map(ctx):
    """{short id: "rx / tx"} from ONE `docker stats` call (eth traffic only); None if it failed."""
    rc, out, _ = dk(ctx, "stats", "--no-stream", "--format", "{{.ID}}\t{{.NetIO}}", timeout=60)
    if rc != 0:
        return None
    m = {}
    for line in out.splitlines():
        cid, _, net = line.partition("\t")
        if cid.strip():
            m[cid.strip()[:12]] = net.strip()
    return m


def volumes_of(info):
    return [m.get("Name") for m in info.get("Mounts") or []
            if m.get("Type") == "volume" and m.get("Name")]


class JanitorRun:
    """One janitor pass: the act log, failure bookkeeping and the keep-checked destructive calls."""

    def __init__(self, cfg, dry):
        self.cfg, self.ctx, self.dry = cfg, cfg["remote_context"], dry
        self.acts, self.last_error = [], None

    def act(self, desc, *cmd, record=True):
        """-> (ok, stderr). A failure is logged and (record=True) kept as janitor.json last_error."""
        self.acts.append(desc)
        if self.dry:
            return True, ""
        rc, _, err = dk(self.ctx, *cmd, timeout=120)
        log("janitor: %s%s" % (desc, "" if rc == 0 else " FAILED: " + err.strip()[:150]))
        if rc != 0 and record:
            self.last_error = {"ts": time.time(), "action": desc, "err": err.strip()[:300]}
        return rc == 0, err

    def fresh(self, kind, ident):
        """Fresh inspect right before a destructive call: the record, or None if gone/kept/unreadable."""
        rc, out, _ = dk(self.ctx, kind, "inspect", ident, timeout=20)
        try:
            data = json.loads(out) if rc == 0 else None
        except ValueError:
            data = None
        info = data[0] if isinstance(data, list) and data and isinstance(data[0], dict) else None
        if info is None or has_keep(info):
            log("janitor: skip %s %s (%s)" % (kind, ident[:24], "kept" if info else "not found"))
            return None
        return info

    def destructive_ok(self, kind, ident):
        return self.fresh(kind, ident) is not None

    def rm_container(self, cid, name, why, force=False):
        """Keep-checked `rm`; `-v` only if none of its volumes is keep-labelled (or unreadable)."""
        info = self.fresh("container", cid)
        if info is None:
            return False
        vols = volumes_of(info)
        with_v = bool(vols) and all(self.destructive_ok("volume", v) for v in vols)
        cmd = ["rm"] + (["-f"] if force else []) + (["-v"] if with_v else []) + [cid]
        return self.act("rm %s (%s)%s" % (name, why, "" if with_v or not vols else " keeping volumes"),
                        *cmd)[0]

    def stop_container(self, cid, name, why):
        if not self.destructive_ok("container", cid):
            return False
        return self.act("stop %s (%s)" % (name, why), "stop", cid)[0]

    def rm_image(self, iid, why):
        """`image rm` without -f: docker itself refuses images any container (even stopped) uses."""
        if not self.destructive_ok("image", iid):
            return False
        return self.act("rm image %s (%s)" % (iid.split(":")[-1][:12], why), "image", "rm", iid)[0]

    def rm_volume(self, name, why):
        if not self.destructive_ok("volume", name):
            return False
        return self.act("rm volume %s (%s)" % (name, why), "volume", "rm", name)[0]


def janitor_containers(J, infos, complete, idle, now, only):
    """Container rules. Returns (new idle map, [(cid, name)] of in-scope stopped non-keep containers
    still present). Idle entries of ids not seen are dropped only when inspect fully succeeded."""
    cfg = J.cfg
    interval = cfg["janitor_interval_min"] * 60
    limit = cfg["idle_stop_hours"] * 3600
    idle = {k: v for k, v in idle.items() if isinstance(v, dict)}
    stopped = []
    seen = set()
    stats = None
    if any((c.get("State") or {}).get("Running") for c in infos):
        stats = netio_map(J.ctx)
    for c in infos:
        cid, name = c["Id"], (c.get("Name") or "").lstrip("/")
        labels = (c.get("Config") or {}).get("Labels") or {}
        st = c.get("State") or {}
        seen.add(cid)
        if only and not name.startswith(only):
            continue
        if keep_label(labels):
            idle.pop(cid, None)
            continue
        if not st.get("Running"):
            idle.pop(cid, None)
            ended = parse_ts(st.get("FinishedAt")) or parse_ts(c.get("Created"))
            if ended and now - ended > cfg["exited_rm_hours"] * 3600:
                if J.rm_container(cid, name, "stopped %dh" % ((now - ended) // 3600)):
                    continue
            stopped.append((cid, name))
            continue
        ttl = parse_ttl(labels.get("rdocker.ttl"))
        started = parse_ts(st.get("StartedAt"))
        if ttl and started and now - started > ttl:
            if J.rm_container(cid, name, "ttl %s expired" % labels.get("rdocker.ttl"), force=True):
                idle.pop(cid, None)
                continue
        netio = stats.get(cid[:12]) if stats is not None else None
        conn = has_connections(cfg, cid)
        prev = idle.get(cid)
        if prev is None:
            idle[cid] = {"idle_s": 0.0, "last_sample": now, "netio": netio}
            continue
        # Sleep, outage or a clock step never counts fully: at most two janitor intervals per sample.
        gap = max(0.0, min(now - float(prev.get("last_sample") or now), 2 * interval))
        moved = netio is not None and prev.get("netio") is not None and netio != prev["netio"]
        unknown = conn is None or netio is None or prev.get("netio") is None
        if moved or conn is True:
            idle_s, idle_now = 0.0, False
        elif unknown:      # can't tell: hold the clock (never counts as idle, never wipes evidence)
            idle_s, idle_now = float(prev.get("idle_s") or 0), False
        else:
            idle_s, idle_now = float(prev.get("idle_s") or 0) + gap, True
        idle[cid] = {"idle_s": idle_s, "last_sample": now,
                     "netio": netio if netio is not None else prev.get("netio")}
        if idle_now and idle_s > limit:
            if J.stop_container(cid, name, "no traffic for %sh" % cfg["idle_stop_hours"]):
                idle.pop(cid, None)
    if complete:
        idle = {k: v for k, v in idle.items() if k in seen}
    return idle, stopped


def janitor_volumes(J, infos, vunused, now, only):
    """Named volumes have no last-used time: track "unused since" ourselves (30-day rule)."""
    rc, out, _ = dk(J.ctx, "volume", "ls", "-q", timeout=20)
    if rc != 0:
        return vunused
    in_use = {v for c in infos for v in volumes_of(c)}
    new = {}
    for name in out.split():
        if only and not name.startswith(only):
            if name in vunused:
                new[name] = vunused[name]
            continue
        if name in in_use:
            continue
        new[name] = vunused.get(name, now)
        if now - new[name] > J.cfg["volume_unused_days"] * 86400:
            if J.rm_volume(name, "unused %dd" % J.cfg["volume_unused_days"]):
                new.pop(name)
    return new


def janitor_image_ledger(J, infos, ledger, now):
    """-> (new ledger, unused image ids oldest-use first) or (ledger, None) if images unreadable.
    Every image any container (running or stopped) uses is stamped `now`; first seen = now."""
    rc, out, _ = dk(J.ctx, "image", "ls", "-q", "--no-trunc", timeout=30)
    if rc != 0:
        return ledger, None
    in_use = {c.get("Image") for c in infos if c.get("Image")}
    images = list(dict.fromkeys(out.split()))
    new = {iid: (now if iid in in_use else float(ledger.get(iid, now))) for iid in images}
    new.update({iid: now for iid in in_use})
    unused = sorted((i for i in images if i not in in_use), key=lambda i: new[i])
    return new, unused


def janitor_disk(cfg, housekeeping):
    """VM disk % and mini free GB in one ssh round-trip (plus log caps/journald/fstrim if asked)."""
    maxb = cfg["host_log_max_mb"] * 1024 * 1024
    script = (
        "export PATH=/opt/homebrew/bin:$PATH; "
        "echo VMDISK $(colima ssh -- df -P /var/lib/docker | tail -1 | awk '{print $5}'); "
        "echo HOSTFREE $(df -k / | tail -1 | awk '{print int($4/1048576)}'); "
        + ("" if not housekeeping else
           "for f in ~/.colima/_lima/colima/*.log /opt/homebrew/var/log/colima.log; do "
           "[ -f \"$f\" ] && [ $(stat -f%z \"$f\") -gt " + str(maxb) + " ] && "
           "tail -c 5000000 \"$f\" > \"$f.tmp\" && cat \"$f.tmp\" > \"$f\" && rm -f \"$f.tmp\" && echo TRUNC $f; done; "
           "colima ssh -- sudo journalctl --vacuum-size=200M >/dev/null 2>&1; "
           "colima ssh -- sudo fstrim -a >/dev/null 2>&1; true"))
    rc, out, _ = run(["ssh", "-o", "BatchMode=yes", cfg["host"], script], timeout=180)
    for t in re.findall(r"TRUNC (\S+)", out):
        log("janitor: truncated %s to 5MB (cap %dMB)" % (t, cfg["host_log_max_mb"]))
    m = re.search(r"VMDISK (\d+)%", out)
    f = re.search(r"HOSTFREE (\d+)", out)
    return (int(m.group(1)) if m else None), (int(f.group(1)) if f else None)


def disk_high(cfg, pct, free):
    return (pct is not None and pct >= cfg["disk_high_pct"]) or (
        free is not None and free < cfg["host_min_free_gb"])


def janitor(cfg, dry=False, only=None, force_critical=False):
    """Reap what agents left behind on the mini. Every destructive call is preceded by a fresh
    keep-check (JanitorRun.fresh); nothing labelled rdocker.keep is removed, and no unfiltered
    prune is ever issued.

    `only` (tests/e2e): restrict container/volume rules to names with this prefix; skip global
    prunes and image GC. `force_critical`: apply the disk-critical container path regardless of
    disk usage (to the `only` scope when given)."""
    J = JanitorRun(cfg, dry)
    ctx = J.ctx
    rc, out, _ = dk(ctx, "ps", "-aq", "--no-trunc", timeout=20)
    if rc != 0:
        return ["mini unreachable - skipped"]
    ids = out.split()
    now = vm_now(ctx)
    state = load_json(JANITOR_PATH, {})
    state = state if isinstance(state, dict) else {}
    updates = {"last_run": now}
    unused = None
    stopped = []
    infos, complete = inspect_all(ctx, ids)
    if infos is None:
        log("janitor: container inspect unreadable - container phase skipped, clocks kept")
        J.acts.append("container phase skipped (inspect unreadable)")
    else:
        updates["idle"], stopped = janitor_containers(J, infos, complete, state.get("idle") or {},
                                                      now, only)
        if complete:   # volume/image use is only known when every container was inspected
            updates["volume_unused_since"] = janitor_volumes(
                J, infos, state.get("volume_unused_since") or {}, now, only)
            updates["image_last_used"], unused = janitor_image_ledger(
                J, infos, state.get("image_last_used") or {}, now)
    if not only and unused:
        days = cfg["image_unused_days"]
        for iid in list(unused):
            if now - updates["image_last_used"][iid] > days * 86400 and J.rm_image(
                    iid, "unused %dd" % days):
                unused.remove(iid)
                updates["image_last_used"].pop(iid, None)

    def save(extra):
        if dry:
            return
        if J.last_error:
            extra = {**extra, "last_error": J.last_error}
        update_state(JANITOR_PATH, lambda st0: {
            **{k: v for k, v in st0.items() if k != "idle_since"}, **extra})

    save(updates)
    pct = free = None
    if not only:
        J.act("prune anonymous volumes not used by any container (keep-labelled exempt)",
              "volume", "prune", "-f", "--filter", "label!=" + KEEP_LABEL)
        J.act("prune dangling images", "image", "prune", "-f")
        J.act("prune build cache older than 7d", "builder", "prune", "-f", "--filter", "until=168h")
        ok, err = J.act("cap build cache at 5GB", "builder", "prune", "-f", "--max-used-space", "5gb",
                        record=False)
        if not ok and "unknown flag" in err:
            J.acts.pop()
            J.act("cap build cache at 5GB", "builder", "prune", "-f", "--keep-storage", "5gb")
        elif not ok:
            J.last_error = {"ts": time.time(), "action": "cap build cache at 5GB",
                            "err": err.strip()[:300]}
        pct, free = janitor_disk(cfg, housekeeping=not dry)
        if pct is not None:
            J.acts.append("VM disk %d%% used" % pct)
        if free is not None:
            J.acts.append("mini disk %dGB free" % free)
        if disk_high(cfg, pct, free):
            log("janitor: WARNING disk pressure (VM %s%%, mini free %sGB) - aggressive prune"
                % (pct, free))
            ledger = updates.get("image_last_used") or {}
            queue = list(unused or [])       # ledger-oldest first; in-use images never listed
            while queue:
                batch, queue = queue[:5], queue[5:]
                for iid in batch:
                    if J.rm_image(iid, "disk high"):
                        ledger.pop(iid, None)
                if dry:
                    continue
                pct2, free2 = janitor_disk(cfg, housekeeping=False)
                if pct2 is None or not disk_high(cfg, pct2, free2):
                    break
            J.act("prune ALL build cache (disk high)", "builder", "prune", "-af")
    if force_critical or (not only and pct is not None and pct >= cfg["disk_critical_pct"]):
        for cid, name in stopped:
            J.rm_container(cid, name, "disk critical")
        if not only:
            J.act("prune anonymous volumes (disk critical, keep-labelled exempt)",
                  "volume", "prune", "-f", "--filter", "label!=" + KEEP_LABEL)
    extra = {"vm_disk_pct": pct, "mini_free_gb": free} if not only else {}
    if "image_last_used" in updates:
        extra["image_last_used"] = updates["image_last_used"]
    save(extra)
    return J.acts


def mini_engine_kick(cfg):
    """Mini reachable but its engine is down (e.g. it rebooted; Colima's LaunchAgent waits for a GUI
    login that never comes) -> start Colima over ssh. The VM keeps running after ssh exits."""
    rc, out, err = run(["ssh", "-o", "BatchMode=yes", cfg["host"],
                        "export PATH=/opt/homebrew/bin:$PATH; colima status >/dev/null 2>&1 || colima start"],
                       timeout=240)
    log("mini engine was down -> colima start (%s)" % ("ok" if rc == 0 else "FAILED: " + (err or out).strip()[-200:]))


def apply_when_idle(cfg):
    """Restart Colima to apply pending config (e.g. log caps) only when nothing runs on the mini."""
    st = load_json(JANITOR_PATH, {})
    if not st.get("restart_pending"):
        return
    rc, out, _ = dk(cfg["remote_context"], "ps", "-q", timeout=20)
    if rc != 0 or out.strip():
        return
    log("applying pending mini config: colima restart (mini idle)")
    rc, _, err = run(["ssh", "-o", "BatchMode=yes", cfg["host"],
                      "export PATH=/opt/homebrew/bin:$PATH; brew services restart colima >/dev/null 2>&1; "
                      "for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done; docker info >/dev/null"],
                     timeout=240)
    if rc == 0:
        update_state(JANITOR_PATH, lambda st0: {**st0, "restart_pending": False})
        log("pending mini config applied")
    else:
        log("colima restart failed: " + err.strip()[-200:])

TS_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"


def tailscale_running():
    rc, out, _ = run([TS_CLI, "status", "--json"], timeout=8)
    try:
        return json.loads(out).get("BackendState") == "Running"
    except ValueError:
        return False


def tailscale_up():
    """Start laptop Tailscale if it is installed but stopped. True if we changed something."""
    if not os.path.exists(TS_CLI) or tailscale_running():
        return False
    run(["open", "-ga", "Tailscale"], timeout=10)
    time.sleep(3)
    run([TS_CLI, "up"], timeout=20)
    return tailscale_running()


# ---------------------------------------------------------------------------- daemon

def set_global_context(cfg, target):
    want = cfg["remote_context"] if target == "mini" else cfg["local_context"]
    rc, out, _ = run([real_docker(), "context", "show"], timeout=10)
    if rc == 0 and out.strip() != want:
        run([real_docker(), "context", "use", want], timeout=10)
        log("global docker context -> " + want)


def daemon():
    log("daemon start pid=%d" % os.getpid())
    events = None
    next_tick = 0
    next_janitor = time.time() + 60
    next_ts_kick = 0
    next_engine_kick = 0
    idle_since = None
    while True:
        cfg = load_cfg()
        now = time.time()
        if now >= next_tick:
            next_tick = now + PERIODIC
            if cfg["mode"] == "off":
                time.sleep(PERIODIC)
                continue
            h = refresh_health(cfg)
            if not h["reachable"] and now >= next_ts_kick:
                next_ts_kick = now + 300
                if tailscale_up():
                    log("mini unreachable and laptop Tailscale was stopped -> started it")
                    h = refresh_health(cfg)
            if h["reachable"] and not h.get("docker_ok") and now >= next_engine_kick:
                next_engine_kick = now + 600
                mini_engine_kick(cfg)
                h = refresh_health(cfg)
            target, why = resolve_target(cfg)
            set_global_context(cfg, target)
            if h["reachable"] and h.get("docker_ok"):
                sync_forwards(cfg)
                if now >= next_janitor:
                    next_janitor = now + cfg["janitor_interval_min"] * 60
                    try:
                        janitor(cfg)
                        apply_when_idle(cfg)
                    except Exception as e:  # a janitor bug must never kill the forwarder
                        log("janitor error: %s" % e)
            # Quit an idle laptop engine (that's the RAM we came here to free).
            if cfg["local_idle_stop_min"] and target == "mini" and local_engine_up(cfg):
                rc, out, _ = dk(cfg["local_context"], "ps", "-q", timeout=10)
                if rc == 0 and not out.strip():
                    idle_since = idle_since or now
                    if now - idle_since > cfg["local_idle_stop_min"] * 60:
                        log("local engine idle %d min -> quitting Docker Desktop"
                            % cfg["local_idle_stop_min"])
                        run(["osascript", "-e", 'quit app "Docker Desktop"'], timeout=20)
                        idle_since = None
                else:
                    idle_since = None
            else:
                idle_since = None
            if (events is None or events.poll() is not None) and h["reachable"] and h.get("docker_ok"):
                events = subprocess.Popen(
                    [real_docker(), "--context", cfg["remote_context"], "events",
                     "--filter", "type=container", "--format", "{{.Action}}"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                log("watching mini container events")
        wait = max(0.5, next_tick - time.time())
        if events and events.poll() is None:
            r, _, _ = select.select([events.stdout], [], [], wait)
            if r:
                line = events.stdout.readline()
                if not line:
                    events = None
                    continue
                action = line.strip()
                if action.startswith(("start", "die", "destroy", "stop", "kill", "unpause",
                                      "restart")):
                    time.sleep(0.3)      # debounce bursts (compose up of N services)
                    sync_forwards(cfg)
        else:
            time.sleep(wait)


# ---------------------------------------------------------------------------- install / setup

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-I</string><string>{script}</string><string>daemon</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
</dict></plist>
"""


def daemon_loaded():
    rc, out, _ = run(["launchctl", "list", PLIST_LABEL], timeout=5)
    return rc == 0


def install_daemon():
    os.makedirs(os.path.dirname(PLIST_PATH), exist_ok=True)
    with open(PLIST_PATH, "w") as f:
        f.write(PLIST.format(label=PLIST_LABEL, script=os.path.realpath(__file__), log=LOG_PATH))
    uid = str(os.getuid())
    run(["launchctl", "bootout", "gui/" + uid + "/" + PLIST_LABEL], timeout=10)
    rc, _, err = run(["launchctl", "bootstrap", "gui/" + uid, PLIST_PATH], timeout=10)
    return rc == 0 or "already" in err


def link(src, dst):
    if os.path.islink(dst) and os.path.realpath(dst) == os.path.realpath(src):
        return False
    if os.path.exists(dst) and not os.path.islink(dst):
        raise SystemExit("rdocker: %s exists and is not our symlink; refusing to replace" % dst)
    if os.path.islink(dst):
        os.unlink(dst)
    os.symlink(src, dst)
    return True


def install(cfg):
    ensure_dirs()
    real = real_docker()
    # 1. docker context for the mini = the mini's docker socket, streamed over the SSH master
    if not cfg["remote_socket"]:
        rc, out, _ = run(["ssh", "-o", "BatchMode=yes", cfg["host"], "echo $HOME"], timeout=20)
        if rc == 0 and out.strip():
            cfg["remote_socket"] = out.strip() + "/.colima/default/docker.sock"
    verb = "update" if run([real, "context", "inspect", cfg["remote_context"]],
                           timeout=10)[0] == 0 else "create"
    rc, _, err = run([real, "context", verb, cfg["remote_context"], "--description",
                      "Mac mini over Tailscale (rdocker)", "--docker",
                      "host=unix://" + MINI_SOCK], timeout=15)
    print(("%sd" % verb if rc == 0 else "FAILED to %s" % verb) + " docker context " +
          cfg["remote_context"] + ("" if rc == 0 else ": " + err.strip()))
    # 2. tailnet IP for fast reachability checks
    if not cfg["host_ip"]:
        try:
            cfg["host_ip"] = socket.gethostbyname(cfg["host"])
        except OSError:
            pass
    # 3. pin what already lives on the laptop engine, so it keeps working where its data is
    found = {"containers": [], "compose_projects": []}
    if local_engine_up(cfg):
        rc, out, _ = dk(cfg["local_context"], "ps", "-a", "--format",
                        '{{.Names}}\t{{.Label "com.docker.compose.project"}}', timeout=15)
        for line in out.splitlines():
            name, _, proj = line.partition("\t")
            found["containers"].append(name)
            found["compose_projects"].append(proj)

    def apply(cur):
        pins = dict(cur["pins"])
        for key, names in found.items():
            pins[key] = list(pins[key])
            for n in names:
                if n and n not in pins[key]:
                    pins[key].append(n)
        return {**cur, "pins": pins,
                "remote_socket": cur["remote_socket"] or cfg["remote_socket"],
                "host_ip": cur["host_ip"] or cfg["host_ip"]}
    cfg = update_cfg(apply)
    # 4. shims
    os.makedirs(BIN_DIR, exist_ok=True)
    os.chmod(SHIM_SRC, 0o755)
    os.chmod(os.path.realpath(__file__), 0o755)
    link(SHIM_SRC, os.path.join(BIN_DIR, "docker"))
    link(os.path.realpath(__file__), os.path.join(BIN_DIR, "rdocker"))
    # 5. background forwarder
    ok = install_daemon()
    print("installed: docker shim + rdocker in %s, launch agent %s (%s)"
          % (BIN_DIR, PLIST_LABEL, "loaded" if ok else "LOAD FAILED"))
    print("pinned to laptop: containers=%s compose=%s"
          % (cfg["pins"]["containers"], cfg["pins"]["compose_projects"]))


MINI_SETUP = r"""
set -e
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH
grep -q 'rdocker: homebrew' ~/.zshenv 2>/dev/null || {
  printf '%s\n' '# rdocker: homebrew + colima docker for non-interactive ssh (docker over ssh needs them)' \
    'export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH' >> ~/.zshenv; }
for f in colima docker; do brew list --formula $f >/dev/null 2>&1 || brew install $f; done
if ! colima status >/dev/null 2>&1; then
  colima start --vm-type vz --vz-rosetta --cpu @CPU@ --memory @MEM@ --disk @DISK@
fi
brew services list | grep -q '^colima.*started' || brew services start colima
docker context use colima >/dev/null 2>&1 || true
docker version --format 'mini docker server {{.Server.Version}} ({{.Server.Arch}})'
colima list
"""


def setup_mini(cfg, cpu, mem, disk):
    script = MINI_SETUP.replace("@CPU@", cpu).replace("@MEM@", mem).replace("@DISK@", disk)
    print("configuring %s over ssh (brew colima+docker, VM %s cpu / %sGB / %sGB disk)..."
          % (cfg["host"], cpu, mem, disk))
    p = subprocess.run(["ssh", "-o", "BatchMode=yes", cfg["host"], "zsh -s"], input=script,
                       text=True)
    return p.returncode


# ---------------------------------------------------------------------------- status / doctor

def status(cfg, fix=False):
    real = real_docker()
    rows = []

    def row(ok, label, detail=""):
        rows.append(("OK " if ok else "-- ") + label + (": " + detail if detail else ""))
        return ok

    if os.path.exists(TS_CLI):
        if fix:
            tailscale_up()
        up = tailscale_running()
        row(up, "tailscale on laptop", "" if up else "stopped - run: rdocker doctor")
    h = refresh_health(cfg)
    row(h["reachable"], "mini reachable (%s)" % cfg["host"],
        "ssh control connection up" if h["reachable"] else "no ssh control connection")
    if h["reachable"] and not h.get("docker_ok") and fix:
        run(["ssh", "-o", "BatchMode=yes", cfg["host"],
             "PATH=/opt/homebrew/bin:$PATH; colima status >/dev/null 2>&1 || colima start"], timeout=180)
        h = refresh_health(cfg)
    row(bool(h.get("docker_ok")), "mini docker engine",
        "%s, %sms round-trip" % (h.get("server_version"), h.get("rtt_ms")) if h.get("docker_ok")
        else "not responding")
    target, why = resolve_target(cfg)
    row(True, "mode=%s -> commands go to %s" % (cfg["mode"], target.upper()), why)
    shim_ok = os.path.realpath(os.path.join(BIN_DIR, "docker")) == os.path.realpath(SHIM_SRC)
    first = shutil.which("docker")
    row(shim_ok and first and os.path.realpath(first) == os.path.realpath(SHIM_SRC),
        "docker shim first on PATH", first or "none")
    loaded = daemon_loaded()
    if not loaded and fix:
        loaded = install_daemon()
    row(loaded, "background forwarder (launchd %s)" % PLIST_LABEL)
    if fix and h.get("docker_ok"):
        sync_forwards(cfg, verbose=True)
    st = load_json(FORWARDS_PATH, {})
    v4 = st.get("tcp4") or []
    no6 = sorted(set(v4) - set(st.get("tcp6") or []))
    row(True, "mirrored ports", (", ".join(str(p) for p in v4) or "none")
        + (" (IPv6 mirror pending: %s)" % ", ".join(map(str, no6)) if no6 else ""))
    if st.get("conflicts"):
        row(False, "port conflicts (busy on laptop)", ", ".join(map(str, st["conflicts"])))
    row(True, "laptop Docker Desktop", "running" if local_engine_up(cfg) else "stopped (starts on demand)")
    ctx = run([real, "context", "show"], timeout=10)[1].strip()
    row(True, "global docker context", ctx)
    print("\n".join(rows))
    return all(not r.startswith("-- ") for r in rows)


def where(cfg, name):
    on_mini = exists_on(cfg, "remote_context", name)
    on_local = exists_on(cfg, "local_context", name) if local_engine_up(cfg) else False
    found = [x for x, y in (("mini", on_mini), ("laptop", on_local)) if y]
    unknown = [x for x, y in (("mini", on_mini), ("laptop", on_local)) if y is None]
    print("%s: %s%s" % (name, " + ".join(found) or "not found",
                        " (could not ask: %s)" % ", ".join(unknown) if unknown else ""))


# ---------------------------------------------------------------------------- main

USAGE = """usage: rdocker <command>
  status                 health, routing target, mirrored ports
  doctor                 status + repair (tailscale, mini engine, forwarder, forwards)
  use auto|mini|local|off   routing mode (auto = mini when healthy & fast, else laptop)
  where <container>      which engine holds a container
  pin|unpin <container|compose-project>   keep it on the laptop engine
  sync [--repeat N --interval S]   reconcile port mirrors now
  clean [--dry-run] [--only PREFIX] [--force-critical]
                         run the mini janitor now (auto every 10 min); --only limits container/volume
                         rules to that name prefix (no global prunes); --force-critical applies the
                         disk-critical stopped-container removal now (rdocker.keep always exempt)
  logs [--route]         tail the forwarder log (or the per-command routing log)
  install                laptop side: context, shims, launch agent, pins
  setup-mini [cpu mem disk]   mini side over ssh: colima+docker (default 6 8 30)
  daemon                 (launchd) event-driven forwarder"""


def main(argv):
    if argv and argv[0] == "shim":
        try:
            shim(argv[1:])
        except SystemExit:
            raise
        except Exception as e:
            if INVOKED["invoked"]:
                # docker already ran: never run it a second time; report its exit code.
                log("shim error after docker ran (rc=%s): %r" % (INVOKED["rc"], e))
                say("internal error after docker ran (%s); see %s" % (e, LOG_PATH))
                return INVOKED["rc"] if INVOKED["rc"] is not None else 1
            # routing failed before docker ran: never let a routing bug break docker
            say("internal error (%s); running docker unrouted" % e)
            exec_real(argv[1:])
        return 0
    try:
        return command(argv)
    except ConfigWriteError as e:
        say("config not saved: %s" % e)
        return 1


def command(argv):
    cfg = load_cfg()
    cmd = argv[0] if argv else "status"
    if cmd == "status":
        return 0 if status(cfg) else 1
    if cmd == "doctor":
        return 0 if status(cfg, fix=True) else 1
    if cmd == "use" and len(argv) > 1 and argv[1] in ("auto", "mini", "local", "off"):
        cfg = update_cfg(lambda cur: {**cur, "mode": argv[1]})
        try:
            os.unlink(HEALTH_PATH)
        except OSError:
            pass
        if argv[1] != "off":
            set_global_context(cfg, resolve_target(cfg)[0])
        print("mode=" + argv[1])
        return 0
    if cmd == "where" and len(argv) > 1:
        where(cfg, argv[1])
        return 0
    if cmd in ("pin", "unpin") and len(argv) > 1:
        def apply(cur):
            pins = dict(cur["pins"])
            for key in ("containers", "compose_projects"):
                pins[key] = [n for n in pins[key] if cmd == "pin" or n != argv[1]]
            if cmd == "pin":
                key = "compose_projects" if "--compose" in argv else "containers"
                if argv[1] not in pins[key]:
                    pins[key].append(argv[1])
            return {**cur, "pins": pins}
        cfg = update_cfg(apply)
        print(json.dumps(cfg["pins"]))
        return 0
    if cmd == "sync":
        repeat = int(argv[argv.index("--repeat") + 1]) if "--repeat" in argv else 1
        interval = float(argv[argv.index("--interval") + 1]) if "--interval" in argv else 1.5
        ok = True
        for i in range(repeat):
            ok = sync_forwards(cfg, verbose=(repeat == 1))[0]
            if i < repeat - 1:
                time.sleep(interval)
        return 0 if ok else 1
    if cmd == "logs":
        path = ROUTE_LOG if "--route" in argv else LOG_PATH
        os.execvp("tail", ["tail", "-n", "60", path])
    if cmd == "clean":
        for k in ("idle_stop_hours", "exited_rm_hours", "volume_unused_days",
                  "image_unused_days"):  # test overrides
            if "--" + k in argv:
                cfg[k] = float(argv[argv.index("--" + k) + 1])
        only = argv[argv.index("--only") + 1] if "--only" in argv else None
        for a in janitor(cfg, dry="--dry-run" in argv, only=only,
                         force_critical="--force-critical" in argv):
            print(("would: " if "--dry-run" in argv else "") + a)
        return 0
    if cmd == "install":
        install(cfg)
        return 0
    if cmd == "setup-mini":
        cpu, mem, disk = (argv[1:4] + ["6", "8", "30"][len(argv[1:4]):])
        return setup_mini(cfg, cpu, mem, disk)
    if cmd == "daemon":
        daemon()
        return 0
    print(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
