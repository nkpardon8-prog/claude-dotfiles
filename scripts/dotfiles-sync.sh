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

set -o pipefail
LC_ALL=C

DOTFILES_DIR="$HOME/.claude-dotfiles"
cd "$DOTFILES_DIR" || exit 0

# Bail if no changes
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    exit 0
fi

# Pre-push secret scan (working tree + untracked files about to be staged)
if ! "$DOTFILES_DIR/scripts/secret-scan.sh" --working; then
    rc=$?
    case "$rc" in
        2) echo "(secret-scan blocked auto-push)" >&2; exit 2 ;;
        *) echo "(secret-scan failed with exit $rc — refusing to push)" >&2; exit 3 ;;
    esac
fi

# Auto-commit and push
git add -A
git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
git push 2>/dev/null || true
