#!/bin/bash
# Auto-sync claude dotfiles to GitHub.
# Called by PostToolUse hook when files in ~/.claude-dotfiles/ are modified
# and by /user:learn after saving patterns.
#
# Pre-push secret scan: if any tracked or about-to-be-tracked file matches a
# known secret shape, the push is BLOCKED (exit 2). Failures are fail-closed —
# if we can't build the file list or run grep, we refuse to push.

set -o pipefail
LC_ALL=C  # avoid locale-dependent grep failures on non-UTF-8 input

DOTFILES_DIR="$HOME/.claude-dotfiles"
cd "$DOTFILES_DIR" || exit 0

# Bail if no changes
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    exit 0
fi

# Pattern set: prefix-anchored token shapes for major providers + PEM headers.
# Specific enough to keep false positives rare. KEEP IN SYNC with the
# SessionStart regex in ~/.claude/settings.json.
RX='(sk-(ant|proj|svcacct)?-?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|ghu_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}|ghr_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|ya29\.[A-Za-z0-9_-]{20,}|whsec_[A-Za-z0-9]{20,}|(rk|sk|pk)_(live|test)_[A-Za-z0-9]{20,}|-----BEGIN +(RSA +|OPENSSH +)?PRIVATE +KEY-----)'
export RX

# Build candidate file list (NUL-delimited so spaces/newlines in paths are fine).
FILES_LIST=$(mktemp -t dotfiles-sync-files.XXXXXX) || {
    echo "BLOCKED: could not create temp file for scan list — refusing to push." >&2
    exit 3
}
trap 'rm -f "$FILES_LIST"' EXIT INT TERM

if ! { git diff --name-only -z HEAD; git ls-files --others --exclude-standard -z; } | sort -uz > "$FILES_LIST"; then
    echo "BLOCKED: could not enumerate changed files — refusing to push." >&2
    exit 3
fi

# Bail if nothing to scan (defensive — the earlier "no changes" check should catch this)
if [ ! -s "$FILES_LIST" ]; then
    exit 0
fi

# Scan each candidate file. -I makes grep skip binary files (treats as no match).
# We tee grep stderr to detect runtime failures; on any sh-level error we fail closed.
HITS=$(
    xargs -0 -I {} sh -c '
        f="$1"
        [ -f "$f" ] || exit 0
        case "$f" in *.git/*|.git/*) exit 0 ;; esac
        grep -InIEH -e "$RX" -- "$f"
    ' _ {} < "$FILES_LIST" 2>/tmp/.dotfiles-sync-grep-err.$$
)
SCAN_RC=$?
GREP_ERRS=$(cat /tmp/.dotfiles-sync-grep-err.$$ 2>/dev/null)
rm -f /tmp/.dotfiles-sync-grep-err.$$

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
        echo "False positive (e.g. AWS docs example, sample PEM)? Move it into a fenced"
        echo "code block and the scanner still hits, so consider relocating to a non-tracked"
        echo "fixture file or rewriting the example."
    } >&2
    exit 2
fi

# Fail closed if scan setup failed
if [ "$SCAN_RC" -ne 0 ] && [ -n "$GREP_ERRS" ]; then
    echo "BLOCKED: scan errors encountered — refusing to push:" >&2
    echo "$GREP_ERRS" >&2
    exit 3
fi

# Auto-commit and push
git add -A
git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
git push 2>/dev/null || true
