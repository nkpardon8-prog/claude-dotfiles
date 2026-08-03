#!/usr/bin/env bash
# 16 - A1..A9: the v1.1 wave-state hardening (codex-review C2/C3/C4).
#
# Load-bearing because: v1 --wave-state trusted the state file as SOLE authority. Two plan-gate
# rules (writes x shared_hazard_paths; subtree-prefix-only-over-absent-dirs) were never re-checked
# at the barrier, the branch NAME merge-wave actually merges was never proven to equal the
# verified worktree HEAD, and merged_chunks was shape-checked only. Each gap lets a hand-forged or
# drifted state walk work past the barrier that the checker never actually validated.
#
# The fix binds the runtime state to the wave_plan --validate-plan blessed (an INDEPENDENT
# <plan>.validated sidecar hash, absent/mismatch => violation), re-runs the two missing plan
# rules directly, asserts branch==verified-HEAD, and proves merged_chunks integrity.
#
# NEGATIVE CONTROL / FAIL-FIRST (each is a NEW rule): before the fix every A2..A9 assertion below
# validated 0 (rules 12-16 did not exist / the sidecar was never written). A1 is the standing
# POSITIVE control: a properly blessed, on-branch, integral state still passes.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "16-wave-state-plan-binding"
wc_wave

STATE="${BASE}/state.json"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b1\n' >> "${WT_B}/src/b.ts"; wc_commit "$WT_B" "chunk b work"

state_edit() {  # state_edit <file> <python body operating on the parsed state as `s`>
  python3 - "$1" "$2" <<'PY'
import json, sys
f, body = sys.argv[1], sys.argv[2]
s = json.load(open(f))
exec(body)
json.dump(s, open(f, "w"))
PY
}

# A1 - POSITIVE control: a blessed, on-branch, integral state passes (fan_out)
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 0 "A1 blessed state passes" --wave-state "$STATE"
wc_expect_reason fan_out "A1 blessed state passes"

# A2 - C2: NO sidecar => the state was never blessed by --validate-plan (fail-closed)
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' 'null' '[]' '[]' nosidecar
wc_check 1 "A2 sidecar absent" --wave-state "$STATE"
wc_expect_reason rule_violation "A2 sidecar absent"
wc_out_has "no validated-plan sidecar" "A2 sidecar absent"

# A3 - C2: a sidecar that does NOT bless this state's topology (the state drifted after blessing).
#      Mutating shared_hazard_paths changes the bound hash but nothing else, isolating rule 12.
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
state_edit "$STATE" 's["shared_hazard_paths"] = ["docs/only-in-state.md"]'
wc_check 1 "A3 sidecar hash mismatch" --wave-state "$STATE"
wc_expect_reason rule_violation "A3 sidecar hash mismatch"
wc_out_has "does not bless" "A3 sidecar hash mismatch"

# A3b - matching sidecar => 0 (the crisp pairing with A3): regenerate a faithful state
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
wc_check 0 "A3b matching sidecar passes" --wave-state "$STATE"

# A4 - C2 defense-in-depth: declared writes intersecting shared_hazard_paths (rule 15). A
#      hazard-intersecting topology can never earn a sidecar, so this fires alongside A2's class;
#      the point is that the BARRIER re-runs the hazard rule rather than trusting the state.
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]' 'null' '[]' '["src/a.ts"]'
wc_check 1 "A4 write intersects shared hazard" --wave-state "$STATE"
wc_out_has "wave-state rule 15" "A4 write intersects shared hazard"
wc_out_has "src/a.ts" "A4 write intersects shared hazard"

# A5 - C2 defense-in-depth: a subtree prefix over a directory that EXISTS at base_sha (rule 14).
#      src/ exists at base, so a "src/" blank cheque must be refused at the barrier too.
wc_state "$STATE" '["src/"]' '[]' '["src/b.ts"]' '[]'
wc_check 1 "A5 subtree prefix over existing dir" --wave-state "$STATE"
wc_out_has "wave-state rule 14" "A5 subtree prefix over existing dir"

# A6 - C3: the branch NAME must resolve, from repo_root, to exactly the verified worktree HEAD.
#      A branch pointing elsewhere (here: base_sha, while the worktree has advanced) is refused.
#      merged_chunks/branch are NOT in the bound hash, so the sidecar still matches - rule 13 alone.
g "$REPO" branch mismatch-branch "$BASE_SHA"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
state_edit "$STATE" 's["chunks"][0]["branch"] = "mismatch-branch"'
wc_check 1 "A6 branch != verified HEAD" --wave-state "$STATE"
wc_expect_reason rule_violation "A6 branch != verified HEAD"
wc_out_has "wave-state rule 13" "A6 branch != verified HEAD"

# A6b - C3: a branch that does not resolve at all is likewise refused
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
state_edit "$STATE" 's["chunks"][0]["branch"] = "no-such-branch-xyz"'
wc_check 1 "A6b branch unresolvable" --wave-state "$STATE"
wc_out_has "does not resolve" "A6b branch unresolvable"

# A7 - C4: merged_chunks integrity. HEAD stays at base_sha; merge_sha entries reference base_sha
#      (a real commit, trivially an ancestor of HEAD) so ONLY the targeted arm fires each time.
# A7a - a DUPLICATE id
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
state_edit "$STATE" 's["merged_chunks"] = [{"id":"chunk-a","merge_sha":s["base_sha"]},{"id":"chunk-a","merge_sha":s["base_sha"]}]'
wc_check 1 "A7a merged_chunks duplicate id" --wave-state "$STATE"
wc_out_has "appears more than once" "A7a merged_chunks duplicate id"

# A7b - a NON-MEMBER id (not a chunk in this wave)
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
state_edit "$STATE" 's["merged_chunks"] = [{"id":"chunk-ghost","merge_sha":s["base_sha"]}]'
wc_check 1 "A7b merged_chunks non-member id" --wave-state "$STATE"
wc_out_has "not a chunk in this wave" "A7b merged_chunks non-member id"

# A7c - a merge_sha that is a real commit but NOT an ancestor of repo_root HEAD
g "$REPO" checkout -q -b sidebr "$BASE_SHA"
printf 'side\n' > "${REPO}/src/side.ts"; wc_commit "$REPO" "an off-history side commit"
SIDE="$(g "$REPO" rev-parse HEAD)"
g "$REPO" checkout -q main
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
state_edit "$STATE" "s['merged_chunks'] = [{'id':'chunk-a','merge_sha':'${SIDE}'}]"
wc_check 1 "A7c merged_chunks non-ancestor sha" --wave-state "$STATE"
wc_out_has "not an ancestor" "A7c merged_chunks non-ancestor sha"

# A7d - a merge_sha that is not a commit at all (dangling 40-hex)
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'
state_edit "$STATE" 's["merged_chunks"] = [{"id":"chunk-a","merge_sha":"0123456789abcdef0123456789abcdef01234567"}]'
wc_check 1 "A7d merged_chunks dangling sha" --wave-state "$STATE"
wc_out_has "is not a commit" "A7d merged_chunks dangling sha"

# A8 - hermetic: nothing escaped the sandbox
case "$WAVES" in "${BASE}"/*) ;; *) wc_fail "A8: PARALLEL_WAVES_DIR escaped the sandbox: ${WAVES}" ;; esac

wc_finish '{"sidecar":"<wave_plan>.validated sha256 of {repo_root,shared_hazard_paths,wave,chunks[id,exclusive_paths,reads]}","absent_or_mismatch":"exit 1 rule_violation","rule13":"branch resolves from repo_root to verified worktree HEAD","rule14":"subtree prefix only over dir absent at base_sha","rule15":"writes disjoint from shared_hazard_paths","rule16":"merged_chunks unique+member+commit+ancestor"}' \
  "13 assertions (A1 blessed, A2 absent, A3/A3b mismatch, A4 hazard, A5 subtree, A6/A6b branch, A7a-A7d merged_chunks)"
