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

# Resolve THIS window's session id from the harness-injected env var. Every Bash tool call in a
# Claude Code session inherits CLAUDE_CODE_SESSION_ID = this very process's own session id — the
# SAME id the statusline reads from its stdin .session_id, so the file written here is exactly what
# THIS window's renderer reads. It is process-scoped, NOT a filesystem mtime guess, so it can never
# bind to a sibling window — even when other tabs in this same folder are actively writing their
# transcripts at the same moment. (The old `ls -t newest *.jsonl` heuristic lost that race and
# could land your label on another tab; that is the bug this replaces.)
SID=$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && { echo "Could not resolve this window's session id (CLAUDE_CODE_SESSION_ID unset) — run /line again."; exit 0; }

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

The resolved `${SID}` is echoed on purpose: it is the harness-supplied id for THIS window, so
printing it lets you confirm at a glance that the label was written to the right tab. Because the id
comes from `CLAUDE_CODE_SESSION_ID` (this process's own session) and not from a newest-file guess,
it is correct regardless of how many other windows are open in this folder or how busy they are —
run `/line`, switch tabs, keep working; the label lands on this tab only. If the env var is ever
unset the command writes nothing and asks you to re-run, so a label can never land on the wrong tab.
