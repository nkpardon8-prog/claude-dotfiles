#!/usr/bin/env bash
# PostToolUse[Task] — drives Bar 2 (current command progress).
# Atomically claims any beacon scratch file, else falls back to spawn-count.
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
F="$HOME/.claude/progress/$SID.json"
[ ! -f "$F" ] && exit 0
SUBAGENT=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "agent"' 2>/dev/null)
NOW=$(date +%s)
BEACON="$HOME/.claude/progress/$SID.current.json"
TMP="$F.tmp.$$"

python3 - "$F" "$TMP" "$NOW" "$SUBAGENT" "$BEACON" <<'PY' 2>/dev/null
import json, sys, os, re, glob
src, tmp, now, sub, beacon = sys.argv[1:6]
try:
    with open(src) as fh: s = json.load(fh)
except Exception: sys.exit(0)

s["task_spawns"] = s.get("task_spawns", 0) + 1
s["last_tick"] = int(now)

# Atomic beacon claim — eliminates TOCTOU between exists() and remove()
beacon_data = None
claimed = beacon + ".merging"
try:
    os.rename(beacon, claimed)
    with open(claimed) as fh: beacon_data = json.load(fh)
    os.remove(claimed)
except FileNotFoundError: pass
except Exception:
    try: os.remove(claimed)
    except Exception: pass

if beacon_data:
    s["current"] = {
        "cmd": s.get("outer_command") or beacon_data.get("cmd","cmd"),
        "step": int(beacon_data.get("step", 0)),
        "total": int(beacon_data["total"]) if beacon_data.get("total") else None,
        "label": beacon_data.get("label") or "working",
        "indeterminate": not beacon_data.get("total"),
        "source": "beacon",
    }
elif s.get("current", {}).get("source") != "beacon":
    # Frontmatter fallback. Handles namespaced commands: /parsa/review/all → parsa/review/all.md
    total = None
    cmd = (s.get("outer_command") or "").lstrip("/")
    if cmd:
        home = os.path.expanduser("~")
        direct = f"{home}/.claude-dotfiles/commands/{cmd}.md"
        if os.path.exists(direct):
            candidates = [direct]
        else:
            candidates = (glob.glob(f"{home}/.claude-dotfiles/commands/{cmd}.md")
                        + glob.glob(f"{home}/.claude-dotfiles/commands/**/{os.path.basename(cmd)}.md", recursive=True))
        for c in candidates:
            try:
                txt = open(c).read()
                m = re.search(r"^expected_subagents:\s*(\d+)", txt, re.M)
                if m: total = int(m.group(1)); break
            except Exception: pass
    s["current"] = {
        "cmd": s.get("outer_command") or "agent",
        "step": s["task_spawns"],
        "total": total,
        "label": sub,
        "indeterminate": total is None,
        "source": "task-count",
    }

with open(tmp, "w") as fh: json.dump(s, fh)
PY
[ -f "$TMP" ] && mv "$TMP" "$F"
exit 0
