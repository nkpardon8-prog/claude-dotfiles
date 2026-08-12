---
description: "Name this window once - sets the statusline caption AND the address other agents message it by."
argument-hint: "[sentence]"
allowed-tools: Bash
---

# /line — name this window (caption + peer address, one step)

Name THIS Claude Code window with one sentence. `/line` sets **both** names a window has:

1. **the statusline caption** — the second line, so you can tell many open windows apart at a glance
2. **the peer address** — a short handle derived from your sentence (`patient retention` →
   `patient-retention`) written into the session registry, which is what `ListAgents` displays and
   what `SendMessage` resolves

Those were two unrelated names before, stored in two places that never referenced each other. A
window captioned "summit admin hub" was addressable only as `dentall-ae`, so asking an agent to
"message my summit admin hub agent" could not work — the caption was cosmetic and nothing could
translate it. One `/line` now sets both, so the name you type IS the address.

With no argument it clears the caption. The peer address is deliberately left alone: clearing a
caption should never make a window unreachable while someone is mid-conversation with it.

Run exactly this Bash, then report its output to the user verbatim (do not editorialize):

```bash
set -uo pipefail   # partial-failure tolerant, matches statusline.sh convention (NO -e)

# Resolve THIS window's session id from the harness-injected env var — the SAME way /mission,
# /pre-compact and /post-compact-resume do (`$CLAUDE_SESSION_ID` then `$CLAUDE_CODE_SESSION_ID`),
# never by transcript mtime. Every Bash tool call inherits its own process's session id, which is
# exactly the id the statusline reads from its stdin .session_id, so the caption written here is
# what THIS window renders. It is process-scoped, NOT a filesystem guess, so it can never bind to a
# sibling window — even when other tabs in this same folder are writing at the same moment. (The old
# `ls -t newest *.jsonl` heuristic lost that race and could land your label on another tab.)
export CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"

python3 "$HOME/.claude-dotfiles/scripts/line-agent-communicator.py" set "${ARGUMENTS:-}"
```

## Finding and messaging other windows

To see every live window — its address, what it is, and whether it can actually receive a message:

```bash
python3 "$HOME/.claude-dotfiles/scripts/line-agent-communicator.py" list
```

Add `--json` for a machine-readable form. Message a window with `SendMessage` using the `ADDRESS`
column. The `CAN RECEIVE` column matters: cross-session messaging arrived in Claude Code **2.1.224**
and the receiving socket is bound at startup, so a window running an older build cannot be messaged
until it is **closed and reopened** — upgrading alone is not enough. The listing says which windows
are in that state and why, so you never send into a void.

## Notes

- Handles are lowercased and hyphenated, trimmed to 40 chars on a word boundary. If another live
  window already holds that handle a numeric suffix is added, because two windows sharing a name is
  what forces callers back to opaque refs.
- Setting the peer address writes the session registry directly. The supported ways to name a
  session are `claude -n <name>` at startup and `/rename` typed by a human — neither can be driven
  from a slash command, so this writes the file itself, defensively: it finds its own entry by
  `sessionId`, preserves every field it does not own, and writes atomically. Verified on 2.1.227 and
  2.1.228 that the harness re-saves the file on each status change and preserves a name marked
  `nameSource: "explicit"`.
- If a future version stops honouring that, `/line` degrades to caption-only and says so out loud;
  the caption and the `list` directory keep working, so discovery never breaks silently.
