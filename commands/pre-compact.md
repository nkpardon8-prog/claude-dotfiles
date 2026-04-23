---
description: Run before Claude Code compacts the conversation. Refreshes project docs via /document, then writes a focused post-compact reference file (CLAUDE.local.md) with task-specific context, build plan, key decisions, open issues, and gaps so post-compact Claude picks up the thread without losing information.
argument-hint: "[optional: current task focus, e.g. 'migrating auth to Clerk']"
---

# Pre-Compact

Manual skill the user runs before context compaction. Two outputs:
1. Refreshed `docs/` via `/document` (persistent project knowledge).
2. `CLAUDE.local.md` written fresh (task-specific handoff that post-compact Claude auto-loads).

**Current task focus (optional):** $ARGUMENTS

## Step 1: Run /document

Invoke the `/document` skill to audit or bootstrap `docs/`. This covers the durable, project-level knowledge. Continue once it returns.

## Step 2: Gather handoff context

Pull from three sources in parallel and label each:

**A. Current conversation.** Walk the visible transcript. Extract:
- What the user is currently trying to do (the active task).
- Decisions made in this session (what was chosen, what was rejected, why).
- Work in progress (files touched but not finished, branches not merged, tests not run).
- Blockers hit and how they were resolved or worked around.
- Explicit user preferences stated during the session.

**B. Memory.** Read `~/.claude/projects/<project>/memory/MEMORY.md` if it exists. Pull entries relevant to the current task. If no project memory directory exists, skip.

**C. Recent git activity.** Run `git log --oneline -n 20` and `git status`. Capture recent commit themes and uncommitted changes. Skip if not a git repo.

## Step 3: Detect issues and gaps

Scan in parallel:
- `grep -rn "TODO\|FIXME\|XXX\|HACK" --include='*.{ts,tsx,js,jsx,py,go,rs,md}'` (cap at 50 results)
- Commented-out code blocks larger than 5 lines
- Files referenced in `docs/` that no longer exist
- Env vars referenced in code but missing from `.env.example`
- Failing or skipped tests (`grep -rn "\.skip\|xit\|xdescribe"`)

Then ask the user once: "Anything else to capture before compaction? (open issues, things to fix later, context I might be missing)" Wait for response. If they say no or skip, continue.

## Step 4: Write CLAUDE.local.md

Overwrite `./CLAUDE.local.md` with this structure. Claude Code auto-loads this file on session start, so post-compact Claude will see it without being told.

```markdown
# Post-Compact Reference

> Written by /pre-compact on YYYY-MM-DD HH:MM.
> Full project docs live in ./docs/ (start at ./docs/README.md).
> This file is the task-specific handoff. Read it first.

## Active Task
[1-3 sentences. What the user is doing right now. If $ARGUMENTS was provided, lead with that.]

## Build Plan
[The overall plan for the current work. Ordered steps. Mark each as done / in progress / pending.]

## Key Decisions (This Session)
- [Decision] — [reasoning] — [source: conversation | memory | git]
- ...

## Rejected Alternatives
- [Alternative] — [why rejected]

## Open Issues
- [Issue with file:line reference where possible]

## Gaps
- [Missing tests, missing docs, unverified behavior, env vars not documented]

## Things To Fix Later
- [Deferred items with enough context to resume]

## Recent Activity
- Files touched this session: [list]
- Recent commits: [last 5 from git log]
- Uncommitted changes: [git status summary]

## Where To Read More
- ./docs/README.md for the project docs index
- [Specific doc file relevant to the active task]
- ./CLAUDE.md for global project rules (if exists)
```

Rules for the content:
- Cut fluff. Every line must be load-bearing.
- Use file paths and line numbers wherever possible so post-compact Claude can verify.
- Label every decision by source (conversation, memory, or git) so future-Claude knows what is claim vs. record.
- Do not include credential values.
- If a section has nothing, write "None at time of writing." Do not fabricate.
- Never write more than 300 lines total. If it would be longer, tighten.

## Step 5: Verify and report

- Confirm `CLAUDE.local.md` exists at repo root.
- Confirm it is in `.gitignore` (add if missing, since it holds task state not meant for version control).
- Output a compact summary:
  - `/document` result (files touched)
  - `CLAUDE.local.md` written (line count)
  - Count of decisions, open issues, gaps, fix-laters captured
  - Anything the user should double-check before continuing

## Rules

- This is manual only. Do not register a PreCompact hook.
- Overwrite `CLAUDE.local.md` each run. Do not append. Stale state is worse than no state.
- Never write secrets to `CLAUDE.local.md`.
- If not in a git repo, skip git steps and note it in the report.
