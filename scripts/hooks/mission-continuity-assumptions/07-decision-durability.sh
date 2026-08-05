#!/usr/bin/env bash
# 07 - decision-durability: the round-8 pending-STOP barrier lifecycle end to end - the ONE mechanism that
# makes an unanswered mandatory human decision un-loseable and un-erasable. Where case 02 pins the AWAIT
# reader's state table, THIS case pins the WRITE path that opens, seeds, closes, resolves, and adopts a
# human STOP: the atomic `pending-stop` mint, the DECISION-first close gate, the strict `resolve` drain,
# the monotonic seq counter (pdseq) high-water, and the crash-orphan adopt.
#
# Load-bearing because every failure here is SILENT and SAFETY-critical. A mint that reuses a seq collides
# two decisions into one idtag and drops the second STOP. A close that clears the barrier WITHOUT a durable
# recorded outcome lets an approve/deny vanish (the wake has nothing to obey). A seed that mis-scans lets a
# fresh mint reuse a live seq across an upgrade boundary. A resolve that strips the wrong / a phantom line,
# or that reports success on a never-existed id, corrupts the pending ledger. An orphan (barrier live, pd
# line lost to a crash) that a re-open does NOT adopt opens a SECOND invisible barrier. Each is a green tick
# over a dropped or forged human approval - the exact class the STOP exists to prevent.
#
# NEGATIVE CONTROL: revert D14 (the lib DECISION-first gate) - D6a then closes a human barrier with a bare
# got=1 and no DECISION, so `state==none` where `live` is expected, RED. Revert D10 (reader) - a human
# barrier is superseded (covered in 02). Revert D5/D16/D6b/D3/D4 individually and the matching leg goes RED
# (each is a distinct mission root, so one revert reddens one assertion, not the whole file).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "07-decision-durability"

# ── D1 - resolve DRAINS both the echoed `pd:1-approve` and the bare `1-approve` id (R8-16) ──────────────
# The mint ECHOES `pd:<seq>-<slug>` but the AWAIT op is the bare `<seq>-<slug>`, so a caller passes EITHER;
# both must strip the same pd line. Separate missions so each drain is independent. RED if the optional
# `pd:` strip reverts (the bare form would then never match -> `already`/`never-existed`, no drain).
# R8r3-R5: resolve now REFUSES to drain while the same-op human STOP is still OPEN (got=0), so we CLOSE the
# barrier (DECISION -> got=1, via mc_close_human) FIRST - the sanctioned order DECISION -> got=1 -> resolve.
SUBd1="drainecho"; SIDd1="drainecho$$"
mc_new_mission "$SUBd1" "$SIDd1"
IDd1=$(mc_pending_stop "$SUBd1" "$SIDd1" approve 1 1 1 decision "Approve A?")
mc_eq "pd:1-approve" "$IDd1" "D1 pending-stop mints pd:1-approve"
mc_eq "1" "$(mc_has_pd "$SUBd1" "$SIDd1" pd:1-approve)" "D1 pd line present before drain"
mc_close_human "$SUBd1" "$SIDd1" "1-approve" approve 1 1 1 decision   # DECISION -> got=1 (close) BEFORE resolve
RESd1=$(mc_resolve_out "$SUBd1" "$SIDd1" "pd:1-approve" approved)
mc_has "resolve ok" "$RESd1" "D1 resolve of the ECHOED form 'pd:1-approve' succeeds"
mc_eq "0" "$(mc_has_pd "$SUBd1" "$SIDd1" pd:1-approve)" "D1 the pd line is actually DRAINED (echoed form)"

SUBd1b="drainbare"; SIDd1b="drainbare$$"
mc_new_mission "$SUBd1b" "$SIDd1b"
mc_pending_stop "$SUBd1b" "$SIDd1b" approve 1 1 1 decision "Approve B?" >/dev/null
mc_close_human "$SUBd1b" "$SIDd1b" "1-approve" approve 1 1 1 decision   # close (DECISION -> got=1) BEFORE resolve
RESd1b=$(mc_resolve_out "$SUBd1b" "$SIDd1b" "1-approve" approved)   # BARE form (no pd:)
mc_has "resolve ok" "$RESd1b" "D1 resolve of the BARE form '1-approve' succeeds"
mc_eq "0" "$(mc_has_pd "$SUBd1b" "$SIDd1b" pd:1-approve)" "D1 the pd line is actually DRAINED (bare form)"

# ── D1r5 (R8r3-R5) - resolve is REFUSED while the SAME-op human STOP is still OPEN (got=0) ───────────────
# Draining the pd line BEFORE a DECISION+got=1 close would create the forbidden pd-missing + ready=0 orphan
# that FIX B refuses to re-open (permanent stall). So resolve fails LOUD (rc=9) until the barrier is closed,
# and the pd line + the live STOP both survive. Closing first (mc_close_human) then lets the resolve drain.
# RED if the open-human-barrier refusal in mission_resolve_pending reverts (the bare drain would succeed).
SUBd1r="resbeforeclose"; SIDd1r="resbeforeclose$$"
mc_new_mission "$SUBd1r" "$SIDd1r"
mc_pending_stop "$SUBd1r" "$SIDd1r" approve 1 1 1 decision "Approve before close?" >/dev/null
RESd1r=$(mc_resolve_out "$SUBd1r" "$SIDd1r" "pd:1-approve" approved)
mc_has "FAILED rc=9" "$RESd1r" "D1r5 resolve BEFORE the got=1 close is REFUSED (rc=9, open human STOP)"
mc_eq "1" "$(mc_has_pd "$SUBd1r" "$SIDd1r" pd:1-approve)" "D1r5 the pd line is NOT drained by the refused resolve"
mc_has "await kind=human" "$(mc_state "$SUBd1r" "$SIDd1r")" "D1r5 the open human STOP survives the refused resolve"
mc_close_human "$SUBd1r" "$SIDd1r" "1-approve" approve 1 1 1 decision   # now close it (DECISION -> got=1)
RESd1r2=$(mc_resolve_out "$SUBd1r" "$SIDd1r" "pd:1-approve" approved)
mc_has "resolve ok" "$RESd1r2" "D1r5 resolve SUCCEEDS once the barrier is closed (sanctioned order)"

# ── D2 - resolve fail-loud vs quiet-ok vs mismatched-op (R8-17) ─────────────────────────────────────────
# never-existed => LOUD (FAILED rc=8); an idempotent re-drive of an already-resolved id => QUIET OK; a
# mismatched op (an id that never had a pd line) => the never-existed loud path, and the REAL pd line
# survives untouched. RED if resolve returns a phantom `ok` on a never-existed id, or fails on a redrive.
SUBd2="resolvefault"; SIDd2="resolvefault$$"
mc_new_mission "$SUBd2" "$SIDd2"
mc_pending_stop "$SUBd2" "$SIDd2" approve 1 1 1 decision "Approve?" >/dev/null
RESd2a=$(mc_resolve_out "$SUBd2" "$SIDd2" "pd:2-other" x)          # never existed
mc_has "FAILED rc=8" "$RESd2a" "D2 resolve of a never-existed id fails LOUD (rc=8)"
mc_has "never existed" "$RESd2a" "D2 the loud refusal names 'never existed'"
mc_eq "1" "$(mc_has_pd "$SUBd2" "$SIDd2" pd:1-approve)" "D2 the mismatched-op resolve leaves the REAL pd line intact"
mc_close_human "$SUBd2" "$SIDd2" "1-approve" approve 1 1 1 decision   # R8r3-R5: close (DECISION -> got=1) BEFORE the real drain
mc_resolve_out "$SUBd2" "$SIDd2" "pd:1-approve" ok >/dev/null      # real drain
RESd2b=$(mc_resolve_out "$SUBd2" "$SIDd2" "pd:1-approve" ok)       # idempotent redrive
mc_has "resolve ok" "$RESd2b" "D2 an idempotent re-drive of an already-resolved id is QUIET OK"
mc_has "already resolved" "$RESd2b" "D2 the redrive names 'already resolved' (idempotent no-op)"

# ── D3 - legacy seed-from-max: the R8-3 upgrade-boundary bypass fix ─────────────────────────────────────
# A mission whose marker still reads pdseq=0 (pre-R8 upgrade) but whose HISTORY holds a higher seq must
# seed the next mint ABOVE that history, never from the stale marker. Two independent anchors:
#   (a) the LOG anchor - a `resolved pd:5-x` narrative on a `resolve-<id>` idtag line.
#   (b) the MD-zone anchor - a `- [pd:5-legacy]` line in the live PENDING DECISIONS zone.
# Either alone must lift the next mint to 6. RED if the seed drops back to the marker (mints pd:1 - a
# LIVE-seq REUSE that would collide a fresh decision onto an existing one).
SUBd3="seedlog"; SIDd3="seedlog$$"
mc_new_mission "$SUBd3" "$SIDd3"
bash "$MW" log "$SIDd3" "${ROOT}/${SUBd3}" "resolved pd:5-x — legacy history" "resolve-5-x" >/dev/null 2>&1
IDd3=$(mc_pending_stop "$SUBd3" "$SIDd3" newq 1 1 1 decision "Next after legacy log?")
mc_eq "pd:6-newq" "$IDd3" "D3 marker pdseq=0 + log 'resolved pd:5-x' => next mint is pd:6 (log anchor, not 1)"

SUBd3b="seedmd"; SIDd3b="seedmd$$"
mc_new_mission "$SUBd3b" "$SIDd3b"
MDd3b="${ROOT}/${SUBd3b}/MISSION.${SIDd3b}.md"
# inject a leftover pd line directly into the live PENDING DECISIONS zone (plan_hash covers only PLAN, so
# a PENDING-zone edit still verifies) - simulates a pre-R8 mission whose marker was never counter-bumped.
perl -0pi -e 's{(<!-- MZONE:PENDING DECISIONS n=\w+ -->\n)}{$1- [pd:5-legacy] leftover from before the upgrade\n}' "$MDd3b"
IDd3b=$(mc_pending_stop "$SUBd3b" "$SIDd3b" newq 1 1 1 decision "Next after legacy md?")
mc_eq "pd:6-newq" "$IDd3b" "D3 marker pdseq=0 + md '[pd:5-legacy]' => next mint is pd:6 (md-zone anchor, not 1)"

# ── D4 - pdseq is a monotonic high-water: PRESERVED across note/challenge/resolve/rebaseline/gen-bump ───
# The counter must never regress on an unrelated re-emit; a reset would re-mint a seq already handed out.
SUBd4="pdseqkeep"; SIDd4="pdseqkeep$$"
mc_new_mission "$SUBd4" "$SIDd4"
MDd4="${ROOT}/${SUBd4}/MISSION.${SIDd4}.md"
mc_pending_stop "$SUBd4" "$SIDd4" approve 1 1 1 decision "Approve?" >/dev/null
mc_eq "1" "$(sed -n 's/.*pdseq=\([0-9][0-9]*\).*/\1/p' "$MDd4" | tail -1)" "D4 pdseq=1 after the mint"
bash "$MW" note "$SIDd4" "${ROOT}/${SUBd4}" "a durable note" >/dev/null 2>&1
bash "$MW" challenge "$SIDd4" "${ROOT}/${SUBd4}" "a plan challenge" >/dev/null 2>&1
mc_eq "1" "$(sed -n 's/.*pdseq=\([0-9][0-9]*\).*/\1/p' "$MDd4" | tail -1)" "D4 pdseq preserved across note + challenge"
mc_close_human "$SUBd4" "$SIDd4" "1-approve" approve 1 1 1 decision
mc_resolve "$SUBd4" "$SIDd4" "pd:1-approve" ok
mc_eq "1" "$(sed -n 's/.*pdseq=\([0-9][0-9]*\).*/\1/p' "$MDd4" | tail -1)" "D4 pdseq preserved across resolve"
bash "$MW" rebaseline "$SIDd4" "${ROOT}/${SUBd4}" "a fresh rebaselined plan" >/dev/null 2>&1
mc_eq "2" "$(sed -n 's/.*gen=\([0-9][0-9]*\).*/\1/p' "$MDd4" | tail -1)" "D4 rebaseline bumped gen to 2"
mc_eq "1" "$(sed -n 's/.*pdseq=\([0-9][0-9]*\).*/\1/p' "$MDd4" | tail -1)" "D4 pdseq SURVIVES the gen boundary (monotonic, not reset)"

# ── D5 - crash-orphan FAIL-CLOSED (barrier live, pd line lost) [R8r2-B] ──────────────────────────────────
# A crash BETWEEN the barrier-first AWAIT and the pd-line write leaves a live got=0 human barrier whose op
# has NO pd line. The ORIGINAL question is GONE with the pd line, so a re-`pending-stop` for the SAME
# slug/coords CANNOT prove the supplied question equals the lost one - a silent ADOPT would rebind a
# possibly-DIFFERENT question to the mandatory STOP (approval-binding bug). So it FAILS CLOSED: no adopt,
# no re-mint, pd line stays absent, the barrier stays live for an explicit resolve/deny. R8r3-R8: the
# orphan class is the DISTINCT rc=14 (non-retryable), not the conflated rc=3. RED if the fail-closed reverts.
SUBd5="orphan"; SIDd5="orphan$$"
mc_new_mission "$SUBd5" "$SIDd5"
mc_pending_stop "$SUBd5" "$SIDd5" approve 1 1 1 decision "Approve?" >/dev/null
MDd5="${ROOT}/${SUBd5}/MISSION.${SIDd5}.md"
# crash sim: strip the pd line + its paired mid marker, leaving the AWAIT barrier live (orphaned).
perl -0pi -e 's/^- \[pd:1-approve\][^\n]*\n(<!-- mid:[^\n]*-->\n)?//m' "$MDd5"
mc_eq "0" "$(mc_has_pd "$SUBd5" "$SIDd5" pd:1-approve)" "D5 pd line gone after the crash sim (orphaned barrier)"
mc_has "await kind=human" "$(mc_state "$SUBd5" "$SIDd5")" "D5 the human barrier is still live (crash orphan)"
OUTd5=$(mc_pending_stop_out "$SUBd5" "$SIDd5" approve 1 1 1 decision "A DIFFERENT question?")
mc_has "rc=3" "$OUTd5" "D5 re-pending-stop on a lost-pd orphan FAILS CLOSED (rc=3, question unverifiable)"
mc_eq "0" "$(mc_has_pd "$SUBd5" "$SIDd5" pd:1-approve)" "D5 the pd line is NOT restored (no silent adopt of a possibly-changed question)"
mc_has "await kind=human" "$(mc_state "$SUBd5" "$SIDd5")" "D5 the orphan barrier stays live for an explicit resolve/deny"
mc_eq "1" "$(sed -n 's/.*pdseq=\([0-9][0-9]*\).*/\1/p' "$MDd5" | tail -1)" "D5 marker pdseq stays the high-water (1, not re-minted)"

# ── D6 - DECISION-first close, lib-enforced (R8-14); deny durability read-side (R8-8) ───────────────────
# (a) a human got=1 close with NO same-op DECISION is REFUSED at the mechanism (not just prose); the barrier
# stays LIVE. Assert the refusal message AND the surviving barrier. RED if the lib gate reverts.
SUBd6="decfirst"; SIDd6="decfirst$$"
mc_new_mission "$SUBd6" "$SIDd6"
mc_pending_stop "$SUBd6" "$SIDd6" approve 1 1 1 decision "Approve?" >/dev/null
OUTd6=$(mc_await_out "$SUBd6" "$SIDd6" "part=1 phase=decision round=1 kind=human op=1-approve attempt=1 need=1 got=1")
mc_has "DECISION-first" "$OUTd6" "D6a a human got=1 close with NO DECISION is REFUSED (DECISION-first, lib-enforced)"
mc_has "await kind=human" "$(mc_state "$SUBd6" "$SIDd6")" "D6a the barrier STAYS live after the refused close"
# (b) a DECISION=deny WITHOUT a got=1 close reads LIVE (the STOP still holds - the machine records the
# outcome but the barrier is answered-not-closed until got=1). The deny outcome is DURABLE in the log and
# SURVIVES a later unrelated append (durability, not prose obedience - the accepted residual).
mc_decision "$SUBd6" "$SIDd6" "1-approve" deny
mc_has "await kind=human" "$(mc_state "$SUBd6" "$SIDd6")" "D6b DECISION=deny without got=1 still reads LIVE (barrier holds)"
mc_eq "1" "$(grep -c 'DECISION op=1-approve outcome=deny' "$(mc_log_file "$SUBd6" "$SIDd6")")" "D6b the deny DECISION is durably recorded in the log"
bash "$MW" note "$SIDd6" "${ROOT}/${SUBd6}" "an unrelated later note" >/dev/null 2>&1
mc_eq "1" "$(grep -c 'DECISION op=1-approve outcome=deny' "$(mc_log_file "$SUBd6" "$SIDd6")")" "D6b the deny DECISION SURVIVES a later append (durable)"

# ── D7 - fail-closed refusals BEFORE any barrier opens (R8: D3/D6/D6b) ──────────────────────────────────
# second-open: a DIFFERENT human STOP while one is open is REFUSED (rc=3) - a second invisible barrier is
# never opened. slug>64, an assembled AWAIT line >=480B, and a sequence-exhausted (>999999) each fail
# CLOSED (no barrier, no pd line, state stays as it was). RED if any preflight is dropped.
SUBd7="secondopen"; SIDd7="secondopen$$"
mc_new_mission "$SUBd7" "$SIDd7"
mc_pending_stop "$SUBd7" "$SIDd7" approve 1 1 1 decision "First?" >/dev/null
OUTd7=$(mc_pending_stop_out "$SUBd7" "$SIDd7" credwrite 2 1 1 decision "Second?")
mc_has "rc=3" "$OUTd7" "D7 a DIFFERENT open human STOP is REFUSED (rc=3, no second barrier)"
mc_has "op=1-approve" "$(mc_state "$SUBd7" "$SIDd7")" "D7 the ORIGINAL barrier is still the single live STOP"

SUBd7b="slugcap"; SIDd7b="slugcap$$"
mc_new_mission "$SUBd7b" "$SIDd7b"
LONGSLUG=$(printf 'a%.0s' $(seq 1 65))   # 65 chars > the 64 cap
OUTd7b=$(mc_pending_stop_out "$SUBd7b" "$SIDd7b" "$LONGSLUG" 1 1 1 decision "Q?")
mc_has "rc=1" "$OUTd7b" "D7 a slug > 64 chars is REFUSED (rc=1)"
mc_eq "none" "$(mc_state "$SUBd7b" "$SIDd7b")" "D7 no barrier opened for the over-long slug"

SUBd7c="linecap"; SIDd7c="linecap$$"
mc_new_mission "$SUBd7c" "$SIDd7c"
LONGPHASE=$(printf 'a%.0s' $(seq 1 480))   # a 480-char phase blows the 480B AWAIT-line budget
OUTd7c=$(mc_pending_stop_out "$SUBd7c" "$SIDd7c" approve 1 1 1 "$LONGPHASE" "Q?")
mc_has "rc=8" "$OUTd7c" "D7 an assembled AWAIT line >= 480B is REFUSED (rc=8)"
mc_eq "none" "$(mc_state "$SUBd7c" "$SIDd7c")" "D7 no barrier opened for the over-long line"

SUBd7d="seqexhaust"; SIDd7d="seqexhaust$$"
mc_new_mission "$SUBd7d" "$SIDd7d"
MDd7d="${ROOT}/${SUBd7d}/MISSION.${SIDd7d}.md"
perl -pi -e 's/pdseq=0/pdseq=999999/' "$MDd7d"   # next would be 1000000 (7 digits)
OUTd7d=$(mc_pending_stop_out "$SUBd7d" "$SIDd7d" toobig 1 1 1 decision "Q?")
mc_has "rc=7" "$OUTd7d" "D7 sequence-exhausted (next > 999999) is REFUSED BEFORE the barrier (rc=7)"
mc_eq "none" "$(mc_state "$SUBd7d" "$SIDd7d")" "D7 no barrier opened when the sequence is exhausted"

# ── D8 - non-land fault injection (R8-9 barrier-first fail-closed) ──────────────────────────────────────
# Pre-seed the LOG with the EXACT idtag the fresh mint (seq=1) will emit for its human AWAIT, but a NON-AWAIT
# body (so the seed scan ignores it -> seed stays 0 -> next=1 -> the SAME idtag). The collision decoy has no
# valid AWAIT, so orphan-adopt does NOT fire (await-state is `none`). The fresh mint's AWAIT append then
# collides on the idtag => `_MLA_OUTCOME=collision` => fail closed: NO pd line, NO echo (rc=9). RED if the
# barrier-first outcome check is dropped (the mint would echo an id while the AWAIT silently never landed).
SUBd8="nonland"; SIDd8="nonland$$"
mc_new_mission "$SUBd8" "$SIDd8"
printf 'm1-await-1-approve-r1-a1-g0\t[mission] note collision-decoy\n' >> "$(mc_log_file "$SUBd8" "$SIDd8")"
mc_eq "none" "$(mc_state "$SUBd8" "$SIDd8")" "D8 the decoy is not a valid AWAIT (state none; orphan-adopt cannot fire)"
OUTd8=$(mc_pending_stop_out "$SUBd8" "$SIDd8" approve 1 1 1 decision "Approve?")
mc_has "rc=9" "$OUTd8" "D8 the fresh mint FAILS CLOSED on the AWAIT-idtag collision (non-land, rc=9)"
mc_eq "0" "$(mc_has_pd "$SUBd8" "$SIDd8" pd:1-approve)" "D8 no pd line minted on the non-land (no forged decision)"

# ── D9 - R8-6 SPINLOCK clamp for the god-review codex-lock consumer (hermetic; NO codex run) ────────────
# The `_SPIN_RAISE` env-clamp in commands/god-review/lib/codex-invoke.sh must CLAMP an out-of-range
# SPINLOCK_TIMEOUT_SEC to 0 (fall back to the flat 21660s floor), NEVER let e.g. 999999 (~11.6 days) inflate
# the stale-lock threshold. We EXTRACT the real `_SPIN_RAISE=0 ... esac` block from the source and eval it
# with env inputs - behavioral, not a grep, and hermetic (the block touches no lock, no codex). RED if the
# numeric `[1,21600]` range check reverts to the old length-only `-le 6` gate (999999 would then raise).
# (DEFERRED per D21: the ui-audit + master-review clamps - pre-existing review-tooling debt, not round-7.)
CIVK="$(cd "${HOOKS}/../.." && pwd -P)/commands/god-review/lib/codex-invoke.sh"
if [ -f "$CIVK" ]; then
  SPINBLK=$(awk '/^_SPIN_RAISE=0$/{c=1} c{print} c&&/^esac$/{exit}' "$CIVK")
  if [ -n "$SPINBLK" ]; then
    R999=$( SPINLOCK_TIMEOUT_SEC=999999; eval "$SPINBLK"; printf '%s' "$_SPIN_RAISE" )
    mc_eq "0" "$R999" "D9 SPINLOCK_TIMEOUT_SEC=999999 CLAMPS to 0 (<=21600 floor holds; no 11.6-day inflation)"
    R3600=$( SPINLOCK_TIMEOUT_SEC=3600; eval "$SPINBLK"; printf '%s' "$_SPIN_RAISE" )
    mc_eq "3600" "$R3600" "D9 an in-range SPINLOCK_TIMEOUT_SEC=3600 is honoured (raise allowed within [1,21600])"
    ROVER=$( SPINLOCK_TIMEOUT_SEC=21601; eval "$SPINBLK"; printf '%s' "$_SPIN_RAISE" )
    mc_eq "0" "$ROVER" "D9 SPINLOCK_TIMEOUT_SEC=21601 (just over the cap) CLAMPS to 0"
  else
    mc_fail "D9 could not extract the _SPIN_RAISE clamp block from codex-invoke.sh"
  fi
else
  mc_fail "D9 codex-invoke.sh not found at ${CIVK}"
fi

mc_finish '{"resolve_drain_both_forms":"pd:1-approve + 1-approve both drain the pd line","resolve_fault":"never-existed rc=8 loud; redrive quiet ok; mismatched-op leaves real line","legacy_seed_from_max":"marker pdseq=0 + log/md seq5 => next mint pd:6","pdseq_preserve":"1 across note/challenge/resolve/gen-bump","orphan_adopt":"same seq re-minted, pd line restored, one live STOP","decision_first":"got=1 w/o DECISION REFUSED + barrier live","deny_durability":"deny read-live + durable in log across appends","second_open_refused":"rc=3, original STOP stays single","slug_cap":"rc=1 no barrier","line_cap":"rc=8 no barrier","seq_exhausted":"rc=7 before barrier","non_land_collision":"rc=9 no pd line no echo","spinlock_clamp":"999999->0, 3600->3600, 21601->0"}' \
  "pending-STOP lifecycle: resolve-drain(both forms) + resolve-fault(loud/quiet/mismatch) + legacy-seed-from-max(log+md) + pdseq-preserve + orphan-adopt + DECISION-first + deny-durability + second-open/slug/line/seq refusals + non-land-collision + R8-6 SPINLOCK clamp"
