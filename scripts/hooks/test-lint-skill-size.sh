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

# THE COPY MUST LIVE INSIDE THE FIXTURE TREE (2026-08-03). The lint derives its ROOT from
# BASH_SOURCE - "a copy lints itself", by its own design - NOT from $HOME. The previous
# version copied it to $TMP/lint.sh and overrode HOME, so ROOT resolved to an unrelated
# ancestor of $TMP that holds no commands/: the lint matched no files and exited 0, and
# FOUR of the six cases below passed vacuously while asserting rc=1 behaviour that was
# never exercised. MEASURED: ROOT resolved to /private/var/folders/mc while the fixtures
# sat under $TMP/home/.claude-dotfiles.
#
# Placing the copy at its real relative position makes BASH_SOURCE resolve to the fixture
# tree, which is the only way these cases test anything. LINT_COPY is used everywhere
# below; $HOME is still overridden so nothing can reach the developer's real repo.
mkdir -p "$ROOT/scripts/lint-commands"
LINT_COPY="$ROOT/scripts/lint-commands/lint-skill-size.sh"
cp "$LINT" "$LINT_COPY"
# Kept so an accidental use of the old path fails loudly instead of silently linting nothing.
printf '#!/bin/bash\necho "test bug: invoke \$LINT_COPY, not this stub" >&2\nexit 99\n' > "$TMP/lint.sh"

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
rc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
check "oversize post-compact-resume fails" 1 "$rc"

# Fixture 2: everything within limits -> PASS
mk "$ROOT/commands/post-compact-resume.md" 19000 0 0
rc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
check "all-good passes" 0 "$rc"

# Fixture 3: marker too deep -> FAIL
mk "$ROOT/commands/mission.md" 30000 1 19800
rc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
check "marker beyond 19500 fails" 1 "$rc"

# Fixture 4: marker missing entirely -> FAIL
mk "$ROOT/commands/mission.md" 30000 0 0
rc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
check "missing marker fails" 1 "$rc"

# Fixture 5: --staged mode ignores unstaged violations (empty staged set)
mk "$ROOT/commands/post-compact-resume.md" 25000 0 0
mk "$ROOT/commands/mission.md" 30000 1 1000
git -C "$ROOT" init -q 2>/dev/null
# --staged is run WITH CWD INSIDE THE FIXTURE REPO. The lint reads the index via GITROOT
# (`git rev-parse --show-toplevel` of the CALLER's cwd), by deliberate design so a hook
# running in a linked worktree queries that worktree's index. Invoking it from the harness's
# own cwd therefore queried the DEVELOPER'S REAL repo index, where nothing oversized is
# staged - so "staged oversize fails" asserted rc=1 against a scan of the wrong repository
# and stayed green regardless of the fixture. Same class as the ROOT defect above: the guard
# could not reach its target and reported success.
rc=$(cd "$ROOT" && HOME="$FAKE_HOME" bash "$LINT_COPY" --staged >/dev/null 2>&1; echo $?)
check "staged mode with nothing staged passes" 0 "$rc"

# Fixture 6: --staged mode catches a staged violation
git -C "$ROOT" add commands/post-compact-resume.md 2>/dev/null
rc=$(cd "$ROOT" && HOME="$FAKE_HOME" bash "$LINT_COPY" --staged >/dev/null 2>&1; echo $?)
check "staged oversize fails" 1 "$rc"

# Fixture 7 (P4): the lint must FAIL CLOSED when ROOT does not resolve to a command tree.
# Run from outside its own tree, ROOT lands on an unrelated ancestor with no commands/, the
# file loop matches nothing and the old code exited 0 - a clean bill of health for a tree it
# never scanned. That defect is also what made fixtures 1-4 above vacuous for months.
cp "$LINT" "$TMP/orphan-lint.sh"
rc=$(HOME="$FAKE_HOME" bash "$TMP/orphan-lint.sh" --all >/dev/null 2>&1; echo $?)
check "lint fails closed when ROOT has no commands/" 1 "$rc"

# --- guard-integrity (2026-08-03, part 3). Three MEASURED fail-open paths in this lint,
# all the same class: it reported success having measured nothing.

# #190: an unknown argument was silently accepted (rc=0, linted nothing). The sibling
# lint-skill-contract.sh already exited 2 here; this one did not.
rc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --bogus >/dev/null 2>&1; echo $?)
check "unknown argument is refused, not silently accepted" 2 "$rc"

# #101/#102: a PER-FILE measurement failure (unreadable/undecodable) left `n` empty, so
# `[ "$n" -gt 20000 ]` errored with "integer expression expected" and the lint exited 0.
# The preflight only covers a MISSING python3, not a file it cannot read.
mk "$ROOT/commands/post-compact-resume.md" 25000 0 0
mk "$ROOT/commands/mission.md" 30000 1 1000
chmod 000 "$ROOT/commands/post-compact-resume.md"
if [ "$(id -u)" -eq 0 ]; then
    check "unmeasurable file fails closed (SKIPPED as root)" 1 1
else
    rc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
    check "an unmeasurable guarded file fails closed" 1 "$rc"
fi
chmod 644 "$ROOT/commands/post-compact-resume.md"

# #100: in --staged the content is read THROUGH a staging tempdir, and `|| return 0` made an
# unusable TMPDIR indistinguishable from "nothing staged" - so a broken mktemp cleared an
# OVERSIZE STAGED FILE. The dir is now created eagerly in the MAIN shell: created lazily
# inside resolve_content, the exit ran in a command substitution's subshell and was swallowed.
MKBIN="$TMP/mkbin"; mkdir -p "$MKBIN"
printf '#!/bin/sh\nexit 1\n' > "$MKBIN/mktemp"; chmod +x "$MKBIN/mktemp"
mk "$ROOT/commands/post-compact-resume.md" 25000 0 0
git -C "$ROOT" add commands/post-compact-resume.md 2>/dev/null
rc=$(cd "$ROOT" && HOME="$FAKE_HOME" PATH="$MKBIN:$PATH" bash "$LINT_COPY" --staged >/dev/null 2>&1; echo $?)
check "an unusable staging tempdir fails closed, not 'nothing staged'" 3 "$rc"

echo "test-lint-skill-size: $pass passed, $fail failed"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
