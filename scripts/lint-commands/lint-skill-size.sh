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

# CONTENT AUTHORITY (2026-08-03, codex-review C1 fix - see lint-skill-contract.sh for the
# full rationale): in --staged mode measure the STAGED BLOB (`git show :<path>`), not the
# worktree. Selecting files from the index but sizing the worktree let a file staged
# oversize / marker-broken but left clean in the worktree pass the ceiling gate. In --all
# mode the working tree is the authority (no index divergence to reconcile).
STAGED_TMP=""
_lint_cleanup() { [ -n "$STAGED_TMP" ] && rm -rf "$STAGED_TMP" 2>/dev/null; return 0; }
trap _lint_cleanup EXIT

# resolve_content <repo-relative-path> -> prints an absolute path to size, or NOTHING when
# the content does not exist (worktree file absent in --all; staged deletion in --staged).
# Memoized per path. A deletion is not a size violation, so callers skip an empty result.
resolve_content() {
    local path="$1" out
    if [ "$MODE" != "--staged" ]; then
        [ -f "$ROOT/$path" ] && printf '%s\n' "$ROOT/$path"
        return 0
    fi
    [ -n "$STAGED_TMP" ] || STAGED_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lint-staged-XXXXXX")" || return 0
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

chars_of() { python3 -c "import sys;print(len(open(sys.argv[1],encoding='utf-8').read()))" "$1"; }
marker_pos() { python3 -c "
import sys
s=open(sys.argv[1],encoding='utf-8').read()
m='<!-- CONTRACT-CORE-END -->'
print(s.index(m) if m in s else -1)" "$1"; }

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
        if [ "$n" -gt 20000 ]; then
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
        if [ "$p" -lt 0 ]; then
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
