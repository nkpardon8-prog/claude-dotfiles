---
description: "Set this window's statusline line 2 to a sentence; no args clears it back to the repo name."
argument-hint: "[sentence]"
allowed-tools: Bash
---

# /line — set this window's statusline second line

Set the **second line** of the statusline for THIS Claude Code window to a sentence you type, so
you can tell your many simultaneous windows apart at a glance. It is per-window: each instance shows
its own label. With no argument, it clears back to the default (the folder/repo name).

Run exactly this Bash, then report its output to the user verbatim (do not editorialize):

```bash
set -uo pipefail   # partial-failure tolerant, matches statusline.sh convention (NO -e)

# Resolve THIS window's session id. The transcript filename basename == the statusline's stdin
# .session_id, so the file written here is exactly what the renderer reads. Handles spaces in the
# cwd; single leading dash. The newest *.jsonl in the project dir is THIS window's transcript,
# because the user's own /line prompt was just appended to it moments ago.
PROJDIR=$(pwd | sed 's|[/ ]|-|g')
SID=$(ls -t "$HOME/.claude/projects/$PROJDIR/"*.jsonl 2>/dev/null | head -1 | xargs -I {} basename {} .jsonl)
SID=$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && { echo "Could not resolve this window's session id yet — try again in a moment."; exit 0; }

DIR="$HOME/.claude/session-status"
mkdir -p "$DIR" && chmod 700 "$DIR"
F="$DIR/$SID.txt"

ARGS="${ARGUMENTS:-}"                       # the sentence the user typed (may be empty)
TRIMMED="$(printf '%s' "$ARGS" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [ -z "$TRIMMED" ]; then
  rm -f "$F" 2>/dev/null
  echo "Cleared status line for window ${SID} — line 2 reverts to the folder/repo name on the next statusline render."
else
  printf '%s\n' "$TRIMMED" > "$F"           # single line; overwrites any prior label
  echo "Status line set for window ${SID}: ${TRIMMED}"
  echo "(updates on the next statusline render)"
fi
```

The resolved `${SID}` is echoed on purpose: if you have 2+ windows open in the *same folder*, the
newest-transcript resolution could in rare cases bind to a sibling window — printing the id makes
that visible so you can confirm it's this window (or just re-run `/line` here). This is a cosmetic
label; no heavier machinery is warranted.
