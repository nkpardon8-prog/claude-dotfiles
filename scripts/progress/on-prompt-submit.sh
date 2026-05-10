#!/usr/bin/env bash
# UserPromptSubmit hook — initializes ~/.claude/progress/<sid>.json.
# NO `set -e`, NO `set -o pipefail` — failing greps must not abort.
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
[ -z "$SID" ] && exit 0

mkdir -p "$HOME/.claude/progress" 2>/dev/null
chmod 700 "$HOME/.claude/progress" 2>/dev/null

# Extract latest human turn's first slash-command from the transcript.
# Pattern includes `/` so namespaced commands like /parsa/review/all are captured.
OUTER=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  OUTER=$(tail -50 "$TRANSCRIPT" 2>/dev/null \
    | jq -rs '[.[] | select(.type=="user" or .message.role=="user")] | last | (.message.content // .content // "")' 2>/dev/null \
    | head -c 1000 \
    | grep -oE '/[a-z][a-z0-9:_/-]*' 2>/dev/null \
    | head -1)
  OUTER=${OUTER:-}
fi

NOW=$(date +%s)
F="$HOME/.claude/progress/$SID.json"
TMP="$F.tmp.$$"

python3 - "$TMP" "$NOW" "$OUTER" <<'PY' 2>/dev/null
import json, sys
out = {
    "schema_version": 1,
    "prompt_started_at": int(sys.argv[2]),
    "last_tick": int(sys.argv[2]),
    "outer_command": sys.argv[3] or None,
    "overall": {"indeterminate": True, "label": "working"},
    "current": {"indeterminate": True, "label": "starting", "source": "init"},
    "task_spawns": 0,
}
with open(sys.argv[1], "w") as fh: json.dump(out, fh)
PY
[ -f "$TMP" ] && mv "$TMP" "$F"
exit 0
