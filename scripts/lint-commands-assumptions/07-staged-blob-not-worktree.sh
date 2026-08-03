#!/usr/bin/env bash
# 07 - A1..A5: --staged reads the STAGED BLOB, not the worktree (codex-review C1).
#
# THE BUG THIS PINS. Both lints SELECT which files to check from the git INDEX
# (`git diff --cached --name-only` via staged_has) but, before this fix, READ the file
# CONTENT from the WORKING TREE. The index and the worktree diverge routinely - stage a
# file, then keep editing; or `git rm --cached` a file you still have on disk. In that gap a
# commit could record broken or ABSENT content while the pre-commit gate graded the clean
# copy still sitting in the worktree, and reported OK. The whole machine-guard was
# bypassable by the most ordinary git workflow there is. Every failure it hides is silent: a
# dropped launch register does not error, the work just serializes again, invisibly.
#
# A1  staged BROKEN + worktree CLEAN  -> --staged must FAIL. The core bypass.
# A2  the SAME tree in --all reads the (clean) worktree -> exit 0, proving the worktree
#     really is clean and A1's failure came from the index, not from a stale mutation.
# A3  staged DELETION (`git rm --cached`) of a guarded file, worktree copy left in place ->
#     --staged must FAIL naming the file. A deleted guarded command is the sharpest form of
#     the bypass: `git show :<path>` yields nothing, so the required-literal checks fail
#     closed rather than reading the worktree's surviving copy.
# A4  INVERSE control: staged CLEAN + worktree BROKEN -> --staged must PASS. This is what
#     proves the fix reads the INDEX and not merely "whichever copy is broken" - the buggy
#     script fails here (it read the broken worktree), the fixed one passes.
# A5  the SAME split in lint-skill-size.sh: a staged marker violation with a clean worktree
#     must FAIL the size lint too - it is the check pre-commit has always run.
#
# NEGATIVE CONTROL: LINTCMD_NEGATIVE_CONTROL=head loads the lint scripts as of git HEAD
# (the C1-buggy ROOT-split version, ac1d11a). Under it A1/A3/A4/A5 flip: the buggy lint
# reads the worktree, so A1/A3/A5 report OK where a failure is required and A4 fails where a
# pass is required. That is the watched-fail this case was written against.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
lc_gate
lc_setup "07-staged-blob-not-worktree"
lc_baseline

# --- A1: staged broken, worktree restored clean ----------------------------------------
lc_edit commands/implement.md "s = s.replace('NO_REVIEW = true', 'NO_REVIEW is true')"
lc_stage commands/implement.md                                             # index = broken
lc_edit commands/implement.md "s = s.replace('NO_REVIEW is true', 'NO_REVIEW = true')"  # worktree = clean
lc_run 1 "A1 staged-broken/worktree-clean fails (reads the staged blob)" "$FIX" "$CONTRACT" --staged
lc_out_has "NO_REVIEW = true" "A1"
lc_out_has "commands/implement.md" "A1"

# --- A2: control - the worktree really is clean ----------------------------------------
lc_run 0 "A2 control: --all reads the clean worktree (so A1 came from the index)" "$FIX" "$CONTRACT" --all

# --- A3: staged deletion of a guarded file, worktree copy still present -----------------
lc_restore
g "$FIX" rm --cached -q -- commands/implement.md >/dev/null 2>&1 || { echo "INFRA: git rm --cached failed" >&2; exit 3; }
[ -f "${FIX}/commands/implement.md" ] || { echo "INFRA: worktree copy unexpectedly gone" >&2; exit 3; }
lc_run 1 "A3 staged deletion fails closed despite a clean worktree copy" "$FIX" "$CONTRACT" --staged
lc_out_has "commands/implement.md" "A3"
lc_out_has "missing/deleted" "A3"

# --- A4: inverse control - staged clean, worktree broken -> passes (reads the index) ----
lc_restore
lc_touch commands/implement.md            # harmless below-marker change so the file has a staged edit
lc_stage commands/implement.md            # index = clean (literals intact)
lc_edit commands/implement.md "s = s.replace('NO_REVIEW = true', 'NO_REVIEW is true')"  # worktree = broken, unstaged
lc_run 0 "A4 inverse: staged-clean/worktree-broken passes (proves it reads the index)" "$FIX" "$CONTRACT" --staged

# --- A5: the same split in the size lint -----------------------------------------------
lc_restore
lc_edit commands/implement.md "s = s.replace('<!-- CONTRACT-CORE-END -->', 'MARKER-REMOVED-BY-TEST', 1)"
lc_stage commands/implement.md            # index = marker gone (Rule 2 violation)
lc_edit commands/implement.md "s = s.replace('MARKER-REMOVED-BY-TEST', '<!-- CONTRACT-CORE-END -->', 1)"  # worktree restored
lc_run 1 "A5 size lint reads the staged marker violation despite a clean worktree" "$FIX" "$SIZE" --staged
lc_out_has "CONTRACT-CORE-END" "A5"

lc_finish '{"staged_broken_worktree_clean":"exit 1","all_reads_worktree":"exit 0","staged_deletion":"exit 1 fail-closed","inverse_staged_clean_worktree_broken":"exit 0 (reads index)","size_lint_same_split":"exit 1"}' \
  "6 assertions (staged blob vs worktree content authority for both lints)"
