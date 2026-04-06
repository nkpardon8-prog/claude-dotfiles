#!/bin/bash
# Auto-sync claude dotfiles to GitHub
# Called by PostToolUse hook when files in ~/.claude-dotfiles/ are modified
# and by /user:learn after saving patterns

DOTFILES_DIR="$HOME/.claude-dotfiles"

cd "$DOTFILES_DIR" || exit 0

# Check if there are any changes to commit
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    exit 0  # Nothing to sync
fi

# Auto-commit and push
git add -A
git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
git push 2>/dev/null || true
