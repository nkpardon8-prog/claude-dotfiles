#!/usr/bin/env bash
# 08 - A1..A7: the multi-chunk confidence floor (schema doc s4 rule 12, reason low_confidence)
#      and the SERIAL_CORRECT verdict (rule 13, reason serial_correct).
#
# Load-bearing because: the reason token on the event is the measurement. A wave that fans out
# on a MEDIUM-confidence write-set is exactly the case the parallelizer is supposed to refuse,
# and it must be distinguishable in the log from a schema error - "we declined because the model
# was unsure" and "we declined because the output was broken" lead to opposite fixes. Rule 13 is
# why SERIAL_CORRECT exits 1: the orchestrator runs serially and needs no validated plan, so a 0
# would tell it to fan out on a plan that says do not.
#
# NEGATIVE CONTROL (controllable precondition): set the confidence back to "high" in A1/A2, or
# restore the independent_of entry in A3, and that assertion goes RED - the reject becomes a 0.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "08-validate-plan-confidence-serial"
wc_wave

PLAN="${BASE}/plan.json"
MUT="${BASE}/mutant.json"
wc_plan golden-wave-plan.json "$PLAN"

SINGLE="p['waves'][0]['chunks'] = [p['waves'][0]['chunks'][0]]
p['waves'][0]['chunks'][0]['independent_of'] = []"

# A1 - a chunk's write_set_confidence must be high in a multi-chunk wave
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][1]['write_set_confidence'] = 'medium'"
wc_check 1 "A1 medium write_set_confidence" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason low_confidence "A1 medium write_set_confidence"
wc_out_has "plan rule 12" "A1 medium write_set_confidence"

# A2 - so must the plan's top-level confidence
wc_mutate "$PLAN" "$MUT" "p['confidence'] = 'medium'"
wc_check 1 "A2 medium top-level confidence" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason low_confidence "A2 medium top-level confidence"

# A3 - every chunk must name every sibling in independent_of: the claim has to be made out loud
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['independent_of'] = []"
wc_check 1 "A3 missing independent_of" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason low_confidence "A3 missing independent_of"
wc_out_has "chunk-b" "A3 missing independent_of"

# A4 - POSITIVE control: rule 12 only bites MULTI-chunk waves
wc_mutate "$PLAN" "$MUT" "${SINGLE}
p['confidence'] = 'medium'
p['waves'][0]['chunks'][0]['write_set_confidence'] = 'medium'"
wc_check 0 "A4 single chunk may be medium" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

# A5 - SERIAL_CORRECT: well-formed, and still exit 1 so the caller cannot mistake it for a plan
wc_mutate "$PLAN" "$MUT" "${SINGLE}
p['verdict'] = 'SERIAL_CORRECT'
p['serial_reasons'] = ['Every pending item edits the same module.']"
wc_check 1 "A5 SERIAL_CORRECT" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason serial_correct "A5 SERIAL_CORRECT"
wc_out_has "plan rule 13" "A5 SERIAL_CORRECT"

# A6 - SERIAL_CORRECT with a multi-chunk wave contradicts itself: malformed, not serial_correct
wc_mutate "$PLAN" "$MUT" "p['verdict'] = 'SERIAL_CORRECT'
p['serial_reasons'] = ['claimed serial']"
wc_check 1 "A6 SERIAL_CORRECT with 2 chunks" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason malformed "A6 SERIAL_CORRECT with 2 chunks"

# A7 - SERIAL_CORRECT with no reasons is malformed: an unexplained refusal is not evidence
wc_mutate "$PLAN" "$MUT" "${SINGLE}
p['verdict'] = 'SERIAL_CORRECT'
p['serial_reasons'] = []"
wc_check 1 "A7 SERIAL_CORRECT without reasons" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason malformed "A7 SERIAL_CORRECT without reasons"

wc_finish '{"rule12":"multi-chunk requires high confidence + full independent_of -> low_confidence","rule13":"SERIAL_CORRECT -> exit 1 reason serial_correct","single_chunk":"rule 12 not applicable"}' \
  "7 assertions (A1-A3 rule 12, A4 positive control, A5-A7 rule 13)"
