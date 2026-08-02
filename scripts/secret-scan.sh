#!/bin/bash
# Shared secret-scanner. Used by:
#   - scripts/dotfiles-sync.sh  (PostToolUse auto-push)
#   - .git/hooks/pre-commit     (blocks local commit)
#   - .git/hooks/pre-push       (blocks manual push)
#   - .github/workflows/secret-scan.yml (CI)
#
# Usage: secret-scan.sh [--] <file> [<file> ...]
#        secret-scan.sh --composite <file>
#                                      # one file of concatenated patch + commit-message
#                                      #   text. ALL patterns; every path-based rule (the
#                                      #   .git exclusion and the CRD allowlist) is bypassed
#                                      #   because the name is a temp path. Pre-push uses this.
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

    # crd_path_allowed keys on a real repository path. For --composite input the name is a
    # temp file, so the allowlist can never legitimately fire - and MUST NOT, or a TMPDIR
    # under an allowlisted directory would silently disable this lane.
    if [ "${MODE:-file}" = composite ] || ! crd_path_allowed "$f"; then
        m=$(printf '%s' "$content" | grep -anE -e "$RX_PIN"); rc=$?
        [ "$rc" -gt 1 ] && return 3
        if [ -n "$m" ]; then
            # Keep a line if ANY PIN occurrence on it has a non-placeholder value.
            # Both simpler forms were wrong: dropping lines that merely CONTAIN a
            # placeholder anywhere hid a real PIN behind an unrelated mention, and dropping
            # lines where a pin-key is followed by a placeholder hid a real PIN sitting
            # beside a second, labelled placeholder. Neutralise every placeholder value,
            # then re-test: whatever still matches is a real one.
            # (Described, not shown - a literal example here would be a true positive
            #  against this repo's own full-tree scan. It was, once.)
            _kept=""
            # Count what goes IN so the loop can prove it processed all of it. bash implements
            # `<<<` with a temp file; if that file cannot be created (no space, unwritable
            # TMPDIR) the loop body never runs at all, _kept stays empty, and every real PIN
            # candidate is discarded as though it were a placeholder - a silent CLEAN verdict
            # on a file that matched. awk is used rather than `grep -c` because grep exits 1 on
            # a zero count, which would itself need special-casing.
            _expect=$(printf '%s\n' "$m" | awk 'END{print NR}')
            _seen=0
            while IFS= read -r _ln; do
                _seen=$((_seen + 1))
                [ -z "$_ln" ] && continue
                # Every status is checked: a failing sed or a grep ERROR (rc>1) must fail
                # closed with 3, not silently drop the candidate as if it were a placeholder.
                # `XXXXXX` was removed from this list in round 5: RX_PIN requires [0-9]{6},
                # so a letter run can never form part of a match and could never have needed
                # exempting. It was dead code, and the test that claimed to cover it stayed
                # green when it was deleted - the giveaway. Only digit placeholders belong here.
                _probe=$(printf '%s' "${_ln#*:}" | sed -E 's/(000000|123456)/PLACEHOLDER/g') || return 3
                printf '%s' "$_probe" | grep -qaE -e "$RX_PIN"; _prc=$?
                [ "$_prc" -gt 1 ] && return 3
                if [ "$_prc" -eq 0 ]; then
                    if [ -n "$_kept" ]; then _kept=$(printf '%s\n%s' "$_kept" "$_ln"); else _kept="$_ln"; fi
                fi
            done <<< "$m"
            # FAIL CLOSED when the here-string did not deliver every candidate line.
            [ "$_seen" -eq "$_expect" ] || return 3
            m="$_kept"
        fi
        # Written as an explicit if rather than the "use-alternate-value" parameter expansion
        # carrying a dollar-quoted newline: bash expands that form correctly, but zsh splices
        # the literal characters, and these scripts get probed and sourced from both. The
        # explicit form is unambiguous under either shell.
        # (Described, not shown. Spelling the idiom out here would trip the static guard in
        #  test-secret-scan.sh - exactly as a literal PIN example once tripped the scanner
        #  against this repo's own full-tree scan.)
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
    # A SYMLINK must be scanned as git stores it: the blob is the TARGET PATH string, not
    # the bytes it points at. Following it read content git never publishes (a tracked link
    # to ~/.aws/credentials produced a false positive) while never reading what git does.
    if [ -L "$f" ]; then
        # Guard an option-shaped name: a tracked symlink literally named `--help` or
        # `--version` would be parsed as a FLAG by GNU readlink, which then prints help and
        # exits 0 - so the link's real target (the bytes git publishes) is never scanned and
        # the file is reported clean. Prefixing `./` makes it unambiguously a path. Done with
        # a case test rather than `--`, whose support differs across BSD and GNU readlink.
        case "$f" in -*) _rl="./$f" ;; *) _rl="$f" ;; esac
        _t=$(readlink "$_rl") || return 3
        printf '%s' "$_t" | scan_stdin "$f"; return $?
    fi
    [ -f "$f" ] || return 0      # absent or non-regular: nothing to publish
    [ -r "$f" ] || return 3      # present but unreadable: cannot prove clean
    scan_stdin "$f" < "$f"; rc=$?
    [ "$rc" -eq 1 ] && return 3  # scan_stdin never returns 1; a 1 means the redirect failed
    return "$rc"
}

usage() {
    echo "Usage: $0 [--staged|--working|--all-history|--composite <file>|[--] <file>...]" >&2
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
    --composite)
        # ONE file of concatenated patch + commit-message text (the pre-push hook's input).
        #
        # Its name is a temp path, NOT a repository path, so every path-based rule is
        # bypassed: the .git exclusion (a TMPDIR inside .git made the scan silently return
        # clean) and the CRD allowlist (a TMPDIR under an allowlisted directory silently
        # disabled a pattern lane). Path rules that key on a meaningless name are not
        # protection, they are three different ways to scan nothing.
        #
        # ALL patterns apply, including the PIN lane. Skipping it here dropped real coverage
        # (a PIN reaching the repo through a merge or rebase runs no pre-commit hook, so
        # push time is the only place left to catch it). The allowlist that would normally
        # exempt a PIN example cannot be consulted for composite text, so the trade is: a
        # PIN-shaped value inside an allowlisted doc WILL block a push once it enters the
        # pushed range. Placeholder values stay exempt, which is what those docs should use.
        # Measured 2026-08-01: zero PIN-pattern matches across this repository's entire
        # history, so the practical false-positive rate today is zero.
        MODE=composite
        shift
        [ -n "${1:-}" ] || { echo "secret-scan: --composite requires a file" >&2; exit 3; }
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
    if [ "$MODE" = composite ]; then
        # Bypasses scan_file entirely: no path exclusion, no allowlist, and a vanished
        # input FAILS CLOSED instead of inheriting "a missing path is clean".
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
            echo "secret-scan: --composite input missing or unreadable: $f" >&2
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
