#!/usr/bin/env python3
"""
line-ensure-settings.py - make THIS Mac's ~/.claude/settings.json carry what cross-Mac messaging needs.

Why it exists: ~/.claude/settings.json is per-Mac and never synced, so a Mac set up from a partial
copy silently lacks the naming hooks. That is exactly how the Mac mini ended up with no
line-reassert-identity hook, so its windows were unreachable by name from the MacBook (2026-10-16).
A rule in a doc does not fix drift; this runs on every session start (from line-reassert-identity.sh)
and from install-transfer.sh, so each Mac converges on its own.

What it ensures (adds what is missing, never reorders or touches anything else):
  - remoteControlAtStartup: true, crossSessionInbound: "accept"   (windows reachable across Macs)
  - UserPromptSubmit + SessionStart(startup|resume|fork): line-agent-communicator.py session-title
                                       (Remote Control title = peer address, so SendMessage by name works)
  - SessionStart: line-reassert-identity.sh                       (address restored after a reopen,
                                                                   and this script re-run from it)
  - SessionEnd: address-book publish                              (a closed window leaves the list)
and REMOVES the hook entries listed in RETIRED.

Safety: refuses a symlinked or unparseable settings file (prints why, changes nothing); takes a lock
so windows starting together cannot interleave writes; backs the file up before the first change;
writes atomically with the original mode. Prints one summary line (nothing with --quiet unless it
changed something or failed). Exit 0 always, so a hook calling it can never break a session start.
"""
import fcntl
import json
import os
import sys
import time
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))
SETTINGS = Path(os.environ.get("LINE_SETTINGS_FILE", str(HOME / ".claude" / "settings.json")))
LOG = HOME / ".claude" / "logs" / "line-settings.log"

LAC = "python3 $HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
TITLE_CMD = f"{LAC} session-title"
REASSERT_CMD = "bash $HOME/.claude-dotfiles/scripts/hooks/line-reassert-identity.sh"
PUBLISH_CMD = f"{LAC} publish --background --delay 3"

# (event, matcher or None, hook entry). Identity is the command string.
REQUIRED = [
    ("UserPromptSubmit", None, {"type": "command", "command": TITLE_CMD, "timeout": 5}),
    ("SessionStart", "startup|resume|fork", {"type": "command", "command": TITLE_CMD, "timeout": 5}),
    ("SessionStart", "startup|resume|clear|compact",
     {"type": "command", "command": REASSERT_CMD, "timeout": 10, "async": True}),
    ("SessionEnd", None, {"type": "command", "command": PUBLISH_CMD, "timeout": 5}),
]
REQUIRED_KEYS = {"remoteControlAtStartup": True, "crossSessionInbound": "accept"}
# Commands whose hook entries are removed wherever they appear.
RETIRED = []


def log(msg: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        if LOG.exists() and LOG.stat().st_size > 65536:
            LOG.write_bytes(LOG.read_bytes()[-32768:])
        with open(LOG, "a") as fh:
            fh.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg + "\n")
    except Exception:
        pass


def has_command(blocks, cmd: str) -> bool:
    return any(isinstance(b, dict) and any(isinstance(h, dict) and h.get("command") == cmd
                                           for h in b.get("hooks") or [])
               for b in blocks)


def converge(d: dict) -> list[str]:
    """Mutates the parsed settings toward REQUIRED/RETIRED. Returns what changed."""
    changed = []
    for key, value in REQUIRED_KEYS.items():
        if d.get(key) != value:
            d[key] = value
            changed.append(key)
    hooks = d.setdefault("hooks", {})
    for event in list(hooks):
        blocks = hooks[event] if isinstance(hooks[event], list) else []
        for b in blocks:
            if not isinstance(b, dict):
                continue
            kept = [h for h in b.get("hooks") or [] if not (isinstance(h, dict) and h.get("command") in RETIRED)]
            if len(kept) != len(b.get("hooks") or []):
                b["hooks"] = kept
                changed.append(f"removed retired {event} hook")
        pruned = [b for b in blocks if not (isinstance(b, dict) and not b.get("hooks"))]
        if len(pruned) != len(blocks):
            hooks[event] = pruned
    for event, matcher, entry in REQUIRED:
        blocks = hooks.setdefault(event, [])
        if not isinstance(blocks, list):
            raise ValueError(f"hooks.{event} is not a list")
        if has_command(blocks, entry["command"]):
            continue
        target = next((b for b in blocks if isinstance(b, dict) and b.get("matcher") == matcher), None)
        if target is None:
            target = {"matcher": matcher, "hooks": []} if matcher is not None else {"hooks": []}
            blocks.append(target)
        target.setdefault("hooks", []).append(dict(entry))
        changed.append(f"{event} {entry['command'].split('/')[-1]}")
    return changed


def main() -> int:
    quiet = "--quiet" in sys.argv[1:]
    dry = "--dry-run" in sys.argv[1:]

    def say(msg: str, always: bool = False) -> None:
        if always or not quiet:
            print(f"line-ensure-settings: {msg}")

    if SETTINGS.is_symlink():
        say(f"{SETTINGS} is a symlink - not editing it; add the hooks by hand (docs/SETUP.md).", True)
        return 0
    if not SETTINGS.exists():
        say(f"{SETTINGS} is missing - copy settings.json.template there first (docs/SETUP.md).", True)
        return 0
    lock_path = SETTINGS.with_name(".line-ensure-settings.lock")
    try:
        with open(lock_path, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            raw = SETTINGS.read_text()
            try:
                d = json.loads(raw)
                if not isinstance(d, dict):
                    raise ValueError("top level is not an object")
                changed = converge(d)
            except ValueError as e:
                say(f"{SETTINGS} could not be read as settings ({e}) - changed nothing.", True)
                log(f"refused unparseable settings: {e}")
                return 0
            if not changed:
                say("already configured")
                return 0
            if dry:
                say("would change: " + ", ".join(changed), True)
                return 0
            stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
            backup = SETTINGS.with_name(f"{SETTINGS.name}.bak-line-{stamp}")
            backup.write_text(raw)
            mode = SETTINGS.stat().st_mode & 0o777
            tmp = SETTINGS.with_name(f".{SETTINGS.name}.line-tmp")
            tmp.write_text(json.dumps(d, indent=2) + "\n")
            os.chmod(tmp, mode)
            os.replace(tmp, SETTINGS)
            say("updated: " + ", ".join(changed) + f" (backup {backup.name})", True)
            log("updated: " + ", ".join(changed) + f" backup={backup.name}")
    except OSError as e:
        say(f"could not update {SETTINGS} ({e.__class__.__name__}: {e})", True)
        log(f"error {e.__class__.__name__}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
