#!/usr/bin/env bash
# 12 — machine-readable round lines must be TERSE, and an oversize one is now REFUSED, not rerouted.
# Fix-plan #6 + Task 4. The 480B boundary is still real; what changed is WHO enforces it and HOW:
#
# BEFORE (superseded): mission_log_append rerouted any >=480B line (even a machine round line) to
# DURABLE NOTES, where the resume grep can't find it — a silent ambiguous resume.
# NOW (Task 4): the `mission-write.sh log` per-shape validator PRE-COMPUTES the persisted line length
# (gen-prefixed idtag + TAB + entry + NL) for EVERY machine shape and REFUSES `line-too-long` — the
# oversize machine line is REJECTED loud, never rerouted and never silently lost. Free text still
# reroutes (that path is unchanged); machine shapes are terse by design.
#
# NEGATIVE CONTROL (controllable precondition): A1 proves a representative TERSE round line is
# ACCEPTED (log ok) and lands in the LOG; A2 (the flipped arm) proves an OVERSIZE round line is
# REFUSED `line-too-long` and lands in NEITHER the LOG nor DURABLE NOTES — the loud-refuse contract.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "12-round-line-reroute-boundary"

. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh" 2>/dev/null \
  || atest_infra "cannot source mission-bridge.sh"
MWSH="$(cd "$HERE/.." && pwd)/mission-write.sh"
[ -f "$MWSH" ] || atest_infra "mission-write.sh not found at $MWSH"

SID="atest12"
ROOT="$ATEST_DIR/anchor"; mkdir -p "$ROOT"
LOG="$ROOT/MISSION.${SID}.log"
bash "$MWSH" create "$SID" "$ROOT" "MISSION MODE: build — t12" >/dev/null 2>&1 \
  || atest_infra "mission create failed"

# --- A1: a TERSE round-checkpoint line is ACCEPTED and stays in the LOG (not NOTES) ------------
TERSE="[mission] part=9 name=t12 phase=fix round=12 dry=1 findings=3"
TERSE_TAG="m9-fix-r12-d1"
tlen=$(printf '%s\t%s\n' "$TERSE_TAG" "$TERSE" | LC_ALL=C wc -c | tr -d ' ')
[ "$tlen" -lt 480 ] || atest_infra "setup: terse line is ${tlen}B, not < 480 — pick a shorter representative"
A1_OUT=$(bash "$MWSH" log "$SID" "$ROOT" "$TERSE" "$TERSE_TAG" 2>/dev/null)
in_log=1;   grep -qE "^${TERSE_TAG}"$'\t' "$LOG" 2>/dev/null && in_log=0
in_notes=1; mission_read_zone "$ROOT/MISSION.${SID}.md" "DURABLE NOTES" 2>/dev/null | grep -q "round=12 dry=1 findings=3" && in_notes=0
{ printf '%s' "$A1_OUT" | grep -q 'log ok'; } && [ "$in_log" = "0" ] && [ "$in_notes" != "0" ]
atest_assert "A1" "$?" "terse round line (${tlen}B) not accepted-into-LOG (status='$A1_OUT' in_log=$in_log) or leaked into NOTES (in_notes=$in_notes) — a terse checkpoint must persist in the LOG the resume grep reads."

# --- A2 (FLIPPED — REFUSE expected): an OVERSIZE round line is REFUSED `line-too-long` -----------
# It must land in NEITHER the LOG nor DURABLE NOTES (loud refuse, not a silent reroute).
BLOB=$(printf 'x%.0s' $(seq 1 600))   # 600-byte name payload → crosses 480B
BIG="[mission] part=9 name=${BLOB} phase=fix round=13 dry=0 findings=0"
BIG_TAG="m9-fix-r13-d0"
blen=$(printf '%s\t%s\n' "$BIG_TAG" "$BIG" | LC_ALL=C wc -c | tr -d ' ')
[ "$blen" -ge 480 ] || atest_infra "setup: oversize line is only ${blen}B, not >= 480 — make the blob longer"
A2_OUT=$(bash "$MWSH" log "$SID" "$ROOT" "$BIG" "$BIG_TAG" 2>/dev/null)
big_in_log=1;   grep -qE "^${BIG_TAG}"$'\t' "$LOG" 2>/dev/null && big_in_log=0
big_in_notes=1; mission_read_zone "$ROOT/MISSION.${SID}.md" "DURABLE NOTES" 2>/dev/null | grep -q "round=13" && big_in_notes=0
{ printf '%s' "$A2_OUT" | grep -q 'REFUSED: line-too-long'; } && [ "$big_in_log" != "0" ] && [ "$big_in_notes" != "0" ]
atest_assert "A2" "$?" "oversize round line (${blen}B) was NOT refused-and-dropped as expected (status='$A2_OUT' in_log=$big_in_log in_notes=$big_in_notes) — a machine shape over budget must be REFUSED line-too-long, landing in NEITHER the LOG nor NOTES."

atest_report
