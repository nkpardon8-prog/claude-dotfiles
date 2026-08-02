#!/usr/bin/env bash
# 07 - A1..A9: post_integration_commands - metacharacter rejection, argv-prefix allowlist, and
#      the typecheck floor (schema doc s2.4, s4 rule 11).
#
# Load-bearing because: these commands come out of a MODEL and are then run, by the
# orchestrator, at the integration barrier. Stage 1 exists so nothing a shell would reinterpret
# ever reaches that point; stage 2 exists so the barrier can only run things the repo already
# defines. The typecheck floor is the other half: a wave that merges four chunks and runs
# nothing that can FAIL is not a barrier at all, it is a green light with no gate behind it.
#
# NEGATIVE CONTROL (controllable precondition): swap the offending command for
# "npm run typecheck" in any of A1/A2/A3/A4 and that assertion goes RED - the reject becomes 0.
# A5/A6/A8 are the standing POSITIVE controls.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "07-validate-plan-command-allowlist"
wc_wave   # package.json declares scripts: typecheck, test

PLAN="${BASE}/plan.json"
MUT="${BASE}/mutant.json"
wc_plan golden-wave-plan.json "$PLAN"

cmd_case() {  # cmd_case <expected-exit> <label> <python list literal>
  wc_mutate "$PLAN" "$MUT" "p['waves'][0]['post_integration_commands'] = $3"
  wc_check "$1" "$2" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
}

# A1 - stage 1: shell metacharacters, with no quoting escape hatch
cmd_case 1 "A1 chained with &&" "['npm run typecheck && echo done']"
wc_out_has "plan rule 11" "A1 chained with &&"
cmd_case 1 "A2 redirection" "['npm run typecheck > out.txt']"
cmd_case 1 "A2b command substitution" "['npm run ' + chr(96) + 'echo typecheck' + chr(96)]"

# A3 - stage 2: an argv prefix that is not on the list
cmd_case 1 "A3 non-allowlisted argv" "['rm -rf tmp', 'npm run typecheck']"
wc_out_has "allowlist" "A3 non-allowlisted argv"

# A4 - stage 2: npm run <script> must name a key that actually exists in package.json
cmd_case 1 "A4 unknown npm script" "['npm run nosuchscript']"
wc_out_has "nosuchscript" "A4 unknown npm script"

# A5 - the typecheck floor: the repo declares typecheck/test, so a wave that runs neither fails
cmd_case 1 "A5 typecheck floor unmet" "['make build']"
wc_out_has "typecheck-class" "A5 typecheck floor unmet"

# A6 - POSITIVE control: floor met, plus an allowlisted assumption-suite command
cmd_case 0 "A6 suite plus typecheck" "['bash scripts/wavefix-assumptions/run-all.sh', 'npm run typecheck']"

# A7 - POSITIVE control: the remaining allowlist arms, with the floor met by npm run test
cmd_case 0 "A7 npx tsc / node --check / make" "['npx tsc --noEmit', 'node --check src/a.mjs', 'make build', 'npm run test']"

# A8 - post_integration_commands must be non-empty (rule 11 / s3.3)
cmd_case 1 "A8 empty command list" "[]"

# A9 - NO package.json at repo_root: the npm|yarn|pnpm arm never matches and the floor does not
#      apply, so the bash-suite arm alone is a complete barrier (s2.4, last paragraph).
REPO2="${BASE}/repo2"
wc_repo "$REPO2" ""
SHA_R2="$(g "$REPO2" rev-parse HEAD)"
wc_mutate "$PLAN" "$MUT" "p['analysis_basis']['repo_root'] = '${REPO2}'
p['analysis_basis']['base_sha'] = '${SHA_R2}'
p['waves'][0]['post_integration_commands'] = ['bash scripts/wavefix-assumptions/run-all.sh']"
wc_check 0 "A9 no package.json" --validate-plan "$MUT" --repo-root "$REPO2" --base-sha "$SHA_R2"

wc_mutate "$PLAN" "$MUT" "p['analysis_basis']['repo_root'] = '${REPO2}'
p['analysis_basis']['base_sha'] = '${SHA_R2}'
p['waves'][0]['post_integration_commands'] = ['npm run typecheck']"
wc_check 1 "A9b no package.json means no npm arm" --validate-plan "$MUT" --repo-root "$REPO2" --base-sha "$SHA_R2"

wc_finish '{"stage1":"; | & $ ` > < newline","stage2":"npm|yarn|pnpm run <declared script> | npx tsc | node --check | bash scripts/<x>-assumptions/run-all.sh | make <target>","floor":"typecheck|tsc|lint|check|test","no_package_json":"floor n/a, npm arm dead"}' \
  "10 assertions (A1-A2b stage 1, A3/A4 stage 2, A5 floor, A6/A7 positive controls, A8 non-empty, A9/A9b no package.json)"
