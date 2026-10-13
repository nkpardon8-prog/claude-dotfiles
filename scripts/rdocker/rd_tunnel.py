"""rdocker rd_tunnel: mini health probe + target resolution, laptop port reservation, SSH master, port-mirror sync.

Split out of rdocker.py; see rdocker.py for the overview.
"""
import errno
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from contextlib import contextmanager

import rd_common
import rd_args


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
        status, body = http_unix(rd_common.MINI_SOCK, "/_ping", PROBE_TIMEOUT)
    except (OSError, ProbeError, ValueError):
        return False, "", round((time.time() - t0) * 1000, 1)
    ms = round((time.time() - t0) * 1000, 1)
    if status != 200 or body.strip() != b"OK":
        return False, "", ms
    ver = ""
    try:
        status, body = http_unix(rd_common.MINI_SOCK, "/version", PROBE_TIMEOUT)
        if status == 200:
            ver = str(json.loads(body.decode("utf-8", "replace")).get("Version") or "")
    except (OSError, ProbeError, ValueError, AttributeError):
        pass
    return True, ver, ms


def reset_master(cfg):
    """Drop a possibly-wedged SSH master (e.g. after a network change) and rebuild it."""
    rd_common.ensure_dirs()
    with rd_common.file_lock(rd_common.LOCK_PATH):
        ssh_ctl(cfg, "-O", "exit", timeout=5)
        ensure_master(cfg)


def tunnel_alive(cfg):
    """Cheap authenticated liveness check over the EXISTING master (a session channel, no new TCP).

    Only meaningful while a master exists: with no master, ssh -S would fall back to a fresh
    connection, so callers check master_pid first."""
    rc, _, _ = rd_common.run(["ssh", "-S", rd_common.FWD_SOCK, "-o", "BatchMode=yes", cfg["host"], "true"], timeout=5)
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
    mini is simply unreachable (ensure_mini_socket already tried to connect) - no second attempt.
    failure = 'engine' (live tunnel, engine silent: the daemon counts these toward a colima
    restart), 'tunnel' (anything else that failed) or None."""
    ok, ver, ms = docker_probe(cfg)
    if not ok and master_pid(cfg):
        if classify_probe_failure(ok, tunnel_alive(cfg)) == "engine":
            return {"ts": time.time(), "reachable": True, "docker_ok": False,
                    "rtt_ms": None, "server_version": "", "failure": "engine"}
        rd_common.log("ssh master stale (liveness check failed) -> rebuilding")
        reset_master(cfg)
        ok, ver, ms = docker_probe(cfg)
    reachable = ok or master_pid(cfg) is not None
    return {"ts": time.time(), "reachable": reachable, "docker_ok": ok,
            "rtt_ms": ms if ok else None, "server_version": ver,
            "failure": None if ok else "tunnel"}


def health_fresh(h, now=None):
    """A reading is usable iff 0 <= age < HEALTH_TTL (future-dated readings are rejected)."""
    if not isinstance(h, dict) or not isinstance(h.get("ts"), (int, float)):
        return False
    age = (time.time() if now is None else now) - h["ts"]
    return 0 <= age < rd_common.HEALTH_TTL


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
        rd_common.ensure_dirs()
        fh = open(rd_common.HEALTH_LOCK, "a+")
    except OSError as e:
        rd_common.log("health lock unavailable (%s); probing unlocked" % e)
    try:
        if fh is not None:
            _flock_wait(fh, HEALTH_WAIT)
        if reuse_fresh:
            h = rd_common.load_json(rd_common.HEALTH_PATH, None)
            if health_fresh(h):
                return h
        h = probe_health(cfg)
        rd_common.write_state(rd_common.HEALTH_PATH, h)
        return h
    finally:
        if fh is not None:
            fh.close()      # closing releases the flock


def health(cfg, force=False):
    if not force:
        h = rd_common.load_json(rd_common.HEALTH_PATH, None)
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


LOCAL_START_WAIT = 90     # seconds ensure_local_running waits for Docker Desktop to answer `info`


LOCAL_INFO_TTL = 30       # seconds a successful laptop `docker info` is trusted (stamp mtime)


def _info_stamp():
    return os.path.join(rd_common.STATE_DIR, "local-info.ok")


def _drop_info_stamp():
    try:
        os.unlink(_info_stamp())
    except OSError:
        pass


def local_engine_ready(cfg):
    """Docker Desktop is usable: its socket accepts AND `docker --context <local> info` succeeds.
    The socket alone is not enough - it accepts connections while Desktop is still booting. A
    successful info is cached for LOCAL_INFO_TTL as the mtime of STATE_DIR/local-info.ok, so
    back-to-back laptop commands pay for it once; a closed socket or a failed info deletes it."""
    if not local_engine_up(cfg):
        _drop_info_stamp()
        return False
    try:
        age = time.time() - os.stat(_info_stamp()).st_mtime
        if 0 <= age < LOCAL_INFO_TTL:
            return True
    except OSError:
        pass
    if rd_common.dk(cfg["local_context"], "info", "--format", "x", timeout=5)[0] != 0:
        _drop_info_stamp()
        return False
    try:
        rd_common.ensure_dirs()
        with open(_info_stamp(), "a"):
            pass
        os.utime(_info_stamp(), None)
    except OSError:
        pass
    return True


def ensure_local_running(cfg):
    if local_engine_ready(cfg):
        return True
    if local_engine_up(cfg):
        rd_common.say("waiting for local Docker Desktop to finish starting...")
    else:
        rd_common.say("starting local Docker Desktop (needed for this command)...")
        rd_common.run(["open", "-ga", "Docker"], timeout=10)
    deadline = time.monotonic() + LOCAL_START_WAIT
    while time.monotonic() < deadline:
        time.sleep(1)
        if local_engine_ready(cfg):
            return True
    rd_common.say("local Docker Desktop did not come up within %ds" % LOCAL_START_WAIT)
    return False


# ---------------------------------------------------------------------------- port mirroring

# Laptop mirrors bind 127.0.0.1:<p> and [::1]:<p> and forward to the mini's 127.0.0.1:<p>, so only
# bindings the mini serves on loopback/any are mirrored (HostIp as `docker inspect` reports it).
MIRROR_IPS = ("", "0.0.0.0", "127.0.0.1", "::")
PORTS_LOCK = os.path.join(rd_common.STATE_DIR, "ports.lock")       # guards reserved.json
RESERVED_PATH = os.path.join(rd_common.STATE_DIR, "reserved.json")  # {"<port>": expiry_epoch}
CID_DIR = os.path.join(rd_common.STATE_DIR, "cid")
# A laptop port stays reserved for a shim that is creating a container until the shim releases it
# (mirror up, or docker failed). RESERVE_TTL only bounds a shim that died without releasing; while
# docker runs (a long image pull) hold_ports() re-extends the shim's live reservations every
# RESERVE_REFRESH seconds, so a parallel shim can never pick the same port mid-pull.
RESERVE_TTL = 900
RESERVE_REFRESH = 60
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


def mirrored_spec(s):
    return s["ip"] in MIRROR_IPS


def _load_reserved(now):
    out, cur = {}, rd_common.load_json(RESERVED_PATH, {})
    for k, v in (cur.items() if isinstance(cur, dict) else []):
        try:
            if float(v) > now:
                out[int(k)] = float(v)
        except (TypeError, ValueError):
            continue
    return out


def mirrored_ports():
    """Laptop ports that are currently our own mirrors (owned by mini containers)."""
    st = rd_common.load_json(rd_common.FORWARDS_PATH, {})
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
    lo, hi = (cfg.get("ephemeral_port_range") or rd_common.DEFAULTS["ephemeral_port_range"])[:2]
    ours = mirrored_ports()
    rd_common.ensure_dirs()
    with rd_common.file_lock(PORTS_LOCK):
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
                                     % (rd_args.format_publish(s), a, b))
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
            rd_common.save_json(RESERVED_PATH, {str(p): t for p, t in sorted(res.items())})
        except OSError as e:
            rd_common.log("port reservation not saved: %s" % e)
    return out, mine


def release_ports(ports):
    if not ports:
        return
    try:
        with rd_common.file_lock(PORTS_LOCK):
            res = _load_reserved(time.time())
            for p in ports:
                res.pop(p, None)
            rd_common.save_json(RESERVED_PATH, {str(p): t for p, t in sorted(res.items())})
    except OSError as e:
        rd_common.log("port reservation not released: %s" % e)


def extend_ports(ports, now=None):
    """Push the expiry of our still-reserved `ports` to now + RESERVE_TTL. A port already released
    (or expired) is NOT re-reserved."""
    if not ports:
        return
    try:
        with rd_common.file_lock(PORTS_LOCK):
            now = time.time() if now is None else now
            res = _load_reserved(now)
            live = [p for p in ports if p in res]
            if not live:
                return
            for p in live:
                res[p] = now + RESERVE_TTL
            rd_common.save_json(RESERVED_PATH, {str(p): t for p, t in sorted(res.items())})
    except OSError as e:
        rd_common.log("port reservation not extended: %s" % e)


@contextmanager
def hold_ports(get_ports, every=None):
    """While the block runs (the shim's docker child), re-extend get_ports() every RESERVE_REFRESH
    seconds from a daemon thread. Release stays explicit (release_ports)."""
    stop = threading.Event()
    every = RESERVE_REFRESH if every is None else every

    def loop():
        while not stop.wait(every):
            try:
                extend_ports(list(get_ports() or []))
            except Exception as e:          # never let the keeper break the docker call
                rd_common.log("port reservation keeper: %r" % e, path=rd_common.ROUTE_LOG)
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    try:
        yield
    finally:
        stop.set()


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
    rc, out, err = rd_common.dk(cfg["remote_context"], "inspect", *ids, timeout=30)
    try:
        data = json.loads(out) if out.strip() else None
    except ValueError:
        data = None
    if not isinstance(data, list):
        rd_common.log("docker inspect on mini failed (rc=%s): %s" % (rc, err.strip()[:200]))
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
    rc, out, err = rd_common.dk(cfg["remote_context"], "ps", "-q", "--no-trunc", timeout=20)
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
            rd_common.log("container %s publishes %d ports - mirroring all of them"
                % (d.get("Name", d.get("Id", "?")[:12]), len(mine)))
        ports |= mine
    return ports


def ssh_ctl(cfg, *args, timeout=10):
    return rd_common.run(["ssh", "-S", rd_common.FWD_SOCK] + list(args) + [cfg["host"]], timeout=timeout)


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
        for f in (rd_common.FWD_SOCK, rd_common.MINI_SOCK):
            try:
                os.unlink(f)
            except OSError:
                pass
        rc, _, err = rd_common.run(["ssh", "-S", rd_common.FWD_SOCK, "-M", "-N", "-f", "-o", "ControlPersist=yes",
                          "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ExitOnForwardFailure=no",
                          "-o", "StreamLocalBindUnlink=yes", cfg["host"]], timeout=20)
        if rc != 0:
            rd_common.log("ssh master start failed: " + err.strip()[:200])
            return None
        pid = master_pid(cfg)
        rd_common.log("ssh master up pid=%s" % pid)
    if pid and cfg["remote_socket"] and not unix_alive(rd_common.MINI_SOCK):
        try:
            os.unlink(rd_common.MINI_SOCK)
        except OSError:
            pass
        rc, _, err = ssh_ctl(cfg, "-O", "forward", "-L", rd_common.MINI_SOCK + ":" + cfg["remote_socket"])
        if rc != 0:
            rd_common.log("docker socket forward failed: " + err.strip()[:200])
    return pid


def ensure_mini_socket(cfg):
    """Fast path for the shim: socket answers -> done; else (re)build the master under the lock."""
    if unix_alive(rd_common.MINI_SOCK):
        return True
    rd_common.ensure_dirs()
    with open(rd_common.LOCK_PATH, "w") as lockf:
        fcntl.flock(lockf, fcntl.LOCK_EX)
        ensure_master(cfg)
    return unix_alive(rd_common.MINI_SOCK)


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
    rd_common.ensure_dirs()
    with open(rd_common.LOCK_PATH, "w") as lockf:
        fcntl.flock(lockf, fcntl.LOCK_EX)
        pid = ensure_master(cfg)
        if not pid:
            if verbose:
                rd_common.say("cannot open the SSH control connection to " + cfg["host"])
            return False, sorted(want), []
        state = rd_common.load_json(rd_common.FORWARDS_PATH, {})
        same = isinstance(state, dict) and state.get("master_pid") == pid
        legacy = state.get("ports") if same else None     # pre-1.6 format: one list, v4+v6 tried
        cur4 = set(state.get("tcp4", legacy) or []) if same else set()
        cur6 = set(state.get("tcp6", legacy) or []) if same else set()
        conflicts = set(state.get("conflicts") or []) if same else set()
        try:
            desired = remote_ports(cfg)
        except RuntimeError as e:
            rd_common.log(str(e))
            if verbose:
                rd_common.say(str(e))
            return False, sorted(want - cur4), sorted(conflicts)
        for p in sorted(desired - cur4):
            rc, _, err = ssh_ctl(cfg, "-O", "forward", "-L", "127.0.0.1:%d:127.0.0.1:%d" % (p, p))
            if rc == 0:
                cur4.add(p)
                conflicts.discard(p)
                rd_common.log("forward +%d" % p)
            else:
                if p not in conflicts:
                    msg = ("port %d is busy on the laptop; mini container on %d is not mirrored "
                           "(free the laptop port or reach it via %s:%d)" % (p, p, cfg["host"], p))
                    rd_common.log(msg)
                    if verbose:
                        rd_common.say(msg)
                conflicts.add(p)
        for p in sorted((cur4 & desired) - cur6):      # IPv6 mirror: best effort, retried each sync
            if ssh_ctl(cfg, "-O", "forward", "-L", "[::1]:%d:127.0.0.1:%d" % (p, p))[0] == 0:
                cur6.add(p)
        for p in sorted(cur4 - desired):
            ssh_ctl(cfg, "-O", "cancel", "-L", "127.0.0.1:%d:127.0.0.1:%d" % (p, p))
            if p in cur6:
                ssh_ctl(cfg, "-O", "cancel", "-L", "[::1]:%d:127.0.0.1:%d" % (p, p))
            cur4.discard(p)
            rd_common.log("forward -%d" % p)
        cur6 &= cur4
        conflicts &= desired
        rd_common.write_state(rd_common.FORWARDS_PATH, {"master_pid": pid, "tcp4": sorted(cur4), "tcp6": sorted(cur6),
                                    "conflicts": sorted(conflicts), "ts": time.time()})
        missing = want - cur4
        return not missing, sorted(missing), sorted(conflicts)


def spawn_bg_sync(repeat=6, interval=1.5):
    """Detached sync loop - for foreground `docker run -p` and async cleanup after stop/rm."""
    try:
        subprocess.Popen([sys.executable, "-I", rd_common.ENTRY, "sync",
                          "--repeat", str(repeat), "--interval", str(interval)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass
