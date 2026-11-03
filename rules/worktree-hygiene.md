# Worktree Hygiene

## Clean up your own worktree, but only once the work is done
Every task that gets its own git worktree leaves a full copy of the repo (about 1-2 GB with
`node_modules`) behind unless someone removes it. On 2026-11-01 dentall had piled up to 284 of them and
the Mac was at 100% full. So the agent that made a worktree is responsible for clearing it, and only
when **all** of these are true:
1. Its branch has landed on the base branch (dev) or been merged/pushed the way the owner asked.
2. Its tests and checks passed **after** landing. Never clean up mid-task or to "make room".
3. The context is saved: handoff / `CLAUDE.local*.md`, plans, `tmp/` evidence, and any docs updates.

## What to clear
- Default: delete only that worktree's `node_modules` (root and one level down, e.g. `server/`,
  `client/`, `admin-*/`). Code, `tmp/`, notes and the branch all stay.
- Remove the whole worktree only if no other `/line`-named chat, preview, or agent uses it. Archive its
  untracked files (`tmp/`, `CLAUDE.local*`, plans) first; `/worktree-cleanup` does this.
- Never delete branches, chat history, or another chat's worktree.

## Never touch
- A worktree with a running process, preview server, or open window inside it.
- A folder other worktrees clone packages from, a prod/release lane, or anything containing a `KEEP` file
  (an empty file named `KEEP` in a worktree's top folder means "always skip").

## Starting a new worktree
Prefer cloning `node_modules` from an existing up-to-date worktree (`cp -c -R`) over a fresh
`npm install`: clones share disk space, while a fresh install costs about 1.8 GB each.

## Freed space shows up late
Deleting many cloned files frees space in the background over hours, so `df` right after a cleanup
undercounts. Check again later before concluding a cleanup "didn't work".

(SCOPE: worktrees you created for your own task. Bulk cleanups of other chats' worktrees go through
`/worktree-cleanup`, which asks each owner first.)
