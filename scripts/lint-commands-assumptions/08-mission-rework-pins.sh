#!/usr/bin/env bash
# 08 - test 13 of the mission rework (2026-11-11): the proto=2 playbook pins in lint-skill-contract.sh
#      each FAIL when their literal is removed, and the retired literals FAIL when they come back.
#
# Load-bearing because the playbook is prose an agent executes: a dropped `bank-review` instruction does
# not error, the conductor just goes back to hand-logging evidence the writer now refuses; a tick prompt
# that loses `docs/mission/wake.md` silently re-reads the 178 KB playbook every tick (about 46k tokens).
# Every pin below is removed ALONE from a pristine fixture, so a green result means that one pin bites.
#
# NEGATIVE CONTROL: LINTCMD_NEGATIVE_CONTROL=head (the pre-rework lint has none of these pins).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
lc_gate
lc_setup "08-mission-rework-pins"
lc_baseline

# remove_case <file> <literal> <label>: replace every occurrence of the literal, expect exit 1 naming it.
remove_case() {
  lc_restore
  lc_edit "$1" "s = s.replace($(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2"), 'REMOVED-BY-FIXTURE')"
  lc_run 1 "$3 removed -> red" "$FIX" "$CONTRACT"
  lc_out_has "$2" "$3"
}
M=commands/mission.md
W=docs/mission/wake.md
remove_case "$M" "bank-review"                                   "P1 bank-review"
remove_case "$M" "budget-state"                                  "P2 budget-state"
remove_case "$M" "[mission] RECIPE part="                        "P3 RECIPE shape"
remove_case "$M" "[mission] SWEEP part="                         "P4 SWEEP shape"
remove_case "$M" "[mission] FULL-SUITE part="                    "P5 FULL-SUITE shape"
remove_case "$M" "proto=2 worktree="                             "P6 PART-START proto=2"
remove_case "$M" "park=<reason>"                                 "P7 park FAIL"
remove_case "$M" "docs/mission/wake.md"                          "P8 tick names wake.md"
remove_case "$M" "Read <WAKE> and run its §12.1 wake routine"    "P9 tick reads WAKE"
remove_case "$W" "## §12.1 The wake routine"                     "P10 wake.md routine heading"
remove_case "$W" "EXIT GATE"                                     "P11 wake.md exit gate"

# Retired literals coming back is red too.
lc_restore
lc_edit "$M" "s = s + '\nRead the PLAYBOOK <PLAYBOOK> for full detail.\n'"
lc_run 1 "R1 the old full-playbook tick read is banned" "$FIX" "$CONTRACT"
lc_out_has "Read the PLAYBOOK" "R1"
lc_restore
lc_edit "$M" "s = s + '\nCAP: <=3 BLOCKING-producing rounds\n'"
lc_run 1 "R2 the fixed blocking-round cap is banned" "$FIX" "$CONTRACT"
lc_out_has "BLOCKING-producing rounds" "R2"
lc_restore
lc_edit "$W" "s = s + '\nbash ~/.claude-dotfiles/scripts/hooks/mission-write.sh cursor-hash\n'"
lc_run 1 "R3 a ~ invocation in wake.md misses the allowlist" "$FIX" "$CONTRACT"
lc_out_has "docs/mission/wake.md" "R3"

lc_restore
lc_run 0 "pristine fixture is green" "$FIX" "$CONTRACT"

lc_finish '{"pins":"each proto=2 pin red when removed alone","retired":"old tick read, fixed cap, ~ invocation all red","pristine":"green"}' \
  "pin-removal + retired-literal cases for the mission rework playbook"
