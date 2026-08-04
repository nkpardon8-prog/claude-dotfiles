#!/bin/bash
# test-lint-skill-size.sh - fixture-based test for lint-skill-size.sh.
# Uses a throwaway git repo masquerading as $HOME/.claude-dotfiles via a
# HOME override, so no fixture ever touches the real repo.
# bash 3.2 compatible.

set -u
# Resolved from THIS FILE's location, not from $HOME (2026-08-04). The $HOME form made this
# harness rc=127 on a CI runner - HOME=/home/runner there and the checkout lives under
# /home/runner/work/..., so `cp` could not find the lint and all ten cases failed with 127.
# It was enrolled in CI while still hard-coding a developer-machine path, so the job it was
# added to had never once actually exercised it: the harness written to prove a guard was
# itself unreachable. Same pattern as the sibling test-secret-scan.sh.
_TLS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$_TLS_REPO/scripts/lint-commands/lint-skill-size.sh"
[ -f "$LINT" ] || { echo "FATAL: lint not found at $LINT (repo root resolved to $_TLS_REPO)" >&2; exit 2; }
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

# ALL FIVE guarded files must exist in the fixture. Until 2026-08-04 only three were created,
# and every --all case below passed while commands/codex-review.md and commands/implement.md
# were ABSENT - the lint simply skipped the rules it could not reach. The new guarded-file
# check in the lint caught this fixture, which is the point: a fixture missing two of the five
# targets was quietly proving less than its case names claimed.
mk "$ROOT/commands/codex-review.md" 5000 1 1000
mk "$ROOT/commands/implement.md"    5000 1 1000

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

# #190b / #201 (round-5 review): the ROOT guard proved commands/ EXISTED but not that any
# guarded file did, so a tree with the directory present and the files renamed returned rc=0
# from --all having measured nothing. CI runs exactly --all, so renaming commands/mission.md
# would have switched the marker rule off and stayed green.
# ASSERTS THE REASON, NOT JUST THE RC. First draft of this case checked `rc == 1` and was
# VACUOUS: with the guarded-file check deleted the lint still exited 1 by another route, so
# the case stayed green under mutation and proved nothing. Keying on the specific message
# makes it discriminate - mutation-verified in BOTH directions.
# RESET ALL FIVE guarded files to a PASSING state first, and assert that baseline, before
# changing the one thing under test. Earlier fixtures deliberately leave files broken (oversize
# post-compact-resume, a too-deep marker in pre-compact), and those persist - so without this
# reset `--all` exits 1 for an unrelated reason and NO later case can discriminate. This is the
# second time that masking silently produced a vacuous case here; the baseline assertion below
# is what makes it impossible a third time, because a dirty fixture now fails loudly and
# immediately rather than quietly propping up the case that follows.
mk "$ROOT/commands/post-compact-resume.md" 19000 0 0
for _g in mission pre-compact codex-review implement; do
    mk "$ROOT/commands/$_g.md" 5000 1 1000
done
_base=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
check "fixture baseline is CLEAN before the renamed-target case (else it cannot discriminate)" 0 "$_base"

mv "$ROOT/commands/mission.md" "$ROOT/commands/mission-renamed.md"
_out=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all 2>&1 >/dev/null)
_rc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
# BOTH the reason AND a non-zero exit. Message-only was itself a vacuous assertion: deleting
# the `exit 1` left the lint printing its complaint and then PASSING, and this case stayed
# green (round-7 review, reproduced). A guard that reports a violation and exits 0 is not a
# guard. rc-only is equally weak here - rc=1 is reachable by other routes - so assert the pair.
check "a RENAMED guarded file fails FOR THAT REASON and EXITS NON-ZERO" \
      "reason=1 rc=nonzero" \
      "reason=$(printf '%s' "$_out" | grep -c 'guarded file(s) absent.*commands/mission\.md') rc=$([ "$_rc" -ne 0 ] && echo nonzero || echo zero)"
mv "$ROOT/commands/mission-renamed.md" "$ROOT/commands/mission.md"

# The same guard must NOT fire in --staged, which reads the index via GITROOT and never
# consults $ROOT. Firing there failed runs for a path they do not use, and forced the
# secret-scan fixture to mkdir an EMPTY commands/ to get past it - passing by having nothing
# to lint, the very masquerade this part exists to remove.
_ns="$TMP/nostaged"; mkdir -p "$_ns"
( cd "$_ns" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
cp "$LINT" "$_ns/lint.sh"
rc=$( cd "$_ns" && HOME="$FAKE_HOME" bash "$_ns/lint.sh" --staged >/dev/null 2>&1; echo $? )
check "--staged does NOT fail for a missing ROOT/commands (guard is --all scoped)" 0 "$rc"

# #101/#102: a PER-FILE measurement failure (unreadable/undecodable) left `n` empty, so
# `[ "$n" -gt 20000 ]` errored with "integer expression expected" and the lint exited 0.
# The preflight only covers a MISSING python3, not a file it cannot read.
mk "$ROOT/commands/post-compact-resume.md" 25000 0 0
mk "$ROOT/commands/mission.md" 30000 1 1000
chmod 000 "$ROOT/commands/post-compact-resume.md"
if [ "$(id -u)" -eq 0 ]; then
    # NOT `check 1 1`. That asserted a tautology and still incremented the pass counter, so a
    # root container reported "N passed" while one case had not been exercised at all - it
    # inflated the very number this mission cites as its proof. A skip is now visible and
    # counted as a skip.
    printf '  SKIP: an unmeasurable guarded file fails closed (running as root; chmod 000 has no effect)\n'
else
    rc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
    check "an unmeasurable guarded file fails closed (Rule 1 / chars_of)" 1 "$rc"
fi
chmod 644 "$ROOT/commands/post-compact-resume.md"

# Rule 2's TWIN, which no test covered until 2026-08-04. The round-5 reviewer mutation-proved
# the gap: reverting marker_pos's `|| echo -2` AND its -2 branch left this harness at 10/0, so
# half the per-file fail-closed fix could regress silently while Rule 1's half stayed guarded.
# mission.md is a marker-rule file, so an unreadable one exercises marker_pos, not chars_of.
if [ "$(id -u)" -eq 0 ]; then
    printf '  SKIP: an unmeasurable MARKER file fails closed (running as root)\n'
else
    # TWO things make this case discriminate, both learned the hard way here:
    #  1. post-compact-resume.md is restored to a PASSING size first. The Rule-1 case above
    #     leaves it at 25000 chars (over the 20000 ceiling) and never shrinks it, so every
    #     later --all run exits 1 for THAT reason - a first draft of this case asserted rc=1
    #     and passed under every mutation, proving nothing.
    #  2. It asserts the specific stderr MESSAGE, not the rc. rc=1 is reachable by many
    #     routes; only this message means "the marker rule could not measure its file".
    mk "$ROOT/commands/post-compact-resume.md" 19000 0 0
    chmod 000 "$ROOT/commands/mission.md"
    _mout=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all 2>&1 >/dev/null)
    _mrc=$(HOME="$FAKE_HOME" bash "$LINT_COPY" --all >/dev/null 2>&1; echo $?)
    chmod 644 "$ROOT/commands/mission.md"
    # Reason AND exit code, for the same reason as the renamed-target case above: removing
    # `fail=1` leaves the message printed and the lint passing.
    check "an unmeasurable MARKER file fails closed (Rule 2 / marker_pos)" \
          "reason=1 rc=nonzero" \
          "reason=$(printf '%s' "$_mout" | grep -c 'commands/mission\.md could not be measured') rc=$([ "$_mrc" -ne 0 ] && echo nonzero || echo zero)"
fi

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
