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
# R4 - a live barrier REQUIRES a post-boundary got=0 OPENER (the real system always opens with got=0
# at mission.md:624); a lone got=1 with no opener is a stale-late bit and reads as none by design.
SUB4="void"; SID4="void$$"
mc_new_mission "$SUB4" "$SID4"
mc_await "$SUB4" "$SID4" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"
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
mc_await "$SUB3" "$SID3" "part=2 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=0"
S=$(mc_state "$SUB3" "$SID3")
mc_has "await kind=human" "$S" "A6 human await outstanding"
mc_has "op=1-approve"     "$S" "A6 names the op (R6: seq-prefixed)"
# A6b (R8-14) - the returning user-turn CLOSES the human await by recording a durable DECISION FIRST
# then writing got=need. DECISION-first is LIB-ENFORCED: a human got=1 close with NO same-op DECISION is
# REFUSED (the barrier can never clear without a recorded, surfaced outcome). A human barrier has no
# separate bank event, so DECISION+got==need IS its resolution -> await-state must report `none` (C6). If
# it stayed outstanding, the loop would park on the user forever after they already answered. Goes RED if
# the DECISION-first close order regresses (a bare got=1 close is refused -> barrier stays live got=0).
mc_close_human "$SUB3" "$SID3" "1-approve" approve 2 1 1 decision
mc_eq "none" "$(mc_state "$SUB3" "$SID3")" "A6b human await closed at DECISION+got=need (C6, DECISION-first)"

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

# A9 - barrier identity includes KIND (A1): a job `got=1 need=3` and a same (part,round,attempt) human
# `got=0 need=1` are DISTINCT barriers. The job bit must NOT satisfy the human need; the human STOP must
# survive (and outrank the job by §8 human-priority). The old (part,round,attempt)-only key OR'd the job
# bit into the human need=1 and read `none` - bypassing the mandatory human handback.
SUB8="kindmix"; SID8="kindmix$$"
mc_new_mission "$SUB8" "$SID8"
mc_await "$SUB8" "$SID8" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=1"
mc_await "$SUB8" "$SID8" "part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=0"
S=$(mc_state "$SUB8" "$SID8")
mc_has "kind=human" "$S" "A9 human barrier NOT resolved by an inherited job bit (A1 key-by-kind)"
mc_has "op=1-approve" "$S" "A9 the human STOP outranks the same-tuple job barrier (§8 human-first)"

# A10 - field-injection rejected (A5): an `op=review-kind=human` token embeds a second `kind=` (its value
# contains `=`). The append MUST be refused, so the barrier stays kind=job got=1 (the injection never
# lands a forged human AWAIT that would park the loop).
SUB9="fieldinj"; SID9="fieldinj$$"
mc_new_mission "$SUB9" "$SID9"
mc_await "$SUB9" "$SID9" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"
mc_await "$SUB9" "$SID9" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=1"
mc_await "$SUB9" "$SID9" "part=1 phase=review round=1 kind=job op=review-kind=human attempt=1 need=3 got=2"
S=$(mc_state "$SUB9" "$SID9")
mc_has "kind=job" "$S" "A10 op=review-kind=human injection refused (barrier stays kind=job)"
mc_has "got=1"    "$S" "A10 the injected got=2 write never landed (still got=1)"

# A11 - attempt selection by HIGHEST attempt, not newest NR (A3): a LATE attempt-1 completion (highest
# log NR) must NOT reselect attempt 1 once attempt 2 has opened.
SUB10="attsel"; SID10="attsel$$"
mc_new_mission "$SUB10" "$SID10"
mc_await "$SUB10" "$SID10" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"
mc_await "$SUB10" "$SID10" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=1"
mc_await "$SUB10" "$SID10" "part=1 phase=review round=1 kind=job op=reviewbar attempt=2 need=3 got=0"
mc_await "$SUB10" "$SID10" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=2"
mc_has "attempt=2" "$(mc_state "$SUB10" "$SID10")" "A11 selects highest attempt, not newest NR (A3)"

# A12 (R4/R6) - barrier identity includes OP, and a human op carries the pd's UNIQUE seq (`<seq>-<slug>`),
# so even two SAME-SLUG mandatory decisions are SEPARATE barriers. This is the R6 CRITICAL: closing
# decision-1 (op=1-approve got=1) must NOT OR-resolve a later same-slug decision-2 (op=2-approve got=0) -
# else the second human handback is silently skipped and autonomous work proceeds unapproved. The seq is
# what disambiguates; the bare slug alone would collide. Job lanes are seq-LESS so they never split a join.
SUB11="humanop"; SID11="humanop$$"
mc_new_mission "$SUB11" "$SID11"
mc_await "$SUB11" "$SID11" "part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=0"
mc_await "$SUB11" "$SID11" "part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=1"
mc_await "$SUB11" "$SID11" "part=1 phase=decision round=1 kind=human op=2-approve attempt=1 need=1 got=0"
S=$(mc_state "$SUB11" "$SID11")
mc_has "await kind=human" "$S" "A12 same-slug decision NOT masked by a resolved sibling (R6 unique-seq op)"
mc_has "op=2-approve"     "$S" "A12 the still-open decision is the live barrier"
mc_has "ready=0"          "$S" "A12 the open decision is not join-ready"

# A13 (R4) - opener guard: a live barrier REQUIRES a post-boundary got=0 OPENER. A late stale lane bit
# (got=1) arriving AFTER the round banks - with its got=0 opener pre-boundary (excluded) - must NOT
# resurrect the closed round. Prevents a lost-wake late completion from reactivating superseded work.
SUB12="opener"; SID12="opener$$"
mc_new_mission "$SUB12" "$SID12"
mc_await "$SUB12" "$SID12" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"
bash "$MW" log "$SID12" "${ROOT}/${SUB12}" \
  "[mission] part=1 name=x phase=review round=1 dry=2 findings=0" "m1-review-r1-d2" >/dev/null 2>&1
mc_await "$SUB12" "$SID12" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=1"
mc_eq "none" "$(mc_state "$SUB12" "$SID12")" "A13 late got=1 after bank cannot reopen (opener guard)"

# A14 (R6) - kind<->op NAMESPACE guard, enforced at the mechanism. A human op WITHOUT a numeric seq
# prefix is REFUSED (would let two same-slug decisions collide); a job op WITH a seq prefix is REFUSED
# (that namespace is reserved for human decisions, so the kind-less idtag stays disjoint). Neither
# refused open lands, so await-state stays `none`; a seq-prefixed human op then opens cleanly.
SUB13="opguard"; SID13="opguard$$"
mc_new_mission "$SUB13" "$SID13"
mc_await "$SUB13" "$SID13" "part=1 phase=decision round=1 kind=human op=approve attempt=1 need=1 got=0"   # no seq -> REFUSED
mc_eq "none" "$(mc_state "$SUB13" "$SID13")" "A14 human op without a seq prefix is REFUSED (no barrier lands)"
mc_await "$SUB13" "$SID13" "part=1 phase=review round=1 kind=job op=7-lane attempt=1 need=3 got=0"        # seq-prefixed job -> REFUSED
mc_eq "none" "$(mc_state "$SUB13" "$SID13")" "A14 seq-prefixed job op is REFUSED (reserved for human)"
mc_await "$SUB13" "$SID13" "part=1 phase=decision round=1 kind=human op=3-approve attempt=1 need=1 got=0" # valid seq op -> lands
mc_has "op=3-approve" "$(mc_state "$SUB13" "$SID13")" "A14 a seq-prefixed human op opens cleanly"

# A14 (R7-2) - the seq check is a PURE-DIGIT prefix test, NOT the loose glob `[0-9]*-*`. A mixed
# `1abc-approve` (non-digit chars after the digits) and an empty-slug `1-` are BOTH invalid human ops
# and REFUSED; a job `7zip-review` (non-digit prefix) is correctly NOT seq-prefixed and so ALLOWED.
# Goes RED if the glob returns (it would accept `1abc-approve`/`1-` and reject `7zip-review`).
SUB13b="opedge"; SID13b="opedge$$"
mc_new_mission "$SUB13b" "$SID13b"
mc_await "$SUB13b" "$SID13b" "part=1 phase=decision round=1 kind=human op=1abc-approve attempt=1 need=1 got=0" # mixed seq -> REFUSED
mc_eq "none" "$(mc_state "$SUB13b" "$SID13b")" "A14 human op '1abc-approve' (mixed, not pure-digit) is REFUSED"
mc_await "$SUB13b" "$SID13b" "part=1 phase=decision round=1 kind=human op=1- attempt=1 need=1 got=0"          # empty slug -> REFUSED
mc_eq "none" "$(mc_state "$SUB13b" "$SID13b")" "A14 human op '1-' (empty slug) is REFUSED"
mc_await "$SUB13b" "$SID13b" "part=1 phase=review round=1 kind=job op=7zip-review attempt=1 need=3 got=0"       # non-digit prefix job -> ALLOWED
mc_has "op=7zip-review" "$(mc_state "$SUB13b" "$SID13b")" "A14 job op '7zip-review' (non-digit prefix) is ALLOWED"

# A14c (R8) - MORE human-op-namespace edges at the mechanism. `op=-x` has an EMPTY seq (nothing before the
# first `-`), so it is NOT a pure-digit-prefixed op and is REFUSED (a decision with no seq would collide
# with a sibling). `op=12-a-b` is a VALID seq (12) with a hyphenated slug (`a-b`) - the slug grammar allows
# `-`, so the barrier lands. `op=007-x` is a pure-digit prefix (leading zeros are digits) so it is a valid
# human op and lands. Goes RED if the seq test mis-classifies an empty seq as valid or rejects a hyphenated
# slug / leading-zero seq.
SUB13c="opedge2"; SID13c="opedge2$$"
mc_new_mission "$SUB13c" "$SID13c"
mc_await "$SUB13c" "$SID13c" "part=1 phase=decision round=1 kind=human op=-x attempt=1 need=1 got=0"          # empty seq -> REFUSED
mc_eq "none" "$(mc_state "$SUB13c" "$SID13c")" "A14 human op '-x' (empty seq) is REFUSED"
mc_await "$SUB13c" "$SID13c" "part=1 phase=decision round=1 kind=human op=12-a-b attempt=1 need=1 got=0"       # seq 12, hyphen slug -> lands
mc_has "op=12-a-b" "$(mc_state "$SUB13c" "$SID13c")" "A14 human op '12-a-b' (valid seq, hyphenated slug) lands"
SUB13d="opedge3"; SID13d="opedge3$$"
mc_new_mission "$SUB13d" "$SID13d"
mc_await "$SUB13d" "$SID13d" "part=1 phase=decision round=1 kind=human op=007-x attempt=1 need=1 got=0"        # leading-zero seq -> lands
mc_has "op=007-x" "$(mc_state "$SUB13d" "$SID13d")" "A14 human op '007-x' (leading-zero pure-digit seq) lands"

# A15 (R7-7) - AWAIT via the generic `log` verb is REFUSED directly (assert the REFUSE message, not just
# a downstream `none` - the old `none`-only assertion was tautological: a got=3 log line has no got=0
# opener, so the opener guard returns `none` even if the refusal were reverted). Capture the log output
# and require the dedicated-verb refusal; then confirm the forged AWAIT never landed.
SUB14="logawait"; SID14="logawait$$"
mc_new_mission "$SUB14" "$SID14"
A15OUT=$(mc_log_out "$SUB14" "$SID14" \
  "[mission] AWAIT part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=3 started_at=1" "m1-await-reviewbar-r1-a1-g3")
mc_has "must be written via the dedicated" "$A15OUT" "A15 log-verb AWAIT is REFUSED (dedicated-verb message)"
mc_eq "none" "$(mc_state "$SUB14" "$SID14")" "A15 refused log-verb AWAIT never lands (state none)"

# A16 (R6/R7-8) - supersede keys are +0-normalized like k4: a validator-legal `part=01 round=01` opener
# is SUPERSEDED by a canonical `part=1` bank / VOID / PART-DONE (pre-R6 the raw-string keys never
# matched, so the leading-zero barrier survived and a late bit could resurrect it). R7-8 extends beyond
# the review-bank supnr path to the VOID supnr path AND the PART-DONE pdnr path.
SUB15="leadzero"; SID15="leadzero$$"
mc_new_mission "$SUB15" "$SID15"
mc_await "$SUB15" "$SID15" "part=01 phase=review round=01 kind=job op=reviewbar attempt=1 need=3 got=0"
mc_has "await kind=job" "$(mc_state "$SUB15" "$SID15")" "A16 part=01 barrier outstanding pre-bank"
bash "$MW" log "$SID15" "${ROOT}/${SUB15}" \
  "[mission] part=1 name=x phase=review round=1 dry=2 findings=0" "m1-review-r1-d2" >/dev/null 2>&1
mc_eq "none" "$(mc_state "$SUB15" "$SID15")" "A16 canonical part=1 bank supersedes the part=01 barrier (+0-normalized keys)"

# A16-void (R7-8) - the VOID supnr path with leading-zero normalization.
SUB15v="leadzerovoid"; SID15v="leadzerovoid$$"
mc_new_mission "$SUB15v" "$SID15v"
mc_await "$SUB15v" "$SID15v" "part=01 phase=review round=01 kind=job op=reviewbar attempt=1 need=3 got=0"
mc_has "await kind=job" "$(mc_state "$SUB15v" "$SID15v")" "A16 part=01 barrier outstanding pre-VOID"
bash "$MW" log "$SID15v" "${ROOT}/${SUB15v}" \
  "[mission] VOID part=1 phase=review round=1 reason=reviewer-dead" "m1-void-r1-leadzerohnofile" >/dev/null 2>&1
mc_eq "none" "$(mc_state "$SUB15v" "$SID15v")" "A16 canonical VOID part=1 supersedes the part=01 barrier (+0-normalized)"

# A16-human-un-erasable (R8-10) - REPLACES the pre-R8 A16 assertion that a PART-DONE SUPERSEDES a human
# barrier. That old assertion encoded the ERASE HOLE: a PART-DONE (or bank/VOID) silently stepping over an
# unanswered mandatory human STOP. D10 closes it - a human barrier is superseded by NOTHING; only its OWN
# DECISION+got=1 resolves it. Three legs prove BOTH halves of the un-erasable STOP (reader keeps it live;
# writer refuses to step over it).
#
# (a) READER: a canonical PART-DONE injected DIRECTLY into the log fixture (bypassing the guarded writer)
# BELOW an open human AWAIT must NOT clear it - await-state still returns the LIVE human barrier. This
# isolates the D10 reader from the D11 writer guard (the line IS present). RED if the reader reverts to
# superseding a human barrier via pdnr (it would return `none`).
SUB15p="humanpd"; SID15p="humanpd$$"
mc_new_mission "$SUB15p" "$SID15p"
mc_pending_stop "$SUB15p" "$SID15p" approve 1 1 1 decision "Approve the destructive write?" >/dev/null
printf 'm1-part-done\t[mission] PART-DONE part=1 (converged)\n' >> "${ROOT}/${SUB15p}/MISSION.${SID15p}.log"
S15p=$(mc_state "$SUB15p" "$SID15p")
mc_has "await kind=human" "$S15p" "A16 human STOP SURVIVES a PART-DONE injected below it (D10: superseded by nothing)"
mc_has "op=1-approve"     "$S15p" "A16 the surviving live barrier is the human op (not erased by pdnr)"

# (b) DUAL (2a #17): a RESOLVED human (DECISION+got=1) followed by a later injected PART-DONE reads `none`
# - the resolved barrier does NOT resurrect, and PART-DONE is free to advance once the STOP is answered.
SUB15q="humanpddone"; SID15q="humanpddone$$"
mc_new_mission "$SUB15q" "$SID15q"
mc_pending_stop "$SUB15q" "$SID15q" approve 1 1 1 decision "Approve?" >/dev/null
mc_close_human "$SUB15q" "$SID15q" "1-approve" approve 1 1 1 decision
mc_eq "none" "$(mc_state "$SUB15q" "$SID15q")" "A16 resolved human barrier reads none (DECISION+got=1)"
printf 'm1-part-done\t[mission] PART-DONE part=1 (converged)\n' >> "${ROOT}/${SUB15q}/MISSION.${SID15q}.log"
mc_eq "none" "$(mc_state "$SUB15q" "$SID15q")" "A16 resolved human + later PART-DONE still none (no resurrection)"

# (c) WRITER: a genuinely-new PART-DONE via the dispatcher while a human barrier is OPEN is REFUSED (D11
# guard, rc=4) BEFORE the live-verify preconditions - the machine half of the un-erasable STOP. RED if the
# _mw_human_barrier_guard call on the PART-DONE path reverts.
SUB15r="pdguard"; SID15r="pdguard$$"
mc_new_mission "$SUB15r" "$SID15r"
mc_pending_stop "$SUB15r" "$SID15r" approve 1 1 1 decision "Approve?" >/dev/null
PDOUT=$(mc_log_out "$SUB15r" "$SID15r" "[mission] PART-DONE part=1 (converged)" "m1-part-done")
mc_has "OPEN human STOP barrier is live" "$PDOUT" "A16 writer REFUSES a new PART-DONE while a human STOP is open (D11 rc=4)"
mc_has "await kind=human" "$(mc_state "$SUB15r" "$SID15r")" "A16 the human barrier is still live after the refused PART-DONE"

# A17 (R7-1) - the pending-mint ROOT FIX for the human seq-REUSE collision. Two `pending` calls with the
# SAME slug MINT DISTINCT monotonic ids (pd:1-approve, pd:2-approve). Opening+closing decision 1 then
# opening decision 2 (via its DISTINCT minted op) leaves decision 2 LIVE (ready=0): the mandatory 2nd
# human STOP is never silently dropped. Goes RED if the mint reverts to an agent-reused seq (the reopen
# would then share decision 1's idtag, get dedup'd, never land, and read `none`).
SUB16="mintreuse"; SID16="mintreuse$$"
mc_new_mission "$SUB16" "$SID16"
ID1=$(mc_pending "$SUB16" "$SID16" approve "Approve the destructive migration?")
ID2=$(mc_pending "$SUB16" "$SID16" approve "Approve the credential write?")
mc_eq "pd:1-approve" "$ID1" "A17 first pending mints pd:1-approve"
mc_eq "pd:2-approve" "$ID2" "A17 second SAME-slug pending mints a DISTINCT pd:2-approve"
# lifecycle: open + close decision 1 (DECISION-first then got=1, R8-14; then resolve), then open decision 2.
OP1=${ID1#pd:}; OP2=${ID2#pd:}
mc_await "$SUB16" "$SID16" "part=1 phase=decision round=1 kind=human op=$OP1 attempt=1 need=1 got=0"
mc_has "op=1-approve" "$(mc_state "$SUB16" "$SID16")" "A17 decision 1 barrier live before close"
mc_close_human "$SUB16" "$SID16" "$OP1" approve 1 1 1 decision
mc_resolve "$SUB16" "$SID16" "$ID1" approved
mc_eq "none" "$(mc_state "$SUB16" "$SID16")" "A17 decision 1 closed (DECISION+got=1) -> none"
mc_await "$SUB16" "$SID16" "part=1 phase=decision round=1 kind=human op=$OP2 attempt=1 need=1 got=0"
S17=$(mc_state "$SUB16" "$SID16")
mc_has "op=2-approve" "$S17" "A17 decision 2 (distinct minted seq) is LIVE after decision 1 closed"
mc_has "ready=0"      "$S17" "A17 decision 2 reads ready=0 (the mandatory 2nd STOP is not skipped)"

# A18 (R7-10) - a MISSION-REBASELINED written via the generic `log` verb is REFUSED (only the dedicated
# `rebaseline` verb may emit a gen boundary; a log-routed one would forge a gen boundary WITHOUT the
# marker gen bump and slice away an earlier human AWAIT). Assert the refusal message directly.
SUB17="logrebase"; SID17="logrebase$$"
mc_new_mission "$SUB17" "$SID17"
A18OUT=$(mc_log_out "$SUB17" "$SID17" "[mission] MISSION-REBASELINED status=active gen=2 (forged)" "")
mc_has "must be written via the dedicated" "$A18OUT" "A18 log-verb MISSION-REBASELINED is REFUSED (dedicated-verb message)"

mc_finish '{"open_got0":"outstanding ready=0","partial_got2":"outstanding got=2 ready=0","or_join":"outstanding got=3 ready=1","banked_round_supersedes":"none","void_supersedes":"none","void_then_fresh_attempt":"outstanding attempt=2","human_await":"outstanding kind=human","human_await_closed":"DECISION-first -> none","started_at_stable":"1000","embedded_await_no_inject":"none","kind_not_mixed":"human survives job bit","field_injection_refused":"kind=job got=1","attempt_select_highest":"attempt=2","human_op_not_masked":"op=2-approve outstanding (same slug, distinct seq)","opener_guard_late_bit":"none","op_namespace_guard":"human-no-seq + job-seq REFUSED","op_seq_edges":"1abc/1- REFUSED, 7zip-review ALLOWED","op_seq_edges2":"-x REFUSED, 12-a-b + 007-x land","log_verb_await_refused":"refuse-message + none","leadzero_supersede":"review + VOID both none","human_un_erasable":"reader keeps human live under injected PART-DONE; resolved+PART-DONE none; writer refuses PART-DONE rc=4","pending_mint_reuse":"pd:1 + pd:2 distinct, decision-2 live ready=0","log_verb_rebaseline_refused":"refuse-message"}' \
  "AWAIT open -> partial -> OR-join(ready) -> bank/VOID supersede + fresh attempt + human(DECISION-first close) + started_at + no-inject + key-by-kind + field-inject-refused + attempt-select + op-keying + opener-guard + op-namespace-guard + seq-edges(+ -x/12-a-b/007-x) + log-await-refuse + leadzero(review/void) + human-un-erasable(reader+writer) + pending-mint-reuse + log-rebaseline-refuse"
