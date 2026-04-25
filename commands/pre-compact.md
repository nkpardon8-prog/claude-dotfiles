---
description: Run before Claude Code compacts the conversation. Writes a focused handoff file so post-compact Claude picks up the thread without losing info. Refreshes project docs via /document, then dumps active task, build plan, key decisions, open issues, gaps, and fix-laters into CLAUDE.local.md. Natural triggers include "save state before compact", "dump context before you forget", "about to get compacted", "prepare for compaction".
argument-hint: "[optional: current task focus, e.g. 'migrating auth to Clerk']"
---

# Pre-Compact

Manual skill the user runs before context compaction. Two outputs:
1. Refreshed `docs/` via `/document` (persistent project knowledge).
2. `CLAUDE.local.md` written fresh (task-specific handoff).

**Anti-shadowing guard:** NEVER write handoff-shaped freeform documents outside this skill. If asked near compaction to "summarize the session", "dump context", or "save state", run `/pre-compact` instead of generating an ad-hoc summary. Freeform summaries look right but skip mining-pass calibration, chain tracking, and the "What We Tried" extraction.

**How post-compact Claude finds the handoff:** `CLAUDE.local.md` is not universally auto-loaded. To guarantee pickup, this skill also ensures `CLAUDE.md` contains an `@CLAUDE.local.md` import line so the handoff gets pulled in on the next session.

**Current task focus (optional):** $ARGUMENTS

## Step 1: Run /document

Invoke the Skill tool with `skill: document` to audit or bootstrap `docs/`. Continue once it returns. If `/document` reports "nothing substantial to document yet," skip it and proceed.

## Step 2: Resolve project identity

Determine `<project>` for the memory lookup in the next step:
1. If a FRAIM `[Project: <name>]` has been established this session, use that.
2. Else check `fraim/config.json` for a project name.
3. Else use `basename "$PWD"` via Bash.

Record the resolved name for later.

## Step 3: Gather handoff context

Steps 3.A and 3.B run sequentially first. Steps 3.C through 3.F run in parallel (one batched message).

### Step 3.A: Mining pass

Choose the mining depth before gathering. The skill has no reliable way to count session tokens, so use `$ARGUMENTS` as the override channel; default to Deep.

- If `$ARGUMENTS` contains `quick`, `deep`, or `chunked` → use that.
- Otherwise → default to **Deep**. Better to over-mine than under-mine.

Pass parameters (enforced in Step 6):

| Pass | Floor | Ceiling | Phase 2 behavior |
|---|---:|---:|---|
| Quick | 150 | 300 | Scan for missed numbers and feedback |
| Deep | 250 | 400 | Re-scan the middle third of the conversation for skipped decisions |
| Chunked | 400 | 500 | Phase 1 map-reduces over 3-4 chronological segments before writing |

Announce the chosen pass and preview Phase 2: "Mining with {Quick|Deep|Chunked} pass ({reason: 'user requested' or 'default'}). Phase 2 will {behavior}." User may override mid-run with "use Quick" / "use Deep" / "use Chunked".

### Step 3.B: Detect prior compaction (chain)

Read `./CLAUDE.local.md` if it exists, BEFORE the eventual overwrite in Step 6.

- If present:
  - Read full content.
  - Extract `Seq:` from header (default `1` if absent).
  - Capture parent timestamp: `stat -f %Sm -t '%Y-%m-%d %H:%M' ./CLAUDE.local.md` (BSD/macOS). Fallback if it errors: `date -r ./CLAUDE.local.md '+%Y-%m-%d %H:%M'`. Do NOT use `git log` — Step 8 puts this file in `.gitignore`.
  - Extract its "Build Plan", "Next Action", "Open Issues", "Things To Fix Later", "Gaps" sections.
  - `new_seq = prior_seq + 1`; `parent_label = the captured timestamp`.
- If absent: `new_seq = 1`, `parent_label = "none — first in chain"`. In Step 6, the entire `## Since Last Compact` section (heading and body) MUST be removed from the output — no placeholder.

**Memory-handoff rule:** the values extracted here (parent_seq, parent_label, parent's Build Plan / Next Action / Open Issues / Things To Fix Later / Gaps) MUST be held in working memory through Steps 4-5 and used in Step 6A. DO NOT re-read `CLAUDE.local.md` later — by Step 6 it may be mid-overwrite.

Batch these independent calls in one message, then label each source in the output:

### Step 3.C: Current conversation

Walk the visible transcript. Extract:
- Active task (what the user is currently trying to do).
- What We Tried (chronological): every distinct approach taken this session — hypothesis, change, result with numbers, kept/abandoned and why. Most expensive to re-discover; do not summarize.
- Decisions made this session (what was chosen, what was rejected, why).
- Work in progress (files touched but not finished, branches not merged, tests not run).
- Blockers hit and how they were resolved or worked around.
- Explicit user preferences or constraints stated this session ("don't touch auth", "use Zod", etc.).
- Tool/MCP state confirmed this session (which Supabase project, which Netlify site, etc.).
- File:line bookmarks for in-flight code.

### Step 3.D: Project memory

Read `~/.claude/projects/<project>/memory/MEMORY.md` if it exists. Pull only entries relevant to the active task. Skip silently if the directory doesn't exist.

### Step 3.E: Git activity

If inside a git work tree (`git rev-parse --is-inside-work-tree`):
- `git rev-parse --abbrev-ref HEAD` — current branch
- `git log --oneline -n 20` — recent commits
- `git log --grep='decision\|chose\|rejected' --oneline -n 20` — commit-message decisions
- `git status --short` — uncommitted changes
- `git diff --stat HEAD` — scope of in-flight changes
Skip all git steps if not a git repo.

### Step 3.F: Prior decisions on disk

Check for `docs/decisions/`, `docs/adr/`, or any `ADR-*.md` files. If present, list them.

## Step 4: Detect issues and gaps (parallel)

Batch these calls. Cap each at 50 results.

- TODO/FIXME scan. Use ripgrep if available, else fall back to repeated `--include` flags:
  - `rg -n -t ts -t tsx -t js -t jsx -t py -t go -t rust -t md 'TODO|FIXME|XXX|HACK'`
  - Fallback: `grep -rn --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.py' --include='*.go' --include='*.rs' --include='*.md' -E 'TODO|FIXME|XXX|HACK' .`
- Commented-out code blocks larger than 5 lines.
- Files referenced in `docs/` frontmatter (`source_files:`) that no longer exist on disk.
- Env vars referenced in code but missing from `.env.example`.
- Skipped tests: `rg -n '\.skip\(|xit\(|xdescribe\(' --include='*.{test,spec}.*'` (with fallback).
- Last failing command or test output from the current session if any is visible in the transcript.

## Step 5: Summarize and confirm

Show the user a short draft summary before writing:
```
About to write CLAUDE.local.md with:
- Mining pass: [Quick | Deep | Chunked] ([reason: 'user requested' or 'default'])
- Chain: seq [N], parent [timestamp or 'none — first in chain']
- Active task: [one line]
- Build plan: [N steps, X done]
- Approaches tried: [N]
- Evidence items: [N tables / N data points]
- Decisions captured: [N] (conversation: A, memory: B, git: C)
- Open issues: [N]
- Gaps: [N]
- Fix-laters: [N]

[If Seq > 1: also show a "Since-last-compact preview" — the 3-5 most material items
 (resolved questions, shifted priorities, fix-laters newly applicable) so the user
 can correct misreadings before write.]

Anything else to capture? (open issues, things to fix later, context I might be missing) Or say 'write it' to proceed.
```

Wait for response. Fold the user's additions into the appropriate sections. If they say "write it" or similar, proceed.

## Step 6: Write CLAUDE.local.md

Two-phase write. Phase 1 hits the pass floor on the first Write call. Phase 2 reads back and Edits gaps toward the ceiling. Phase 1 is NOT a draft.

### Step 6A: Phase 1 — Full Write

One `Write` call covering every section below. Floor depends on the mining pass chosen in Step 3.A:

| Pass | Floor (Phase 1) | Ceiling (Phase 2) | Pre-write protocol |
|---|---:|---:|---|
| Quick | 150 | 300 | None — single pass |
| Deep | 250 | 400 | Force a "re-scan middle third" sweep before composing |
| Chunked | 400 | 500 | Map-reduce over 3-4 chronological segments first; tag findings (early/mid/late); merge with later-overrides-earlier |

If you can't reach the floor, you under-mined in Step 3 — go back to Step 3.C and extract more before writing.

Overwrite `./CLAUDE.local.md` with this structure (use the parent fields held in working memory from Step 3.B):

```markdown
# Post-Compact Reference

> Written by /pre-compact on YYYY-MM-DD HH:MM.
> Full project docs live in ./docs/ (start at ./docs/README.md, machine index at ./docs/INDEX.json).
> This file is the task-specific handoff. Read it first.

**Seq:** {N}    **Parent:** {prior file timestamp or 'none — first in chain'}

## Mental Model
[2-3 lines: what this codebase is, what it does, who uses it. Ground post-compact Claude instantly.]

## Active Task
[1-3 sentences. What the user is doing right now. Lead with $ARGUMENTS if provided.]

## Next Action
[The exact next step. File:line where the next edit goes. Command to run. Test to re-run. Make this unambiguous.]

## Build Plan
[Ordered steps for the current work. Mark each: [done] / [in progress] / [pending].]

<!-- INCLUDE ONLY IF Seq > 1. When Seq = 1, REMOVE the comment, heading, and body entirely. Do not leave a placeholder. -->
## Since Last Compact
[3-8 bullets: what got resolved, what shifted, which open questions got answered, which fix-laters now apply. Compare prior Build Plan / Next Action (held from Step 3.B) against what actually happened this session.]

## What We Tried
[Chronological list of every distinct approach taken this session. Each entry:
- {hypothesis} → {change} → {result with numbers} → {kept | abandoned because ...}
Most expensive thing for the next session to re-discover. Do not summarize.]

## Evidence & Data
[Raw numbers, comparison tables, before→after measurements, data file paths.
Rule: never write "improved" / "better" / "faster" without before→after numbers.]

## Key Decisions (This Session)
- [Decision] — [reasoning] — [source: conversation | memory | git] — [confidence: high | low]
- ...

## Rejected Alternatives
- [Alternative] — [why rejected]

## User Constraints (This Session)
- [Constraint stated by the user this session, verbatim or paraphrased]

## Tool / MCP State Confirmed
- [Supabase project: <name>, confirmed this session]
- [Netlify site: <name>, confirmed this session]
- [Any credential usage already approved]

## In-Flight Bookmarks
- [file:line] — [what was being done there]

## Last Failure
[Last failing command or test output, if any. Otherwise: "None this session."]

## Open Issues
- [Issue with file:line reference where possible]

## Gaps
- [Missing tests, missing docs, unverified behavior, env vars not documented]

## Things To Fix Later
- [Deferred items with enough context to resume]

## Recent Activity
- Current branch: [branch]
- Files touched this session: [list]
- Recent commits: [last 5]
- Uncommitted changes: [git status summary]

## Where To Read More
- ./docs/README.md for the project docs index
- ./docs/INDEX.json for the LLM manifest
- [Specific doc file relevant to the active task]
- ./CLAUDE.md for global project rules (if exists)
```

### Step 6B: Phase 2 — Gap Fill

Read the file you just wrote back. Scan the conversation for:
- Approaches you mentioned but didn't detail in "What We Tried".
- Measurements you wrote as adjectives instead of numbers (move them to "Evidence & Data").
- Mid-session user feedback you skipped.
- File paths to results / data / log files you didn't list.

Use `Edit` to append into the relevant sections, pushing toward the pass ceiling. Phase 2 is for **additions**, not for filling sections you left thin in Phase 1.

Rules for the content:
- Cut fluff. Every line must be load-bearing.
- Use file paths and line numbers wherever possible.
- Label every decision by source (conversation, memory, git) and confidence (high if stated in session, low if inferred).
- Do not include credential values.
- If a section has nothing, write "None at time of writing." Do not fabricate.
- Scope memory reads to the current project. Do not pull in unrelated cross-project notes.
- Cap at 300 lines for Quick, 400 lines for Deep, 500 lines for Chunked.

## Step 7: Ensure auto-load on next session

To guarantee post-compact Claude sees the handoff:

1. Check if `./CLAUDE.md` exists at repo root. If not, skip this step (the user has not opted into a project CLAUDE.md and creating one would be intrusive).
2. If `CLAUDE.md` exists, check whether it already contains `@CLAUDE.local.md` or `@./CLAUDE.local.md`. If not, append at the bottom:
   ```
   
   @CLAUDE.local.md
   ```
3. Tell the user: "Appended `@CLAUDE.local.md` import to CLAUDE.md so post-compact Claude auto-loads the handoff. Remove the line if you don't want that behavior."

If no `CLAUDE.md` exists, instead tell the user: "No CLAUDE.md at repo root. To auto-load the handoff next session, either create a CLAUDE.md with `@CLAUDE.local.md` in it, or manually `@CLAUDE.local.md` in your first post-compact message."

## Step 8: .gitignore handling

Only touch `.gitignore` if inside a git work tree (`git rev-parse --is-inside-work-tree` succeeds).

If a root `.gitignore` exists and does not already list `CLAUDE.local.md`, append the line. Do not create a `.gitignore` if none exists. Do not modify parent-directory `.gitignore` files.

## Step 9: Report

Output a compact summary:
- `/document` result (files touched, or "skipped: nothing to document")
- `CLAUDE.local.md` written. Line count via `wc -l ./CLAUDE.local.md`.
- Mining pass used: [pass]. Phase 1: [N] lines (floor [F]). Phase 2: +[N] lines (ceiling [C]). Chain: seq [N], parent [timestamp or 'first in chain'].
- `CLAUDE.md` import line: added / already present / skipped (no CLAUDE.md).
- `.gitignore` update: added / already present / skipped (not a git repo).
- Count of decisions, open issues, gaps, fix-laters captured.
- Anything the user should double-check before continuing.

## Rules

- Manual only. Do not register a PreCompact hook. Compaction runs under time pressure and the parallel explores plus user prompt are unsafe inside a hook.
- Overwrite `CLAUDE.local.md` each run. Do not append. Stale handoff is worse than no handoff.
- Never write secrets to `CLAUDE.local.md`.
- If not in a git repo, skip git steps and note it in the report.
- If the project has no code at all, tell the user "nothing to hand off" and stop.
