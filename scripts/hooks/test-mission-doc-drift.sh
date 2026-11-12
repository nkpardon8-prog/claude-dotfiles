#!/usr/bin/env bash
# test-mission-doc-drift.sh — pins commands/mission.md (+ docs/mission/wake.md, reference.md) against silent drift.
# Rewritten for the mission rework (proto=2, 2026-11-11): budgets by recipe, rubric once, fixed caps gone.
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
# DOC defaults from $HERE, not $HOME (2026-08-17). CI invokes every harness as
# `bash "$h" </dev/null` with NO arguments, so the DEFAULT is the only path that matters
# there; the old $HOME form made this harness exit 2 ("FATAL: cannot read ...") on any
# checkout not living at ~/.claude-dotfiles. commands/ is two levels up from scripts/hooks/.
# An explicit $1 still wins, so callers that already pass a path are unaffected.
DOC="${1:-$HERE/../../commands/mission.md}"
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

WAKE="${3:-$HERE/../../docs/mission/wake.md}"
REF="${4:-$HERE/../../docs/mission/reference.md}"
[ -r "$WAKE" ] || { printf 'FATAL: cannot read %s\n' "$WAKE"; exit 2; }
[ -r "$REF"  ] || { printf 'FATAL: cannot read %s\n' "$REF";  exit 2; }
# All three mission docs, for "stated exactly once" checks: a rule restated in a sibling file drifts too.
agrep() { cat "$DOC" "$WAKE" "$REF" | grep -a -o -F "$1" 2>/dev/null | wc -l | tr -d ' '; }

# ── 1. Fixed round counts are gone; budgets come from the recipe ────────────────────────────────
# The fixed counts ("hard cap 6", the 3-blocking-round cap with an exempt dry pair, the 4-6 / 3-6 soft
# targets) drove the 11-, 17- and 33-round loops. proto=2 budgets come from the RECIPE and the wall clock.
for gone in 'hard cap 6' 'BLOCKING-producing rounds' 'dry pair EXEMPT' 'MISSION_PART_MAX_TICKS' 'MISSION_PART_MAX_MINUTES' '4-6 rounds' '3-6 rounds'; do
  N=$(agrep "$gone")
  if [ "${N:-0}" = 0 ]; then pass "retired fixed-count rule absent: $gone"
  else fail "retired fixed-count rule absent: $gone" "$N occurrence(s) remain"; fi
done
for k in '[mission] RECIPE part=' 'review=<budget>' 'budget=<min>' 'budget-state'; do
  N=$(agrep "$k")
  if [ "${N:-0}" -ge 1 ]; then pass "budget by recipe: doc names $k"
  else fail "budget by recipe: doc names $k" "missing"; fi
done

# ── 2. The BLOCKING rubric is stated exactly ONCE across the playbook and its reference files ─────
N=$(agrep 'a test that can pass while the thing it guards is broken')
if [ "${N:-0}" = 1 ]; then pass "the BLOCKING rubric is stated exactly once (canonical)"
else fail "the BLOCKING rubric is stated exactly once" "found $N - 0 means deleted, >1 means it can drift"; fi
N=$(agrep 'not by how confident')
if [ "${N:-0}" -ge 1 ]; then pass "the rubric rejects confidence as the tie-break"
else fail "the rubric rejects confidence as the tie-break" "the everything-is-blocking regression is unguarded"; fi

# ── 3. Park: non-blocking, never a STOP, never an AWAIT, carries disposition + range ────────────
for k in 'park=<reason>' 'disposition=' 'reverted | isolated | left-with-recorded-risk' 'range=<base12>..<head12>' 'never a STOP' 'never opens a human AWAIT'; do
  N=$(agrep "$k")
  if [ "${N:-0}" -ge 1 ]; then pass "park contract names: $k"
  else fail "park contract names: $k" "missing"; fi
done

# ── 4. DOC <-> CODE (legacy fold): the FROZEN window after dry=1 is still machine-enforced ────────
if grep -a -q 'FROZEN' "$DOC"; then pass "doc states the post-dry=1 window is FROZEN"
else fail "doc states the post-dry=1 window is FROZEN" "missing"; fi
if grep -a -q '!(act>rl\[a\])' "$MW"; then
  pass "CODE enforces it (PART-DONE fold rejects an actionable event after dry=1)"
else
  fail "CODE enforces it" "the '!(act>rl[a])' guard is gone from mission-write.sh - the doc's FROZEN claim is now false"
fi
if grep -a -q 'convergence-not-machine-clean' "$MW"; then pass "CODE refuses PART-DONE with convergence-not-machine-clean"
else fail "CODE refuses PART-DONE with convergence-not-machine-clean" "refusal path missing"; fi

# ── 5. DOC <-> CODE (proto=2): every writer verb, shape and refusal the playbook relies on exists ──
# STRICT: a doc that names a verb, shape or refusal the writer lacks is exactly the drift this file
# exists to catch. (The chunk-D-era MISSION_DOC_DRIFT_WRITER_PENDING skip is gone: writer and playbook
# land together, so there is no state in which a missing writer feature is acceptable.)
proto2() {  # proto2 <label> <file> <literal>
  if grep -a -q -F -- "$3" "$2" 2>/dev/null; then pass "$1"
  else fail "$1" "'$3' not found in $2"; fi
}
for verb in bank-review budget-state; do
  N=$(agrep "$verb")
  if [ "${N:-0}" -ge 1 ]; then pass "doc names verb $verb"; else fail "doc names verb $verb" "missing"; fi
  proto2 "CODE: mission-write.sh implements $verb" "$MW" "$verb"
done
for shape in RECIPE SWEEP FULL-SUITE ANCHOR; do
  N=$(agrep "[mission] $shape part=")
  if [ "${N:-0}" -ge 1 ]; then pass "doc defines the $shape line"; else fail "doc defines the $shape line" "missing"; fi
  proto2 "CODE: mission-write.sh validates the $shape shape" "$MW" "$shape"
done
for refusal in part-over-budget part-retired; do
  N=$(agrep "$refusal")
  if [ "${N:-0}" -ge 1 ]; then pass "doc names refusal $refusal"; else fail "doc names refusal $refusal" "missing"; fi
  proto2 "CODE: mission-write.sh refuses with $refusal" "$MW" "$refusal"
done
proto2 "CODE: cutover refusal tells a running conductor to reload the playbook" "$MW" "re-read commands/mission.md"
WD="$HERE/mission-watchdog.sh"
N=$(agrep 'mission-watchdog.sh')
if [ "${N:-0}" -ge 1 ]; then pass "doc launches the helper watchdog"; else fail "doc launches the helper watchdog" "missing"; fi
proto2 "CODE: the watchdog exists and reports STALL" "$WD" "STALL"

# ── 6. The wake reads wake.md, not the playbook; wake.md holds the decision rows the plan moved ───
for k in 'budget-state' 'watchdog' 'Close join' 'Repair'; do
  if grep -a -q -F -- "$k" "$WAKE"; then pass "wake.md decision table carries: $k"
  else fail "wake.md decision table carries: $k" "missing"; fi
done
# Budget and watchdog rows must come BEFORE the job-AWAIT rows, so a pending job's heartbeat exit
# can never skip an over-budget part or a stalled helper (plan 5.5).
ORD=$(python3 -c "
import sys
s=open(sys.argv[1],encoding='utf-8').read()
t=s.find('## Decision table'); s=s[t:]
a=s.find('over ... replan=1'); w=s.find('watchdog status file'); j=s.find('await kind=job ready=0')
print('ok' if -1 not in (a,w,j) and a<j and w<j else 'bad')" "$WAKE")
if [ "$ORD" = ok ]; then pass "budget + watchdog rows precede the job-AWAIT rows"
else fail "budget + watchdog rows precede the job-AWAIT rows" "order broken or row missing"; fi

# ── 7. DOC <-> CODE: the Codex-may-write split (6.5) is backed by the guarded wrapper ───────────
CBC="$HERE/../codex-build-chunk.sh"
if grep -a -q 'codex-build-chunk' "$DOC"; then pass "doc routes Codex code-writing through the wrapper"
else fail "doc routes Codex code-writing through the wrapper" "missing"; fi
if [ -r "$CBC" ]; then
  if grep -a -q 'refused-main-worktree\|main-worktree' "$CBC" && grep -a -q 'workspace-write' "$CBC"; then
    pass "CODE: the wrapper refuses a main working tree (the sandbox-boundary property)"
  else
    fail "CODE: the wrapper refuses a main working tree" "the linked-worktree refusal is gone from codex-build-chunk.sh"
  fi
  if grep -a -q 'no-changes' "$CBC"; then pass "CODE: zero changed files is a failure, not an ok"
  else fail "CODE: zero changed files is a failure" "the no-op guard is gone"; fi
else
  fail "codex-build-chunk.sh exists" "not found at $CBC - 6.5 names a wrapper that is not there"
fi

# ── 7b. Model routing: Terra for cheap work only, Sol for every review and verify ───────────────
for k in 'gpt-6.1-terra' 'gpt-6.1-sol'; do
  if grep -a -q -F -- "$k" "$DOC"; then pass "model routing names $k"; else fail "model routing names $k" "missing"; fi
done
if grep -a -i 'terra' "$DOC" "$WAKE" "$REF" | grep -a -i -q 'review lane\|verify lane\|for review'; then
  if grep -a -q 'Never Terra for review' "$DOC"; then pass "Terra is never a review model"
  else fail "Terra is never a review model" "a Terra line mentions review without the ban"; fi
else pass "Terra is never a review model"; fi

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

# ── 9. DOC <-> CODE: line shapes the playbook teaches are the shapes the writer accepts ──────────
# Each pair: the doc literal AND the writer literal that enforces it. Integration found the playbook
# and the writer disagreeing on these (built in parallel against the plan, not each other).
both() {  # both <label> <doc-literal> <writer-literal>
  N=$(agrep "$2")
  if [ "${N:-0}" -ge 1 ] && grep -a -q -F -- "$3" "$MW"; then pass "$1"
  elif [ "${N:-0}" -lt 1 ]; then fail "$1" "doc lacks: $2"
  else fail "$1" "writer lacks: $3"; fi
}
both "PART-START carries needs=" 'proto=2 worktree=<abs path> base=<sha12> needs=<none|N[,N...]>' 'base=[0-9a-f]{12} needs=(none|'
both "RECIPE repeats the PART-START needs=" 'repeats its PART-START `needs=`' 'recipe needs= differs from the PART-START needs='
both "park FAIL shape + idtag" '[mission] FAIL part=<N> park=<reason> disposition=<reverted|isolated|left-with-recorded-risk> range=<base12>..<head12>` (`m<N>-fail-park`)' '-fail-park" ] || _mw_emit_refuse log 1 "REFUSED: bad-park-idtag'
both "close result is REVIEW-EVIDENCE scope=close head=<freeze>" 'scope=close base=<base> head=<freeze> ... result=clean|blocking' 'review-evidence-$_bsc-r$_bk'
both "REVIEW-EVIDENCE idtag carries the scope" 'm<N>-review-evidence-<scope>-r<K>' '"m$_bn-review-evidence-$_bsc-r$_bk"'
both "ANCHOR is writer-only" 'ANCHOR` is written only by the writer' 'is written only by the writer itself'
both "suite report header + body documented" 'sha= base= command= env= completed= infra=' '_p2_kr_hdr "$1" infra'
both "suite report body line documented" '`<test id> | <failure signature>`' "grep ' | '"
both "budget-state over token" 'over part=<N> minutes=<M> replan=<0|1>' 'echo "over part=$_bsn minutes=$2 replan=$3"'
both "writer refreshes the morning report" 'the writer rewrites `<root>/tmp/mission/MORNING.md`' 'mission-status.sh" morning'
for k in 'mission-status.sh' 'MORNING.md'; do
  if grep -a -q -F -- "$k" "$WAKE"; then pass "wake.md stop path names $k"; else fail "wake.md stop path names $k" "missing"; fi
done
for gone in 'scope=close sha=<freeze>' 'm<N>-review-evidence-r<K>' 'written once at cutover'; do
  N=$(agrep "$gone")
  if [ "${N:-0}" = 0 ]; then pass "stale shape absent: $gone"; else fail "stale shape absent: $gone" "$N occurrence(s)"; fi
done
if grep -a -q -F 'second dirty sweep' "$WAKE"; then pass "wake.md: a second dirty sweep on the same types -> redesign"
else fail "wake.md: second dirty sweep -> redesign" "missing (a resumed tick would sweep forever)"; fi

printf '\nPASS: %s  FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
