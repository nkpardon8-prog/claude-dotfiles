#!/bin/bash
# Shared secret-scanner. Used by:
#   - scripts/dotfiles-sync.sh  (PostToolUse auto-push)
#   - .git/hooks/pre-commit     (blocks local commit)
#   - .git/hooks/pre-push       (blocks manual push)
#   - .github/workflows/secret-scan.yml (CI)
#
# Usage: secret-scan.sh <file> [<file> ...]
#        secret-scan.sh --staged       # scan staged files
#        secret-scan.sh --working      # scan tracked + untracked working files
#        secret-scan.sh --all-history  # scan every blob in every commit (slow)
#
# Exit codes:
#   0 = clean
#   2 = secret(s) detected (caller should block)
#   3 = scan failure (caller should fail closed)

set -o pipefail
LC_ALL=C

RX='(sk-(ant|proj|svcacct)?-?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|ghu_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}|ghr_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|ya29\.[A-Za-z0-9_-]{20,}|whsec_[A-Za-z0-9]{20,}|(rk|sk|pk)_(live|test)_[A-Za-z0-9]{20,}|-----BEGIN +(RSA +|OPENSSH +|EC +|DSA +|PGP +)?PRIVATE +KEY-----)'
export RX

scan_file() {
    f="$1"
    [ -f "$f" ] || return 0
    case "$f" in *.git/*|.git/*) return 0 ;; esac
    match=$(tr -d "\000" < "$f" | grep -anEH -e "$RX")
    [ -n "$match" ] && printf "%s:%s\n" "$f" "$match"
}

case "${1:-}" in
    --staged)
        FILES=$(git diff --cached --name-only --diff-filter=ACMR -z | tr '\0' '\n')
        ;;
    --working)
        FILES=$( { git diff --name-only -z HEAD; git ls-files --others --exclude-standard -z; } | sort -uz | tr '\0' '\n')
        ;;
    --all-history)
        # Scan every blob in every commit (slow — for one-time audit)
        HITS=""
        while read -r sha; do
            while read -r f; do
                content=$(git show "$sha:$f" 2>/dev/null | tr -d '\000')
                m=$(printf '%s' "$content" | grep -anEH -e "$RX" 2>/dev/null)
                [ -n "$m" ] && HITS="$HITS$sha:$f:$m\n"
            done < <(git ls-tree -r --name-only "$sha")
        done < <(git rev-list --all)
        if [ -n "$HITS" ]; then printf "%b" "$HITS" >&2; exit 2; fi
        exit 0
        ;;
    "")
        echo "Usage: $0 [--staged|--working|--all-history|<file>...]" >&2
        exit 3
        ;;
    *)
        FILES="$*"
        FILES=$(printf '%s\n' $FILES)
        ;;
esac

[ -z "$FILES" ] && exit 0

HITS=""
while IFS= read -r f; do
    [ -z "$f" ] && continue
    out=$(scan_file "$f") && [ -n "$out" ] && HITS="$HITS$out\n"
done <<< "$FILES"

if [ -n "$HITS" ]; then
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "BLOCKED: secret detected. Aborting."
        echo "═══════════════════════════════════════════════════════════════"
        printf "%b" "$HITS"
        echo ""
        echo "Action: remove the secret, ROTATE it at the provider, then retry."
        echo "If false positive: relocate the example into a non-tracked fixture."
    } >&2
    exit 2
fi

exit 0
