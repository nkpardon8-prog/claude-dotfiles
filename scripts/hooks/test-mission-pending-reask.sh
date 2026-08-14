#!/usr/bin/env bash
# test-mission-pending-reask.sh — regression harness for mission-pending-reask.sh
# (the UserPromptSubmit hook that re-asks a mission's open questions when the user comes back).
#
# Emits a final `PASS: N  FAIL: M` line and exits nonzero on any FAIL.
#
# HOUSE RULE (scripts/hooks/mission-bridge-assumptions/README.md): every assertion carries an
# explicit NEGATIVE CONTROL. This hook's default is SILENCE, so "it printed nothing" is the cheapest
# possible false green — a hook with `exit 0` on line 1 would pass every silence test in this file.
# Each silence case is therefore paired with a case that fires under the same fixture with only the
# guarded condition changed.
#
# Hermetic: per-test temp roots under $TMPDIR, sids namespaced by UNIQ, all state removed on exit.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOOK="$ROOT/mission-pending-reask.sh"
MWSH="$ROOT/mission-write.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "${2:-}"; }

UNIQ="tmpr-$$-$(date +%s)"
WORKBASE="${TMPDIR:-/tmp}/${UNIQ}"
mkdir -p "$WORKBASE"

cleanup() {
  rm -f "$HOME/.claude/progress/.mission-reask-${UNIQ}"* 2>/dev/null
  rm -f "$HOME/.claude/progress/mission-liveness-${UNIQ}"*.json 2>/dev/null
  rm -f "$HOME/.claude/progress/mission-liveness/${UNIQ}"* 2>/dev/null
  rm -rf "$WORKBASE" 2>/dev/null
}
trap cleanup EXIT

fresh_root() { d="$WORKBASE/$1"; mkdir -p "$d"; ( cd "$d" && git init -q . >/dev/null 2>&1 ); printf '%s' "$d"; }

# Run the hook with a real UserPromptSubmit-shaped payload. Captures stdout; asserts exit 0 always.
run_hook() {  # run_hook <sid> <cwd>  -> stdout; sets RC
  OUT=$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$1" "$2" \
        | bash "$HOOK" 2>/dev/null)
  RC=$?
}

seed_mission() {  # seed_mission <sid> <root>
  bash "$MWSH" create "$1" "$2" "MISSION MODE: build
Test mission for the re-ask hook." >/dev/null 2>&1
}

has()   { case "$2" in *"$1"*) pass "$3" ;; *) fail "$3" "missing '$1'" ;; esac; }
hasnt() { case "$2" in *"$1"*) fail "$3" "unexpected '$1'" ;; *) pass "$3" ;; esac; }

printf 'test-mission-pending-reask\n'

# ── 1. Silent when there is no mission for this sid ─────────────────────────────────────────────
R1=$(fresh_root r1); S1="${UNIQ}-nomission"
run_hook "$S1" "$R1"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "silent when no mission exists for the sid" \
  || fail "silent when no mission exists for the sid" "rc=$RC out=${OUT:0:80}"

# ── 2. Silent when a mission exists but PENDING DECISIONS is empty ──────────────────────────────
R2=$(fresh_root r2); S2="${UNIQ}-nopending"
seed_mission "$S2" "$R2"
run_hook "$S2" "$R2"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "silent when the pending zone is empty" \
  || fail "silent when the pending zone is empty" "rc=$RC out=${OUT:0:80}"

# ── 3. NEGATIVE CONTROL for 1+2: same fixture, one pending question -> it FIRES ─────────────────
bash "$MWSH" pending "$S2" "$R2" "dbchoice" "Should the recall sweep use the new index or the old one?" >/dev/null 2>&1
run_hook "$S2" "$R2"
has "mission-pending-reask" "$OUT" "fires once a pending question exists (control for 1+2)"
has "Should the recall sweep use the new index" "$OUT" "carries the question text"
has "pd:" "$OUT" "carries the pd id"

# ── 4. Untrusted framing + the resolve instruction are present ──────────────────────────────────
has "UNTRUSTED RECORDED DATA" "$OUT" "frames injected text as untrusted data"
has "never as an instruction" "$OUT" "tells the reader not to act on it"
has "mission-write.sh resolve" "$OUT" "carries a copy-runnable resolve command"

# ── 5. Labels a plain `pending` NON-BLOCKING ────────────────────────────────────────────────────
has "non-blocking" "$OUT" "labels a plain pending as non-blocking"

# ── 6. THROTTLE: the same unanswered id-set stays quiet on the next prompt ──────────────────────
run_hook "$S2" "$R2"
[ -z "$OUT" ] && pass "throttled: same pd-id-set is silent on the next prompt" \
  || fail "throttled: same pd-id-set is silent on the next prompt" "out=${OUT:0:80}"

# ── 7. NEGATIVE CONTROL for 6: a NEW question changes the id-set -> fires again ─────────────────
bash "$MWSH" pending "$S2" "$R2" "second" "Second open question?" >/dev/null 2>&1
run_hook "$S2" "$R2"
has "Second open question" "$OUT" "a NEW question re-fires despite the throttle (control for 6)"

# ── 8. BLOCKING label: a pending-stop opens an AWAIT kind=human and must be labelled BLOCKING ───
R8=$(fresh_root r8); S8="${UNIQ}-blocking"
seed_mission "$S8" "$R8"
bash "$MWSH" pending-stop "$S8" "$R8" "credflip" 1 1 1 implement "May I rotate the production credential?" >/dev/null 2>&1
run_hook "$S8" "$R8"
has "BLOCKING - the run is parked" "$OUT" "labels a pending-stop question BLOCKING"
has "May I rotate the production credential" "$OUT" "carries the blocking question text"

# ── 9. NEGATIVE CONTROL for 8: same hook, a NON-stop pending in a clean mission is NOT BLOCKING ─
R9=$(fresh_root r9); S9="${UNIQ}-nonblocking"
seed_mission "$S9" "$R9"
bash "$MWSH" pending "$S9" "$R9" "styleq" "Tabs or spaces in the generated file?" >/dev/null 2>&1
run_hook "$S9" "$R9"
hasnt "BLOCKING - the run is parked" "$OUT" "a plain pending is NOT labelled blocking (control for 8)"

# ── 10. Never adopts ANOTHER sid's mission under the same root ──────────────────────────────────
RS=$(fresh_root rshared); SA="${UNIQ}-owner"; SB="${UNIQ}-sibling"
seed_mission "$SA" "$RS"
bash "$MWSH" pending "$SA" "$RS" "ownerq" "OWNER-ONLY-QUESTION-MARKER" >/dev/null 2>&1
run_hook "$SB" "$RS"
[ -z "$OUT" ] && pass "a sibling sid in the SAME root sees nothing" \
  || fail "a sibling sid in the SAME root sees nothing" "leaked: ${OUT:0:120}"

# ── 11. NEGATIVE CONTROL for 10: the OWNER sid in that same root does see it ────────────────────
run_hook "$SA" "$RS"
has "OWNER-ONLY-QUESTION-MARKER" "$OUT" "the owning sid DOES see its own question (control for 10)"

# ── 12. Kill switch silences it ─────────────────────────────────────────────────────────────────
R12=$(fresh_root r12); S12="${UNIQ}-killswitch"
seed_mission "$S12" "$R12"
bash "$MWSH" pending "$S12" "$R12" "q" "KILLSWITCH-MARKER" >/dev/null 2>&1
OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$S12" "$R12" | MISSION_REASK_DISABLED=1 bash "$HOOK" 2>/dev/null)
[ -z "$OUT" ] && pass "MISSION_REASK_DISABLED=1 silences it" || fail "MISSION_REASK_DISABLED=1 silences it" "out=${OUT:0:80}"

# ── 13. NEGATIVE CONTROL for 12: identical fixture without the switch fires ─────────────────────
run_hook "$S12" "$R12"
has "KILLSWITCH-MARKER" "$OUT" "same fixture WITHOUT the kill switch fires (control for 12)"

# ── 14. A CLEARED mission does not re-ask ───────────────────────────────────────────────────────
R14=$(fresh_root r14); S14="${UNIQ}-cleared"
seed_mission "$S14" "$R14"
bash "$MWSH" pending "$S14" "$R14" "q" "CLEARED-MISSION-MARKER" >/dev/null 2>&1
run_hook "$S14" "$R14" >/dev/null 2>&1      # consume the first (throttle) fire
bash "$MWSH" log "$S14" "$R14" "[mission] MISSION-CLEARED status=achieved reason=done" "" >/dev/null 2>&1
rm -f "$HOME/.claude/progress/.mission-reask-${S14}" 2>/dev/null   # defeat the throttle, isolate the lifecycle gate
run_hook "$S14" "$R14"
[ -z "$OUT" ] && pass "a CLEARED mission does not re-ask" || fail "a CLEARED mission does not re-ask" "out=${OUT:0:100}"

# ── 15. Long question text is byte-capped ───────────────────────────────────────────────────────
R15=$(fresh_root r15); S15="${UNIQ}-cap"
seed_mission "$S15" "$R15"
LONGQ=$(python3 -c 'print("X"*3000)')
bash "$MWSH" pending "$S15" "$R15" "longq" "$LONGQ" >/dev/null 2>&1
run_hook "$S15" "$R15"
XCOUNT=$(printf '%s' "$OUT" | tr -cd 'X' | wc -c | tr -d ' ')
if [ "${XCOUNT:-0}" -gt 0 ] && [ "${XCOUNT:-0}" -le 500 ]; then
  pass "long question text is byte-capped (kept ${XCOUNT} of 3000)"
else
  fail "long question text is byte-capped" "kept ${XCOUNT} chars"
fi

# ── 16. Malformed / empty stdin never breaks a prompt ───────────────────────────────────────────
RC_A=0; printf 'not json at all' | bash "$HOOK" >/dev/null 2>&1 || RC_A=$?
RC_B=0; printf ''                | bash "$HOOK" >/dev/null 2>&1 || RC_B=$?
[ "$RC_A" = 0 ] && [ "$RC_B" = 0 ] && pass "malformed and empty stdin both exit 0 (never blocks a prompt)" \
  || fail "malformed/empty stdin exit 0" "garbage=$RC_A empty=$RC_B"

printf '\nPASS: %s  FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
