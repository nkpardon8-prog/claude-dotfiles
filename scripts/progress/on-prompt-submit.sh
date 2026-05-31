#!/usr/bin/env bash
# UserPromptSubmit hook — initializes ~/.claude/progress/<sid>.json (schema v2).
# Marks the session active and starts the elapsed timer. The line-2 renderer owns
# all display logic; this hook just establishes the active state. NO slash-command
# scrape (it mis-captured typed file paths) and NO `current`/`task_spawns` (the
# single-bar renderer derives those from beacons/todos). NO `set -e`/`pipefail`.
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0

mkdir -p "$HOME/.claude/progress" 2>/dev/null
chmod 700 "$HOME/.claude/progress" 2>/dev/null

NOW=$(date +%s)
F="$HOME/.claude/progress/$SID.json"
TMP="$F.tmp.$$"

python3 - "$TMP" "$NOW" <<'PY' 2>/dev/null
import json, sys
out = {
    "schema_version": 2,
    "active": True,
    "prompt_started_at": int(sys.argv[2]),
    "last_tick": int(sys.argv[2]),
    "overall": {"indeterminate": True, "label": "working"},
}
with open(sys.argv[1], "w") as fh: json.dump(out, fh)
PY
[ -f "$TMP" ] && mv "$TMP" "$F"
exit 0
