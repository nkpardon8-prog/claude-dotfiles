#!/usr/bin/python3
"""rdocker - run Docker on the always-on Mac mini, transparently.

The laptop's `docker` (via the shim in ~/.local/bin) is routed per call:
  * normal work (test databases, builds, compose stacks) -> the mini over SSH/Tailscale;
  * commands that need the laptop's own files or network (bind mounts of laptop paths,
    --network host) and containers pinned as laptop-resident -> the local Docker Desktop;
  * mini unreachable or too slow (mode=auto) -> local, with a one-line notice.
Published ports of mini containers are mirrored onto the laptop's 127.0.0.1 through one SSH
ControlMaster, so `localhost:<port>` keeps working (same port number on both sides).

Stdlib only; runs on the system /usr/bin/python3 (3.9). See commands/docker.md for the playbook.
"""
import fcntl
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CFG_DIR = os.path.join(HOME, ".config", "rdocker")
CFG_PATH = os.path.join(CFG_DIR, "config.json")
STATE_DIR = os.path.join(HOME, ".local", "state", "rdocker")
HEALTH_PATH = os.path.join(STATE_DIR, "health.json")
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
    "host_ip": "",                     # tailnet IP, used for fast reachability checks
    "remote_context": "mini",
    "remote_socket": "",               # mini docker socket, streamed over the SSH master
    "local_context": "desktop-linux",
    "local_socket": os.path.join(HOME, ".docker", "run", "docker.sock"),
    "mode": "auto",                    # auto | mini | local | off
    "max_rtt_ms": 150,                 # auto mode: slower than this -> run locally
    "local_idle_stop_min": 15,         # quit Docker Desktop after N idle minutes (0 = never)
    "pins": {"containers": [], "compose_projects": []},  # laptop-resident (sticky local)
    # Janitor (mini only). Labels: rdocker.keep=1 exempts; rdocker.ttl=<30m|2h|1d> hard lifetime.
    "janitor_interval_min": 10,
    "idle_stop_hours": 12,             # running, zero TCP connections this long -> stop
    "exited_rm_hours": 24,             # stopped this long -> rm -v (anonymous volumes go too)
    "image_unused_days": 14,           # unused images older than this -> removed
    "disk_high_pct": 80,               # VM disk above this -> prune all unused images + cache
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
RAW_PASSTHRU = {"context", "login", "logout", "help", "completion", "--help", "-h",
                "--version", "-v", "version", "plugin", "trust", "scout", "init", "desktop",
                "debug", "extension", "sbom", "mcp", "model", "ai", "offload"}
# docker global flags that take a value
GLOBAL_VALUE_FLAGS = {"--config", "-c", "--context", "-H", "--host", "-l", "--log-level",
                      "--tlscacert", "--tlscert", "--tlskey"}
# boolean flags of run/create/exec (anything else starting with '-' is assumed to take a value)
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


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def load_cfg():
    cfg = dict(DEFAULTS)
    user = load_json(CFG_PATH, {})
    cfg.update(user)
    pins = dict(DEFAULTS["pins"])
    pins.update(user.get("pins") or {})
    cfg["pins"] = pins
    return cfg


def save_cfg(cfg):
    ensure_dirs()
    save_json(CFG_PATH, cfg)


def say(msg):
    sys.stderr.write("rdocker: " + msg + "\n")


def log(msg, path=LOG_PATH):
    ensure_dirs()
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n"
    try:
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

def tcp_rtt(host, port=22, timeout=1.5):
    best = None
    for _ in range(2):
        t0 = time.time()
        try:
            s = socket.create_connection((host, port), timeout)
            s.close()
        except OSError:
            return None
        dt = (time.time() - t0) * 1000
        best = dt if best is None else min(best, dt)
    return round(best, 1)


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


def probe_health(cfg, check_docker=True):
    rtt = tcp_rtt(cfg["host_ip"] or cfg["host"])
    h = {"ts": time.time(), "reachable": rtt is not None, "rtt_ms": rtt, "docker_ok": None}
    if rtt is not None and check_docker:
        ensure_mini_socket(cfg)
        rc, out, _ = dk(cfg["remote_context"], "version", "--format", "{{.Server.Version}}",
                        timeout=12)
        h["docker_ok"] = rc == 0 and bool(out.strip())
        h["server_version"] = out.strip()
    return h


def health(cfg, force=False):
    h = load_json(HEALTH_PATH, None)
    if not force and h and time.time() - h.get("ts", 0) < HEALTH_TTL:
        return h
    # Inline (shim) probe: TCP only, fast. The daemon writes the full reading incl. docker_ok.
    h = probe_health(cfg, check_docker=False)
    prev = load_json(HEALTH_PATH, {}) or {}
    h["docker_ok"] = prev.get("docker_ok") if h["reachable"] else False
    try:
        ensure_dirs()
        save_json(HEALTH_PATH, h)
    except OSError:
        pass
    return h


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
    rtt = h.get("rtt_ms") or 0
    if cfg["max_rtt_ms"] and rtt > cfg["max_rtt_ms"]:
        return "local", "mini round-trip %sms > %sms" % (rtt, cfg["max_rtt_ms"])
    return "mini", "ok"


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


def positionals(args, value_flags=None):
    """Positional args (stop scanning after '--'). Unknown flags are assumed to take a value."""
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            out.extend(args[i + 1:])
            break
        if a.startswith("--"):
            if "=" in a or a in BOOL_FLAGS or (value_flags is not None and a not in value_flags):
                i += 1
            else:
                i += 2
            continue
        if a.startswith("-") and len(a) > 1:
            if a in BOOL_FLAGS or set(a[1:]) <= SHORT_BOOL_CHARS:
                i += 1
            elif len(a) > 2:      # -p5432:5432 style
                i += 1
            else:
                i += 2
            continue
        out.append(a)
        i += 1
    return out


def skip_flag(args, i):
    """Index after the flag at args[i] (and its value, if it takes one)."""
    a = args[i]
    if a.startswith("--"):
        return i + 1 if ("=" in a or a in BOOL_FLAGS) else i + 2
    if a in BOOL_FLAGS or set(a[1:]) <= SHORT_BOOL_CHARS or len(a) > 2:
        return i + 1
    return i + 2


def flag_values(args, names):
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
        i = skip_flag(args, i)
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


def compose_inspect(cflags):
    """Render the compose model client-side (no daemon needed) -> (project, needs_local_reason)."""
    rc, out, _ = run([real_docker(), "compose"] + cflags + ["config", "--format", "json"],
                     timeout=20)
    if rc != 0:
        return None, None
    try:
        model = json.loads(out)
    except ValueError:
        return None, None
    for name, svc in (model.get("services") or {}).items():
        if svc.get("network_mode") == "host":
            return model.get("name"), "service %s uses network_mode: host" % name
        for vol in svc.get("volumes") or []:
            if isinstance(vol, dict) and vol.get("type") == "bind" and is_bind_source(
                    vol.get("source", "")):
                return model.get("name"), "service %s bind-mounts %s" % (name, vol.get("source"))
    return model.get("name"), None


def container_targets(sub, args):
    pos = positionals(args)
    if not pos:
        return []
    if sub == "cp":
        return [p.split(":", 1)[0] for p in pos if ":" in p and not p.startswith(("/", "."))][:1]
    if sub in MULTI_TARGET:
        return pos
    if sub == "rename":
        return pos[:1]
    return pos[:1]


def exists_on(cfg, ctx_key, name):
    return dk(cfg[ctx_key], "container", "inspect", "--format", "{{.Id}}", name, timeout=12)[0] == 0


# ---------------------------------------------------------------------------- port mirroring

PORT_RE = re.compile(r"(?:(\d+\.\d+\.\d+\.\d+|\[?::\]?):)?(\d+)(?:-(\d+))?->")


def remote_ports(cfg):
    rc, out, err = dk(cfg["remote_context"], "ps", "--format", "{{.Ports}}", timeout=20)
    if rc != 0:
        raise RuntimeError("docker ps on mini failed: " + err.strip()[:200])
    ports = set()
    for line in out.splitlines():
        for ip, a, b in PORT_RE.findall(line):
            if ip and ip not in ("127.0.0.1", "0.0.0.0", "::", "[::]"):
                continue
            lo = int(a)
            hi = int(b) if b else lo
            for p in range(lo, min(hi, lo + 99) + 1):
                ports.add(p)
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
                          "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=no",
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


def sync_forwards(cfg, verbose=False):
    """Make laptop 127.0.0.1:<p> (and [::1]) forward to mini 127.0.0.1:<p> for every published port."""
    ensure_dirs()
    with open(LOCK_PATH, "w") as lockf:
        fcntl.flock(lockf, fcntl.LOCK_EX)
        pid = ensure_master(cfg)
        if not pid:
            if verbose:
                say("cannot open the SSH control connection to " + cfg["host"])
            return False
        state = load_json(FORWARDS_PATH, {})
        current = set(state.get("ports", [])) if state.get("master_pid") == pid else set()
        conflicts = set(state.get("conflicts", [])) if state.get("master_pid") == pid else set()
        try:
            desired = remote_ports(cfg)
        except RuntimeError as e:
            log(str(e))
            if verbose:
                say(str(e))
            return False
        for p in sorted(desired - current):
            spec = "127.0.0.1:%d:127.0.0.1:%d" % (p, p)
            rc, _, err = ssh_ctl(cfg, "-O", "forward", "-L", spec)
            if rc == 0:
                current.add(p)
                conflicts.discard(p)
                ssh_ctl(cfg, "-O", "forward", "-L", "[::1]:%d:127.0.0.1:%d" % (p, p))
                log("forward +%d" % p)
            else:
                if p not in conflicts:
                    msg = ("port %d is busy on the laptop; mini container on %d is not mirrored "
                           "(free the laptop port or reach it via %s:%d)" % (p, p, cfg["host"], p))
                    log(msg)
                    if verbose:
                        say(msg)
                conflicts.add(p)
        for p in sorted(current - desired):
            ssh_ctl(cfg, "-O", "cancel", "-L", "127.0.0.1:%d:127.0.0.1:%d" % (p, p))
            ssh_ctl(cfg, "-O", "cancel", "-L", "[::1]:%d:127.0.0.1:%d" % (p, p))
            current.discard(p)
            log("forward -%d" % p)
        conflicts &= desired
        save_json(FORWARDS_PATH, {"master_pid": pid, "ports": sorted(current),
                                  "conflicts": sorted(conflicts), "ts": time.time()})
        return True


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

def exec_real(args):
    d = real_docker()
    os.execv(d, [d] + args)


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
    if sub in ("container", "image", "volume", "network", "system", "builder") and args:
        sub, args = args[0], args[1:]

    target, why = resolve_target(cfg)
    if target == "mini" and not ensure_mini_socket(cfg):
        target, why = "local", "cannot open the SSH tunnel to the mini"
    local_reason = None
    compose_sub = None
    compose_project = None

    if target == "mini":
        if sub in ("run", "create"):
            local_reason = run_needs_local(args)
        elif sub == "compose":
            cflags, compose_sub, _ = compose_split(args)
            if compose_sub not in ("version", "ls", ""):
                compose_project, local_reason = compose_inspect(cflags)
                if compose_project and compose_project in cfg["pins"]["compose_projects"]:
                    local_reason = "compose project %s is pinned to the laptop" % compose_project
        elif sub in CONTAINER_TARGETED:
            names = container_targets(sub, args)
            pinned = [n for n in names if n in cfg["pins"]["containers"]]
            if pinned and len(pinned) == len(names):
                local_reason = "container %s is pinned to the laptop" % pinned[0]
            elif names and local_engine_up(cfg):
                missing = [n for n in names if not exists_on(cfg, "remote_context", n)]
                if missing and len(missing) == len(names) and all(
                        exists_on(cfg, "local_context", n) for n in missing):
                    local_reason = "container %s lives on the laptop" % missing[0]
                elif missing and sub in MULTI_TARGET and len(missing) < len(names):
                    # Split across engines: run each half where it lives.
                    loc = [n for n in missing if exists_on(cfg, "local_context", n)]
                    remote_names = [n for n in names if n not in loc]
                    opts = [a for a in args if a not in names]
                    rc1 = subprocess.call([real_docker(), "--context", cfg["remote_context"]]
                                          + gflags + [sub] + opts + remote_names)
                    rc2 = subprocess.call([real_docker(), "--context", cfg["local_context"]]
                                          + gflags + [sub] + opts + loc) if loc else 0
                    if sub in STOP_LIKE:
                        spawn_bg_sync(repeat=1)
                    sys.exit(rc1 or rc2)

    if local_reason:
        target = "local"
        if os.environ.get("RDOCKER_VERBOSE"):
            say("running locally: " + local_reason)
    elif target == "local" and mode == "auto" and why != "ok" and os.isatty(2):
        say("running locally (%s)" % why)

    ctx = cfg["remote_context"] if target == "mini" else cfg["local_context"]
    log("%-5s %-8s %s | %s" % (target, sub, (local_reason or why), os.getcwd()), ROUTE_LOG)
    if target == "local" and not ensure_local_running(cfg):
        sys.exit(1)

    base = [real_docker(), "--context", ctx] + gflags

    # `ps`: while the laptop engine still holds containers, show both engines.
    if sub == "ps" and target == "mini" and local_engine_up(cfg):
        rc = subprocess.call(base + rest)
        out = run([real_docker(), "--context", cfg["local_context"]] + gflags + rest, timeout=20)[1]
        lines = out.splitlines()
        tabular = not any(a in ("-q", "--quiet") or a.startswith("--format") for a in args)
        if tabular and lines:
            lines = lines[1:]
        if lines:
            sys.stdout.write("\n".join(lines) + "\n")
        sys.exit(rc)

    if target == "mini":
        detached = "-d" in args or "--detach" in args or any(
            a.startswith("-") and not a.startswith("--") and "d" in a[1:] and set(a[1:]) <= SHORT_BOOL_CHARS
            for a in args[:positionals_index(args)])
        if sub in START_LIKE or (sub == "compose" and compose_sub in COMPOSE_START):
            foreground = (sub == "run" and not detached) or (
                sub == "compose" and compose_sub in ("up", "run") and not detached)
            if foreground:
                spawn_bg_sync(repeat=10, interval=1.5)
                exec_real(["--context", ctx] + gflags + rest)
            rc = subprocess.call(base + rest)
            if rc == 0:
                sync_forwards(cfg, verbose=True)
            sys.exit(rc)
        if sub in STOP_LIKE or (sub == "compose" and compose_sub in COMPOSE_STOP):
            rc = subprocess.call(base + rest)
            spawn_bg_sync(repeat=1)
            sys.exit(rc)

    exec_real(["--context", ctx] + gflags + rest)


def positionals_index(args):
    """Index of the first positional (the image for run) - flags before it belong to docker."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--" or a == "-" or not a.startswith("-"):
            return i
        i = skip_flag(args, i)
    return i



# ---------------------------------------------------------------------------- janitor (mini)

def parse_ts(s):
    """Docker RFC3339 (nanoseconds, Z) -> epoch seconds; 0 for the zero time."""
    if not s or s.startswith("0001-"):
        return 0.0
    import calendar
    return float(calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")))


def parse_ttl(v):
    m = re.match(r"^\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*$", v or "")
    if not m:
        return None
    return float(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


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


def janitor(cfg, dry=False, only=None):
    """Reap what agents left behind on the mini. Never touches rdocker.keep=1 containers/volumes.

    `only` (tests): restrict container/volume rules to names with this prefix; skip global prunes."""
    ctx = cfg["remote_context"]
    acts = []

    def act(desc, *cmd):
        acts.append(desc)
        if dry:
            return
        rc, _, err = dk(ctx, *cmd, timeout=120)
        log("janitor: %s%s" % (desc, "" if rc == 0 else " FAILED: " + err.strip()[:150]))

    rc, out, _ = dk(ctx, "ps", "-aq", timeout=20)
    if rc != 0:
        return ["mini unreachable - skipped"]
    ids = out.split()
    state = load_json(JANITOR_PATH, {})
    idle = state.get("idle_since", {})
    now = time.time()
    seen = set()
    if ids:
        rc, out, _ = dk(ctx, "inspect", *ids, timeout=30)
        try:
            infos = json.loads(out) if rc == 0 else []
        except ValueError:
            infos = []
        for c in infos:
            cid, name = c["Id"], c["Name"].lstrip("/")
            labels = (c.get("Config") or {}).get("Labels") or {}
            st = c.get("State") or {}
            seen.add(cid)
            if only and not name.startswith(only):
                continue
            if str(labels.get("rdocker.keep", "")).lower() in ("1", "true", "yes"):
                continue
            ttl = parse_ttl(labels.get("rdocker.ttl"))
            started = parse_ts(st.get("StartedAt"))
            if st.get("Running"):
                if ttl and started and now - started > ttl:
                    act("rm %s (ttl %s expired)" % (name, labels.get("rdocker.ttl")),
                        "rm", "-f", "-v", cid)
                    continue
                conn = has_connections(cfg, cid)
                if conn is False:
                    idle.setdefault(cid, now)
                    if now - idle[cid] > cfg["idle_stop_hours"] * 3600:
                        act("stop %s (no connections for %sh)" % (name, cfg["idle_stop_hours"]),
                            "stop", cid)
                        idle.pop(cid, None)
                else:
                    idle.pop(cid, None)
            else:
                ended = parse_ts(st.get("FinishedAt")) or parse_ts(c.get("Created"))
                if ended and now - ended > cfg["exited_rm_hours"] * 3600:
                    act("rm %s (stopped %dh)" % (name, (now - ended) // 3600), "rm", "-v", cid)
    idle = {k: v for k, v in idle.items() if k in seen}
    # Named volumes: docker has no last-used time, so track "unused since" ourselves.
    vunused = state.get("volume_unused_since", {})
    rc, out, _ = dk(ctx, "volume", "ls", "--format", '{{.Name}}\t{{.Label "rdocker.keep"}}', timeout=20)
    in_use = set()
    rc2, out2, _ = dk(ctx, "ps", "-a", "--format", "{{.Mounts}}", timeout=20)
    for line in out2.splitlines():
        in_use.update(x.strip() for x in line.split(",") if x.strip())
    vols_now = {}
    for line in out.splitlines():
        name, _, keep = line.partition("\t")
        if not name or keep.lower() in ("1", "true", "yes") or (only and not name.startswith(only)):
            continue
        if name in in_use or any(name.startswith(u.rstrip("…")) for u in in_use if u.endswith("…")):
            continue
        vols_now[name] = vunused.get(name, now)
        if now - vols_now[name] > cfg["volume_unused_days"] * 86400:
            act("rm volume %s (unused %dd)" % (name, cfg["volume_unused_days"]), "volume", "rm", name)
            vols_now.pop(name, None)
    if not dry:
        st0 = load_json(JANITOR_PATH, {})
        st0.update({"idle_since": idle, "volume_unused_since": vols_now, "last_run": now})
        save_json(JANITOR_PATH, st0)
    if only:
        return acts
    act("prune anonymous volumes not used by any container", "volume", "prune", "-f")
    act("prune dangling images", "image", "prune", "-f")
    act("prune images unused for %dd" % cfg["image_unused_days"], "image", "prune", "-af",
        "--filter", "until=%dh" % (cfg["image_unused_days"] * 24))
    act("prune build cache older than 7d", "builder", "prune", "-f", "--filter", "until=168h")
    act("cap build cache at 5GB", "builder", "prune", "-f", "--keep-storage", "5gb")
    # Mini host housekeeping in one ssh round-trip: VM disk %, host free GB, log caps, journald,
    # fstrim (hands freed VM blocks back to macOS).
    maxb = cfg["host_log_max_mb"] * 1024 * 1024
    script = (
        "export PATH=/opt/homebrew/bin:$PATH; "
        "echo VMDISK $(colima ssh -- df -P /var/lib/docker | tail -1 | awk '{print $5}'); "
        "echo HOSTFREE $(df -k / | tail -1 | awk '{print int($4/1048576)}'); "
        + ("" if dry else
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
    pct = int(m.group(1)) if m else None
    free = int(f.group(1)) if f else None
    if pct is not None:
        acts.append("VM disk %d%% used" % pct)
    if free is not None:
        acts.append("mini disk %dGB free" % free)
    high = (pct is not None and pct >= cfg["disk_high_pct"]) or (
        free is not None and free < cfg["host_min_free_gb"])
    if high:
        log("janitor: WARNING disk pressure (VM %s%%, mini free %sGB) - aggressive prune" % (pct, free))
        act("prune ALL unused images (disk high)", "image", "prune", "-af")
        act("prune ALL build cache (disk high)", "builder", "prune", "-af")
    if pct is not None and pct >= cfg["disk_critical_pct"]:
        act("remove ALL stopped containers (disk critical)", "container", "prune", "-f")
        act("prune anonymous volumes (disk critical)", "volume", "prune", "-f")
    if not dry:
        st0 = load_json(JANITOR_PATH, {})
        st0.update({"vm_disk_pct": pct, "mini_free_gb": free})
        save_json(JANITOR_PATH, st0)
    return acts


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
        st["restart_pending"] = False
        save_json(JANITOR_PATH, st)
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
            h = probe_health(cfg, check_docker=True)
            save_json(HEALTH_PATH, h)
            if not h["reachable"] and now >= next_ts_kick:
                next_ts_kick = now + 300
                if tailscale_up():
                    log("mini unreachable and laptop Tailscale was stopped -> started it")
                    h = probe_health(cfg, check_docker=True)
                    save_json(HEALTH_PATH, h)
            if h["reachable"] and not h.get("docker_ok") and now >= next_engine_kick:
                next_engine_kick = now + 600
                mini_engine_kick(cfg)
                h = probe_health(cfg, check_docker=True)
                save_json(HEALTH_PATH, h)
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
    if local_engine_up(cfg):
        rc, out, _ = dk(cfg["local_context"], "ps", "-a", "--format",
                        '{{.Names}}\t{{.Label "com.docker.compose.project"}}', timeout=15)
        for line in out.splitlines():
            name, _, proj = line.partition("\t")
            if name and name not in cfg["pins"]["containers"]:
                cfg["pins"]["containers"].append(name)
            if proj and proj not in cfg["pins"]["compose_projects"]:
                cfg["pins"]["compose_projects"].append(proj)
    save_cfg(cfg)
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
    h = probe_health(cfg, check_docker=True)
    save_json(HEALTH_PATH, h)
    row(h["reachable"], "mini reachable (%s)" % cfg["host"],
        "%sms round-trip" % h["rtt_ms"] if h["reachable"] else "no answer on ssh port")
    if h["reachable"] and not h.get("docker_ok") and fix:
        run(["ssh", "-o", "BatchMode=yes", cfg["host"],
             "PATH=/opt/homebrew/bin:$PATH; colima status >/dev/null 2>&1 || colima start"], timeout=180)
        h = probe_health(cfg, check_docker=True)
        save_json(HEALTH_PATH, h)
    row(bool(h.get("docker_ok")), "mini docker engine", h.get("server_version") or "not responding")
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
    row(True, "mirrored ports", ", ".join(str(p) for p in st.get("ports", [])) or "none")
    if st.get("conflicts"):
        row(False, "port conflicts (busy on laptop)", ", ".join(map(str, st["conflicts"])))
    row(True, "laptop Docker Desktop", "running" if local_engine_up(cfg) else "stopped (starts on demand)")
    ctx = run([real, "context", "show"], timeout=10)[1].strip()
    row(True, "global docker context", ctx)
    print("\n".join(rows))
    return all(not r.startswith("-- ") for r in rows)


def where(cfg, name):
    on_mini = exists_on(cfg, "remote_context", name)
    on_local = local_engine_up(cfg) and exists_on(cfg, "local_context", name)
    print("%s: %s" % (name, " + ".join([x for x, y in (("mini", on_mini), ("laptop", on_local)) if y])
                      or "not found"))


# ---------------------------------------------------------------------------- main

USAGE = """usage: rdocker <command>
  status                 health, routing target, mirrored ports
  doctor                 status + repair (tailscale, mini engine, forwarder, forwards)
  use auto|mini|local|off   routing mode (auto = mini when healthy & fast, else laptop)
  where <container>      which engine holds a container
  pin|unpin <container|compose-project>   keep it on the laptop engine
  sync [--repeat N --interval S]   reconcile port mirrors now
  clean [--dry-run]      run the mini janitor now (auto every 10 min)
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
        except Exception as e:  # never let a routing bug break docker: fall back to raw CLI
            say("internal error (%s); running docker unrouted" % e)
            exec_real(argv[1:])
        return 0
    cfg = load_cfg()
    cmd = argv[0] if argv else "status"
    if cmd == "status":
        return 0 if status(cfg) else 1
    if cmd == "doctor":
        return 0 if status(cfg, fix=True) else 1
    if cmd == "use" and len(argv) > 1 and argv[1] in ("auto", "mini", "local", "off"):
        cfg["mode"] = argv[1]
        save_cfg(cfg)
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
        for key in ("containers", "compose_projects"):
            lst = cfg["pins"][key]
            if cmd == "unpin" and argv[1] in lst:
                lst.remove(argv[1])
        if cmd == "pin":
            key = "compose_projects" if "--compose" in argv else "containers"
            if argv[1] not in cfg["pins"][key]:
                cfg["pins"][key].append(argv[1])
        save_cfg(cfg)
        print(json.dumps(cfg["pins"]))
        return 0
    if cmd == "sync":
        repeat = int(argv[argv.index("--repeat") + 1]) if "--repeat" in argv else 1
        interval = float(argv[argv.index("--interval") + 1]) if "--interval" in argv else 1.5
        ok = True
        for i in range(repeat):
            ok = sync_forwards(cfg, verbose=(repeat == 1))
            if i < repeat - 1:
                time.sleep(interval)
        return 0 if ok else 1
    if cmd == "logs":
        path = ROUTE_LOG if "--route" in argv else LOG_PATH
        os.execvp("tail", ["tail", "-n", "60", path])
    if cmd == "clean":
        for k in ("idle_stop_hours", "exited_rm_hours", "volume_unused_days"):  # test overrides
            if "--" + k in argv:
                cfg[k] = float(argv[argv.index("--" + k) + 1])
        only = argv[argv.index("--only") + 1] if "--only" in argv else None
        for a in janitor(cfg, dry="--dry-run" in argv, only=only):
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
