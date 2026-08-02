#!/usr/bin/env bash
# 14 - A1..A6: merge-wave.sh REFUSES loudly and merges nothing when the gate is red, and the
#      untracked-collision refusal - where git declines BEFORE starting, so no merge is in
#      progress and `git merge --abort` must NOT be run (proven by dentall assumption test
#      scripts/parallelizer-assumptions/03-merge-wave-failure-semantics.sh, A1/A2).
#
# Load-bearing because: the untracked collision is the one failure that arrives through a
# PASSING checker. Rule 11 is deliberately tracked-only (Divergence 9), so an untracked file in
# the integration checkout does not refuse a wave - it refuses a MERGE, at the merge, with git's
# own error naming the file. If merge-wave blanket-aborted here it would stack a second,
# confusing error on top of a perfectly clear one; if it swallowed the failure, the file's
# contents would look merged and would not be.
# The same case proves the incremental promise end to end: chunk-a's merge SURVIVES chunk-b's
# refusal, the tree sits clean at that tip, and re-running after the obstacle is cleared resumes.
#
# NEGATIVE CONTROL (controllable precondition): delete the untracked src/new.ts before A3 and
# that assertion goes RED - the merge succeeds and the expected nonzero exit becomes 0. (A5 runs
# exactly that removal as the POSITIVE control.)
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "14-merge-wave-refusal-and-resume"
wc_wave

STATE="${BASE}/state.json"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b1\n' >> "${WT_B}/src/b.ts"
printf 'from-chunk-b\n' > "${WT_B}/src/new.ts"
wc_commit "$WT_B" "chunk b work plus a new file"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts","src/new.ts"]' '[]'
GITDIR="$(g "$REPO" rev-parse --absolute-git-dir)"
merged_count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["merged_chunks"]))' "$STATE"; }

# A1 - a RED checker means nothing is merged at all (a dirty chunk worktree, s6 rule 3)
printf 'uncommitted\n' >> "${WT_A}/src/a.ts"
wc_merge 1 1 "A1 checker red" "$STATE"   # 1 event: the checker's own; merge-wave adds none
wc_out_has "MERGED NOTHING" "A1 checker red"
[ "$(g "$REPO" rev-parse HEAD)" = "$BASE_SHA" ] || wc_fail "A1: HEAD moved despite a red checker"
[ "$(merged_count)" = "0" ] || wc_fail "A1: merged_chunks was written despite a red checker"
g "$WT_A" checkout -q -- src/a.ts

# A2 - a corrupt state file refuses BEFORE any merge (exit 2)
printf '{"repo_root": "truncated"\n' > "${BASE}/corrupt.json"
wc_merge 2 1 "A2 corrupt state" "${BASE}/corrupt.json"
[ "$(g "$REPO" rev-parse HEAD)" = "$BASE_SHA" ] || wc_fail "A2: HEAD moved on a corrupt state file"
OUT="$(bash "$MERGE_WAVE" "${BASE}/does-not-exist.json" 2>&1)"; RC=$?
[ "$RC" = "2" ] || wc_fail "A2b: an absent state file should exit 2, got ${RC}"

# A3 - untracked collision: chunk-a merges, chunk-b is REFUSED before the merge starts
printf 'local-untracked\n' > "${REPO}/src/new.ts"
wc_check 0 "A3 checker tolerates an untracked repo_root file" --wave-state "$STATE"
wc_merge 1 2 "A3 untracked collision" "$STATE"
wc_out_has "src/new.ts" "A3 untracked collision"
wc_out_has "not running" "A3 untracked collision"
[ ! -f "${GITDIR}/MERGE_HEAD" ] || wc_fail "A3: MERGE_HEAD exists - the merge partially started"
[ "$(cat "${REPO}/src/new.ts")" = "local-untracked" ] || wc_fail "A3: untracked content was clobbered"

# A4 - the earlier merge SURVIVES, the tree is clean at that tip, and the state records exactly it
[ "$(merged_count)" = "1" ] || wc_fail "A4: expected exactly chunk-a recorded, got $(merged_count)"
TIP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["merged_chunks"][0]["merge_sha"])' "$STATE")"
[ "$(g "$REPO" rev-parse HEAD)" = "$TIP" ] || wc_fail "A4: HEAD is not at the last successful merge tip"
[ -z "$(g "$REPO" status --porcelain --untracked-files=no)" ] || wc_fail "A4: tree is not clean after the refusal"
grep -q 'a1' "${REPO}/src/a.ts" || wc_fail "A4: chunk-a's merged content did not survive"

# A5 - POSITIVE control + resume: clear the obstacle and re-run; only chunk-b merges
rm -f "${REPO}/src/new.ts"
wc_merge 0 2 "A5 resume after clearing the obstacle" "$STATE"
wc_out_has "skip chunk-a" "A5 resume after clearing the obstacle"
[ "$(merged_count)" = "2" ] || wc_fail "A5: expected both chunks recorded after the resume"
[ "$(cat "${REPO}/src/new.ts")" = "from-chunk-b" ] || wc_fail "A5: chunk-b's file did not land on resume"

# A6 - the wave-state the resume produced re-verifies clean
wc_check 0 "A6 final state re-verifies" --wave-state "$STATE"

wc_finish '{"checker_red":"exit 1, nothing merged","corrupt_state":"exit 2, nothing merged","untracked_collision":"nonzero, no MERGE_HEAD, no abort attempted, content preserved","partial_wave":"clean at the last successful merge tip","resume":"merges only what is missing"}' \
  "8 assertions (A1 checker red, A2/A2b corrupt+absent, A3 untracked refusal, A4 partial-wave tip, A5 resume, A6 re-verify)"
