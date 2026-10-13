#!/usr/bin/python3
"""A stand-in `docker` CLI for shim tests. Never talks to a daemon.

Env:
  FAKE_DOCKER_FIXTURE  JSON file: {"<context>": {"containers": {name: {...}}, "version_ok": bool,
                       "compose_projects": {project: [ids]}, "down": bool},
                       "_compose_model": {...}  # what `docker compose ... config --format json` prints
                       }
  FAKE_DOCKER_LOG      every invocation's argv is appended here as one JSON line.

Behaviour (minimal): `--context X version|info|container inspect|inspect|ps|run|create|rm|<anything>`.
A context marked "down" (or missing) fails every call with a daemon-connection error, which the
shim must treat as "cannot tell" - never as "No such container".

Containers made by `run`/`create` persist in FAKE_DOCKER_STATE (default <fixture>.state) so later
`ps -q`, `inspect` (full JSON incl. NetworkSettings.Ports) and `rm -f` see them. `run` honours
`--cidfile`. Per-context fixture knobs:
  "alloc_fail_once": true   first `run` creates the container, writes the cidfile, then fails like
                            the daemon: exit 125 "... Bind for 0.0.0.0:<hp> failed: port is already allocated"
  "fg_seconds": N           a foreground `run` (no -d) stays "running" up to N s, exiting early (137)
                            once its container is removed
Janitor knobs (per context):
  containers.<name>: "Labels", "Image", "Mounts" ([{"Type": "volume", "Name": ...}]), "StartedAt",
                     "FinishedAt", "Created", "netio" (docker stats NetIO), "established" (bool)
  "ghosts": [ids]           listed by `ps -a` but gone at inspect -> partial JSON + exit 1
  "inspect_garbage": true   bulk `container inspect` prints non-JSON and exits 1
  "volumes": {name: {"Labels": {...}}}, "images": {id: {"Labels": {...}}}
  "system_time": "<RFC3339>"   `info --format {{.SystemTime}}`
  "fail": ["stop", "image rm", ...]   these subcommands exit 1 ("boom")
  "old_buildx": true        `builder prune --max-used-space` fails with "unknown flag"
"""
import fcntl
import json
import os
import sys
import time
from contextlib import contextmanager

RUN_VALUES = {"-p", "--publish", "--name", "--cidfile", "-e", "--env", "-v", "--volume", "-l",
              "--label", "-a", "-u", "-w", "-h", "-m", "-c", "--network", "--net", "--mount",
              "--entrypoint", "--env-file", "--user", "--workdir"}


def state_path():
    return os.environ.get("FAKE_DOCKER_STATE") or os.environ.get("FAKE_DOCKER_FIXTURE", "/tmp/x") + ".state"


@contextmanager
def state():
    path = state_path()
    with open(path + ".lock", "a+") as lk:
        fcntl.flock(lk.fileno(), fcntl.LOCK_EX)
        try:
            with open(path) as f:
                st = json.load(f)
        except (OSError, ValueError):
            st = {"n": 0, "containers": {}}
        yield st
        with open(path + ".tmp", "w") as f:
            json.dump(st, f)
        os.replace(path + ".tmp", path)


def parse_run(args):
    """-> (opts {flag: [values]}, detached)."""
    opts, detached, i = {}, False, 0
    while i < len(args):
        a = args[i]
        if not a.startswith("-") or a == "-":
            break
        if a.startswith("--") and "=" in a:
            k, v = a.split("=", 1)
            opts.setdefault(k, []).append(v)
        elif a in RUN_VALUES:
            opts.setdefault(a, []).append(args[i + 1])
            i += 1
        elif a in ("-d", "--detach"):
            detached = True
        elif not a.startswith("--"):
            for j, ch in enumerate(a[1:], 1):
                if "-" + ch in RUN_VALUES:
                    v = a[j + 1:] or args[i + 1]
                    if not a[j + 1:]:
                        i += 1
                    opts.setdefault("-" + ch, []).append(v)
                    break
                if ch == "d":
                    detached = True
        i += 1
    return opts, detached


def net_ports(publishes, st):
    ports = {}
    for v in publishes:
        v, _, proto = v.partition("/")
        parts = v.split(":")
        ip, hp, cp = ("", "", parts[0]) if len(parts) == 1 else \
            (("", parts[0], parts[1]) if len(parts) == 2 else parts)
        lo, _, hi = cp.partition("-")
        hlo = hp.partition("-")[0]
        for k, c in enumerate(range(int(lo), int(hi or lo) + 1)):
            if hlo:
                h = int(hlo) + k
            else:
                st["n"] += 1
                h = 32768 + st["n"]
            ports.setdefault("%d/%s" % (c, proto or "tcp"), []).append(
                {"HostIp": ip or "0.0.0.0", "HostPort": str(h)})
    return ports


def do_run(eng, sub, args):
    opts, detached = parse_run(args)
    pubs = opts.get("-p", []) + opts.get("--publish", [])
    with state() as st:
        st["n"] += 1
        cid = "cid%04d" % st["n"]
        ports = net_ports(pubs, st)
        fail = sub == "run" and eng.get("alloc_fail_once") and not st.get("alloc_failed")
        st["containers"][cid] = {"Id": cid, "Name": "/" + (opts.get("--name") or [cid])[-1],
                                 "running": sub == "run" and not fail, "ports": ports}
        if fail:
            st["alloc_failed"] = True
    for path in opts.get("--cidfile", []):
        with open(path, "w") as f:
            f.write(cid)
    if fail:
        hp = next((b["HostPort"] for bs in ports.values() for b in bs), "0")
        sys.stderr.write("docker: Error response from daemon: driver failed programming external "
                         "connectivity on endpoint x (%s): Bind for 0.0.0.0:%s failed: port is "
                         "already allocated.\n" % (cid, hp))
        return 125
    if sub == "create" or detached:
        print(cid)
        return 0
    deadline = time.time() + float(eng.get("fg_seconds") or 0)
    while time.time() < deadline:
        time.sleep(0.2)
        with state() as st:
            if cid not in st["containers"]:
                return 137
    with state() as st:
        if cid in st["containers"]:
            st["containers"][cid]["running"] = False
    return 0


def find(st, containers, n):
    for c in st["containers"].values():
        if n in (c["Id"], c["Name"].lstrip("/")):
            return {"Id": c["Id"], "Name": c["Name"],
                    "State": {"Running": c["running"],
                              "Status": "running" if c["running"] else "created"},
                    "NetworkSettings": {"Ports": c["ports"]}}
    key = next((k for k, c in containers.items() if n in (k, c.get("Id", "id-" + k))), None)
    if key is not None:
        n, c = key, containers[key]
        return {"Id": c.get("Id", "id-" + n), "Name": "/" + n,
                "Created": c.get("Created", "2026-01-01T00:00:00Z"),
                "Image": c.get("Image", "sha256:img-" + n),
                "Config": {"Labels": c.get("Labels") or {}},
                "Mounts": c.get("Mounts") or [],
                "State": {"Running": c.get("running", True),
                          "Status": "running" if c.get("running", True) else "exited",
                          "StartedAt": c.get("StartedAt", "0001-01-01T00:00:00Z"),
                          "FinishedAt": c.get("FinishedAt", "0001-01-01T00:00:00Z")},
                "NetworkSettings": {"Ports": c.get("Ports") or {}}}
    return None


def main(argv):
    log = os.environ.get("FAKE_DOCKER_LOG")
    if log:
        with open(log, "a") as f:
            f.write(json.dumps(argv) + "\n")
    try:
        with open(os.environ["FAKE_DOCKER_FIXTURE"]) as f:
            fixture = json.load(f)
    except (KeyError, OSError, ValueError):
        fixture = {}

    ctx = None
    if argv[:1] == ["--context"] and len(argv) > 1:
        ctx, argv = argv[1], argv[2:]
    if not argv:
        return 0
    if argv[0] == "compose" and "config" in argv:
        model = fixture.get("_compose_model")
        if model is None:
            sys.stderr.write("no configuration file provided: not found\n")
            return 1
        print(json.dumps(model))
        return 0
    if ctx is None:
        return 0

    eng = fixture.get(ctx)
    if not isinstance(eng, dict) or eng.get("down"):
        sys.stderr.write("Cannot connect to the Docker daemon at unix:///fake.sock. "
                         "Is the docker daemon running?\n")
        return 1
    containers = eng.get("containers") or {}

    if argv[0] == "version":
        if eng.get("version_ok", True):
            print("28.5.1")
            return 0
        return 1
    fail = eng.get("fail") or []
    if argv[0] in fail or " ".join(argv[:2]) in fail:
        sys.stderr.write("Error response from daemon: boom\n")
        return 1
    if argv[0] == "info":
        print(eng.get("system_time", "x") if "--format" in argv else "x")
        return 0
    if argv[:2] in (["volume", "inspect"], ["image", "inspect"]):
        pool = eng.get("volumes" if argv[0] == "volume" else "images") or {}
        name = argv[2]
        if name not in pool:
            print("[]")
            sys.stderr.write("Error: No such %s: %s\n" % (argv[0], name))
            return 1
        labels = pool[name].get("Labels") or {}
        rec = {"Name": name, "Labels": labels} if argv[0] == "volume" else \
            {"Id": name, "Config": {"Labels": labels}}
        print(json.dumps([rec]))
        return 0
    if argv[:2] == ["volume", "ls"]:
        print("\n".join(eng.get("volumes") or {}))
        return 0
    if argv[:2] in (["image", "ls"], ["images"]):
        print("\n".join(eng.get("images") or {}))
        return 0
    if argv[0] == "stats":
        for k, c in containers.items():
            if c.get("running", True):
                print("%s\t%s" % (c.get("Id", "id-" + k)[:12], c.get("netio", "0B / 0B")))
        return 0
    if argv[0] == "exec":
        c = next((c for k, c in containers.items() if argv[1] in (k, c.get("Id", "id-" + k))), None)
        if c is None:
            sys.stderr.write("Error: No such container: %s\n" % argv[1])
            return 1
        print("  sl  local_address rem_address   st")
        if c.get("established"):
            print("   0: 0100007F:1F90 0100007F:C350 01 0")
        return 0
    if argv[:2] == ["builder", "prune"] and "--max-used-space" in argv and eng.get("old_buildx"):
        sys.stderr.write("unknown flag: --max-used-space\n")
        return 1
    if argv[0] == "inspect" or argv[:2] == ["container", "inspect"]:
        rest = argv[1:] if argv[0] == "inspect" else argv[2:]
        if eng.get("inspect_garbage") and len(rest) > 1:
            print("not json {")
            return 1
        names, i, fmt = [], 0, False
        while i < len(rest):
            if rest[i] in ("--format", "-f", "--type"):
                fmt = fmt or rest[i] != "--type"
                i += 2
                continue
            if not rest[i].startswith("-"):
                names.append(rest[i])
            i += 1
        rc, found = 0, []
        with state() as st:
            for n in names:
                d = find(st, containers, n)
                if d is None:
                    sys.stderr.write("Error: No such container: %s\n" % n)
                    rc = 1
                elif fmt:
                    print(d["Id"])
                else:
                    found.append(d)
        if not fmt:
            print(json.dumps(found))
        return rc
    if argv[0] == "ps":
        flt = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "--filter"]
        for f in flt:
            if f.startswith("label=com.docker.compose.project="):
                proj = f.split("=", 2)[2]
                for cid in (eng.get("compose_projects") or {}).get(proj, []):
                    print(cid)
                return 0
        all_ = bool({"-a", "-aq", "--all"} & set(argv))
        for k, c in containers.items():
            if c.get("running", True) or all_:
                print(c.get("Id", "id-" + k))
        if all_:
            for g in eng.get("ghosts") or []:
                print(g)
        with state() as st:
            for c in st["containers"].values():
                if c["running"] or all_:
                    print(c["Id"])
        return 0
    if argv[0] in ("run", "create"):
        return do_run(eng, argv[0], argv[1:])
    if argv[0] == "container" and argv[1:2] in (["run"], ["create"]):
        return do_run(eng, argv[1], argv[2:])
    if argv[0] == "rm":
        with state() as st:
            for n in [a for a in argv[1:] if not a.startswith("-")]:
                st["containers"].pop(n, None)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
