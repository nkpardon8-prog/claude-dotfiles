# Worktree Hygiene

## Clean up your own worktree, but only once the work is done
Every task worktree leaves a full copy of the repo (1-2 GB with `node_modules`) behind; left alone they
fill the disk. The agent that made a worktree clears it, and only when **all** of these are true:
1. Its branch has landed on the base branch, or been merged/pushed the way the owner asked.
2. Its tests and checks passed **after** landing. Never clean up mid-task or to "make room".
3. The context is saved: handoff / `CLAUDE.local*.md`, plans, `tmp/` evidence, docs updates.

## What to clear
- Default: delete only that worktree's `node_modules` (the root and the app subfolders one level
  down). Code, `tmp/`, notes and the branch all stay.
- Remove the whole worktree only if no other `/line`-named chat, preview or agent uses it. Archive its
  untracked files (`tmp/`, `CLAUDE.local*`, plans) first; `/worktree-cleanup` does this.
- Never delete branches, chat history, or another chat's worktree.

## Never touch
- A worktree with a running process, preview server, or open window inside it.
- A folder other worktrees clone packages from, a prod/release lane, or anything containing a `KEEP`
  file (an empty `KEEP` in a worktree's top folder means "always skip").

## Starting a new worktree
Start it fresh off the current base branch (`git fetch` first). Clone `node_modules` from an
up-to-date worktree (`cp -c -R`) rather than a fresh install: clones share disk space. `git stash` is
shared across all worktrees of a repo, so never run a bare `git stash pop`.

## Freed space shows up late
Deleting many cloned files frees space in the background over hours; check `df` again later before
concluding a cleanup did not work.

(SCOPE: worktrees you created for your own task. Bulk cleanups of other chats' worktrees go through
`/worktree-cleanup`, which asks each owner first.)
