#!/usr/bin/env bash
# 01 - gate-parity: the no-detach gate's OWN fixture table is the source of truth for which
# shell-detach forms block a codex launch; this case gates that table into the continuity
# suite (so a regression in the gate is caught by the SAME command that proves the AWAIT
# machinery), then re-pipes three keystone cases directly through the live gate as a spot
# check that the table and the gate have not drifted from each other.
#
# Load-bearing because road 1 of the mission stall is exactly a `nohup codex ... &` whose
# wrapper exits in ~1s: the harness tracks the launcher, codex finishes orphaned, and the
# idle /mission never wakes. The gate is the machine backstop for that foot-gun; if it stops
# blocking the literal detach forms, the backstop is silently gone.
#
# NEGATIVE CONTROL: temporarily weaken the gate's DETACH regex (e.g. drop `nohup` from the
# alternation in no-detach-gate.py) and re-run - `nohup codex &` then returns exit 0 where
# this case asserts 2, the fixture suite reports a FAIL, and A1 goes RED. Restore to green.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "01-gate-parity"

[ -f "$FIXTURE_TEST" ] || { echo "INFRA: missing test-no-detach-fixtures.py" >&2; exit 3; }
[ -f "$GATE" ]         || { echo "INFRA: missing no-detach-gate.py" >&2; exit 3; }

# A1 - the gate's whole fixture table passes (its own source of truth for block/allow).
mc_rc 0 "A1 no-detach fixture table passes" python3 "$FIXTURE_TEST"

# Direct re-pipe of three keystone cases through the LIVE gate. run_gate feeds the exact
# PreToolUse stdin payload and echoes the gate's exit code.
run_gate() {  # run_gate <command> -> stdout the gate exit code
  printf '%s' "{\"tool_input\":{\"command\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")}}" \
    | python3 "$GATE" >/dev/null 2>&1
  echo $?
}

# A2 - the orphaning form MUST block (exit 2). This is the f71c8667 road-1 shape verbatim.
mc_eq 2 "$(run_gate 'nohup codex exec x & echo launched')" "A2 nohup codex & blocks"

# A3 - the sanctioned foreground `&&` sequence MUST allow (exit 0): codex runs in the
# foreground, its completion wakes the agent - never blocked (the critical (?<!&) case).
mc_eq 0 "$(run_gate 'codex exec x && echo done')" "A3 codex && sequence allows"

# A4 - a detach with NO codex token is not our concern and MUST allow (exit 0).
mc_eq 0 "$(run_gate 'nohup "$CHROME" --headless >/dev/null 2>&1 &')" "A4 nohup non-codex allows"

mc_finish '{"fixture_table":"passes (exit 0)","nohup_codex_amp":"block=2","codex_and_seq":"allow=0","nohup_noncodex":"allow=0"}' \
  "4 assertions (no-detach gate parity: fixture table + 3 keystone re-pipes)"
