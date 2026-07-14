#!/usr/bin/env bash
# test-mission-drift-check.sh — proof for the mission stale-claim guard.
#
# Covers every load-bearing assumption the 3-reviewer round flagged:
#   T1 incident replay  — converge → edit → PART-DONE BLOCKED (rc=4); re-converge → PART-DONE ok.
#   T2 append-gating    — re-emit converged line at a CHANGED tree stamps NO new snapshot (no drift-masking).
#   T3 untracked content— fingerprint changes on untracked-CONTENT edit (not just add); .gitignore'd noise excluded.
#   T4 determinism      — same tree hashes identically across runs AND across git-config toggles (pinned flags).
#   T5 skip-not-block   — non-git / unborn-HEAD / no-snapshot(legacy) never false-block PART-DONE.
#   T6 scratch-exclusion— mission-log appends (MISSION.*) do NOT change the fingerprint.
#   T7 large multi-part — the part-N converged snapshot is found + enforced in a big multi-part log.
#   T8 stdout purity    — the converged log write emits EXACTLY one status line (snapshot emit is silent).
# Real throwaway git repos + the real mission-write.sh verbs. macOS bash 3.2 compatible.

set -u
MW="$HOME/.claude-dotfiles/scripts/hooks/mission-write.sh"
DC="$HOME/.claude-dotfiles/scripts/hooks/mission-drift-check.sh"
LIB="$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"
. "$LIB" || { echo "FATAL: cannot source $LIB"; exit 2; }

PASS=0; FAIL=0; TMPS=""
ok()  { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
has()   { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 [missing '$1' in: $2]" ;; esac; }
hasnt() { case "$2" in *"$1"*) bad "$3 [unexpected '$1']" ;; *) ok "$3" ;; esac; }
eq()    { [ "$1" = "$2" ] && ok "$3" || bad "$3 [expected '$1' == '$2']"; }
ne()    { [ "$1" != "$2" ] && ok "$3" || bad "$3 [expected '$1' != '$2']"; }

newrepo() {
  _r=$(mktemp -d "${TMPDIR:-/tmp}/mdt.XXXXXX"); TMPS="$TMPS $_r"
  ( cd "$_r" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'v1\n' > code.txt && git add code.txt && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$_r"
}
mlogq() { bash "$MW" log "$1" "$2" "$3" "$4" >/dev/null 2>&1; }
# converge <sid> <root> <part> <impl_round> <review_a> <review_b> [with_part_start=1]
converge() {
  _c_sid=$1; _c_root=$2; _c_p=$3; _c_ir=$4; _c_ra=$5; _c_rb=$6; _c_ps=${7:-1}
  [ "$_c_ps" = 1 ] && mlogq "$_c_sid" "$_c_root" "[mission] PART-START part=$_c_p name=alpha" "m$_c_p-part-start"
  mlogq "$_c_sid" "$_c_root" "[mission] part=$_c_p name=alpha phase=implement round=$_c_ir dry=0" "m$_c_p-implement-r$_c_ir-d0"
  mlogq "$_c_sid" "$_c_root" "[mission] part=$_c_p name=alpha phase=review round=$_c_ra dry=1 findings=0" "m$_c_p-review-r$_c_ra-d1"
  mlogq "$_c_sid" "$_c_root" "[mission] part=$_c_p name=alpha phase=review round=$_c_rb dry=2 findings=0" "m$_c_p-review-r$_c_rb-d2"
  mlogq "$_c_sid" "$_c_root" "[mission] live-verify part=$_c_p round=$_c_rb status=n/a reason=tooling" "m$_c_p-live-verify-r$_c_rb"
}

echo "== T1 incident replay =="
R=$(newrepo); S=t1
bash "$MW" create "$S" "$R" "plan" >/dev/null
converge "$S" "$R" 1 1 1 2
DONE_OK=$(bash "$MW" log "$S" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done")
has "log ok" "$DONE_OK" "T1a happy-path PART-DONE accepted (no drift)"
# fresh mission, drift after converge
R=$(newrepo); S=t1b
bash "$MW" create "$S" "$R" "plan" >/dev/null
converge "$S" "$R" 1 1 1 2
printf 'edited-after-converge\n' > "$R/code.txt"
DONE_DRIFT=$(bash "$MW" log "$S" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done")
has "rc=4" "$DONE_DRIFT" "T1b drifted PART-DONE refused rc=4"
has "convergence-stale" "$DONE_DRIFT" "T1b refusal reason is convergence-stale"
# re-converge at the new tree, PART-DONE now passes
converge "$S" "$R" 1 2 3 4 0
DONE_RE=$(bash "$MW" log "$S" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done")
has "log ok" "$DONE_RE" "T1b PART-DONE clears after re-convergence at new tree"

echo "== T2 append-gating (no drift masking) =="
R=$(newrepo); S=t2
bash "$MW" create "$S" "$R" "plan" >/dev/null
converge "$S" "$R" 1 1 1 2
SNAP1=$(grep -a 'SNAPSHOT part=1' "$R/MISSION.$S.log" | sed -n 's/.*tree=\([A-Za-z0-9]*\).*/\1/p' | head -1)
printf 'changed\n' > "$R/code.txt"
# re-emit the SAME converged review line at the changed tree — dedup-idempotent, must NOT re-stamp
mlogq "$S" "$R" "[mission] part=1 name=alpha phase=review round=2 dry=2 findings=0" "m1-review-r2-d2"
SNAP_COUNT=$(grep -ac 'SNAPSHOT part=1 kind=converged' "$R/MISSION.$S.log")
eq "1" "$SNAP_COUNT" "T2 exactly one converged snapshot for part 1 (re-emit did not re-stamp)"
SNAP_NOW=$(grep -a 'SNAPSHOT part=1' "$R/MISSION.$S.log" | sed -n 's/.*tree=\([A-Za-z0-9]*\).*/\1/p' | tail -1)
eq "$SNAP1" "$SNAP_NOW" "T2 snapshot tree unchanged (drift not masked)"

echo "== T3 untracked content + gitignore =="
R=$(newrepo)
FP0=$(_mission_tree_fingerprint "$R")
printf 'a\n' > "$R/untracked.txt"
FP1=$(_mission_tree_fingerprint "$R")
ne "$FP0" "$FP1" "T3a adding an untracked file changes the fingerprint"
printf 'b-different\n' > "$R/untracked.txt"
FP2=$(_mission_tree_fingerprint "$R")
ne "$FP1" "$FP2" "T3b modifying UNTRACKED CONTENT changes the fingerprint (the blind-spot fix)"
( cd "$R" && printf 'build/\n' > .gitignore && git add .gitignore && git commit -qm ignore ) >/dev/null 2>&1
FP_BASE=$(_mission_tree_fingerprint "$R")
( cd "$R" && mkdir -p build && printf 'junk\n' > build/artifact.o ) >/dev/null 2>&1
FP_IGN=$(_mission_tree_fingerprint "$R")
eq "$FP_BASE" "$FP_IGN" "T3c .gitignore'd build artifact does NOT change the fingerprint"

echo "== T4 determinism =="
R=$(newrepo)
printf 'staged\n' > "$R/s.txt"; ( cd "$R" && git add s.txt ) >/dev/null 2>&1
FA=$(_mission_tree_fingerprint "$R")
FB=$(_mission_tree_fingerprint "$R")
eq "$FA" "$FB" "T4a same tree hashes identically across runs"
( cd "$R" && git config color.diff always && git config core.autocrlf true && git config diff.noprefix true ) >/dev/null 2>&1
FC=$(_mission_tree_fingerprint "$R")
eq "$FA" "$FC" "T4b hash stable across hostile git-config toggles (pinned flags hold)"

echo "== T5 skip-not-block =="
eq "nogit" "$(_mission_tree_fingerprint /tmp)" "T5a non-git root -> nogit sentinel"
R5=$(mktemp -d "${TMPDIR:-/tmp}/mdt.XXXXXX"); TMPS="$TMPS $R5"; ( cd "$R5" && git init -q ) >/dev/null 2>&1
eq "nohead" "$(_mission_tree_fingerprint "$R5")" "T5b unborn HEAD -> nohead sentinel"
# legacy: converge, DELETE the snapshot line, drift, PART-DONE must still pass (skip on missing stamp)
R=$(newrepo); S=t5
bash "$MW" create "$S" "$R" "plan" >/dev/null
converge "$S" "$R" 1 1 1 2
grep -av 'SNAPSHOT' "$R/MISSION.$S.log" > "$R/MISSION.$S.log.tmp" && mv "$R/MISSION.$S.log.tmp" "$R/MISSION.$S.log"
printf 'edited\n' > "$R/code.txt"
DONE_LEGACY=$(bash "$MW" log "$S" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done")
has "log ok" "$DONE_LEGACY" "T5c legacy mission (no snapshot) is NOT false-blocked"

echo "== T6 scratch-file exclusion =="
R=$(newrepo); S=t6
bash "$MW" create "$S" "$R" "plan" >/dev/null
FP_PRE=$(_mission_tree_fingerprint "$R")
mlogq "$S" "$R" "[mission] part=1 name=alpha phase=implement round=1 dry=0" "m1-implement-r1-d0"
mlogq "$S" "$R" "[mission] part=1 name=alpha phase=review round=1 dry=1 findings=0" "m1-review-r1-d1"
FP_POST=$(_mission_tree_fingerprint "$R")
eq "$FP_PRE" "$FP_POST" "T6 mission-log appends (MISSION.*) do NOT change the fingerprint"

echo "== T7 large multi-part log =="
R=$(newrepo); S=t7
bash "$MW" create "$S" "$R" "plan" >/dev/null
# part 1: work, converge, done (clean)
printf 'p1\n' > "$R/code.txt"
converge "$S" "$R" 1 1 1 2
mlogq "$S" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done"
# part 2: work (changes tree), converge, done (clean) — proves part-2 snapshot found among many lines
printf 'p2\n' > "$R/code.txt"
converge "$S" "$R" 2 1 1 2
D2=$(bash "$MW" log "$S" "$R" "[mission] PART-DONE part=2 (converged)" "m2-part-done")
has "log ok" "$D2" "T7a part-2 PART-DONE clean in a large log"
# part 3: work, converge, DRIFT, done -> blocked (snapshot found + enforced deep in the log)
printf 'p3\n' > "$R/code.txt"
converge "$S" "$R" 3 1 1 2
printf 'p3-drift\n' > "$R/code.txt"
D3=$(bash "$MW" log "$S" "$R" "[mission] PART-DONE part=3 (converged)" "m3-part-done")
has "convergence-stale" "$D3" "T7b part-3 drift caught in a large multi-part log"
LINES=$(grep -ac '' "$R/MISSION.$S.log")
[ "$LINES" -ge 15 ] && ok "T7c log is genuinely large ($LINES lines)" || bad "T7c log too small ($LINES)"

echo "== T8 stdout purity =="
R=$(newrepo); S=t8
bash "$MW" create "$S" "$R" "plan" >/dev/null
mlogq "$S" "$R" "[mission] part=1 name=alpha phase=implement round=1 dry=0" "m1-implement-r1-d0"
mlogq "$S" "$R" "[mission] part=1 name=alpha phase=review round=1 dry=1 findings=0" "m1-review-r1-d1"
CONV_OUT=$(bash "$MW" log "$S" "$R" "[mission] part=1 name=alpha phase=review round=2 dry=2 findings=0" "m1-review-r2-d2")
CONV_LINES=$(printf '%s\n' "$CONV_OUT" | grep -c '')
eq "1" "$CONV_LINES" "T8 converged log write prints exactly one status line (snapshot emit silent)"
has "SNAPSHOT part=1" "$(cat "$R/MISSION.$S.log")" "T8 (sanity) snapshot WAS stamped despite silent stdout"

for t in $TMPS; do rm -rf "$t"; done
echo ""
echo "==================================================="
echo "  mission-drift-check:  PASS=$PASS  FAIL=$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ] || exit 1
