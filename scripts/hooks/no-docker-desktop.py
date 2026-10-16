#!/usr/bin/env python3
"""
PreToolUse gate (Bash) - block launching laptop Docker Desktop by hand.

Why: Docker runs on the Mac mini (rdocker); laptop Docker Desktop costs GBs of RAM on a 16 GB laptop
that a dozen agents share. rdocker never starts it, but agents had a habit of `open -a Docker` whenever
`docker info` failed or was slow (2026-10-15: four sessions; one launch took the RAM the user needed).
A failing docker means "fix the mini" (`rdocker doctor`), not "boot a second engine here".

Blocks (exit 2, message on stderr): `open [-flags] -a Docker`, `open .../Docker.app`, AppleScript
activate/launch/run of application "Docker", `docker desktop start`. Allowed when the command carries
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


def main():
    try:
        d = json.loads(sys.stdin.read() or "{}")
        cmd = (d.get("tool_input") or {}).get("command") or ""
    except Exception:
        return 0
    if d.get("tool_name") != "Bash" or not cmd or "RDOCKER_LOCAL_START=1" in cmd:
        return 0
    if not LAUNCH.search(cmd):
        return 0
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
