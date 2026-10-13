#!/usr/bin/python3
"""rdocker - run Docker on the always-on Mac mini, transparently.

The laptop's `docker` (via the shim in ~/.local/bin) is routed per call:
  * normal work (test databases, builds, compose stacks) -> the mini over SSH/Tailscale;
  * commands that need the laptop's own files or network (bind mounts of laptop paths,
    --network host) and containers pinned as laptop-resident -> the local Docker Desktop;
  * mini unreachable (mode=auto) -> only NEW throwaway containers (--rm, or no named volume and
    no rdocker.keep label) fall back to the laptop, with a one-line notice; anything that keeps
    data is refused (exit 1) rather than created on the wrong engine. A slow mini (round-trip
    > max_rtt_ms on 2 consecutive readings) likewise sends only new throwaway containers to the laptop.
Published ports of mini containers are mirrored onto the laptop's 127.0.0.1 through one SSH
ControlMaster, so `localhost:<port>` keeps working (same port number on both sides).

Stdlib only; runs on the system /usr/bin/python3 (3.9). See commands/docker.md for the playbook.

This file is only the entry point (launchd plist, ~/.local/bin/rdocker and docker-shim all point
here). The code lives beside it, in dependency order:
  rd_common  paths, DEFAULTS, config/state files + locks, logging, subprocess/docker helpers
  rd_args    docker argv parsing from explicit per-command flag tables (run/create, compose, publish)
  rd_tunnel  health probe, target resolution, laptop port reservation, SSH master, mirror sync
  rd_route   the shim's per-call routing (mini run/compose, pins, Engines)
  rd_janitor janitor, mini lock, engine kick/restart, apply_when_idle
  rd_daemon  launchd forwarder loop, tailscale, global docker context
  rd_setup   install / setup-mini and the CLI (status, where, main, command)
If those modules fail to import (any exception, not only ImportError), a shim call still runs
read-only docker commands unrouted and refuses anything that targets or creates a container (it
could land on the wrong engine). rd_setup.routing_failed applies the same FALLBACK_SAFE rule when
routing raises before docker runs.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)   # the shim runs us with -I, which keeps the script dir off sys.path

# Shim subcommands safe to run unrouted when the modules are broken: none of them targets or
# creates a container. Everything else is refused.
FALLBACK_SAFE = {"version", "info", "ps", "images", "context", "login", "logout", "help",
                 "completion", "search", "pull", "push", "tag", "--help", "-h", "--version", "-v"}
FALLBACK_GLOBAL_VALUE_FLAGS = {"--config", "-c", "--context", "-H", "--host", "-l", "--log-level",
                               "--tlscacert", "--tlscert", "--tlskey"}


def fallback_real_docker():
    """Inline copy of rd_common.real_docker(): first `docker` on PATH that is not our shim."""
    shim = os.path.realpath(os.path.join(HERE, "docker-shim"))
    dirs = os.environ.get("PATH", "").split(":") + [
        "/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin"]
    for d in dirs:
        p = os.path.join(d, "docker")
        if os.path.isfile(p) and os.access(p, os.X_OK) and os.path.realpath(p) != shim:
            return p
    raise SystemExit("rdocker: no real docker CLI found (install Docker Desktop or `brew install docker`)")


def fallback_split(argv):
    """-> (unrouted, sub): unrouted when a working rdocker would not route this call either
    (bypass, mode off, explicit context/host); sub is the docker subcommand or None."""
    try:
        home = os.path.expanduser(os.environ.get("RDOCKER_HOME") or "~")   # == rd_common.HOME
        with open(os.path.join(home, ".config", "rdocker", "config.json")) as f:
            mode = json.load(f).get("mode")
    except (OSError, ValueError, AttributeError):
        mode = None
    unrouted = bool((os.environ.get("RDOCKER_MODE") or mode) == "off" or os.environ.get("RDOCKER_BYPASS")
                    or os.environ.get("DOCKER_HOST") or os.environ.get("DOCKER_CONTEXT"))
    i = 0
    while i < len(argv) and argv[i].startswith("-") and argv[i] != "-":
        if argv[i] in ("-c", "--context", "-H", "--host") or argv[i].startswith(("--context=", "--host=")):
            unrouted = True
        i += 2 if argv[i] in FALLBACK_GLOBAL_VALUE_FLAGS else 1
    return unrouted, (argv[i] if i < len(argv) else None)


def import_failed(argv, err):
    sys.stderr.write("rdocker: modules failed to import (%s: %s)\n" % (type(err).__name__, err))
    if not argv or argv[0] != "shim":
        return 1
    unrouted, sub = fallback_split(argv[1:])
    if unrouted or sub is None or sub in FALLBACK_SAFE:
        d = fallback_real_docker()
        os.execv(d, [d] + argv[1:])
    sys.stderr.write("rdocker: modules failed to import; refusing %s (run `rdocker doctor`)\n" % sub)
    return 1


if __name__ == "__main__":
    try:
        import rd_setup
    except Exception as e:      # ImportError, SyntaxError, or a NameError/... at module import
        sys.exit(import_failed(sys.argv[1:], e))
    sys.exit(rd_setup.main(sys.argv[1:]))
