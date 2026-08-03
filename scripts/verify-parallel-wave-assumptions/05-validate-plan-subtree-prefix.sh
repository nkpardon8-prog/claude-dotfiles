#!/usr/bin/env bash
# 05 - A1..A5: subtree prefixes are admissible ONLY over a directory ABSENT at the wave's sha,
#      and the rule is evaluated at the PASSED sha (schema doc s2.3 Divergence 7, s4 rule 7).
#
# Load-bearing because: a trailing-"/" entry over an EXISTING directory is a blank cheque over
# files nobody enumerated - "src/" quietly authorizes rewriting every file a sibling might also
# touch, and the disjointness check still says yes. Over a directory that does not exist yet,
# the same entry authorizes only files this chunk is about to CREATE, which is the bounded case
# the divergence was written for. Because base_sha is re-pinned every wave, the same plan text
# must be re-judged at the NEW sha: a directory created by wave 1 makes wave 2's prefix illegal.
#
# NEGATIVE CONTROL (controllable precondition): pass BASE_SHA instead of SHA2 in A3 and the
# assertion goes RED - the prefix is legal at the older sha, so the expected reject becomes 0.
# (A3b runs exactly that comparison as a POSITIVE control in the same case.)
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "05-validate-plan-subtree-prefix"
wc_wave

PLAN="${BASE}/plan.json"
MUT="${BASE}/mutant.json"
wc_plan golden-wave-plan.json "$PLAN"

# A1 - the golden plan's "client/panels/" is admissible: that directory is absent at base_sha
wc_check 0 "A1 prefix over an absent dir" --validate-plan "$PLAN" --repo-root "$REPO" --base-sha "$BASE_SHA"

# A2 - a prefix over a directory that EXISTS at base_sha is rejected
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['exclusive_paths'] = ['src/']
p['waves'][0]['chunks'][1]['exclusive_paths'] = ['client/panels/']
p['waves'][0]['chunks'][1]['reads'] = []"
wc_check 1 "A2 prefix over an existing dir" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_expect_reason rule_violation "A2 prefix over an existing dir"
wc_out_has "plan rule 7" "A2 prefix over an existing dir"

# A directory that appears AFTER base_sha - exactly what a merged earlier wave produces.
mkdir -p "${REPO}/docs"
printf 'guide\n' > "${REPO}/docs/guide.md"
wc_commit "$REPO" "wave 1 created docs/"
SHA2="$(g "$REPO" rev-parse HEAD)"

wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['exclusive_paths'] = ['docs/']
p['waves'][0]['chunks'][0]['reads'] = []"

# A3 - re-validated at the RE-PINNED sha, the same plan text is now illegal
wc_check 1 "A3 prefix judged at the passed sha" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$SHA2"
wc_out_has "plan rule 7" "A3 prefix judged at the passed sha"
wc_out_has "$SHA2" "A3 prefix judged at the passed sha"

# A3b - POSITIVE control: the identical file is accepted at the OLDER sha, where docs/ is absent
wc_check 0 "A3b same plan at the older sha" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

# A4 - shared_hazard_paths prefixes are existence-UNBOUNDED (s3.2): a hazard prefix over an
#      existing directory is legal, because a hazard is a fence, not a write claim.
wc_mutate "$PLAN" "$MUT" "p['analysis_basis']['shared_hazard_paths'] = ['docs/', 'package.json']"
wc_check 0 "A4 hazard prefix over an existing dir" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$SHA2"

# A5 - a prefix naming a path that exists as a FILE at the sha is likewise rejected
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['exclusive_paths'] = ['src/a.ts/']"
wc_check 1 "A5 prefix over an existing file path" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

wc_finish "{\"absent_dir\":\"exit 0\",\"existing_dir\":\"exit 1 rule 7\",\"evaluated_at\":\"the PASSED sha\",\"hazard_prefix\":\"existence-unbounded\",\"probe\":\"git ls-tree -z <sha> -- <dir>\"}" \
  "6 assertions (A1 absent, A2 existing, A3/A3b passed-sha evaluation, A4 hazard unbounded, A5 file path)"
