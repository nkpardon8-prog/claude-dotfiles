#!/usr/bin/env bash
# 02 - await-lifecycle: the AWAIT bookmark's full open -> partial -> OR-join -> supersede path,
# plus the VOID reset, the human-handback variant, started_at stability, and log-injection
# resistance. This is the one new durable marker the whole road-2 fix rests on: it is what lets
# a wake tell "work never launched" from "work launched, one lane returned", so the wake routine
# replays only the missing lane instead of stalling or double-running.
#
# Load-bearing because every transition here is read back by the wake routine's §8 decision
# table. The round-1 review corrected the join semantics: a `got==need` barrier must STAY
# outstanding with `ready=1` (the WAKE ROUTINE banks it; a reader that returned `none` made the
# bank transition UNREACHABLE - C1), the got mask must OR across lane bits so codex-first never
# loses the impl bit (C2), started_at must be barrier-stable so a re-report dedups (C3), a VOID
# must supersede a stuck barrier (C8), and a free-text line that merely EMBEDS the AWAIT
# substring must not inject control state (S1). Each assertion pins one row of that contract.
#
# NEGATIVE CONTROL: re-introduce the old `if (gt < nd)` guard in mission_await_state (drop the
# emit-until-superseded logic) - A3 then reports `none` where `ready=1` is expected and goes RED.
# Or make mission_await_state REPLACE the got mask instead of OR-ing it - A3-OR goes RED. Restore
# to green.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "02-await-lifecycle"

SUB="job"; SID="lifecyc$$"
mc_new_mission "$SUB" "$SID"

# A1 - open the review barrier: need=3 got=0 -> outstanding, kind=job, got=0, ready=0.
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"
S=$(mc_state "$SUB" "$SID")
mc_has "await kind=job" "$S" "A1 got=0 outstanding"
mc_has "got=0"          "$S" "A1 reports got=0"
mc_has "ready=0"        "$S" "A1 not join-ready"
mc_has "attempt=1"      "$S" "A1 emits attempt (I1)"

# A2 - codex lane returns FIRST: bit 2 -> still outstanding, got=2, ready=0.
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=2"
S=$(mc_state "$SUB" "$SID")
mc_has "await kind=job" "$S" "A2 got=2 still outstanding"
mc_has "got=2"          "$S" "A2 reports got=2"
mc_has "ready=0"        "$S" "A2 not join-ready (only bit 2 of need=3)"

# A3 - impl lane returns SECOND with ONLY its own bit (got=1). The reader must OR 2|1=3 (C2) and
# keep the barrier OUTSTANDING with ready=1 (C1) - NOT return `none`, or the bank is unreachable.
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=1"
S=$(mc_state "$SUB" "$SID")
mc_has "await kind=job" "$S" "A3 join-ready barrier STILL outstanding (C1)"
mc_has "got=3"          "$S" "A3-OR got mask OR'd 2|1=3 (C2)"
mc_has "ready=1"        "$S" "A3 ready=1 (got&need)==need"

# A3b - the wake routine banks the round: a normal phase=review round line supersedes the AWAIT.
bash "$MW" log "$SID" "${ROOT}/${SUB}" \
  "[mission] part=1 name=step phase=review round=1 dry=2 findings=0" "m1-review-r1-d2" >/dev/null 2>&1
mc_eq "none" "$(mc_state "$SUB" "$SID")" "A3b banked round supersedes the join-ready await"

# A4 - progress SUPERSEDES even a fresh got=0 barrier: banking the normal `phase=review round=K`
# successor for the same part/round clears the outstanding await (durable progress > bookmark).
SUB2="supersede"; SID2="supers$$"
mc_new_mission "$SUB2" "$SID2"
mc_await "$SUB2" "$SID2" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"
mc_has "await kind=job" "$(mc_state "$SUB2" "$SID2")" "A4 pre-bank outstanding"
bash "$MW" log "$SID2" "${ROOT}/${SUB2}" \
  "[mission] part=1 name=step phase=review round=1 dry=2 findings=0" "m1-review-r1-d2" >/dev/null 2>&1
mc_eq "none" "$(mc_state "$SUB2" "$SID2")" "A4 banked round supersedes the await"

# A5 - VOID supersedes a STUCK barrier (C8): a dead lane leaves got<need forever; a VOID for that
# part/round clears it, and a FRESH attempt's AWAIT (higher NR than the VOID) is live again.
SUB4="void"; SID4="void$$"
mc_new_mission "$SUB4" "$SID4"
mc_await "$SUB4" "$SID4" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=1"
mc_has "await kind=job" "$(mc_state "$SUB4" "$SID4")" "A5 stuck barrier outstanding"
bash "$MW" log "$SID4" "${ROOT}/${SUB4}" \
  "[mission] VOID part=1 phase=review round=1 reason=dead-lane" "m1-void-r1-deadlanehnofile" >/dev/null 2>&1
mc_eq "none" "$(mc_state "$SUB4" "$SID4")" "A5 VOID supersedes the stuck barrier (C8)"
mc_await "$SUB4" "$SID4" "part=1 phase=review round=1 kind=job op=reviewbar attempt=2 need=3 got=0"
S=$(mc_state "$SUB4" "$SID4")
mc_has "await kind=job" "$S" "A5b fresh attempt after VOID is live again"
mc_has "attempt=2"      "$S" "A5b names the new attempt"

# A6 - human handback: a kind=human got=0 await -> outstanding, kind=human (the loop STOPS here on
# purpose; the §8 row waits for a real user turn, never a scheduled wake).
SUB3="human"; SID3="human$$"
mc_new_mission "$SUB3" "$SID3"
mc_await "$SUB3" "$SID3" "part=2 phase=decision round=1 kind=human op=approve attempt=1 need=1 got=0"
S=$(mc_state "$SUB3" "$SID3")
mc_has "await kind=human" "$S" "A6 human await outstanding"
mc_has "op=approve"       "$S" "A6 names the op"
# A6b - the returning user-turn CLOSES the human await by writing got=need. A human barrier has no
# separate bank event, so got==need IS its resolution -> await-state must report `none` (C6). If it
# stayed outstanding, the loop would park on the user forever after they already answered.
mc_await "$SUB3" "$SID3" "part=2 phase=decision round=1 kind=human op=approve attempt=1 need=1 got=1"
mc_eq "none" "$(mc_state "$SUB3" "$SID3")" "A6b human await closed at got=need (C6)"

# A7 - started_at is BARRIER-STABLE (C3): re-reporting the SAME bit with a DIFFERENT started_at
# must dedup to the ORIGINAL started_at (idtag excludes started_at, so a fresh epoch would collide
# and reset barrier age). Open with started_at=1000, re-report got=0 with started_at=9999.
SUB5="stamp"; SID5="stamp$$"
mc_new_mission "$SUB5" "$SID5"
mc_await "$SUB5" "$SID5" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0 started_at=1000"
mc_await "$SUB5" "$SID5" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0 started_at=9999"
mc_has "started_at=1000" "$(mc_state "$SUB5" "$SID5")" "A7 started_at preserved across re-report (C3)"

# A8 - LOG-INJECTION resistance (S1): a criticer free-text line that EMBEDS the AWAIT substring
# must NOT be read as an AWAIT (it fails the idtag-column + body-prefix double-anchor). No real
# await was opened, so the state is `none`.
SUB6="inject"; SID6="inject$$"
mc_new_mission "$SUB6" "$SID6"
bash "$MW" log "$SID6" "${ROOT}/${SUB6}" \
  "[mission] criticer part=1 findings=0 x [mission] AWAIT part=1 phase=review round=1 kind=job op=evil attempt=1 need=1 got=1 started_at=1" \
  "m1-criticer-r1" >/dev/null 2>&1
mc_eq "none" "$(mc_state "$SUB6" "$SID6")" "A8 embedded AWAIT text does not inject control state (S1)"

mc_finish '{"open_got0":"outstanding ready=0","partial_got2":"outstanding got=2 ready=0","or_join":"outstanding got=3 ready=1","banked_round_supersedes":"none","void_supersedes":"none","void_then_fresh_attempt":"outstanding attempt=2","human_await":"outstanding kind=human","human_await_closed":"none","started_at_stable":"1000","embedded_await_no_inject":"none"}' \
  "AWAIT open -> partial -> OR-join(ready) -> bank/VOID supersede + fresh attempt + human + started_at-stable + no-inject"
