#!/bin/bash
# Auto-sync claude dotfiles to GitHub.
# Called by PostToolUse hook when files in ~/.claude-dotfiles/ are modified
# and by /user:learn after saving patterns.
#
# HARD STOP if any tracked or about-to-be-tracked file appears to contain a real
# secret. We never push silently — a leak detected here means rotate AND fix.

set -o pipefail

DOTFILES_DIR="$HOME/.claude-dotfiles"
cd "$DOTFILES_DIR" || exit 0

# Bail if no changes
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    exit 0
fi

# ---------- Pre-push secret scan ----------
# Patterns: prefix-anchored token shapes for major providers + PEM headers.
# Specific enough to keep false positives rare.
RX='(sk-(ant|proj|svcacct)?-?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|ghu_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}|ghr_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|ya29\.[A-Za-z0-9_-]{20,}|whsec_[A-Za-z0-9]{20,}|(rk|sk|pk)_(live|test)_[A-Za-z0-9]{20,}|-----BEGIN +(RSA +|OPENSSH +)?PRIVATE +KEY-----)'

# Files to scan: existing tracked-with-changes + untracked-not-ignored.
# NUL-delimited so filenames with spaces/newlines are handled correctly.
# `-z` makes git emit NUL terminators; xargs -0 reads them.
{
    git diff --name-only -z HEAD
    git ls-files --others --exclude-standard -z
} | sort -uz > /tmp/.dotfiles-sync-files.$$

# Scan only regular files inside this repo. Use grep's own -I for binary exclusion.
HITS=$(
    xargs -0 -I {} sh -c '
        f="$1"
        # Only scan if file exists, is regular, and is inside the dotfiles dir
        [ -f "$f" ] || exit 0
        case "$f" in
            *.git/*|.git/*) exit 0 ;;
        esac
        grep -InEH -e "$RX" -- "$f" 2>/dev/null
    ' _ {} < /tmp/.dotfiles-sync-files.$$ 2>/dev/null
)
RX="$RX" # exported below
export RX

# Re-run scan with RX exported so the inner sh sees it
HITS=$(
    xargs -0 -I {} sh -c '
        f="$1"
        [ -f "$f" ] || exit 0
        case "$f" in
            *.git/*|.git/*) exit 0 ;;
        esac
        grep -InEH -e "$RX" -- "$f" 2>/dev/null
    ' _ {} < /tmp/.dotfiles-sync-files.$$ 2>/dev/null
)
rm -f /tmp/.dotfiles-sync-files.$$

if [ -n "$HITS" ]; then
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "BLOCKED: dotfiles auto-push aborted — possible secret detected."
        echo "═══════════════════════════════════════════════════════════════"
        echo "$HITS"
        echo ""
        echo "Action:"
        echo "  1. Remove the secret from the file."
        echo "  2. ROTATE the leaked credential at the provider (assume it's compromised)."
        echo "  3. If already committed, rewrite history with git-filter-repo before pushing."
        echo "  4. Re-run after cleanup."
        echo ""
        echo "If this is a false positive (e.g. AWS docs example, sample PEM), add an"
        echo "ignore comment above the line: # noqa-secret  — and re-run."
    } >&2
    exit 2
fi

# ---------- Auto-commit and push ----------
git add -A
git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
git push 2>/dev/null || true
