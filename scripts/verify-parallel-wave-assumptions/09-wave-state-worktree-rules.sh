#!/usr/bin/env bash
# 09 - A1..A7: the per-worktree barrier rules (schema doc s6 rules 1-4) - worktree present,
#      base_sha an ancestor of its HEAD, CLEAN including untracked, at least one commit.
#
# Load-bearing because: the merge only ever sees COMMITTED work. A chunk that edited files and
# never committed, or left a brand-new untracked file behind, merges as if it had done nothing -
# the wave goes green and the work is silently discarded when the worktree is torn down at
# barrier step (d). That is the single most expensive silent failure in the whole design, which
# is why rule 3 counts untracked files as uncleanliness rather than ignoring them.
#
# NEGATIVE CONTROL (controllable precondition): commit the stray edit / stray file before the
# check in A3 or A4 and that assertion goes RED - the expected 1 becomes a 0. A1 is the standing
# POSITIVE control that the same fixture passes when the precondition is absent.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "09-wave-state-worktree-rules"
wc_wave

STATE="${BASE}/state.json"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b1\n' >> "${WT_B}/src/b.ts"; wc_commit "$WT_B" "chunk b work"

# A1 - the clean, disjoint wave passes
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 0 "A1 clean disjoint wave" --wave-state "$STATE"
wc_expect_reason fan_out "A1 clean disjoint wave"

# A2 - a worktree that is not on disk is an ENVIRONMENT error (rule 1): exit 2, not a verdict
WT_B_REAL="$WT_B"
WT_B="${BASE}/wt/vanished"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 2 "A2 missing worktree" --wave-state "$STATE"
wc_out_has "vanished" "A2 missing worktree"
WT_B="$WT_B_REAL"

# A3 - a TRACKED uncommitted edit
printf 'uncommitted\n' >> "${WT_A}/src/a.ts"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 1 "A3 tracked-dirty worktree" --wave-state "$STATE"
wc_expect_reason dirty_repo_root "A3 tracked-dirty worktree"
wc_out_has "uncommitted work" "A3 tracked-dirty worktree"
wc_out_has "chunk-a" "A3 tracked-dirty worktree"
g "$WT_A" checkout -q -- src/a.ts

# A4 - an UNTRACKED file only: still unfinished work the merge would drop
printf 'scratch\n' > "${WT_A}/src/scratch.ts"
wc_check 1 "A4 untracked-only worktree" --wave-state "$STATE"
wc_expect_reason dirty_repo_root "A4 untracked-only worktree"
wc_out_has "src/scratch.ts" "A4 untracked-only worktree"
rm -f "${WT_A}/src/scratch.ts"

# A4b - POSITIVE control: with the stray file gone the identical state passes again
wc_check 0 "A4b clean again" --wave-state "$STATE"

# A5 - a worktree with NO commit beyond base_sha produced nothing to merge (rule 4)
BR_C="w1-fixture-chunk-c"
WT_C="${BASE}/wt/chunk-c"
g "$REPO" worktree add -q -b "$BR_C" "$WT_C" "$BASE_SHA"
BR_B_REAL="$BR_B"; WT_B_REAL="$WT_B"
BR_B="$BR_C"; WT_B="$WT_C"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 1 "A5 zero-commit worktree" --wave-state "$STATE"
wc_expect_reason rule_violation "A5 zero-commit worktree"
wc_out_has "wave-state rule 4" "A5 zero-commit worktree"
BR_B="$BR_B_REAL"; WT_B="$WT_B_REAL"

# A6 - a worktree whose HEAD does not descend from base_sha is on a different history (rule 2)
g "$WT_A" checkout -q --orphan orphan-branch
wc_commit "$WT_A" "orphan root commit"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 1 "A6 worktree off the base history" --wave-state "$STATE"
wc_expect_reason rule_violation "A6 worktree off the base history"
wc_out_has "wave-state rule 2" "A6 worktree off the base history"

# A7 - a state file that is not structurally a wave_state cannot have rules 1-11 evaluated at
#      all, so it is an INPUT error (exit 2) - the same class as unreadable or unparseable.
printf 'not json at all\n' > "${BASE}/corrupt.json"
wc_check 2 "A7 unparseable state" --wave-state "${BASE}/corrupt.json"
printf '{"repo_root":"%s","base_sha":"%s","wave":1}\n' "$REPO" "$BASE_SHA" > "${BASE}/incomplete.json"
wc_check 2 "A7b state missing required keys" --wave-state "${BASE}/incomplete.json"
wc_check 2 "A7c state file absent" --wave-state "${BASE}/nope.json"

wc_finish '{"clean":"exit 0","missing_worktree":"exit 2","tracked_dirty":"exit 1 dirty_repo_root","untracked_only":"exit 1 dirty_repo_root","zero_commit":"exit 1 malformed","off_history":"exit 1 malformed","corrupt_state":"exit 2"}' \
  "9 assertions (A1 clean, A2 missing, A3 tracked-dirty, A4/A4b untracked, A5 zero-commit, A6 off-history, A7-A7c input errors)"
