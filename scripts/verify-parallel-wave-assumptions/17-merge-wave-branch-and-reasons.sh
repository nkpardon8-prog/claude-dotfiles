#!/usr/bin/env bash
# 17 - A1..A5: merge-wave.sh branch-argument safety (codex-review Fix 6) and the v1.1 de-aliased
#      OUTCOME reason tokens on their REAL paths (Fix 7).
#
# Load-bearing because: v1 emitted merge SUCCESS and a verify PASS as the same token (fan_out),
# and a merge CONFLICT, a usage error, and a real rule violation all as `malformed`. Analytics
# could not tell a merged wave from a bad plan from a conflict. v1.1 gives each a distinct token:
# merge_success / merge_conflict from merge-wave, rule_violation / io_error / usage_error from the
# checker. Separately, merge-wave hands each chunk's branch NAME to `git merge`; an unvalidated
# ref (a leading dash could be read as a git option) is refused before any merge, so the
# integration checkout never moves. rule 13 in the checker's inline pass is the first catcher;
# merge-wave's check-ref-format pre-pass is the callsite backstop. Either way: nothing merges.
#
# FAIL-FIRST: before Fix 7 A1 saw `fan_out` where it now demands `merge_success`, and A2 saw
# `malformed` where it now demands `merge_conflict` (assert the new tokens => RED on the old
# code). Before Fix 6/1 a dash branch reached `git merge -evil` and failed with a confusing git
# option error instead of a clean, up-front refusal.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "17-merge-wave-branch-and-reasons"
wc_wave

state_edit() {  # state_edit <file> <python body operating on the parsed state as `s`>
  python3 - "$1" "$2" <<'PY'
import json, sys
f, body = sys.argv[1], sys.argv[2]
s = json.load(open(f))
exec(body)
json.dump(s, open(f, "w"))
PY
}
merged_count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["merged_chunks"]))' "$1"; }

STATE="${BASE}/state.json"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b1\n' >> "${WT_B}/src/b.ts"
printf 'from-chunk-b\n' > "${WT_B}/src/new.ts"
wc_commit "$WT_B" "chunk b work plus a new file"

# A1 - Fix 7: a successful integration records `merge_success` (NOT the verify-pass token fan_out),
#      and the inline verify event that preceded it is the DISTINCT `fan_out` token.
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts","src/new.ts"]' '[]'
wc_merge 0 2 "A1 happy merge" "$STATE"
[ "$(wc_event_field reason)" = "merge_success" ] \
  || wc_fail "A1: merge success reason should be merge_success, got '$(wc_event_field reason)'"
PENULT="$(python3 -c 'import sys,json;L=[l for l in open(sys.argv[1]) if l.strip()];print(json.loads(L[-2])["reason"] if len(L)>=2 else "NONE")' "${WAVES}/rework.log")"
[ "$PENULT" = "fan_out" ] || wc_fail "A1: the inline verify event should be fan_out, got '${PENULT}'"
g "$REPO" reset --hard -q "$BASE_SHA"   # rewind for the next scenario
state_edit "$STATE" 's["merged_chunks"] = []'

# A2 - Fix 7: a merge CONFLICT/refusal records `merge_conflict` (NOT malformed). An untracked
#      collision in repo_root makes git refuse chunk-b after chunk-a merged (proven in case 14).
printf 'local-untracked\n' > "${REPO}/src/new.ts"
wc_merge 1 2 "A2 conflict" "$STATE"
[ "$(wc_event_field reason)" = "merge_conflict" ] \
  || wc_fail "A2: merge conflict reason should be merge_conflict, got '$(wc_event_field reason)'"
rm -f "${REPO}/src/new.ts"
g "$REPO" reset --hard -q "$BASE_SHA"
state_edit "$STATE" 's["merged_chunks"] = []'

# A3 - Fix 6/1: a leading-dash branch is REFUSED and NOTHING is merged. merge-wave hands branch
#      names to `git merge`; a dash could be read as a git option. The system refuses cleanly and
#      the integration checkout never moves; the refusal names the offending branch.
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts","src/new.ts"]' '[]'
state_edit "$STATE" 's["chunks"][0]["branch"] = "-evil"'
HEAD_BEFORE="$(g "$REPO" rev-parse HEAD)"
OUT="$(bash "$MERGE_WAVE" "$STATE" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || wc_fail "A3: a dash branch must make merge-wave refuse (nonzero), got 0"
[ "$(g "$REPO" rev-parse HEAD)" = "$HEAD_BEFORE" ] || wc_fail "A3: HEAD moved despite a refused branch"
[ "$(merged_count "$STATE")" = "0" ] || wc_fail "A3: something was merged despite a refused branch"
printf '%s' "$OUT" | grep -qF -- "-evil" || wc_fail "A3: the refusal never named the offending branch '-evil'"

# A3b - Fix 6/1: a malformed (non-resolving) branch ref is likewise refused, nothing merged.
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts","src/new.ts"]' '[]'
state_edit "$STATE" 's["chunks"][1]["branch"] = "bad..name"'
HEAD_BEFORE="$(g "$REPO" rev-parse HEAD)"
OUT="$(bash "$MERGE_WAVE" "$STATE" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] || wc_fail "A3b: a malformed branch ref must make merge-wave refuse"
[ "$(g "$REPO" rev-parse HEAD)" = "$HEAD_BEFORE" ] || wc_fail "A3b: HEAD moved despite a malformed branch ref"
[ "$(merged_count "$STATE")" = "0" ] || wc_fail "A3b: something merged despite a malformed branch ref"

# A4 - hermetic: nothing escaped the sandbox
case "$WAVES" in "${BASE}"/*) ;; *) wc_fail "A4: PARALLEL_WAVES_DIR escaped the sandbox: ${WAVES}" ;; esac

wc_finish '{"merge_success":"exit 0 outcome","merge_conflict":"exit 1 outcome","inline_verify":"fan_out (distinct)","branch_guard":"leading dash + check-ref-format --branch => refuse before merge, nothing merged"}' \
  "7 assertions (A1 merge_success+fan_out, A2 merge_conflict, A3 dash branch, A3b malformed ref, A4 hermetic)"
