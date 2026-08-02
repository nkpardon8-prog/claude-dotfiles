#!/usr/bin/env bash
# 06 - A1..A5: a commit made from a LINKED WORKTREE is linted against that worktree's
#      staged set and that worktree's file content.
#
# Load-bearing because this is the seam the ROOT split exists for, and it is listed as an
# open risk in the plan (Task 11, "worktree-index visibility for the staged-set lint
# query"). Linked worktrees SHARE .git/hooks, so a commit made in one runs the very same
# generated pre-commit, which invokes the lint by its $HOME path. Before the split, both
# the file reads and the `--cached` query were pinned to $HOME/.claude-dotfiles: the query
# returned the MAIN tree's staged set - empty during a worktree commit - so every check
# skipped and the hook reported success having examined nothing. That is the shape this
# whole task is meant to prevent, in the machinery meant to prevent it.
#
# It matters right now because the parallelizer's own write-wave machinery creates linked
# worktrees and has subagents commit inside them. A command file edited by a wave chunk
# would commit past a hook that looked at the wrong index.
#
# A3 pins the second half of the split, which is a DELIBERATE REFINEMENT of the plan's
# literal wording (recorded in the task report): the plan specified content from
# BASH_SOURCE's ROOT and only the staged QUERY from the git toplevel. Split that way, a
# worktree commit is listed from the worktree but READ from the main tree, so a break
# staged in the worktree is judged against the main tree's untouched text - the same silent
# pass by a different route. In --staged mode the tree being committed is therefore the
# authority for content as well. The two paths are identical in the ordinary main-tree
# case, so nothing else changes.
#
# NEGATIVE CONTROL: LINTCMD_NEGATIVE_CONTROL=head (the pre-change lint hardcodes
# ROOT="$HOME/.claude-dotfiles" for both questions - A1 and A4 go green-when-they-should-be-
# red, which IS the bug).
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
lc_gate
lc_setup "06-linked-worktree-staged-set"
lc_baseline

WT="${BASE}/wt"
g "$FIX" worktree add -q "$WT" -b wtbranch >/dev/null 2>&1 || { echo "INFRA: git worktree add failed" >&2; exit 3; }
[ -f "${WT}/commands/implement.md" ] || { echo "INFRA: worktree checkout is empty" >&2; exit 3; }

# Break and stage INSIDE the worktree. The main tree is untouched and its index is empty.
python3 -c "
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace('verify-parallel-wave', 'the wave checker')
open(p, 'w', encoding='utf-8').write(s)" "${WT}/commands/implement.md" || { echo "INFRA: worktree edit failed" >&2; exit 3; }
g "$WT" add -- commands/implement.md >/dev/null 2>&1 || { echo "INFRA: worktree git add failed" >&2; exit 3; }

# A1 - the hook's invocation shape: the MAIN tree's script, cwd at the worktree root.
lc_run 1 "A1 worktree commit is linted against the worktree's staged set" "$WT" "$CONTRACT" --staged
lc_out_has "verify-parallel-wave" "A1"

# A2 - the same instant, cwd at the main tree: its index is empty, so nothing is checked.
# This is what proves A1 read the worktree's index rather than simply checking everything.
lc_run 0 "A2 main tree's own (empty) index checks nothing" "$FIX" "$CONTRACT" --staged

# A3 - content follows the tree being committed. Restore the worktree's file, stage it, and
# break the MAIN tree's copy of the same path: the worktree commit must stay green.
python3 -c "
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace('the wave checker', 'verify-parallel-wave')
open(p, 'w', encoding='utf-8').write(s)" "${WT}/commands/implement.md" || { echo "INFRA: worktree restore failed" >&2; exit 3; }
g "$WT" add -- commands/implement.md >/dev/null 2>&1
lc_edit commands/implement.md "s = s.replace('chunk-id | phase', 'chunk id and phase')"
lc_run 0 "A3 content is read from the committing tree, not from the script's own tree" "$WT" "$CONTRACT" --staged
lc_restore

# A4 - the SAME split in lint-skill-size.sh: a Rule-2 marker violation staged in the
# worktree must fail there. lint-skill-size.sh is the check pre-commit has always run, so
# it carried the blind spot for every worktree commit made until now.
python3 -c "
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace('<!-- CONTRACT-CORE-END -->', '', 1)
open(p, 'w', encoding='utf-8').write(s)" "${WT}/commands/implement.md" || { echo "INFRA: worktree marker edit failed" >&2; exit 3; }
g "$WT" add -- commands/implement.md >/dev/null 2>&1
lc_run 1 "A4 size lint sees the worktree's staged marker violation" "$WT" "$SIZE" --staged
lc_out_has "CONTRACT-CORE-END" "A4"

# A5 - and the size lint's full mode still reads its OWN tree (the main fixture), which is
# intact, so the two modes are not silently the same thing.
lc_run 0 "A5 size lint --all reads the script's own tree" "$WT" "$SIZE" --all

g "$FIX" worktree remove --force "$WT" >/dev/null 2>&1 || true

lc_finish '{"worktree_staged":"exit 1 from the worktree index","main_tree_index":"empty -> exit 0","content_authority":"the committing tree in --staged mode","size_lint":"same split, exit 1 on a staged marker violation"}' \
  "5 assertions (linked-worktree index + content resolution for both lints)"
