#!/usr/bin/env bash
# 02 - A1..A5: --staged FAILS on a staged file whose required literal is gone.
#
# Load-bearing because case 01's skip is only safe if this is true. A --staged mode that
# skipped too much would be the worst of both worlds: a pre-commit hook that runs on every
# commit, reports nothing, and lets the register that makes agents fan out disappear from
# the file that carries it. That failure is silent by nature - a dropped register does not
# error, the command simply runs serially forever and the loss never appears in any log.
#
# A4/A5 pin the SCOPE of the report: only staged files are named. A hook that also reported
# a sibling's unstaged edit would train committers to ignore its output.
#
# NEGATIVE CONTROL: LINTCMD_NEGATIVE_CONTROL=head (pre-change lint knows none of these
# literals and reads $HOME's tree, so it reports OK on this sandbox).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
lc_gate
lc_setup "02-staged-mode-fails-on-staged"
lc_baseline

# Two independent breaks, in two different files.
lc_edit commands/implement.md "s = s.replace('NO_REVIEW = true', 'NO_REVIEW is true')"
lc_edit commands/codex-review.md "s = s.replace('EXACTLY 1 Agent call', 'exactly one Agent call')"

# A1 - stage ONLY implement.md: red, and the message names the file and the literal.
lc_stage commands/implement.md
lc_run 1 "A1 staged file with a missing literal fails" "$FIX" "$CONTRACT" --staged
lc_out_has "commands/implement.md" "A1"
lc_out_has "NO_REVIEW = true" "A1"

# A2 - the unstaged sibling's break is NOT reported: the report is scoped to this commit.
lc_out_lacks "commands/codex-review.md" "A2 scope"

# A3 - staging the sibling too brings it in.
lc_stage commands/codex-review.md
lc_run 1 "A3 both staged, both checked" "$FIX" "$CONTRACT" --staged
lc_out_has "EXACTLY 1 Agent call" "A3"

# A4 - restoring the staged content clears it: the check reads the tree being committed,
# not a memory of what was wrong a moment ago.
lc_edit commands/implement.md "s = s.replace('NO_REVIEW is true', 'NO_REVIEW = true')"
lc_edit commands/codex-review.md "s = s.replace('exactly one Agent call', 'EXACTLY 1 Agent call')"
lc_stage commands/implement.md commands/codex-review.md
lc_run 0 "A4 restored content passes with the same staged set" "$FIX" "$CONTRACT" --staged

# A5 - an unknown argument must not be treated as "full mode" or as "no mode": a typo in
# the hook body would otherwise change what the gate checks without saying so.
lc_run 2 "A5 unknown argument exits 2" "$FIX" "$CONTRACT" --stagedd
lc_out_has "unknown argument" "A5"

lc_finish '{"staged_fail":"exit 1 naming file+literal","scope":"unstaged sibling not reported","restore":"exit 0","unknown_arg":"exit 2"}' \
  "5 assertions (staged-set enforcement + report scope + argument validation)"
