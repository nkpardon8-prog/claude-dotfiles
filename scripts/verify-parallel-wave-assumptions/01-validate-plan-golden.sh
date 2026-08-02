#!/usr/bin/env bash
# 01 - A1..A6: the GOLDEN ENVELOPE plus schema doc s4 rules 1 (shape) and 2 (repo_root).
#      A known-disjoint 2-chunk wave_plan passes; a known-DEPENDENT one is rejected.
#
# Load-bearing because: every FAN_OUT the orchestrator ever acts on passes through
# --validate-plan. If the checker accepts a dependent pair, two subagents build against a file
# one of them is rewriting and the damage is silent - it looks like a merge that worked. And if
# it REJECTS the known-good shape, the wave machinery is dead on arrival and every run degrades
# to serial without anyone noticing why.
#
# NEGATIVE CONTROL (controllable precondition): remove the dependency from the dependent
# fixture (clear chunk-b's reads) and A2 goes RED - the plan validates 0 where 1 was expected.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "01-validate-plan-golden"
wc_wave

PLAN="${BASE}/plan.json"
DEP="${BASE}/dependent.json"
MUT="${BASE}/mutant.json"
wc_plan golden-wave-plan.json "$PLAN"
wc_plan dependent-wave-plan.json "$DEP"

# A1 - the golden envelope validates
wc_check 0 "A1 golden plan" --validate-plan "$PLAN" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason fan_out "A1 golden plan"

# A2 - the known-DEPENDENT pair is rejected, naming the rule and the file
wc_check 1 "A2 dependent plan" --validate-plan "$DEP" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason malformed "A2 dependent plan"
wc_out_has "plan rule 9" "A2 dependent plan"
wc_out_has "src/shared.ts" "A2 dependent plan"
wc_out_has "chunk-b" "A2 dependent plan"

# A3 - rule 1: a schema_version the checker does not implement is REJECTED, never best-effort
#      parsed (schema doc s8).
wc_mutate "$PLAN" "$MUT" 'p["schema_version"] = "parallelizer.v2"'
wc_check 1 "A3 schema_version" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason malformed "A3 schema_version"

# A4 - rule 2: analysis_basis.repo_root must equal the passed --repo-root
wc_mutate "$PLAN" "$MUT" 'p["analysis_basis"]["repo_root"] = "/nowhere/else"'
wc_check 1 "A4 repo_root mismatch" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "plan rule 2" "A4 repo_root mismatch"

# A5 - rule 1: a missing required chunk key is malformed
wc_mutate "$PLAN" "$MUT" 'del p["waves"][0]["chunks"][0]["rationale"]'
wc_check 1 "A5 missing required key" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason malformed "A5 missing required key"

# A6 - s3.1 forward tolerance: an UNKNOWN top-level key is ignored, not rejected. Nothing about
#      a chunk's permissions is inferable from an unknown key, so tolerating it cannot widen a
#      write-set - and a checker that rejected them would break on the next schema addition.
wc_mutate "$PLAN" "$MUT" 'p["some_future_key"] = {"anything": 1}'
wc_check 0 "A6 unknown key tolerated" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

# A7 - a mode-less invocation is a usage error with NO event: the closed tool_mode set has no
#      value to attribute it to, and inventing one would corrupt the denominator.
wc_check_noevent 2 "A7 no mode named" --repo-root "$REPO"

wc_finish '{"golden":"exit 0 reason fan_out","dependent":"exit 1 rule 9","schema_version_reject":true,"unknown_key_tolerated":true,"modeless_invocation":"exit 2, no event"}' \
  "7 assertions (A1 golden, A2 dependent, A3 schema_version, A4 repo_root, A5 shape, A6 forward tolerance, A7 modeless)"
