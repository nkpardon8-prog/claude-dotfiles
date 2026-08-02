#!/usr/bin/env bash
# 01 - A1..A4: --staged checks ONLY files in the staged set.
#
# Load-bearing because this is what makes the lint safe to put in pre-commit at all. The
# generated pre-commit hook is the one place the contract lint runs automatically, and it
# runs on EVERY commit in this repo - including commits that touch nothing under commands/.
# If --staged checked everything, an unrelated commit made while a command file was
# mid-edit would be blocked for a reason the committer did not cause, and the reflex that
# follows is --no-verify, which silently disables the secret gate chained behind it. The
# skip is not a convenience; it is what keeps the whole pre-commit chain trustworthy.
#
# The same property is what keeps scripts/hooks/test-secret-scan.sh green: that test builds
# a fixture $HOME containing scripts/ but NO commands/, and commits plain text files. Every
# check must skip there, or every commit in that fixture aborts.
#
# A2 is the control that makes A1 mean something: the SAME tree, in full mode, must be RED.
# Without it, A1 would also pass if the mutation had silently failed to apply.
#
# NEGATIVE CONTROL: LINTCMD_NEGATIVE_CONTROL=head (the pre-change lint has no --staged mode
# at all; it ignores the argument, hardcodes ROOT to $HOME, and reports the real repo).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
lc_gate
lc_setup "01-staged-mode-skips-unstaged"
lc_baseline

# Break implement.md: drop the mode literal the wave gate depends on.
lc_edit commands/implement.md "s = s.replace('NO_REVIEW = true', 'NO_REVIEW is true')"

# A1 - nothing staged at all: an empty staged set checks nothing.
lc_run 0 "A1 empty staged set skips the broken file" "$FIX" "$CONTRACT" --staged

# A2 - CONTROL: the same tree in full mode is red, so A1 was a skip and not a dead mutation.
lc_run 1 "A2 control: full mode sees the same break" "$FIX" "$CONTRACT"
lc_out_has "NO_REVIEW = true" "A2 control"
lc_out_has "commands/implement.md" "A2 control"

# A3 - a DIFFERENT file staged: still skipped, because implement.md is not in this commit.
lc_touch commands/plan.md
lc_stage commands/plan.md
lc_run 0 "A3 unrelated staged file leaves the break unchecked" "$FIX" "$CONTRACT" --staged

# A4 - cwd outside any repository: GITROOT falls back to the script's own ROOT, so the
# staged set is the FIXTURE's index (which holds only plan.md) and the broken implement.md
# is still not checked. What this pins is that the fallback DEGRADES TO A STAGED SET, never
# to an accidental full-tree scan - a hook always runs with cwd inside the repo, so this
# path is only ever reached by a hand invocation.
lc_run 0 "A4 cwd outside any repo falls back to a staged set, not a full scan" "$BASE" "$CONTRACT" --staged

lc_finish '{"staged_skip":"unstaged file with a missing literal -> exit 0","full_mode_same_tree":"exit 1","empty_staged_set":"exit 0","outside_repo_staged":"exit 0"}' \
  "4 assertions (staged-set scoping of the contract lint)"
