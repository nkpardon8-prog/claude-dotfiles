#!/usr/bin/env bash
# 12 - A1..A8: the rework.log event contract (schema doc s7) - one event per invocation of every
#      mode on BOTH exit paths, a fixed key set in a fixed order, the CLOSED reason-token set,
#      and the 480-byte cap with its deterministic overflow rule.
#
# Load-bearing because: this log is the denominator. Every claim the parallelizer work will make
# later - how often the gate opened, how often a wave reworked - is counted from these lines. An
# invocation that exits without writing makes the denominator wrong in the flattering direction;
# a typo'd reason token silently invents a new category nobody reads; and a line over PIPE_BUF
# can interleave with a concurrent appender and corrupt the file that the whole measurement
# story rests on. Rejecting an unknown token is what keeps the set closed.
#
# HERMETIC: PARALLEL_WAVES_DIR points into this case's mktemp sandbox, so none of these events
# reach the real ~/.claude/parallel-waves/rework.log.
#
# NEGATIVE CONTROL (controllable precondition): add a token to the expected list in A1 that the
# checker does not implement, or shorten the A6 repo_root below the cap, and those assertions go
# RED - the exit flips and the truncated flag disappears.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
wc_gate
wc_setup "12-events-and-reason-tokens"
wc_wave

PLAN="${BASE}/plan.json"
MUT="${BASE}/mutant.json"
STATE="${BASE}/state.json"
wc_plan golden-wave-plan.json "$PLAN"
printf 'a1\n' >> "${WT_A}/src/a.ts"; wc_commit "$WT_A" "chunk a work"
printf 'b1\n' >> "${WT_B}/src/b.ts"; wc_commit "$WT_B" "chunk b work"
wc_state "$STATE" '["src/a.ts"]' '[]' '["src/b.ts"]' '[]'

# A1 - every token in the v1.1 closed set is accepted and echoed verbatim (17 tokens: the 11
#      carried-over gate/pass tokens, malformed as the fallback, plus the 5 de-aliased tokens).
for tok in lt2_chunks no_review dirty_repo_root merge_in_progress pct_unknown pct_over_60 \
           stale_wave dotfiles_unpaused serial_correct malformed low_confidence fan_out \
           rule_violation usage_error io_error merge_success merge_conflict; do
  wc_check 0 "A1 token ${tok}" --log-decision serial --reason "$tok" --repo-root "$REPO"
  wc_expect_reason "$tok" "A1 token ${tok}"
done

# A2 - an unknown token is REJECTED (exit 2, a usage_error) and still writes ONE event, with the
#      passed decision preserved because that argument was itself valid (s7.2).
wc_check 2 "A2 unknown reason token" --log-decision serial --reason typo_token --repo-root "$REPO"
wc_expect_reason usage_error "A2 unknown reason token"
[ "$(wc_event_field decision)" = "serial" ] \
  || wc_fail "A2: decision should be preserved as 'serial', got '$(wc_event_field decision)'"
wc_out_has "closed set" "A2 unknown reason token"

# A3 - an invalid decision value: exit 2, and decision is null because it was NOT valid
wc_check 2 "A3 invalid decision" --log-decision maybe --reason fan_out --repo-root "$REPO"
[ "$(wc_event_field decision)" = "null" ] \
  || wc_fail "A3: decision should be null, got '$(wc_event_field decision)'"

# A4 - all three modes, both exit paths: 6 invocations, 6 events, correct tool_mode on each
expect_mode() { [ "$(wc_event_field tool_mode)" = "$1" ] || wc_fail "${2}: tool_mode should be ${1}, got '$(wc_event_field tool_mode)'"; }
BEFORE="$(wc_events_count)"
wc_check 0 "A4 validate-plan pass" --validate-plan "$PLAN" --repo-root "$REPO" --base-sha "$BASE_SHA"
expect_mode validate-plan "A4 validate-plan pass"
wc_mutate "$PLAN" "$MUT" "p['waves'][0]['chunks'][1]['exclusive_paths'] = ['src/a.ts']"
wc_check 1 "A4 validate-plan fail" --validate-plan "$MUT" --repo-root "$REPO" --base-sha "$BASE_SHA"
expect_mode validate-plan "A4 validate-plan fail"
wc_check 0 "A4 wave-state pass" --wave-state "$STATE"
expect_mode wave-state "A4 wave-state pass"
wc_check 2 "A4 wave-state fail" --wave-state "${BASE}/absent.json"
expect_mode wave-state "A4 wave-state fail"
wc_check 0 "A4 log-decision pass" --log-decision fan_out --reason fan_out --repo-root "$REPO"
expect_mode log-decision "A4 log-decision pass"
wc_check 2 "A4 log-decision fail" --log-decision fan_out --reason nope --repo-root "$REPO"
expect_mode log-decision "A4 log-decision fail"
AFTER="$(wc_events_count)"
[ "$((AFTER - BEFORE))" = "6" ] || wc_fail "A4: expected 6 events across the three modes, got $((AFTER - BEFORE))"

# A5 - the fixed key SET, in the fixed ORDER (s7.1)
KEYS="$(python3 -c '
import json, sys
line = [l for l in open(sys.argv[1]) if l.strip()][-1]
print(",".join(json.loads(line).keys()))' "${WAVES}/rework.log")"
[ "$KEYS" = "ts,tool_mode,decision,verdict,exit,repo_root,wave,reason" ] \
  || wc_fail "A5: event keys/order should be ts,tool_mode,decision,verdict,exit,repo_root,wave,reason - got ${KEYS}"

# A5b - verdict is READ from the plan under --validate-plan and null elsewhere
wc_check 0 "A5b verdict recorded" --validate-plan "$PLAN" --repo-root "$REPO" --base-sha "$BASE_SHA"
[ "$(wc_event_field verdict)" = "FAN_OUT" ] || wc_fail "A5b: verdict should be FAN_OUT, got '$(wc_event_field verdict)'"
[ "$(wc_event_field wave)" = "1" ] || wc_fail "A5b: wave should be 1, got '$(wc_event_field wave)'"
wc_check 0 "A5c verdict null in log-decision" --log-decision serial --reason lt2_chunks --repo-root "$REPO"
[ "$(wc_event_field verdict)" = "null" ] || wc_fail "A5c: verdict should be null, got '$(wc_event_field verdict)'"

# A6 - the 480-byte cap and the overflow rule: repo_root keeps its LAST 80 characters and the
#      line carries truncated:true. (Step 2 of the rule - dropping repo_root entirely - cannot be
#      reached while every other field is bounded by construction; it is implemented as the
#      schema's literal fallback, not as a live path.)
LONG_ROOT="/$(python3 -c 'print("d" * 600)')"
wc_check 0 "A6 overflow" --log-decision serial --reason pct_over_60 --repo-root "$LONG_ROOT"
LINE_BYTES="$(tail -1 "${WAVES}/rework.log" | wc -c | tr -d ' ')"
[ "$LINE_BYTES" -le 480 ] || wc_fail "A6: event line is ${LINE_BYTES} bytes, cap is 480"
[ "$(wc_event_field truncated)" = "True" ] || wc_fail "A6: truncated flag missing on an over-cap line"
EXPECT_TAIL="$(printf '%s' "$LONG_ROOT" | tail -c 80)"
[ "$(wc_event_field repo_root)" = "$EXPECT_TAIL" ] \
  || wc_fail "A6: repo_root should be the last 80 chars of the passed root"
# A6b - a normal-length root carries NO truncated key
wc_check 0 "A6b no truncation" --log-decision serial --reason pct_over_60 --repo-root "$REPO"
[ "$(wc_event_field truncated)" = "MISSING" ] || wc_fail "A6b: truncated key present on a line that fits"

# A7 - the waves dir is CREATED when absent: the event must survive a first-ever run
rm -rf "$WAVES"
wc_check 0 "A7 waves dir created" --log-decision fan_out --reason fan_out --repo-root "$REPO"
[ -f "${WAVES}/rework.log" ] || wc_fail "A7: rework.log was not created under PARALLEL_WAVES_DIR"

# A8 - hermetic: everything written lives under this case's sandbox
case "$WAVES" in "${BASE}"/*) ;; *) wc_fail "A8: PARALLEL_WAVES_DIR escaped the sandbox: ${WAVES}" ;; esac

wc_finish '{"tokens":17,"unknown_token":"exit 2 reason usage_error, decision preserved","modes_x_exits":6,"key_order":"ts,tool_mode,decision,verdict,exit,repo_root,wave,reason","cap_bytes":480,"overflow":"last 80 chars + truncated:true"}' \
  "25 assertions (A1 x17 tokens, A2 unknown, A3 decision, A4 modes x exits, A5-A5c shape, A6/A6b cap, A7 dir creation, A8 hermetic)"
