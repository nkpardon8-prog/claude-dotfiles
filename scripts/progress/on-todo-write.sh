#!/usr/bin/env bash
# PostToolUse[TodoWrite] — drives Bar 1 (overall task progress).
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
F="$HOME/.claude/progress/$SID.json"
[ ! -f "$F" ] && exit 0

DONE=$(echo "$INPUT" | jq '[.tool_input.todos[]? | select(.status=="completed")] | length' 2>/dev/null)
TOTAL=$(echo "$INPUT" | jq '[.tool_input.todos[]?] | length' 2>/dev/null)
ACTIVE=$(echo "$INPUT" | jq -r '[.tool_input.todos[]? | select(.status=="in_progress")][0].activeForm // empty' 2>/dev/null)
{ [ -z "$TOTAL" ] || [ "$TOTAL" = "0" ]; } && exit 0

NOW=$(date +%s)
TMP="$F.tmp.$$"
python3 - "$F" "$TMP" "$DONE" "$TOTAL" "$NOW" "${ACTIVE:-working}" <<'PY' 2>/dev/null
import json, sys
src, tmp, done, total, now, active = sys.argv[1:7]
try:
    with open(src) as fh: s = json.load(fh)
except Exception: sys.exit(0)
s["active"] = True   # a TodoWrite means work is in progress — keep/promote to active
s["overall"] = {"done": int(done), "total": int(total), "label": active, "indeterminate": False}
s["last_tick"] = int(now)
with open(tmp, "w") as fh: json.dump(s, fh)
PY
[ -f "$TMP" ] && mv "$TMP" "$F"
exit 0
