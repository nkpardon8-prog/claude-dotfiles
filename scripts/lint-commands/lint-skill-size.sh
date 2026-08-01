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
# WARN (never fails): any other staged commands/*.md over 30000 chars.
#
# Modes:
#   --staged   check only files in the git staged set (pre-commit use)
#   --all      check the rules unconditionally (phase-gate / CI use; default)
#
# bash 3.2 compatible. Runs from any cwd (resolves the repo root itself).

set -u
ROOT="$HOME/.claude-dotfiles"
MODE="${1:---all}"

fail=0

chars_of() { python3 -c "import sys;print(len(open(sys.argv[1],encoding='utf-8').read()))" "$1"; }
marker_pos() { python3 -c "
import sys
s=open(sys.argv[1],encoding='utf-8').read()
m='<!-- CONTRACT-CORE-END -->'
print(s.index(m) if m in s else -1)" "$1"; }

staged_has() {
    [ "$MODE" != "--staged" ] && return 0
    git -C "$ROOT" diff --cached --name-only 2>/dev/null | grep -qx "$1"
}

# Rule 1: post-compact-resume must fit the ceiling whole
F="commands/post-compact-resume.md"
if [ -f "$ROOT/$F" ] && staged_has "$F"; then
    n=$(chars_of "$ROOT/$F")
    if [ "$n" -gt 20000 ]; then
        echo "lint-skill-size: FAIL $F is $n chars (> 20000). Its body is re-injected head-truncated at 20,000 chars after every compaction - it must fit whole." >&2
        fail=1
    fi
fi

# Rule 2: contract-core marker position for the two large skills
for F in commands/mission.md commands/pre-compact.md; do
    if [ -f "$ROOT/$F" ] && staged_has "$F"; then
        p=$(marker_pos "$ROOT/$F")
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
        case "$f" in
            commands/post-compact-resume.md|commands/mission.md|commands/pre-compact.md) continue ;;
            commands/*.md) ;;
            *) continue ;;
        esac
        [ -f "$ROOT/$f" ] || continue
        n=$(chars_of "$ROOT/$f")
        [ "$n" -gt 30000 ] && echo "lint-skill-size: WARN $f is $n chars; only its first 20,000 survive re-injection after a compaction." >&2
    done < <(git -C "$ROOT" diff --cached --name-only 2>/dev/null)
fi

exit $fail
