#!/usr/bin/env bash
# test-mission-doc-drift.sh — pins commands/mission.md against silent drift.
#
# WHY. mission.md is a CONTRACT the model executes, and its two recurring failure modes are both
# silent: (a) a rule stated three times in three places, so a fix lands in one and the other two keep
# instructing the old behaviour; (b) prose that CLAIMS a machine enforces something the machine does
# not actually enforce, which reads as a guarantee and is a wish. Neither shows up as a red test
# anywhere else - the doc always "works".
#
# So the load-bearing assertions here are the DOC <-> CODE ones: where mission.md says
# `mission-write.sh` refuses something, this file greps the actual enforcement out of
# mission-write.sh. If someone deletes the guard, the doc's claim goes red.
#
# Emits a final `PASS: N  FAIL: M` line and exits nonzero on any FAIL.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="${1:-$HOME/.claude-dotfiles/commands/mission.md}"
MW="${2:-$HERE/mission-write.sh}"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "${2:-}"; }

printf 'test-mission-doc-drift\n  doc: %s\n  code: %s\n' "$DOC" "$MW"
[ -r "$DOC" ] || { printf 'FATAL: cannot read %s\n' "$DOC"; exit 2; }
[ -r "$MW"  ] || { printf 'FATAL: cannot read %s\n' "$MW";  exit 2; }

# grep -a everywhere: a single NUL byte makes grep skip a file SILENTLY, which would turn every
# absence-assertion below into a false green (this exact blindness has bitten this repo before).
# Counts OCCURRENCES, not matching lines. `grep -c` counts lines, so two restatements that happen to
# share a line read as one - a mutant that duplicated the rubric inline passed against the -c version.
dgrep() { grep -a -o -F "$1" "$DOC" 2>/dev/null | wc -l | tr -d ' '; }

# ── 1. The undefined "hard cap 6" is gone from EVERY site ───────────────────────────────────────
# It was stated three times with no behaviour attached, which left dry=2 as the only real exit.
N=$(dgrep 'hard cap 6'); M=$(grep -a -ci 'hard cap 6' "$DOC" | tr -d ' ')
if [ "${M:-0}" = 0 ]; then pass "the behaviourless 'hard cap 6' is absent everywhere"
else fail "the behaviourless 'hard cap 6' is absent everywhere" "$M occurrence(s) remain"; fi

# ── 2. The cap is DEFINED exactly once, and by what it does ─────────────────────────────────────
N=$(dgrep 'BLOCKING-producing rounds')
if [ "${N:-0}" -ge 1 ]; then pass "the cap is stated in terms of BLOCKING-producing rounds"
else fail "the cap is stated in terms of BLOCKING-producing rounds" "no such statement found"; fi

N=$(dgrep 'dry pair EXEMPT'); N2=$(dgrep 'pair is EXEMPT')
if [ "${N:-0}" -ge 1 ] || [ "${N2:-0}" -ge 1 ]; then pass "the dry pair is stated EXEMPT from the cap"
else fail "the dry pair is stated EXEMPT from the cap" "the unclosable-part trap is unguarded"; fi

# ── 3. The canonical BLOCKING rubric exists, and is defined by ENUMERATION not confidence ───────
N=$(dgrep 'Classify by which list it belongs to')
if [ "${N:-0}" = 1 ]; then pass "the BLOCKING rubric is stated exactly once (canonical)"
else fail "the BLOCKING rubric is stated exactly once" "found $N — 0 means deleted, >1 means it can drift"; fi

N=$(dgrep 'not by how confident')
if [ "${N:-0}" -ge 1 ]; then pass "the rubric explicitly rejects confidence as the tie-break"
else fail "the rubric explicitly rejects confidence as the tie-break" "the everything-is-blocking regression is unguarded"; fi

# ── 4. Both park paths exist and BOTH carry the required disposition field ──────────────────────
for slug in cap-exhausted-blocking part-over-budget; do
  N=$(dgrep "reason=$slug")
  if [ "${N:-0}" -ge 1 ]; then pass "park path reason=$slug is documented"
  else fail "park path reason=$slug is documented" "missing"; fi
done
N=$(dgrep 'disposition=')
if [ "${N:-0}" -ge 1 ]; then pass "the park path requires a disposition= for the code left in the tree"
else fail "the park path requires a disposition=" "later parts would build on an undeclared tree"; fi

# ── 5. A park must NEVER be a STOP (a STOP freezes every remaining part) ────────────────────────
N=$(dgrep 'never a STOP')
if [ "${N:-0}" -ge 1 ]; then pass "the park is explicitly distinguished from a STOP"
else fail "the park is explicitly distinguished from a STOP" "missing"; fi

# ── 6. DOC <-> CODE: the frozen-window claim is actually enforced by mission-write.sh ───────────
# §6.2 tells the conductor a phase=fix after the dry=1 bank is REFUSED. That is only true because
# the PART-DONE fold tracks `act` (any fix/implement/VOID/findings>0 line) and requires it to be
# ordered BEFORE the dry=1 line. Delete that and the doc becomes a wish.
if grep -a -q 'FROZEN' "$DOC"; then pass "doc states the post-dry=1 window is FROZEN"
else fail "doc states the post-dry=1 window is FROZEN" "missing"; fi

if grep -a -q '!(act>rl\[a\])' "$MW"; then
  pass "CODE actually enforces it (PART-DONE fold rejects an actionable event after dry=1)"
else
  fail "CODE actually enforces it" "the '!(act>rl[a])' guard is gone from mission-write.sh — the doc's FROZEN claim is now false"
fi

if grep -a -q 'phase=fix' "$MW" && grep -a -q 'convergence-not-machine-clean' "$MW"; then
  pass "CODE refuses PART-DONE with convergence-not-machine-clean"
else
  fail "CODE refuses PART-DONE with convergence-not-machine-clean" "refusal path missing"
fi

# ── 7. DOC <-> CODE: the spend brake's settings are named in the doc AND the stall marker the ───
#      wake routine reads is the one the liveness hook actually writes.
for k in MISSION_PART_MAX_TICKS MISSION_PART_MAX_MINUTES; do
  N=$(dgrep "$k")
  if [ "${N:-0}" -ge 1 ]; then pass "spend-brake setting $k is named in the doc"
  else fail "spend-brake setting $k is named in the doc" "missing"; fi
done

LIVENESS="$HERE/mission-liveness.sh"
if [ -r "$LIVENESS" ]; then
  if grep -a -q 'stall-alert' "$DOC" && grep -a -q 'stall-alert' "$LIVENESS"; then
    pass "the stall-alert filename matches between the doc and the hook that writes it"
  else
    fail "the stall-alert filename matches between doc and hook" \
         "doc=$(grep -a -c 'stall-alert' "$DOC" | tr -d ' ') hook=$(grep -a -c 'stall-alert' "$LIVENESS" | tr -d ' ') — the conductor would read a file nobody writes"
  fi
fi

# ── 8. The contract core still fits its injection budget ────────────────────────────────────────
CORE=$(python3 -c "
import io,sys
s=io.open(sys.argv[1],encoding='utf-8').read()
i=s.find('<!-- CONTRACT-CORE-END')
print(len(s[:i]) if i!=-1 else -1)
" "$DOC" 2>/dev/null)
if [ "${CORE:-0}" -gt 0 ] && [ "${CORE:-0}" -le 19500 ]; then
  pass "contract core fits the 19500-char injection budget (${CORE})"
else
  fail "contract core fits the 19500-char injection budget" "measured ${CORE}"
fi

printf '\nPASS: %s  FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
