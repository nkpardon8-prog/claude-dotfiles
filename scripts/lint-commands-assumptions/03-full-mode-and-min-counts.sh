#!/usr/bin/env bash
# 03 - A1..A6: full mode (the Validation-Gates invocation) checks every rule regardless of
#      the index, and min-counts are enforced at the documented boundary.
#
# Load-bearing because the bare invocation is the gate the plan's Validation Gates run and
# the only invocation that sees files nobody happens to be committing. Pre-commit only ever
# sees a diff; drift that arrives by any other route (a rebase, a cherry-pick, an --amend
# with --no-verify, an agent editing through the ~/.claude symlink) is caught here or not
# at all.
#
# The min-count is the subtle rule. `req` counts matching LINES, not occurrences, so a
# min of 4 means "four separate lines still carry this". CODEX_TIMEOUT_SECS=540 is the
# lens self-timeout: collection is a bounded wait on the .status sidecars, and a lens
# launched without the self-timeout never writes one, so the wait burns its full ceiling
# instead of degrading to "that lens is not usable". Four lens invocations, four lines.
# A1/A2 run both sides of the boundary so the number is pinned, not merely present.
#
# NEGATIVE CONTROL: LINTCMD_NEGATIVE_CONTROL=head (the pre-change lint has no knowledge of
# these files' literals and reads $HOME's tree, so every case below reports OK).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
lc_gate
lc_setup "03-full-mode-and-min-counts"
lc_baseline

# A1 - below the min: 5 lines carry the self-timeout, drop 2, leaving 3 (< 4).
lc_edit commands/codex-review.md "s = s.replace('CODEX_TIMEOUT_SECS=540', 'CODEX_TIMEOUT_SECS=300', 2)"
lc_run 1 "A1 min-count 4 rejects 3 remaining lines" "$FIX" "$CONTRACT"
lc_out_has "need >=4, have 3" "A1"

# A2 - the OTHER side of the same boundary: 4 remaining lines is accepted. Without this,
# the min could be any number from 1 to 4 and the suite could not tell.
lc_restore
lc_edit commands/codex-review.md "s = s.replace('CODEX_TIMEOUT_SECS=540', 'CODEX_TIMEOUT_SECS=300', 1)"
lc_run 0 "A2 min-count 4 accepts 4 remaining lines" "$FIX" "$CONTRACT"

# A3 - full mode ignores the index: stage nothing, break plan.md, still red.
lc_restore
lc_edit commands/plan.md "s = s.replace('CRITICAL - research is a parallel fan-out', 'Research can be parallel')"
lc_run 1 "A3 full mode flags an unstaged break" "$FIX" "$CONTRACT"
lc_out_has "commands/plan.md" "A3"

# A4 - the explicit --all spelling behaves identically to the bare invocation. The hook
# passes --staged; every other caller passes nothing or --all, and those two must not
# diverge.
lc_run 1 "A4 --all matches the bare invocation" "$FIX" "$CONTRACT" --all

# A5 - a required literal deleted outright (not merely reworded) is still a miss, with the
# have-count reported as 0 rather than the check being skipped for a missing match.
lc_restore
lc_edit commands/implement.md "s = s.replace('merge-wave.sh', 'the merge script')"
lc_run 1 "A5 deleted literal reports have-0" "$FIX" "$CONTRACT"
lc_out_has "have 0" "A5"

# A6 - and the pristine tree is green, so none of the above is a permanently red lint.
lc_restore
lc_run 0 "A6 pristine fixture is green in full mode" "$FIX" "$CONTRACT"

lc_finish '{"min_count":"4 required; 3 rejected, 4 accepted","full_mode":"index-independent","all_flag":"same as bare","missing_literal":"have 0 -> exit 1"}' \
  "6 assertions (full-mode coverage + min-count boundary)"
