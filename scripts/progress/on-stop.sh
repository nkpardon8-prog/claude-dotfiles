#!/usr/bin/env bash
# Stop hook — marks the session idle when a prompt completes (does NOT delete the
# state file). Keeping the file means line 2 falls cleanly to the idle label with
# no flicker and never vanishes between prompts. The next UserPromptSubmit overwrites
# it back to active; the SessionStart cleanup GCs files older than 7 days.
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
rm -f "$HOME/.claude/progress/$SID.current.json" 2>/dev/null
rm -f "$HOME/.claude/progress/$SID.activity.json" 2>/dev/null
F="$HOME/.claude/progress/$SID.json"
[ ! -f "$F" ] && exit 0
TMP="$F.tmp.$$"
python3 - "$F" "$TMP" <<'PY' 2>/dev/null
import json, sys, os
src, tmp = sys.argv[1], sys.argv[2]
try:
    with open(src) as fh: s = json.load(fh)
except Exception: sys.exit(0)
s["active"] = False
for k in ("prompt_started_at", "current", "overall"):
    s.pop(k, None)
with open(tmp, "w") as fh: json.dump(s, fh)
os.replace(tmp, src)   # atomic — never expose a truncated file to the renderer
PY
exit 0
