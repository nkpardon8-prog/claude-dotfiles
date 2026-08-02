#!/bin/bash
# Shared secret-scanner. Used by:
#   - scripts/dotfiles-sync.sh  (PostToolUse auto-push)
#   - .git/hooks/pre-commit     (blocks local commit)
#   - .git/hooks/pre-push       (blocks manual push)
#   - .github/workflows/secret-scan.yml (CI)
#
# Usage: secret-scan.sh [--] <file> [<file> ...]
#        secret-scan.sh --patch <file> # one file of composite patch/message text, PRIMARY
#                                      #   pattern only (no path-aware lanes). Pre-push uses this.
#        secret-scan.sh --staged       # scan staged files (reads INDEX blobs, not worktree bytes)
#        secret-scan.sh --working      # scan tracked + untracked working files
#        secret-scan.sh --all-history  # COARSE audit over every blob in every commit (slow).
#                                      #   Primary RX only: it does NOT apply the CRD/PIN lane
#                                      #   and does NOT honor the rc=3 contract. One-time use.
#
# Exit codes:
#   0 = clean
#   2 = secret(s) detected (caller should block)
#   3 = scan failure (caller should fail closed)
#
# Precedence is 3 > 2 > 0: if ANY input could not be proven clean, the run exits 3 even
# when another input produced a real hit. "Could not prove clean" is never reported as clean.
#
# SCOPE: this chain defends against ACCIDENTAL exposure. It is NOT a defense against
# deliberate circumvention by the person pushing (--no-verify, core.hooksPath, BASH_ENV,
# PATH shims, or editing this file). See docs/SECURITY-secret-chain.md.

set -o pipefail
export LC_ALL=C

RX='(sk-(ant|proj|svcacct)?-?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|ghu_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}|ghr_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|ya29\.[A-Za-z0-9_-]{20,}|whsec_[A-Za-z0-9]{20,}|(rk|sk|pk)_(live|test)_[A-Za-z0-9]{20,}|-----BEGIN +(RSA +|OPENSSH +|EC +|DSA +|PGP +)?PRIVATE +KEY-----)'
export RX

# Mac mini CRD skill secondary patterns (path-aware allowlisting applied per-file)
RX_PIN='([Pp][Ii][Nn]|CRD_PIN)[^A-Za-z0-9]*[=:]?[^A-Za-z0-9]*[0-9]{6}([^0-9]|$)'
export RX_PIN

# Path-based allowlist for the secondary (CRD) patterns. These paths intentionally
# discuss formats in the abstract or live in scratch dirs.
crd_path_allowed() {
    case "$1" in
        tmp/briefs/*|tmp/ready-plans/*|tmp/done-plans/*|*/tmp/briefs/*|*/tmp/ready-plans/*|*/tmp/done-plans/*) return 0 ;;
        skills/macmini/README.md|*/skills/macmini/README.md) return 0 ;;
    esac
    return 1
}

# scan_stdin <label>
# Reads candidate content on STDIN so the same matcher serves worktree files and index blobs.
# Prints "<label>:<lineno>:<match>" lines on STDOUT.
# Returns: 0 clean, 2 hit, 3 scan failure.
#
# Every filter's status is checked. grep exits 0=match, 1=no-match, >1=error; treating an
# error as "no match" is precisely how a broken scanner reports a secret-bearing file clean.
scan_stdin() {
    f="$1"
    content=$(tr -d "\000") || return 3

    hits=$(printf '%s' "$content" | grep -anE -e "$RX"); rc=$?
    [ "$rc" -gt 1 ] && return 3

    # In --patch mode the label is a temp file holding concatenated patch text, so the
    # path-aware PIN lane cannot mean anything and is skipped entirely (see --patch below).
    if [ "${MODE:-file}" != patch ] && ! crd_path_allowed "$f"; then
        m=$(printf '%s' "$content" | grep -anE -e "$RX_PIN"); rc=$?
        [ "$rc" -gt 1 ] && return 3
        if [ -n "$m" ]; then
            # Drop a line ONLY when the PIN's own VALUE is a placeholder. Filtering on the
            # whole line let a real secret hide behind an unrelated mention: a line reading
            # "<pin-key>=<real six digits>" followed by a comment that happens to name a
            # placeholder value was silently accepted in full.
            # (Deliberately described rather than shown - a literal example here would be a
            #  true positive against this repo's own full-tree scan. It was, once.)
            m=$(printf '%s' "$m" | grep -vE '([Pp][Ii][Nn]|CRD_PIN)[^A-Za-z0-9]*[=:]?[^A-Za-z0-9]*(000000|123456|XXXXXX)'); rc=$?
            [ "$rc" -gt 1 ] && return 3
        fi
        # Written as an explicit if rather than ${hits:+$'\n'}: bash expands that form
        # correctly, but zsh does not (it splices the literal characters), and these
        # scripts get probed and sourced from both. The explicit form is unambiguous.
        if [ -n "$m" ]; then
            if [ -n "$hits" ]; then
                hits=$(printf '%s\n%s' "$hits" "$m")
            else
                hits="$m"
            fi
        fi
    fi

    [ -z "$hits" ] && return 0
    # Prefix the label WITHOUT interpolating it into a sed program. `sed "s|^|$f:|"` breaks
    # on any filename containing the delimiter `|`, a backslash, or a newline - probed: a
    # newline in the name made the sed script invalid and turned a real hit into rc=3.
    while IFS= read -r line; do
        printf '%s:%s\n' "$f" "$line"
    done <<< "$hits"
    return 2
}

# scan_file <path> — scans the WORKTREE bytes at <path>.
# Returns: 0 clean, 2 hit, 3 scan failure.
scan_file() {
    f="$1"
    # Anchor on a real .git path component. The old `*.git/*` also matched ordinary
    # paths such as vendor/leak.git/secret.txt, which silently skipped them everywhere.
    case "$f" in .git/*|*/.git/*) return 0 ;; esac
    [ -f "$f" ] || return 0      # absent or non-regular: nothing to publish
    [ -r "$f" ] || return 3      # present but unreadable: cannot prove clean
    scan_stdin "$f" < "$f"; rc=$?
    [ "$rc" -eq 1 ] && return 3  # scan_stdin never returns 1; a 1 means the redirect failed
    return "$rc"
}

usage() {
    echo "Usage: $0 [--staged|--working|--all-history|--patch <file>|[--] <file>...]" >&2
}

# Enumeration goes through a NUL-delimited temp file, never a newline-delimited scalar:
# bash cannot hold NUL in a variable, and a newline-delimited list silently splits any
# path containing a newline. A file also lets the producer's exit status be checked,
# which `< <(...)` process substitution structurally cannot report.
TMPLIST=$(mktemp "${TMPDIR:-/tmp}/secret-scan.XXXXXX") || exit 3
# Two separate traps on purpose: a single `trap ... EXIT HUP INT TERM` RESUMES after the
# handler and exits 0 (probe-confirmed fail-open). Signal handlers must exit explicitly.
trap 'rm -f "$TMPLIST"' EXIT
trap 'rm -f "$TMPLIST"; exit 3' HUP INT TERM

MODE=file
case "${1:-}" in
    --staged)
        MODE=staged
        # ACMRT, not ACMR: T is a TYPE CHANGE. Staging a symlink-to-regular-file swap that
        # carries a secret produced an empty ACMR enumeration and exited 0 - a real bypass
        # of this very gate. A type-changed path is still an ordinary blob in the index.
        git diff --cached --name-only --diff-filter=ACMRT -z > "$TMPLIST" || exit 3
        ;;
    --patch)
        # Scan ONE file of composite patch/message text (used by the pre-push hook).
        # PRIMARY RX ONLY: the path-aware secondary lane (crd_path_allowed) is meaningless
        # against concatenated patch text, where every original path has been lost - it
        # would apply the PIN pattern to allowlisted content and block legitimate pushes.
        # Per-file PIN coverage with correct path semantics is the pre-commit hook's job.
        MODE=patch
        shift
        [ -n "${1:-}" ] || { echo "secret-scan: --patch requires a file" >&2; exit 3; }
        printf '%s\0' "$@" > "$TMPLIST" || exit 3
        ;;
    --working)
        if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
            { git diff --name-only -z HEAD && git ls-files --others --exclude-standard -z; } \
                | sort -uz > "$TMPLIST" || exit 3
        else
            git ls-files --others --exclude-standard -z | sort -uz > "$TMPLIST" || exit 3
        fi
        ;;
    --all-history)
        # Coarse one-time audit: primary RX only (see the usage note above).
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
        usage
        exit 3
        ;;
    --)
        # Explicit end of options: everything after is a PATH, even if it looks like a
        # flag. CI passes `--` so a tracked file named "--staged" cannot switch modes and
        # silently turn a full-tree scan into a scan of nothing.
        shift
        printf '%s\0' "$@" > "$TMPLIST" || exit 3
        ;;
    *)
        printf '%s\0' "$@" > "$TMPLIST" || exit 3
        ;;
esac

WORST=0
HITS=""
while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    if [ "$MODE" = patch ]; then
        # A composite patch file is NOT a repository path: it must bypass the .git
        # exclusion (a TMPDIR resolving inside .git made scan_file return clean and
        # approved an unscanned push) and it must FAIL CLOSED if it has vanished,
        # rather than inheriting scan_file's "missing path is clean" rule.
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
            echo "secret-scan: --patch input missing or unreadable: $f" >&2
            WORST=3
            continue
        fi
        out=$(scan_stdin "$f" < "$f"); rc=$?
    elif [ "$MODE" = staged ]; then
        # Read the INDEX blob, not the worktree. Enumerating index paths while reading
        # worktree bytes let `git add <secret>; echo harmless > <file>` pass cleanly.
        if ! t=$(git cat-file -t ":$f" 2>/dev/null); then
            echo "secret-scan: cannot read index entry: $f" >&2
            WORST=3
            continue
        fi
        # --diff-filter=ACMR includes submodule (gitlink) updates, which have no blob.
        [ "$t" = blob ] || continue
        out=$(git cat-file blob ":$f" 2>/dev/null | scan_stdin "$f"); rc=$?
    else
        out=$(scan_file "$f"); rc=$?
    fi
    case "$rc" in
        0) ;;
        2)
            if [ -n "$out" ]; then
                if [ -n "$HITS" ]; then HITS=$(printf '%s\n%s' "$HITS" "$out"); else HITS="$out"; fi
            fi
            if [ "$WORST" -lt 2 ]; then WORST=2; fi
            ;;
        *)
            echo "secret-scan: SCAN FAILED (rc=$rc): $f" >&2
            WORST=3
            ;;
    esac
done < "$TMPLIST"

if [ -n "$HITS" ]; then
    {
        echo "==============================================================="
        echo "BLOCKED: secret detected. Aborting."
        echo "==============================================================="
        printf '%s\n' "$HITS"
        echo ""
        echo "Action: remove the secret, ROTATE it at the provider, then retry."
        echo "If false positive: relocate the example into a non-tracked fixture."
    } >&2
fi

if [ "$WORST" -eq 3 ]; then
    echo "secret-scan: at least one input could not be proven clean - failing closed (exit 3)." >&2
fi

exit "$WORST"
