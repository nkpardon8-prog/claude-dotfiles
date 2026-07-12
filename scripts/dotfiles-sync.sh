#!/bin/bash
# Auto-sync claude dotfiles to GitHub.
# Called by PostToolUse hook when files in ~/.claude-dotfiles/ are modified
# and by /user:learn after saving patterns.
#
# Defense in depth:
#   - Local git pre-commit hook blocks staged secrets (see install-git-hooks.sh)
#   - This script blocks pre-push via secret-scan.sh
#   - Native git pre-push hook also blocks (belt-and-suspenders for manual `git push`)
#   - GitHub Actions runs the same scan on the server side
# All four layers share the same regex from scripts/secret-scan.sh.

# PAUSE GUARD: an out-of-repo marker silences auto-sync entirely (used while agents batch-edit
# the dotfiles machinery, or while pushes are held). Out-of-repo so `git add -A` can never stage it.
[ -f "$HOME/.claude/.dotfiles-sync-paused" ] && exit 0

set -o pipefail
LC_ALL=C

DOTFILES_DIR="$HOME/.claude-dotfiles"
cd "$DOTFILES_DIR" || exit 0

# Bail if no changes
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    exit 0
fi

# Pre-push secret scan (working tree + untracked files about to be staged)
"$DOTFILES_DIR/scripts/secret-scan.sh" --working
rc=$?
case "$rc" in
    0) ;;  # clean — proceed
    2) echo "(secret-scan blocked auto-push)" >&2; exit 2 ;;
    *) echo "(secret-scan failed with exit $rc — refusing to push)" >&2; exit 3 ;;
esac

# PUBLIC-REPO PUSH GUARD — FAIL CLOSED (2026-07-12: the remote was discovered PUBLIC with a
# third-party fork — this repo carries the user's PRIVATE global instructions and must never
# auto-publish them). The PUSH proceeds ONLY on an EXPLICIT isPrivate=true. Every other outcome
# — isPrivate=false, empty (gh not authed / not installed / API error), or a repo with no gh
# view — commits locally but HOLDS the push. Rationale (god-report 2026-07-12, two lenses):
# a silent auto-publish of private instructions is far worse than a stalled sync, and a held
# push is NOT silent — the SessionStart stale-handoff-guard surfaces a PAUSED/held notice with
# the unpushed-commit count every session, so a legitimately-private repo whose gh momentarily
# failed is a visible, recoverable one-liner (re-run this script), not lost work.
_vis=$(gh repo view --json isPrivate -q .isPrivate 2>/dev/null)
git add -A
git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
if [ "$_vis" = "true" ]; then
    git push 2>/dev/null || true
else
    echo "(dotfiles-sync: PUSH HELD — could not confirm the remote is PRIVATE (isPrivate='${_vis:-unknown}'); committed locally only. Confirm the repo is private, then re-run this script to push.)" >&2
    exit 4
fi
