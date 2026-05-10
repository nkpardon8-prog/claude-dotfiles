#!/usr/bin/env bash
# Stop hook — clears state file when prompt completes.
# Deletes the beacon scratch immediately, but DELAYS deleting the main state
# file by 5 seconds so the user can see the bars at completion (otherwise short
# prompts like "hi" only show line 2 for ~1-2s and the user misses it).
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
rm -f "$HOME/.claude/progress/$SID.current.json" 2>/dev/null
# Delayed background delete; nohup + disown so it survives shell exit
( sleep 5 && rm -f "$HOME/.claude/progress/$SID.json" 2>/dev/null ) &
disown 2>/dev/null || true
exit 0
