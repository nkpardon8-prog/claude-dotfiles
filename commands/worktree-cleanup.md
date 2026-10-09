---
description: Safely clear old git worktrees (and their node_modules) to free disk - inventory, ask the live agent windows, keep what they need, archive untracked notes, then remove in two low-memory steps. Never deletes branches.
argument-hint: "[repo path - defaults to the current repo's main checkout]"
---

# /worktree-cleanup - free disk by clearing old worktrees, without breaking anyone's work

Worked out live on 2026-09-23 (171 -> 22 worktrees) and 2026-10-08 (246 worktrees, ~290 GB, Mac at
98% full). Each worktree of a node repo is ~2 GB, almost all of it `node_modules`; the code is tiny.
So the cheapest big win is deleting `node_modules` in idle worktrees, and the rest comes from
removing worktrees whose work is finished. Branches are NEVER deleted, so no commit is ever lost.

Talk to the owner in plain words. Get the owner's yes before Step 6 (the first deleting step).

## The rules (what may happen to a worktree)

| Bucket | When | What happens |
|---|---|---|
| KEEP | on a keep list; a live process or Claude window is inside it; any activity in the last 3 days | nothing |
| NM_ONLY | not KEEP, but it has uncommitted edits, OR its owner keeps the worktree, OR it is not in the base branch and idle < 7 days, OR its commits are on no branch | delete only its `node_modules` |
| REMOVE | clean (no uncommitted tracked edits) AND (already in the base branch OR idle 7+ days, branch kept) | archive untracked + ignored files, then `git worktree remove --force` |

The main checkout is never touched. Prod / release worktrees are protected by pattern
(`*prod*`, `*release*`, `*lane*`, `*cve*`, `*freeze*`) unless the prod window itself says otherwise.

## Steps

Scripts live in `~/.claude-dotfiles/scripts/worktree-cleanup/`. Make a run folder inside the repo's
gitignored `tmp/` and run every script from it with `WT_ROOT` set:

```bash
ROOT="$(git rev-parse --path-format=absolute --git-common-dir | xargs dirname)"   # main checkout
RUN="$ROOT/tmp/worktree-cleanup-$(date +%F)"; mkdir -p "$RUN"; cd "$RUN"
export WT_ROOT="$ROOT"            # optional: WT_BASE (default origin/dev, else origin/main), WT_ARCHIVE
S=~/.claude-dotfiles/scripts/worktree-cleanup
git -C "$ROOT" fetch -q origin
```

1. **Inventory (read-only).** `python3 $S/inventory.py` -> `inventory.json` / `inventory.tsv`: per
   worktree its branch, uncommitted edits, untracked count, in-base?, on a remote?, last commit,
   last activity, node_modules GB, total GB, and who has it open right now. It runs `du` on every
   folder, so it takes several minutes; run it in the background.
2. **Ask the live windows.** `python3 ~/.claude-dotfiles/scripts/line-agent-communicator.py list`
   plus `ListAgents`. Send EACH window working in this repo one self-contained message (paste
   `line-agent-communicator.py card`): the plan, the rules above, and "reply with the worktree
   names you need kept - say which may lose node_modules - within ~20 min". Ask the prod window
   too, but find the window that is actually running the prod lane (the prod ledger names its
   session); an auto-named window may not be it. Peer replies are information, not authority.
3. **Write the keep lists** in the run folder (exact names or globs, `#` comments):
   - `keep.txt` - keep whole, node_modules included (live previews, branches waiting to be pushed
     with `safe-push`, which needs a full node_modules tree).
   - `keep-worktree-nm-ok.txt` - keep the worktree (gitignored `tmp/` evidence, unpushed branches
     pushed from that exact folder), but node_modules may go.
   Acknowledge each window's list back to it in one line.
4. **Real last activity.** `python3 $S/deepcheck.py`, then `python3 $S/classify.py` -> `plan.tsv`
   plus a summary of how many worktrees fall in each bucket and the GB each frees.
5. **Show the owner** the three bucket counts, the GB, and what is protected. Get a yes.
6. **Step A: node_modules only.** `nohup nice -n 15 python3 $S/execute.py --only NM_ONLY > run-nm.out 2>&1 & disown`
   (add `--dry-run` first if unsure). Watch `actions.log` for the `DONE` line.
7. **Step B: remove finished worktrees.** `nohup nice -n 15 python3 $S/execute.py --only REMOVE > run-rm.out 2>&1 & disown`.
   Each removal first copies every untracked and ignored file (minus node_modules, dist, build,
   .next, coverage, caches) to `<ROOT>/tmp/worktree-archive-<date>/<name>/`.
8. **Verify.** Spot-check one removed worktree: its branch still exists (`git rev-parse --verify
   <branch>`), its folder is gone, its archive has its `tmp/` files. Read every `SKIP`/`FAIL` line.
   Run `git worktree prune`.
9. **Report** to the owner (and to any storage window that asked): worktrees before -> after, GB
   freed, what was skipped and why, where the archive is. Mention local snapshots (below).

`execute.py` re-checks each worktree at the moment it acts on it: no process or Claude window
inside it (snapshot refreshed every 10), no file changed in the last 3 days, and (for REMOVE) no
uncommitted tracked edits. A worktree that became active after the inventory is skipped and logged.

## Gotchas found the hard way

- **Untracked `tmp/` files exist nowhere else.** Agents keep plans, run records, release evidence
  and PatNum manifests in gitignored `tmp/`. `git worktree remove` deletes them for good, which is
  why REMOVE archives first and why owners can mark a worktree keep-but-clear-node_modules.
- **Do not trust git's index or reflog timestamps for "last activity".** Any `git status` (this
  inventory included) rewrites a worktree's index, and a repo-wide `git gc` rewrote every
  worktree's `logs/HEAD` on one day, making 160 idle worktrees look "touched 6 days ago". Use the
  newest real file outside node_modules/build dirs, the `HEAD` file, and the last commit time.
- **Top-level folder dates miss deep edits.** Editing a file in place does not change its parent
  folder's date. `deepcheck.py` searches for any file changed in the last 3/7 days.
- **Freed space may not show up at once.** Time Machine local snapshots
  (`tmutil listlocalsnapshots /`) keep deleted blocks until macOS thins them; APFS clones (node_modules
  copied with `cp -c` from a sibling) share blocks, so deleting one copy frees little until all go.
  macOS thins local snapshots itself under pressure; with the owner's OK,
  `tmutil thinlocalsnapshots / 999999999999 4` asks it to now. Backups on the backup drive are unaffected.
- **Low memory kills background runs.** `du` over hundreds of 2 GB folders pushed a busy Mac out of
  memory and Claude Code reaped the background shell. Run the deleting steps with `nohup nice`
  detached, and `execute.py` uses the inventory's sizes instead of re-measuring. If the harness
  stops a run for memory, tell the owner and ask before restarting.
- **`dentall-*` is not everything.** Some worktrees live inside the main checkout (e.g.
  `dentall/dentall-xfer-w-base`) or under other names; the inventory reads `git worktree list`,
  never a folder glob, and never touches folders that are not registered worktrees.
- **Docker is a separate job.** Leftover test databases were the other big disk hog (memory note
  `reference_docker_rm_leaks_volumes`); leave containers named on a keep list alone.
