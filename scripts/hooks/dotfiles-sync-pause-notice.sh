#!/bin/bash
# UserPromptSubmit hook: surface a HELD or BLOCKED dotfiles auto-sync at the next PROMPT,
# not merely at the next session start.
#
# Why this exists: scripts/dotfiles-sync.sh runs from an `async: true` PostToolUse hook,
# so its stderr and its exit status reach nobody. When it blocks (secret found, scan
# failed, commit rejected, push failed, target unresolvable) it writes a pause marker.
# Without this hook the marker is only surfaced at SessionStart, so a sync could stay
# dead for an entire session while edits pile up locally. This shrinks the blind window
# from a whole session to a single turn.
#
# SILENCE INVARIANT: stdout from these hooks is injected into session context (see
# scripts/hooks/stale-handoff-guard.sh:15). Say nothing at all unless something is wrong.

M="$HOME/.claude/.dotfiles-sync-paused"
[ -f "$M" ] || exit 0

reason=$(sed -n 's/^reason: //p' "$M" 2>/dev/null | head -1)
[ -n "$reason" ] || reason="(no reason recorded in the marker)"

echo "dotfiles-sync PAUSED: ${reason} — auto-push to the dotfiles remote is HALTED and local edits are accumulating. Clear with: rm ${M}"
exit 0
