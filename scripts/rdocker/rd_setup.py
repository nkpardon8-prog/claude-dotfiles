"""rdocker rd_setup: install / launch agent / setup-mini, plus the CLI (status, where, main, command).

Split out of rdocker.py; see rdocker.py for the overview.
"""
import fcntl
import json
import os
import shutil
import socket
import subprocess
import time

import rd_common
import rd_tunnel
import rd_route
import rd_janitor
import rd_daemon
import rd_run


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
    rc, out, _ = rd_common.run(["launchctl", "list", rd_common.PLIST_LABEL], timeout=5)
    return rc == 0


def install_daemon():
    os.makedirs(os.path.dirname(rd_common.PLIST_PATH), exist_ok=True)
    with open(rd_common.PLIST_PATH, "w") as f:
        f.write(PLIST.format(label=rd_common.PLIST_LABEL, script=rd_common.ENTRY, log=rd_common.LOG_PATH))
    uid = str(os.getuid())
    rd_common.run(["launchctl", "bootout", "gui/" + uid + "/" + rd_common.PLIST_LABEL], timeout=10)
    rc, _, err = rd_common.run(["launchctl", "bootstrap", "gui/" + uid, rd_common.PLIST_PATH], timeout=10)
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
    rd_common.ensure_dirs()
    real = rd_common.real_docker()
    # 1. docker context for the mini = the mini's docker socket, streamed over the SSH master
    if not cfg["remote_socket"]:
        rc, out, _ = rd_common.run(["ssh", "-o", "BatchMode=yes", cfg["host"], "echo $HOME"], timeout=20)
        if rc == 0 and out.strip():
            cfg["remote_socket"] = out.strip() + "/.colima/default/docker.sock"
    verb = "update" if rd_common.run([real, "context", "inspect", cfg["remote_context"]],
                           timeout=10)[0] == 0 else "create"
    rc, _, err = rd_common.run([real, "context", verb, cfg["remote_context"], "--description",
                      "Mac mini over Tailscale (rdocker)", "--docker",
                      "host=unix://" + rd_common.MINI_SOCK], timeout=15)
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
    if rd_tunnel.local_engine_up(cfg):
        rc, out, _ = rd_common.dk(cfg["local_context"], "ps", "-a", "--format",
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
    cfg = rd_common.update_cfg(apply)
    # 4. shims
    os.makedirs(rd_common.BIN_DIR, exist_ok=True)
    os.chmod(rd_common.SHIM_SRC, 0o755)
    os.chmod(rd_common.ENTRY, 0o755)
    link(rd_common.SHIM_SRC, os.path.join(rd_common.BIN_DIR, "docker"))
    link(rd_common.ENTRY, os.path.join(rd_common.BIN_DIR, "rdocker"))
    os.chmod(rd_common.RRUN_SRC, 0o755)
    link(rd_common.RRUN_SRC, os.path.join(rd_common.BIN_DIR, "rrun"))
    # 5. background forwarder
    ok = install_daemon()
    print("installed: docker shim + rdocker + rrun in %s, launch agent %s (%s)"
          % (rd_common.BIN_DIR, rd_common.PLIST_LABEL, "loaded" if ok else "LOAD FAILED"))
    print("pinned to laptop: containers=%s compose=%s"
          % (cfg["pins"]["containers"], cfg["pins"]["compose_projects"]))


# The mini's engine config, owned by rdocker. colima.yaml gets this `docker:` block (daemon.json:
# publish on 127.0.0.1 by default, capped json-file logs, build-cache GC); Lima's override.yaml makes
# the VM->mini port forwarder bind 127.0.0.1 only (DNS port 53 ignored first - order matters).
COLIMA_DOCKER_BLOCK = """docker:
  ip: 127.0.0.1
  log-driver: json-file
  log-opts:
    max-size: 10m
    max-file: "3"
  builder:
    gc:
      enabled: true
      defaultKeepStorage: 5GB
"""
LIMA_OVERRIDE = """# rdocker: Lima port forwards bind the mini's loopback only (written whole by rdocker setup-mini)
portForwards:
  - guestPort: 53
    ignore: true
  - guestIP: 0.0.0.0
    hostIP: 127.0.0.1
"""

# POSIX sh (no python/yq on the mini). Idempotent: each file is rebuilt into a temp file and only
# swapped in (old copy kept as <file>.bak.<epoch>) when it differs. Prints `RDSETUP changed` or
# `RDSETUP unchanged` (or `RDSETUP no-profile`). The docker block replaced runs from a top-level
# `docker:` line to the next non-indented line (key or column-0 comment); blank lines just before
# that line are kept. No `docker:` key -> the block is appended.
MINI_CONFIG = r"""CY="$HOME/.colima/default/colima.yaml"
OV="$HOME/.colima/_lima/_config/override.yaml"
TS=$(date +%s)
CHANGED=0
[ -f "$CY" ] || { echo "RDSETUP no-profile"; exit 1; }
BLOCK=$(cat <<'RDOCKER_BLOCK'
@BLOCK@RDOCKER_BLOCK
)
OVER=$(cat <<'RDOCKER_OVER'
@OVER@RDOCKER_OVER
)
swap() {   # $1 = target, $2 = new content file
  if [ -f "$1" ] && cmp -s "$1" "$2"; then rm -f "$2"; return 0; fi
  [ -f "$1" ] && cp -p "$1" "$1.bak.$TS"
  mv -f "$2" "$1" && CHANGED=1
}
printf '%s\n' "$BLOCK" > "$CY.rdnew.$$"
awk -v blockfile="$CY.rdnew.$$" '
  function emit(  l) { while ((getline l < blockfile) > 0) print l; close(blockfile); done = 1 }
  skip && /^[ \t]*$/ { held = held $0 "\n"; next }
  skip && /^[ \t]/ { held = ""; next }
  skip { emit(); printf "%s", held; held = ""; skip = 0 }
  !done && /^docker:/ { skip = 1; next }
  { print }
  END { if (skip) { emit(); printf "%s", held } else if (!done) { print ""; emit() } }
' "$CY" > "$CY.rdtmp.$$" || { rm -f "$CY.rdnew.$$" "$CY.rdtmp.$$"; echo "RDSETUP error awk"; exit 1; }
rm -f "$CY.rdnew.$$"
swap "$CY" "$CY.rdtmp.$$"
mkdir -p "$(dirname "$OV")"
printf '%s\n' "$OVER" > "$OV.rdtmp.$$"
swap "$OV" "$OV.rdtmp.$$"
if [ "$CHANGED" = 1 ]; then echo "RDSETUP changed"; else echo "RDSETUP unchanged"; fi
"""

MINI_PRELUDE = r"""set -e
export PATH=@BREW@:$PATH
grep -q 'rdocker: homebrew' ~/.zshenv 2>/dev/null || {
  printf '%s\n' '# rdocker: homebrew + colima docker for non-interactive ssh (docker over ssh needs them)' \
    'export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH' >> ~/.zshenv; }
for f in colima docker; do brew list --formula $f >/dev/null 2>&1 || brew install $f; done
if [ ! -f "$HOME/.colima/default/colima.yaml" ]; then
  colima start --vm-type vz --vz-rosetta --cpu @CPU@ --memory @MEM@ --disk @DISK@
elif ! colima status >/dev/null 2>&1; then
  colima start
fi
brew services list | grep -q '^colima.*started' || brew services start colima
docker context use colima >/dev/null 2>&1 || true
docker version --format 'mini docker server {{.Server.Version}} ({{.Server.Arch}})'
colima list
set +e
"""


def mini_config_script():
    """The idempotent colima.yaml docker-block + Lima override edit (POSIX sh, run on the mini)."""
    return (MINI_CONFIG.replace("@BLOCK@", COLIMA_DOCKER_BLOCK)
            .replace("@OVER@", LIMA_OVERRIDE))


def setup_mini(cfg, cpu, mem, disk):
    """Mini side over ssh: brew colima+docker, the VM (created only when there is no profile), then
    the rdocker engine config. A config change is NOT applied by restarting here - other agents'
    containers may be running: it sets janitor.json restart_pending and the janitor restarts Colima
    under the mini lock once nothing runs (apply_when_idle)."""
    script = (MINI_PRELUDE.replace("@BREW@", rd_janitor.BREW_PATH).replace("@CPU@", cpu)
              .replace("@MEM@", mem).replace("@DISK@", disk) + mini_config_script())
    print("configuring %s over ssh (brew colima+docker, VM %s cpu / %sGB / %sGB disk)..."
          % (cfg["host"], cpu, mem, disk))
    p = subprocess.Popen(["ssh", "-o", "BatchMode=yes", cfg["host"], "/bin/sh", "-s"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    p.stdin.write(script)
    p.stdin.close()
    lines = []
    for line in p.stdout:
        lines.append(line)
        if not line.startswith("RDSETUP "):
            print(line, end="", flush=True)
    rc = p.wait()
    return setup_mini_result(cfg, rc, rd_janitor.marker("".join(lines), "RDSETUP"))


def setup_mini_result(cfg, rc, m):
    """Report setup-mini's config outcome; a change marks a Colima restart pending -> exit code."""
    if m[:1] == ["changed"]:
        now = time.time()
        rd_common.update_state(rd_common.JANITOR_PATH, lambda st0: {
            **st0, "restart_pending": True,
            "restart_pending_since": st0.get("restart_pending_since") if st0.get("restart_pending")
            and isinstance(st0.get("restart_pending_since"), (int, float)) else now})
        print("mini engine config changed -> Colima restart pending; the janitor applies it once no "
              "container runs on the mini (rdocker clean / within %d min)"
              % cfg["janitor_interval_min"])
    elif m[:1] == ["unchanged"]:
        print("mini engine config unchanged")
    else:
        print("mini engine config NOT applied (%s)" % (" ".join(m) or "setup failed, rc=%s" % rc))
        return rc or 1
    return rc


# ---------------------------------------------------------------------------- status / doctor

def status(cfg, fix=False):
    real = rd_common.real_docker()
    rows = []

    def row(ok, label, detail=""):
        rows.append(("OK " if ok else "-- ") + label + (": " + detail if detail else ""))
        return ok

    if os.path.exists(rd_daemon.TS_CLI):
        if fix:
            rd_daemon.tailscale_up()
        up = rd_daemon.tailscale_running()
        row(up, "tailscale on laptop", "" if up else "stopped - run: rdocker doctor")
    prior = rd_common.load_json(rd_common.HEALTH_PATH, None)   # what shims were using until now
    h = rd_tunnel.refresh_health(cfg)
    row(h["reachable"], "mini reachable (%s)" % cfg["host"],
        "ssh control connection up" if h["reachable"] else "no ssh control connection")
    if h["reachable"] and not h.get("docker_ok") and fix:
        # VM down -> start (profile-guarded, via the brew-services agent when loaded). Never a
        # VM-up restart from here: that is the daemon's call, under its 10-min + mini-side checks.
        rd_janitor.mini_engine_kick(cfg)
        h = rd_tunnel.refresh_health(cfg)
    row(bool(h.get("docker_ok")), "mini docker engine",
        "%s, %sms round-trip" % (h.get("server_version"), h.get("rtt_ms")) if h.get("docker_ok")
        else "not responding")
    target, why = rd_tunnel.resolve_target(cfg)
    row(True, "mode=%s -> commands go to %s" % (cfg["mode"], target.upper()), why)
    shim_ok = os.path.realpath(os.path.join(rd_common.BIN_DIR, "docker")) == os.path.realpath(rd_common.SHIM_SRC)
    first = shutil.which("docker")
    row(shim_ok and first and os.path.realpath(first) == os.path.realpath(rd_common.SHIM_SRC),
        "docker shim first on PATH", first or "none")
    loaded = daemon_loaded()
    if not loaded and fix:
        loaded = install_daemon()
    row(loaded, "background forwarder (launchd %s)" % rd_common.PLIST_LABEL)
    now = time.time()
    for ok, label, detail in (daemon_rows(now) + [health_age_row(prior, now)]
                              + janitor_rows(cfg, now) + [janitor_stopped_row(now),
                                                          fallback_pins_row(cfg),
                                                          rd_run.status_row(now)]):
        row(ok, label, detail)
    if fix and h.get("docker_ok"):
        rd_tunnel.sync_forwards(cfg, verbose=True)
    st = rd_common.load_json(rd_common.FORWARDS_PATH, {})
    v4 = st.get("tcp4") or []
    no6 = sorted(set(v4) - set(st.get("tcp6") or []))
    row(True, "mirrored ports", (", ".join(str(p) for p in v4) or "none")
        + (" (IPv6 mirror pending: %s)" % ", ".join(map(str, no6)) if no6 else ""))
    if st.get("conflicts"):
        row(False, "port conflicts (busy on laptop)", ", ".join(map(str, st["conflicts"])))
    row(True, "laptop Docker Desktop", "running" if rd_tunnel.local_engine_up(cfg) else "stopped (starts on demand)")
    ctx = rd_common.run([real, "context", "show"], timeout=10)[1].strip()
    row(True, "global docker context", ctx)
    if fix:
        drift = rd_daemon.flag_drift_check()
        row(True, "docker CLI flags vs rd_args.SPECS", "could not read --help" if drift is None
            else "%d unknown" % len(drift) if drift else "all known")
    rows.extend(attention_rows(now))
    print("\n".join(rows))
    # rc: only `--` rows (real faults: mini/engine/daemon/shim down, recent janitor error, port
    # conflicts) fail status; WARN rows are attention items for a human and keep rc 0.
    return all(not r.startswith("-- ") for r in rows)


def attention_rows(now):
    """attention.json items as `WARN` rows: things a human should look at. They never fail status
    (only `--` rows do), so a walk-away condition is visible without breaking health checks."""
    return ["WARN %s (since %s)" % (i["msg"], ago(i["since"] if isinstance(i.get("since"), (int, float))
                                                  else now, now))
            for i in rd_common.attention_items()]


def ago(ts, now):
    """'42s ago' / '7m ago' / '3h ago' / '2d ago' for an epoch timestamp."""
    d = max(0, int(now - ts))
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if d >= size:
            return "%d%s ago" % (d // size, unit)
    return "%ds ago" % d


RELOAD_GRACE = 2 * rd_common.PERIODIC   # the daemon checks its code every tick; longer = stuck


def daemon_rows(now):
    """The running daemon (daemon.json, written at its start) vs the code on disk. The daemon
    re-execs itself within one tick of a code change; a change older than RELOAD_GRACE that it
    has not picked up means the new code does not import (see daemon.log)."""
    d = rd_common.load_json(rd_common.DAEMON_PATH, None)
    if not isinstance(d, dict) or not isinstance(d.get("pid"), int):
        return [(False, "daemon process", "no daemon.json - not started since this version")]
    if not rd_daemon.pid_alive(d["pid"]):
        return [(False, "daemon process", "pid %d not running" % d["pid"])]
    disk = rd_daemon.code_mtime(rd_daemon.module_mtimes())
    ran = d.get("code_mtime")
    detail = "pid %d, started %s" % (d["pid"], ago(d.get("started") or now, now))
    if disk is None or not isinstance(ran, (int, float)) or disk <= ran:
        return [(True, "daemon process", detail + ", running the code on disk")]
    stuck = now - disk > RELOAD_GRACE
    return [(not stuck, "daemon process", detail + ", code changed %s - reload %s"
             % (ago(disk, now), "NOT picked up (does it import? see daemon.log)" if stuck
                else "pending"))]


def health_age_row(prior, now):
    """Age of the health reading shims were using before this status re-probed (the daemon keeps it
    under HEALTH_TTL; older means shims probe inline)."""
    if not isinstance(prior, dict) or not isinstance(prior.get("ts"), (int, float)):
        return (True, "health reading", "none on file before this check")
    age = now - prior["ts"]
    return (True, "health reading", "%ds old before this check (fresh < %ds)"
            % (age, rd_common.HEALTH_TTL))


def janitor_rows(cfg, now):
    """Last janitor pass, its last error and the mini's disk use, from janitor.json."""
    j = rd_common.load_json(rd_common.JANITOR_PATH, {})
    j = j if isinstance(j, dict) else {}
    rows = []
    last = j.get("last_run")
    rows.append((True, "janitor last run",
                 ago(last, now) if isinstance(last, (int, float)) else "never"))
    err = j.get("last_error")
    if isinstance(err, dict) and isinstance(err.get("ts"), (int, float)):
        # kept until the next failure, so only an error from about the latest pass counts as a fault
        recent = now - err["ts"] < 1.5 * cfg["janitor_interval_min"] * 60
        rows.append((not recent, "janitor last error", "%s: %s: %s" % (
            ago(err["ts"], now), err.get("action", "?"), str(err.get("err", ""))[:160])))
    elif err:
        rows.append((True, "janitor last error", str(err)[:200]))
    pct = j.get("vm_disk_pct")
    if isinstance(pct, (int, float)):
        free = j.get("mini_free_gb")
        rows.append((True, "mini disk", "VM %s%% used%s" % (
            pct, ", mini %s GB free" % free if isinstance(free, (int, float)) else "")))
    if j.get("restart_pending"):
        rows.append((True, "mini engine config", "Colima restart pending (applied when idle)"))
    return rows


def janitor_stopped_row(now, window=86400):
    """Containers either janitor idle-stopped in the last 24 h (auto-started again on exec/cp/...)."""
    items = []
    for target, where_ in (("mini", "mini"), ("local", "laptop")):
        for cid, r in rd_common.janitor_stops(rd_common.janitor_state_path(target)).items():
            ts = r.get("ts")
            if isinstance(ts, (int, float)) and 0 <= now - ts < window:
                items.append((ts, "%s (%s, %dh ago)" % (r.get("name") or cid[:12], where_,
                                                         (now - ts) // 3600)))
    return (True, "janitor-stopped in the last 24 h (restarted on exec/cp/attach/top/port/logs -f "
                  "unless run since; --rm ones were deleted by the stop)",
            ", ".join(t for _, t in sorted(items, reverse=True)) or "none")


def fallback_pins_row(cfg):
    fb = [p for p in cfg["pins"].get("fallback") or [] if isinstance(p, dict) and p.get("name")]
    return (True, "fallback pins (made on the laptop while the mini was out)",
            ", ".join("%s (%s)" % (p["name"], p.get("kind", "?")) for p in fb) or "none")


def where(cfg, name):
    on_mini = rd_route.exists_on(cfg, "remote_context", name)
    on_local = rd_route.exists_on(cfg, "local_context", name) if rd_tunnel.local_engine_up(cfg) else False
    found = [x for x, y in (("mini", on_mini), ("laptop", on_local)) if y]
    unknown = [x for x, y in (("mini", on_mini), ("laptop", on_local)) if y is None]
    print("%s: %s%s" % (name, " + ".join(found) or "not found",
                        " (could not ask: %s)" % ", ".join(unknown) if unknown else ""))


# ---------------------------------------------------------------------------- daemon jobs

JOB_LOCKS = {"janitor-run": "janitor.lock", "kick": "kick.lock",
             "laptop-janitor-run": "laptop-janitor.lock"}


def run_job(name, cfg, args=()):
    """Daemon-spawned job (`rdocker janitor-run` / `laptop-janitor-run` / `kick`). Takes a NON-blocking flock on its
    own lock file: if a previous run still holds it, exit 0 quietly instead of piling up."""
    rd_common.ensure_dirs()
    with open(os.path.join(rd_common.STATE_DIR, JOB_LOCKS[name]), "a+") as fh:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
        try:
            if name == "kick":
                rd_janitor.mini_engine_kick(cfg, restart_ok="--restart-ok" in args)
            elif name == "laptop-janitor-run":
                rd_janitor.laptop_janitor(cfg)
            else:
                rd_janitor.janitor(cfg)
                rd_janitor.apply_when_idle(cfg)
        except Exception as e:  # logged like the old in-daemon janitor; the daemon sees rc=1
            rd_common.log("%s error: %r" % (name, e))
            return 1
    return 0


# ---------------------------------------------------------------------------- CLI

DESCRIPTION = "Run Docker on the always-on Mac mini, transparently (see commands/docker.md)."


def build_parser():
    """The rdocker CLI. argparse is imported here, not at module level: the shim (main's fast path)
    never needs it. janitor-run / kick are internal (spawned by the daemon) and not listed."""
    import argparse
    p = argparse.ArgumentParser(prog="rdocker", description=DESCRIPTION)
    sp = p.add_subparsers(dest="cmd", metavar="<command>")
    s = sp.add_parser("status", help="health, routing target, mirrored ports, janitor, daemon")
    s.add_argument("--fix", action="store_true", help="also repair (same as `rdocker doctor`)")
    sp.add_parser("doctor", help="status + repair (tailscale, mini engine, forwarder, forwards)")
    s = sp.add_parser("use", help="routing mode (auto = mini when healthy & fast, else laptop; "
                                  "off = plain docker, global context -> laptop)")
    s.add_argument("mode", choices=("auto", "mini", "local", "off"))
    s = sp.add_parser("where", help="which engine holds a container")
    s.add_argument("name")
    s = sp.add_parser("pin", help="keep a container (or --compose project) on the laptop engine")
    s.add_argument("name")
    s.add_argument("--compose", action="store_true", help="NAME is a compose project")
    s = sp.add_parser("unpin", help="drop a laptop pin (container or compose project)")
    s.add_argument("name")
    s = sp.add_parser("sync", help="reconcile port mirrors now")
    s.add_argument("--repeat", type=int, default=1, metavar="N")
    s.add_argument("--interval", type=float, default=1.5, metavar="S")
    s = sp.add_parser("logs", help="tail the forwarder log (or --route: the per-command routing log)")
    s.add_argument("--route", action="store_true")
    s = sp.add_parser("clean", help="run the mini janitor now (auto every 10 min)",
                      description="Run the mini janitor now. Waits up to %ds for the mini lock "
                      "(background janitor), then exits 1." % rd_janitor.CLEAN_LOCK_WAIT)
    s.add_argument("--dry-run", action="store_true", help="print what would be done")
    s.add_argument("--only", metavar="PREFIX",
                   help="limit container/volume rules to this name prefix (no global prunes)")
    s.add_argument("--force-critical", action="store_true",
                   help="apply the disk-critical stopped-container removal now "
                        "(rdocker.keep always exempt)")
    g = s.add_argument_group("threshold overrides (testing)")
    for k in CLEAN_OVERRIDES:
        g.add_argument("--" + k, type=float, metavar="N")
    s = sp.add_parser("run", help="run a heavy job ON the Mac mini (same as `rrun`)",
                      description="Run <command> on the Mac mini against a snapshot of this git "
                      "worktree (HEAD + uncommitted/untracked files + allowlisted .env files); "
                      "output streams back, the exit code is the command's. Mini unreachable "
                      "before the command was released (GO) => runs on the laptop (RRUN_STRICT=1: "
                      "exit 75 instead); mini lost after that => exit 75, never a second run.")
    s.add_argument("-e", dest="env", action="append", default=[], metavar="NAME[=VALUE]",
                   help="environment for the remote command (repeatable); a bare NAME forwards "
                   "that variable's value from rrun's own environment (keeps it out of argv)")
    s.add_argument("argv", nargs=argparse.REMAINDER, metavar="[--] command ...")
    sp.add_parser("install", help="laptop side: context, shims, launch agent, pins")
    s = sp.add_parser("setup-mini", help="mini side over ssh: colima+docker + engine config "
                                         "(Colima restart deferred until the mini is idle)")
    s.add_argument("cpu", nargs="?", default="6")
    s.add_argument("mem", nargs="?", default="8", help="GB")
    s.add_argument("disk", nargs="?", default="30", help="GB")
    sp.add_parser("daemon", help="(launchd) event-driven forwarder")
    sp.add_parser("janitor-run")                      # internal, spawned by the daemon
    sp.add_parser("laptop-janitor-run")               # internal, spawned by the daemon
    s = sp.add_parser("kick")                         # internal, spawned by the daemon
    s.add_argument("--restart-ok", action="store_true")
    return p


CLEAN_OVERRIDES = ("idle_stop_hours", "exited_rm_hours", "volume_unused_days", "image_unused_days")


def parse_args(argv):
    """-> (namespace, None) or (None, exit code) when argparse printed help/usage and stopped."""
    try:
        ns = build_parser().parse_args(argv)
    except SystemExit as e:          # --help -> 0, bad usage -> 2 (usage already on stderr)
        return None, e.code if isinstance(e.code, int) else 2
    if ns.cmd is None:
        ns.cmd, ns.fix = "status", False
    return ns, None


def routing_failed(args, exc):
    """The shim's routing raised before docker ran. Running the command unrouted would send it to
    whatever the global context says (maybe the wrong engine), so - as when the modules fail to
    import (rdocker.py) - only the FALLBACK_SAFE commands run on the real docker; anything that
    targets or creates a container is refused with exit 1. The traceback goes to route.log."""
    import traceback
    import rdocker
    rd_common.log("shim routing error: %s" % traceback.format_exc().strip().replace("\n", " | "),
                  path=rd_common.ROUTE_LOG)
    unrouted, sub = rdocker.fallback_split(args)
    if unrouted or sub is None or sub in rdocker.FALLBACK_SAFE:
        rd_route.exec_real(args)
        return 0
    rd_common.say("internal error routing %s: %s (run rdocker doctor)" % (sub, exc))
    return 1


def main(argv):
    if argv and argv[0] == "shim":        # the hot path: no argparse, no CLI setup
        rd_common.attention_notify()      # stderr only, at most hourly per item, never raises
        try:
            rd_route.shim(argv[1:])
        except SystemExit:
            raise
        except Exception as e:
            if rd_route.INVOKED["invoked"]:
                # docker already ran: never run it a second time; report its exit code.
                rd_common.log("shim error after docker ran (rc=%s): %r" % (rd_route.INVOKED["rc"], e))
                rd_common.say("internal error after docker ran (%s); see %s" % (e, rd_common.LOG_PATH))
                return rd_route.INVOKED["rc"] if rd_route.INVOKED["rc"] is not None else 1
            return routing_failed(argv[1:], e)
        return 0
    try:
        return command(argv)
    except rd_common.ConfigWriteError as e:
        rd_common.say("config not saved: %s" % e)
        return 1


def use_mode(mode):
    """`rdocker use <mode>`. Every mode also points the global docker context at an engine, so docker
    run without the shim (or with RDOCKER_BYPASS) agrees: off -> the laptop engine."""
    cfg = rd_common.update_cfg(lambda cur: {**cur, "mode": mode})
    try:
        os.unlink(rd_common.HEALTH_PATH)
    except OSError:
        pass
    target = "local" if mode == "off" else rd_tunnel.resolve_target(cfg)[0]
    rd_daemon.set_global_context(cfg, target)
    print("mode=" + mode)
    return 0


def set_pin(name, pin, compose=False):
    def apply(cur):
        pins = dict(cur["pins"])
        for key in ("containers", "compose_projects"):
            pins[key] = [n for n in pins[key] if pin or n != name]
        if not pin:          # unpin also drops automatic (fallback) pins of that name
            pins["fallback"] = [p for p in pins.get("fallback") or []
                                if not (isinstance(p, dict) and p.get("name") == name)]
        if pin:
            key = "compose_projects" if compose else "containers"
            if name not in pins[key]:
                pins[key].append(name)
        return {**cur, "pins": pins}
    cfg = rd_common.update_cfg(apply)
    print(json.dumps(cfg["pins"]))
    return 0


def clean(cfg, ns):
    cfg = dict(cfg)
    for k in CLEAN_OVERRIDES:                       # test overrides
        if getattr(ns, k) is not None:
            cfg[k] = getattr(ns, k)
    try:
        acts = rd_janitor.janitor(cfg, dry=ns.dry_run, only=ns.only, force_critical=ns.force_critical,
                                  lock_wait=rd_janitor.CLEAN_LOCK_WAIT)
    except rd_janitor.MiniLockBusy as e:
        rd_common.say("clean not run: %s (waited %ds; the background janitor may be mid-pass - "
                      "retry shortly)" % (e, rd_janitor.CLEAN_LOCK_WAIT))
        return 1
    except rd_janitor.MiniEngineDown as e:
        rd_common.say("clean not run: %s - see `rdocker status`" % e)
        return 1
    for a in acts:
        print(("would: " if ns.dry_run else "") + a)
    return 0


def command(argv):
    ns, rc = parse_args(argv)
    if ns is None:
        return rc
    cmd = ns.cmd
    if cmd == "run":
        return rd_run.rrun(ns.argv, ns.env)
    cfg = rd_common.load_cfg()
    if cmd in ("status", "doctor"):
        return 0 if status(cfg, fix=cmd == "doctor" or ns.fix) else 1
    if cmd == "use":
        return use_mode(ns.mode)
    if cmd == "where":
        where(cfg, ns.name)
        return 0
    if cmd in ("pin", "unpin"):
        return set_pin(ns.name, cmd == "pin", getattr(ns, "compose", False))
    if cmd == "sync":
        ok = True
        for i in range(ns.repeat):
            ok = rd_tunnel.sync_forwards(cfg, verbose=(ns.repeat == 1))[0]
            if i < ns.repeat - 1:
                time.sleep(ns.interval)
        return 0 if ok else 1
    if cmd == "logs":
        path = rd_common.ROUTE_LOG if ns.route else rd_common.LOG_PATH
        os.execvp("tail", ["tail", "-n", "60", path])
    if cmd == "clean":
        return clean(cfg, ns)
    if cmd == "install":
        install(cfg)
        return 0
    if cmd == "setup-mini":
        return setup_mini(cfg, ns.cpu, ns.mem, ns.disk)
    if cmd in JOB_LOCKS:          # internal: spawned detached by the daemon
        return run_job(cmd, cfg, ["--restart-ok"] if getattr(ns, "restart_ok", False) else [])
    if cmd == "daemon":
        rd_daemon.daemon()
        return 0
    return 2      # unreachable: argparse rejects unknown commands
