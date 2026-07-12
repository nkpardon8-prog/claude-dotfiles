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

# PUBLIC-REPO PUSH GUARD (2026-07-12: the remote was discovered PUBLIC with a third-party fork —
# this repo carries the user's private global instructions and must never auto-publish them).
# Block the PUSH only on an EXPLICIT isPrivate=false answer; any gh absence/error proceeds
# (fail-open on infrastructure so a gh hiccup can't silently kill cross-device sync — the
# commit below still happens either way, so nothing is lost while a push is blocked).
_vis=$(gh repo view --json isPrivate -q .isPrivate 2>/dev/null)
if [ "$_vis" = "false" ]; then
    git add -A
    git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
    echo "(dotfiles-sync: PUSH BLOCKED — remote repo is PUBLIC; committed locally only. Flip the repo private, then push.)" >&2
    exit 4
fi

# Auto-commit and push
git add -A
git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
git push 2>/dev/null || true
