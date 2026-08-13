#!/usr/bin/env bash
# test-mission-liveness.sh — regression harness for mission-liveness.sh (the Stop-hook naked-yield guard)
#
# Emits a final `PASS: N  FAIL: M` line, matching test-mission-bridge.sh, and exits nonzero on any FAIL.
#
# HOUSE RULE THIS HARNESS OBEYS (scripts/hooks/mission-bridge-assumptions/README.md): every assertion
# carries an explicit NEGATIVE CONTROL. A green here is only meaningful because the detector is
# demonstrably able to go red — so for every "stays silent" case there is a paired "and it DOES fire
# when the guarded condition is genuinely present".
#
# The hook's failure posture is asymmetric on purpose: a spurious block interrupts a human, a missed
# block costs one wake. Most tests below therefore prove SILENCE, and exactly one proves the block.
#
# Hermetic: per-test temp roots under $TMPDIR, per-test sids namespaced by UNIQ, all state removed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOOK="$ROOT/mission-liveness.sh"
MWSH="$ROOT/mission-write.sh"
. "$ROOT/lib/auto-compact-sentinel.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "${2:-}"; }

UNIQ="tml-$$-$(date +%s)"
WORKBASE="${TMPDIR:-/tmp}/${UNIQ}"
mkdir -p "$WORKBASE"
STATE_DIR="$HOME/.claude/progress/mission-liveness"
# Hermeticity: never write the user's real diagnostic log from a test run.
ML_LOG_UNDER_TEST="$WORKBASE/mission-liveness.log"
export MISSION_LIVENESS_LOG="$ML_LOG_UNDER_TEST"

CREATED_SIDS=()
cleanup() {
  for s in ${CREATED_SIDS+"${CREATED_SIDS[@]}"}; do
    rm -f "$HOME/.claude/progress/mission-liveness-$s.json" \
          "$HOME/.claude/chains/$s.json" "$HOME/.claude/chains/$s.log" \
          "$(ac_sentinel_path "$s")" 2>/dev/null
    rm -f "$STATE_DIR/$s".* 2>/dev/null
  done
  rm -rf "$WORKBASE" 2>/dev/null
}
trap cleanup EXIT

fresh_root() { d="$WORKBASE/$1"; mkdir -p "$d"; printf '%s' "$d"; }

arm() {  # arm <sid> <root>
  CREATED_SIDS+=("$1")
  mkdir -p "$HOME/.claude/progress" 2>/dev/null
  printf '{"sid":"%s","root":"%s"}' "$1" "$2" > "$HOME/.claude/progress/mission-liveness-$1.json"
}

# Build a transcript in the REAL shape. This matters more than any assertion in this file: the first
# version of these fixtures ended each turn directly at the ScheduleWakeup tool_use, which is a shape
# the runtime NEVER produces. The parser was broken for real transcripts and the harness was green
# anyway. In reality a tool RESULT is a `user` record, so a healthy wake turn looks like:
#     user(prompt) -> assistant(tool_use) -> user(tool_result) -> assistant(tool_use)
#                  -> user(tool_result) -> assistant(text)
# and the boundary prompt carries the sid (it is the self-contained tick prompt /mission authored).
# Modes: with | without | failed | human   (human = a real user prompt, no sid)
mk_transcript() {  # mk_transcript <path> <mode> <sid>
  p="$1"; mode="$2"; s="${3:-}"
  {
    if [ "$mode" = human ]; then
      printf '%s\n' '{"type":"user","message":{"role":"user","content":"hey can you explain what you just did"}}'
    else
      printf '{"type":"user","message":{"role":"user","content":"MISSION TICK sid=%s run section 12.1 of the playbook"}}\n' "$s"
    fi
    case "$mode" in
      with|failed)
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_sw","name":"ScheduleWakeup","input":{"delaySeconds":60}}]}}'
        if [ "$mode" = failed ]; then
          printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_sw","is_error":true,"content":"schedule failed"}]}}'
        else
          printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_sw","content":"scheduled"}]}}'
        fi
        # the lock release that section 12.1 mandates AFTER the schedule, plus a closing message -
        # this is the tail that broke the original parser
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_rl","name":"Bash","input":{"command":"rmdir tick.lock"}}]}}'
        printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_rl","content":"ok"}]}}'
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Banked the round; next wake booked."}]}}'
        ;;
      *)
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_c","name":"Bash","input":{"command":"git commit"}}]}}'
        printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_c","content":"[main abc123] done"}]}}'
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Committed. That is commit 4 landed."}]}}'
        ;;
    esac
  } > "$p"
}

run_hook() {  # run_hook <sid> <prompt_id> <transcript> -> sets RC / OUT
  OUT=$(printf '{"session_id":"%s","prompt_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' \
        "$1" "$2" "$3" | bash "$HOOK" 2>&1)
  RC=$?
}

# A mission with work owed: created, a PART-START banked, no lifecycle close, no human barrier.
mk_live_mission() {  # mk_live_mission <sid> <root>
  bash "$MWSH" create "$1" "$2" "MISSION MODE: build — liveness harness" >/dev/null 2>&1
  bash "$MWSH" log "$1" "$2" "[mission] PART-START part=1 name=x" "m1-part-start" >/dev/null 2>&1
}

printf '\n== mission-liveness: naked-yield guard ==\n\n'

# === 1 — THE POSITIVE CASE. Armed, work owed, no ScheduleWakeup in the turn => BLOCK (exit 2).
# This is the whole reason the hook exists; every other test proves it stays out of the way.
SID="$UNIQ-block"; R=$(fresh_root block)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "2" ] && printf '%s' "$OUT" | grep -q 'NAKED YIELD BLOCKED'; then
  pass "armed + work owed + no ScheduleWakeup => exit 2 with a continue instruction"
else
  fail "naked yield must block" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 2 — NEGATIVE CONTROL for #1: identical state, but the turn DID call ScheduleWakeup.
# If this also blocked, test 1 would be proving nothing but "the hook always fires".
SID="$UNIQ-booked"; R=$(fresh_root booked)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" with "$SID"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "same state but ScheduleWakeup present => silent (the detector discriminates)"
else
  fail "booked wake must be silent" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 3 — Unarmed session is never touched. Without this the hook would fire on every turn end of
# every session on the machine, including sibling windows in the same repo and live human chat.
SID="$UNIQ-unarmed"; R=$(fresh_root unarmed); CREATED_SIDS+=("$SID")
mk_live_mission "$SID" "$R"
# mission-write.sh now arms on any bridge write (that is the point of test 18), so an unarmed session
# has to be made unarmed deliberately. Assert the removal landed - otherwise this test would silently
# become a duplicate of test 1 and stop covering the unarmed path at all.
rm -f "$HOME/.claude/progress/mission-liveness-$SID.json"
[ -f "$HOME/.claude/progress/mission-liveness-$SID.json" ] && fail "unarmed fixture" "could not disarm"
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "unarmed session => silent even with a naked yield in view"
else
  fail "unarmed must be silent" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 4 — Yields to the auto-compact chain. Blocking a stop mid-compaction perturbs the PTY window
# that auto-compact-after-pre-compact.sh:258-267 documents as timing-fragile (a 27-minute freeze).
SID="$UNIQ-ac"; R=$(fresh_root ac)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
mkdir -p "$(dirname "$(ac_sentinel_path "$SID")")" 2>/dev/null
printf '{}' > "$(ac_sentinel_path "$SID")"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "auto-compact armed => silent (yields to the compaction chain)"
else
  fail "must yield to auto-compact" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi
rm -f "$(ac_sentinel_path "$SID")"

# === 5 — Blocks a given prompt AT MOST ONCE. stop_hook_active is undocumented in 2.1.229, so
# prompt_id is the loop bound; without it a stubborn turn traps the session in a block loop.
SID="$UNIQ-once"; R=$(fresh_root once)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
run_hook "$SID" "pX" "$T"; FIRST=$RC
run_hook "$SID" "pX" "$T"; SECOND=$RC
if [ "$FIRST" = "2" ] && [ "$SECOND" = "0" ]; then
  pass "same prompt_id blocks once then goes silent (no block loop)"
else
  fail "prompt_id loop bound" "first=$FIRST second=$SECOND"
fi

# === 6 — An unreadable/absent transcript must NEVER block. The docs warn transcript_path may lag;
# treating missing evidence as a naked yield would block constantly on a slow flush.
SID="$UNIQ-notx"; R=$(fresh_root notx)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
run_hook "$SID" "p1" "$R/does-not-exist.jsonl"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "unreadable transcript => silent (never block on absent evidence)"
else
  fail "missing transcript must be silent" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 7 — A transcript with no assistant turn at all is inconclusive, not a naked yield.
SID="$UNIQ-inconc"; R=$(fresh_root inconc)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$T"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "no assistant turn in transcript => inconclusive => silent"
else
  fail "inconclusive transcript must be silent" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 8 — A CLEARED mission is a sanctioned stop. Nagging a finished run is a false positive.
SID="$UNIQ-cleared"; R=$(fresh_root cleared)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
bash "$MWSH" log "$SID" "$R" "[mission] MISSION-CLEARED status=achieved reason=done" "" >/dev/null 2>&1
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "MISSION-CLEARED => silent (sanctioned stop)"
else
  fail "cleared mission must be silent" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 9 — An open human park is a sanctioned stop: the run is WAITING on the user, by design.
SID="$UNIQ-park"; R=$(fresh_root park)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
# Signature is `pending-stop <sid> <root> <slug> <part> <round> <attempt> <phase> <question...>`.
# Assert the barrier actually opened before asserting the hook's reaction to it — an unopened barrier
# made this test a FALSE GREEN in the first run (it was passing on an unrelated early exit).
PS=$(bash "$MWSH" pending-stop "$SID" "$R" "approve-thing" 1 1 1 review "May I do the thing?" 2>&1)
AW=$(bash "$MWSH" await-state "$SID" "$R" 2>/dev/null)
case "$AW" in
  await*kind=human*) : ;;
  *) fail "human park fixture" "barrier did not open: pending-stop='$PS' await='$AW'" ;;
esac
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "open human STOP barrier => silent (parked on the user, not frozen)"
else
  fail "human park must be silent" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 10 — Never adopts another session's mission. Several windows routinely share a repo root; the
# root comes from THIS sid's arming sentinel and the mission is resolved by sid, never by cwd.
SID="$UNIQ-own"; OTHER="$UNIQ-other"; R=$(fresh_root shared)
mk_live_mission "$OTHER" "$R"; CREATED_SIDS+=("$OTHER")
arm "$SID" "$R"                       # armed, but THIS sid has no mission of its own in that root
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "another sid's mission under a shared root is never adopted"
else
  fail "must not adopt a foreign mission" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 11 — THE UNBOUNDED-LOOP REGRESSION. With no prompt_id in the payload the original code never
# wrote its attempt marker, so the loop bound never tripped and the hook blocked EVERY time -
# reproduced three-for-three in review. Assert it now blocks at most once per window instead.
SID="$UNIQ-noprompt"; R=$(fresh_root noprompt)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
OUT=$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$SID" "$T" | bash "$HOOK" 2>&1); A=$?
OUT=$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$SID" "$T" | bash "$HOOK" 2>&1); B=$?
OUT=$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$SID" "$T" | bash "$HOOK" 2>&1); C=$?
if [ "$A" = "2" ] && [ "$B" = "0" ] && [ "$C" = "0" ]; then
  pass "absent prompt_id still bounded (blocks once per window, not every turn)"
else
  fail "absent prompt_id must be bounded" "rc sequence=$A,$B,$C (was 2,2,2 before the fix)"
fi

# === 12 — Kill switch. This is the only hook in the tree that can refuse to end a turn, so the
# escape hatch must work even when every blocking condition is genuinely met.
SID="$UNIQ-kill"; R=$(fresh_root kill)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
OUT=$(printf '{"session_id":"%s","prompt_id":"p1","transcript_path":"%s","hook_event_name":"Stop"}' "$SID" "$T" \
      | MISSION_LIVENESS_DISABLED=1 bash "$HOOK" 2>&1); RC=$?
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "MISSION_LIVENESS_DISABLED=1 suppresses a would-be block"
else
  fail "kill switch" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi
# NEGATIVE CONTROL for #12 — without the switch, that exact payload MUST block, or #12 proves nothing.
run_hook "$SID" "p2" "$T"
if [ "$RC" = "2" ]; then
  pass "same payload without the kill switch blocks (switch test is meaningful)"
else
  fail "kill-switch negative control" "rc=$RC — test 12 was passing for the wrong reason"
fi

# === 13 — The stall sample must be taken on a BOOKED turn too. The original sampled only on a
# block, so it could never observe the "keeps booking wakes, tree never moves" shape it existed for.
SID="$UNIQ-stall"; R=$(fresh_root stall)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" with "$SID"          # booked => the hook exits silent at step 5
rm -f "$STATE_DIR/$SID.cursor"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -s "$STATE_DIR/$SID.cursor" ]; then
  pass "cursor sampled on a booked (silent) turn — the stall detector can actually observe"
else
  fail "stall sample on booked turn" "rc=$RC cursor-file=$([ -s "$STATE_DIR/$SID.cursor" ] && echo present || echo ABSENT)"
fi

# === 14 — HUMAN-TURN REGRESSION. An armed window the user goes back to talking in must never be
# blocked. Three review lenses independently called this the worst outcome in the design: worse than
# the freeze, because it interrupts a real conversation and orders the model off to mission work.
SID="$UNIQ-human"; R=$(fresh_root human)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" human "$SID"     # boundary prompt carries no sid
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "human-initiated turn in an armed window => silent"
else
  fail "human turn must never block" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi
# NEGATIVE CONTROL — the SAME mission and arming, but a wake-initiated turn, must still block.
T2="$R/t2.jsonl"; mk_transcript "$T2" without "$SID"
run_hook "$SID" "p2" "$T2"
if [ "$RC" = "2" ]; then
  pass "wake-initiated turn in that same window still blocks (origin test is meaningful)"
else
  fail "human-turn negative control" "rc=$RC — test 14 was passing for the wrong reason"
fi

# === 15 — A FAILED ScheduleWakeup is not a booking. mission.md section 12.1 step 7 is explicit that a
# failed schedule must not be treated as continuation; crediting the bare tool_use would let the
# guard go quiet on exactly the turn that froze.
SID="$UNIQ-failsched"; R=$(fresh_root failsched)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
T="$R/t.jsonl"; mk_transcript "$T" failed "$SID"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "2" ]; then
  pass "ScheduleWakeup called but FAILED => still a naked yield => blocks"
else
  fail "failed schedule must block" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 16 — STOP-LOUD is a sanctioned stop. mission.md:1477-1478: "A STOP-LOUD must NEVER schedule the
# next self-wake (that would loop a wedged mission forever)." It banks no lifecycle line and opens no
# human barrier, so without this check the hook would shove a wedged mission back into the loop.
SID="$UNIQ-stoploud"; R=$(fresh_root stoploud)
mk_live_mission "$SID" "$R"; arm "$SID" "$R"
# Real grammar (mission-write.sh:265): FAIL part=<N> phase=<a-z-> reason=<a-z0-9-> attempt=<N>.
# Assert it BANKED - the first version of this test used a malformed line, the writer refused it, and
# the test then "failed" against a hook that was behaving correctly.
FL=$(bash "$MWSH" log "$SID" "$R" "[mission] FAIL part=1 phase=review reason=panel-unavailable-3x attempt=1" "m1-fail-panel3x-r1" 2>&1)
case "$FL" in *"log ok"*) : ;; *) fail "STOP-LOUD fixture" "FAIL line did not bank: $FL" ;; esac
T="$R/t.jsonl"; mk_transcript "$T" without "$SID"
run_hook "$SID" "p1" "$T"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then
  pass "STOP-LOUD (FAIL is the newest banked line) => silent, never re-driven"
else
  fail "STOP-LOUD must be silent" "rc=$RC out=$(printf '%s' "$OUT" | head -c 200)"
fi

# === 17 — Log hygiene, matching the sibling logger (lib/auto-compact-sentinel.sh writes 0600).
# The log records absolute repo paths on every armed turn end; world-readable is the wrong default.
if [ -f "$ML_LOG_UNDER_TEST" ]; then
  MODE=$(stat -f %Lp "$ML_LOG_UNDER_TEST" 2>/dev/null || stat -c %a "$ML_LOG_UNDER_TEST" 2>/dev/null)
  if [ "$MODE" = "600" ]; then
    pass "decision log is mode 600 (matches ac_log's umask 077 posture)"
  else
    fail "log permissions" "mode=$MODE expected 600"
  fi
else
  fail "log hygiene" "no log written at $ML_LOG_UNDER_TEST — the hook logged nothing at all"
fi

# === 18 — THE PRODUCTION ARMING PATH. Every other test in this file arms via the local arm() helper,
# which proves only "the hook reads what the test writes". This one proves the real writer arms, which
# is the property that actually keeps the guard from being inert in the field.
# Regression: arming used to live ONLY in mission.md's wake routine (step 0), so a mission driven
# entirely by USER turns never armed and the guard was permanently inert for it - measured on this
# machine as an active 34-day mission with zero arming sentinels. The conversational-to-overnight
# handoff ("continue, I'm going to bed") is exactly that population.
SID="$UNIQ-prodarm"; R=$(fresh_root prodarm); CREATED_SIDS+=("$SID")
ARMFILE="$HOME/.claude/progress/mission-liveness-$SID.json"
rm -f "$ARMFILE"
if [ -f "$ARMFILE" ]; then
  fail "production arming" "sentinel existed before any mission write"
else
  bash "$MWSH" create "$SID" "$R" "MISSION MODE: build — prod arm" >/dev/null 2>&1
  if [ -f "$ARMFILE" ] && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('sid')==sys.argv[2] and d.get('root')==sys.argv[3] else 1)" "$ARMFILE" "$SID" "$R"; then
    pass "mission-write.sh arms the guard on a real bridge mutation (sid+root correct, valid JSON)"
  else
    fail "production arming" "no valid sentinel at $ARMFILE after create"
  fi
fi

# === 19 — Registration coexistence: uninstalling auto-compact must not remove this hook.
if [ -f "$ROOT/uninstall-auto-compact.sh" ]; then
  if grep -q 'auto-compact-after-pre-compact' "$ROOT/uninstall-auto-compact.sh" 2>/dev/null &&
     ! grep -q 'mission-liveness' "$ROOT/uninstall-auto-compact.sh" 2>/dev/null; then
    pass "uninstall-auto-compact.sh filters only its own entry (liveness registration survives)"
  else
    fail "uninstall-auto-compact.sh scope" "it may remove or miss the liveness entry"
  fi
else
  pass "uninstall-auto-compact.sh absent — nothing to coexist with"
fi

printf '\nPASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
