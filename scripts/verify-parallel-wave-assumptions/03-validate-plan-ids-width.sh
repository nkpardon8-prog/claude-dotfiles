#!/usr/bin/env bash
# 03 - A1..A7: chunk-id syntax and plan-wide uniqueness (schema doc s2.1, s4 rule 4) and the
#      WAVE_WIDTH_MAX cap (s2.5, s4 rule 5).
#
# Load-bearing because: a chunk id becomes a git BRANCH name and a worktree DIRECTORY name
# (w<W>-<SID8>-<chunk-id>). An id carrying a slash, a space, or a shell metacharacter turns two
# machine-generated commands into something else entirely; a DUPLICATE id makes wave 3 collide
# with wave 1's branch and worktree, and the second `worktree add` fails halfway through a
# spawn batch. The width cap is a constant precisely so no caller can raise it.
#
# NEGATIVE CONTROL (controllable precondition): lower the injected chunk count from 5 to 4 and
# A5 goes RED - the over-width plan validates 0 where 1 was expected.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "03-validate-plan-ids-width"
wc_wave

PLAN="${BASE}/plan.json"
MUT="${BASE}/mutant.json"
wc_plan golden-wave-plan.json "$PLAN"

id_case() {  # id_case <expected-exit> <label> <id literal>
  wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][0]['id'] = '''$3'''
p['waves'][0]['chunks'][1]['independent_of'] = [{'chunk_id': '''$3''', 'reason': 'disjoint'}]"
  wc_check "$1" "$2" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
}

# A1..A3 - the id regex ^[a-z0-9][a-z0-9-]{0,31}$
id_case 1 "A1 uppercase id" "Chunk-A"
wc_out_has "plan rule 4" "A1 uppercase id"
id_case 1 "A2 leading hyphen id" "-chunk"
id_case 1 "A3 over-long id" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
id_case 1 "A4 path separator in id" "chunk/a"
id_case 0 "A4b 32-char id accepted" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# A5 - ids must be unique across the WHOLE plan, not just within a wave
INJECT_SECOND_WAVE="import copy
w2 = copy.deepcopy(p['waves'][0])
w2['wave'] = 2
w2['chunks'] = [copy.deepcopy(p['waves'][0]['chunks'][0])]
w2['chunks'][0]['independent_of'] = []
p['waves'].append(w2)"
wc_mutate "$PLAN" "$MUT" "$INJECT_SECOND_WAVE"
wc_check 1 "A5 duplicate id plan-wide" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "plan rule 4" "A5 duplicate id plan-wide"

wc_mutate "$PLAN" "$MUT" "${INJECT_SECOND_WAVE}
p['waves'][1]['chunks'][0]['id'] = 'chunk-c'
p['waves'][1]['chunks'][0]['exclusive_paths'] = ['src/c.ts']"
wc_check 0 "A5b distinct id accepted" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

# A6/A7 - WAVE_WIDTH_MAX = 4
WIDEN="import copy
w = p['waves'][0]
tmpl = copy.deepcopy(w['chunks'][0])
for name in EXTRA:
    c = copy.deepcopy(tmpl)
    c['id'] = name
    c['exclusive_paths'] = ['src/' + name + '.ts']
    c['reads'] = []
    w['chunks'].append(c)
ids = [c['id'] for c in w['chunks']]
for c in w['chunks']:
    c['independent_of'] = [{'chunk_id': o, 'reason': 'disjoint'} for o in ids if o != c['id']]"
wc_mutate "$PLAN" "$MUT" "EXTRA = ['chunk-c', 'chunk-d']
${WIDEN}"
wc_check 0 "A6 width 4 accepted" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"

wc_mutate "$PLAN" "$MUT" "EXTRA = ['chunk-c', 'chunk-d', 'chunk-e']
${WIDEN}"
wc_check 1 "A7 width 5 rejected" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
wc_out_has "plan rule 5" "A7 width 5 rejected"

wc_finish '{"id_regex":"^[a-z0-9][a-z0-9-]{0,31}$","uniqueness":"plan-wide","WAVE_WIDTH_MAX":4,"width_4":"exit 0","width_5":"exit 1"}' \
  "8 assertions (A1-A4b id syntax, A5/A5b uniqueness, A6/A7 width cap)"
