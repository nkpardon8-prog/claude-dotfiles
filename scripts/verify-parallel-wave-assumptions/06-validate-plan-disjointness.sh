#!/usr/bin/env bash
# 06 - A1..A7: the three declared-set disjointness rules (schema doc s2.3 overlap predicate,
#      s4 rules 8, 9, 10) - writes x writes, writes x sibling reads, writes x shared hazards.
#
# Load-bearing because: these three rules ARE the safety argument for spawning N writers at
# once. Rule 8 stops two chunks editing one file in separate worktrees (the merge would silently
# pick one, or conflict at the barrier). Rule 9 is the subtler one added by delta 2: nothing
# collides on disk, yet chunk B compiles against a version of a file chunk A is rewriting, so
# the wave integrates green and is wrong. Rule 10 keeps generated output, lockfiles, and schema
# files - the paths the repo's own conventions call hazards - out of every parallel write-set.
#
# NEGATIVE CONTROL (controllable precondition): point the colliding entry at an unrelated file
# ("src/z.ts") in any of A1/A2/A3/A5 and that assertion goes RED - the reject becomes a 0. A4
# and A6 are the standing POSITIVE controls (self-reads and near-miss names stay legal).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "06-validate-plan-disjointness"
wc_wave

PLAN="${BASE}/plan.json"
MUT="${BASE}/mutant.json"
wc_plan golden-wave-plan.json "$PLAN"

# A1 - rule 8: the same exact file claimed by both chunks
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][1]['exclusive_paths'] = ['src/b.ts', 'src/a.ts']"
wc_check 1 "A1 same file in both write-sets" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "plan rule 8" "A1 same file in both write-sets"
wc_out_has "src/a.ts" "A1 same file in both write-sets"
wc_out_has "chunk-a" "A1 same file in both write-sets"

# A2 - rule 8 via the PREFIX arm of the overlap predicate: a file under a sibling's subtree
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['exclusive_paths'] = ['client/panels/x.ts']"
wc_check 1 "A2 file under a sibling prefix" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "plan rule 8" "A2 file under a sibling prefix"

# A3 - rule 9: writes(A) intersects reads(B)
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][1]['reads'] = ['src/a.ts']"
wc_check 1 "A3 sibling reads a sibling write" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "plan rule 9" "A3 sibling reads a sibling write"

# A4 - POSITIVE control: a chunk reading its OWN write is fine (s2.3 "self-reads are fine"),
#      and reads may freely overlap each other (the golden plan already shares src/shared.ts).
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['reads'] = ['src/a.ts', 'src/shared.ts']"
wc_check 0 "A4 self-read and shared reads" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

# A5 - rule 10: a declared write over a shared hazard path
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['exclusive_paths'] = ['src/a.ts', 'package.json']"
wc_check 1 "A5 write over a shared hazard" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "plan rule 10" "A5 write over a shared hazard"
wc_out_has "package.json" "A5 write over a shared hazard"

# A6 - POSITIVE control for the EXACT-match discipline (s2.3): "src/a" never matches "src/ab",
#      so two similarly-named claims are genuinely disjoint and must NOT be flagged.
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['exclusive_paths'] = ['src/a']
p['waves'][0]['chunks'][1]['exclusive_paths'] = ['src/ab']
p['waves'][0]['chunks'][1]['reads'] = []"
wc_check 0 "A6 exact match is not a prefix match" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

# A7 - rule 9 is ORDERED: the collision is caught when it runs B-writes x A-reads too
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['reads'] = ['src/b.ts']"
wc_check 1 "A7 reverse-ordered write/read pair" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "plan rule 9" "A7 reverse-ordered write/read pair"

wc_finish '{"rule8":"writes x writes","rule9":"writes x sibling reads (ordered)","rule10":"writes x shared_hazard_paths","predicate":"a==b or prefix-of either way","self_reads":"legal"}' \
  "7 assertions (A1/A2 rule 8, A3/A7 rule 9, A4/A6 positive controls, A5 rule 10)"
