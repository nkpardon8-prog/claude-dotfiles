#!/usr/bin/env bash
# 10 - A1..A9: what the chunks ACTUALLY touched (schema doc s6 rules 5-9) - the post-hoc half
#      of the safety argument, measured with `git diff --name-only --no-renames -z base..HEAD`.
#
# Load-bearing because: rules 6-10 of --validate-plan check what a MODEL PROMISED. These rules
# check what four subagents DID, in four separate worktrees, before anything is merged. A chunk
# that wandered outside its fence is the exact failure the wave design cannot otherwise see: the
# merge succeeds (different files!), the barrier goes green, and a file nobody assigned has been
# rewritten by a worker who never read the rest of the change.
#
# `--no-renames` is pinned on purpose: with rename detection ON, moving src/a.ts to src/a2.ts is
# reported as ONE path, so a chunk could move a file OUT of a sibling's declared set and the
# destination would never appear in `touched`. Both sides must count (A6).
#
# NEGATIVE CONTROL (controllable precondition): declare the offending path in the chunk's
# exclusive_paths (A2/A3/A6) or drop it from the sibling's reads (A9) and that assertion goes
# RED - the expected 1 becomes a 0. A1, A6b and A7 are the standing POSITIVE controls.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "10-wave-state-touched-rules"
wc_wave

STATE="${BASE}/state.json"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b1\n' >> "${WT_B}/src/b.ts"; wc_commit "$WT_B" "chunk b work"
SHA_A0="$(g "$WT_A" rev-parse HEAD)"
SHA_B0="$(g "$WT_B" rev-parse HEAD)"
reset_a() { g "$WT_A" reset --hard "$SHA_A0" >/dev/null 2>&1; }
reset_b() { g "$WT_B" reset --hard "$SHA_B0" >/dev/null 2>&1; }

# A1 - POSITIVE control: touched == declared
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 0 "A1 touched within declared" --wave-state "$STATE"

# A2 - rule 6: a write outside the chunk's own declared set
printf 'stray\n' >> "${WT_A}/src/shared.ts"; wc_commit "$WT_A" "chunk a strayed"
wc_check 1 "A2 undeclared write" --wave-state "$STATE"
wc_expect_reason malformed "A2 undeclared write"
wc_out_has "wave-state rule 6" "A2 undeclared write"
wc_out_has "src/shared.ts" "A2 undeclared write"
wc_out_has "chunk-a" "A2 undeclared write"
reset_a

# A3 - rule 6 again, and the case that matters most: A wrote into B's DECLARED path
printf 'trespass\n' >> "${WT_A}/src/b.ts"; wc_commit "$WT_A" "chunk a wrote chunk b's file"
wc_check 1 "A3 A writes B's declared path" --wave-state "$STATE"
wc_out_has "wave-state rule 6" "A3 A writes B's declared path"
wc_out_has "src/b.ts" "A3 A writes B's declared path"
reset_a

# A4 - rule 7: DECLARED sets that intersect, even when nothing touched them
wc_state "$STATE" '["src/a.ts","src/shared.ts"]' '[]' '["src/b.ts","src/shared.ts"]' '[]'
wc_check 1 "A4 declared intersection" --wave-state "$STATE"
wc_out_has "wave-state rule 7" "A4 declared intersection"
wc_out_has "src/shared.ts" "A4 declared intersection"

# A5 - rule 8: both chunks actually TOUCHED the same file. Rule 8 cannot fire alone - a file two
#      chunks both touch is either declared by both (rule 7 also fires, as here) or declared by
#      neither (rule 6 fires). The point of asserting both messages is that the ACTUAL collision
#      is reported in its own right, not merely inferred from the declarations.
printf 'both\n' >> "${WT_A}/src/shared.ts"; wc_commit "$WT_A" "a touched shared"
printf 'both\n' >> "${WT_B}/src/shared.ts"; wc_commit "$WT_B" "b touched shared"
wc_check 1 "A5 touched overlap" --wave-state "$STATE"
wc_out_has "wave-state rule 8" "A5 touched overlap"
wc_out_has "wave-state rule 7" "A5 touched overlap"
reset_a; reset_b

# A6 - rule 5: a rename counts BOTH sides
g "$WT_A" mv src/a.ts src/a2.ts
wc_commit "$WT_A" "chunk a renamed its file"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 1 "A6 rename destination is undeclared" --wave-state "$STATE"
wc_out_has "src/a2.ts" "A6 rename destination is undeclared"
# A6b - POSITIVE control: declaring BOTH sides makes the same rename legal
wc_state "$STATE" '["src/a.ts","src/a2.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 0 "A6b rename with both sides declared" --wave-state "$STATE"
reset_a

# A7 - rule 6 with a subtree prefix: it admits files CREATED under a directory absent at base
mkdir -p "${WT_B}/client/panels/nested"
printf 'x\n' > "${WT_B}/client/panels/x.ts"
printf 'y\n' > "${WT_B}/client/panels/nested/y.ts"
wc_commit "$WT_B" "chunk b created the new panel dir"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts","client/panels/"]' '[]'
wc_check 0 "A7 prefix admits new files" --wave-state "$STATE"
# A7b - the same files against an exact-only declaration are undeclared
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts","client/panels/x.ts"]' '[]'
wc_check 1 "A7b prefix removed" --wave-state "$STATE"
wc_out_has "client/panels/nested/y.ts" "A7b prefix removed"
reset_b

# A8/A9 - rule 9: what A touched is something B declared it READS
printf 'shared-edit\n' >> "${WT_A}/src/shared.ts"; wc_commit "$WT_A" "a owns shared this wave"
wc_state "$STATE" '["src/a.ts","src/shared.ts"]' '[]' '["src/b.ts"]' '["src/shared.ts"]'
wc_check 1 "A8 touched intersects sibling reads" --wave-state "$STATE"
wc_out_has "wave-state rule 9" "A8 touched intersects sibling reads"
wc_out_has "src/shared.ts" "A8 touched intersects sibling reads"
# A9 - POSITIVE control: the same write with no sibling declaring that read is legal
wc_state "$STATE" '["src/a.ts","src/shared.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 0 "A9 same write, no sibling read" --wave-state "$STATE"

wc_finish '{"probe":"git diff --name-only --no-renames -z base..HEAD","rule6":"touched subset of own declared","rule7":"declared pairwise disjoint","rule8":"touched pairwise disjoint","rule9":"touched x sibling reads","rename":"both sides counted"}' \
  "11 assertions (A1 baseline, A2/A3 rule 6, A4 rule 7, A5 rule 8, A6/A6b renames, A7/A7b prefixes, A8/A9 rule 9)"
