"""rdocker rd_route: the docker shim: per-call routing between mini and laptop, mini run/compose, pins, Engines.

Split out of rdocker.py; see rdocker.py for the overview.
"""
import os
import re
import signal
import subprocess
import sys
import threading
import time
import uuid

import rd_common
import rd_args
import rd_tunnel


def exists_on(cfg, ctx_key, name):
    """Tri-state: True (exists), False (engine answered "No such ..."), None (could not tell)."""
    rc, out, err = rd_common.dk(cfg[ctx_key], "container", "inspect", "--format", "{{.Id}}", name, timeout=12)
    if rc == 0:
        return True
    return False if "no such" in (err + out).lower() else None


def project_on(cfg, ctx_key, project):
    """Tri-state: does compose project `project` have any container (any state) on this engine?"""
    rc, out, _ = rd_common.dk(cfg[ctx_key], "ps", "-a", "-q", "--filter",
                    "label=com.docker.compose.project=" + project, timeout=12)
    if rc != 0:
        return None
    return bool(out.strip())


# ---------------------------------------------------------------------------- the shim

# Execute-once bookkeeping: set right before docker runs, so main()'s catch-all never re-runs a
# command (a second `run -d`) when routing code fails AFTER docker already ran. The single explicit
# exception is mini_run's one retry after the mini reports an ephemeral port as already allocated:
# that first attempt left only a Created container (removed by cid) and nothing running.
INVOKED = {"invoked": False, "rc": None}


class Refuse(Exception):
    """The shim cannot route safely; the message is printed and the shim exits 1 without docker."""


def exec_real(args):
    d = rd_common.real_docker()
    if rd_common.STDIN_REPLAY["data"] is not None:
        # stdin was consumed (buffered `compose -f -`): a plain exec would hand docker an empty
        # stdin, so run it as a child fed the same bytes and propagate its exit code.
        sys.exit(call_docker([d] + args))
    prev = INVOKED["invoked"]
    INVOKED["invoked"] = True
    try:
        os.execv(d, [d] + args)
    except OSError:
        INVOKED["invoked"] = prev       # docker never started
        raise


def spawn(cmd, **kw):
    """Popen for the user's docker command. When stdin was buffered (rd_common.STDIN_REPLAY) the
    child gets those bytes on a pipe (fed from a thread, so a child that writes before reading
    cannot deadlock us); otherwise it inherits our stdin."""
    data = rd_common.STDIN_REPLAY["data"]
    if data is None:
        return subprocess.Popen(cmd, **kw)
    child = subprocess.Popen(cmd, stdin=subprocess.PIPE, **kw)

    def feed():
        try:
            child.stdin.write(data)
        except OSError:              # the child exited / closed stdin early
            pass
        finally:
            try:
                child.stdin.close()
            except OSError:
                pass
    threading.Thread(target=feed, daemon=True).start()
    return child


def call_docker(cmd):
    prev = INVOKED["invoked"]
    INVOKED["invoked"] = True
    try:
        child = spawn(cmd)
    except OSError:
        INVOKED["invoked"] = prev
        raise
    rc = child.wait()
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
    rd_common.log("port refuse: %s | %s" % (msg, cwd()), rd_common.ROUTE_LOG)
    sys.exit(125)


def call_docker_capture(cmd):
    """Run docker with stdin/stdout inherited and stderr teed: re-emitted to our stderr unchanged as
    it arrives, and returned so the shim can recognise "port is already allocated". -> (rc, stderr)."""
    prev = INVOKED["invoked"]
    INVOKED["invoked"] = True
    try:
        child = spawn(cmd, stderr=subprocess.PIPE)
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
        child = spawn(cmd)
    except OSError:
        INVOKED["invoked"] = prev
        raise
    result = {"ok": True}

    def body():
        try:
            result["ok"] = watch(child) is not False
        except Exception as e:      # a watcher bug must not turn into a second docker run
            rd_common.log("foreground watcher error: %r" % e)

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
        rc, _, err = rd_common.dk(cfg["remote_context"], "rm", "-f", cid, timeout=60)
        if rc == 0:
            rd_common.say("removed container %s (just created by this command): %s" % (cid[:12], why))
            rd_common.log("removed just-created %s: %s" % (cid[:12], why))
        else:
            rd_common.say("could not remove container %s: %s" % (cid[:12], err.strip()[:200]))


def post_check(cfg, ids, created):
    """After containers `ids` started on the mini: sync mirrors and require a live laptop mirror for
    every TCP port they publish. On failure print which ports failed and why, `rm -f` the containers
    of `created` (made by this invocation; pre-existing ones keep running) and return False."""
    want_by = rd_tunnel.published_ports(cfg, ids)
    want = set().union(*want_by.values()) if want_by else set()
    ok, missing, conflicts = rd_tunnel.sync_forwards(cfg, verbose=False, want=want)
    if ok or not want:
        return True
    # A container that stopped on its own meanwhile has nothing to mirror - not a failure.
    still = rd_tunnel.published_ports(cfg, list(want_by))
    alive = set().union(*still.values()) if still else set()
    bad = sorted(set(missing) & alive)
    if not bad:
        return True
    for p in bad:
        if p in conflicts:
            rd_common.say("port %d is not mirrored to the laptop: laptop port %d is busy (another process "
                "holds it)" % (p, p))
        else:
            rd_common.say("port %d is not mirrored to the laptop: the SSH mirror could not be set up "
                "(see rdocker logs)" % p)
    owners = [cid for cid, ps in still.items() if ps & set(bad)]
    mine = [c for c in owners if any(c.startswith(x) or x.startswith(c) for x in created)]
    rm_created(cfg, mine, "its published port has no laptop mirror")
    for c in owners:
        if c not in mine:
            rd_common.say("container %s existed before this command - left running" % c[:12])
    return False


def wait_running(cfg, child, cid):
    """Poll until container `cid` runs or the foreground child exits -> True if running."""
    while child.poll() is None:
        d = rd_tunnel.inspect_containers(cfg, [cid])
        if d and (d[0].get("State") or {}).get("Running"):
            return True
        if d and (d[0].get("State") or {}).get("Status") in ("exited", "dead"):
            return False
        time.sleep(0.3)
    return False


def project_ids(cfg, project, all_=True):
    rc, out, _ = rd_common.dk(cfg["remote_context"], "ps", "-q", "--no-trunc", *(["-a"] if all_ else []),
                    "--filter", "label=com.docker.compose.project=" + project, timeout=20)
    return set(out.split()) if rc == 0 else set()


def mini_run(cfg, base, prefix, sub, args, detached):
    """docker run/create on the mini: laptop port preflight + reservation, --cidfile, one retry when
    the mini reports an ephemeral port as already allocated, then mirror post-check. Exits."""
    slots = rd_args.publish_slots(args, sub)
    specs = [rd_args.parse_publish(v) for _, _, v in slots]

    def rewrite(cur_args, new_specs):
        a = list(cur_args)
        for (i, pre, _), old, new in zip(slots, specs, new_specs):
            if old is not None and new is not None and new != old:
                a[i] = pre + rd_args.format_publish(new)
        return a

    try:
        new_specs, reserved = rd_tunnel.reserve_ports(cfg, specs)
    except rd_tunnel.PortRefuse as e:
        port_refuse_exit(e)
    user_cid = rd_args.parse_sub(sub, args).last("--cidfile")
    ours = []

    def with_cidfile(a):
        if user_cid:
            return a, user_cid
        os.makedirs(rd_tunnel.CID_DIR, exist_ok=True)
        path = os.path.join(rd_tunnel.CID_DIR, uuid.uuid4().hex)
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
                rd_tunnel.release_ports(reserved)
                return ok
            sys.exit(run_watched(base + prefix + run_args, watch))
        rc, err = call_docker_capture(base + prefix + run_args)
        cid = read_cid(cidpath)
        if rc == 125 and rd_tunnel.ALLOC_TEXT in err:
            # Execute-once exception (documented): the mini refused the port, so the first attempt left
            # only a Created container - removed here - and nothing running. One retry, ephemeral only.
            if cid:
                rm_created(cfg, [cid], "the mini reported its port as already allocated")
            m = re.search(r":(\d+) failed: port is already allocated", err)
            bad = int(m.group(1)) if m else None
            eph = [s for o, s in zip(specs, new_specs) if o is not None and s != o]
            eph_ports = {p for s in eph for p in range(s["host"][0], s["host"][1] + 1)}
            if not eph or (bad is not None and bad not in eph_ports):
                rd_tunnel.release_ports(reserved)
                sys.exit(rc)
            rd_tunnel.release_ports(reserved)
            picked = eph_ports if bad is None else {bad}
            if user_cid and read_cid(user_cid) == cid:
                os.unlink(user_cid)
            try:
                new_specs, reserved = rd_tunnel.reserve_ports(cfg, specs, exclude=picked)
            except rd_tunnel.PortRefuse as e:
                port_refuse_exit(e)
            run_args, cidpath = with_cidfile(rewrite(args, new_specs))
            rd_common.say("mini reported port %s as allocated - retrying once with another port"
                % (bad if bad is not None else "?"))
            rc, err = call_docker_capture(base + prefix + run_args)
            cid = read_cid(cidpath)
            if rc == 125 and rd_tunnel.ALLOC_TEXT in err and cid:
                rm_created(cfg, [cid], "the mini reported its port as already allocated")
        if rc != 0 or sub == "create":
            if rc != 0:
                rd_tunnel.release_ports(reserved)
            sys.exit(rc)     # create: reservations simply expire (nothing is bound until start)
        ok = post_check(cfg, [cid] if cid else [], [cid] if cid else [])
        rd_tunnel.release_ports(reserved)
        sys.exit(rc if ok else 1)
    finally:
        if sub == "run":            # create keeps its reservation until the TTL (bound at start)
            rd_tunnel.release_ports(reserved)
        for path in ours:
            try:
                os.unlink(path)
            except OSError:
                pass


def compose_port_specs(model, csub, crest):
    """Published ports a compose up/create/run will bind on the mini (parse_publish-shaped dicts,
    always with a host port: entries without a published port get no preflight - the post-check
    covers them)."""
    services = (model or {}).get("services") or {}
    pos, publish, service_ports, no_deps = rd_args.compose_services_and_publish(csub, crest)
    specs = []
    if csub == "run":
        specs.extend(rd_args.parse_publish(v) for v in publish)
        wanted = pos if service_ports else []
        deps = False
    else:
        wanted = [p for p in pos if p in services] or list(services)
        deps = not no_deps
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
                    host = rd_args._port_range(str(p.get("published") or ""))
                    tgt = int(p.get("target"))
                except (TypeError, ValueError):
                    continue
                specs.append({"ip": p.get("host_ip") or "", "host": host, "cport": (tgt, tgt),
                              "proto": (p.get("protocol") or "tcp").lower(), "proto_given": True})
            else:
                specs.append(rd_args.parse_publish(str(p)))
    return [s for s in specs if s is not None and (s["host"] is not None or s["proto"] != "tcp")]


def mini_compose(cfg, base, rest, compose_sub, crest, project, model, detached):
    """compose up/run/create (+start/restart) on the mini: preflight + reservation of the model's
    published ports, then mirror post-check; containers this invocation created are removed when
    their mirror fails. Exits."""
    reserved = []
    if compose_sub in rd_args.COMPOSE_CREATING:
        try:
            _, reserved = rd_tunnel.reserve_ports(cfg, compose_port_specs(model, compose_sub, crest))
        except rd_tunnel.PortRefuse as e:
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
                rd_tunnel.release_ports(reserved)
                return True
            sys.exit(run_watched(base + rest, watch))
        rc = call_docker(base + rest)
        if rc != 0 or compose_sub == "create":
            if rc != 0:
                rd_tunnel.release_ports(reserved)
            sys.exit(rc)
        ok = True
        if project:
            after = project_ids(cfg, project)
            ok = post_check(cfg, project_ids(cfg, project, all_=False), after - before)
        else:
            rd_tunnel.sync_forwards(cfg, verbose=True)
        rd_tunnel.release_ports(reserved)
        sys.exit(rc if ok else 1)
    except Exception:
        rd_tunnel.release_ports(reserved)
        raise


def pin_names(cfg, kind):
    """Names the config hints live on the laptop: explicit pins + fallback pins of this kind."""
    pins = cfg.get("pins") or {}
    explicit = pins.get("containers" if kind == "container" else "compose_projects") or []
    fb = [p.get("name") for p in pins.get("fallback") or []
          if isinstance(p, dict) and p.get("kind") == kind]
    return set(explicit) | {n for n in fb if n}


def add_fallback_pins(entries):
    """Record (name, kind) pairs as fallback pins in one config write. Raises ConfigWriteError /
    OSError - callers decide whether a lost pin matters."""
    entries = [(n, k) for n, k in entries if n]
    if not entries:
        return
    now = time.time()

    def apply(cur):
        pins = dict(cur["pins"])
        fb = [p for p in pins.get("fallback") or []
              if not (isinstance(p, dict) and (p.get("name"), p.get("kind")) in entries)]
        pins["fallback"] = fb + [{"name": n, "kind": k, "ts": now} for n, k in entries]
        return {**cur, "pins": pins}
    rd_common.update_cfg(apply)


def add_fallback_pin(name, kind):
    try:
        add_fallback_pins([(name, kind)])
    except (rd_common.ConfigWriteError, OSError) as e:
        rd_common.log("fallback pin %s/%s not saved: %s" % (kind, name, e))


def mark_local_active():
    """About to run a docker command on the laptop engine: leave a `local-active/<pid>` marker and
    touch `local-last`, so the daemon never quits Docker Desktop under it. The marker carries this
    process's pid - os.execv keeps the pid and call_docker waits here - so it is live exactly while
    the command runs; the daemon deletes markers whose pid is gone. Never fails the command."""
    try:
        os.makedirs(rd_common.LOCAL_ACTIVE_DIR, exist_ok=True)
        open(os.path.join(rd_common.LOCAL_ACTIVE_DIR, str(os.getpid())), "w").close()
        with open(rd_common.LOCAL_LAST_PATH, "w"):
            pass
        os.utime(rd_common.LOCAL_LAST_PATH)
    except OSError as e:
        rd_common.log("local-active marker not written: %s" % e)


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
        rd_common.update_cfg(apply)
    except (rd_common.ConfigWriteError, OSError) as e:
        rd_common.log("fallback pins %s not dropped: %s" % (names, e))


class Engines:
    """Lazily measured engine state for one shim call."""

    def __init__(self, cfg, mode):
        self.cfg, self.mode = cfg, mode
        self._mini = None
        self._laptop = None

    def mini(self):
        """-> (usable, reason): the mini engine answers over a working tunnel (speed not considered)."""
        if self._mini is None:
            h = rd_tunnel.health(self.cfg)
            if not h.get("reachable"):
                self._mini = (False, "mini unreachable")
            elif h.get("docker_ok") is False:
                self._mini = (False, "mini docker engine not responding")
            else:
                try:
                    ok = rd_tunnel.ensure_mini_socket(self.cfg)
                except OSError as e:
                    rd_common.log("ensure_mini_socket: %s" % e)
                    ok = False
                self._mini = (True, "ok") if ok else (False, "cannot open the SSH tunnel to the mini")
        return self._mini

    def slow(self):
        """Reason string when the (usable) mini is slower than max_rtt_ms, else None. Consulted ONLY
        for new throwaway containers (route_creating); every other command ignores RTT."""
        h = rd_tunnel.health(self.cfg)
        rtt = h.get("rtt_ms") or 0
        if self.cfg["max_rtt_ms"] and rtt > self.cfg["max_rtt_ms"]:
            return "mini round-trip %sms > %sms" % (rtt, self.cfg["max_rtt_ms"])
        return None

    def laptop_up(self):
        if self._laptop is None:
            self._laptop = rd_tunnel.local_engine_up(self.cfg)
        return self._laptop

    def start_laptop(self):
        self._laptop = rd_tunnel.ensure_local_running(self.cfg)
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
        rd_common.say("running on the laptop (%s)" % why)
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
            rd_common.say("%s %s found only on the laptop (%s) - showing the laptop's"
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


def unknown_flag_msg(what, flags, decides):
    # Unknown flags REFUSE rather than pick an engine. Guessing the flag's width either way can hide
    # what decides placement: read as a boolean, its value becomes the "image" and every later -v is
    # taken for a container argument (a laptop bind mount silently lands on the mini); read as
    # value-taking, the image is swallowed and the same happens one word later. Defaulting to the
    # laptop instead would split kept data (a named volume created empty on the laptop). A refusal is
    # loud and has escape hatches; a mis-route is silent. (Docker 28.5.1 rejects these flags anyway;
    # this only bites a newer CLI with flags the tables in rd_args do not know yet.)
    return ("docker %s: unrecognized flag %s - rdocker cannot tell %s, so it will not pick an engine. "
            "Force one with RDOCKER_MODE=local or `docker --context <ctx> ...`, or add the flag to "
            "rd_args.SPECS" % (what, " ".join(flags), decides))


def compose_config_exit(e):
    """`compose config` (the model render) failed: show compose's own error and stop - the user's
    command would fail the same way, and routing on a model we could not read is a guess."""
    sys.stderr.write(e.stderr if e.stderr.endswith("\n") or not e.stderr else e.stderr + "\n")
    rd_common.say("`docker compose config` failed (exit %s); not running the command" % e.rc)
    rd_common.log("compose config failed rc=%s | %s" % (e.rc, cwd()), rd_common.ROUTE_LOG)
    sys.exit(1)


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
    rd_common.say("running on the laptop (%s)" % why)
    return "local", why, True


def ps_tabular(args):
    """Does `docker ps <args>` print a table with a header line? Not with -q/--quiet (also inside a
    short cluster like -aq) nor with a --format other than `table ...` (json, Go templates)."""
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-q", "--quiet") or (a.startswith("-") and not a.startswith("--") and "q" in a[1:]):
            return False
        if a == "--format" or a.startswith("--format="):
            val = a.partition("=")[2] if "=" in a else (args[i + 1] if i + 1 < len(args) else "")
            if not val.strip().startswith("table"):
                return False
        if a in ("-f", "--filter", "--format", "-n", "--last"):
            i += 1          # skip the flag's value
        i += 1
    return True


def merged_ps(cfg, base, gflags, rest, args):
    """`ps` while the laptop engine is up: the mini's output streams first, then the laptop's (its
    table header dropped so the table has one). -> non-zero when either engine's ps failed."""
    rc1 = call_docker(base + rest)
    rc2, out, err = rd_common.run([rd_common.real_docker(), "--context", cfg["local_context"]]
                                  + gflags + rest, timeout=20)
    lines = out.splitlines()
    if lines and ps_tabular(args):
        lines = lines[1:]
    if lines:
        sys.stdout.write("\n".join(lines) + "\n")
        sys.stdout.flush()
    if rc1 != 0:
        rd_common.say("ps on the mini failed (rc=%s); laptop containers listed below it" % rc1)
    if rc2 != 0:
        rd_common.say("ps on the laptop engine failed (rc=%s): %s"
                      % (rc2, (err.strip().splitlines() or ["no output"])[-1][:200]))
    return rc1 or rc2


def shim(argv):
    cfg = rd_common.load_cfg()
    mode = os.environ.get("RDOCKER_MODE") or cfg["mode"]
    gflags, rest = rd_args.split_global(argv)
    explicit = any(f in ("-c", "--context", "-H", "--host") or f.startswith(("--context=", "--host="))
                   for f in gflags) or os.environ.get("DOCKER_HOST") or os.environ.get("DOCKER_CONTEXT")
    if mode == "off" or explicit or os.environ.get("RDOCKER_BYPASS") or not rest \
            or rest[0] in rd_args.RAW_PASSTHRU:
        exec_real(argv)

    sub, args = rest[0], rest[1:]
    group = None
    if sub in rd_args.MGMT_GROUPS and args:
        group, sub, args = sub, args[0], args[1:]
    container_cmd = group in (None, "container")
    if container_cmd and sub == "inspect" and group is None:
        typ = rd_args.parse_sub("inspect", args).last("--type")
        container_cmd = typ is None or typ == "container"

    eng = Engines(cfg, mode)
    compose_sub = compose_project = None
    rm_names = []
    try:
        if sub == "compose" and group is None:
            cflags, compose_sub, crest, unknown = rd_args.compose_split(args)
            if unknown and mode != "local":
                raise Refuse(unknown_flag_msg("compose", unknown, "which compose subcommand runs"))
        if mode == "local":
            target, why = "local", "mode=local"
        elif container_cmd and sub in rd_args.CONTAINER_TARGETED:
            names = rd_args.container_targets(sub, args)
            target, why = route_targeted(eng, sub, names, pin_names(cfg, "container"),
                                         sub in rd_args.READ_ONLY_TARGETED, "container")
            if target == "split":
                groups = why
                opts = [a for a in args if a not in names]
                rc1 = call_docker([rd_common.real_docker(), "--context", cfg["remote_context"]]
                                  + gflags + [sub] + opts + groups["mini"]) if groups["mini"] else 0
                rc2 = 0
                if groups["local"] and rd_tunnel.ensure_local_running(cfg):
                    mark_local_active()
                    rc2 = call_docker([rd_common.real_docker(), "--context", cfg["local_context"]]
                                      + gflags + [sub] + opts + groups["local"])
                    if sub == "rm" and rc2 == 0:
                        drop_fallback_pins(cfg, groups["local"], "container")
                elif groups["local"]:
                    rc2 = 1
                rd_common.log("split %-8s mini=%s laptop=%s | %s" % (sub, groups["mini"], groups["local"], cwd()),
                    rd_common.ROUTE_LOG)
                if sub in rd_args.STOP_LIKE and groups["mini"]:
                    rd_tunnel.spawn_bg_sync(repeat=1)
                sys.exit(rc1 or rc2)
            if sub == "rm":
                rm_names = names
        elif sub == "compose" and compose_sub in rd_args.COMPOSE_TARGETED:
            compose_project, _, _ = rd_args.compose_inspect(cflags)
            target, why = route_targeted(eng, "compose " + compose_sub,
                                         [compose_project] if compose_project else [],
                                         pin_names(cfg, "compose"),
                                         compose_sub in rd_args.COMPOSE_READ_ONLY, "compose project")
        elif container_cmd and sub in rd_args.RUN_LIKE:
            unknown = rd_args.unknown_flags(sub, args)
            if unknown:
                raise Refuse(unknown_flag_msg(sub, unknown, "whether it mounts laptop paths"))
            name = rd_args.parse_sub(sub, args).last("--name")
            target, why, fell_back = route_creating(eng, rd_args.run_needs_local(args, sub),
                                                    rd_args.run_not_throwaway(args, sub), None)
            if fell_back and name:
                add_fallback_pin(name, "container")
        elif sub == "compose" and compose_sub in rd_args.COMPOSE_CREATING:
            compose_project, need_local, named = rd_args.compose_inspect(cflags)
            if compose_sub == "run":
                unknown = rd_args.unknown_flags("compose run", crest)
                if unknown:
                    raise Refuse(unknown_flag_msg("compose run", unknown,
                                                  "whether it mounts laptop paths"))
                need_local = need_local or rd_args.compose_run_needs_local(crest)
                if named is not None:
                    named = named + rd_args.compose_run_named_volumes(crest)
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
        rd_common.say(str(e))
        rd_common.log("refuse %-8s %s | %s" % (sub, e, cwd()), rd_common.ROUTE_LOG)
        sys.exit(1)
    except rd_args.ComposeConfigError as e:
        compose_config_exit(e)

    if target == "local" and os.environ.get("RDOCKER_VERBOSE"):
        rd_common.say("running locally: " + why)
    ctx = cfg["remote_context"] if target == "mini" else cfg["local_context"]
    rd_common.log("%-5s %-8s %s | %s" % (target, sub, why, cwd()), rd_common.ROUTE_LOG)
    if target == "local":
        if not rd_tunnel.ensure_local_running(cfg):
            sys.exit(1)
        mark_local_active()

    base = [rd_common.real_docker(), "--context", ctx] + gflags

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
    if sub == "ps" and container_cmd and target == "mini" and rd_tunnel.local_engine_up(cfg):
        sys.exit(merged_ps(cfg, base, gflags, rest, args))

    if target == "mini":
        if sub == "compose":
            detached = rd_args.is_detached(crest, "compose " + compose_sub)
        else:
            detached = rd_args.is_detached(args, sub)
        if container_cmd and sub in rd_args.RUN_LIKE:
            mini_run(cfg, base, rest[:len(rest) - len(args)], sub, args, detached)
        if sub == "compose" and compose_sub in rd_args.COMPOSE_START:
            try:            # cached: already rendered while routing, so this cannot newly fail
                if compose_project is None:
                    compose_project = rd_args.compose_inspect(cflags)[0]
                model = rd_args.compose_model(cflags)
            except rd_args.ComposeConfigError as e:
                compose_config_exit(e)
            mini_compose(cfg, base, rest, compose_sub, crest, compose_project, model, detached)
        if container_cmd and sub in rd_args.START_LIKE:
            rc = call_docker(base + rest)
            if rc == 0 and not post_check(cfg, rd_args.container_targets(sub, args), []):
                sys.exit(1)
            sys.exit(rc)
        if (container_cmd and sub in rd_args.STOP_LIKE) or (sub == "compose" and compose_sub in rd_args.COMPOSE_STOP):
            rc = call_docker(base + rest)
            rd_tunnel.spawn_bg_sync(repeat=1)
            sys.exit(rc)

    exec_real(["--context", ctx] + gflags + rest)
