#!/usr/bin/env bash
# test-codex-build-chunk.sh — proof for codex-build-chunk.sh, the ONE place Codex may write code.
#
# Hermetic: real throwaway git repos + real linked worktrees, and a STUB standing in for the codex
# binary (CODEX_BUILD_CHUNK_CMD) so no model is ever invoked. The stub is the point - it lets the
# suite drive the exact misbehaviours the wrapper exists to catch (edited nothing, ran git, touched
# the mission bridge), which a real Codex run could not be made to do on demand.
#
# HOUSE RULE: every assertion carries a NEGATIVE CONTROL. This wrapper's whole job is REFUSING, so a
# suite of refusals proves nothing on its own - each refusal is paired with the same fixture minus
# the guarded condition, which must reach `ok`.
#
# Emits a final `PASS: N  FAIL: M` line and exits nonzero on any FAIL.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-$HERE/../codex-build-chunk.sh}"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "${2:-}"; }

UNIQ="tcbc-$$-$(date +%s)"
WORK="${TMPDIR:-/tmp}/${UNIQ}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

printf 'test-codex-build-chunk\n  sut: %s\n' "$SUT"
[ -r "$SUT" ] || { printf 'FATAL: cannot read %s\n' "$SUT"; exit 2; }

# ── stubs standing in for the codex binary ──────────────────────────────────────────────────────
mk_stub() {  # mk_stub <name> <body-run-inside-the--C-dir>
  p="$WORK/stub-$1"
  {
    printf '#!/bin/bash\n'
    printf '# args: exec [flags] -C <dir> -\n'
    printf 'd=""; prev=""\n'
    printf 'for a in "$@"; do [ "$prev" = "-C" ] && d="$a"; prev="$a"; done\n'
    printf 'cat >/dev/null\n'          # drain the prompt on stdin, like codex does
    printf 'cd "$d" || exit 1\n'
    printf '%s\n' "$2"
    printf 'exit 0\n'
  } > "$p"
  chmod +x "$p"
  printf '%s' "$p"
}
STUB_EDIT=$(mk_stub edit    'printf "changed\n" >> src.txt')
STUB_NOOP=$(mk_stub noop    ':')
STUB_GIT=$(mk_stub  gitcommit 'printf "x\n" >> src.txt; git add -A >/dev/null 2>&1; git -c user.email=a@b -c user.name=c commit -qm mutant >/dev/null 2>&1')
STUB_ADD=$(mk_stub  gitadd  'printf "x\n" >> src.txt; git add -A >/dev/null 2>&1')
STUB_BRIDGE=$(mk_stub bridge 'printf "x\n" >> src.txt; printf "forged\n" > MISSION.deadbeef.md')

PROMPT="$WORK/prompt.txt"; printf 'make the mechanical change\n' > "$PROMPT"

# ── fixture builders ────────────────────────────────────────────────────────────────────────────
new_repo() {  # new_repo <name> -> prints main-tree path
  r="$WORK/$1"; mkdir -p "$r"
  ( cd "$r" && git init -q . && printf 'seed\n' > src.txt && git add -A >/dev/null 2>&1 \
    && git -c user.email=a@b -c user.name=c commit -qm seed >/dev/null 2>&1 )
  printf '%s' "$r"
}
new_worktree() {  # new_worktree <repo> <name> -> prints linked worktree path
  w="$WORK/wt-$2"
  ( cd "$1" && git worktree add -q -b "b-$2" "$w" >/dev/null 2>&1 )
  printf '%s' "$w"
}
run_sut() {  # run_sut <stub> <dir> -> sets RC, STATUS
  o="$WORK/out-$RANDOM.txt"
  CODEX_BUILD_CHUNK_CMD="$1" bash "$SUT" "$PROMPT" "$o" "$2" >/dev/null 2>&1
  RC=$?
  STATUS=$(cat "$o.status" 2>/dev/null)
}

# ── 1. HAPPY PATH: linked worktree, clean, stub edits a file -> ok ──────────────────────────────
R=$(new_repo repo1); W=$(new_worktree "$R" a)
run_sut "$STUB_EDIT" "$W"
[ "$RC" = 0 ] && [ "$STATUS" = ok ] && pass "linked worktree + a real edit -> ok" \
  || fail "happy path" "rc=$RC status=$STATUS"

# ── 2. MAIN WORKING TREE IS REFUSED (the load-bearing safety property) ──────────────────────────
# .git/ lives inside a main tree, so workspace-write would hand Codex git state and the bridge.
R2=$(new_repo repo2)
run_sut "$STUB_EDIT" "$R2"
[ "$STATUS" = refused-main-worktree ] && pass "a MAIN working tree is refused (gitdir inside the writable root)" \
  || fail "main worktree not refused" "rc=$RC status=$STATUS"

# ── 3. NEGATIVE CONTROL for 2: the same repo's LINKED worktree is accepted ──────────────────────
W2=$(new_worktree "$R2" b)
run_sut "$STUB_EDIT" "$W2"
[ "$STATUS" = ok ] && pass "the same repo's LINKED worktree is accepted (control for 2)" \
  || fail "linked worktree of repo2" "rc=$RC status=$STATUS"

# ── 4. ZERO CHANGES IS A FAILURE, not an ok ─────────────────────────────────────────────────────
R4=$(new_repo repo4); W4=$(new_worktree "$R4" d)
run_sut "$STUB_NOOP" "$W4"
[ "$STATUS" = no-changes ] && [ "$RC" != 0 ] && pass "a run that edits nothing FAILS (never a silent ok)" \
  || fail "no-op not failed" "rc=$RC status=$STATUS"

# ── 5. NEGATIVE CONTROL for 4: identical fixture, stub that edits -> ok ─────────────────────────
R5=$(new_repo repo5); W5=$(new_worktree "$R5" e)
run_sut "$STUB_EDIT" "$W5"
[ "$STATUS" = ok ] && pass "identical fixture WITH an edit reaches ok (control for 4)" \
  || fail "control for no-op" "rc=$RC status=$STATUS"

# ── 6. CODEX RUNNING git commit IS CAUGHT (instruction alone is not a control) ──────────────────
R6=$(new_repo repo6); W6=$(new_worktree "$R6" f)
run_sut "$STUB_GIT" "$W6"
[ "$STATUS" = refused-git-moved ] && pass "a Codex that COMMITS is caught (HEAD moved)" \
  || fail "git commit not caught" "rc=$RC status=$STATUS"

# ── 7. CODEX RUNNING git add IS CAUGHT (staged index, HEAD unmoved) ─────────────────────────────
R7=$(new_repo repo7); W7=$(new_worktree "$R7" g)
run_sut "$STUB_ADD" "$W7"
[ "$STATUS" = refused-git-moved ] && pass "a Codex that STAGES is caught (index dirty, HEAD unmoved)" \
  || fail "git add not caught" "rc=$RC status=$STATUS"

# ── 8. TOUCHING THE MISSION BRIDGE IS REFUSED (the absolute half of the rule) ───────────────────
R8=$(new_repo repo8); W8=$(new_worktree "$R8" h)
run_sut "$STUB_BRIDGE" "$W8"
[ "$STATUS" = refused-touched-bridge ] && pass "writing a MISSION.*.md is refused (bridge stays Claude-only)" \
  || fail "bridge write not refused" "rc=$RC status=$STATUS"

# ── 9. A DIRTY WORKTREE IS REFUSED BEFORE Codex runs ────────────────────────────────────────────
R9=$(new_repo repo9); W9=$(new_worktree "$R9" i)
printf 'preexisting\n' >> "$W9/src.txt"
run_sut "$STUB_EDIT" "$W9"
[ "$STATUS" = refused-dirty-worktree ] && pass "a dirty worktree is refused (before/after diff would be a lie)" \
  || fail "dirty worktree not refused" "rc=$RC status=$STATUS"

# ── 10. NEGATIVE CONTROL for 9: same worktree, cleaned -> ok ────────────────────────────────────
( cd "$W9" && git checkout -q -- . )
run_sut "$STUB_EDIT" "$W9"
[ "$STATUS" = ok ] && pass "the same worktree once CLEAN reaches ok (control for 9)" \
  || fail "control for dirty" "rc=$RC status=$STATUS"

# ── 11. A NON-git directory is refused ──────────────────────────────────────────────────────────
ND="$WORK/notgit"; mkdir -p "$ND"
run_sut "$STUB_EDIT" "$ND"
case "$STATUS" in refused-not-git|refused-not-toplevel) pass "a non-git directory is refused" ;;
  *) fail "non-git not refused" "rc=$RC status=$STATUS" ;; esac

# ── 12. A SUBDIRECTORY of a worktree is refused (would leave the rest unaudited) ────────────────
R12=$(new_repo repo12); W12=$(new_worktree "$R12" l); mkdir -p "$W12/sub"
run_sut "$STUB_EDIT" "$W12/sub"
[ "$STATUS" = refused-not-toplevel ] && pass "a SUBDIR of a worktree is refused (not the toplevel)" \
  || fail "subdir not refused" "rc=$RC status=$STATUS"

# ── 13. The no-git + no-bridge constraints actually reach the model's prompt ────────────────────
R13=$(new_repo repo13); W13=$(new_worktree "$R13" m)
CAP="$WORK/captured-prompt.txt"
STUB_CAP=$(mk_stub capture ':')
# rewrite the capture stub so it saves stdin instead of draining it
{ printf '#!/bin/bash\n'; printf 'd=""; prev=""\n';
  printf 'for a in "$@"; do [ "$prev" = "-C" ] && d="$a"; prev="$a"; done\n';
  printf 'cat > "%s"\n' "$CAP"; printf 'cd "$d" && printf "x\\n" >> src.txt\n'; printf 'exit 0\n'; } > "$STUB_CAP"
chmod +x "$STUB_CAP"
run_sut "$STUB_CAP" "$W13"
if grep -q 'Do NOT run git' "$CAP" 2>/dev/null && grep -q 'MISSION' "$CAP" 2>/dev/null \
   && grep -q 'make the mechanical change' "$CAP" 2>/dev/null; then
  pass "the hard constraints AND the caller's prompt both reach the model"
else fail "prompt preamble" "captured=$(head -c 120 "$CAP" 2>/dev/null)"; fi

printf '\nPASS: %s  FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
