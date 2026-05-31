#!/usr/bin/env bash
# 10 — FAIL idtag must be ATTEMPT-scoped, not reason-scoped, or the 5-strike loop-breaker dies.
# Fix-plan #4. Exercises the REAL mission_log_append anchored-dedup (lib:775) to prove the
# idtag SCHEME — not the lib — decides whether 5 same-reason FAILs survive as 5 lines or
# collapse to 1.
#
# Load-bearing contract: mission.md:259 currently builds the FAIL idtag as `m<N>-fail-<reason-hash>`
# (reason-only). The lib dedups anchored on a LEADING `^<tag>\t` (lib:775), so 5 retries that fail
# for the SAME reason produce ONE log line → a "5 FAILs for the same part+phase" guard can never
# reach 5 → the autonomous loop-breaker is DEAD. The fix must make the idtag encode the ATTEMPT
# (e.g. `m<N>-fail-<reason>-<attempt>`), so each emission appends a distinct line.
#
# NEGATIVE CONTROL (controllable precondition): A1 emits 5 FAILs with an ATTEMPT-scoped idtag and
# requires 5 lines; A2 (the red arm proving the bug is real) emits 5 FAILs with a REASON-ONLY idtag
# and requires they collapse to 1. A2 going green is what proves A1's distinctness is load-bearing
# and that the lib dedup genuinely bites a reason-only scheme.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "10-fail-idtag-attempt-scoped"

. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh" 2>/dev/null \
  || atest_infra "cannot source mission-bridge.sh"

SID="atest10"
ROOT="$ATEST_DIR/anchor"; mkdir -p "$ROOT"
LOG="$ROOT/MISSION.${SID}.log"
mission_create "$SID" "$ROOT" "MISSION MODE: build — t10" >/dev/null 2>&1 \
  || atest_infra "mission_create failed"

REASON="bridge-write-rc2"        # the SAME failure reason every attempt
PART="m3"

# --- A1: ATTEMPT-scoped idtag → 5 distinct anchored FAIL lines (the fix) -----------
attempt=1
while [ "$attempt" -le 5 ]; do
  # FIX scheme: idtag carries the attempt counter, so the dedup never collapses retries.
  mission_log_append "$SID" "$ROOT" "[mission] FAIL ${PART} phase=fix reason=${REASON} attempt=${attempt}" \
    "${PART}-fail-${REASON}-${attempt}" >/dev/null 2>&1 \
    || atest_infra "attempt-scoped FAIL append failed (attempt=$attempt)"
  attempt=$((attempt + 1))
done
n_attempt=$(grep -cE "^${PART}-fail-${REASON}-[0-9]+"$'\t' "$LOG" 2>/dev/null | tr -d ' ')
[ -n "$n_attempt" ] && [ "$n_attempt" -eq 5 ]
atest_assert "A1" "$?" "attempt-scoped idtags produced ${n_attempt:-0} FAIL lines, expected 5 — the 5-strike loop-breaker cannot count attempts unless each FAIL appends a distinct line."

# --- A2 (NEGATIVE CONTROL): REASON-ONLY idtag → 5 emissions collapse to 1 ----------
# Proves the lib dedup is real AND that the CURRENT mission.md scheme (reason-hash, no attempt)
# is the bug: 5 identical-reason FAILs become one line, so the guard never fires.
attempt=1
while [ "$attempt" -le 5 ]; do
  mission_log_append "$SID" "$ROOT" "[mission] FAIL ${PART} phase=test reason=${REASON} attempt=${attempt}" \
    "${PART}-failonly-${REASON}" >/dev/null 2>&1 \
    || atest_infra "reason-only FAIL append failed (attempt=$attempt)"
  attempt=$((attempt + 1))
done
n_reason=$(grep -cE "^${PART}-failonly-${REASON}"$'\t' "$LOG" 2>/dev/null | tr -d ' ')
[ -n "$n_reason" ] && [ "$n_reason" -eq 1 ]
atest_assert "A2" "$?" "reason-only idtags produced ${n_reason:-0} lines, expected exactly 1 (collapse) — if this is not 1 the anchored dedup (lib:775) is not behaving as assumed and #10's premise is wrong."

atest_report
