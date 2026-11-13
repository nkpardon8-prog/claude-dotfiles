"""rdocker rd_fleet: the machine registry (fleet.json) - load/validate, ssh Host blocks, sync-fleet.

fleet.json lives in the dotfiles (synced between machines), so it never holds secrets: only public
client keys and per-machine facts. Roles: home (docker routing target, kept DBs; at most one),
worker (rrun target; linux, or a mac "rented" via its share switch - see rr_runner.pl), agent (never
gets jobs). Disabled/placeholder entries (ip "") are allowed.
"""
import copy
import json
import ipaddress
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time

import rd_common

SERVER_DIR = os.path.join(rd_common.HERE, "server")        # provision-linux.sh, rd-tune.*
REPORTER_DIR = os.path.join(rd_common.HERE, "reporter")    # shipped to a server when present (lane C)
ROLES = ("home", "worker", "agent")
OSES = ("linux", "mac")
FIELDS = {"name": str, "alias": str, "ip": str, "port": int, "user": str, "os": str, "wsl": bool,
          "roles": list, "speed": (int, float), "max_slots": int, "heavy_slots": int, "mem_gb": (int, float),
          "enabled": bool, "ts_key_expiry": str,   # ts_key_expiry: YYYY-MM-DD, or "none" (key expiry disabled)
          "shards": bool,   # shards: false = a worker that never gets a vitest shard (and is not pre-warmed)
          # eligibility (rd_pool.eligibility; a missing field = no limit): classes = the job classes it
          # takes; max_cost_s = the longest expected command (s, on this worker) it takes; cold_ok: false
          # = never a job whose packages are not prepared there yet (no npm ci in one of its slots)
          "classes": list, "max_cost_s": (int, float), "cold_ok": bool,
          # evidence (rd_pool.Model): runs.log rows before this epoch are ignored - set it at a hardware
          # or config change (an SSD, a CPU swap, new eligibility) so old timings never count.
          # ROLLOUT: rd_fleet before 2026-11-11 rejects unknown fields (the whole fleet.json, so every
          # client falls back to one host): add it only after every client runs this code (Phase B rule)
          "history_since": int,
          # optional: true = a nice addition that is often away (a laptop): while it is down, rrun leaves
          # it out of the plan and nothing (rrun, rd-steward) warns about it. Same ROLLOUT rule as above
          "optional": bool}
# rd_run worktree lanes (Phase C1, 2026-11-13): concurrent rrun jobs per agent worktree; each lane has its
# own worker mirror and push ref. Small on purpose: every lane is one more checkout + node_modules per worker.
WT_LANES_DEFAULT, WT_LANES_MAX = 3, 8
JOB_CLASSES = ("light", "normal", "heavy", "db", "build")    # rd_pool.classify's classes
REQUIRED = ("name", "roles", "enabled")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
KEY_RE = re.compile(r"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[A-Za-z0-9-]+) [A-Za-z0-9+/]+={0,2}( [^\x00-\x1f]+)?$")
SECRETISH = re.compile(r"(secret|token|passw|private)", re.I)    # fleet.json is synced: refuse these keys
DEFAULT_ENTRY = {"alias": "", "ip": "", "port": 22, "user": "rd", "os": "linux", "wsl": False,
                 "speed": 0.5, "max_slots": 2, "heavy_slots": 1, "mem_gb": 8}


class FleetError(ValueError):
    """fleet.json is missing, unreadable or invalid (message lists every problem)."""


def problems(fl):
    """-> list of human-readable problems with a fleet dict ([] = valid)."""
    bad = []
    if not isinstance(fl, dict) or not isinstance(fl.get("machines"), list):
        return ["top level must be an object with a 'machines' list"]
    keys = fl.get("client_keys", [])
    if not isinstance(keys, list) or not all(isinstance(k, str) and KEY_RE.match(k) for k in keys):
        bad.append("client_keys must be a list of one-line SSH public keys")
    pnm = fl.get("pool_node_major")
    if pnm is not None and (not isinstance(pnm, int) or isinstance(pnm, bool) or not 1 <= pnm <= 999):
        bad.append("pool_node_major must be a whole number (the node major the pool runs, e.g. 25)")
    wl = fl.get("wt_lanes")
    if wl is not None and (not isinstance(wl, int) or isinstance(wl, bool) or not 1 <= wl <= WT_LANES_MAX):
        bad.append("wt_lanes must be a whole number from 1 to %d (concurrent rrun jobs per worktree)" % WT_LANES_MAX)
    names, aliases, homes = set(), set(), []
    for i, m in enumerate(fl["machines"]):
        if not isinstance(m, dict):
            bad.append("machines[%d] is not an object" % i)
            continue
        who = "machine %r" % (m.get("name") or i)
        for k in m:
            if k not in FIELDS:
                bad.append("%s: unknown field %r%s" % (who, k, " (no secrets in fleet.json)" if SECRETISH.search(k) else ""))
        for k in REQUIRED:
            if k not in m:
                bad.append("%s: missing %r" % (who, k))
        mistyped = [k for k, t in FIELDS.items() if k in m
                    and (not isinstance(m[k], t) or (isinstance(m[k], bool) and t is not bool))]
        bad += ["%s: %r has the wrong type" % (who, k) for k in mistyped]
        if mistyped:
            continue
        e = {**DEFAULT_ENTRY, **m}
        if not NAME_RE.match(str(m.get("name", ""))):
            bad.append("%s: name must be lowercase letters, digits, '-'" % who)
        if m.get("name") in names:
            bad.append("%s: duplicate name" % who)
        names.add(m.get("name"))
        if e["alias"]:
            if not ALIAS_RE.match(e["alias"]):
                bad.append("%s: bad alias" % who)
            if e["alias"] in aliases:
                bad.append("%s: duplicate alias %r" % (who, e["alias"]))
            aliases.add(e["alias"])
        if e["ip"]:
            try:
                ipaddress.IPv4Address(e["ip"])
            except ValueError:
                bad.append("%s: ip %r is not an IPv4 address" % (who, e["ip"]))
        if e["os"] not in OSES:
            bad.append("%s: os must be one of %s" % (who, "/".join(OSES)))
        if not isinstance(m.get("roles"), list) or not m["roles"] or any(r not in ROLES for r in m["roles"]):
            bad.append("%s: roles must be a non-empty subset of %s" % (who, "/".join(ROLES)))
            continue
        roles = m["roles"]
        if "agent" in roles and len(roles) > 1:
            bad.append("%s: agent cannot be combined with other roles" % who)
        if "home" in roles:
            homes.append(m.get("name"))
        serves = any(r in roles for r in ("home", "worker"))
        if serves:
            if "home" in roles and e["os"] != "linux":
                bad.append("%s: the home machine must be linux" % who)
            elif e["os"] not in ("linux", "mac"):
                bad.append("%s: worker machines must be linux or mac" % who)
            if not USER_RE.match(e["user"]):
                bad.append("%s: bad ssh user" % who)
            if not e["alias"]:
                bad.append("%s: home/worker needs an alias" % who)
            if m.get("enabled") and not e["ip"]:
                bad.append("%s: enabled home/worker needs an ip" % who)
        if not 1 <= e["port"] <= 65535:
            bad.append("%s: port out of range" % who)
        if e["speed"] <= 0:
            bad.append("%s: speed must be > 0" % who)
        if e["max_slots"] < 0 or e["heavy_slots"] < 0 or e["heavy_slots"] > e["max_slots"]:
            bad.append("%s: need 0 <= heavy_slots <= max_slots" % who)
        if "worker" in roles and m.get("enabled") and e["max_slots"] < 1:
            bad.append("%s: an enabled worker needs max_slots >= 1" % who)
        if "classes" in m and (not m["classes"] or any(not isinstance(c, str) or c not in JOB_CLASSES
                                                       for c in m["classes"])
                               or len(set(m["classes"])) != len(m["classes"])):
            bad.append("%s: classes must be a non-empty list of distinct job classes from %s"
                       % (who, "/".join(JOB_CLASSES)))
        if "max_cost_s" in m and not m["max_cost_s"] > 0:
            bad.append("%s: max_cost_s must be > 0 (seconds)" % who)
        if "history_since" in m and not 1600000000 <= m["history_since"] <= time.time() + 86400:
            bad.append("%s: history_since must be a unix epoch (seconds) in the past" % who)
    if len(homes) > 1:
        bad.append("more than one home: %s" % ", ".join(map(str, homes)))
    return bad


def load_doc(path=None):
    """The validated fleet.json document (dict with 'client_keys' + 'machines'). Raises FleetError."""
    path = path or rd_common.FLEET_PATH
    doc = rd_common.load_json(path, None)
    if doc is None:
        raise FleetError("%s missing or not valid JSON" % path)
    bad = problems(doc)
    if bad:
        raise FleetError("%s invalid: %s" % (path, "; ".join(bad)))
    return doc


def wt_lanes(cfg=None):
    """How many rrun jobs one agent worktree may run at once (top-level "wt_lanes", 1..WT_LANES_MAX;
    rd_run's worktree lanes): WT_LANES_DEFAULT when absent or when fleet.json is missing / invalid. An
    older rd_fleet ignores unknown top-level keys, so adding it never breaks an older client."""
    try:
        v = load_doc((cfg or {}).get("fleet_path")).get("wt_lanes")
    except FleetError:
        return WT_LANES_DEFAULT
    return v if isinstance(v, int) and not isinstance(v, bool) and 1 <= v <= WT_LANES_MAX else WT_LANES_DEFAULT


def pool_node_major(cfg=None):
    """The node major the pool runs (top-level "pool_node_major", the one source of truth for rrun's
    pool result cache), else None (absent, or no valid fleet.json): the pool cache is then off. An
    older rd_fleet ignores unknown top-level keys, so adding it never breaks an older client."""
    try:
        return load_doc((cfg or {}).get("fleet_path")).get("pool_node_major")
    except FleetError:
        return None


def entry(m):
    """A machine with defaults filled in (new dict)."""
    return {**DEFAULT_ENTRY, **copy.deepcopy(m)}


def load(cfg=None):
    """FROZEN API: the fleet as list[dict], each with name, alias, ip, port, user, os, roles, speed,
    max_slots, heavy_slots, mem_gb, enabled, wsl (bool); optional keys (ts_key_expiry, shards,
    classes, max_cost_s, cold_ok, history_since, optional) only when set. `cfg` may carry 'fleet_path' (tests)."""
    return [entry(m) for m in load_doc((cfg or {}).get("fleet_path"))["machines"]]


def workers(fleet):
    """FROZEN API: enabled entries with 'worker' in roles."""
    return [m for m in fleet if "worker" in m["roles"] and m["enabled"]]


def home(fleet):
    """FROZEN API: the enabled 'home' entry, or None."""
    return next((m for m in fleet if "home" in m["roles"] and m["enabled"]), None)


def get(fleet, name):
    return next((m for m in fleet if m["name"] == name), None)


def _client_keys():
    try:
        return list(load_doc().get("client_keys", []))
    except FleetError:
        return []


CLIENT_KEYS = _client_keys()    # FROZEN API: fleet.json top-level "client_keys" (public keys only)


def upsert(doc, new):
    """A new fleet doc with machine `new` (dict with 'name') merged over the entry of that name or
    appended. A new 'home' role is taken away from any other machine."""
    out = copy.deepcopy(doc)
    i = next((i for i, m in enumerate(out["machines"]) if m["name"] == new["name"]), None)
    if i is None:
        out["machines"].append(entry(new))
    else:
        out["machines"][i] = {**out["machines"][i], **copy.deepcopy(new)}
    if "home" in new.get("roles", []):
        for m in out["machines"]:
            if m["name"] != new["name"] and "home" in m["roles"]:
                m["roles"] = [r for r in m["roles"] if r != "home"] or ["worker"]
    bad = problems(out)
    if bad:
        raise FleetError("; ".join(bad))
    return out


def save(doc, path=None):
    bad = problems(doc)
    if bad:
        raise FleetError("refusing to save invalid fleet: " + "; ".join(bad))
    rd_common.save_json(path or rd_common.FLEET_PATH, doc)


# ---------------------------------------------------------------------------- ssh blocks

def host_block(host, hostname, port, user, control="rdocker", key_alias=None):
    """One ssh Host block: dedicated key, Tailscale address, ControlMaster at ~/.ssh/<control>-%C
    (rdocker-* for the docker host, rr-* for rrun workers), host key pinned under `key_alias`."""
    return ("Host {host}\n  HostName {hostname}\n  Port {port}\n  HostKeyAlias {kalias}\n"
            "  User {user}\n  IdentityFile ~/.ssh/rdocker_ed25519\n"
            "  IdentitiesOnly yes\n  ControlMaster auto\n"
            "  ControlPath ~/.ssh/{control}-%C\n  ControlPersist 30m\n"
            "  ServerAliveInterval 15\n  ServerAliveCountMax 3\n"
            "  ConnectTimeout 5\n  StrictHostKeyChecking accept-new\n".format(
                host=host, hostname=hostname, port=port, user=user, control=control,
                kalias=key_alias or host))


def render_ssh_blocks(fleet, cfg=None):
    """The whole ~/.ssh/config.d/rdocker text. One Host <alias> per home/worker entry that has an ip
    (disabled ones too: a not-yet-enabled box stays debuggable by alias), then `Host macmini-docker`
    (cfg['host'], the docker host every shim uses) = the enabled home entry with ITS alias as
    HostKeyAlias. No enabled home -> macmini-docker keeps cfg's own host settings."""
    out = ["# rdocker: written whole by `rdocker sync-fleet` / `add-server` from fleet.json - do not edit "
           "(old copies: ~/.ssh/rdocker-backups/)\n"]
    for m in fleet:
        if m["alias"] and m["ip"] and any(r in m["roles"] for r in ("home", "worker")):
            out.append(host_block(m["alias"], m["ip"], m["port"], m["user"], control="rr"))
    h = home(fleet)
    if cfg and h and h["ip"]:
        out.append(host_block(cfg["host"], h["ip"], h["port"], h["user"], key_alias=h["alias"]))
    elif cfg:
        out.append(host_block(cfg["host"], cfg["ssh_hostname"], cfg.get("ssh_port") or 22, cfg["ssh_user"]))
    return "\n".join(out)


def ssh_blocks(fleet=None, cfg=None, path=None):
    """Own and rewrite ~/.ssh/config.d/rdocker (0600, atomic) from the fleet. A differing old file is
    first copied to ~/.ssh/rdocker-backups/. -> True when the file changed."""
    path = path or rd_common.FLEET_SSH_PATH
    cfg = cfg or rd_common.load_cfg()
    text = render_ssh_blocks(load() if fleet is None else fleet, cfg)
    old = None
    try:
        with open(path) as f:
            old = f.read()
    except OSError:
        pass
    if old == text:
        return False
    if old is not None:
        bdir = os.path.join(rd_common.HOME, ".ssh", "rdocker-backups")
        os.makedirs(bdir, mode=0o700, exist_ok=True)
        bpath = os.path.join(bdir, "rdocker.%d.%d" % (time.time_ns(), os.getpid()))
        fd = os.open(bpath, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)   # never overwrite an older backup
        with os.fdopen(fd, "w") as f:
            f.write(old)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp.%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)
    return True


def sync(cfg=None, pull=False):
    """`rdocker sync-fleet`: optionally `git pull --ff-only` the dotfiles, validate fleet.json, rewrite
    the ssh blocks. -> exit code."""
    if pull:
        rc, _, err = rd_common.run(["git", "-C", rd_common.HERE, "pull", "--ff-only"], timeout=60)
        if rc:
            rd_common.say("dotfiles pull failed: " + err.strip()[-200:])
            return 1
    try:
        fleet = load()
    except FleetError as e:
        rd_common.say(str(e))
        return 1
    changed = ssh_blocks(fleet, cfg)
    h = home(fleet)
    print("fleet: %d machines; home=%s; workers=%s; ssh blocks %s" % (
        len(fleet), h["name"] if h else "none", ",".join(m["name"] for m in workers(fleet)) or "none",
        "updated" if changed else "unchanged"))
    return 0


# ---------------------------------------------------------------------------- add-server

def interactive(cmd):
    """Run with the terminal attached (sudo password prompt). Patched in tests."""
    return subprocess.call(cmd)


def reporter_secret_cmd(name, url="", role=""):
    """Remote command (stdin-free) that writes ~/.config/rdocker/reporter.json (0600) in the reporter's
    format {name, url, key, role, rrRoot}: a random 32-byte key is minted once and kept on re-runs (an
    older {machine, secret} file is converted, keeping its secret). Never prints the key."""
    code = ("import json,os,secrets; d=os.path.expanduser('~/.config/rdocker'); os.makedirs(d,mode=0o700,exist_ok=True); "
            "p=d+'/reporter.json'; old={}\n"
            "try: old=json.load(open(p))\nexcept Exception: pass\n"
            "k=old.get('key') or old.get('secret') or secrets.token_hex(32); "
            "c={'name':%r,'url':(%r or old.get('url','')),'key':k,'role':(%r or old.get('role','worker')),'rrRoot':'~/rr'}; "
            "t=p+'.tmp'; fd=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); os.write(fd,json.dumps(c,indent=1).encode()); "
            "os.close(fd); os.replace(t,p)" % (name, url, role))
    return "/usr/bin/python3 -c " + shlex.quote(code)


def ingest_url(doc):
    """fleet.json `dashboard` origin -> the reporter's wss://.../ingest URL ('' when unset)."""
    o = (doc.get("dashboard") or "").strip().rstrip("/") if isinstance(doc, dict) else ""
    return (re.sub(r"^http", "ws", o) + "/ingest") if o.startswith("http") else ""


def secret_put_hint(name, alias):
    """The owner's command: pipes the key from the machine into wrangler (never shown, never stored)."""
    var = "MACHINE_KEY_" + re.sub(r"[^A-Za-z0-9]", "_", name).upper()
    read = "import json,os;print(json.load(open(os.path.expanduser('~/.config/rdocker/reporter.json')))['key'],end='')"
    return "ssh %s %s | wrangler secret put %s" % (alias, shlex.quote("/usr/bin/python3 -c " + shlex.quote(read)), var)


def stage_dir(keys, parent):
    """The directory copied to the server: server/* + client_keys (+ reporter/ when it exists)."""
    d = os.path.join(parent, "rdocker-provision")
    shutil.copytree(SERVER_DIR, d)
    if os.path.isdir(REPORTER_DIR):
        shutil.copytree(REPORTER_DIR, os.path.join(d, "reporter"))
    with open(os.path.join(d, "client_keys"), "w") as f:
        f.write("\n".join(keys) + "\n")
    return d


def own_pubkey():
    try:
        with open(os.path.join(rd_common.HOME, ".ssh", "rdocker_ed25519.pub")) as f:
            line = f.read().strip()
        return line if KEY_RE.match(line) else None
    except OSError:
        return None


def repoint_home(cfg, m, old_home):
    """This machine becomes the docker host: config.json + stale known_hosts entries of the old one."""
    for alias in {cfg["host"], (old_home or {}).get("alias")} - {None, "", m["alias"]}:
        rd_common.run(["ssh-keygen", "-R", alias], timeout=10)
    rd_common.update_cfg(lambda c: {**c, "ssh_hostname": m["ip"], "ssh_port": m["port"], "ssh_user": m["user"],
                                    "server_os": "linux", "host_ip": m["ip"],
                                    "remote_socket": "/var/run/docker.sock"})
    try:
        os.unlink(rd_common.HEALTH_PATH)
    except OSError:
        pass


def parse_verify(out):
    """rd-verify output -> [(PASS|FAIL|SKIP, name, detail)]; unparseable lines are ignored."""
    rows = []
    for ln in out.splitlines():
        parts = ln.strip().split(None, 2)
        if len(parts) >= 2 and parts[0] in ("PASS", "FAIL", "SKIP"):
            rows.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
    return rows


def verify_table(rows):
    w = max([len(r[1]) for r in rows] + [5])
    return "\n".join("%-4s  %-*s  %s" % (st, w, name, detail) for st, name, detail in rows)


def parse_key_expiry(text):
    """`tailscale status --json` -> 'YYYY-MM-DD' of Self.KeyExpiry, 'none' when expiry is disabled, None unknown."""
    try:
        exp = (json.loads(text).get("Self") or {}).get("KeyExpiry")
    except (ValueError, AttributeError):
        return None
    if exp is None or str(exp).startswith("0001"):
        return "none"
    return str(exp)[:10] if re.match(r"\d{4}-\d\d-\d\d", str(exp)) else None


def commit_push(name, push):
    top_rc, top, _ = rd_common.run(["git", "-C", rd_common.HERE, "rev-parse", "--show-toplevel"], timeout=10)
    if top_rc:
        return "dotfiles is not a git repo here: fleet.json left uncommitted"
    top = top.strip()
    rel = os.path.relpath(rd_common.FLEET_PATH, top)
    steps = [["add", rel], ["commit", "-m", "rdocker fleet: add/update %s" % name, "--", rel]] + ([["push"]] if push else [])
    for cmd in steps:
        rc, _, err = rd_common.run(["git", "-C", top] + cmd, timeout=90)
        if rc:
            return "git %s failed: %s" % (cmd[0], err.strip()[-160:])
    return "committed" + (" and pushed" if push else "")


def bench_cmd(m):
    """-> (ssh argv, stdin text or None) running the worker benchmark (rd-tune bench: writes ~/rr/speed,
    prints the speed). A Linux worker has rd-tune installed; a Mac worker gets the same script piped in
    (`bash -s bench`: nothing installed there)."""
    base = ["ssh", "-o", "BatchMode=yes", m["alias"]]
    if m.get("os") == "mac":
        with open(os.path.join(SERVER_DIR, "rd-tune.sh")) as f:
            return base + ["/bin/bash -s bench"], f.read()
    return base + ["/usr/local/bin/rd-tune bench"], None


def parse_speed(out):
    try:
        return float(out.strip().splitlines()[-1]) if out.strip() else None
    except ValueError:
        return None


def bench_worker(cfg, name):
    """`rdocker bench-worker <name>`: run the benchmark on one worker (linux or mac) over ssh. It stores
    ~/rr/speed there, which the scheduler's probe prefers over fleet.json's speed - so no fleet edit is
    needed; put the printed value in fleet.json by hand to make it the default. -> exit code."""
    try:
        m = get(load(cfg), name)
    except FleetError as e:
        rd_common.say(str(e))
        return 2
    if not m or not m["alias"] or not any(r in m["roles"] for r in ("home", "worker")):
        rd_common.say("no home/worker named %r in fleet.json" % name)
        return 2
    cmd, stdin = bench_cmd(m)
    rc, out, err = rd_common.run(cmd, timeout=300, input_=stdin)
    speed = parse_speed(out) if rc == 0 else None
    if speed is None:
        rd_common.say("benchmark on %s failed (exit %d): %s" % (name, rc, (err.strip().splitlines() or ["no output"])[-1][:200]))
        return 1
    print("%s: speed %.2f (stored in ~/rr/speed there; fleet.json says %s)" % (name, speed, m["speed"]))
    return 0


def add_server(cfg, ns):
    """`rdocker add-server <name> <ip>`: provision a Linux box over ssh and add it to the fleet.
    ns: name, ip, role, user, admin_user, port, alias, speed, max_slots, heavy_slots, no_push, dry_run."""
    dry = ns.dry_run
    roles = [r for r in ns.role.split(",") if r]
    try:
        doc = load_doc()
        old_home = home(load())
        cur = get([entry(m) for m in doc["machines"]], ns.name) or {}
        new = {"name": ns.name, "ip": ns.ip, "roles": roles, "user": ns.user, "port": ns.port, "os": "linux",
               "alias": ns.alias or cur.get("alias") or "rd-" + ns.name, "enabled": False,
               "max_slots": ns.max_slots or cur.get("max_slots", DEFAULT_ENTRY["max_slots"]),
               "heavy_slots": ns.heavy_slots if ns.heavy_slots is not None else cur.get("heavy_slots", DEFAULT_ENTRY["heavy_slots"])}
        if ns.speed:
            new["speed"] = ns.speed
        pending = upsert(doc, new)
    except FleetError as e:
        rd_common.say(str(e))
        return 2
    m = get([entry(x) for x in pending["machines"]], ns.name)
    keys = list(dict.fromkeys(doc.get("client_keys", []) + ([own_pubkey()] if own_pubkey() else [])))
    target = "%s@%s" % (ns.admin_user or ns.user, ns.ip)
    ssh_opts = ["-o", "StrictHostKeyChecking=accept-new", "-p", str(ns.port)]
    remote = "/tmp/rdocker-provision-" + ns.name

    def sh(cmd, label, tty=False, input_=None, timeout=300):
        print("%s: %s" % (label, " ".join(shlex.quote(c) for c in cmd)))
        if dry:
            return 0, "", ""
        if tty:
            return interactive(cmd), "", ""
        return rd_common.run(cmd, timeout=timeout, input_=input_)

    for alias in {m["alias"]} if not dry else ():       # a re-provisioned box has new host keys
        rd_common.run(["ssh-keygen", "-R", alias], timeout=10)
    tmp = tempfile.mkdtemp(prefix="rdk-prov-", dir=rd_common.STATE_DIR if os.path.isdir(rd_common.STATE_DIR) else None)
    try:
        src = stage_dir(keys, tmp)
        if sh(["scp", "-r", "-P", str(ns.port), "-o", "StrictHostKeyChecking=accept-new", src, "%s:%s" % (target, remote)],
              "copy provision files")[0]:
            rd_common.say("could not copy to %s (is sshd up on port %d and the key/password right?)" % (target, ns.port))
            return 1
    finally:
        shutil.rmtree(tmp, True)
    args = ["--ts-ip", m["ip"], "--user", m["user"], "--port", str(m["port"]), "--keys", remote + "/client_keys",
            "--max-slots", str(m["max_slots"]), "--heavy-slots", str(m["heavy_slots"]),
            "--admin-user", ns.admin_user or ns.user] + (
        ["--home"] if "home" in roles else [])
    if sh(["ssh", "-t"] + ssh_opts + [target, "sudo", "bash", remote + "/provision-linux.sh"] + args,
          "provision (asks for the sudo password once)", tty=True)[0]:
        rd_common.say("provisioning failed (see output above); fleet.json unchanged")
        return 1
    sh(["ssh"] + ssh_opts + [target, "rm", "-rf", remote], "clean up")
    # from here on the machine is reachable by its alias: make that true before verifying
    if not dry:      # interim: reachable by alias but not enabled and NOT yet home (a failed verify changes no routing)
        save(upsert(doc, {**new, "roles": [r for r in roles if r != "home"] or ["worker"]}))
        ssh_blocks(load(), cfg)
    ok = sh(["ssh", "-o", "BatchMode=yes", m["alias"], "true"], "verify ssh", timeout=30)[0] == 0
    if not ok:
        rd_common.say("%s provisioned but ssh as %s@%s:%d failed - left DISABLED in fleet.json; fix and re-run"
                      % (ns.name, m["user"], m["ip"], m["port"]))
        return 1
    rc, out, _ = sh(bench_cmd(m)[0], "benchmark", timeout=180)
    speed = parse_speed(out)
    final = {"enabled": True, "roles": roles, **({"speed": speed} if speed and not ns.speed else {})}
    try:
        url = ingest_url(load_doc((cfg or {}).get("fleet_path")))
    except FleetError:
        url = ""
    sh(["ssh", "-o", "BatchMode=yes", m["alias"], reporter_secret_cmd(ns.name, url, ",".join(roles))], "reporter config")
    sh(["ssh", "-o", "BatchMode=yes", m["alias"],
        "export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user daemon-reload 2>/dev/null; "
        "systemctl --user restart rd-reporter 2>/dev/null; true"], "start reporter")
    expiry = parse_key_expiry(sh(["ssh", "-o", "BatchMode=yes", m["alias"], "tailscale status --json"], "tailscale key expiry")[1])
    if expiry:
        final["ts_key_expiry"] = expiry
    _, vout, _ = sh(["ssh", "-o", "BatchMode=yes", m["alias"], "/usr/local/bin/rd-verify" + (" --home" if "home" in roles else "")],
                    "verify self-recovery")
    rows = parse_verify(vout)
    if expiry and expiry != "none":
        rows.append(("FAIL", "tailscale-key-expiry", "key expires %s: disable expiry in the Tailscale admin console" % expiry))
    if not dry:
        save(upsert(load_doc(), {"name": ns.name, **final}))
        fleet = load()
        if "home" in roles:
            repoint_home(cfg, get(fleet, ns.name), old_home)
        ssh_blocks(fleet, rd_common.load_cfg())
        print("git: " + commit_push(ns.name, not ns.no_push))
    print("added %s (%s) roles=%s speed=%s" % (ns.name, ns.ip, ",".join(roles), speed or "unmeasured"))
    print("owner, once: " + secret_put_hint(ns.name, m["alias"]))
    if dry:
        return 0
    print("self-recovery check:\n" + (verify_table(rows) if rows else "FAIL  rd-verify  produced no output (is /usr/local/bin/rd-verify installed?)"))
    failed = [r for r in rows if r[0] == "FAIL"] or ([] if rows else [("FAIL",)])
    if failed:
        rd_common.say("%d self-recovery check(s) FAILED: the machine is enabled and works, but will NOT come back "
                      "unattended until fixed (re-run add-server, it is idempotent; `ssh %s rd-verify` re-checks)"
                      % (len(failed), m["alias"]))
    return 1 if failed else 0
