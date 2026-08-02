#!/usr/bin/env bash
# 05 - A1..A5: absent() - a SWEPT literal must not come back.
#
# Load-bearing because the deleted sentence and its replacement are not mutually exclusive
# in a file. codex-review.md used to end two steps with "Spawn ALL FOUR Bash calls in a
# SINGLE message"; the launch schedule is now six calls. req() cannot catch the old wording
# returning - the new wording is present too, so every presence check stays green while the
# file gives an agent two contradictory launch counts and it follows whichever it read
# last. Re-growth is the likely failure mode, not the exotic one: this text is edited by
# agents that regularly have an older revision of the same file in context.
#
# A3 pins that absence is judged with the same staged-set scoping as presence, so the
# banned string cannot slip in through a commit that never gets checked... and A4 pins the
# other half: once that file IS staged, it is caught.
#
# NEGATIVE CONTROL: LINTCMD_NEGATIVE_CONTROL=head (the pre-change lint has no absence check
# of any kind).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
lc_gate
lc_setup "05-absent-banned-literal"
lc_baseline

BANNED='Spawn ALL FOUR Bash calls in a SINGLE message'

# A1 - pristine: the sweep really did land, and the check is not trivially red.
lc_run 0 "A1 pristine fixture carries no banned wording" "$FIX" "$CONTRACT"

# A2 - the old sentence returns (as it would from a copy-paste out of an older revision).
lc_edit commands/codex-review.md "s = s + chr(10) + '${BANNED} first.' + chr(10)"
lc_run 1 "A2 re-grown banned wording fails" "$FIX" "$CONTRACT"
lc_out_has "banned literal" "A2"
lc_out_has "$BANNED" "A2"

# A3 - and the diagnostic names the LINE, because the point of the message is to make the
# survivor findable in a 57k-char file.
lc_out_has "commands/codex-review.md" "A3 diagnostic"

# A4 - staged-set scoping applies to absence too: unstaged, this commit is not the one that
# introduced it, so nothing is reported.
lc_run 0 "A4 --staged skips the unstaged file carrying the banned wording" "$FIX" "$CONTRACT" --staged

# A5 - stage it and the same tree is red. Without this, A4 would be indistinguishable from
# absence() never running at all.
lc_stage commands/codex-review.md
lc_run 1 "A5 --staged catches it once the file is in the commit" "$FIX" "$CONTRACT" --staged
lc_out_has "$BANNED" "A5"

lc_finish '{"pristine":"exit 0","regrown":"exit 1 naming file+line","staged_scoping":"unstaged skipped, staged caught"}' \
  "5 assertions (banned-literal absence check + its staged scoping)"
