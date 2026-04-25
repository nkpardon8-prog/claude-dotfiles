#!/bin/bash
# Auto-sync claude dotfiles to GitHub
# Called by PostToolUse hook when files in ~/.claude-dotfiles/ are modified
# and by /user:learn after saving patterns
#
# HARD STOP if any tracked file appears to contain a real secret. We never push
# silently — a leak detected here means rotate the secret AND fix the file.

set -o pipefail

DOTFILES_DIR="$HOME/.claude-dotfiles"
cd "$DOTFILES_DIR" || exit 0

# Nothing changed → bail
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    exit 0
fi

# ---------- Pre-push secret scan ----------
# Scan all files that would be added to the next commit (tracked-with-changes
# + untracked-but-not-gitignored). BLOCKS the push on any match.

# Patterns: prefix-anchored token shapes for major providers + PEM headers.
# Each pattern is intentionally specific to keep false positives low.
PATTERNS='(
  sk-(ant|proj|svcacct)?-?[A-Za-z0-9_-]{20,}|
  AIza[0-9A-Za-z_-]{35}|
  ghp_[A-Za-z0-9]{36,}|
  gho_[A-Za-z0-9]{36,}|
  ghu_[A-Za-z0-9]{36,}|
  ghs_[A-Za-z0-9]{36,}|
  ghr_[A-Za-z0-9]{36,}|
  github_pat_[A-Za-z0-9_]{40,}|
  AKIA[0-9A-Z]{16}|
  ASIA[0-9A-Z]{16}|
  xox[abposr]-[A-Za-z0-9-]{10,}|
  hf_[A-Za-z0-9]{30,}|
  ya29\.[A-Za-z0-9_-]{20,}|
  whsec_[A-Za-z0-9]{20,}|
  rk_(live|test)_[A-Za-z0-9]{20,}|
  sk_(live|test)_[A-Za-z0-9]{20,}|
  pk_(live|test)_[A-Za-z0-9]{20,}|
  -----BEGIN[[:space:]]+(RSA[[:space:]]+)?PRIVATE[[:space:]]+KEY-----|
  -----BEGIN[[:space:]]+OPENSSH[[:space:]]+PRIVATE[[:space:]]+KEY-----
)'
# Compact to one line for grep -E
RX=$(echo "$PATTERNS" | tr -d '\n ' )

# Files to scan: changed-tracked + untracked-not-ignored (binary files excluded by -I)
FILES_TO_SCAN=$( { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u )

if [ -n "$FILES_TO_SCAN" ]; then
  HITS=$(printf '%s\n' "$FILES_TO_SCAN" | xargs -I {} sh -c 'test -f "{}" && grep -InEH "$0" "{}" 2>/dev/null' "$RX" -I)
  if [ -n "$HITS" ]; then
    echo "═══════════════════════════════════════════════════════════════" >&2
    echo "BLOCKED: dotfiles auto-push aborted — possible secret detected." >&2
    echo "═══════════════════════════════════════════════════════════════" >&2
    echo "$HITS" >&2
    echo "" >&2
    echo "Action:" >&2
    echo "  1. Remove the secret from the file." >&2
    echo "  2. ROTATE the leaked credential at the provider (assume it's compromised)." >&2
    echo "  3. If already committed: 'git reset HEAD~1' before this script ran, OR rewrite history with git-filter-repo." >&2
    echo "  4. Re-run after cleanup." >&2
    exit 2
  fi
fi

# ---------- Auto-commit and push (clean) ----------
git add -A
git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
git push 2>/dev/null || true
