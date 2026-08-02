#!/usr/bin/env bash
# 02 - A1..A6: the base_sha ancestry rule (schema doc s3.2, s4 rule 3).
#      Equal at wave 1; an ANCESTOR on later-wave re-validation; anything else rejected.
#
# Load-bearing because: the orchestrator RE-PINS base_sha at every wave, so a plan analyzed at
# wave 1 is legitimately behind the sha passed at wave 3 - a naive equality check would refuse
# every wave after the first and the machinery would never run past one wave. The mirror risk is
# worse: accepting a base_sha from a DIFFERENT history means every disjointness claim in the
# plan was computed against files that are not the ones about to be edited.
#
# NEGATIVE CONTROL (controllable precondition): fast-forward the side branch so its commit
# BECOMES an ancestor of the passed sha and A3 goes RED - the reject turns into a 0.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "02-validate-plan-base-sha"
wc_wave

PLAN="${BASE}/plan.json"
MUT="${BASE}/mutant.json"
wc_plan golden-wave-plan.json "$PLAN"

# A1 - wave 1: the plan's base_sha EQUALS the passed sha
wc_check 0 "A1 equality" --validate-plan "$PLAN" --repo-root "$REPO" --base-sha "$BASE_SHA"

# advance repo_root, as merging wave 1 would
printf 'second\n' >> "${REPO}/src/shared.ts"
wc_commit "$REPO" "second commit"
SHA2="$(g "$REPO" rev-parse HEAD)"

# A2 - later-wave re-validation: the plan's base_sha is an ANCESTOR of the re-pinned sha
wc_check 0 "A2 ancestor accepted" --validate-plan "$PLAN" --repo-root "$REPO" --base-sha "$SHA2"

# A3 - a base_sha on a DIVERGENT history is rejected
g "$REPO" checkout -q -b side "$BASE_SHA"
printf 'side\n' > "${REPO}/src/side.ts"
wc_commit "$REPO" "side commit"
SIDE="$(g "$REPO" rev-parse HEAD)"
g "$REPO" checkout -q main
wc_mutate "$PLAN" "$MUT" "p['analysis_basis']['base_sha'] = '${SIDE}'"
wc_check 1 "A3 non-ancestor rejected" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$SHA2"
wc_expect_reason malformed "A3 non-ancestor rejected"
wc_out_has "plan rule 3" "A3 non-ancestor rejected"

# A4 - a base_sha that is not a 40-char hex sha is malformed (shape, rule 1)
wc_mutate "$PLAN" "$MUT" "p['analysis_basis']['base_sha'] = 'HEAD'"
wc_check 1 "A4 non-sha base_sha" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason malformed "A4 non-sha base_sha"

# A5 - a PASSED sha that does not resolve in the repo is an ENVIRONMENT error, not a verdict
wc_check 2 "A5 unresolvable passed sha" --validate-plan "$PLAN" --repo-root "$REPO" \
  --base-sha "0000000000000000000000000000000000000000"

# A6 - a passed --repo-root that is not a git repository is likewise exit 2
wc_check 2 "A6 non-repo root" --validate-plan "$PLAN" --repo-root "${BASE}/not-a-repo" --base-sha "$BASE_SHA"

wc_finish "{\"equality\":\"exit 0\",\"ancestor\":\"exit 0\",\"divergent\":\"exit 1 rule 3\",\"unresolvable_sha\":\"exit 2\",\"predicate\":\"git merge-base --is-ancestor\"}" \
  "6 assertions (A1 equal, A2 ancestor, A3 divergent, A4 non-sha, A5 unresolvable, A6 non-repo)"
