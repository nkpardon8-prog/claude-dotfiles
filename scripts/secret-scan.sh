#!/bin/bash
# Shared secret-scanner. Used by:
#   - scripts/dotfiles-sync.sh  (PostToolUse auto-push)     exit-code-only
#   - .git/hooks/pre-commit     (blocks local commit)       exit-code-only
#   - .git/hooks/pre-push       (blocks manual push)        exit-code-only
#   - .github/workflows/secret-scan.yml (CI)                exit-code-only
#   - settings.json.template SessionStart credentials.md scan  (added 2026-08-03)
#         Maps the exit code to user-facing prose, so it must distinguish rc=2 (a real hit
#         -> rotate) from any other non-zero (the scan could not run -> do NOT tell anyone
#         to rotate).
#   - commands/god-review/principles/secret-leak.md 2.4      (added 2026-08-03)
#         Also renders the exit code as prose, and applies the same 3>2>0 precedence.
#
# NO COUNT IS WRITTEN HERE ON PURPOSE. A numeral drifted THREE TIMES - in three consecutive
# commits that each forbade exactly that drift ("three of four" -> "FIVE" -> "SIX") - and the
# proof-suite guard could only ever forbid the PREVIOUS wording, so it reported success while
# a stale count sat in the repo. Deleting the numerals removes the surface: the BULLET LIST
# above is the fact, and a list cannot go stale without someone editing the thing it lists.
#
# The property that actually matters: EVERY consumer branches on the exit code, and the two
# that render it as PROSE A HUMAN READS (SessionStart and the 2.4 scan block) must tell rc=2
# from rc=3, because only they can tell a person to rotate a credential. Of the others,
# dotfiles-sync maps rc=2 and rc=3 to different marker states and pre-push emits its
# RANGE-NOT-PROVEN-CLEAN token on rc=3 - so "exit-code-only" means "no human-facing prose",
# never "ignores the value".
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
# THE RESIDUAL GAP THIS BOUNDARY ACCEPTS (documented 2026-08-03 - three reviewers derived it
# independently because it was written down nowhere): an ALPHANUMERIC-glued key is a false
# negative. MEASURED: `PREFIXsk-<44 chars>` -> rc=0. That is the unavoidable cost of excluding
# only [A-Za-z0-9]; the alternative reintroduces the prose false positives above. It is a much
# narrower class than the `backup_sk-` case (a key run together with a preceding WORD, no
# separator at all, is not a shape secrets are normally written in), so the trade is accepted -
# but it is ACCEPTED, not absent. Do not "fix" it without a measured false-positive count.
#
# A NUL byte is a separator too, and deleting one used to close this boundary - see the note
# in scan_stdin about `tr` translating rather than deleting.
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
    # NUL is TRANSLATED TO A SPACE, never deleted (2026-08-03, round-2 review - a real
    # false negative, found by one reviewer of seven).
    #
    # Bash cannot hold a NUL in a variable, so it has to go. But DELETING it closes the gap
    # between the bytes on either side, and the boundary-anchored lanes added in round 1
    # need that gap: `X\0sk-<key>` collapsed to `Xsk-<key>`, where `(^|[^A-Za-z0-9])` has
    # no non-alphanumeric character to match, so grep returned 1 and the scanner exited 0.
    # MEASURED: `X\0sk-<44 chars>` -> rc=0, while the identical content with a space ->
    # rc=2. The anchoring fix introduced this; the unanchored regex it replaced caught it.
    #
    # A space is the minimal correct substitute: it restores the word boundary while
    # preserving line numbering exactly (a newline would renumber every reported hit in a
    # NUL-bearing file). Any non-alphanumeric byte would do; space is the least surprising.
    content=$(tr "\000" " ") || return 3

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
# The three enumerate-everything modes take NO further arguments. Without this, an extra
# argument was silently DISCARDED (round-3 review): `--staged --bogus` exited 0 ignoring the
# typo, and worse, `--staged <path>` exited 0 having scanned the index while the caller
# believed it had scanned that path. Same "an argument I did not understand vanished" shape
# the per-path validation below closes for the explicit-path branch - fail closed, both sides.
case "${1:-}" in
    --staged|--working|--all-history)
        if [ "$#" -gt 1 ]; then
            _mode_name="$1"; shift
            echo "secret-scan: $_mode_name takes no further arguments (got: $*)" >&2
            usage
            exit 3
        fi
        ;;
esac

case "${1:-}" in
    --staged)
        MODE=staged
        # Same root-relative reasoning as --working below: git emits repo-relative paths, so
        # the index keys (":$f") and any path test must be evaluated from the repo root.
        # `cd ""` SUCCEEDS and does not move, so the old form of this guard could never
        # fire outside a repo - the rc=3 those cases returned came from the enumeration
        # failing downstream, not from here. Capture first, test for emptiness, then cd.
        # (Same `cd ""` class fixed in the 2.4 block; instance fixed there, class not.)
        _root=$(git rev-parse --show-toplevel 2>/dev/null)
        [ -n "$_root" ] || { echo "secret-scan: --staged requires a git repository" >&2; exit 3; }
        cd "$_root" || { echo "secret-scan: cannot cd to repo root $_root" >&2; exit 3; }
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
        # MODE MUST be set here. This branch was the ONLY mode branch that never assigned it,
        # so it silently ran as MODE=file and inherited the explicit-path zero-scanned
        # invariant below - making a CLEAN working tree (or a deletion-only change) return
        # rc=3. dotfiles-sync.sh, the sole --working consumer, maps any non-0/2 to a
        # `kind: unproven` pause marker and then halts EVERY subsequent auto-sync, so that
        # would have permanently jammed the auto-push behind a false "could not prove the
        # working tree clean". Found in round 3, reproduced end to end against a real bare
        # remote. An enumeration finding nothing is legitimately clean - there is nothing
        # to publish - and only an EXPLICIT-PATH caller can be said to have scanned nothing.
        #
        # ROUND 4: that exemption then opened a false NEGATIVE, which is the worse direction.
        # `git diff --name-only` and `git ls-files` emit paths relative to the REPOSITORY ROOT,
        # but the scan resolved them against the CALLER's cwd - so from any subdirectory every
        # enumerated path missed, was "not counted", and the exempted invariant let it return
        # rc=0. MEASURED on one dirty tree holding a real key: rc=2 from the root, rc=0 from
        # `deep/`, rc=0 from an unrelated repo entirely.
        #
        # This was NOT theoretical: dotfiles-sync-pause-notice.sh tells a human recovering from
        # a CONFIRMED leak to run `bash ~/.claude-dotfiles/scripts/secret-scan.sh --working`
        # - an absolute path, no cd - as the "Confirm clean" gate immediately before deleting
        # the marker and resuming pushes to the PUBLIC remote. Run from anywhere but the root,
        # it answered "clean" about a tree it never looked at.
        #
        # Fixed at the cause: enumerate AND scan from the repository root, so the paths git
        # emits are the paths that get opened. The invariant below is simultaneously widened
        # from "MODE=file" to "enumerated something but reached none of it", which keeps a
        # clean tree at rc=0 while failing closed on reach-nothing in EVERY mode.
        MODE=working
        # `cd ""` SUCCEEDS and does not move, so the old form of this guard could never
        # fire outside a repo - the rc=3 those cases returned came from the enumeration
        # failing downstream, not from here. Capture first, test for emptiness, then cd.
        # (Same `cd ""` class fixed in the 2.4 block; instance fixed there, class not.)
        _root=$(git rev-parse --show-toplevel 2>/dev/null)
        [ -n "$_root" ] || { echo "secret-scan: --working requires a git repository" >&2; exit 3; }
        cd "$_root" || { echo "secret-scan: cannot cd to repo root $_root" >&2; exit 3; }
        # --diff-filter=d EXCLUDES deletions (lowercase d = "not deleted"). A deleted path has
        # no bytes to publish, so enumerating it only to skip it is noise - and it is what
        # made the strict invariant below unusable: a deletion-only commit would have
        # enumerated one path, scanned none, and failed closed, re-jamming the auto-push that
        # round 3 just unjammed. Excluding deletions here means every path that IS enumerated
        # must be openable, which is exactly what makes "enumerated but reached none" a sound
        # error signal rather than a false alarm.
        if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
            { git diff --name-only -z --diff-filter=d HEAD && git ls-files --others --exclude-standard -z; } \
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
                # NUL -> space, not deleted: same boundary-collapse false negative as in
                # scan_stdin (see the note there). This lane is a coarse audit, but it
                # must not be MORE blind than the live one.
                content=$(git show "$sha:$f" 2>/dev/null | tr '\000' ' ')
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
        # having scanned NOTHING while reporting clean. Most consumers render no prose, so
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
ENUMERATED=0
while IFS= read -r -d '' f; do
    [ -z "$f" ] && continue
    ENUMERATED=$((ENUMERATED + 1))
    if [ "$MODE" = composite ]; then
        # Bypasses scan_file entirely: no path exclusion, no allowlist, and a vanished
        # input FAILS CLOSED instead of inheriting "a missing path is clean".
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
            echo "secret-scan: --composite input missing or unreadable: $f" >&2
            WORST=3
            continue
        fi
        out=$(scan_stdin "$f" < "$f"); rc=$?
        SCANNED=$((SCANNED + 1))
    elif [ "$MODE" = staged ]; then
        # Read the INDEX blob, not the worktree. Enumerating index paths while reading
        # worktree bytes let `git add <secret>; echo harmless > <file>` pass cleanly.
        #
        # SUBMODULE GITLINKS ARE CHECKED FIRST, by index MODE (160000), because
        # `git cat-file -t ":<gitlink>"` FAILS with rc=128 rather than printing a type - so
        # the `[ "$t" = blob ] || continue` line below, written to handle exactly this case,
        # was unreachable dead code and every gitlink hit the rc=3 arm instead. MEASURED with
        # a real installed pre-commit: a commit whose only change was a submodule bump was
        # refused permanently, and dotfiles-sync turned that into a pause marker that halts
        # all auto-sync. A gitlink has no blob in THIS repository - there is nothing here to
        # publish - so it is legitimately accounted for, which is why it counts as scanned
        # (it must not trip the "enumerated but reached none" invariant either).
        _mode=$(git ls-files -s -- "$f" 2>/dev/null | awk '{print $1; exit}')
        if [ "$_mode" = 160000 ]; then
            SCANNED=$((SCANNED + 1))
            continue
        fi
        if ! t=$(git cat-file -t ":$f" 2>/dev/null); then
            echo "secret-scan: cannot read index entry: $f" >&2
            WORST=3
            continue
        fi
        # A non-blob index entry (nothing to read) is accounted for, not skipped silently.
        [ "$t" = blob ] || { SCANNED=$((SCANNED + 1)); continue; }
        out=$(git cat-file blob ":$f" 2>/dev/null | scan_stdin "$f"); rc=$?
        SCANNED=$((SCANNED + 1))
    else
        # An absent path is TOLERATED here but does NOT count as scanned. Two intents meet
        # at this line and both are legitimate:
        #   - CI pipes `git ls-files` in, so a path that vanished between enumeration and
        #     scan must not turn the whole run red (an earlier diff-based CI job did exactly
        #     that on every deletion-bearing push, which is why the -f guard was dropped).
        #   - But a scanner told to scan ONE path that is not there, answering "clean", is
        #     "scanned nothing, reported success" - the class this whole effort exists to kill.
        # Counting rather than failing satisfies both: a mixed batch stays green, while an
        # invocation where NOTHING was scanned fails closed at the counter below.
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then
            echo "secret-scan: no such path (not counted as scanned): $f" >&2
            continue
        fi
        # A dangling symlink is still scannable (scan_file reads the stored target string,
        # which is what git publishes), so -L is checked before the regular-file test.
        #
        # A non-regular entry is accounted for DIFFERENTLY depending on who chose the path,
        # and that distinction is the whole fix (round-5 review). Round 4 widened the
        # "enumerated but reached none" invariant to every mode while leaving this branch's
        # round-3 skip in place, and the two then contradicted each other: when EVERY
        # enumerated path was non-regular, --working reported rc=3 and dotfiles-sync turned
        # that into a permanent pause marker. MEASURED, all three reachable and ordinary:
        # an untracked NESTED REPO (any agent running `git init` in a scratch dir), a
        # submodule pointer bump alone, and a dirty submodule worktree alone.
        #
        #   ENUMERATED BY GIT (--working): git legitimately lists gitlinks and nested repos.
        #     There is no blob here to publish, so the entry IS accounted for - exactly the
        #     accounting the --staged branch already uses for index mode 160000. Not doing
        #     this makes a normal repo shape jam the auto-push.
        #   NAMED BY THE CALLER (explicit path): a directory is NOT accounted for, so a lone
        #     directory argument still trips the invariant and returns 3. A caller who asked
        #     for one thing and got nothing scanned must not be told "clean".
        if [ ! -L "$f" ] && [ ! -f "$f" ]; then
            if [ "$MODE" = working ]; then
                SCANNED=$((SCANNED + 1))   # nothing to publish here; legitimately accounted
            else
                echo "secret-scan: not a regular file, not counted as scanned: $f" >&2
            fi
            continue
        fi
        out=$(scan_file "$f"); rc=$?
        SCANNED=$((SCANNED + 1))   # only a REAL scan counts toward the invariant below
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

# THE INVARIANT, asserted rather than assumed (2026-08-03, round-2 review): an explicit-path
# invocation that scanned ZERO files has proved nothing, so it must not report clean. Every
# individual route to "scanned nothing, exited 0" that has been found here was a DIFFERENT
# route - an unknown flag, a nonexistent path, an empty argument list after `--`. Closing them
# one at a time is whack-a-mole; this counter closes the shape, including the next route.
# MEASURED before the fix: `secret-scan.sh --` (no paths) -> rc=0.
#
# Scoped to explicit-path mode ONLY. An enumeration legitimately finds nothing to scan: a
# commit that stages a submodule pointer alone, or a clean working tree, must stay rc=0.
# TWO shapes, both meaning "nothing was proven" (widened in round 4):
#
# (a) We ENUMERATED work and reached NONE of it. This holds in EVERY mode, and it is the
#     shape that caught the round-4 defect: --working listed repo-relative paths, resolved
#     them against the wrong cwd, missed every one, and returned rc=0. Scoping the check to
#     explicit-path mode (round 2) is what let that be silent. A clean tree enumerates zero
#     and so is untouched by this - it is legitimately clean, there is nothing to publish.
# (b) An EXPLICIT-PATH caller passed nothing scannable at all (`--` with no paths). An
#     enumeration finding nothing is fine; a caller asking for nothing and being told "clean"
#     is not.
if [ "$ENUMERATED" -gt 0 ] && [ "$SCANNED" -eq 0 ]; then
    echo "secret-scan: enumerated $ENUMERATED path(s) but scanned NONE - refusing to report clean" >&2
    WORST=3
elif [ "$MODE" = file ] && [ "$ENUMERATED" -eq 0 ]; then
    echo "secret-scan: explicit-path invocation scanned ZERO files - refusing to report clean" >&2
    WORST=3
fi

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
