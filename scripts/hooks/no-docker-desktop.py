#!/usr/bin/env python3
"""
PreToolUse gate (Bash) - block launching a local Docker engine and pattern sweeps of containers.

Why: Docker runs on the Mac mini (rdocker); laptop Docker Desktop costs GBs of RAM on a 16 GB laptop
that a dozen agents share. rdocker never starts it, but agents had a habit of `open -a Docker` whenever
`docker info` failed or was slow (2026-10-15: four sessions; one launch took the RAM the user needed).
A failing docker means "fix the mini" (`rdocker doctor`), not "boot a second engine here".

Blocks (exit 2, message on stderr): `open [-flags] -a Docker`, `open .../Docker.app`, AppleScript
activate/launch/run of application "Docker", `docker desktop start`, Linux `systemctl start docker`,
`service docker start`, and `dockerd`. Allowed when the command carries
RDOCKER_LOCAL_START=1 (the deliberate opt-in rdocker itself honours). FAILS OPEN on any parse error.
"""
import json
import re
import sys

LAUNCH = re.compile(
    r"(^|[\s;&|(])open\s+(-[A-Za-z]+\s+)*(-[A-Za-z]*a[A-Za-z]*\s+)[\"']?Docker( Desktop)?(\.app)?[\"']?(\s|$|[;&|)])"
    r"|(^|[\s;&|(])open\s+(-[A-Za-z]+\s+)*[\"']?\S*Docker\.app[\"']?"
    r"|application\s+\\?[\"']Docker( Desktop)?\\?[\"']\s+to\s+(activate|launch|run|open)"
    r"|(tell\s+application\s+\\?[\"']Docker( Desktop)?\\?[\"'])[^\n]*\b(activate|launch|run)\b"
    r"|(^|[\s;&|(])docker\s+desktop\s+(start|restart)\b",
    re.I)

# Linux: starting the local engine. Anchored to the start of a command segment (start of line, or after
# ; & | ( or `$(`, optionally behind sudo/nohup/env assignments), so `grep dockerd`, `which dockerd`,
# `man dockerd` or `echo systemctl start docker` are not blocked.
_SEG = r"(?:^|[;&|(]|\$\()\s*(?:(?:sudo|nohup|exec)(?:\s+-\S+)*\s+|[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
LINUX_LAUNCH = re.compile(
    _SEG + r"systemctl\s+(?:--user\s+)?(?:start|restart|enable\s+--now)\s+docker(?:\.(?:service|socket))?(?=\s|$|[;&|)])"
    r"|" + _SEG + r"service\s+docker\s+(?:start|restart)(?=\s|$|[;&|)])"
    r"|" + _SEG + r"(?:[^\s;&|]*/)?dockerd(?=\s|$|[;&|)])",
    re.I)


# Bulk removal by pattern: `docker rm $(docker ps ... --filter name=X)`, `docker ps ... | grep X | xargs
# docker rm`, prune. All agents share ONE mini engine, so a sweep by name prefix deletes other agents'
# live containers (twice on 2026-10-15: p7p3-vitest-db-*). Remove only your own, by exact name/id.
SWEEP = re.compile(
    r"docker\s+(container\s+)?(rm|stop|kill)\b[^;&|\n]*\$\(\s*docker\s+(container\s+)?ps\b"
    r"|docker\s+(container\s+)?ps\b[^;&\n]*\|[^;&\n]*xargs\b[^;&|\n]*docker\s+(container\s+)?(rm|stop|kill)\b"
    r"|docker\s+(container\s+)?prune\b|docker\s+system\s+prune\b",
    re.I)


def log_block(d, cmd, kind):
    """Who tried, for later debugging: ~/.local/state/rdocker/blocked-desktop.log (never raises)."""
    try:
        import os
        import time
        d_ = os.path.expanduser("~/.local/state/rdocker")
        os.makedirs(d_, exist_ok=True)
        with open(os.path.join(d_, "blocked-desktop.log"), "a") as f:
            f.write("%s %s session=%s cwd=%s cmd=%s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), kind,
                    d.get("session_id", "?"), d.get("cwd", "?"), " ".join(cmd.split())[:200]))
    except Exception:
        pass


def main():
    try:
        d = json.loads(sys.stdin.read() or "{}")
        cmd = (d.get("tool_input") or {}).get("command") or ""
    except Exception:
        return 0
    if d.get("tool_name") != "Bash" or not cmd:
        return 0
    if SWEEP.search(cmd) and "RDOCKER_ALLOW_SWEEP=1" not in cmd:
        log_block(d, cmd, "sweep")
        print("NO-DOCKER-SWEEP: don't remove/stop containers by pattern - every agent shares the Mac "
              "mini's Docker, so a name-prefix sweep deletes OTHER agents' containers. Remove only "
              "the containers you created, by exact name or id (`docker rm -f -v <name>`); the rdocker "
              "janitor reaps leftovers. (Only if the user asked for a sweep: RDOCKER_ALLOW_SWEEP=1.)",
              file=sys.stderr)
        return 2
    if "RDOCKER_LOCAL_START=1" in cmd or not (LAUNCH.search(cmd) or LINUX_LAUNCH.search(cmd)):
        return 0
    log_block(d, cmd, "desktop")
    if LINUX_LAUNCH.search(cmd):
        print("NO-DOCKER-DESKTOP: don't start the local docker engine; Docker runs on the Mac mini. "
              "Run `rdocker doctor` and retry. Only if the user wants the laptop engine: prefix the "
              "command with RDOCKER_LOCAL_START=1.", file=sys.stderr)
    else:
        print("NO-DOCKER-DESKTOP: don't start laptop Docker Desktop - it costs GBs of RAM and Docker runs "
              "on the Mac mini. If docker fails or is slow, run `rdocker doctor` (and `rdocker status`), "
              "then retry; plain `docker ...` already goes to the mini. Only if the user wants the laptop "
              "engine: prefix the command with RDOCKER_LOCAL_START=1.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
