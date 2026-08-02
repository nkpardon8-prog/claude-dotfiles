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

# Guidance is REASON-AWARE on purpose. Telling someone to delete the marker is correct for a
# transient failure, but actively dangerous when a secret triggered the pause: clearing it
# resumes the auto-push and publishes the secret. Lead with rotate-and-remove in that case.
#
# Routed on the marker's machine-written `kind:` field, NEVER by grepping the prose. This
# repo's own work is called "secret-chain", so a substring test reported ordinary pauses as
# credential leaks - and a rotation warning that cries wolf is worse than none. Markers
# written before `kind:` existed have no field and fall through to the generic branch.
kind=$(sed -n 's/^kind: //p' "$M" 2>/dev/null | head -1)
case "$kind" in
    secret)
        echo "dotfiles-sync PAUSED — a secret was detected or could not be ruled out: ${reason}"
        echo "  Auto-push is HALTED. Do NOT simply delete the marker: that resumes pushing to a PUBLIC remote."
        echo "  1) ROTATE the credential at its provider - assume it is already compromised."
        echo "  2) Remove it from the working tree (and from history if it was committed)."
        echo "  3) Confirm clean:  bash ~/.claude-dotfiles/scripts/secret-scan.sh --working"
        echo "  4) Only then:      rm ${M}"
        ;;
    *)
        echo "dotfiles-sync PAUSED: ${reason} — auto-push is HALTED and local commits are accumulating."
        echo "  Fix the cause above, then clear with: rm ${M}"
        ;;
esac
exit 0
