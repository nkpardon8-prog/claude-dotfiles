#!/usr/bin/env bash
# SessionStart cleanup — removes progress files older than 7 days.
mkdir -p "$HOME/.claude/progress" 2>/dev/null
chmod 700 "$HOME/.claude/progress" 2>/dev/null
find "$HOME/.claude/progress" -type f -mtime +7 -delete 2>/dev/null
exit 0
