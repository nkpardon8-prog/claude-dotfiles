#!/usr/bin/env bash
# PostToolUse[Task] — drives the single line-2 bar ONLY when a command publishes a
# beacon (e.g. /god-review via emit-beacon.sh). Atomically claims the beacon scratch
# file and writes `current` with source="beacon". With no beacon, it just bumps
# last_tick so the renderer's stalled-color logic stays fresh during long Task phases.
# NO task-spawn-count fallback and NO command-frontmatter glob — those produced a
# meaningless bar; the renderer falls back to the to-do bar / spinner instead.
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
F="$HOME/.claude/progress/$SID.json"
[ ! -f "$F" ] && exit 0
NOW=$(date +%s)
BEACON="$HOME/.claude/progress/$SID.current.json"
TMP="$F.tmp.$$"

python3 - "$F" "$TMP" "$NOW" "$BEACON" <<'PY' 2>/dev/null
import json, sys, os
src, tmp, now, beacon = sys.argv[1:5]
try:
    with open(src) as fh: s = json.load(fh)
except Exception: sys.exit(0)

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
    total = int(beacon_data["total"]) if beacon_data.get("total") else None
    s["current"] = {
        "source": "beacon",
        "step": int(beacon_data.get("step", 0)),
        "total": total,
        "label": beacon_data.get("label") or "working",
        "indeterminate": total is None,
    }

with open(tmp, "w") as fh: json.dump(s, fh)
PY
[ -f "$TMP" ] && mv "$TMP" "$F"
exit 0
