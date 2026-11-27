#!/usr/bin/env python3
"""settings-drift-check.py - tell a window when this Mac's ~/.claude/settings.json drifted from the
keys every Mac must share.

Why (2026-11-27): ~/.claude/settings.json is per-machine and not synced. Twice in two days the Mac
mini drifted from the Air on cost-relevant keys (autoCompactEnabled:false turned compaction off;
a missing subagentPromptCacheTtl cost about 8.5% of spend).

Source of truth: the "_sync_required" block of ~/.claude-dotfiles/settings.json.template. Each
non-underscore key must equal its value; "_forbidden" lists keys that must be absent or not false.

Prints NOTHING when everything matches. On drift prints one short block naming only the drifted
keys. Malformed JSON prints one warning line. Always exits 0: it never blocks a session.
Called at main-window SessionStart by scripts/hooks/rules-in-force.py (report()), or run by hand.
"""
from __future__ import annotations

import json
import socket
import sys
from pathlib import Path

FIX = ("Fix: back up ~/.claude/settings.json, set those keys, validate with jq. "
       "A settings change needs the owner's OK typed in a window on this machine.")


def _show(value) -> str:
    """A local value, short. Only the listed keys are ever shown, never anything else."""
    text = json.dumps(value)
    return text if len(text) <= 24 else f"<{type(value).__name__}>"


def _same(a, b) -> bool:
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)   # False != 0, 0.01 == 0.01


def report(home: Path | None = None) -> str:
    home = home or Path.home()
    template = home / ".claude-dotfiles/settings.json.template"
    settings = home / ".claude/settings.json"
    try:
        required = json.loads(template.read_text()).get("_sync_required")
    except (OSError, ValueError) as e:
        return f"settings-drift-check: could not read {template.name} ({e.__class__.__name__}); drift not checked."
    if not isinstance(required, dict):
        return ""
    try:
        local = json.loads(settings.read_text())
    except OSError:
        local = {}
    except ValueError:
        return "settings-drift-check: ~/.claude/settings.json is not valid JSON; drift not checked."
    if not isinstance(local, dict):
        return "settings-drift-check: ~/.claude/settings.json is not a JSON object; drift not checked."

    drift = []
    for key, want in required.items():
        if key.startswith("_"):
            continue
        if key not in local:
            drift.append(f"{key} is absent, should be {json.dumps(want)}")
        elif not _same(local[key], want):
            drift.append(f"{key} is {_show(local[key])}, should be {json.dumps(want)}")
    for key in required.get("_forbidden") or []:
        if isinstance(key, str) and key in local and local[key] is False:
            drift.append(f"{key} is false, should be absent")
    if not drift:
        return ""
    host = socket.gethostname().split(".")[0]
    return f"SETTINGS DRIFT on {host}: " + "; ".join(drift) + "\n" + FIX


def main() -> int:
    try:
        out = report()
    except Exception as e:   # never block: one line, exit 0
        out = f"settings-drift-check: failed ({e.__class__.__name__}); drift not checked."
    if out:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
