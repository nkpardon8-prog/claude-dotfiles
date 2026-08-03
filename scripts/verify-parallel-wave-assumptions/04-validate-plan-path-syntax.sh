#!/usr/bin/env bash
# 04 - A1..A10: path syntax for exclusive_paths / reads / shared_hazard_paths
#      (schema doc s2.2, s4 rule 6).
#
# Load-bearing because: every disjointness rule in the whole system is STRING comparison over
# these entries. An entry the checker cannot compare honestly - "../etc", "/abs", "src/*.ts",
# "a//b" - is not a narrower claim, it is an UNCHECKABLE one: it silently matches nothing, so a
# chunk that writes outside its fence looks compliant. Rejecting the syntax up front is what
# keeps "touched is a subset of declared" a real statement.
#
# RESOLUTION recorded (plan text vs schema): the plan's Task-7 case list called "./y" a
# violation; docs/wave-plan-schema.md s2.2 NORMALIZES a "./" prefix away and only rejects what
# is empty or "." AFTER normalization. The schema doc is the sole authority (its header says
# so), so A3 asserts "./src/a.ts" is ACCEPTED and normalized to "src/a.ts".
#
# NEGATIVE CONTROL (controllable precondition): replace the offending entry with a legal one
# ("src/a.ts") in any of A1/A2/A4..A10 and that assertion goes RED - the reject becomes a 0.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "04-validate-plan-path-syntax"
wc_wave

PLAN="${BASE}/plan.json"
MUT="${BASE}/mutant.json"
wc_plan golden-wave-plan.json "$PLAN"

writes_case() {  # writes_case <expected-exit> <label> <python list literal>
  wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['exclusive_paths'] = $3"
  wc_check "$1" "$2" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
}

writes_case 1 "A1 parent traversal" "['../outside.ts']"
wc_out_has "plan rule 6" "A1 parent traversal"
writes_case 1 "A2 absolute path" "['/etc/passwd']"
writes_case 0 "A3 ./ normalized away" "['./src/a.ts']"
writes_case 1 "A4 empty segment" "['src//a.ts']"
writes_case 1 "A5 glob metacharacter" "['src/*.ts']"
writes_case 1 "A6 bracket glob" "['src/[ab].ts']"
writes_case 1 "A7 duplicate entry" "['src/a.ts', './src/a.ts']"
writes_case 1 "A8 dot" "['.']"
# A8b - a MID-PATH "." segment (src/./x): normalizePath only strips a LEADING "./", so without
# an explicit "." segment reject this would slip through and dodge the rule-9 write-into-read
# comparison (which is exact-string). FAIL-FIRST: before the dot-segment fix this validated 0.
writes_case 1 "A8b dot segment mid-path" "['src/./x.ts']"
wc_out_has "plan rule 6" "A8b dot segment mid-path"
writes_case 1 "A9 windows separator" "['src' + chr(92) + 'a.ts']"

# A10 - reads[] must be EXACT file paths: a subtree read would let a chunk fence off a
# directory it merely consumes, which inverts the bounded definition of reads (s2.2, delta 2).
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['reads'] = ['src/']"
wc_check 1 "A10 subtree prefix in reads" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "reads" "A10 subtree prefix in reads"

# A11 - the same syntax rules apply to shared_hazard_paths
wc_mutate "$PLAN" "$MUT" "p['analysis_basis']['shared_hazard_paths'] = ['../lock.json']"
wc_check 1 "A11 hazard path syntax" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

wc_finish '{"rejects":["..","/abs","a//b","glob","dup",".","./ mid-path .","backslash","prefix-in-reads"],"normalized":"./a -> a","authority":"schema doc s2.2 (plan text deferred to it for ./y)"}' \
  "12 assertions (A1-A9 exclusive_paths syntax incl mid-path dot, A10 reads exactness, A11 hazard paths)"
