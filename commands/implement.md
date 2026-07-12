---
description: Executes an approved plan by breaking work into parallelizable chunks and spawning implementation sub-agents. Automatically reviews the result for completeness. Use after a plan is approved.
argument-hint: "[plan file path] [--no-review]"
expected_subagents: 5
---

# Implementation Agent

## Plan to Execute: $ARGUMENTS

## Step 1: Load and Review Plan

**Parse arguments first.** Check `$ARGUMENTS` for a `--no-review` token (opt-in, additive):
- If `--no-review` is present: set `NO_REVIEW = true`, then strip the `--no-review` token from `$ARGUMENTS` before resolving the plan path.
- If `--no-review` is absent (the default): set `NO_REVIEW = false`. **Behavior is completely unchanged** — every step below runs exactly as it always has.

The remaining (flag-stripped) `$ARGUMENTS` is the plan path:
- If a path is provided: Read from it
- If no path: Find the most recent plan in `./tmp/ready-plans/`

Review the plan to understand: implementation phases, task checklist, technical requirements, dependencies between tasks, and success criteria.

## Step 2: Identify Dangerous Commands

**BEFORE ANY IMPLEMENTATION**, scan the plan for commands that must NOT be run automatically:

- Database commands (`db:diff`) — instruct user to run this
- Environment variable changes
- Package installations that change `package.json`
- Any destructive operations

**Collect into a "Manual Steps" list** and present to the user before proceeding.

## Step 3: Break Plan into Chunks

1. **Identify Independent Units**: Group related tasks that can be completed together
2. **Respect Dependencies**: Schema before API, backend before frontend, types before implementations
3. **Chunk Size**: 2-5 related tasks with clear boundaries

```
Phase 1: Foundation (Sequential) → Schema, types
Phase 2: Core (Parallel) → Backend chunks, frontend chunks
Phase 3: Integration (Sequential) → Connect frontend to backend
```

## Step 3.5: Assumption-Gate — Pre-Implementation (runs on EVERY path, `--no-review`/`/mission` included)

Assumption tests written by `/script` live at `scripts/<feature>-assumptions/run-all.sh` and are the runtime regression net for this plan (script.md's "Integration with /implement" contract requires /implement to run them before the first chunk, after each chunk, and at end-of-implementation). Discover EVERY existing gate under the plan's repo and run each one BEFORE spawning the first chunk:

```bash
# Discover every assumption-gate in the repo (zero, one, or many). Also honor the
# plan's own "Assumption Gates" field (from plan_base.md) if it names explicit paths.
GATES=( $(ls scripts/*-assumptions/run-all.sh 2>/dev/null) )
```

For each discovered gate, run it and record the result (which gate, exit code, pass/fail) against the pre-implementation checkpoint:
- **PASS (exit 0)** — record and continue.
- **FAIL (exit 1, or exit 3 = infrastructure/timeout fail)** — **HALT immediately.** Do NOT spawn any implementation chunk. Report which gate failed and its output — the plan's load-bearing assumptions are already violated by the current tree, so implementation must not begin.
- **REFUSED (exit 2 — the safety env-gate is not set)** — the gate needs an explicit env var (e.g. `<PROJECT>_SMOKE_ALLOW_DEV=true`) to run against real infrastructure. Report the exact gate + the env var it requires and **pause per the away-policy** (surface it for the user / the `/mission` checkpoint rather than silently skipping — an unrun gate is not a passed gate).

If the glob matches nothing, there are no assumption gates for this plan — record "no assumption gates" and proceed.

## Step 4: Spawn Implementation Agents

Use the `Agent` tool with `subagent_type: "implementer"` for each chunk.

- **Parallel**: Spawn multiple agents simultaneously for independent chunks
- **Sequential**: Wait for dependent chunks to complete before next phase
- Each agent prompt must include: specific tasks, relevant context, file paths, success criteria

### Re-run the assumption-gates after each chunk / wave (INSIDE this step, on purpose)

After EACH completed chunk (or each completed parallel wave), re-run the SAME `scripts/*-assumptions/run-all.sh` gates discovered in Step 3.5 and record the result against the chunk it covers. Same handling as Step 3.5: **FAIL (exit 1/3) ⇒ HALT immediately** (the chunk that just shipped regressed a proven assumption — do not proceed to the next chunk/wave); **exit 2 ⇒ report the required gate + pause per the away-policy**.

This per-chunk gate lives INSIDE Step 4 deliberately: `--no-review` (which `/mission` always passes) skips Steps 5–6 per the Step 5 guard below, so a per-chunk gate placed as a later step would never run for mission-mode. Placing it here means every path — autonomous `/mission` runs included — gets the after-each-chunk regression check that script.md's contract promises.

## Step 5: Automatic Implementation Review

> **`--no-review` guard (opt-in skip).** If `NO_REVIEW = true` (the `--no-review` flag was passed), **SKIP this Step 5 AND Step 6 entirely** and jump straight to Step 7. The caller (e.g. `/mission`) owns the review barrier and the plan lifecycle in that case, so `/implement` returns right after the implementation chunks complete — it does NOT spawn the implementation-reviewer and does NOT move the plan.
>
> If `NO_REVIEW = false` (the default — no flag), run Step 5 and Step 6 below exactly as written.

After all implementation agents complete, **automatically spawn an implementation-reviewer** AND, in the **same message**, a parallel `criticer` (the generative value-critic lane). Step 5 is entirely skipped under `--no-review` per the guard above, so `criticer` inherits that skip automatically — no new conditional, and it never runs under `/mission`.

```
Agent tool (call 1):
  subagent_type: "implementation-reviewer"
  prompt: "Review the implementation against the plan at [path].
    Run npm run typecheck and npm run lint.
    Check every task in the plan was completed.
    Flag any gaps, missing integrations, or convention violations.
    Report completeness status for each plan task."

Agent tool (call 2, sent in the SAME message as call 1):
  subagent_type: "criticer"
  prompt: "Critique the completed implementation against the plan at [path] as a
    generative value-critic. Apply up to 5 lenses — (1) biggest gap, (2) honest
    assessment of where it quietly fails, (3) cheap win being skipped, (4) premise
    check, (5) over-built. Return a `## Criticer Notes` block, at most 5 findings
    ranked by value, empty is fine. NEVER ask the user anything — state, don't ask.
    Do NOT emit an `## Assumption-Test Candidates` section."
```

`criticer` is advisory only — it never asks, gates, or blocks. It critiques
implementation-vs-plan, so it intentionally takes no brief-path (the plan already
carries the intent). Hold its `## Criticer Notes` output for rendering in Step 7.

## Step 6: Move Plan to Done — DEFERRED to Step 7

> The plan-move does NOT happen here. It is DEFERRED into Step 7, AFTER the final
> assumption-gate passes — a gate FAILURE must never leave the plan retired in
> `done-plans/` (codex-review 2026-07-12: moving here, before the Step 7 gate, retired the
> plan even on a final-gate failure). The `mv` instruction now lives at the end of Step 7's
> default-path branch. Under `--no-review` the caller owns the plan lifecycle and no move happens.

## Step 7: Present Results

### Final assumption-gate (runs regardless of `NO_REVIEW` — placed ahead of the `--no-review` early-return AND ahead of the plan-move)

Before presenting anything OR moving the plan, run the `scripts/*-assumptions/run-all.sh` gates discovered in Step 3.5 ONE final time as the end-of-implementation regression check. Same handling as Step 3.5: **FAIL (exit 1/3) ⇒ HALT and report** (do NOT present success and do NOT move the plan — leave it in `ready-plans/` so the failure is fixed before retirement); **exit 2 ⇒ report the required gate + pause per the away-policy**.

This final gate sits at the TOP of Step 7, **ahead of both the `--no-review` early-return below and the default-path plan-move**, on purpose: `/mission` runs `/implement --no-review`, which skips Steps 5–6 and jumps straight to Step 7; the default path reaches Step 7 with the plan NOT yet moved (Step 6 defers it). Because the gate precedes both terminal actions, every path gets this final regression check before it commits — and a gate failure never retires the plan.

**If `NO_REVIEW = true`:** present a brief result and return — do NOT present reviewer findings (none were produced) and do NOT report a plan move:

```
Implementation chunks complete.

Review skipped (--no-review); caller owns review + plan-move.

Chunks implemented: X
Manual steps remaining:
- [ ] [Dangerous commands from Step 2]
```

Then stop. Everything below applies only to the default (`NO_REVIEW = false`) path.

**If `NO_REVIEW = false` (default):** present the implementation-reviewer's findings to the user:

```
Implementation complete.

Quality checks:
  typecheck: PASS/FAIL
  lint: PASS/FAIL

Completeness: X/Y tasks done
[List any MISSING or PARTIAL items]

Issues found: [count]
[Summarize key issues if any]

Criticer: [≤5 value-critique findings from the criticer lane, or — if none]

Manual steps remaining:
- [ ] [Dangerous commands from Step 2]

Plan moved to: ./tmp/done-plans/<plan-file>.md

Next steps:
- Fix any issues flagged above
- `/prepare-pr` — Commit, build, and open/update a PR
```

**Now (default path only) perform the DEFERRED plan-move** — ONLY after the final assumption-gate above passed AND all reviewer issues are resolved. This is the move Step 6 deferred; doing it here guarantees a gate failure never retires the plan:

```bash
mkdir -p ./tmp/done-plans && mv ./tmp/ready-plans/<plan-file>.md ./tmp/done-plans/
```

If the reviewer found unresolved issues, do NOT move the plan — leave it in `ready-plans/` until they are fixed. (Under `--no-review` the caller owns the plan lifecycle; no move happens here.)
