#!/bin/bash
# Shared secret-scanner. Used by:
#   - scripts/dotfiles-sync.sh  (PostToolUse auto-push)     exit-code-only
#   - .git/hooks/pre-commit     (blocks local commit)       exit-code-only
#   - .git/hooks/pre-push       (blocks manual push)        exit-code-only
#   - .github/workflows/secret-scan.yml (CI)                exit-code-only
#   - settings.json.template SessionStart credentials.md scan  (added 2026-08-03)
#         The ONLY consumer that maps the exit code to user-facing prose, so it is the only
#         one that must distinguish rc=2 (a real hit -> rotate) from any other non-zero
#         (the scan could not run -> do NOT tell anyone to rotate). Keep this list accurate:
#         the "three of four are exit-code-only" reasoning used elsewhere depends on it.
#
# KEEP THIS LIST COMPLETE. Anyone changing the exit-code vocabulary below must be able to
# enumerate every caller from here; a consumer missing from this list is a consumer that
# silently keeps the old contract.
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

# ANCHORING (2026-08-03): the `sk-` lane is LEFT-ANCHORED on an ALPHANUMERIC boundary.
# Unanchored it matched INSIDE a word: any word ending in those two letters, followed by a
# hyphen and a 20+ character hyphenated run, was a hit - so ordinary prose about a
# task-specific thing, a risk-based approach, or disk-space monitoring all returned rc=2.
# In this repo, whose prose is full of long kebab-case identifiers, that is not a cosmetic
# false positive: a hit jams EVERY commit and silently halts the async auto-push to the
# public remote.
#
# THE BOUNDARY EXCLUDES ONLY [A-Za-z0-9] - NOT `_` AND NOT `-`. This is load-bearing and was
# corrected after review: an earlier draft used [^A-Za-z0-9_-], which treats _ and - as part
# of the preceding word and therefore MISSED a real key written `backup_sk-<payload>` or
# `prefix-sk-<payload>`. That trades a false positive for a false NEGATIVE on the one control
# standing between this repo and a public remote - strictly the wrong direction. The
# false-positive cases only ever needed alphanumeric exclusion (task/risk/disk end in a, i, i),
# so this boundary rejects them AND still catches a key glued to a separator.
#
# NOT every other lane is self-anchoring. AKIA/ghp_/AIza/npm_/github_pat_ are, via fixed
# prefixes. `hf_`, `xox[abposr]-`, and `(rk|sk|pk)_(live|test)_` are NOT - measured rc=2 on
# `branchf_...`, `prefixoxb-...`, `network_live_...`. Left unanchored deliberately for now:
# they are far rarer in prose than the task/risk/disk family, and widening the fix without a
# measured false-positive is how the previous over-correction happened. Tracked, not closed.
#
# Negative cases for all three phrases, and positive cases for the separator-glued forms,
# live in scripts/hooks/test-secret-scan.sh.
# Do NOT write those example words here with a separator between the two halves - a
# non-alphanumeric character in that position makes this very comment match the lane.
RX='((^|[^A-Za-z0-9])sk-(ant|proj|svcacct)?-?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|ghu_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}|ghr_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|npm_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|ya29\.[A-Za-z0-9_-]{20,}|whsec_[A-Za-z0-9]{20,}|(rk|sk|pk)_(live|test)_[A-Za-z0-9]{20,}|-----BEGIN +(RSA +|OPENSSH +|EC +|DSA +|PGP +)?PRIVATE +KEY-----)'
export RX

# Connection strings and JWTs (added 2026-08-03 by explicit user decision on pd:2-rx-conn-scope,
# after an earlier measurement had argued AGAINST them). Folded into RX so they apply everywhere
# the primary lane does, including --composite at push time.
#
# FALSE POSITIVES ARE THE DOMINANT RISK HERE, not misses: a false positive jams EVERY commit in
# this repo AND silently blocks the async auto-push, which is strictly worse than one missed
# exotic secret. So both patterns are anchored to STRUCTURE, never to a loose prefix:
#
#   JWT - requires all THREE base64url segments AND a `eyJ` first segment (base64 of `{"`).
#         A bare `eyJ...` prefix rule would match ordinary base64 in docs; three dot-separated
#         segments of >=10 chars each is a shape prose does not accidentally produce.
#         MEASURED before adding: 0 hits across every tracked file.
#
#   CONN - requires scheme + BOTH a user and a password + host. `postgres://localhost/db` and
#          `https://example.com` correctly do NOT match; only an embedded credential pair does.
#          Schemes are enumerated (no generic `://`) so ordinary URLs cannot trip it.
#          An INTERPOLATED password (`${VAR}`, `$VAR`) is excluded - it is a reference, not a
#          literal secret, and matching it would red the tree on ordinary fixtures.
#          KNOWN BLIND SPOT, accepted deliberately: a real literal password CONTAINING `$` is
#          missed. That is the correct trade here - see the asymmetry argument above.
#          MEASURED before adding: 2 hits, both tracked test fixtures; one was an interpolated
#          password (now excluded by the pattern) and one was a literal that was converted to
#          runtime assembly, matching this repo's existing fixture convention.
RX_JWT='eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
RX_CONN='(postgres|postgresql|mysql|mongodb(\+srv)?|redis|rediss|amqp|amqps|mssql)://[^:/@[:space:]]+:[^@/[:space:]$\{]+@[^[:space:]/]+'
RX="${RX%)}|${RX_JWT}|${RX_CONN})"
export RX RX_JWT RX_CONN

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
    -*)
        # FAIL CLOSED on an unrecognized option (2026-08-03). Without this branch the
        # catch-all below treated `--stdin` / a typo / a renamed flag as a PATH: the file
        # does not exist, the per-file existence check skips it, and the scanner exits 0
        # having scanned NOTHING while reporting clean. Three of the four consumers are
        # exit-code-only, so none of them would ever notice.
        #
        # THE PATTERN IS `-*`, NOT `--*`. Corrected after review: the first draft matched
        # only double-dash, so `-staged` - the single most likely typo of the flag the
        # pre-commit hook actually passes - still fell through to the path branch and exited
        # 0 having scanned nothing. That left the exact fail-open this branch exists to close.
        # The literal `--` end-of-options token is claimed by the case above, so widening to
        # `-*` cannot swallow it, and a real file whose name begins with a dash is still
        # reachable via `--`.
        echo "secret-scan: unknown option '$1'" >&2
        usage
        exit 3
        ;;
    *)
        # Validate EVERY argument, not just $1 (2026-08-03, round-2 review). The `-*` guard
        # above inspects only the FIRST token, so `clean.txt --stdin` fell through to here:
        # the flag became a "path", the per-file existence check skipped it, and the scanner
        # exited 0 having scanned only `clean.txt` while silently dropping an argument it did
        # not understand. MEASURED before the fix: `secret-scan.sh ok.txt --stdin` -> rc=0.
        # Options are only ever meaningful in first position, so any later dash-leading token
        # is a mistake; `--` above remains the escape hatch for a real file named `-x`.
        for _a in "$@"; do
            case "$_a" in
                -*)
                    echo "secret-scan: unknown option '$_a' (use -- before a path starting with a dash)" >&2
                    usage
                    exit 3
                    ;;
            esac
        done
        printf '%s\0' "$@" > "$TMPLIST" || exit 3
        ;;
esac

WORST=0
HITS=""
SCANNED=0
while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    SCANNED=$((SCANNED + 1))
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
