#!/usr/bin/env bash
# Stop hook — clears state file when prompt completes.
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
rm -f "$HOME/.claude/progress/$SID.json" "$HOME/.claude/progress/$SID.current.json" 2>/dev/null
exit 0
