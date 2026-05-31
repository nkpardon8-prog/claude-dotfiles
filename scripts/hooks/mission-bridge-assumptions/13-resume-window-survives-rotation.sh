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

atest_report
