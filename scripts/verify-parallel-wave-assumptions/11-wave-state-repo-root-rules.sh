#!/usr/bin/env bash
# 11 - A1..A8: the integration-checkout rules (schema doc s6 rules 10 and 11) - repo_root HEAD
#      is base_sha or a RECORDED merge commit, and repo_root is TRACKED-clean except for
#      impl_plan_path when that path resolves under repo_root.
#
# Load-bearing because: rule 10 is what makes an interrupted merge RESUMABLE instead of a
# refusal. merge-wave.sh re-verifies inline before every merge, so after chunk 1 lands the tree
# is legitimately ahead of base_sha; a naive "HEAD must equal base_sha" would turn every partial
# wave into a dead end. Comparing against the recorded MERGE COMMITS (not the branch tips) is
# what keeps that narrow: HEAD may only be somewhere this machinery put it.
# Rule 11 is scoped to TRACKED changes by Divergence 9 - an untracked scratch file in the
# integration checkout is not a reason to refuse a wave - and the plan file itself is exempt
# only when it lives under the repo being integrated.
#
# NEGATIVE CONTROL (controllable precondition): drop the merged_chunks entry in A2 and that
# assertion goes RED (HEAD is then unexplained -> exit 1); restore the plan file before A5 and
# A5 goes RED the other way. A1/A2/A5/A8 are the standing POSITIVE controls.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "11-wave-state-repo-root-rules"
wc_wave

STATE="${BASE}/state.json"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b1\n' >> "${WT_B}/src/b.ts"; wc_commit "$WT_B" "chunk b work"

# A1 - HEAD at base_sha, tree clean
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 0 "A1 HEAD at base_sha" --wave-state "$STATE"

# A2 - HEAD at a RECORDED merge commit is accepted: this is the resume case
g "$REPO" merge --no-ff -q -m "wave 1: merge chunk-a" "$BR_A"
MERGE_SHA="$(g "$REPO" rev-parse HEAD)"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' 'null' \
  "[{\"id\":\"chunk-a\",\"merge_sha\":\"${MERGE_SHA}\"}]"
wc_check 0 "A2 HEAD at a recorded merge_sha" --wave-state "$STATE"

# A3 - the SAME HEAD with nothing recorded is unexplained
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 1 "A3 unrecorded HEAD" --wave-state "$STATE"
wc_expect_reason dirty_repo_root "A3 unrecorded HEAD"
wc_out_has "wave-state rule 10" "A3 unrecorded HEAD"

# A4 - HEAD somewhere else entirely (a hand commit in the integration checkout)
printf 'hand\n' >> "${REPO}/src/shared.ts"
wc_commit "$REPO" "a hand commit nobody recorded"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' 'null' \
  "[{\"id\":\"chunk-a\",\"merge_sha\":\"${MERGE_SHA}\"}]"
wc_check 1 "A4 HEAD moved past the recorded merge" --wave-state "$STATE"
wc_out_has "wave-state rule 10" "A4 HEAD moved past the recorded merge"
g "$REPO" reset --hard -q "$MERGE_SHA"

# A5 - tracked-dirty repo_root, no exemption in play
printf 'dirty\n' >> "${REPO}/src/shared.ts"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' 'null' \
  "[{\"id\":\"chunk-a\",\"merge_sha\":\"${MERGE_SHA}\"}]"
wc_check 1 "A5 tracked-dirty repo_root" --wave-state "$STATE"
wc_expect_reason dirty_repo_root "A5 tracked-dirty repo_root"
wc_out_has "wave-state rule 11" "A5 tracked-dirty repo_root"
g "$REPO" checkout -q -- src/shared.ts

# A6 - dirty ONLY at impl_plan_path, and that path is UNDER repo_root: exempt
printf '\n- progress note\n' >> "${REPO}/impl-plan.md"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' "\"${REPO}/impl-plan.md\"" \
  "[{\"id\":\"chunk-a\",\"merge_sha\":\"${MERGE_SHA}\"}]"
wc_check 0 "A6 impl_plan_path exemption" --wave-state "$STATE"

# A7 - the identical dirt with impl_plan_path OUTSIDE repo_root: no exemption (s5)
printf '# elsewhere\n' > "${BASE}/outside-plan.md"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' "\"${BASE}/outside-plan.md\"" \
  "[{\"id\":\"chunk-a\",\"merge_sha\":\"${MERGE_SHA}\"}]"
wc_check 1 "A7 impl_plan_path outside repo_root" --wave-state "$STATE"
wc_expect_reason dirty_repo_root "A7 impl_plan_path outside repo_root"
wc_out_has "no exemption" "A7 impl_plan_path outside repo_root"
wc_out_has "impl-plan.md" "A7 impl_plan_path outside repo_root"

# A7b - null impl_plan_path is likewise no exemption
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' 'null' \
  "[{\"id\":\"chunk-a\",\"merge_sha\":\"${MERGE_SHA}\"}]"
wc_check 1 "A7b null impl_plan_path" --wave-state "$STATE"
g "$REPO" checkout -q -- impl-plan.md

# A8 - rule 11 is TRACKED-only (Divergence 9): an untracked scratch file does not refuse a wave
printf 'scratch\n' > "${REPO}/scratch.txt"
wc_check 0 "A8 untracked file in repo_root" --wave-state "$STATE"
rm -f "${REPO}/scratch.txt"

wc_finish '{"rule10":"HEAD in {base_sha} + merged_chunks[].merge_sha","rule11":"git status --porcelain --untracked-files=no","exemption":"impl_plan_path only when under repo_root","untracked_root":"tolerated"}' \
  "9 assertions (A1/A2 rule 10 accept, A3/A4 rule 10 reject, A5 rule 11, A6 exemption, A7/A7b no exemption, A8 tracked-only)"
