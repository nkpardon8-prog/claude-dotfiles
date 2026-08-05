#!/usr/bin/env bash
# 09 - CROSS-COPY CONSUMER AGREEMENT (R8r6-E7, the anti-drift machine).
#
# THE SINGULAR ROOT this suite defends. Round 4 hardened ONE control-line reader (mission_await_state)
# with a full-grammar MISSION-CLEARED anchor + the full DECISION-resolved predicate. Its SIBLING
# consumers - mission_lifecycle_state, the gen-boundary readers, and the WAKE's last_decision derivation
# (mission.md §12.1) - each read the SAME control lines but had DRIFTED to a weaker matcher, and each
# drift was a real mandatory-STOP bypass. The per-site RED-on-revert guards in 08 pin each copy against
# its OWN past; NOTHING pinned the copies against EACH OTHER - and that gap between siblings is exactly
# where the drift lived (W1: the wake consumed a forged approve the reader kept live).
#
# WHAT THIS TEST DOES. It drives a CURATED adversarial log set through the REAL, LIVE consumers - the
# CLI `await-state` verb (mission_await_state), the sourced `mission_lifecycle_state`, and the wake's
# last_decision awk EXTRACTED verbatim from commands/mission.md and RUN over the same stream - and
# asserts they AGREE: no row may have one consumer authorize a denied/unapproved action or hide a STOP
# while another keeps it live. This is behavioural (effects, not layout) and hermetic (mktemp root, real
# scripts, no DB/OD/PHI/network). Any FUTURE sibling drift that breaks agreement reddens THIS test.
#
# RED-on-revert coverage (each reverts one sibling's anchor/predicate and reddens exactly one leg):
#   ROW B (conflict): revert the wake last_decision !conflict check -> last_decision returns the forged
#     approve while await_state keeps the barrier LIVE = the W1 consumer bypass. RED.
#   ROW C (got=1-before-DECISION): revert the before-got=1 (dnr<g1nr) check -> last_decision consumes an
#     out-of-order close the reader distrusts. RED.
#   ROW D (torn MISSION-CLEARED): revert the lifecycle_state full-grammar anchor to a prefix -> a torn
#     line marks the mission cleared while await_state keeps the STOP live = the G1 bypass. RED.
#   ROW E (malformed gen boundary): revert the gen-boundary reader full-grammar anchor to a prefix -> the
#     malformed boundary becomes the slice point and await_state returns none (STOP HIDDEN) = the G5
#     bypass, while lifecycle_state stays not-cleared. RED.
#   ROW A (sanctioned answer): a positive control - reverting the predicate TOO strict drops the approve.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "09-consumer-agreement"

MISSION_MD="${HOOKS}/../../commands/mission.md"
[ -f "$MISSION_MD" ] || { echo "INFRA: missing commands/mission.md" >&2; exit 3; }

# --- EXTRACT the wake's last_decision awk program verbatim from mission.md (§12.1) ------------------
# Grab from the `last_decision=$(awk -F...` line through the closing `' /tmp/mission-resume.$$` line,
# then strip the shell prefix (up to the LAST single-quote on the opener line, which is the awk-program
# opener - `-F'\t'` also carries single-quotes, so a greedy `.*'` is required) and the closing single-
# quote suffix. What remains is the exact awk PROGRAM the wake runs. Driving THIS (not a re-spelling)
# is what makes a prose-side drift redden the test.
SQ="'"
_raw_ld="$(awk '/last_decision=[$][(]awk -F/{g=1} g{print} /tmp\/mission-resume/{if(g)exit}' "$MISSION_MD")"
LAST_DECISION_AWK="$(printf '%s\n' "$_raw_ld" | sed "1s/^.*${SQ}//" | sed "\$ s/${SQ}.*//")"
case "$LAST_DECISION_AWK" in
  *"print dline"*) : ;;
  *) echo "INFRA: could not extract the wake last_decision awk from mission.md" >&2; exit 3 ;;
esac

# run the wake's last_decision over a fixture stream file. <stream-file> <op> <dtag> -> stdout dline|empty.
mc_last_decision() { awk -F'\t' -v t="$3" -v op="$2" "$LAST_DECISION_AWK" "$1"; }
# mission_lifecycle_state via the sourced lib (no dedicated CLI verb). <subdir> <sid> -> active|cleared|unknown|unreadable.
mc_lifecycle() { ( . "${HOOKS}/lib/mission-bridge.sh" >/dev/null 2>&1; mission_lifecycle_state "$2" "${ROOT}/$1" ) 2>/dev/null; }

# --- EXTRACT the wake's mission_state awk program verbatim from mission.md (§12.1) ------------------
# The GLOBAL active-iff gate (keys ONLY on CLEARED/REBASELINED) is a THIRD sibling consumer of the same
# control lines. It is a single line `mission_state=$(awk -F'\t' '<PROG>' /tmp/mission-resume.$$ ...)`; the
# program is the 4th single-quote-delimited field (it carries no single-quote of its own). Driving THIS
# (not a re-spelling) is what makes a prose-side drift of the active-iff gate redden the test. This closes
# the "the suite never EXECUTES mission_state" gap (criticer A1 / the L1-L4 finding).
MISSION_STATE_AWK="$(grep 'mission_state=[$][(]awk -F' "$MISSION_MD" | head -1 | awk -F"'"'"'" '{print $4}')"
case "$MISSION_STATE_AWK" in
  *"MISSION-REBASELINED"*"MISSION-CLEARED"*|*"MISSION-CLEARED"*"MISSION-REBASELINED"*) : ;;
  *) echo "INFRA: could not extract the wake mission_state awk from mission.md" >&2; exit 3 ;;
esac
# run the wake's mission_state over a fixture stream file. <stream-file> -> stdout the matched CLEARED/
# REBASELINED lifecycle line (EMPTY = no active-iff lifecycle line = a torn/forged line was REFUSED).
mc_mission_state() { awk -F'\t' "$MISSION_STATE_AWK" "$1" | tail -1; }

AW="[mission] AWAIT part=1 phase=decision round=1 kind=human"   # shared AWAIT body prefix

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ROW A - sanctioned answer: opener + after-opener approve DECISION + got=1 close.
#   AGREE: await_state RESOLVED (none) AND last_decision = the approve line (answered-approve).
# ══════════════════════════════════════════════════════════════════════════════════════════════
SUBa="rowA"; SIDa="rowA$$"; OPa="1-approve"; TAGa="pd-1-decision-approve"
mc_new_mission "$SUBa" "$SIDa"; LOGa="$(mc_log_file "$SUBa" "$SIDa")"
{
  printf 'm1-await-1-approve-r1-a1-g0\t%s op=%s attempt=1 need=1 got=0 started_at=1\n' "$AW" "$OPa"
  printf 'pd-1-decision-approve\t[mission] DECISION op=%s outcome=approve\n' "$OPa"
  printf 'm1-await-1-approve-r1-a1-g1\t%s op=%s attempt=1 need=1 got=1 started_at=1\n' "$AW" "$OPa"
} >> "$LOGa"
STa="$(mc_state "$SUBa" "$SIDa")"; LDa="$(mc_last_decision "$LOGa" "$OPa" "$TAGa")"
mc_eq "none" "$STa" "ROW A await_state RESOLVES the sanctioned (DECISION->got=1) close -> none"
mc_has "outcome=approve" "$LDa" "ROW A last_decision returns the answered approve (positive control: predicate not over-strict)"
# (lifecycle agreement is asserted explicitly on the STOP-bearing rows D/E below, where it is load-bearing.)

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ROW B - conflict: opener + a durable deny THEN a forged conflicting approve (same op) + got=1.
#   AGREE: await_state keeps the barrier LIVE (ready=0) AND last_decision returns NO decision (EMPTY).
#   DISAGREEMENT WOULD BE: last_decision returns the forged approve while the reader keeps it live = the
#   W1 consumer bypass (the wake runs the DENIED action). This row pins the wake !conflict check.
# ══════════════════════════════════════════════════════════════════════════════════════════════
SUBb="rowB"; SIDb="rowB$$"; OPb="1-deny"; TAGb="pd-1-decision-deny"
mc_new_mission "$SUBb" "$SIDb"; LOGb="$(mc_log_file "$SUBb" "$SIDb")"
{
  printf 'm1-await-1-deny-r1-a1-g0\t%s op=%s attempt=1 need=1 got=0 started_at=1\n' "$AW" "$OPb"
  printf 'pd-1-decision-deny\t[mission] DECISION op=%s outcome=deny\n' "$OPb"
  printf 'pd-1-decision-deny\t[mission] DECISION op=%s outcome=approve\n' "$OPb"
  printf 'm1-await-1-deny-r1-a1-g1\t%s op=%s attempt=1 need=1 got=1 started_at=1\n' "$AW" "$OPb"
} >> "$LOGb"
STb="$(mc_state "$SUBb" "$SIDb")"; LDb="$(mc_last_decision "$LOGb" "$OPb" "$TAGb")"
mc_has "await kind=human" "$STb" "ROW B await_state keeps the conflicting-DECISION barrier LIVE"
mc_has "ready=0" "$STb" "ROW B the conflicting-DECISION barrier reports ready=0 (not authorized)"
mc_eq "" "$LDb" "ROW B AGREEMENT: last_decision returns NO decision on conflict (does NOT consume the forged approve the reader kept live)"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ROW C - out-of-order: opener + got=1 close BEFORE any DECISION, then a DECISION.
#   AGREE: await_state keeps it LIVE (effgot=0, ready=0) AND last_decision returns NO decision (EMPTY).
#   Pins the wake before-got=1 (dnr<g1nr) check vs the reader decnr<maxnr.
# ══════════════════════════════════════════════════════════════════════════════════════════════
SUBc="rowC"; SIDc="rowC$$"; OPc="1-approve"; TAGc="pd-1-decision-approve"
mc_new_mission "$SUBc" "$SIDc"; LOGc="$(mc_log_file "$SUBc" "$SIDc")"
{
  printf 'm1-await-1-approve-r1-a1-g0\t%s op=%s attempt=1 need=1 got=0 started_at=1\n' "$AW" "$OPc"
  printf 'm1-await-1-approve-r1-a1-g1\t%s op=%s attempt=1 need=1 got=1 started_at=1\n' "$AW" "$OPc"
  printf 'pd-1-decision-approve\t[mission] DECISION op=%s outcome=approve\n' "$OPc"
} >> "$LOGc"
STc="$(mc_state "$SUBc" "$SIDc")"; LDc="$(mc_last_decision "$LOGc" "$OPc" "$TAGc")"
mc_has "await kind=human" "$STc" "ROW C await_state keeps the got=1-before-DECISION barrier LIVE (out-of-order close distrusted)"
mc_has "ready=0" "$STc" "ROW C the out-of-order-close barrier reports ready=0"
mc_eq "" "$LDc" "ROW C AGREEMENT: last_decision returns NO decision (does NOT consume the DECISION that followed a forged got=1)"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ROW D - torn MISSION-CLEARED over an open human STOP.
#   AGREE: await_state keeps the STOP LIVE AND lifecycle_state is NOT 'cleared'. A torn line must clear
#   NOTHING at EITHER consumer. Pins the lifecycle_state full-grammar anchor (G1) beside await_state.
# ══════════════════════════════════════════════════════════════════════════════════════════════
SUBd="rowD"; SIDd="rowD$$"
mc_new_mission "$SUBd" "$SIDd"
mc_pending_stop "$SUBd" "$SIDd" approve 1 1 1 decision "Approve X?" >/dev/null   # a REAL open human STOP
LOGd="$(mc_log_file "$SUBd" "$SIDd")"
printf '\t[mission] MISSION-CLEARED\n' >> "$LOGd"   # TORN: empty idtag + prefix only, NO status=/reason= tail
STd="$(mc_state "$SUBd" "$SIDd")"; LFd="$(mc_lifecycle "$SUBd" "$SIDd")"; MSd="$(mc_mission_state "$LOGd")"
mc_has "await kind=human" "$STd" "ROW D await_state keeps the STOP LIVE under a torn MISSION-CLEARED"
mc_has "ready=0" "$STd" "ROW D the STOP stays ready=0 under the torn line"
case "$LFd" in cleared) mc_fail "ROW D AGREEMENT: lifecycle_state read 'cleared' from a TORN MISSION-CLEARED while the STOP is live (G1 drift)";; *) mc_ok "ROW D AGREEMENT: lifecycle_state is NOT 'cleared' under a torn MISSION-CLEARED (= '${LFd}')";; esac
# THIRD consumer: the wake mission_state gate must ALSO refuse the torn line (EMPTY = no active-iff lifecycle line).
case "$MSd" in *MISSION-CLEARED*) mc_fail "ROW D AGREEMENT: wake mission_state picked the TORN MISSION-CLEARED as the active-iff gate line while the STOP is live";; *) mc_ok "ROW D AGREEMENT: wake mission_state REFUSES the torn MISSION-CLEARED (= '${MSd}')";; esac

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ROW E - malformed gen boundary over an open human STOP (gen=1 mission, no gen field on the boundary).
#   AGREE: await_state keeps the STOP LIVE (the malformed boundary is NOT a slice point, so the earlier
#   opener is NOT sliced away) AND lifecycle_state is NOT 'cleared'. Pins the gen-boundary reader
#   full-grammar anchor (G5): a prefix match would slice the STOP away -> await_state none (STOP HIDDEN).
# ══════════════════════════════════════════════════════════════════════════════════════════════
SUBe="rowE"; SIDe="rowE$$"
mc_new_mission "$SUBe" "$SIDe"
mc_pending_stop "$SUBe" "$SIDe" approve 1 1 1 decision "Approve Y?" >/dev/null   # a REAL open human STOP (the opener)
LOGe="$(mc_log_file "$SUBe" "$SIDe")"
printf '\t[mission] MISSION-REBASELINED status=active\n' >> "$LOGe"   # MALFORMED boundary: empty idtag, NO gen field
STe="$(mc_state "$SUBe" "$SIDe")"; LFe="$(mc_lifecycle "$SUBe" "$SIDe")"; MSe="$(mc_mission_state "$LOGe")"
mc_has "await kind=human" "$STe" "ROW E await_state keeps the STOP LIVE (a malformed gen boundary is NOT a slice point) — not hidden as none"
mc_has "ready=0" "$STe" "ROW E the STOP stays ready=0 under the malformed boundary"
case "$LFe" in cleared) mc_fail "ROW E AGREEMENT: lifecycle_state read 'cleared' from a malformed boundary";; *) mc_ok "ROW E AGREEMENT: lifecycle_state is NOT 'cleared' under a malformed boundary (= '${LFe}')";; esac
# TIGHTENED (CL9): the malformed boundary must be REFUSED by the active-iff gate too — the wake mission_state
# must NOT pick it as the REBASELINED active line (EMPTY = refused). Asserts REFUSAL, not merely not-cleared.
case "$MSe" in *MISSION-REBASELINED*) mc_fail "ROW E AGREEMENT: wake mission_state accepted the MALFORMED REBASELINED boundary as the active-iff gate line";; *) mc_ok "ROW E AGREEMENT: wake mission_state REFUSES the malformed REBASELINED boundary (= '${MSe}')";; esac

mc_finish '{"row_a_sanctioned":"opener+after-opener approve+got=1 -> await_state none AND last_decision approve (agree, resolved-answered)","row_b_conflict":"durable deny + forged approve -> await_state LIVE ready=0 AND last_decision EMPTY (agree: forged approve NOT consumed = W1)","row_c_out_of_order":"got=1 before the DECISION -> await_state LIVE ready=0 AND last_decision EMPTY (agree: out-of-order close distrusted = D3)","row_d_torn_cleared":"torn MISSION-CLEARED over an open STOP -> await_state LIVE AND lifecycle_state not cleared (agree = G1)","row_e_malformed_boundary":"malformed gen boundary over an open STOP -> await_state LIVE (not sliced to none) AND lifecycle_state not cleared (agree = G5)"}' \
  "cross-copy consumer agreement: await_state + lifecycle_state + wake last_decision AGREE on a curated adversarial log set (sanctioned / conflict / out-of-order-close / torn-cleared / malformed-boundary) — no consumer authorizes a denied/unapproved action or hides a STOP that another keeps live"
