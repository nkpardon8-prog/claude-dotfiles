#!/usr/bin/env bash
# 13 — the resume READ strategy must survive log rotation. Fix-plan #5. Drives the REAL
# _mission_log_rotate (lib:506) and proves `tail -n 40` of the live log loses an archived
# lifecycle line that grep-over-(live + newest archive) recovers.
#
# Load-bearing contract: mission.md:79/281 read resume state via `tail -n 40` of the LIVE log only.
# _mission_log_rotate archives the OLDEST HALF (gzip) to .mission-backups/ and keeps the newest
# half. A lifecycle line that rotated into the archive is INVISIBLE to `tail -n 40` → resume reads
# the wrong (or no) lifecycle state. The fix replaces tail-40 with `grep '[mission] '` over the
# full live log PLUS the newest archive.
#
# NEGATIVE CONTROL (controllable precondition): A1 is the RED arm — it REQUIRES `tail -n 40` of the
# live log to MISS the archived lifecycle line (==0 matches). That failing-by-design read is what
# proves the seam is real; A2/A3 prove the grep-over-rotation strategy recovers it (GREEN).
#
# Rotation is forced DETERMINISTICALLY (one controlled call with a tiny threshold) so exactly one
# archive is produced and the lifecycle line lands in it — avoiding multi-rotation flakiness.
export MISSION_LOG_MAX_BYTES=1000000      # high during setup → no auto-rotation mid-append
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "13-resume-window-survives-rotation"

. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh" 2>/dev/null \
  || atest_infra "cannot source mission-bridge.sh"

SID="atest13"
ROOT="$ATEST_DIR/anchor"; mkdir -p "$ROOT"
LOG="$ROOT/MISSION.${SID}.log"
ARCDIR="$ROOT/.mission-backups"
mission_create "$SID" "$ROOT" "MISSION MODE: build — t13" >/dev/null 2>&1 \
  || atest_infra "mission_create failed"

# Phase 1: the lifecycle line we want resume to recover, then a few fillers (so it is in the
# OLDEST half that rotation archives).
mission_log_append "$SID" "$ROOT" "[mission] MISSION-CLEARED reason=phase1-done" "m-clear" >/dev/null 2>&1 \
  || atest_infra "lifecycle append failed"
i=1
while [ "$i" -le 10 ]; do
  mission_log_append "$SID" "$ROOT" "[mission] part=1 phase=fix round=$i dry=0 findings=0" "pre-$i" >/dev/null 2>&1 \
    || atest_infra "pre-rotation filler append failed (i=$i)"
  i=$((i + 1))
done

# Force EXACTLY ONE rotation: threshold=1 archives the oldest half (incl. the lifecycle line),
# keeps the newest half. Temporary assignment applies to this function call only.
MISSION_LOG_MAX_BYTES=1 _mission_log_rotate "$LOG" "$ROOT" "$SID" 2>/dev/null \
  || atest_infra "_mission_log_rotate returned nonzero"

# locate the (single) newest archive; handle both gzip (.gz) and no-gzip (.txt) builds.
ARC=$(ls -t "$ARCDIR"/MISSION.${SID}.log.* 2>/dev/null | head -1)
[ -n "$ARC" ] || atest_infra "rotation produced no archive in $ARCDIR (cannot test grep-over-rotation)"
case "$ARC" in
  *.gz) DECOMP() { gzip -dc "$1" 2>/dev/null; } ;;
  *)    DECOMP() { cat "$1" 2>/dev/null; } ;;
esac
# setup sanity: the lifecycle line really is in the archive (not the live log).
DECOMP "$ARC" | grep -q 'MISSION-CLEARED' || atest_infra "setup: lifecycle line not in the archive — rotation kept it live; tune fillers"

# Phase 2: >40 more lines into the (now-small) live log so tail -n 40 cannot reach back to the
# rotation boundary, and append the genuine LAST round line at the very end.
i=1
while [ "$i" -le 45 ]; do
  mission_log_append "$SID" "$ROOT" "[mission] part=9 phase=fix round=$i dry=0 findings=0" "post-$i" >/dev/null 2>&1 \
    || atest_infra "post-rotation filler append failed (i=$i)"
  i=$((i + 1))
done
mission_log_append "$SID" "$ROOT" "[mission] part=9 phase=fix round=99 dry=1 findings=2" "round-last" >/dev/null 2>&1 \
  || atest_infra "last-round append failed"

# --- A1 (NEGATIVE CONTROL / RED arm): tail -n 40 of the LIVE log MISSES the archived clear ----
tail_hits=$(tail -n 40 "$LOG" 2>/dev/null | grep -c 'MISSION-CLEARED' | tr -d ' ')
[ "${tail_hits:-0}" = "0" ]
atest_assert "A1" "$?" "tail -n 40 of the live log still sees the lifecycle line (hits=$tail_hits) — then the seam is not reproduced (lifecycle line did not rotate far enough back); the test proves nothing about rotation loss."

# --- A2: grep over (newest archive + live log) RECOVERS the last lifecycle line ---------------
COMBINED=$({ DECOMP "$ARC"; cat "$LOG"; } 2>/dev/null)
last_lifecycle=$(printf '%s\n' "$COMBINED" | grep -E '\[mission\] (MISSION-|part=)' | grep 'MISSION-CLEARED' | tail -1)
case "$last_lifecycle" in
  *MISSION-CLEARED*) _a2=0 ;;
  *)                 _a2=1 ;;
esac
atest_assert "A2" "$_a2" "grep over (newest archive + live) did not recover the MISSION-CLEARED lifecycle line — the fix's resume read must union the live log with the newest archive, not tail -n 40 alone."

# --- A3: grep over (newest archive + live log) finds the genuine LAST round line --------------
last_round=$(printf '%s\n' "$COMBINED" | grep -E "^round-last"$'\t' )
[ -n "$last_round" ]
atest_assert "A3" "$?" "the last round line (round-last) was not found via grep over (archive + live) — resume cannot recover the most recent round/phase/dry state after rotation."

# ===============================================================================================
# Task 4: the GEN-SLICED reads (void-count + the PART-DONE live-verify precondition) must ALSO
# survive rotation — they read the archive-inclusive stream, so a VOID / live-verify / dry-round
# rotated into an archive is still seen. Two fresh hermetic sub-scenarios, deterministic rotation.
# ===============================================================================================
MWSH="$(cd "$HERE/.." && pwd)/mission-write.sh"
[ -f "$MWSH" ] || atest_infra "mission-write.sh not found at $MWSH"

# --- A4: a VOID rotated into an archive is still counted by void-count -------------------------
SIDB="atest13b"; ROOTB="$ATEST_DIR/anchorB"; mkdir -p "$ROOTB"
LOGB="$ROOTB/MISSION.${SIDB}.log"
bash "$MWSH" create "$SIDB" "$ROOTB" "MISSION MODE: build — t13b" >/dev/null 2>&1 \
  || atest_infra "13b create failed"
mission_log_append "$SIDB" "$ROOTB" "[mission] VOID part=1 phase=review round=1 reason=codex-unavailable" "m1-void-r1-earlyhdeadbeef" >/dev/null 2>&1 \
  || atest_infra "13b VOID append failed"
ib=1; while [ "$ib" -le 10 ]; do
  mission_log_append "$SIDB" "$ROOTB" "[mission] part=1 name=x phase=implement round=$ib dry=0 findings=0 padding padding" "b-pre-$ib" >/dev/null 2>&1
  ib=$((ib + 1))
done
MISSION_LOG_MAX_BYTES=1 _mission_log_rotate "$LOGB" "$ROOTB" "$SIDB" 2>/dev/null \
  || atest_infra "13b rotation failed"
ARCB=$(ls -1 "$ROOTB/.mission-backups/"MISSION.${SIDB}.log.* 2>/dev/null | head -1)
[ -n "$ARCB" ] || atest_infra "13b produced no archive"
# the VOID must be in the archive, not the live log (proves the seam)
{ case "$ARCB" in *.gz) gzip -dc "$ARCB" 2>/dev/null;; *) cat "$ARCB" 2>/dev/null;; esac; } | grep -q 'VOID part=1' \
  || atest_infra "13b: VOID did not rotate into the archive — tune fillers"
VCB=$(bash "$MWSH" void-count "$SIDB" "$ROOTB" 1 1 2>/dev/null)
[ "$VCB" = "1" ]
atest_assert "A4" "$?" "void-count did not recover a VOID rotated into the archive (got '$VCB', want 1) — the gen-sliced read must union archives + live log, not read the live log alone."

# --- A5: a live-verify + dry-round convergence that CROSSES a rotation still satisfies PART-DONE -
SIDC="atest13c"; ROOTC="$ATEST_DIR/anchorC"; mkdir -p "$ROOTC"
LOGC="$ROOTC/MISSION.${SIDC}.log"
bash "$MWSH" create "$SIDC" "$ROOTC" "MISSION MODE: build — t13c" >/dev/null 2>&1 \
  || atest_infra "13c create failed"
# live-verify first (post-convergence in §5, but here it is the OLDEST evidence so it rotates out),
# then the two adjacent dry review rounds. No actionable event after the live-verify ⇒ FRESH.
bash "$MWSH" log "$SIDC" "$ROOTC" "[mission] live-verify part=1 round=2 status=ok evidence=od:1377" "m1-live-verify-r2" >/dev/null 2>&1
bash "$MWSH" log "$SIDC" "$ROOTC" "[mission] part=1 name=x phase=review round=1 dry=1 findings=0" "m1-review-r1-d1" >/dev/null 2>&1
bash "$MWSH" log "$SIDC" "$ROOTC" "[mission] part=1 name=x phase=review round=2 dry=2 findings=0" "m1-review-r2-d2" >/dev/null 2>&1
MISSION_LOG_MAX_BYTES=1 _mission_log_rotate "$LOGC" "$ROOTC" "$SIDC" 2>/dev/null \
  || atest_infra "13c rotation failed"
ARCC=$(ls -1 "$ROOTC/.mission-backups/"MISSION.${SIDC}.log.* 2>/dev/null | head -1)
[ -n "$ARCC" ] || atest_infra "13c produced no archive"
# PART-DONE must PASS: the live-verify EXISTENCE + freshness + dry fold all read across the rotation.
PDC=$(bash "$MWSH" log "$SIDC" "$ROOTC" "[mission] PART-DONE part=1 (converged)" "m1-part-done" 2>/dev/null)
printf '%s' "$PDC" | grep -q 'log ok'
atest_assert "A5" "$?" "PART-DONE was not accepted across a rotation (status='$PDC') — the gen-sliced live-verify/dry-fold precondition must read the archive-inclusive stream so rotated evidence still satisfies convergence."

atest_report
