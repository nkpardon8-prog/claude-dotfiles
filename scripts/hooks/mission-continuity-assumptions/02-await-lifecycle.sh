#!/usr/bin/env bash
# 02 - await-lifecycle: the AWAIT bookmark's full open -> partial -> join -> supersede path,
# plus the human-handback variant. This is the one new durable marker the whole road-2 fix
# rests on: it is what lets a wake tell "work never launched" from "work launched, one lane
# returned", so the wake routine replays only the missing lane instead of stalling or
# double-running.
#
# Load-bearing because every transition here is read back by the wake routine's §8 decision
# table. If `got<need` did not report outstanding, a wake would collect a half-finished
# barrier as done; if `got=need` did not report `none`, the barrier would replay forever; if
# a banked `phase=review` round did not SUPERSEDE the AWAIT, a completed round would look
# unfinished on the next wake. Each assertion pins one row of that table.
#
# NEGATIVE CONTROL: change mission_await_state in lib/mission-bridge.sh to emit the await even
# when `got>=need` (drop the `if (gt < nd)` guard) - A4/A5 then report an await where `none`
# is expected and go RED. Restore to green.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "02-await-lifecycle"

SUB="job"; SID="lifecyc$$"
mc_new_mission "$SUB" "$SID"

# A1 - open the review barrier: need=3 got=0 -> outstanding, kind=job, got=0.
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"
S=$(mc_state "$SUB" "$SID")
mc_has "await kind=job" "$S" "A1 got=0 outstanding"
mc_has "got=0"         "$S" "A1 reports got=0"

# A2 - one lane returns: update to got=2 -> still outstanding, now got=2.
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=2"
S=$(mc_state "$SUB" "$SID")
mc_has "await kind=job" "$S" "A2 got=2 still outstanding"
mc_has "got=2"          "$S" "A2 reports got=2"

# A3 - both lanes joined: got=3 (==need) -> the barrier is join-ready, no longer outstanding.
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=3"
mc_eq "none" "$(mc_state "$SUB" "$SID")" "A3 got=need -> none"

# A4 - progress SUPERSEDES: on a FRESH barrier still at got=0, banking the normal
# `phase=review round=K` successor for the same part/round clears the outstanding await
# (durable progress outranks the bookmark). idtag shape m<part>-review-r<round>-d<dry>.
SUB2="supersede"; SID2="supers$$"
mc_new_mission "$SUB2" "$SID2"
mc_await "$SUB2" "$SID2" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"
mc_has "await kind=job" "$(mc_state "$SUB2" "$SID2")" "A4 pre-bank outstanding"
bash "$MW" log "$SID2" "${ROOT}/${SUB2}" \
  "[mission] part=1 name=step phase=review round=1 dry=2 findings=0" "m1-review-r1-d2" >/dev/null 2>&1
mc_eq "none" "$(mc_state "$SUB2" "$SID2")" "A4 banked round supersedes the await"

# A5 - human handback: a kind=human got=0 await -> outstanding, kind=human (the loop STOPS
# here on purpose; the §8 row waits for a real user turn, never a scheduled wake).
SUB3="human"; SID3="human$$"
mc_new_mission "$SUB3" "$SID3"
mc_await "$SUB3" "$SID3" "part=2 phase=decision round=1 kind=human op=approve attempt=1 need=1 got=0"
S=$(mc_state "$SUB3" "$SID3")
mc_has "await kind=human" "$S" "A5 human await outstanding"
mc_has "op=approve"       "$S" "A5 names the op"

mc_finish '{"open_got0":"outstanding","partial_got2":"outstanding got=2","join_got_eq_need":"none","banked_round_supersedes":"none","human_await":"outstanding kind=human"}' \
  "8 assertions (AWAIT open -> partial -> join -> supersede + human handback)"
