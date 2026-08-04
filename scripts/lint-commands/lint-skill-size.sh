#!/bin/bash
# lint-skill-size.sh - fail-closed guard for the 20,000-CHAR invoked-skills
# re-injection ceiling (verified 2026-08-01: after every compaction the harness
# re-injects each invoked skill's body HEAD-TRUNCATED to its first 20,000
# characters - chars, not bytes).
#
# Rules (FAIL = exit 1):
#   commands/post-compact-resume.md        total chars <= 20000 (must fit whole)
#   commands/mission.md                    '<!-- CONTRACT-CORE-END -->' marker
#   commands/pre-compact.md                present at char index <= 19500
#   commands/codex-review.md
#   commands/implement.md
# WARN (never fails): any other staged commands/*.md over 30000 chars.
#
# Modes:
#   --staged   check only files in the git staged set (pre-commit use)
#   --all      check the rules unconditionally (phase-gate / CI use; default)
#
# bash 3.2 compatible. Runs from any cwd (resolves the repo root itself).

set -u

# ROOT SPLIT (2026-08-02) - see lint-skill-contract.sh for the full rationale:
#   ROOT     WHERE THE FILES LIVE (this script's own tree, so a copy lints itself).
#   GITROOT  WHICH INDEX the --staged query reads (cwd's repo - hooks run with cwd at the
#            invoking worktree root, and a main-tree --cached query cannot see a linked
#            worktree's index, so it would report an empty staged set and skip silently).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GITROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")"
MODE="${1:---all}"

# UNKNOWN ARGUMENT = REFUSE (2026-08-03). The sibling lint-skill-contract.sh already exits 2
# here; this one silently accepted anything, so `--bogus` (or a renamed flag, or a typo of
# --staged) exited 0 having linted nothing. MEASURED: `--bogus` -> rc=0 here vs rc=2 there.
# Same shape as the secret scanner's unknown-flag fail-open closed earlier in this mission.
case "$MODE" in
    --staged|--all) ;;
    *) echo "lint-skill-size: unknown argument: $MODE (expected --staged or --all)" >&2; exit 2 ;;
esac

# --staged reads content THROUGH a staging tempdir, so an unusable TMPDIR means the lint can
# see no content at all. That used to be indistinguishable from "nothing is staged" (a bare
# `|| return 0`), and the lint cleared an OVERSIZE STAGED FILE. MEASURED before this fix:
# staged 25,000-char file + a failing mktemp -> rc=0. Created HERE, in the main shell, so the
# exit is real - inside resolve_content it would run in a command substitution's subshell and
# be swallowed.
STAGED_TMP=""
# The cleanup trap is installed BEFORE the mktemp it removes. It used to be installed ~30
# lines further down, after the ROOT guard, so any `exit` between the two leaked the staging
# directory (measured: a --staged run against a tree with no commands/ left lint-staged-XXXXXX
# behind). A trap that is armed after the resource it guards is not a trap.
_lint_cleanup() { [ -n "$STAGED_TMP" ] && rm -rf "$STAGED_TMP" 2>/dev/null; return 0; }
trap _lint_cleanup EXIT
if [ "$MODE" = "--staged" ]; then
    STAGED_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lint-staged-XXXXXX")" || {
        echo "lint-skill-size: FAIL - cannot create a staging tempdir (TMPDIR unusable);" >&2
        echo "lint-skill-size: refusing to report success on staged content it could not read." >&2
        exit 3
    }
fi

# FAIL CLOSED WHEN ROOT DOES NOT RESOLVE TO A REAL COMMAND TREE (2026-08-03, P4).
# ROOT is derived from BASH_SOURCE, so it is only correct while this script sits inside the
# tree it is meant to lint. Run a COPY from anywhere else - which is exactly what the test
# harness did - and ROOT resolves to some unrelated ancestor directory that contains no
# `commands/`, the file loop matches nothing, and the lint EXITS 0: a clean bill of health
# for a tree it never looked at. That is the governing bug class this part exists to kill,
# and it made four of the harness's six cases vacuously green.
#
# SCOPED TO --all (2026-08-04). The first version fired in BOTH modes, contradicting the
# sentence directly above it: --staged reads the index via GITROOT and never consults $ROOT,
# so failing a --staged run for a missing $ROOT/commands/ fails it for a path it does not use.
# The visible cost of that over-broad guard was a masquerade - the secret-scan e2e fixture had
# to `mkdir` an EMPTY commands/ just to get its pre-commit hook past this line, i.e. the fix
# was made to pass by giving it nothing to lint.
#
# AND IT NOW CHECKS FOR THE GUARDED FILES, NOT JUST THE DIRECTORY. `[ -d commands ]` proved
# only that a directory exists: a tree with commands/ present but every guarded file renamed
# or moved returned rc=0 from --all having measured NOTHING - the identical clean-bill-of-
# health this guard was written to prevent, one level in. That is verdict-corpus #190/#201,
# found in the corpus and independently confirmed by the round-5 review panel. CI runs exactly
# --all, so a renamed commands/mission.md would have switched the marker rule off silently
# and stayed green.
if [ "$MODE" = "--all" ]; then
    if [ ! -d "$ROOT/commands" ]; then
        echo "lint-skill-size: FAIL - ROOT does not resolve to a command tree (no commands/ under $ROOT)." >&2
        echo "lint-skill-size: refusing to report success for a tree that was never scanned." >&2
        exit 1
    fi
    _missing=""
    for _g in post-compact-resume.md mission.md pre-compact.md codex-review.md implement.md; do
        [ -f "$ROOT/commands/$_g" ] || _missing="$_missing commands/$_g"
    done
    if [ -n "$_missing" ]; then
        echo "lint-skill-size: FAIL - guarded file(s) absent:$_missing" >&2
        echo "lint-skill-size: a rule whose target is missing is an UNENFORCED rule, not a satisfied one." >&2
        echo "lint-skill-size: if a command was intentionally renamed or retired, update this list in the same commit." >&2
        exit 1
    fi
fi

# CONTENT AUTHORITY (2026-08-03, codex-review C1 fix - see lint-skill-contract.sh for the
# full rationale): in --staged mode measure the STAGED BLOB (`git show :<path>`), not the
# worktree. Selecting files from the index but sizing the worktree let a file staged
# oversize / marker-broken but left clean in the worktree pass the ceiling gate. In --all
# mode the working tree is the authority (no index divergence to reconcile).
# (The _lint_cleanup trap used to be installed here. It now sits beside the mktemp it cleans
# up, above the ROOT guard, so an early exit cannot leak the staging directory.)

# resolve_content <repo-relative-path> -> prints an absolute path to size, or NOTHING when
# the content does not exist (worktree file absent in --all; staged deletion in --staged).
# Memoized per path. A deletion is not a size violation, so callers skip an empty result.
resolve_content() {
    local path="$1" out
    if [ "$MODE" != "--staged" ]; then
        [ -f "$ROOT/$path" ] && printf '%s\n' "$ROOT/$path"
        return 0
    fi
    # The staging dir is created ONCE, EAGERLY, before any caller (see below). It must not
    # be created here: callers invoke this function as `cf="$(resolve_content "$F")"`, and an
    # `exit` inside a command substitution kills only the SUBSHELL - the failure would be
    # swallowed and read as "no content", which is the very fail-open being closed. (Measured:
    # a first attempt that exited here still returned rc=0 on an oversize staged file.)
    [ -n "$STAGED_TMP" ] || return 1
    out="$STAGED_TMP/$path"
    if [ ! -f "$out" ]; then
        mkdir -p "$(dirname "$out")" 2>/dev/null || return 0
        if ! git -C "$GITROOT" show ":$path" > "$out" 2>/dev/null; then
            rm -f "$out" 2>/dev/null
            return 0
        fi
    fi
    printf '%s\n' "$out"
}

fail=0

# FAIL CLOSED IF python3 IS UNUSABLE. Both helpers below are python3 one-liners. When python3
# is missing or broken they printed NOTHING, every `[ "$n" -gt 20000 ]` degraded to an
# "integer expression expected" error on stderr, `fail` was never set, and this lint EXITED 0
# HAVING MEASURED NOTHING - a green gate that checked zero files. Proven by shadowing python3
# with an `exit 127` stub: this script returned 0 while lint-skill-contract.sh correctly
# returned 1 (it has a `|| echo -1` fallback). A size guard that silently passes everything is
# worse than no guard, because the pre-commit chain reports success.
#
# The probe is FUNCTIONAL, not `command -v`: a stub on PATH satisfies command -v and still
# cannot run. Checked once, up front, so the failure is one clear message rather than a burst
# of arithmetic errors.
if [ "$(python3 -c 'print(len("abc"))' 2>/dev/null)" != "3" ]; then
    echo "lint-skill-size: python3 is missing or not working - cannot measure file sizes." >&2
    echo "lint-skill-size: refusing to report success on an unmeasured tree (fail closed)." >&2
    exit 3
fi

# Both measurers emit -1 ON ANY FAILURE and the callers treat -1 as UNMEASURABLE -> FAIL
# (2026-08-03, mission part 3). The preflight above catches a MISSING python3, but not a
# PER-FILE failure: an unreadable or undecodable guarded file made python3 print a traceback
# and nothing to stdout, so `n` was empty, `[ "$n" -gt 20000 ]` errored with "integer
# expression expected", and the lint EXITED 0. MEASURED: a 25,000-char guarded file at mode
# 000 -> rc=0. A file the lint cannot measure is precisely the file it must not clear.
chars_of() { python3 -c "import sys;print(len(open(sys.argv[1],encoding='utf-8').read()))" "$1" 2>/dev/null || echo -1; }
marker_pos() { python3 -c "
import sys
s=open(sys.argv[1],encoding='utf-8').read()
m='<!-- CONTRACT-CORE-END -->'
print(s.index(m) if m in s else -1)" "$1" 2>/dev/null || echo -2; }

staged_has() {
    [ "$MODE" != "--staged" ] && return 0
    git -C "$GITROOT" diff --cached --name-only 2>/dev/null | grep -qxF -- "$1"
}

# Rule 1: post-compact-resume must fit the ceiling whole
F="commands/post-compact-resume.md"
if staged_has "$F"; then
    cf="$(resolve_content "$F")"
    if [ -n "$cf" ]; then
        n=$(chars_of "$cf")
        case "$n" in ''|*[!0-9-]*) n=-1 ;; esac      # non-numeric == unmeasurable
        if [ "$n" -lt 0 ]; then
            echo "lint-skill-size: FAIL $F could not be measured (unreadable or undecodable). Refusing to pass a file the lint could not read." >&2
            fail=1
        elif [ "$n" -gt 20000 ]; then
            echo "lint-skill-size: FAIL $F is $n chars (> 20000). Its body is re-injected head-truncated at 20,000 chars after every compaction - it must fit whole." >&2
            fail=1
        fi
    fi
fi

# Rule 2: contract-core marker position for the large skills. codex-review.md and
# implement.md joined 2026-08-02 (parallelizer v1): both now exceed the 20,000-char
# re-injection ceiling outright, so their launch registers only survive a compaction if
# the contract core ends before char 19500.
for F in commands/mission.md commands/pre-compact.md commands/codex-review.md commands/implement.md; do
    if staged_has "$F"; then
        cf="$(resolve_content "$F")"
        [ -n "$cf" ] || continue
        p=$(marker_pos "$cf")
        case "$p" in ''|*[!0-9-]*) p=-2 ;; esac
        if [ "$p" = "-2" ]; then
            echo "lint-skill-size: FAIL $F could not be measured (unreadable or undecodable). Refusing to pass a file the lint could not read." >&2
            fail=1
        elif [ "$p" -lt 0 ]; then
            echo "lint-skill-size: FAIL $F lacks the '<!-- CONTRACT-CORE-END -->' marker. The first 20,000 chars are all a post-compaction agent sees - the contract core must end (marker) before char 19500." >&2
            fail=1
        elif [ "$p" -gt 19500 ]; then
            echo "lint-skill-size: FAIL $F contract-core marker at char $p (> 19500). Move content below the marker or compress the core." >&2
            fail=1
        fi
    fi
done

# WARN: other staged command files over 30k chars
if [ "$MODE" = "--staged" ]; then
    while IFS= read -r f; do
        # Files with a hard rule above are skipped here: a WARN under a FAIL is noise, and
        # for these the marker position - not the total - is the thing that matters.
        case "$f" in
            commands/post-compact-resume.md|commands/mission.md|commands/pre-compact.md) continue ;;
            commands/codex-review.md|commands/implement.md) continue ;;
            commands/*.md) ;;
            *) continue ;;
        esac
        cf="$(resolve_content "$f")"
        [ -n "$cf" ] || continue
        n=$(chars_of "$cf")
        [ "$n" -gt 30000 ] && echo "lint-skill-size: WARN $f is $n chars; only its first 20,000 survive re-injection after a compaction." >&2
    done < <(git -C "$GITROOT" diff --cached --name-only 2>/dev/null)
fi

exit $fail
