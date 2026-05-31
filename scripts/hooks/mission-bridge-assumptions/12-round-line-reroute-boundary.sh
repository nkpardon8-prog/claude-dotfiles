#!/usr/bin/env bash
# 12 — the round-checkpoint line must stay UNDER the 480B reroute boundary or it silently
# leaves the LOG. Fix-plan #6. Exercises the REAL mission_log_append reroute (lib:766-769).
#
# Load-bearing contract: mission_log_append measures the FULL `tag\tentry\n` byte length and, if
# it is >= 480B, reroutes the WHOLE entry to the DURABLE NOTES zone of the .md (lib:768-769) — it
# does NOT land in the .log the resume grep reads. So a round-checkpoint line that inlines verbose
# `findings=` text crosses the boundary and VANISHES from the LOG → ambiguous resume. The fix keeps
# the round line terse (part/phase/round/dry + a short findings COUNT) and puts verbose findings in
# a separate note.
#
# NEGATIVE CONTROL (controllable precondition): A1 proves a representative TERSE round line stays in
# the LOG and NOT in NOTES; A2 (the red arm) proves an OVERSIZE variant (verbose findings) reroutes
# OUT of the LOG into NOTES — demonstrating the boundary is real and why terseness is load-bearing.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "12-round-line-reroute-boundary"

. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh" 2>/dev/null \
  || atest_infra "cannot source mission-bridge.sh"

SID="atest12"
ROOT="$ATEST_DIR/anchor"; mkdir -p "$ROOT"
LOG="$ROOT/MISSION.${SID}.log"
mission_create "$SID" "$ROOT" "MISSION MODE: build — t12" >/dev/null 2>&1 \
  || atest_infra "mission_create failed"

# --- A1: a TERSE round-checkpoint line (count, not verbose findings) stays in the LOG ----
TERSE="[mission] part=9 phase=fix round=12 dry=1 findings=3"
TERSE_TAG="m9-r12"
# sanity: confirm the terse line is genuinely under the 480B boundary the lib measures.
tlen=$(printf '%s\t%s\n' "$TERSE_TAG" "$TERSE" | LC_ALL=C wc -c | tr -d ' ')
[ "$tlen" -lt 480 ] || atest_infra "setup: terse line is ${tlen}B, not < 480 — pick a shorter representative"
mission_log_append "$SID" "$ROOT" "$TERSE" "$TERSE_TAG" >/dev/null 2>&1 \
  || atest_infra "terse round-line append failed"
in_log=1;  grep -qE "^${TERSE_TAG}"$'\t' "$LOG" 2>/dev/null && in_log=0
in_notes=1; mission_read_zone "$ROOT/MISSION.${SID}.md" "DURABLE NOTES" 2>/dev/null | grep -q "round=12 dry=1 findings=3" && in_notes=0
[ "$in_log" = "0" ] && [ "$in_notes" != "0" ]
atest_assert "A1" "$?" "terse round line (${tlen}B) is not in the LOG (in_log=$in_log) or leaked into NOTES (in_notes=$in_notes) — a terse checkpoint must persist in the LOG the resume grep reads."

# --- A2 (NEGATIVE CONTROL): an OVERSIZE round line reroutes OUT of the LOG into NOTES -----
# Worst case: a round line that inlines a long multibyte findings blob → crosses 480B.
BLOB=$(printf 'x%.0s' $(seq 1 600))   # 600-byte findings payload
BIG="[mission] part=9 phase=fix round=13 dry=0 findings=${BLOB}"
BIG_TAG="m9-r13"
blen=$(printf '%s\t%s\n' "$BIG_TAG" "$BIG" | LC_ALL=C wc -c | tr -d ' ')
[ "$blen" -ge 480 ] || atest_infra "setup: oversize line is only ${blen}B, not >= 480 — make the blob longer"
mission_log_append "$SID" "$ROOT" "$BIG" "$BIG_TAG" >/dev/null 2>&1 \
  || atest_infra "oversize round-line append returned nonzero"
big_in_log=1;   grep -qE "^${BIG_TAG}"$'\t' "$LOG" 2>/dev/null && big_in_log=0
big_in_notes=1; mission_read_zone "$ROOT/MISSION.${SID}.md" "DURABLE NOTES" 2>/dev/null | grep -q "round=13 dry=0" && big_in_notes=0
[ "$big_in_log" != "0" ] && [ "$big_in_notes" = "0" ]
atest_assert "A2" "$?" "oversize round line (${blen}B) did NOT reroute as expected (in_log=$big_in_log in_notes=$big_in_notes) — if it stayed in the LOG the 480B boundary moved; if it vanished from both it was LOST. Either way the terse-line rule is load-bearing."

atest_report
