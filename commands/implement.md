---
description: Executes an approved plan with one primary implementation stream by default, using bounded parallel sidecars only when the write scopes are truly disjoint. Supports default Claude execution or an explicit Codex executor option. Automatically reviews the result for completeness and intent fidelity. Use after a plan is approved.
argument-hint: "[plan file path] [claude|codex|--codex]"
---

# Implementation Agent

## Plan to Execute: $ARGUMENTS

## Step 1: Resolve Executor and Load Plan

Interpret `$ARGUMENTS` as:
- default: Claude execution
- `claude` or `--claude`: explicitly use Claude as the primary executor
- `--codex` or standalone `codex`: use Codex as the primary executor
- any remaining path-like argument: plan path

Examples:
- `/implement ./tmp/ready-plans/2026-04-21-foo.md`
- `/implement claude ./tmp/ready-plans/2026-04-21-foo.md`
- `/implement --codex ./tmp/ready-plans/2026-04-21-foo.md`
- `/implement codex ./tmp/ready-plans/2026-04-21-foo.md`

If Codex execution was explicitly requested but Codex is unavailable
(`command -v codex` fails), do not silently fall back to Claude. Tell the user
and wait for direction.

- If a path is provided after parsing executor flags: Read from that path
- If no path: Find the most recent plan in `./tmp/ready-plans/`

If the plan includes a `Source Artifacts` section or references a supporting
brief / dossier path, read those artifacts too before implementing.

Treat the sources of truth as:
- **Brief / intent artifact**: why this work exists, what outcome matters, and
  what must not be optimized away
- **Plan**: execution shape, task ordering, file-level implementation details
- **Dossier**: supporting evidence and anchors, not the authoritative execution
  contract

If no separate brief artifact exists, treat the plan's `Intent / Why`, `Locked
Decisions`, `Known Mismatches / Assumptions`, and success criteria as the
minimum intent source of truth.

Review the plan to understand: implementation phases, task checklist, technical
requirements, dependencies between tasks, success criteria, and original user
intent.

## Step 2: Identify Dangerous Commands

**BEFORE ANY IMPLEMENTATION**, scan the plan for commands that must NOT be run automatically:

- Environment variable changes
- Package installations that change `package.json`, `requirements.txt`, `Cargo.toml`, `go.mod`, etc.
- Any destructive operations (drops, force-pushes, hard resets)

**Collect into a "Manual Steps" list** and present to the user before proceeding.

> **Note:** Schema/migration handling is done automatically in Step 5.5 after implementation and review — do NOT handle it here.

## Step 3: Choose Execution Strategy

Default to **one primary implementer** owning the plan end-to-end.

Only split work into parallel chunks when **all** of the following are true:
- write scopes are genuinely disjoint
- the integration contract between chunks is already clear in the plan
- parallelism will not hide missing last-mile wiring
- one primary implementer still owns final integration and finish-line checks

Keep these with the primary implementer unless there is an unusually clean
reason not to:
- schema and shared types
- routing / bootstrap / exports
- auth / permissions / tokens
- jobs / async orchestration / dispatch semantics
- final frontend-to-backend wiring

```
Primary stream: schema/types → backend/runtime wiring → frontend wiring → finish-line verification
Optional sidecars: bounded disjoint tasks that cannot break the primary stream's integration work
```

## Step 4: Start the Primary Execution Lane

If the executor is **Claude**:

Use `Task tool` with `subagent_type: "implementer"` for the primary stream.

If you choose to parallelize, keep it bounded:
- **Primary implementer**: owns the mainline path and final integration
- **Sidecar implementers**: own only clearly disjoint file sets
- **Sequential**: wait whenever a later chunk depends on an earlier chunk's result
- Every agent prompt must include: specific tasks, relevant context, file paths, success criteria, and explicit ownership boundaries
- Every agent prompt must include the brief / intent source when available, not
  just the task list
- Tell every implementer that a task is not complete until the end-to-end
  runtime or user-facing path is actually wired and still preserves the brief's
  intended outcome

If the executor is **Codex** and Codex is available:

- **Pre-check write capability before doing anything.** Stock `codex exec` runs in read-only sandbox mode and CANNOT modify files. Probe whether this install supports write mode (`codex exec --help 2>&1 | grep -E '\-\-write|--full-access|--no-sandbox|--workspace-write'`). If write mode is NOT available, **tell the user explicitly: "Codex is read-only on this machine; I'm falling back to Claude as the implementer"** and switch to the Claude path above. Do NOT silently launch a read-only Codex run as the implementer — it will produce zero file edits and look like progress.
- If write mode IS supported, use **one** primary Codex invocation with the appropriate write flag — the example below uses `codex exec --cd "$WORKDIR"` for documentation, but you must add whatever write flag your install requires (e.g. `--workspace-write` or `--full-access` depending on the build).
- Pass the same implementation contract used for the Claude implementer:
  - brief / intent artifact first, plan second
  - one primary owner for the whole stream
  - no silent scope drift
  - finish-line runtime wiring required
  - run the project's typecheck and lint commands during the work (e.g. `npm run typecheck` / `npm run lint`, `pnpm typecheck` / `pnpm lint`, `cargo check` / `cargo clippy`, `mypy` / `ruff`, etc. — discover from the project's package manifest or scripts)
  - update the plan progress where practical
- Do **not** launch multiple Codex rescue jobs for the same primary stream unless the user explicitly asks for more delegation
- Do **not** also spawn a Claude implementer for the same primary stream

Suggested Codex executor invocation (Bash, requires `codex` CLI on PATH):

```bash
WORKDIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
codex exec --cd "$WORKDIR" "Implement the plan at [plan path]. Supporting brief / intent artifact: [path if available]. Treat the brief as the source of truth for why and the plan as the source of truth for how. You are the primary implementation authority for this run. Do not silently simplify or defer scope. A task is not complete until the end-to-end runtime or user-facing path is wired and still preserves the intended outcome. Run the project's typecheck and lint commands as you work (discover from package manifest or scripts). Update the plan progress where practical and report any remaining manual steps or unresolved blockers clearly."
```

If your `codex` CLI install does not support write mode (the default `codex exec -s read-only` cannot write files), tell the user and fall back to the Claude executor — do not silently downgrade.

## Step 5: Parallel Review Gates

After the primary execution lane completes, always run a Claude
`implementation-reviewer` pass.

If Codex is available in this session (`command -v codex`), launch the Claude
reviewer and the Codex review lane in parallel and **wait for both** before
continuing. Do not treat the first result that returns as sufficient.

**Claude review lane:**

```
Task tool:
  subagent_type: "implementation-reviewer"
  prompt: "Review the implementation against the supporting brief / intent artifact first, then against the plan at [path].
    Supporting brief / intent artifact: [path if available]. Treat the brief as the source of truth for why and the plan as the source of truth for how.
    Run the project's typecheck and lint commands (discover from package manifest, scripts, or Makefile — e.g. npm run typecheck/lint, pnpm typecheck/lint, cargo check/clippy, mypy/ruff, etc.).
    Check every task in the plan was completed.
    Flag any gaps, missing integrations, convention violations, or brief-intent regressions.
    Report completeness status for each plan task."
```

**Codex review lane (if available — uses `codex exec` directly, no plugin required):**

```bash
codex exec -s read-only --ephemeral --cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" "Review the implementation diff against the supporting brief / intent artifact first, then against [plan path]. Treat the brief as the source of truth for why and the plan as the source of truth for how. Focus on whether the code preserves the brief's intended outcome, still respects its constraints and non-goals, actually satisfies the plan, and reaches the finish line at runtime."
```

```bash
codex exec -s read-only --ephemeral --cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" "Adversarial review: focus on missing plan tasks, brief-intent regressions, runtime wiring, auth and permission gaps, transaction boundaries, race conditions, background-job registration, dead query-param flows, and whether the implementation actually reached the finish line."
```

After both lanes finish, combine the findings into one review result. Triage the
combined findings:
- **Auto-fixable** — apply the fixes directly
- **Needs user input** — surface clearly to the user

Do not ask the user questions from either lane before both lanes complete.
Always wait for every active review lane, merge overlapping findings, and then
present one combined set of user-facing questions or decisions.

If you apply fixes after either lane reports issues:
- rerun the Claude `implementation-reviewer`
- rerun the Codex review `codex exec` invocation if Codex is available
- rerun the Codex adversarial review too when the fixes affect architecture,
  flow control, auth, async work, or finish-line wiring
- wait for all active review lanes again before continuing

If Codex is unavailable, run only the Claude review lane and treat it as the
review gate.

## Step 5.5: Generate Dev Migration SQL (If Schema Changed)

After the review gates are complete and any auto-fixable issues are resolved,
check if a schema file was modified. Discover the schema source-of-truth from
the project (common patterns: `schema.ts`, `schema.prisma`, `migrations/`,
`db/schema/`, `models.py`, etc.). For example:

```bash
# Discover the base branch first — prefer remote refs (latest team-shared state).
BASE_REF=""
# Try origin/HEAD first — this is the actual remote default branch (works for `release`, `production`, etc.).
if git symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
  BASE_REF=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
fi
if [ -z "$BASE_REF" ]; then
  for cand in main master develop trunk release production; do
    if git rev-parse --verify "origin/$cand" >/dev/null 2>&1; then BASE_REF="origin/$cand"; break; fi
    if git rev-parse --verify "$cand" >/dev/null 2>&1; then BASE_REF="$cand"; break; fi
  done
fi
SCHEMA_RX='schema\.(ts|prisma|sql|py|rb|kt|swift)$|models?/.*\.(py|rb)$|migrations/|db/schema/|alembic/versions/'
# Three-way detection: committed branch changes (triple-dot), staged, AND unstaged — /implement runs before commit, so uncommitted edits matter.
{
  [ -n "$BASE_REF" ] && git diff "$BASE_REF"...HEAD --name-only
  git diff --cached --name-only
  git diff --name-only
} | sort -u | grep -E "$SCHEMA_RX"
# Triple-dot diff so schema detection only fires on changes introduced by this branch, not unrelated upstream schema edits.
```

If a schema file was changed:

1. **Do NOT run the schema-diff command yourself.** Identify the project's schema-diff command (e.g. `npm run db:diff:dev`, `npx prisma migrate diff`, `alembic revision --autogenerate`, etc.) by reading `package.json`, `pyproject.toml`, or the project's developer docs. Then **tell the user the exact command to run** — schema-diff commands typically connect to a live dev database and may mutate migration state, so they must stay user-invoked.
2. Present TWO separate blocks to the user:

**Schema changes (migration SQL):**
```sql
BEGIN;
-- the generated migration SQL here
COMMIT;
```

**Apply migration to dev database (user runs this):**
```bash
# whatever the project's migrate command is — e.g. npm run db:migrate:dev,
# npx prisma migrate dev, alembic upgrade head, etc.
```

3. Only include additive SQL (CREATE, ADD). If destructive SQL (DROP, ALTER type) appears, flag it and ask the user to confirm before proceeding.

If no schema file was changed, skip this step silently.

## Step 6: Move Plan to Done

If Step 5.5 detected schema changes, **HALT** here until the user has provided
the actual generated dev migration SQL and confirmed it was reviewed/applied.
Do not move the plan to `done-plans/` while a schema-changing implementation
still has placeholder migration SQL — the schema handoff is part of the plan's
finish-line completeness.

Once all tasks pass the review gates, brief intent is still preserved, the
implementation is complete, and (if applicable) the schema migration SQL has
been collected, move the plan file from `./tmp/ready-plans/` to
`./tmp/done-plans/`:

```bash
mv ./tmp/ready-plans/<plan-file>.md ./tmp/done-plans/
```

Create `./tmp/done-plans/` if it doesn't exist. Only move the plan when all
tasks are confirmed complete — if the review pass found unresolved issues, wait
until they are fixed.

## Step 7: Present Results

Present the combined final review findings to the user:

```
Implementation complete.

Quality checks:
  typecheck: PASS/FAIL
  lint: PASS/FAIL

Executor used:
  Claude / Codex

Intent fidelity:
  brief / why preserved: PASS/FAIL

Completeness: X/Y tasks done
[List any MISSING or PARTIAL items]

Issues found: [count]
[Summarize key issues if any]

Questions needing user input:
- [Only include items that neither review lane could safely auto-resolve]

Manual steps remaining:
- [ ] [Dangerous commands from Step 2, if any]

Schema changes:
  [If Step 5.5 ran, show the migration SQL and apply command here]
  [If no schema changes, show "None"]

Plan moved to: ./tmp/done-plans/<plan-file>.md

Next steps:
- Fix any issues flagged above
- `/prepare-pr` — Commit, build, and open/update a PR
```

If either review lane found issues, offer to fix them before the user commits.
Only move the plan to `done-plans/` after all issues are resolved.
