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

# In --staged mode the tree being COMMITTED is the authority for content too (identical
# to $ROOT in the ordinary main-tree case; only the worktree case differs).
CONTENT_ROOT="$ROOT"
[ "$MODE" = "--staged" ] && CONTENT_ROOT="$GITROOT"

fail=0

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
if [ -f "$CONTENT_ROOT/$F" ] && staged_has "$F"; then
    n=$(chars_of "$CONTENT_ROOT/$F")
    if [ "$n" -gt 20000 ]; then
        echo "lint-skill-size: FAIL $F is $n chars (> 20000). Its body is re-injected head-truncated at 20,000 chars after every compaction - it must fit whole." >&2
        fail=1
    fi
fi

# Rule 2: contract-core marker position for the large skills. codex-review.md and
# implement.md joined 2026-08-02 (parallelizer v1): both now exceed the 20,000-char
# re-injection ceiling outright, so their launch registers only survive a compaction if
# the contract core ends before char 19500.
for F in commands/mission.md commands/pre-compact.md commands/codex-review.md commands/implement.md; do
    if [ -f "$CONTENT_ROOT/$F" ] && staged_has "$F"; then
        p=$(marker_pos "$CONTENT_ROOT/$F")
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
        [ -f "$CONTENT_ROOT/$f" ] || continue
        n=$(chars_of "$CONTENT_ROOT/$f")
        [ "$n" -gt 30000 ] && echo "lint-skill-size: WARN $f is $n chars; only its first 20,000 survive re-injection after a compaction." >&2
    done < <(git -C "$GITROOT" diff --cached --name-only 2>/dev/null)
fi

exit $fail
