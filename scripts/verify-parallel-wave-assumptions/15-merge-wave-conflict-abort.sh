#!/usr/bin/env bash
# 15 - A1..A6: a genuine CONTENT conflict at merge time - `git merge --abort` runs (a merge IS
#      in progress here, unlike case 14), the tree lands CLEAN at the last successful merge tip,
#      and nothing about the recorded state changes. Mirrors dentall assumption test
#      scripts/parallelizer-assumptions/03-merge-wave-failure-semantics.sh A3.
#
# HOW THIS SHAPE IS REACHED, stated plainly: a conflict cannot arise from a wave the checker
# validated - if two chunks touched the same file, rules 6/7/8 would have refused before any
# merge. The plan calls a conflict after a passed checker "a checker hole", and this case builds
# exactly that hole on purpose: `merged_chunks` records a merge_sha that the checker accepts as
# HEAD (rule 10 compares SHAs, it does not verify WHICH branch produced them), while that merge
# commit actually carries an unrelated change to the file chunk-b is about to bring in. The
# fixture is contrived; the failure path it exercises is the real one the barrier depends on.
#
# Load-bearing because: when the hole is hit in the field, the operator's next move depends
# entirely on the state merge-wave leaves behind. A clean tree at a known tip with an accurate
# merged_chunks list is a serial fix plus a resume. A half-merged tree with conflict markers in
# it, or a state file claiming a merge that never happened, is an incident.
#
# NEGATIVE CONTROL (controllable precondition): give the rogue branch a DIFFERENT file to touch
# (src/shared.ts) and A2 goes RED - the merge succeeds and the expected nonzero exit becomes 0.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "15-merge-wave-conflict-abort"
wc_wave

STATE="${BASE}/state.json"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b0\nb1-from-chunk-b\n' > "${WT_B}/src/b.ts"; wc_commit "$WT_B" "chunk b work"

# The integration checkout is advanced by a REAL merge commit that touches src/b.ts.
g "$REPO" checkout -q -b rogue "$BASE_SHA"
printf 'rogue-version\n' > "${REPO}/src/b.ts"
wc_commit "$REPO" "an unrelated change to src/b.ts"
g "$REPO" checkout -q main
g "$REPO" merge --no-ff -q -m "wave 1: merge chunk-a" rogue
TIP="$(g "$REPO" rev-parse HEAD)"
GITDIR="$(g "$REPO" rev-parse --absolute-git-dir)"
merged_count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["merged_chunks"]))' "$STATE"; }

wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' 'null' \
  "[{\"id\":\"chunk-a\",\"merge_sha\":\"${TIP}\"}]"

# A1 - the checker passes: HEAD is a recorded merge_sha and every per-chunk rule holds. This IS
#      the hole, asserted rather than assumed, so a future checker that closes it fails HERE and
#      the operator is told which case to update instead of finding out at a merge.
wc_check 0 "A1 checker passes on the hole shape" --wave-state "$STATE"

# A2 - the merge conflicts: nonzero, with the checker's event plus the outcome event
wc_merge 1 2 "A2 conflict" "$STATE"
wc_out_has "MERGE FAILED" "A2 conflict"
wc_out_has "chunk-b" "A2 conflict"

# A3 - the abort ran, which is only reachable when MERGE_HEAD existed (case 14 proves the other
#      branch of that conditional)
wc_out_has "aborted the in-progress merge" "A2 conflict abort branch"
[ ! -f "${GITDIR}/MERGE_HEAD" ] || wc_fail "A3: MERGE_HEAD survived - the merge was left in progress"

# A4 - the tree is CLEAN at the last successful merge tip, with no conflict markers on disk
[ "$(g "$REPO" rev-parse HEAD)" = "$TIP" ] || wc_fail "A4: HEAD is not at the last successful merge tip"
[ -z "$(g "$REPO" status --porcelain)" ] || wc_fail "A4: tree is not clean after the abort"
grep -q '<<<<<<<' "${REPO}/src/b.ts" && wc_fail "A4: conflict markers were left in src/b.ts"
[ "$(cat "${REPO}/src/b.ts")" = "rogue-version" ] || wc_fail "A4: src/b.ts is not the pre-merge content"

# A5 - the state file is untouched by a failed merge: nothing was recorded that did not happen
[ "$(merged_count)" = "1" ] || wc_fail "A5: merged_chunks changed on a failed merge (got $(merged_count))"

# A6 - the failure is REPEATABLE, not a one-shot corruption: re-running fails the same way and
#      leaves the same tip, which is what makes "serial-fix then resume" a real recovery.
wc_merge 1 2 "A6 repeat conflict" "$STATE"
[ "$(g "$REPO" rev-parse HEAD)" = "$TIP" ] || wc_fail "A6: a repeat run moved HEAD"
[ "$(merged_count)" = "1" ] || wc_fail "A6: a repeat run changed merged_chunks"

wc_finish '{"conflict":"exit 1","abort":"only when MERGE_HEAD exists","tree":"clean at the last successful merge tip","state":"unchanged on failure","repeatable":true,"shape":"deliberate checker hole (rule 10 compares SHAs, not provenance)"}' \
  "7 assertions (A1 hole passes, A2 conflict, A3 abort ran, A4 clean tip, A5 state intact, A6 repeatable)"
