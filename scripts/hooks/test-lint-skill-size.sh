#!/bin/bash
# test-lint-skill-size.sh - fixture-based test for lint-skill-size.sh.
# Uses a throwaway git repo masquerading as $HOME/.claude-dotfiles via a
# HOME override, so no fixture ever touches the real repo.
# bash 3.2 compatible.

set -u
LINT="$HOME/.claude-dotfiles/scripts/lint-commands/lint-skill-size.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/lint-size-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
ROOT="$FAKE_HOME/.claude-dotfiles"
mkdir -p "$ROOT/commands"
cp "$LINT" "$TMP/lint.sh"

pass=0; fail=0
check() { # check <desc> <expected-rc> <actual-rc>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); else
        echo "FAIL: $1 (expected rc=$2 got rc=$3)" >&2; fail=$((fail+1)); fi
}

mk() { python3 -c "
import sys
n=int(sys.argv[2]); marker=sys.argv[3]=='1'; pos=int(sys.argv[4])
s='x'*pos + ('<!-- CONTRACT-CORE-END -->\n' if marker else '')
s += 'y'*max(0, n-len(s))
open(sys.argv[1],'w').write(s[:n] if not marker else s)
" "$1" "$2" "$3" "$4"; }

# Fixture 1: post-compact-resume over the ceiling -> FAIL
mk "$ROOT/commands/post-compact-resume.md" 20500 0 0
mk "$ROOT/commands/mission.md" 30000 1 1000
mk "$ROOT/commands/pre-compact.md" 30000 1 1000
rc=$(HOME="$FAKE_HOME" bash "$TMP/lint.sh" --all >/dev/null 2>&1; echo $?)
check "oversize post-compact-resume fails" 1 "$rc"

# Fixture 2: everything within limits -> PASS
mk "$ROOT/commands/post-compact-resume.md" 19000 0 0
rc=$(HOME="$FAKE_HOME" bash "$TMP/lint.sh" --all >/dev/null 2>&1; echo $?)
check "all-good passes" 0 "$rc"

# Fixture 3: marker too deep -> FAIL
mk "$ROOT/commands/mission.md" 30000 1 19800
rc=$(HOME="$FAKE_HOME" bash "$TMP/lint.sh" --all >/dev/null 2>&1; echo $?)
check "marker beyond 19500 fails" 1 "$rc"

# Fixture 4: marker missing entirely -> FAIL
mk "$ROOT/commands/mission.md" 30000 0 0
rc=$(HOME="$FAKE_HOME" bash "$TMP/lint.sh" --all >/dev/null 2>&1; echo $?)
check "missing marker fails" 1 "$rc"

# Fixture 5: --staged mode ignores unstaged violations (empty staged set)
mk "$ROOT/commands/post-compact-resume.md" 25000 0 0
mk "$ROOT/commands/mission.md" 30000 1 1000
git -C "$ROOT" init -q 2>/dev/null
rc=$(HOME="$FAKE_HOME" bash "$TMP/lint.sh" --staged >/dev/null 2>&1; echo $?)
check "staged mode with nothing staged passes" 0 "$rc"

# Fixture 6: --staged mode catches a staged violation
git -C "$ROOT" add commands/post-compact-resume.md 2>/dev/null
rc=$(HOME="$FAKE_HOME" bash "$TMP/lint.sh" --staged >/dev/null 2>&1; echo $?)
check "staged oversize fails" 1 "$rc"

echo "test-lint-skill-size: $pass passed, $fail failed"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
