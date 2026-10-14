"""rdocker rd_janitor: mini janitor (idle/exited containers, volumes, images, disk), laptop janitor
(shim-fallback containers only), engine kick, apply_when_idle.

Split out of rdocker.py; see rdocker.py for the overview.
"""
import json
import os
import re
import shlex
import socket
import time
from contextlib import contextmanager

import rd_common
import rd_tunnel



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


def has_connections(cfg, ctx, cid):
    """True if the container has an ESTABLISHED TCP connection; None if it can't be read. ctx is the
    engine that holds it (the laptop pass must never exec into the mini)."""
    rc, out, _ = rd_common.dk(ctx, "exec", cid, "cat", "/proc/net/tcp", "/proc/net/tcp6",
                    timeout=15)
    if rc != 0 and not out:
        return None
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) > 3 and f[3] == "01":
            return True
    return False


def vm_now(ctx, what="mini"):
    """The engine's clock (container timestamps are VM time); laptop time if unreadable."""
    rc, out, err = rd_common.dk(ctx, "info", "--format", "{{.SystemTime}}", timeout=20)
    t = parse_ts(out.strip()) if rc == 0 else 0.0
    if not t:
        rd_common.log("janitor: cannot read " + what + " SystemTime (%s); using laptop clock"
            % (out.strip() or err.strip())[:100])
        return time.time()
    return t


def inspect_all(ctx, ids):
    """-> (infos, complete). `docker container inspect a b` exits 1 when one vanished but still
    prints JSON for the rest: use it. infos=None when stdout is not a JSON list (phase must skip)."""
    if not ids:
        return [], True
    rc, out, _ = rd_common.dk(ctx, "container", "inspect", *ids, timeout=30)
    try:
        infos = json.loads(out)
    except ValueError:
        return None, False
    if not isinstance(infos, list) or not all(isinstance(c, dict) and c.get("Id") for c in infos):
        return None, False
    return infos, rc == 0


def netio_map(ctx):
    """{short id: "rx / tx"} from ONE `docker stats` call (eth traffic only); None if it failed."""
    rc, out, _ = rd_common.dk(ctx, "stats", "--no-stream", "--format", "{{.ID}}\t{{.NetIO}}", timeout=60)
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


# `image rm` refusals that mean "not collectable now", not a janitor fault.
IMAGE_RM_SKIP = ("referenced in multiple repositories", "dependent child images",
                 "image is being used", "is using its referenced image", "No such image")


class MiniEngineDown(Exception):
    """The janitor could not list the mini's containers (engine down or mini unreachable)."""


class JanitorRun:
    """One janitor pass: the act log, failure bookkeeping and the keep-checked destructive calls."""

    def __init__(self, cfg, dry, lock=None, ctx=None, tag="janitor"):
        self.cfg, self.ctx, self.dry, self.lock = cfg, ctx or cfg["remote_context"], dry, lock
        self.tag = tag                      # daemon.log prefix ("laptop janitor" for the laptop pass)
        self.acts, self.last_error = [], None
        self.stopped = {}                   # idle stops this pass -> state "stopped_by_janitor"

    def act(self, desc, *cmd, record=True):
        """-> (ok, stderr). A failure is logged and (record=True) kept as janitor.json last_error."""
        self.acts.append(desc)
        if self.dry:
            return True, ""
        if self.lock is not None:
            self.lock.heartbeat()          # raises MiniLockLost: stop before touching anything
        rc, _, err = rd_common.dk(self.ctx, *cmd, timeout=120)
        rd_common.log("%s: %s%s" % (self.tag, desc, "" if rc == 0 else " FAILED: " + err.strip()[:150]))
        if rc != 0 and record:
            self.last_error = {"ts": time.time(), "action": desc, "err": err.strip()[:300]}
        return rc == 0, err

    def fresh(self, kind, ident):
        """Fresh inspect right before a destructive call: the record, or None if gone/kept/unreadable."""
        rc, out, _ = rd_common.dk(self.ctx, kind, "inspect", ident, timeout=20)
        try:
            data = json.loads(out) if rc == 0 else None
        except ValueError:
            data = None
        info = data[0] if isinstance(data, list) and data and isinstance(data[0], dict) else None
        if info is None or has_keep(info):
            rd_common.log("%s: skip %s %s (%s)" % (self.tag, kind, ident[:24], "kept" if info else "not found"))
            return None
        if kind == "container":
            # A container whose data volume is keep-labelled is kept too (compose-made DBs carry the
            # label on the volume, not the container). Unreadable volume -> kept (fail safe).
            for v in volumes_of(info):
                rc, out, _ = rd_common.dk(self.ctx, "volume", "inspect", v, timeout=20)
                try:
                    vd = json.loads(out) if rc == 0 else None
                except ValueError:
                    vd = None
                vinfo = vd[0] if isinstance(vd, list) and vd and isinstance(vd[0], dict) else None
                if vinfo is None or has_keep(vinfo):
                    rd_common.log("%s: skip container %s (volume %s %s)"
                                  % (self.tag, ident[:24], v[:24], "kept" if vinfo else "unreadable"))
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

    def stop_container(self, cid, name, why, idle_h=None):
        if not self.destructive_ok("container", cid):
            return False
        ok = self.act("stop %s (%s)" % (name, why), "stop", cid)[0]
        if ok and not self.dry and idle_h is not None:
            self.stopped[cid] = {"name": name, "ts": time.time(), "idle_h": idle_h}
        return ok

    def rm_image(self, iid, why):
        """Remove an unused image without -f: one `image rm <repo:tag>` per tag (a bare id is refused
        for an image tagged in several repositories), then the id if it is still there (untagged).
        Docker's own refusals - still used by a container, has child images, multi-repo - are skips,
        not janitor errors: docker itself keeps images any container (even stopped) uses."""
        info = self.fresh("image", iid)
        if info is None:
            return False
        short = iid.split(":")[-1][:12]
        desc = "rm image %s (%s)" % (short, why)
        if self.dry:
            return self.act(desc)[0]
        tags = [t for t in info.get("RepoTags") or [] if t and "<none>" not in t]
        for ref in tags + [iid]:
            if ref == iid and tags and not self.image_exists(iid):
                return True                 # removing the last tag removed the image
            ok, err = self.act(desc + ("" if ref == iid else " tag " + ref),
                               "image", "rm", ref, record=False)
            if ok:
                continue
            if any(t in err for t in IMAGE_RM_SKIP):
                rd_common.log("janitor: skip image %s (%s)" % (short, err.strip()[:120]))
                return False
            self.last_error = {"ts": time.time(), "action": desc, "err": err.strip()[:300]}
            return False
        return True

    def image_exists(self, iid):
        return rd_common.dk(self.ctx, "image", "inspect", iid, timeout=20)[0] == 0

    def rm_volume(self, name, why):
        if not self.destructive_ok("volume", name):
            return False
        return self.act("rm volume %s (%s)" % (name, why), "volume", "rm", name)[0]


def running_ids(infos):
    """Ids this pass saw running (inspected before any stop): their janitor-stop records are stale."""
    return {c["Id"] for c in infos if (c.get("State") or {}).get("Running")}


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
        if ttl:          # a declared lifetime replaces the idle rule: never idle-stopped before it
            idle.pop(cid, None)
            continue
        netio = stats.get(cid[:12]) if stats is not None else None
        conn = has_connections(cfg, J.ctx, cid)
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
            if J.stop_container(cid, name, "no traffic for %sh" % cfg["idle_stop_hours"],
                                idle_h=cfg["idle_stop_hours"]):
                idle.pop(cid, None)
    if complete:
        idle = {k: v for k, v in idle.items() if k in seen}
    return idle, stopped


def janitor_volumes(J, infos, vunused, now, only):
    """Named volumes have no last-used time: track "unused since" ourselves (30-day rule)."""
    rc, out, _ = rd_common.dk(J.ctx, "volume", "ls", "-q", timeout=20)
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
    rc, out, _ = rd_common.dk(J.ctx, "image", "ls", "-q", "--no-trunc", timeout=30)
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
    rc, out, _ = rd_common.run(["ssh", "-o", "BatchMode=yes", cfg["host"], script], timeout=180)
    for t in re.findall(r"TRUNC (\S+)", out):
        rd_common.log("janitor: truncated %s to 5MB (cap %dMB)" % (t, cfg["host_log_max_mb"]))
    m = re.search(r"VMDISK (\d+)%", out)
    f = re.search(r"HOSTFREE (\d+)", out)
    return (int(m.group(1)) if m else None), (int(f.group(1)) if f else None)


def disk_high(cfg, pct, free):
    return (pct is not None and pct >= cfg["disk_high_pct"]) or (
        free is not None and free < cfg["host_min_free_gb"])


def janitor(cfg, dry=False, only=None, force_critical=False, lock_wait=None):
    """Reap what agents left behind on the mini. Every destructive call is preceded by a fresh
    keep-check (JanitorRun.fresh); nothing labelled rdocker.keep is removed, and no unfiltered
    prune is ever issued. A real (non-dry) pass holds the mini lock (MiniLock) throughout, so two
    laptops' janitors - or a janitor and a colima restart - never overlap; held elsewhere -> skip.

    `only` (tests/e2e): restrict container/volume rules to names with this prefix; skip global
    prunes and image GC. `force_critical`: apply the disk-critical container path regardless of
    disk usage (to the `only` scope when given).

    lock_wait=None (daemon janitor-run): lock held elsewhere or engine down -> skip this pass. A
    number (manual `rdocker clean`): wait up to that many seconds for the lock, then raise
    MiniLockBusy; an engine that does not answer raises MiniEngineDown (dry runs raise it too)."""
    if dry:
        return janitor_pass(JanitorRun(cfg, True), only, force_critical)
    try:
        with mini_lock(cfg, "janitor", wait=lock_wait or 0) as lk:
            J = JanitorRun(cfg, False, lk)
            try:
                return janitor_pass(J, only, force_critical)
            except MiniLockLost as e:
                rd_common.log("janitor: stopped - mini lock lost (%s)" % e)
                rd_common.attention_set("janitor-error",
                                        "mini janitor pass stopped: mini lock lost (%s)" % e)
                return J.acts + ["stopped: mini lock lost (%s)" % e]
    except (MiniLockBusy, MiniEngineDown) as e:
        if lock_wait is not None:
            raise
        rd_common.log("janitor: skipped - %s" % e)
        return ["skipped: %s" % e]


def janitor_pass(J, only, force_critical):
    cfg, dry, ctx = J.cfg, J.dry, J.ctx
    rc, out, err = rd_common.dk(ctx, "ps", "-aq", "--no-trunc", timeout=20)
    if rc != 0:
        raise MiniEngineDown("mini docker engine not answering (%s)"
                             % ((err or out).strip()[-160:] or "rc=%s" % rc))
    ids = out.split()
    now = vm_now(ctx)
    state = rd_common.load_json(rd_common.JANITOR_PATH, {})
    state = state if isinstance(state, dict) else {}
    updates = {"last_run": now}
    unused = None
    stopped = []
    infos, complete = inspect_all(ctx, ids)
    if infos is None:
        rd_common.log("janitor: container inspect unreadable - container phase skipped, clocks kept")
        J.acts.append("container phase skipped (inspect unreadable)")
    else:
        updates["idle"], stopped = janitor_containers(J, infos, complete, state.get("idle") or {},
                                                      now, only)
        if not dry:
            rd_common.drop_janitor_stops_ids(rd_common.JANITOR_PATH, running_ids(infos))
            rd_common.record_janitor_stops(rd_common.JANITOR_PATH, J.stopped)
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

    def save(extra, final=False):
        """Persist. The final save of a full (not --only) pass records the pass's outcome: an
        error is kept as last_error + an attention item; a clean pass clears both."""
        if dry:
            return
        drop = {"idle_since"}
        if J.last_error:
            extra = {**extra, "last_error": J.last_error}
        elif final and not only:
            drop.add("last_error")
        rd_common.update_state(rd_common.JANITOR_PATH, lambda st0: {
            **{k: v for k, v in st0.items() if k not in drop}, **extra})
        if J.last_error:
            rd_common.attention_set("janitor-error", "mini janitor: %s failed: %s" % (
                J.last_error.get("action", "?"), str(J.last_error.get("err", ""))[:120]))
        elif final and not only:
            rd_common.attention_clear("janitor-error")

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
            rd_common.log("janitor: WARNING disk pressure (VM %s%%, mini free %sGB) - aggressive prune"
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
    save(extra, final=True)
    return J.acts




# ---------------------------------------------------------------------------- janitor (laptop)
#
# Docker Desktop has no janitor of its own, so throwaway containers the shim put there (fallback while
# the mini was out or slow, RDOCKER_MODE=local, bind mounts, --network host) piled up and ate the
# laptop RAM rdocker exists to save. Scope: ONLY containers carrying rd_common.PLACED_LABEL, which the
# shim stamps on every throwaway-shaped run/create it sends to the laptop (compose is never stamped).
# Rules = the mini's container rules (janitor_containers): idle_stop_hours of unchanged NetIO and no
# ESTABLISHED TCP connection -> stop; stopped > exited_rm_hours -> rm -v (anonymous volumes only);
# rdocker.ttl replaces the idle rule. Immediately before every stop/rm (LaptopJanitorRun.fresh): a
# keep label on the container or any of its volumes, a manual pin (pins.containers) or a manually
# pinned compose project (by its compose label), read from config.json at that moment -> skip.
# Container-only: no volume/image/disk/prune work and no mini lock. Own state file
# (laptop_janitor.json) and attention key; daemon.log lines start "laptop janitor:".

LAPTOP_ATTENTION = "laptop-janitor-error"


def manual_pin_reason(cfg, info):
    """Why a container must not be touched because the user pinned it (or its compose project)."""
    pins = cfg.get("pins") or {}
    name = (info.get("Name") or "").lstrip("/")
    if name and name in (pins.get("containers") or []):
        return "pinned to the laptop"
    proj = ((info.get("Config") or {}).get("Labels") or {}).get("com.docker.compose.project")
    if proj and proj in (pins.get("compose_projects") or []):
        return "compose project %s pinned to the laptop" % proj
    return None


class LaptopJanitorRun(JanitorRun):
    """JanitorRun on the laptop engine; its fresh() also re-reads the manual pins."""

    def __init__(self, cfg):
        super().__init__(cfg, False, ctx=cfg["local_context"], tag="laptop janitor")

    def fresh(self, kind, ident):
        info = super().fresh(kind, ident)
        if info is None or kind != "container":
            return info
        why = manual_pin_reason(rd_common.load_cfg(), info)     # a pin added mid-pass counts
        if why:
            rd_common.log("laptop janitor: skip container %s (%s)" % (ident[:24], why))
            return None
        return info


def laptop_janitor(cfg):
    """One laptop pass (daemon job `laptop-janitor-run`). Does nothing while Docker Desktop is down.
    -> list of actions taken."""
    if not rd_tunnel.local_engine_up(cfg):
        return []
    J = LaptopJanitorRun(cfg)
    rc, out, err = rd_common.dk(J.ctx, "ps", "-aq", "--no-trunc", "--filter",
                                "label=" + rd_common.PLACED_LABEL, timeout=20)
    if rc != 0:
        rd_common.log("laptop janitor: skipped - laptop engine not answering (%s)"
                      % ((err or out).strip()[-160:] or "rc=%s" % rc))
        return []
    state = rd_common.load_json(rd_common.LAPTOP_JANITOR_PATH, {})
    state = state if isinstance(state, dict) else {}
    infos, complete = inspect_all(J.ctx, out.split())
    if infos is None:
        rd_common.log("laptop janitor: container inspect unreadable - skipped, clocks kept")
        return []
    now = vm_now(J.ctx, "laptop engine")
    idle, _ = janitor_containers(J, infos, complete, state.get("idle") or {}, now, None)
    rd_common.update_state(rd_common.LAPTOP_JANITOR_PATH, lambda st0: {
        **{k: v for k, v in st0.items() if k != "last_error"}, "idle": idle, "last_run": now,
        **({"last_error": J.last_error} if J.last_error else {})})
    rd_common.drop_janitor_stops_ids(rd_common.LAPTOP_JANITOR_PATH, running_ids(infos))
    rd_common.record_janitor_stops(rd_common.LAPTOP_JANITOR_PATH, J.stopped)
    if J.last_error:
        rd_common.attention_set(LAPTOP_ATTENTION, "laptop janitor: %s failed: %s" % (
            J.last_error.get("action", "?"), str(J.last_error.get("err", ""))[:120]))
    else:
        rd_common.attention_clear(LAPTOP_ATTENTION)
    return J.acts


# ---------------------------------------------------------------------------- mini lock

# Every remote step below is a POSIX sh script fed to `ssh <host> /bin/sh -s` (mini_sh, the one seam
# tests replace): no python/yq on the mini, no zsh quoting. Scripts answer with a marker line
# (`RDLOCK ...`, `RDKICK ...`, `RDRESTART ...`) so a stray login banner never reads as success.
BREW_PATH = "/opt/homebrew/bin:/opt/homebrew/sbin"   # mini Homebrew (colima, docker)
MINI_LOCK_DIR = "$HOME/.rdocker/janitor.lock"        # mkdir-atomic; holds `owner` = "<id> <epoch>"
MINI_LOCK_STALE = 600       # a lock whose heartbeat is older than this (mini clock) may be stolen
LOCK_POLL = 5               # seconds between acquire attempts while waiting for a held lock
CLEAN_LOCK_WAIT = 90        # manual `rdocker clean` waits this long for the lock, then fails
HEARTBEAT_EVERY = 60        # refresh the heartbeat at most this often between destructive steps
RESTART_MIN_GAP = 1800      # at most one colima restart per 30 min (wall clock, janitor.json)
COLIMA_PROFILE = "$HOME/.colima/default/colima.yaml"
# A VM-up restart kills every container on the mini (other agents' live databases), so it needs
# all of: ENGINE probe failures continuous for ENGINE_RESTART_AFTER_S (daemon, monotonic), then -
# on the mini, under the mini lock - `docker info` failing within ENGINE_CHECK_TIMEOUT (a slow
# tunnel/laptop is not a dead engine) and `docker ps -q` empty or itself failing/hanging.
ENGINE_RESTART_AFTER_S = 600
ENGINE_CHECK_TIMEOUT = 30


class MiniLockBusy(Exception):
    """The mini lock is held by someone else (fresh heartbeat) or the mini did not answer."""


class MiniLockLost(Exception):
    """Our mini lock was stolen (we went stale) or the heartbeat could not be written."""


def mini_sh(cfg, script, timeout=60):
    """Run a POSIX sh `script` on the mini -> (rc, stdout, stderr)."""
    return rd_common.run(["ssh", "-o", "BatchMode=yes", cfg["host"], "/bin/sh", "-s"],
                         timeout=timeout, input_=script)


def marker(out, tag):
    """First `<tag> word...` line of a remote script's output -> [word, ...] ([] if none)."""
    for line in (out or "").splitlines():
        parts = line.split()
        if parts and parts[0] == tag:
            return parts[1:] or [""]
    return []


_LOCK_PRELUDE = r"""L=%(dir)s
ME=%(me)s
NOW=$(date +%%s)
owner() {
  O=""; T=""
  [ -f "$L/owner" ] && read -r O T < "$L/owner"
  case "$T" in ''|*[!0-9]*)   # owner not written yet (or garbage): age the dir itself
    T=$(stat -c %%Y "$L" 2>/dev/null || stat -f %%m "$L" 2>/dev/null || echo 0) ;;
  esac
}
claim() { printf '%%s %%s\n' "$ME" "$NOW" > "$L/owner.$$" && mv -f "$L/owner.$$" "$L/owner"; }
"""

_LOCK_OPS = {
    "acquire": r"""mkdir -p "$(dirname "$L")" || { echo "RDLOCK error mkdir"; exit 1; }
if mkdir "$L" 2>/dev/null; then claim && echo "RDLOCK ok"; exit 0; fi
owner
if [ "$O" = "$ME" ]; then claim && echo "RDLOCK ok"; exit 0; fi
AGE=$((NOW - T))
if [ "$AGE" -ge -60 ] && [ "$AGE" -le %(stale)d ]; then echo "RDLOCK held $O ${AGE}s"; exit 0; fi
rm -rf "$L"
if mkdir "$L" 2>/dev/null; then
  claim; owner
  if [ "$O" = "$ME" ]; then echo "RDLOCK ok stole-stale ${AGE}s"; exit 0; fi
fi
echo "RDLOCK held race"
""",
    "heartbeat": r"""owner
if [ -d "$L" ] && [ "$O" = "$ME" ]; then claim && echo "RDLOCK ok"; else echo "RDLOCK lost ${O:-none}"; fi
""",
    "release": r"""owner
if [ "$O" = "$ME" ]; then rm -rf "$L"; echo "RDLOCK released"; else echo "RDLOCK notours ${O:-none}"; fi
""",
}


def lock_script(op, me):
    return (_LOCK_PRELUDE % {"dir": MINI_LOCK_DIR.replace("$HOME", '"$HOME"'), "me": shlex.quote(me)}
            + _LOCK_OPS[op] % {"stale": MINI_LOCK_STALE})


class MiniLock:
    """Mini-side mutex for destructive mini work (janitor pass, colima restart), shared by every
    laptop: a `mkdir`-created dir whose `owner` file carries "<host>:<pid> <mini epoch>". The
    heartbeat rewrites the epoch before destructive steps; a lock is stale (stealable) only when its
    epoch is more than MINI_LOCK_STALE old. Release removes it only while the owner is still us."""

    def __init__(self, cfg, purpose, runner=None, clock=None, sleep=None):
        host = re.sub(r"[^A-Za-z0-9._-]", "_", socket.gethostname().split(".")[0]) or "laptop"
        self.me = "%s:%d" % (host, os.getpid())
        self.purpose = purpose
        self.runner = runner or (lambda script: mini_sh(cfg, script, timeout=30))
        self.clock = clock or time.monotonic
        self.sleep = sleep or time.sleep
        self.held, self.last_beat = False, None

    def _op(self, op):
        rc, out, err = self.runner(lock_script(op, self.me))
        return marker(out, "RDLOCK"), (err or out or "").strip()[-200:]

    def acquire(self, wait=0):
        """Take the lock. Held elsewhere -> poll every LOCK_POLL up to `wait` seconds (0 = one try);
        still held, or the mini does not answer (never retried) -> MiniLockBusy."""
        deadline = self.clock() + wait
        while True:
            m, err = self._op("acquire")
            if m[:1] != ["held"] or self.clock() + LOCK_POLL > deadline:
                break
            self.sleep(LOCK_POLL)
        if m[:1] != ["ok"]:
            raise MiniLockBusy("mini lock held by %s" % " ".join(m[1:]) if m[:1] == ["held"]
                               else "mini unreachable (%s)" % (err or "no answer"))
        self.held, self.last_beat = True, self.clock()
        if len(m) > 1:
            rd_common.log("mini lock: took over a stale lock (%s) for %s" % (m[-1], self.purpose))
        return self

    def heartbeat(self, force=False):
        if not self.held:
            raise MiniLockLost("not held")
        if not force and self.clock() - self.last_beat < HEARTBEAT_EVERY:
            return
        m, err = self._op("heartbeat")
        if m[:1] != ["ok"]:
            self.held = False
            raise MiniLockLost(" ".join(m) or err or "no answer")
        self.last_beat = self.clock()

    def release(self):
        if self.held:
            self.held = False
            self._op("release")


@contextmanager
def mini_lock(cfg, purpose, runner=None, wait=0):
    lk = MiniLock(cfg, purpose, runner).acquire(wait)
    try:
        yield lk
    finally:
        lk.release()


# ---------------------------------------------------------------------------- engine recovery

# Colima on the mini runs as the brew-services LaunchAgent sh.brew.colima (`colima start -f` in the
# foreground; launchd restarts it on exit), so a bare `colima start/restart` would race launchd.
# Agent loaded in the GUI domain -> drive it with `launchctl kickstart [-k]`. Not loaded (no GUI login
# after a power cut, so no gui/<uid> domain) -> fall back to plain colima. Then wait (bounded,
# ENGINE_WAIT_S) for `colima status` + `docker info`. The marker's 2nd word says which path ran.
ENGINE_WAIT_S = 120
_ENGINE_PRELUDE = """export PATH=%s:$PATH
SVC="gui/$(id -u)/sh.brew.colima"
if launchctl print "$SVC" >/dev/null 2>&1; then HOW=launchd; else HOW=colima; fi
engine_wait() {
  i=0
  while [ $i -lt %d ]; do
    colima status >/dev/null 2>&1 && docker info >/dev/null 2>&1 && return 0
    i=$((i+1)); sleep 2
  done
  return 1
}
"""


def _engine_prelude():
    return _ENGINE_PRELUDE % (BREW_PATH, ENGINE_WAIT_S // 2)


def kick_script():
    return _engine_prelude() + """if colima status >/dev/null 2>&1; then echo "RDKICK vm-up"; exit 0; fi
if [ ! -f "%s" ]; then echo "RDKICK no-profile"; exit 0; fi
if [ "$HOW" = launchd ]; then launchctl kickstart "$SVC" >/dev/null 2>&1; else colima start >/dev/null 2>&1; fi
if engine_wait; then echo "RDKICK started $HOW"; else echo "RDKICK start-failed $HOW"; fi
""" % COLIMA_PROFILE


# Bounded command on the mini (macOS has no `timeout`): stdout -> $T; rc 124 when killed.
_TMO = """T=$(mktemp -t rdchk 2>/dev/null || echo "/tmp/rdchk.$$")
tmo() {
  s=$1; shift
  "$@" > "$T" 2>/dev/null &
  p=$!; i=0
  while kill -0 $p 2>/dev/null; do
    if [ $i -ge $s ]; then kill -9 $p 2>/dev/null; wait $p 2>/dev/null; return 124; fi
    sleep 1; i=$((i+1))
  done
  wait $p
}
"""


def dead_check():
    """Mini-side gate of a non-idle restart: `RDRESTART engine-ok` when docker info answers there
    (only the path to it is slow/broken), `RDRESTART busy <n>` when docker ps lists running
    containers; falls through (restart) only when info fails and ps is empty, fails or hangs."""
    return _TMO + """tmo %d docker info; INFO=$?
if [ $INFO -eq 0 ]; then rm -f "$T"; echo "RDRESTART engine-ok"; exit 0; fi
if tmo %d docker ps -q && [ -s "$T" ]; then
  N=$(grep -c . "$T"); rm -f "$T"; echo "RDRESTART busy $N"; exit 0
fi
rm -f "$T"
""" % (ENGINE_CHECK_TIMEOUT, ENGINE_CHECK_TIMEOUT)


def restart_script(require_idle, require_dead=False):
    idle = ("""IDS=$(docker ps -q 2>/dev/null) || { echo "RDRESTART docker-error"; exit 0; }
[ -z "$IDS" ] || { echo "RDRESTART busy"; exit 0; }
""" if require_idle else "")
    return _engine_prelude() + idle + (dead_check() if require_dead else "") + """if [ "$HOW" = launchd ]; then
  launchctl kickstart -k "$SVC" >/dev/null 2>&1 || { echo "RDRESTART failed $HOW"; exit 0; }
else
  colima restart >/dev/null 2>&1 || { echo "RDRESTART failed $HOW"; exit 0; }
fi
if engine_wait; then echo "RDRESTART ok $HOW"; else echo "RDRESTART no-docker $HOW"; fi
"""


def restart_due(now=None):
    """False while the last colima restart (janitor.json last_engine_restart) is < 30 min old."""
    last = rd_common.load_json(rd_common.JANITOR_PATH, {})
    last = last.get("last_engine_restart") if isinstance(last, dict) else None
    now = time.time() if now is None else now
    return not isinstance(last, (int, float)) or not 0 <= now - last < RESTART_MIN_GAP


def colima_restart(cfg, lock, why, require_idle=False, require_dead=False):
    """`colima restart` on the mini under `lock` (heartbeat first). require_idle: the remote script
    re-checks `docker ps -q` is empty right before restarting. require_dead: dead_check() first.
    -> marker word (ok/busy/engine-ok/failed/...)."""
    lock.heartbeat(force=True)
    rc, out, err = mini_sh(cfg, restart_script(require_idle, require_dead),
                           timeout=300 + 2 * ENGINE_CHECK_TIMEOUT)
    m = marker(out, "RDRESTART") or ["no-answer"]
    res = m[0]
    if res not in ("busy", "docker-error", "engine-ok"):   # a restart was attempted: 30-min clock
        rd_common.update_state(rd_common.JANITOR_PATH,
                               lambda st0: {**st0, "last_engine_restart": time.time()})
    rd_common.log("colima restart (%s): %s" % (why, " ".join(m) if res != "no-answer"
                                               else "no answer: " + (err or out).strip()[-200:]))
    return res, m[1:]


def locked_restart(cfg, why, require_idle=False, require_dead=False):
    """Rate-limited colima restart under the mini lock -> result word."""
    return locked_restart_detail(cfg, why, require_idle, require_dead)[0]


def locked_restart_detail(cfg, why, require_idle=False, require_dead=False):
    """locked_restart -> (result word, extra marker words)."""
    if not restart_due():
        rd_common.log("colima restart (%s) deferred: last restart < %d min ago"
                      % (why, RESTART_MIN_GAP // 60))
        return "rate-limited", []
    try:
        with mini_lock(cfg, "colima restart") as lk:
            return colima_restart(cfg, lk, why, require_idle, require_dead)
    except MiniLockBusy as e:
        rd_common.log("colima restart (%s) deferred: %s" % (why, e))
        return "lock-busy", []
    except MiniLockLost as e:
        rd_common.log("colima restart (%s) aborted: mini lock lost (%s)" % (why, e))
        return "lock-lost", []


ENGINE_ATTENTION = "engine"      # one attention key for every mini-engine condition (re-worded)
_DOWN_MIN = ENGINE_RESTART_AFTER_S // 60
_RESTART_ATTENTION = {
    "engine-ok": "mini docker engine answers on the mini but not through the tunnel for %d+ min - "
                 "not restarted (check the ssh master / laptop network: rdocker doctor)" % _DOWN_MIN,
    "busy": "mini docker engine not answering through the tunnel for %d+ min but %s container(s) "
            "run there - not restarted (would kill them; check the mini)",
    "rate-limited": "mini docker engine still not answering; restart rate-limited (last restart "
                    "< %d min ago)" % (RESTART_MIN_GAP // 60),
    "lock-lost": "mini engine restart aborted: mini lock lost",
}


def mini_engine_kick(cfg, restart_ok=False):
    """Mini reachable but its engine is not answering. VM down (e.g. the mini rebooted; Colima's
    LaunchAgent waits for a GUI login that never comes) -> `colima start`, only if the profile exists
    (never invent a VM with default sizing). VM up -> `colima restart` only with restart_ok (the
    daemon saw engine failures continuously for ENGINE_RESTART_AFTER_S) AND the mini-side
    dead_check() agrees (info fails there, nothing running) - rate-limited, under the mini lock.
    Anything that needs a human (no profile, failed start, a restart declined/failed) becomes the
    `engine` attention item; a successful start/restart clears it."""
    rc, out, err = mini_sh(cfg, kick_script(), timeout=240)
    m = marker(out, "RDKICK") or ["no-answer"]
    res = m[0]
    if res == "started":
        rd_common.log("mini engine was down -> started via %s (ok)" % " ".join(m[1:]))
        rd_common.attention_clear(ENGINE_ATTENTION)
    elif res == "no-profile":
        rd_common.log("mini engine down and no colima profile (~/.colima/default/colima.yaml) - "
                      "run: rdocker setup-mini")
        rd_common.attention_set(ENGINE_ATTENTION, "mini engine down and no colima profile on the "
                                "mini - run: rdocker setup-mini")
    elif res == "vm-up":
        if not restart_ok:
            rd_common.log("mini VM up but docker not answering - restart considered after %d min "
                          "of continuous failures" % _DOWN_MIN)
            return res
        res, words = locked_restart_detail(cfg, "docker unresponsive with VM up", require_dead=True)
        if res == "ok":
            rd_common.attention_clear(ENGINE_ATTENTION)
        elif res in _RESTART_ATTENTION:
            msg = _RESTART_ATTENTION[res]
            rd_common.attention_set(ENGINE_ATTENTION, msg % (_DOWN_MIN, (words or ["?"])[0])
                                    if res == "busy" else msg)
        elif res != "lock-busy":            # failed / no-docker / no-answer
            rd_common.attention_set(ENGINE_ATTENTION, "mini engine restart did not bring docker "
                                    "back (%s) - check the mini" % " ".join([res] + words))
        return res
    else:
        rd_common.log("mini engine was down -> start FAILED: %s"
                      % (" ".join(m) if res != "no-answer" else (err or out).strip()[-200:]))
        rd_common.attention_set(ENGINE_ATTENTION, "mini engine start failed (%s) - check the mini"
                                % " ".join(m))
    return res


def apply_when_idle(cfg):
    """Restart Colima to apply pending mini config (setup-mini sets restart_pending) only when no
    container runs there: a cheap pre-check, then - holding the mini lock - the restart script
    re-checks `docker ps -q` is empty right before `colima restart`. Pending stays set otherwise."""
    st = rd_common.load_json(rd_common.JANITOR_PATH, {})
    if not isinstance(st, dict) or not st.get("restart_pending"):
        rd_common.attention_clear(PENDING_ATTENTION)
        return None
    pending_age_check(st)
    rc, out, _ = rd_common.dk(cfg["remote_context"], "ps", "-q", timeout=20)
    if rc != 0 or out.strip():
        return "busy"
    res = locked_restart(cfg, "apply pending mini config", require_idle=True)
    if res == "ok":
        rd_common.update_state(rd_common.JANITOR_PATH, lambda st0: {
            **{k: v for k, v in st0.items() if k != "restart_pending_since"},
            "restart_pending": False})
        rd_common.attention_clear(PENDING_ATTENTION)
        rd_common.log("pending mini config applied")
    return res


PENDING_ATTENTION = "restart-pending"
PENDING_WARN_AFTER = 86400       # restart_pending this old -> attention (the mini is never idle)


def pending_age_check(st, now=None):
    """restart_pending older than PENDING_WARN_AFTER -> attention item. A pending flag without a
    start time (set by an older rdocker) is stamped now."""
    now = time.time() if now is None else now
    since = st.get("restart_pending_since")
    if not isinstance(since, (int, float)):
        rd_common.update_state(rd_common.JANITOR_PATH,
                               lambda st0: {**st0, "restart_pending_since": now})
        return False
    if now - since < PENDING_WARN_AFTER:
        return False
    rd_common.attention_set(PENDING_ATTENTION, "mini engine config change pending for %dh - Colima "
                            "restarts only when no container runs on the mini; stop them or run "
                            "`rdocker clean`" % ((now - since) // 3600))
    return True
