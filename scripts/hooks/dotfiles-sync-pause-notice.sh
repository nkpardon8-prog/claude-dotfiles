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
        echo "dotfiles-sync PAUSED — a secret was DETECTED: ${reason}"
        echo "  Auto-push is HALTED. Do NOT simply delete the marker: that resumes pushing to a PUBLIC remote."
        echo "  1) ROTATE the credential at its provider - assume it is already compromised."
        echo "  2) Remove it from the working tree (and from history if it was committed)."
        # The `cd` is load-bearing, not tidiness: --working enumerates REPO-ROOT-RELATIVE
        # paths, so run from anywhere else it used to scan nothing and answer "clean" - on
        # the one command a human runs to confirm a CONFIRMED leak is gone, immediately
        # before deleting the marker and resuming pushes to a PUBLIC remote. The scanner now
        # cd's to the repo root itself, so this is belt-and-braces; keep them in step.
        echo "  3) Confirm clean:  cd ~/.claude-dotfiles && bash scripts/secret-scan.sh --working"
        echo "  4) Only then:      rm ${M}"
        ;;
    unproven)
        # rc=3 from the gate: NOT a confirmed leak, but the range was never proven clean, so
        # "clear it and retry" would push unverified bytes to a public remote. Distinct wording
        # from `secret` on purpose - telling someone to rotate a credential that may not exist
        # is the cry-wolf failure this field was introduced to avoid.
        echo "dotfiles-sync PAUSED — the secret gate could not PROVE the pushed range clean: ${reason}"
        echo "  Auto-push is HALTED. This is not a confirmed leak, but nothing has been verified either."
        echo "  1) Fix the cause above (missing scanner, unusable TMPDIR, unreadable range)."
        echo "  2) rm ${M}"
        echo "  3) Re-prove by RETRYING THE PUSH: bash ~/.claude-dotfiles/scripts/dotfiles-sync.sh"
        echo "     The pre-push hook re-scans the whole range, commit messages included, and"
        echo "     blocks again if it still cannot prove it - so the gate itself is the proof."
        echo "     (NOT secret-scan.sh --working: that reads the WORKING TREE only and cannot"
        echo "      say anything about queued commits or their messages.)"
        ;;
    *)
        echo "dotfiles-sync PAUSED: ${reason} — auto-push is HALTED and local commits are accumulating."
        echo "  Fix the cause above, then clear with: rm ${M}"
        ;;
esac
exit 0
