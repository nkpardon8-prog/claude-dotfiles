# Post-Compact Reference

> Written by /pre-compact on YYYY-MM-DD HH:MM.
> Full project docs live in ./docs/ (start at ./docs/README.md, machine index at ./docs/INDEX.json).
> This file is the task-specific handoff. Read it first.

**Seq:** {N}    **Parent:** {prior file timestamp or 'none — first in chain'}

## Mental Model
[2-3 lines: what this codebase is, what it does, who uses it. Ground post-compact Claude instantly.]

## Active Skill State
<!-- Populated by Step 3.G. If no skill detected, write: "No active skill detected — generic continuation. See ## Next Action below." Otherwise: -->
- Detected skill: [/plan | /implement | /discussion | /master-review | /god-review | /god-report | /codex-review | none]
- Phase indicator: [skill-specific, e.g. "mid review round 2", "implement Phase 3 of 5", "Phase 2 of god-review round 4 (consecutive_clean=1)"]
- Critical artifacts to preserve: [paths to in-flight files, e.g. ./tmp/ready-plans/foo.md, tmp/god-review/state.json]
- Resumption directive: [skill-specific Next Action template from Step 3.G — verbatim]
- Loop state (if applicable):
  - Exit criterion: [e.g., "3 consecutive clean rounds" for /god-review]
  - Current standing: [e.g., "1 of 3 clean; round 4 had 8 new findings"]
  - Iteration / round number: [N]
- Self-assessment (optional): confidence work is complete ~N%; unresolved doubt: [one specific concern]

## Active Task
[1-3 sentences. What the user is doing right now. Lead with $ARGUMENTS if provided.]

## Next Action
[The exact next step. File:line where the next edit goes. Command to run. Test to re-run. Make this unambiguous.]

## Build Plan
[Ordered steps for the current work. Mark each: [done] / [in progress] / [pending].]

<!-- Omit section entirely if single-thread session (no parallel work streams). -->
## Work Streams
<!-- Populate if the session touched 2 or more distinct subsystems/threads. Omit
section entirely if single-thread. Each stream gets its own ### subheading. -->
### Stream 1: <name>
- Status: in-progress | paused | blocked | done | implement chunk N of M shipped
- Files touched: [path list]
- Last known state: [1-2 lines]
- Stream-specific next action: [specific command or file:line]
- Blockers (if any): [link to Pending Externals if external]

<!-- INCLUDE ONLY IF Seq > 1. When Seq = 1, REMOVE the comment, heading, and body entirely. Do not leave a placeholder. -->
## Since Last Compact
[3-8 bullets: what got resolved, what shifted, which open questions got answered, which fix-laters now apply. Compare prior Build Plan / Next Action (held from Step 3.B) against what actually happened this session.]

## What We Tried
[Chronological list of every distinct approach taken this session. Each entry:
- {hypothesis} → {change} → {result with numbers} → {kept | abandoned because ...}
Most expensive thing for the next session to re-discover. Do not summarize.]

<!-- Omit section entirely if not applicable. -->
## Live Hypotheses
<!-- Half-formed "I suspect X but haven't proven" thinking. Omit section if none. -->
- HYPOTHESIS: [statement]
  - Evidence pointing here: [list]
  - NOT YET TRIED: [next experiment]
  - Confidence: N%

## Evidence & Data
[Raw numbers, comparison tables, before→after measurements, data file paths.
Rule: never write "improved" / "better" / "faster" without before→after numbers.]

### Surprising Discoveries
<!-- System-level facts uncovered this session. Permanent truths, not try-results.
Anti-duplication: only include here if the fact is NOT already captured
as a result line in What We Tried. Do not duplicate. -->
- [discovery] — [where observed] — [implication]

<!-- Omit section entirely if no reviewers ran this session. -->
## Review/Fix Loop Ledger
<!-- Per-iteration trail for sessions involving reviewers (codex/claude/impl/plan/
master/god). Omit section if no reviewers ran. -->
| Round | UTC | Reviewer(s) | Findings (crit/non-crit) | Fixes applied | Verification |
|---|---|---|---|---|---|
| R1 | YYYY-MM-DDTHH:MMZ | codex-review | 13/47 | 13 files, tests rerun | passed |
| R2 | ... | ... | ... | ... | ... |

## Key Decisions (This Session)
- [Decision] — [reasoning] — [source: conversation | memory | git] — [confidence: high | low]
- ...

## Rejected Alternatives
- [Alternative] — [why rejected]

<!-- Omit section entirely if not applicable. -->
## Footguns Discovered This Session
<!-- Operational "do not repeat" — distinct from Rejected Alternatives (design). -->
- DO NOT [action] — [consequence observed this session]

## User Constraints (This Session)
- [Constraint stated by the user this session, verbatim or paraphrased]

<!-- Omit section entirely if not applicable. -->
## User Wishes & Asides
<!-- Forward-looking desires expressed in passing. Distinct from User Constraints
(hard rules) and Mid-Session Feedback (reactive). -->
- "[verbatim or near-verbatim quote]" — [context if non-obvious]

## Tool / MCP State Confirmed
- [Supabase project: <name>, confirmed this session]
- [Netlify site: <name>, confirmed this session]
- [Any credential usage already approved]

<!-- Omit section entirely if not applicable. -->
## Pending Externals
<!-- External dependencies, waits, blocked-on-people, scheduled-for-later,
background tasks (run_in_background agents, scheduled wakeups). Omit if none. -->
- Waiting on: [person/system] — [item] — [last contact date]
- Scheduled: [event] at [time] — [verification command]
- Background: [process or agent] — [purpose] — [status check command]
- User will: [action] [when]

## In-Flight Bookmarks
- [file:line] — [what was being done there]

## Last Failure
[Last failing command or test output, if any. Otherwise: "None this session."]

## Open Issues
- [Issue with file:line reference where possible]

### Deliberately Skipped Tests
- [test name/path] — [reason skipped this session — distinct from forgot]

<!-- Omit section entirely if not applicable. -->
## Deferred-for-Human Queue
<!-- Items the orchestrator deliberately punted for human attention. Distinct from
Open Issues (bugs) and Things To Fix Later (debt). HUMAN_GATE_QUEUE-style. -->
- [item description] — [why deferred to human] — [link to relevant artifact]

## Gaps
- [Missing tests, missing docs, unverified behavior, env vars not documented]

## Things To Fix Later
- [Deferred items with enough context to resume]

## Recent Activity
- Current branch: [branch]
- Files touched this session: [list]
- Recent commits: [last 5]
- Uncommitted changes: [git status summary]

## Mid-Session User Feedback
**Workflow pattern this session:** [e.g., "/script → /implement → /codex-review until clean, repeated 3x"]
- [Verbatim or near-verbatim quote from the user about what happened, what worked, what to change]
- [Any mid-session corrections, redirects, or approvals from the user]

## Where To Read More
- ./docs/README.md for the project docs index
- ./docs/INDEX.json for the LLM manifest
- [Specific doc file relevant to the active task]
- ./CLAUDE.md for global project rules (if exists)
- References consulted this session:
  - [URL or path] — [what was checked there]
