#!/usr/bin/env bash
# 13 - A1..A7: merge-wave.sh's normal path - inline re-verification, --no-ff merges in DECLARED
#      order, {id, merge_sha} recorded back into the wave-state, and a re-run that RESUMES
#      instead of repeating (plan pseudocode "merge-wave.sh (INCREMENTAL with resume)").
#
# Load-bearing because: the recorded merge_sha is the only thing that makes an interrupted wave
# recoverable. If it were the BRANCH TIP instead of the merge commit, the checker's rule 10 would
# reject the very tree merge-wave just produced and every partial wave would need a human. If the
# skip list were not consulted, a re-run would merge an already-merged branch a second time. And
# the merges must be --no-ff: a fast-forward would leave HEAD at a branch tip that rule 10 has no
# way to recognise.
#
# NEGATIVE CONTROL (controllable precondition): blank merged_chunks[] before the re-run in A5 and
# that assertion goes RED - merge-wave stops skipping and reports 2 merged instead of 0.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "13-merge-wave-happy-resume"
wc_wave

STATE="${BASE}/state.json"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b1\n' >> "${WT_B}/src/b.ts"; wc_commit "$WT_B" "chunk b work"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'

state_q() { python3 -c '
import json, sys
st = json.load(open(sys.argv[1]))
if sys.argv[2] == "ids":     print(",".join(m["id"] for m in st["merged_chunks"]))
elif sys.argv[2] == "shas":  print(",".join(m["merge_sha"] for m in st["merged_chunks"]))
elif sys.argv[2] == "count": print(len(st["merged_chunks"]))
' "$STATE" "$1"; }

# A1 - the wave integrates: exit 0, and TWO events (the inline checker run + the outcome event)
wc_merge 0 2 "A1 happy path" "$STATE"
wc_out_has "chunk-a" "A1 happy path"
wc_out_has "chunk-b" "A1 happy path"

# A2 - both chunks recorded, in DECLARED order
[ "$(state_q ids)" = "chunk-a,chunk-b" ] || wc_fail "A2: merged_chunks should be chunk-a,chunk-b - got '$(state_q ids)'"

# A3 - each recorded sha is a real MERGE COMMIT (two parents), not a branch tip
IDX=1
for sha in $(state_q shas | tr ',' ' '); do
  PARENTS="$(g "$REPO" rev-list --parents -n 1 "$sha" | wc -w | tr -d ' ')"
  [ "$PARENTS" = "3" ] || wc_fail "A3: recorded sha ${IDX} (${sha}) has $((PARENTS - 1)) parent(s); a --no-ff merge commit has 2"
  IDX=$((IDX + 1))
done
LAST_SHA="$(state_q shas | sed 's/.*,//')"
[ "$(g "$REPO" rev-parse HEAD)" = "$LAST_SHA" ] || wc_fail "A3: repo HEAD is not the last recorded merge_sha"

# A4 - the content of both chunks actually landed
grep -q 'a1' "${REPO}/src/a.ts" || wc_fail "A4: chunk-a's change is not in the integrated tree"
grep -q 'b1' "${REPO}/src/b.ts" || wc_fail "A4: chunk-b's change is not in the integrated tree"
[ -z "$(g "$REPO" status --porcelain)" ] || wc_fail "A4: repo_root is not clean after a successful wave"

# A5 - the checker ACCEPTS the tree merge-wave just produced (rule 10 resume acceptance)
wc_check 0 "A5 post-merge state re-verifies" --wave-state "$STATE"

# A6 - a re-run RESUMES: nothing merged again, no new commits, same HEAD
HEAD_BEFORE="$(g "$REPO" rev-parse HEAD)"
wc_merge 0 2 "A6 resume re-run" "$STATE"
wc_out_has "skip chunk-a" "A6 resume re-run"
wc_out_has "skip chunk-b" "A6 resume re-run"
[ "$(g "$REPO" rev-parse HEAD)" = "$HEAD_BEFORE" ] || wc_fail "A6: a re-run moved HEAD"
[ "$(state_q count)" = "2" ] || wc_fail "A6: a re-run duplicated merged_chunks entries"

# A7 - merge-wave NEVER tears down: worktrees and branches survive for barrier step (d)
[ -d "$WT_A" ] && [ -d "$WT_B" ] || wc_fail "A7: merge-wave removed a worktree"
g "$REPO" rev-parse --verify -q "$BR_A" >/dev/null || wc_fail "A7: merge-wave deleted branch ${BR_A}"
g "$REPO" rev-parse --verify -q "$BR_B" >/dev/null || wc_fail "A7: merge-wave deleted branch ${BR_B}"

# A8 - usage: no argument at all is a loud refusal, not a no-op
OUT="$(bash "$MERGE_WAVE" 2>&1)"; RC=$?
[ "$RC" = "2" ] || wc_fail "A8: merge-wave with no argument should exit 2, got ${RC}"
printf '%s' "$OUT" | grep -qF 'usage' || wc_fail "A8: merge-wave printed no usage line"

wc_finish '{"merges":"--no-ff in declared order","records":"{id, merge_sha} = the MERGE COMMIT","resume":"skips ids in merged_chunks[]","teardown":"never","events_per_run":2}' \
  "8 assertions (A1 integrate, A2 order, A3 merge commits, A4 content, A5 re-verify, A6 resume, A7 no teardown, A8 usage)"
