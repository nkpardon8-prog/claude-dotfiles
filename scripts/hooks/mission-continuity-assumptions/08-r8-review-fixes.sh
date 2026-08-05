#!/usr/bin/env bash
# 08 - round-8 /codex-review fix pass: RED-on-revert guards for the four CRITICAL bypasses (C1-C4) and the
# IMPORTANT hardening (I1-I8) found by the 6-lens review of the round-8 mission-stall-fix implementation.
# Every failure guarded here is SILENT and SAFETY-critical - a preplanted approval that satisfies a human
# STOP, an unrelated request that rebinds an open barrier's question, a torn/pre-opener DECISION that
# closes a barrier, a rebaseline/clear that erases an open STOP, a forged pending line, a poisoned seq
# counter, a legacy lockdir that wedges god-review forever. Each is a green tick over a dropped or forged
# human approval - the exact class the STOP machinery exists to prevent.
#
# NEGATIVE CONTROLS (each fix reverts one assertion RED, independent missions so one revert reddens one leg):
#   C1a: drop DECISION from _mission_pdseq_highwater -> preplanted DECISION op=1 lets a fresh mint reuse
#        op=1 (expects pd:2, revert -> pd:1).
#   C1b: drop the NR (after-opener) check in mission_await_append's DECISION-first gate -> a pre-opener
#        DECISION satisfies the got=1 close (expects REFUSED).
#   C2:  restore adopt-before-match -> a DIFFERENT request adopts the orphan (expects rc=12, no forge);
#        FIX B (R8r2): a LOST-pd orphan is UNVERIFIABLE so even an EXACT re-request fails closed (rc=14).
#   C3:  drop the `outcome=(approve|deny)$` body anchor -> a torn DECISION satisfies the close.
#   C4:  drop the under-lock await-state re-check in mission_rebaseline / mission_clear_append -> a direct
#        call proceeds and erases the open STOP (expects rc=7 / rc=4, barrier survives).
#   I1:  drop the newline/`- [pd:` question guard -> a forged md/pending line lands (expects rc=1).
#   I2:  drop the high-water seed from the non-blocking `pending` mint -> reuses a live seq (expects pd:5).
#   I3:  drop the resolve pd-id grammar gate -> a crafted id breaks the strip (expects rc=1).
#   I4:  part=08 (octal-looking) coord idempotent re-request matches via leading-zero STRING strip (FIX G).
#   I6:  drop the idtag anchor from the seed scans -> free-text poison forces false exhaustion (expects pd:1).
#   I8:  drop `rm -f "$LOCKDIR/budget"` from the reclaim -> a legacy budget file wedges rmdir forever.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "08-r8-review-fixes"

# ── C1a - STALE-APPROVE BYPASS, seed side: a preplanted DECISION forces the mint PAST that op ────────────
# A `log`-planted DECISION op=1-approve (no AWAIT, no pd line) must lift the fresh-mint seed so op=1 is
# NEVER reminted - else the preplanted DECISION would later satisfy op=1's mandatory human close (bypass).
SUBc1a="c1seed"; SIDc1a="c1seed$$"
mc_new_mission "$SUBc1a" "$SIDc1a"
mc_decision "$SUBc1a" "$SIDc1a" "1-approve" approve         # preplant DECISION op=1 in the log (no barrier)
IDc1a=$(mc_pending_stop "$SUBc1a" "$SIDc1a" approve 1 1 1 decision "Approve X?")
mc_eq "pd:2-approve" "$IDc1a" "C1a a preplanted DECISION op=1 forces the mint to seq>=2 (no remint of op=1)"

# ── C1b - STALE-APPROVE BYPASS, close side: a DECISION BEFORE the got=0 opener cannot close the barrier ──
# The DECISION-first gate must require the DECISION to appear AFTER the barrier's got=0 opener (NR order in
# the active-gen stream), not merely EXIST - so a DECISION preplanted before the barrier cannot authorize it.
SUBc1b="c1close"; SIDc1b="c1close$$"
mc_new_mission "$SUBc1b" "$SIDc1b"
mc_decision "$SUBc1b" "$SIDc1b" "5-grant" approve          # DECISION FIRST (NR before the opener)
mc_await "$SUBc1b" "$SIDc1b" "part=1 phase=decision round=1 kind=human op=5-grant attempt=1 need=1 got=0"
OUTc1b=$(mc_await_out "$SUBc1b" "$SIDc1b" "part=1 phase=decision round=1 kind=human op=5-grant attempt=1 need=1 got=1")
mc_has "DECISION-first" "$OUTc1b" "C1b a DECISION recorded BEFORE the got=0 opener does NOT satisfy the got=1 close"
mc_has "await kind=human" "$(mc_state "$SUBc1b" "$SIDc1b")" "C1b the barrier stays LIVE after the refused pre-opener close"
# positive control: a DECISION recorded AFTER the opener DOES close the barrier (the gate is not just off)
mc_await "$SUBc1b" "$SIDc1b" "part=2 phase=decision round=1 kind=human op=6-open attempt=1 need=1 got=0"
mc_decision "$SUBc1b" "$SIDc1b" "6-open" approve           # DECISION after the opener (NR later)
OUTc1bp=$(mc_await_out "$SUBc1b" "$SIDc1b" "part=2 phase=decision round=1 kind=human op=6-open attempt=1 need=1 got=1")
mc_has "await ok" "$OUTc1bp" "C1b positive: a DECISION recorded AFTER the opener ALLOWS the got=1 close"

# ── C2 - ORPHAN-ADOPT WRONG-BINDING: a DIFFERENT request must not adopt an open orphan barrier ──────────
# The identity match (slug+coords) is checked BEFORE any adopt, so an unrelated request while a human
# barrier is open FAILS CLOSED (never rebinds its question to the open op); an EXACT re-request adopts.
SUBc2="c2orphan"; SIDc2="c2orphan$$"
mc_new_mission "$SUBc2" "$SIDc2"
mc_pending_stop "$SUBc2" "$SIDc2" approve 1 1 1 decision "Approve orig?" >/dev/null
MDc2="${ROOT}/${SUBc2}/MISSION.${SIDc2}.md"
perl -0pi -e 's/^- \[pd:1-approve\][^\n]*\n(<!-- mid:[^\n]*-->\n)?//m' "$MDc2"   # crash -> orphan
mc_eq "0" "$(mc_has_pd "$SUBc2" "$SIDc2" pd:1-approve)" "C2 pd line gone (orphan) after the crash sim"
OUTc2=$(mc_pending_stop_out "$SUBc2" "$SIDc2" deploy 2 1 1 decision "Deploy prod?")
# R8r3-R8: a DIFFERENT open human STOP is now the DISTINCT rc=12 (non-retryable), not the conflated rc=3.
mc_has "rc=12" "$OUTc2" "C2 a DIFFERENT request while a human barrier is open FAILS CLOSED (rc=12, no adopt)"
mc_eq "0" "$(mc_has_pd "$SUBc2" "$SIDc2" pd:1-approve)" "C2 the different request did NOT forge/rebind a pd line onto the open op"
mc_has "op=1-approve" "$(mc_state "$SUBc2" "$SIDc2")" "C2 the ORIGINAL orphan barrier is still the single live STOP"
# FIX B (R8r2): a LOST-pd orphan can NOT be re-adopted even by an EXACT re-request - the ORIGINAL question
# is GONE with the pd line so the supplied question is UNVERIFIABLE => FAIL CLOSED, no silent adopt.
# R8r3-R8: the orphan class is now the DISTINCT rc=14 (non-retryable: resolve/deny explicitly), not rc=3.
OUTc2b=$(mc_pending_stop_out "$SUBc2" "$SIDc2" approve 1 1 1 decision "Approve orig?")
mc_has "rc=14" "$OUTc2b" "C2 an EXACT re-request on a LOST-pd orphan is REFUSED (rc=14, question unverifiable) - no silent adopt"
mc_eq "0" "$(mc_has_pd "$SUBc2" "$SIDc2" pd:1-approve)" "C2 the refused exact re-request did NOT restore/forge the pd line"

# ── C3 - DECISION-FIRST DOUBLE-ANCHOR: a torn DECISION (no outcome=) cannot close the barrier ───────────
# The DECISION body must FULLY match `outcome=(approve|deny)$`; a torn append ending at `op=<op>` must NOT
# satisfy the got=1 close. Inject a torn line directly (the validator would reject it, so bypass it).
SUBc3="c3torn"; SIDc3="c3torn$$"
mc_new_mission "$SUBc3" "$SIDc3"
mc_pending_stop "$SUBc3" "$SIDc3" approve 1 1 1 decision "Approve?" >/dev/null
printf 'pd-1-decision-approve\t[mission] DECISION op=1-approve\n' >> "$(mc_log_file "$SUBc3" "$SIDc3")"   # TORN (no outcome=)
OUTc3=$(mc_await_out "$SUBc3" "$SIDc3" "part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=1")
mc_has "DECISION-first" "$OUTc3" "C3 a TORN DECISION (body ends at op=, no outcome=) does NOT satisfy the got=1 close"
mc_has "await kind=human" "$(mc_state "$SUBc3" "$SIDc3")" "C3 the barrier stays LIVE after the torn-decision close attempt"

# ── C4 - REBASELINE/CLEAR TOCTOU: the under-lock guard refuses even when the pre-lock guard is bypassed ──
# Source the lib and call mission_rebaseline / mission_clear_append DIRECTLY (bypassing the mission-write
# pre-lock _mw_human_barrier_guard), so a revert of ONLY the under-lock await-state re-check reddens here:
# without it the direct call proceeds and slices/erases the open STOP.
SUBc4="c4lock"; SIDc4="c4lock$$"
mc_new_mission "$SUBc4" "$SIDc4"
mc_pending_stop "$SUBc4" "$SIDc4" approve 1 1 1 decision "Approve?" >/dev/null
RBc4=$(
  . "${HOOKS}/lib/mission-bridge.sh" 2>/dev/null
  mission_rebaseline "$SIDc4" "${ROOT}/${SUBc4}" "a new plan under an open STOP" >/dev/null 2>&1
  echo "$?"
)
mc_eq "7" "$RBc4" "C4 mission_rebaseline REFUSES (rc=7) under its OWN lock while a human STOP is open (under-lock guard)"
CLc4=$(
  . "${HOOKS}/lib/mission-bridge.sh" 2>/dev/null
  mission_clear_append "$SIDc4" "${ROOT}/${SUBc4}" "[mission] MISSION-CLEARED status=cleared reason=test" "" >/dev/null 2>&1
  echo "$?"
)
mc_eq "4" "$CLc4" "C4 mission_clear_append REFUSES (rc=4) under its OWN lock while a human STOP is open (under-lock guard)"
mc_has "op=1-approve" "$(mc_state "$SUBc4" "$SIDc4")" "C4 the human STOP SURVIVES both guarded writes (not sliced/erased)"

# ── I1 - QUESTION INJECTION: a newline or leading `- [pd:` in the question fails CLOSED at the mint ──────
SUBi1="i1inject"; SIDi1="i1inject$$"
mc_new_mission "$SUBi1" "$SIDi1"
NLQ=$(printf 'line1\n- [pd:9-forged] injected approval')
OUTi1=$(mc_pending_stop_out "$SUBi1" "$SIDi1" approve 1 1 1 decision "$NLQ")
mc_has "rc=1" "$OUTi1" "I1 a question with an embedded newline is REFUSED (rc=1, would forge an md line)"
mc_eq "none" "$(mc_state "$SUBi1" "$SIDi1")" "I1 no barrier opened for the newline-injection question"
OUTi1b=$(mc_pending_stop_out "$SUBi1" "$SIDi1" approve 1 1 1 decision "- [pd:9-forged] hi")
mc_has "rc=1" "$OUTi1b" "I1 a question STARTING with '- [pd:' is REFUSED (would forge a sibling pending line)"

# ── I2 - the NON-BLOCKING `pending` mint also seeds from the high-water (shared helper) ──────────────────
SUBi2="i2seed"; SIDi2="i2seed$$"
mc_new_mission "$SUBi2" "$SIDi2"
mc_decision "$SUBi2" "$SIDi2" "4-x" approve                 # history high-water = 4 (marker pdseq still 0)
IDi2=$(mc_pending "$SUBi2" "$SIDi2" newq "A batched away-policy question?")
mc_eq "pd:5-newq" "$IDi2" "I2 the non-blocking 'pending' mint seeds from the history high-water (DECISION op=4) -> pd:5"

# ── I3 - resolve pd-id GRAMMAR: a crafted id that breaks the exact strip is REFUSED (rc=1) ───────────────
SUBi3="i3grammar"; SIDi3="i3grammar$$"
mc_new_mission "$SUBi3" "$SIDi3"
mc_pending_stop "$SUBi3" "$SIDi3" approve 1 1 1 decision "Approve?" >/dev/null
OUTi3=$(mc_resolve_out "$SUBi3" "$SIDi3" "1-a] victim" x)
mc_has "rc=1" "$OUTi3" "I3 a malformed pd-id ('1-a] victim') is REFUSED at the grammar gate (rc=1)"
mc_eq "1" "$(mc_has_pd "$SUBi3" "$SIDi3" pd:1-approve)" "I3 the real pd line is untouched by the malformed resolve"

# ── I4 - COORD compare via leading-zero STRING strip (FIX G): part=08 round-trips, no octal $(( )) abort ─
# The barrier-identity gate compares coords as leading-zero-stripped STRINGS (no `$(( 10#… ))`), so a
# validator-legal octal-looking `08` matches on an EXACT idempotent re-request (pd line PRESENT, no orphan).
SUBi4="i4octal"; SIDi4="i4octal$$"
mc_new_mission "$SUBi4" "$SIDi4"
mc_pending_stop "$SUBi4" "$SIDi4" approve 08 1 1 decision "Approve at 08?" >/dev/null
IDi4=$(mc_pending_stop "$SUBi4" "$SIDi4" approve 08 1 1 decision "Approve at 08?")
mc_eq "pd:1-approve" "$IDi4" "I4 a part=08 (octal-looking) coord idempotent re-request matches via string-compare (no arithmetic abort)"

# ── I5 - IDEMPOTENT-REDRIVE is ARCHIVE-INCLUSIVE: an already-resolved id redriven after a rebaseline ─────
# The redrive check must search the ALL-generation stream, not the active-gen slice, so a `resolve-<id>`
# narrative recorded in gen N-1 (before a later rebaseline boundary) is still found -> QUIET OK, not a
# false "never existed" (rc=8).
SUBi5="i5redrive"; SIDi5="i5redrive$$"
mc_new_mission "$SUBi5" "$SIDi5"
mc_pending_stop "$SUBi5" "$SIDi5" approve 1 1 1 decision "Approve?" >/dev/null
mc_close_human "$SUBi5" "$SIDi5" "1-approve" approve 1 1 1 decision
mc_resolve "$SUBi5" "$SIDi5" "pd:1-approve" ok                                  # resolved in gen 1
bash "$MW" rebaseline "$SIDi5" "${ROOT}/${SUBi5}" "a fresh rebaselined plan" >/dev/null 2>&1   # gen -> 2
OUTi5=$(mc_resolve_out "$SUBi5" "$SIDi5" "pd:1-approve" ok)                     # redrive AFTER the rebaseline
mc_has "already resolved" "$OUTi5" "I5 an already-resolved id redriven AFTER a rebaseline is QUIET OK (archive-inclusive), not a false never-existed"

# ── I7 - EXACT-RETRY includes the QUESTION: a changed question at the same slug+coords is REFUSED ────────
SUBi7="i7question"; SIDi7="i7question$$"
mc_new_mission "$SUBi7" "$SIDi7"
mc_pending_stop "$SUBi7" "$SIDi7" approve 1 1 1 decision "Question ONE" >/dev/null
OUTi7=$(mc_pending_stop_out "$SUBi7" "$SIDi7" approve 1 1 1 decision "Question TWO")
# R8r3-R8: a changed question at the same op is the DISTINCT rc=13 (non-retryable), not the conflated rc=3.
mc_has "rc=13" "$OUTi7" "I7 same slug+coords with a CHANGED question is REFUSED (rc=13, not a silent idempotent reuse)"
IDi7=$(mc_pending_stop "$SUBi7" "$SIDi7" approve 1 1 1 decision "Question ONE")
mc_eq "pd:1-approve" "$IDi7" "I7 an EXACT re-request (same slug+coords+question) is the idempotent no-op"

# ── I6 - SEED POISON: free-text `resolved pd:999999`/`op=999999` cannot force a false sequence-exhaustion ─
SUBi6="i6poison"; SIDi6="i6poison$$"
mc_new_mission "$SUBi6" "$SIDi6"
LOGi6="$(mc_log_file "$SUBi6" "$SIDi6")"
printf 'm1-criticer-r1\t[mission] criticer note mentions resolved pd:999999-poison and op=999999-x\n' >> "$LOGi6"
printf '\tresolved pd:888888-freetext op=888888-x\n' >> "$LOGi6"
IDi6=$(mc_pending_stop "$SUBi6" "$SIDi6" approve 1 1 1 decision "Approve?")
mc_eq "pd:1-approve" "$IDi6" "I6 free-text 'resolved pd:999999'/'op=999999' (no anchored idtag) does NOT poison the seed -> pd:1"

# ── I8 - CODEX-INVOKE legacy budget residue: the stale-lockdir reclaim clears a round-7 budget FILE ──────
# A lockdir left by a SIGKILLed round-7 holder still contains a `budget` file; a plain rmdir cannot remove
# a non-empty dir, so the reclaim must `rm -f "$LOCKDIR/budget"` FIRST. Extract the real reclaim block and
# eval it against a fixture stale lockdir; assert the dir is removed. RED if the rm-f line reverts.
CIVK8="$(cd "${HOOKS}/../.." && pwd -P)/commands/god-review/lib/codex-invoke.sh"
if [ -f "$CIVK8" ]; then
  RECLAIM=$(awk '/if \[ -d "\$LOCKDIR" \]; then/{c=1} c{print} c&&/^fi$/{exit}' "$CIVK8")
  if [ -n "$RECLAIM" ]; then
    LKD8="${ROOT}/codexlock.d"
    mkdir -p "$LKD8"; printf 'stale-round7-budget\n' > "$LKD8/budget"
    touch -t 200001010000 "$LKD8" 2>/dev/null
    ( LOCKDIR="$LKD8"; _LOCK_CAP_FLOOR=$((21600 + 60)); _SPIN_RAISE=0; WORK_OUT=/dev/null; eval "$RECLAIM" )
    if [ -d "$LKD8" ]; then
      mc_fail "I8 the stale lockdir SURVIVES - the legacy budget file was not cleared (rmdir blocked)"
    else
      mc_ok "I8 the reclaim clears the legacy budget file and force-removes the stale lockdir"
    fi
  else
    mc_fail "I8 could not extract the stale-lockdir reclaim block from codex-invoke.sh"
  fi
else
  mc_fail "I8 codex-invoke.sh not found at ${CIVK8}"
fi

# ── R8r2-A - the PUBLIC `await` verb REFUSES a lock-free human got=0 opener (only pending-stop opens) ────
# A lock-free append ignores the mkdir-lock, so a human got=0 opener via the public `await` verb could
# interleave INSIDE clear's/rebaseline's held-lock window and be sliced/hidden. Only pending-stop (lock-HELD,
# mutually exclusive with clear/rebaseline) may open a human STOP. The public verb (NO internal flag) is
# refused; pending-stop STILL opens (positive control). RED if the got=0 human refusal reverts.
SUBa8="a_opener"; SIDa8="a_opener$$"
mc_new_mission "$SUBa8" "$SIDa8"
OUTa8=$(bash "$MW" await "$SIDa8" "${ROOT}/${SUBa8}" "part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=0" 2>&1)
mc_has "REFUSED" "$OUTa8" "R8r2-A the PUBLIC await verb REFUSES a lock-free human got=0 opener"
mc_eq "none" "$(mc_state "$SUBa8" "$SIDa8")" "R8r2-A no human STOP opened via the public await verb"
IDa8=$(mc_pending_stop "$SUBa8" "$SIDa8" approve 1 1 1 decision "Approve?")
mc_eq "pd:1-approve" "$IDa8" "R8r2-A pending-stop STILL opens the human STOP (sanctioned under-lock path)"

# ── R8r2-D - pending-stop REFUSES opening a STOP below a MISSION-CLEARED lifecycle ──────────────────────
# If clear wins the lock first, await-state reads `none` (cleared short-circuit); a fresh STOP appended
# below MISSION-CLEARED would be permanently hidden. pending-stop re-checks the cleared lifecycle UNDER the
# lock and fails closed. R8r3-R8: CLEARED is now the DISTINCT rc=10 (non-retryable), not the conflated rc=3.
SUBd8="d_cleared"; SIDd8="d_cleared$$"
mc_new_mission "$SUBd8" "$SIDd8"
# source the lib in a subshell (08 sources it only inside subshells, mirroring C4) and clear directly.
( . "${HOOKS}/lib/mission-bridge.sh" 2>/dev/null
  mission_clear_append "$SIDd8" "${ROOT}/${SUBd8}" "[mission] MISSION-CLEARED status=cleared reason=test" "" >/dev/null 2>&1 )
OUTd8=$(mc_pending_stop_out "$SUBd8" "$SIDd8" approve 1 1 1 decision "Approve after clear?")
mc_has "rc=10" "$OUTd8" "R8r2-D pending-stop REFUSES (rc=10) opening a STOP below MISSION-CLEARED"

# ── R8r2-C-reader - a DECISION whose IDTAG encoded-op != BODY op does NOT authorize the close ────────────
# The DECISION-first close reader matches idtag `pd-<seq>-decision-<slug>` + body `op=<op>`. Without binding
# the idtag's encoded op to the body op, a FORGED raw line (`pd-999-decision-other` + `op=1-approve`) would
# satisfy the gate and close op=1-approve. Forge one directly into the log (the forged-line threat model);
# the close must STILL be refused and the barrier stay live. RED if the idtag<->body-op bind reverts.
SUBc8="c_reader"; SIDc8="c_reader$$"
mc_new_mission "$SUBc8" "$SIDc8"
mc_pending_stop "$SUBc8" "$SIDc8" approve 1 1 1 decision "Approve?" >/dev/null
printf 'pd-999-decision-other\t[mission] DECISION op=1-approve outcome=approve\n' >> "$(mc_log_file "$SUBc8" "$SIDc8")"
OUTc8=$(mc_await_out "$SUBc8" "$SIDc8" "part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=1")
mc_has "DECISION-first" "$OUTc8" "R8r2-C-reader a DECISION whose idtag op != body op does NOT authorize the close"
mc_has "await kind=human" "$(mc_state "$SUBc8" "$SIDc8")" "R8r2-C-reader the barrier STAYS live (mismatched-idtag DECISION rejected)"

# ── R8r3-R1 - an ENV-inherited internal flag CANNOT bypass FIX A (mission-write unsets it at the CLI entry) ─
# _MISSION_INTERNAL_HUMAN_OPEN is the SANCTIONED opener's same-process function-prefix. If a caller EXPORTS
# it, the child `bash mission-write.sh` would INHERIT it and the public `await ... kind=human got=0` would
# open a LOCK-FREE human STOP through the public path - defeating FIX A (the clear/rebaseline TOCTOU race).
# R1 unsets it at the top of mission-write.sh, so even an env-inherited flag is dropped: the public got=0
# human opener STAYS refused and no barrier lands. Distinct from R8r2-A (marker-LESS refusal): this proves
# the ENV-inheritance bypass specifically. RED if `unset _MISSION_INTERNAL_HUMAN_OPEN` reverts.
SUBr1="r1env"; SIDr1="r1env$$"
mc_new_mission "$SUBr1" "$SIDr1"
OUTr1=$(_MISSION_INTERNAL_HUMAN_OPEN=1 bash "$MW" await "$SIDr1" "${ROOT}/${SUBr1}" "part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=0" 2>&1)
mc_has "REFUSED" "$OUTr1" "R8r3-R1 an ENV-inherited _MISSION_INTERNAL_HUMAN_OPEN STILL cannot open a human got=0 via the public await verb"
mc_eq "none" "$(mc_state "$SUBr1" "$SIDr1")" "R8r3-R1 no human STOP opened via the env-inherited bypass (FIX A holds)"

# ── R8r3-R10 - STRUCTURED seed poison: an idtag-PRESENT line whose ENCODED op != BODY op is IGNORED ──────
# I6 covers FREE-TEXT poison (no anchored idtag). R10 covers STRUCTURED poison: a forged AWAIT/DECISION
# whose idtag encodes op=1-approve but whose BODY says op=999999-x. Without the idtag<->body-op bind in the
# AWAIT + DECISION high-water scans, the body op=999999 drives the seed -> next mint 1000000 > 999999 =
# REFUSED sequence-exhausted = a PERMANENT stall (all future mints refused). With the bind the mismatched
# lines are ignored -> the fresh mint seeds from 0 -> pd:1. Forge both directly into the log (forged-line
# threat model; got=1 so the AWAIT is not a live STOP). RED if the AWAIT/DECISION idtag<->body-op bind reverts.
SUBr10="r10poison"; SIDr10="r10poison$$"
mc_new_mission "$SUBr10" "$SIDr10"
LOGr10="$(mc_log_file "$SUBr10" "$SIDr10")"
printf 'm1-await-1-approve-r1-a1-g1\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=999999-x attempt=1 need=1 got=1 started_at=1\n' >> "$LOGr10"
printf 'pd-1-decision-approve\t[mission] DECISION op=999999-x outcome=approve\n' >> "$LOGr10"
IDr10=$(mc_pending_stop "$SUBr10" "$SIDr10" approve 1 1 1 decision "Approve after structured poison?")
mc_eq "pd:1-approve" "$IDr10" "R8r3-R10 a STRUCTURED (idtag-present, op-mismatched) AWAIT+DECISION does NOT poison the seed -> pd:1"

# ── R8r3-R11 - the PART-DONE UNDER-LOCK wrapper itself refuses an open STOP (real RED-on-revert for FIX J) ─
# 02-A16(c) drives PART-DONE through the DISPATCHER, whose LOCK-FREE _mw_partdone_check pre-check refuses
# FIRST - so reverting the UNDER-LOCK wrapper (mission_partdone_append) stays GREEN there (the pre-check
# masks it). This exercises the wrapper DIRECTLY (bypassing the dispatcher pre-check): with an open human
# STOP, a genuinely-new PART-DONE via mission_partdone_append must return rc=4 and NOT append. RED if the
# under-lock human-barrier re-check in mission_partdone_append reverts (a plain append would return rc=0).
SUBr11="r11wrap"; SIDr11="r11wrap$$"
mc_new_mission "$SUBr11" "$SIDr11"
mc_pending_stop "$SUBr11" "$SIDr11" approve 1 1 1 decision "Approve?" >/dev/null
RCr11=$( . "${HOOKS}/lib/mission-bridge.sh" 2>/dev/null
         mission_partdone_append "$SIDr11" "${ROOT}/${SUBr11}" "[mission] PART-DONE part=1 (converged)" "m1-part-done" >/dev/null 2>&1
         echo $? )
mc_eq "4" "$RCr11" "R8r3-R11 mission_partdone_append (under-lock wrapper) REFUSES rc=4 while a human STOP is open"
mc_eq "0" "$(grep -c 'PART-DONE part=1' "$(mc_log_file "$SUBr11" "$SIDr11")")" "R8r3-R11 the refused PART-DONE did NOT append"

# ── R8r3-R12 - the PART-DONE wrapper is DEDUP-FIRST (an idempotent re-emit is NOT refused as rc=4) ───────
# _mw_partdone_check returns early on an already-banked idtag (so the dispatcher pre-check never runs), but
# the dispatcher STILL calls the wrapper. If a human STOP opened after the part banked, an UNCONDITIONAL
# re-check would turn a quiet dedup into rc=4. The wrapper must dedup-FIRST: bank the PART-DONE, open a STOP,
# then RE-EMIT the SAME idtag -> quiet ok (rc=0), not rc=4. RED if the dedup-first guard reverts.
SUBr12="r12dedup"; SIDr12="r12dedup$$"
mc_new_mission "$SUBr12" "$SIDr12"
( . "${HOOKS}/lib/mission-bridge.sh" 2>/dev/null
  mission_partdone_append "$SIDr12" "${ROOT}/${SUBr12}" "[mission] PART-DONE part=1 (converged)" "m1-part-done" >/dev/null 2>&1 )
mc_eq "1" "$(grep -c 'PART-DONE part=1' "$(mc_log_file "$SUBr12" "$SIDr12")")" "R8r3-R12 the initial PART-DONE banked (no STOP)"
mc_pending_stop "$SUBr12" "$SIDr12" approve 1 1 1 decision "Approve next?" >/dev/null
RCr12=$( . "${HOOKS}/lib/mission-bridge.sh" 2>/dev/null
         mission_partdone_append "$SIDr12" "${ROOT}/${SUBr12}" "[mission] PART-DONE part=1 (converged)" "m1-part-done" >/dev/null 2>&1
         echo $? )
mc_eq "0" "$RCr12" "R8r3-R12 an idempotent PART-DONE re-emit is a QUIET dedup (rc=0), NOT rc=4, even with a STOP open"

# ══ ROUND-8 REVIEW ROUND-4 (R8r4) ═══════════════════════════════════════════════════════════════════════

# ── R8r4-C9 (KEYSTONE) - the READER (await-state) enforces DECISION-first, not just the writer ───────────
# CORE-BYPASS class: DECISION-first was enforced ONLY on the writer (mission_await_append). The READER
# (mission_await_state, the verdict the WAKE consumes) OR-selected on got, so a forged/planted raw
# `AWAIT kind=human got=1` line made the reader read RESOLVED with NO DECISION - a stale-approve bypass at
# the read layer. FIX: a human barrier reads RESOLVED only if got meets need AND a matching post-opener
# DECISION exists; else it stays LIVE (got=0 ready=0). RED if the reader-side DECISION-first check reverts.
SUBc9="c9reader"; SIDc9="c9reader$$"
mc_new_mission "$SUBc9" "$SIDc9"
mc_pending_stop "$SUBc9" "$SIDc9" approve 1 1 1 decision "Approve?" >/dev/null   # real got=0 human opener op=1-approve
LOGc9="$(mc_log_file "$SUBc9" "$SIDc9")"
# (a) a FORGED got=1 close with NO DECISION must NOT resolve the STOP - it stays LIVE (fail-closed).
printf 'm1-await-1-approve-r1-a1-g1\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=1 started_at=1\n' >> "$LOGc9"
Sc9a="$(mc_state "$SUBc9" "$SIDc9")"
mc_has "await kind=human" "$Sc9a" "R8r4-C9 a forged got=1 with NO DECISION stays LIVE at the reader (DECISION-first)"
mc_has "ready=0" "$Sc9a" "R8r4-C9 the forged got=1 barrier reports ready=0 (fail-closed, got not trusted)"
# (b) R8r5-D3 - a DECISION recorded AFTER the got=1 close does NOT resolve it. The barrier from (a) already
#     carries the forged got=1; a DECISION appended now lands at a HIGHER NR than the got=1, violating the
#     sanctioned order (DECISION -> got=1). A got=1-that-preceded-its-DECISION stays LIVE (fail-safe: a
#     forged got=1 followed by a late/forged approve must NOT resolve). RED if the reader drops the
#     decnr<maxnr ordering check.
printf 'pd-1-decision-approve\t[mission] DECISION op=1-approve outcome=approve\n' >> "$LOGc9"
mc_has "await kind=human" "$(mc_state "$SUBc9" "$SIDc9")" "R8r5-D3 a DECISION recorded AFTER the got=1 stays LIVE (got=1-before-DECISION not resolved)"
# (b2) the SANCTIONED order (opener -> DECISION -> got=1 close) DOES resolve it (reads none).
SUBc9c="c9order"; SIDc9c="c9order$$"
mc_new_mission "$SUBc9c" "$SIDc9c"
mc_pending_stop "$SUBc9c" "$SIDc9c" approve 1 1 1 decision "Approve?" >/dev/null   # real got=0 human opener op=1-approve
LOGc9c="$(mc_log_file "$SUBc9c" "$SIDc9c")"
printf 'pd-1-decision-approve\t[mission] DECISION op=1-approve outcome=approve\n' >> "$LOGc9c"                                                                   # DECISION FIRST
printf 'm1-await-1-approve-r1-a1-g1\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=1 started_at=1\n' >> "$LOGc9c"   # THEN got=1 close
mc_eq "none" "$(mc_state "$SUBc9c" "$SIDc9c")" "R8r4-C9/D3 the SANCTIONED order (DECISION before got=1) resolves the barrier -> none"
# (c) a MISMATCHED-idtag DECISION (idtag op != body op) does NOT resolve - the barrier stays LIVE.
SUBc9b="c9mismatch"; SIDc9b="c9mismatch$$"
mc_new_mission "$SUBc9b" "$SIDc9b"
mc_pending_stop "$SUBc9b" "$SIDc9b" approve 1 1 1 decision "Approve?" >/dev/null
LOGc9b="$(mc_log_file "$SUBc9b" "$SIDc9b")"
printf 'm1-await-1-approve-r1-a1-g1\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=1 started_at=1\n' >> "$LOGc9b"
printf 'pd-999-decision-other\t[mission] DECISION op=1-approve outcome=approve\n' >> "$LOGc9b"   # idtag encodes op=999-other != body op=1-approve
mc_has "await kind=human" "$(mc_state "$SUBc9b" "$SIDc9b")" "R8r4-C9 a mismatched-idtag DECISION does NOT resolve (barrier stays LIVE)"

# ── R8r4-C4 - resolve's open-barrier check is OP-SPECIFIC (not await-state's single top selection) ───────
# await-state returns ONE top barrier (human > job, then attempt, then NR). If a DIFFERENT open human STOP
# OUTRANKS the requested op, the old resolve read the outranking barrier, saw op != requested, passed its
# guard, and drained the requested op's pd WHILE ITS OWN STOP was still open. FIX: pass the op to
# await-state so it returns THIS op's barrier. RED if the op-specific arg reverts (resolve drains it).
SUBc4b="c4opspec"; SIDc4b="c4opspec$$"
mc_new_mission "$SUBc4b" "$SIDc4b"
mc_pending_stop "$SUBc4b" "$SIDc4b" approve 1 1 1 decision "Approve A?" >/dev/null   # real op=1-approve got=0 + pd line
LOGc4b="$(mc_log_file "$SUBc4b" "$SIDc4b")"
# forge a SECOND live human barrier for a DIFFERENT op that OUTRANKS op=1-approve (same attempt, higher NR).
printf 'm1-await-2-other-r1-a1-g0\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=2-other attempt=1 need=1 got=0 started_at=2\n' >> "$LOGc4b"
mc_has "op=2-other" "$(mc_state "$SUBc4b" "$SIDc4b")" "R8r4-C4 the outranking barrier (op=2-other) is await-state's UNFILTERED top selection"
OUTc4b=$(mc_resolve_out "$SUBc4b" "$SIDc4b" "pd:1-approve")
mc_has "rc=9" "$OUTc4b" "R8r4-C4 resolve is REFUSED (rc=9) for op=1-approve - its OWN STOP is open despite op=2-other outranking"
mc_eq "1" "$(mc_has_pd "$SUBc4b" "$SIDc4b" pd:1-approve)" "R8r4-C4 op=1-approve's pd line is NOT drained (op-specific fail-closed)"

# ── R8r4-C5/C11 - a readable-but-CORRUPT gzip archive makes await-state fail CLOSED (corrupt, not none) ──
# _mission_timing_stream reads every archive with `gzip -dc 2>/dev/null`, so a corrupt .gz silently yields
# no line and await-state emitted `none` - erasing an open STOP. FIX: a `gzip -t` integrity pre-check emits
# `corrupt`. RED if the read-integrity check reverts (the corrupt archive is skipped -> reads none).
SUBc5="c5corrupt"; SIDc5="c5corrupt$$"
mc_new_mission "$SUBc5" "$SIDc5"
mc_eq "none" "$(mc_state "$SUBc5" "$SIDc5")" "R8r4-C5 healthy mission (no barriers) reads none"
mkdir -p "${ROOT}/${SUBc5}/.mission-backups"
printf 'this is not valid gzip data at all' > "${ROOT}/${SUBc5}/.mission-backups/MISSION.${SIDc5}.log.20200101T000000Z.corrupt.gz"
mc_eq "corrupt" "$(mc_state "$SUBc5" "$SIDc5")" "R8r4-C11 a readable-but-corrupt gzip archive makes await-state fail closed (corrupt, not none)"

# ── R8r4-C10 - a planted self-consistent high-op DECISION must NOT force rc=7 sequence-exhaustion ────────
# The DECISION high-water validator accepts a grammar-valid self-consistent op with no matching mint. A
# planted `op=999999-x` DECISION (idtag pd-999999-decision-x + body op=999999-x) lifted the history
# high-water to 999999 => next mint 1000000 > 999999 => rc=7 => (S1) STOP forever = total-stall DoS. FIX:
# the MARKER pdseq is authoritative; a HISTORY-driven overflow falls back to the marker. RED if the
# fallback reverts (mint returns rc=7 sequence-exhausted instead of pd:1).
SUBc10="c10poison"; SIDc10="c10poison$$"
mc_new_mission "$SUBc10" "$SIDc10"
mc_decision "$SUBc10" "$SIDc10" "999999-x" approve   # self-consistent idtag pd-999999-decision-x + body op=999999-x
OUTc10=$(mc_pending_stop_out "$SUBc10" "$SIDc10" approve 1 1 1 decision "Approve after a high-op DECISION?")
case "$OUTc10" in *"rc=7"*) mc_fail "R8r4-C10 a planted DECISION op=999999 forced rc=7 (should fall back to the marker)";; *) mc_ok "R8r4-C10 a planted DECISION op=999999 does NOT force rc=7 exhaustion";; esac
mc_has "id=pd:1-approve" "$OUTc10" "R8r4-C10 the mint falls back to the authoritative marker -> pd:1"

# ── R8r4-R10pos (MINOR) - POSITIVE control: a MATCHING structured AWAIT raises the high-water ────────────
# The existing R8r3-R10 only proves a MISMATCHED AWAIT is IGNORED - deleting the AWAIT high-water scan
# entirely would still pass it. This positive control proves the scan actually FIRES: a self-consistent
# AWAIT (idtag op == body op == 5-x) lifts the high-water to 5 so the next mint is pd:6. RED if the AWAIT
# high-water scan is removed (the seed drops to 0 -> pd:1).
SUBr10p="r10pos"; SIDr10p="r10pos$$"
mc_new_mission "$SUBr10p" "$SIDr10p"
LOGr10p="$(mc_log_file "$SUBr10p" "$SIDr10p")"
printf 'm1-await-5-x-r1-a1-g1\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=5-x attempt=1 need=1 got=1 started_at=1\n' >> "$LOGr10p"
IDr10p=$(mc_pending_stop "$SUBr10p" "$SIDr10p" approve 1 1 1 decision "Approve after a matching AWAIT?")
mc_eq "pd:6-approve" "$IDr10p" "R8r4-R10pos a MATCHING structured AWAIT (op=5-x) raises the high-water -> pd:6"

# ── R8r4-S1 (doc) - the pending-stop rc contract classifies EVERY non-zero rc as do-not-proceed ─────────
# The blocking opener's ONLY proceed-able outcome is rc=0; the generic "log + proceed" rule must NOT apply
# to it (rc=7/8/9 previously fell through to proceed = the naked yield). Assert the S1 prose. RED if the
# old block (which omitted rc=7/8/9 and let the generic proceed rule apply) is restored.
S1DOC="$(cat "${HOOKS}/../../commands/mission.md" 2>/dev/null)"
mc_has "ONLY proceed-able outcome" "$S1DOC" "R8r4-S1 pending-stop doc: only rc=0 is proceed-able"
mc_has "EVERY non-zero rc means the STOP did NOT open" "$S1DOC" "R8r4-S1 pending-stop doc: every non-zero rc = do-not-proceed"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# R8r5 (round-8 review ROUND 5) - the action-authorizing cases the prior tests omitted (E7).
# ══════════════════════════════════════════════════════════════════════════════════════════════

# ── R8r6-W1 - the WAKE's last_decision must mirror the FULL reader resolved-predicate (mirror C9) ────────
# CORE-BYPASS: the reader (C9) keeps a pre-opener / conflicting / out-of-order-close barrier LIVE, but the
# WAKE's last_decision derivation (mission.md §12.1) originally classified ANY same-op DECISION as ANSWERED
# (newest-wins) -> the wake executed a stale/forged/corrupt outcome. (a) BEHAVIOR: the reader agrees - a
# DECISION recorded BEFORE the got=0 opener does NOT resolve a forged got=1 (stays LIVE). (b) SOURCE: the
# mission.md last_decision awk now carries the FULL predicate (after-opener AND no-conflict AND before any
# post-opener got=1). RED if either the reader anchoring or the prose predicate reverts. (The behavioural
# agreement of all four consumers on the conflict/out-of-order/torn rows is proven executably by 09.)
SUBe1="e1preopener"; SIDe1="e1preopener$$"
mc_new_mission "$SUBe1" "$SIDe1"
LOGe1="$(mc_log_file "$SUBe1" "$SIDe1")"
{
  printf 'pd-1-decision-approve\t[mission] DECISION op=1-approve outcome=approve\n'                                                                 # DECISION planted FIRST (pre-opener)
  printf 'm1-await-1-approve-r1-a1-g0\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=0 started_at=1\n'  # got=0 opener AFTER the DECISION
  printf 'm1-await-1-approve-r1-a1-g1\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=1 started_at=1\n'  # forged got=1 close
} >> "$LOGe1"
mc_has "await kind=human" "$(mc_state "$SUBe1" "$SIDe1")" "R8r6-W1 a PRE-opener DECISION does NOT resolve the barrier (decnr<openernr -> stays LIVE)"
mc_has "ready=0" "$(mc_state "$SUBe1" "$SIDe1")" "R8r6-W1 the pre-opener-DECISION barrier reports ready=0 (fail-closed)"
E1SRC="$(cat "${HOOKS}/../../commands/mission.md" 2>/dev/null)"
mc_has "dnr>opnr && !conflict && (g1nr<=opnr || dnr<g1nr)" "$E1SRC" "R8r6-W1 the wake's last_decision awk carries the FULL reader resolved-predicate (after-opener + no-conflict + before-got=1)"

# ── R8r5-E2 - C10 fallback must NOT reuse an occupied low op; ignore only out-of-range history ──────────
# marker=0 + a legit op-1 history + a planted op-999999 (out-of-range: +1 overflows). The OLD blanket
# fallback re-minted op=1 (OCCUPIED) = a fail-open stale-approve bypass. FIX: ignore the out-of-range
# op-999999, keep the legit op-1, mint pd:2. RED if the fallback-to-marker+1 (op-1 reuse) reverts.
SUBe2="e2highwater"; SIDe2="e2highwater$$"
mc_new_mission "$SUBe2" "$SIDe2"
LOGe2="$(mc_log_file "$SUBe2" "$SIDe2")"
{
  printf 'pd-1-decision-approve\t[mission] DECISION op=1-approve outcome=approve\n'   # legit in-range op-1 history
  printf 'pd-999999-decision-x\t[mission] DECISION op=999999-x outcome=approve\n'     # planted out-of-range op-999999 (would overflow)
} >> "$LOGe2"
IDe2="$(mc_pending_stop "$SUBe2" "$SIDe2" approve 2 1 1 decision "next?")"
mc_eq "pd:2-approve" "$IDe2" "R8r5-E2 planted op-999999 IGNORED (out-of-range), legit op-1 KEPT -> mint pd:2 (no op-1 reuse, no rc=7)"

# ── R8r5-E3 - two DIFFERENT-outcome DECISIONs for one op = CORRUPTION -> fail-closed (not newest-wins) ──
# A durable deny then a forged approve (raw, same idtag) must NOT flip the barrier to authorized. FIX: the
# reader marks the op conflicted and keeps its barrier LIVE. RED if the conflict check reverts (barrier
# would resolve to none = the forged approve authorizes the denied action).
SUBe3="e3conflict"; SIDe3="e3conflict$$"
mc_new_mission "$SUBe3" "$SIDe3"
mc_pending_stop "$SUBe3" "$SIDe3" deny 1 1 1 decision "Destructive?" >/dev/null   # opener op=1-deny
LOGe3="$(mc_log_file "$SUBe3" "$SIDe3")"
{
  printf 'pd-1-decision-deny\t[mission] DECISION op=1-deny outcome=deny\n'        # durable deny (post-opener)
  printf 'pd-1-decision-deny\t[mission] DECISION op=1-deny outcome=approve\n'     # FORGED conflicting approve (opposite outcome, same op)
  printf 'm1-await-1-deny-r1-a1-g1\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=1-deny attempt=1 need=1 got=1 started_at=1\n'   # got=1 close AFTER both
} >> "$LOGe3"
mc_has "await kind=human" "$(mc_state "$SUBe3" "$SIDe3")" "R8r5-E3 conflicting-outcome DECISIONs keep the barrier LIVE (forged approve does NOT authorize the deny)"
mc_has "ready=0" "$(mc_state "$SUBe3" "$SIDe3")" "R8r5-E3 the conflicting-DECISION barrier reports ready=0 (not authorized)"

# ── R8r5-E4 - a TORN/forged MISSION-CLEARED must NOT clear barriers at the reader (full-grammar anchor) ─
# The reader prefix-matched `^[mission] MISSION-CLEARED`, so a torn line (no status=/reason= tail) hid an
# open human STOP. FIX: full-grammar anchor. RED if the prefix match reverts (torn line clears -> none).
SUBe4="e4torn"; SIDe4="e4torn$$"
mc_new_mission "$SUBe4" "$SIDe4"
mc_pending_stop "$SUBe4" "$SIDe4" approve 1 1 1 decision "Approve?" >/dev/null   # open human STOP op=1-approve
LOGe4="$(mc_log_file "$SUBe4" "$SIDe4")"
printf '\t[mission] MISSION-CLEARED\n' >> "$LOGe4"   # TORN: empty idtag + prefix, NO status=/reason= tail
mc_has "await kind=human" "$(mc_state "$SUBe4" "$SIDe4")" "R8r5-E4 a TORN MISSION-CLEARED (no status=/reason=) does NOT clear the open human STOP"
mc_has "ready=0" "$(mc_state "$SUBe4" "$SIDe4")" "R8r5-E4 the STOP stays LIVE under a torn MISSION-CLEARED"
printf '\t[mission] MISSION-CLEARED status=cleared reason=done\n' >> "$LOGe4"   # positive control: full grammar
mc_eq "none" "$(mc_state "$SUBe4" "$SIDe4")" "R8r5-E4 a FULL-GRAMMAR MISSION-CLEARED still clears (anchor not over-tight)"

# ── R8r5-E8 - a forged unbounded got must NOT hang await-state (range-validate before bor/band) ─────────
# An unbounded got (e.g. 400 nines -> awk `inf`) made the bor/band bit-loop never terminate (reader hang/
# DoS). FIX: range-validate got/need to 0..7 BEFORE bor/band; out-of-range -> corrupt. A portable watchdog
# bounds the call so a REGRESSION fails RED instead of hanging the suite. RED if the range check reverts.
SUBe8="e8bound"; SIDe8="e8bound$$"
mc_new_mission "$SUBe8" "$SIDe8"
mc_pending_stop "$SUBe8" "$SIDe8" approve 1 1 1 decision "Approve?" >/dev/null   # open STOP op=1-approve
LOGe8="$(mc_log_file "$SUBe8" "$SIDe8")"
E8BIG="$(printf '9%.0s' $(seq 1 400))"   # 400-digit got -> awk coerces to inf
printf 'm1-await-1-approve-r1-a1-gX\t[mission] AWAIT part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=%s started_at=1\n' "$E8BIG" >> "$LOGe8"
E8OUT="$(mktemp)"
bash "$MW" await-state "$SIDe8" "${ROOT}/$SUBe8" > "$E8OUT" 2>/dev/null & _e8pid=$!
( sleep 15; kill -9 "$_e8pid" 2>/dev/null ) & _e8killer=$!
wait "$_e8pid" 2>/dev/null; kill "$_e8killer" 2>/dev/null; wait "$_e8killer" 2>/dev/null
E8RES="$(cat "$E8OUT" 2>/dev/null)"; rm -f "$E8OUT"
mc_has "corrupt" "$E8RES" "R8r5-E8 a forged unbounded got is range-rejected -> corrupt (no awk inf hang; watchdog-bounded)"

# ── R8r6-D2/G4/G2 - a CRASHED rebaseline (marker gen bumped, boundary append died) must RECOVER under lock ─
# from the guarded writers, and a FORGED FUTURE-gen boundary must NOT be healed (bounded to the crash sig).
# Setup uses the REAL rebaseline to bump the marker gen (verify-safe), then deletes / forges the boundary line.
# (1) recover via CLEAR (G4: the lock-free _mw_human_barrier_guard pre-check used to refuse rc=4 on the corrupt
#     read BEFORE clear/part-done/rebaseline could reach their under-lock recover -> permanent wedge).
SUBd2="d2clear"; SIDd2="d2clear$$"
mc_new_mission "$SUBd2" "$SIDd2"
bash "$MW" rebaseline "$SIDd2" "${ROOT}/$SUBd2" "rebased plan v2" >/dev/null 2>&1     # REAL gen bump -> marker gen=2 + boundary
LOGd2="$(mc_log_file "$SUBd2" "$SIDd2")"
grep -v 'MISSION-REBASELINED' "$LOGd2" > "${LOGd2}.t" && mv "${LOGd2}.t" "$LOGd2"     # the crash: the boundary append died
mc_eq "corrupt" "$(mc_state "$SUBd2" "$SIDd2")" "R8r6-D2 a crashed rebaseline (marker gen=2, no boundary) reads corrupt (the exact crash signature)"
bash "$MW" log "$SIDd2" "${ROOT}/$SUBd2" "[mission] MISSION-CLEARED status=cleared reason=done" >/dev/null 2>&1
mc_eq "none" "$(mc_state "$SUBd2" "$SIDd2")" "R8r6-D2/G4 clear RECOVERS the crashed rebaseline under lock (reachable — not refused rc=4 at the pre-check) then clears -> none"
mc_has "gen=2 (recovered)" "$(cat "$LOGd2")" "R8r6-D2 the missing gen=2 boundary was healed (recovered) under the clear's lock"
# (2) recover via RESOLVE (its own under-lock recover runs after verify, before the pd strip).
SUBd2r="d2resolve"; SIDd2r="d2resolve$$"
mc_new_mission "$SUBd2r" "$SIDd2r"
bash "$MW" rebaseline "$SIDd2r" "${ROOT}/$SUBd2r" "rebased plan v2" >/dev/null 2>&1
LOGd2r="$(mc_log_file "$SUBd2r" "$SIDd2r")"
grep -v 'MISSION-REBASELINED' "$LOGd2r" > "${LOGd2r}.t" && mv "${LOGd2r}.t" "$LOGd2r"
bash "$MW" resolve "$SIDd2r" "${ROOT}/$SUBd2r" "1-none" >/dev/null 2>&1               # bogus id ok — recover runs first
mc_has "gen=2 (recovered)" "$(cat "$LOGd2r")" "R8r6-D2 resolve's under-lock gen-recover also heals a crashed rebaseline (reachable from all guarded writers)"
# (3) a FORGED FUTURE-gen boundary (marker gen=2, boundary gen=5) is NOT healed — bounded to marker-gen-behind.
SUBd2f="d2forge"; SIDd2f="d2forge$$"
mc_new_mission "$SUBd2f" "$SIDd2f"
bash "$MW" rebaseline "$SIDd2f" "${ROOT}/$SUBd2f" "rebased plan v2" >/dev/null 2>&1   # marker gen=2, boundary gen=2
LOGd2f="$(mc_log_file "$SUBd2f" "$SIDd2f")"
sed 's/status=active gen=2 /status=active gen=5 /' "$LOGd2f" > "${LOGd2f}.t" && mv "${LOGd2f}.t" "$LOGd2f"   # forge a future-gen boundary
CLRd2f="$(bash "$MW" log "$SIDd2f" "${ROOT}/$SUBd2f" "[mission] MISSION-CLEARED status=cleared reason=x" 2>&1)"
mc_has "FAILED rc=4" "$CLRd2f" "R8r6-G2 a FORGED FUTURE-gen boundary is NOT healed (bounded recovery) — clear fails closed rc=4"
mc_eq "0" "$(grep -c 'gen=2 (recovered)' "$LOGd2f" | tr -d ' ')" "R8r6-G2 no recovered gen=2 boundary was appended for the forged future-gen boundary"

# ── R8r6-E2-cap-edge - a REAL occupying barrier at the cap (999999) is COUNTED to the full cap, so the next
# mint reports TRUE exhaustion (rc=7) instead of REUSING the occupied op (a barrier-first crash at the cap).
# A planted op=999999 DECISION with NO barrier stays ignored (round-5 E2, above). RED if the barrier/pd cap
# bound reverts to <=999998 (then 999999 is ignored, seed falls to marker, and a LOW op is minted/reused).
SUBe2c="e2capedge"; SIDe2c="e2capedge$$"
mc_new_mission "$SUBe2c" "$SIDe2c"
LOGe2c="$(mc_log_file "$SUBe2c" "$SIDe2c")"
printf 'm1-await-999999-x-r1-a1-g0\t[mission] AWAIT part=1 phase=build round=1 kind=job op=999999-x attempt=1 need=1 got=0 started_at=1\n' >> "$LOGe2c"   # a REAL AWAIT barrier occupying op=999999
OUTe2c="$(mc_pending_stop_out "$SUBe2c" "$SIDe2c" next 2 1 1 decision "next?")"
mc_has "sequence-exhausted" "$OUTe2c" "R8r6-E2-cap-edge a REAL barrier at op=999999 pushes the seed to the cap -> next mint reports TRUE exhaustion (rc=7), never REUSES 999999"

mc_finish '{"r8r6_w1_wake_full_predicate":"pre-opener DECISION stays LIVE; last_decision awk carries the FULL reader resolved-predicate (after-opener + no-conflict + before-got=1)","r8r6_d2_clear_recover":"crashed rebaseline (marker gen=2, no boundary) reads corrupt; clear recovers under lock -> none + gen=2 (recovered)","r8r6_d2_resolve_recover":"resolve under-lock recover also heals a crashed rebaseline","r8r6_g2_forged_future_not_healed":"a forged future-gen boundary is NOT healed; clear fails closed rc=4","r8r6_e2_capedge_real_barrier":"a real barrier at op=999999 is counted to the cap -> next mint reports true exhaustion, never reuses 999999","r8r5_e2_c10_no_low_reuse":"planted op-999999 ignored, legit op-1 kept -> mint pd:2 (no op-1 reuse)","r8r5_e3_conflict_failclosed":"deny then forged approve keeps the barrier LIVE (not authorized)","r8r5_e4_torn_cleared":"torn MISSION-CLEARED does NOT clear; full-grammar cleared still clears","r8r5_e8_got_range":"forged unbounded got -> corrupt, no hang","r8r5_d3_decision_before_got1":"got=1-before-DECISION stays LIVE; DECISION-before-got=1 resolves","c1a_seed_includes_decision":"preplanted DECISION op=1 -> mint pd:2 (no remint)","c1b_decision_after_opener":"pre-opener DECISION rejected; post-opener allowed","c2_orphan_bind":"different request rc=12 no forge; lost-pd exact re-request rc=14 (unverifiable)","c3_torn_decision":"no outcome= body does not close","c4_toctou":"under-lock rebaseline rc=7 / clear rc=4; STOP survives","i1_question_injection":"newline + leading pd: rejected rc=1","i2_nonblocking_seed":"pending seeds high-water -> pd:5","i3_resolve_grammar":"1-a] victim rejected rc=1","i4_coord_octal":"part=08 idempotent re-request matches via string-compare","i5_redrive_archive":"already-resolved redrive post-rebaseline is quiet ok","i7_retry_question":"changed question rc=13; same question idempotent","i6_seed_poison":"free-text 999999 ignored -> pd:1","i8_budget_residue":"legacy budget file cleared, lockdir reclaimed","r8r2_a_opener":"public await verb refuses human got=0; pending-stop still opens","r8r2_d_cleared":"pending-stop rc=10 below MISSION-CLEARED","r8r2_c_reader":"idtag op != body op does not authorize close","r8r3_r1_env_bypass":"env-inherited _MISSION_INTERNAL_HUMAN_OPEN still refused (FIX A holds)","r8r3_r10_structured_poison":"idtag-present op-mismatched AWAIT+DECISION ignored -> pd:1","r8r3_r11_partdone_wrapper":"mission_partdone_append rc=4 under open STOP (direct wrapper test)","r8r3_r12_partdone_dedup":"idempotent PART-DONE re-emit quiet rc=0 even with STOP open","r8r4_c9_reader_decision_first":"forged got=1 no-DECISION stays LIVE; matching post-opener DECISION resolves; mismatched-idtag DECISION does not","r8r4_c4_op_specific_resolve":"resolve refused rc=9 for the target op even when a different barrier outranks; pd not drained","r8r4_c5c11_corrupt_gzip":"readable-but-corrupt gzip archive -> await-state corrupt not none","r8r4_c10_highwater_bound":"planted DECISION op=999999 falls back to marker -> pd:1 (no rc=7)","r8r4_r10_positive":"matching structured AWAIT op=5-x raises high-water -> pd:6","r8r4_s1_doc":"pending-stop only rc=0 proceeds; every non-zero rc = do-not-proceed"}' \
  "round-8 review fixes: C1a/C1b stale-approve + C2 orphan-bind(rc12/rc14) + C3 torn-decision + C4 rebaseline/clear TOCTOU + I1 question-injection + I2 non-blocking-seed + I3 resolve-grammar + I4 coord-octal + I6 seed-poison + I8 legacy-budget-residue + R8r3 R1-env-bypass/R10-structured-poison/R11-partdone-wrapper/R12-partdone-dedup + R8r4 C9-reader-decision-first/C4-op-specific-resolve/C5-C11-corrupt-gzip/C10-highwater-bound/R10-positive/S1-doc"
