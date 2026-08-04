#!/usr/bin/env bash
# 03 - lost-wake-replay: an AWAIT with `got < need` and NO durable progress after it STAYS
# outstanding across re-reads. This is the safety-net signal the wake routine reads to replay
# the missing lane - the property that makes correctness independent of 100% wake delivery.
#
# Load-bearing because a background-completion wake CAN be lost (the harness dropped it, the
# app was closed at the moment the job exited). If a dropped wake left the barrier looking
# done, the join would fire on a half-finished review and the missing lane's findings would
# be silently discarded - a quiet, unrecoverable stall of the exact kind the whole fix
# targets. The §8 `AWAIT got<need + NO tracked job -> replay the missing lane` row depends on
# this token surviving; here we prove it does not self-clear just because time passed / the
# state was re-read.
#
# NEGATIVE CONTROL: make mission_await_state treat any AWAIT line as satisfied (e.g. print
# `none` unconditionally in its END block) - A2/A3 then report `none` where an outstanding
# await is required, and this case goes RED. Restore to green.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "03-lost-wake-replay"

SUB="job"; SID="lostwake$$"
mc_new_mission "$SUB" "$SID"

# Open a two-lane barrier (got=0 opener - R4: a live barrier requires a post-boundary opener) and land
# ONE lane (simulating one completion wake that DID arrive), then drop the second lane's wake entirely -
# got stays 1, below need=3.
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=lane attempt=1 need=3 got=0"
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=lane attempt=1 need=3 got=1"

# A1 - first read after the dropped wake: still outstanding (the replay signal is live).
S=$(mc_state "$SUB" "$SID")
mc_has "await kind=job" "$S" "A1 got<need still outstanding"
mc_has "got=1"          "$S" "A1 reports the partial got=1"

# A2 - re-read with NO further progress banked: MUST still be outstanding. A bookmark that
# self-cleared on a second read would drop the replay signal and silently strand the lane.
mc_eq "$S" "$(mc_state "$SUB" "$SID")" "A2 idempotent re-read stays outstanding"

# A3 - the CURSOR is unchanged across those two reads (no append happened), which is what
# lets the wake routine recognise there is nothing new to do EXCEPT honour the replay row -
# rather than mistaking a re-read for progress.
C1=$(mc_cursor "$SUB" "$SID"); C2=$(mc_cursor "$SUB" "$SID")
mc_eq "$C1" "$C2" "A3 cursor stable while the lane is stranded"
[ -n "$C1" ] && mc_ok "A3 cursor non-empty" || mc_fail "A3 cursor empty"

mc_finish '{"partial_await":"outstanding got=1","re_read":"still outstanding (replay signal survives)","cursor_stable":"unchanged across re-reads"}' \
  "5 assertions (a dropped completion wake does NOT silently clear the AWAIT)"
