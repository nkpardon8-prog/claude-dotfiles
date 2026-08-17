---
description: Executes an approved plan by breaking work into parallelizable chunks and spawning implementation sub-agents. Automatically reviews the result for completeness. Use after a plan is approved.
argument-hint: "[plan file path] [--no-review]"
expected_subagents: 7
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

4. **Output the CHUNK TABLE** - after chunking, before Step 3.5, print one row per chunk:

```
chunk-id | phase | parallel|sequential | task files
```

`chunk-id` must match `^[a-z0-9][a-z0-9-]{0,31}$` (lowercase alphanumerics and hyphens, 1-32 chars, never leading with a hyphen). It becomes a git branch name and a worktree directory name downstream, so anything outside that set is a shell/filesystem hazard. The `task files` column is the chunk's **declared** file set - the Step 4 post-batch overlap check is evaluated against exactly these declarations, so a vague or omitted declaration is a chunk that cannot be run in parallel.

If >= 2 chunks are pending and NO_REVIEW is not set, consult the WAVE GATE section below the contract-core marker; otherwise proceed serial. These two serial branches log their decision HERE, on the serial branch - NOT in the WAVE GATE, which is never reached on either path (it is entered only when >= 2 chunks AND NOT NO_REVIEW, exactly when these two tokens cannot occur). Before the serial path continues, emit exactly one decision event with the same absolute call the gate uses:

```bash
node ~/.claude-dotfiles/scripts/verify-parallel-wave.mjs --log-decision serial --reason <token> --repo-root <repo_root>
```

`--reason lt2_chunks` when fewer than 2 chunks are pending; `--reason no_review` when NO_REVIEW is set (a >= 2-chunk run invoked with `--no-review`). Without these two log points, `rework.log`'s serial denominator silently omits the two commonest serial paths, because neither token can ever fire inside the gate.

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

**CLASSIFY EACH CHUNK BEFORE DISPATCH - you, not the worker, choose the model.** There are three
classes and they are NOT interchangeable:

| Class | Route | Signal |
|---|---|---|
| hard / ambiguous / cross-layer / architecture-sensitive / high-risk | **`model: "opus"`** (the definition's default - pass nothing) | touches a contract, a schema, auth, or more than one layer |
| normal bounded chunk with a strong reviewed plan | **`model: "sonnet"`** on the call | file set is known, the plan already answered the design questions |
| isolated, mechanical, fully specified | **Codex** via `scripts/codex-build-chunk.sh` | pure mechanical edit, no judgment left in it |

`agents/implementer.md` stays `opus` deliberately, as the FAIL-SAFE: a chunk you forget to classify
runs at full capacity rather than silently dropping to the cheap lane. Never set the cheap model in
the definition - a frontmatter value is a GLOBAL route, which is exactly what "do not globally route
every implementer to one model" forbids. The class decision belongs on the call, every time.

- CRITICAL - chunk-parallel spawn: chunks whose table rows are marked parallel AND whose
  file sets are determinable from task text, pairwise disjoint, and free of hazard classes
  (shared types/contracts, generated outputs, lockfiles, schema/migrations, shared
  fixtures) MUST be spawned together in a SINGLE message - one implementer Agent call per
  chunk, at the model its class selects. Indeterminable or hazardous ⇒ sequential. One-at-a-time
  spawning of qualifying chunks is a playbook violation. Record HEAD before the batch.
  Each chunk prompt includes the report contract: "return a short digest + your file list,
  not a dump".
- POST-BATCH OVERLAP CHECK (the serial path's machine leg): after the batch returns, run
  `git diff --name-only <pre-batch HEAD>..HEAD` (plus `git status --porcelain` for
  uncommitted work) and compare - with each worker's reported file list - against the
  chunk table's declared sets. Any touched file outside its chunk's declared set, or
  claimed by two chunks, ⇒ HALT, whole batch jointly implicated. Then run the Step 3.5
  gates once; on FAIL the batch is jointly implicated (:71-75 exit-code semantics
  unchanged).
- **Sequential**: Wait for dependent chunks to complete before next phase
- Each agent prompt must include: specific tasks, relevant context, file paths, success criteria

### Re-run the assumption-gates after each chunk / wave (INSIDE this step, on purpose)

After EACH completed chunk (or each completed parallel wave), re-run the SAME `scripts/*-assumptions/run-all.sh` gates discovered in Step 3.5 and record the result against the chunk it covers. Same handling as Step 3.5: **FAIL (exit 1/3) ⇒ HALT immediately** (the chunk that just shipped regressed a proven assumption — do not proceed to the next chunk/wave); **exit 2 ⇒ report the required gate + pause per the away-policy**.

This per-chunk gate lives INSIDE Step 4 deliberately: `--no-review` (which `/mission` always passes) skips Steps 5–6 per the Step 5 guard below, so a per-chunk gate placed as a later step would never run for mission-mode. Placing it here means every path — autonomous `/mission` runs included — gets the after-each-chunk regression check that script.md's contract promises.

<!-- CONTRACT-CORE-END -->

Everything above this marker is the contract core: Steps 1-3.5, the Step 4 chunk-parallel register, the serial spawn, and the per-chunk gate re-run. It is self-sufficient - an agent that only ever sees the first 20,000 characters executes `/implement` correctly, serially. The two sections below are the OPTIONAL write-wave path plus Steps 5-7; read them from disk (`~/.claude-dotfiles/commands/implement.md`) when the Step 3 pointer line sends you here. Losing them degrades to serial, which is today's behavior - never to a half-run wave.

## WAVE GATE (reached only from the Step 3 pointer line)

Entered ONLY when >= 2 chunks are pending AND `NO_REVIEW = false`. Every condition here is failure-biased: anything unresolved, unreadable, or unexpected means SERIAL. Serial is not a degraded outcome - it is the behavior `/implement` has always had.

### Resolve the session identity (SID block) - run this FIRST

Bash tool calls are FRESH SHELLS: variables never survive from one call to the next. So this block PRINTS its values, and you substitute those printed values as LITERALS into every later command (worktree paths, branch names, state filenames). Never re-derive them in a later shell.

```bash
SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
# NO other fallback: empty ⇒ SERIAL. Never guess an identity that names on-disk state.
SAFE_SID=$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9_-' | head -c 128); SID8=${SAFE_SID:0:8}
PCT=$(. ~/.claude-dotfiles/scripts/hooks/lib/ctx-gate-config.sh && ctx_gate_read_pct "$SAFE_SID" || echo "")
printf 'SAFE_SID=%s SID8=%s PCT=%s\n' "$SAFE_SID" "$SID8" "${PCT:-}"
```

There is deliberately NO fallback identity. An invented SID would name on-disk state (worktree dirs, branch names, wave-state files) that a concurrent session could then collide with or sweep. An empty `SAFE_SID` also forces an empty `PCT`, so it lands on the `pct_unknown` arm below and the run goes serial with a logged reason.

### SERIAL when ANY of these holds

| Condition | Reason token |
| --- | --- |
| fewer than 2 pending chunks | `lt2_chunks` |
| `NO_REVIEW = true` (the `/mission` path - wave machinery is out of scope there) | `no_review` |
| `repo_root` is TRACKED-dirty: `git -C <repo_root> status --porcelain --untracked-files=no` is non-empty, ignoring `impl_plan_path` when it resolves under `repo_root` | `dirty_repo_root` |
| a merge or rebase is in progress at `repo_root` (`.git/MERGE_HEAD`, `.git/rebase-merge`, `.git/rebase-apply`) | `merge_in_progress` |
| `PCT` is empty or unresolvable (an empty `SAFE_SID` lands here) | `pct_unknown` |
| `PCT` > 60 | `pct_over_60` |
| a wave-state file for the SAME `repo_root` still has worktrees on disk (scan below) | `stale_wave` |
| `repo_root` is `~/.claude-dotfiles` and the sync-pause marker `~/.claude/.dotfiles-sync-paused` is ABSENT | `dotfiles_unpaused` |

Untracked files at `repo_root` do NOT block (Divergence 9: repo_root gates scope to TRACKED changes; the chunk worktrees themselves are held to the strict standard, untracked included, by the checker).

**Stale-wave scan.** Read every `~/.claude/parallel-waves/*-w*.json`. For each whose `repo_root` equals this run's `repo_root`, test whether any path in its `chunks[].worktree` still exists on disk. If any does, REFUSE to fan out and print the owning SID (the `<SAFE_SID>` component of that state filename) together with BOTH recovery routes:

- **Finish it:** `bash ~/.claude-dotfiles/scripts/merge-wave.sh <state.json>` (incremental and resumable - it skips chunks already in `merged_chunks[]`).
- **Abandon it:** for EVERY worktree recorded in that state file - a 3-chunk wave needs three pairs, not one - run `git -C <repo_root> worktree remove --force <worktree>` and `git -C <repo_root> branch -D <branch>`, THEN `rm <state.json>`.

Print the commands with the real paths substituted, and let the USER choose. Do not auto-recover another session's wave.

**Dotfiles condition.** `~/.claude-dotfiles` has a PostToolUse hook that auto-commits AND PUSHES on every Edit/Write. Parallel worktree writers under an unpaused hook race that push. Fan out there ONLY while the pause marker exists - and NEVER create, edit, or remove that marker yourself; it is user-owned, and a marker whose `kind` is `secret` or `unproven` means a poisoned HEAD, not a green light.

### Log EVERY decision path

Serial or fan-out, exactly one call before you act on the decision:

```bash
node ~/.claude-dotfiles/scripts/verify-parallel-wave.mjs --log-decision <serial|fan_out> --reason <token> --repo-root <repo_root>
```

Absolute literal `node` invocation on purpose. The reason tokens are a CLOSED set - the checker rejects anything else, because a typo'd reason would silently become a new category and corrupt the denominator:

```
lt2_chunks | no_review | dirty_repo_root | merge_in_progress | pct_unknown |
pct_over_60 | stale_wave | dotfiles_unpaused | serial_correct | malformed |
low_confidence | fan_out
```

This log is instructed-per-path, so it is not self-verifying; `scripts/parallel-stats.py --replay` supplies the independent denominator.

### No serial condition fired ⇒ spawn PARALLELIZER

ONE `Agent` call, `subagent_type: "parallelizer"`. Its definition pins `opus`/`high` and that IS full capacity for this role - do not pass a model or claim "max effort" here; the owner set `high` as the standing ceiling, with `xhigh` reserved for explicit on-request escalation. It is ADVISORY: it reads the repo and returns a schedule. It never implements and never spawns. You remain the single scheduler.

Envelope, passed as JSON in the prompt:

```
{ repo_root, base_ref, pending_items, in_flight, impl_plan_path,
  WAVE_WIDTH_MAX: 4, context_pct: <PCT>, shared_hazard_paths }
```

- `in_flight` - this run's in-progress and already-completed items. Without it PARALLELIZER re-plans work you have already shipped.
- `shared_hazard_paths` - read from the TARGET repo's own conventions (`CLAUDE.md`, `AGENTS.md`, and what they point at): lockfiles, schema/migration dirs, generated clients, shared fixtures, shared type/contract modules. The checker enforces that no chunk declares a write inside this list, so an incomplete list is the main way a bad wave gets through.

Verdict handling - three of the four outcomes are serial:

- `SERIAL_CORRECT` ⇒ serial, log `serial_correct`.
- Output unparseable or schema-invalid ⇒ serial, log `malformed`.
- Multi-chunk wave without `high` confidence ⇒ serial, log `low_confidence`.
- `FAN_OUT` ⇒ validate, then WAVE MODE, log `fan_out`.

### FAN_OUT ⇒ per-wave `--validate-plan`

```bash
node ~/.claude-dotfiles/scripts/verify-parallel-wave.mjs --validate-plan <wave_plan.json> --repo-root <repo_root> --base-sha <this wave's re-pinned base_sha>
```

Run ONCE PER WAVE, at that wave's re-pinned sha - never once for the whole plan. Ancestry rule (`docs/wave-plan-schema.md` §3.2): the plan's `analysis_basis.base_sha` must EQUAL the passed sha at wave 1 and be an ANCESTOR of it on later-wave re-validation, because the orchestrator re-pins the base every wave by design. A non-ancestor plan is analyzing a different history and is rejected. Any non-zero exit ⇒ serial for the remaining work, logged with the checker's own reason token.

### Record the gate list into the wave-state

Step 3.5 already discovered the repo's assumption gates. Record that list VERBATIM into `wave_state.gate_list[]`; the barrier re-runs EXACTLY that list, nothing inferred. When `repo_root` is not your cwd, re-discover the gates under `repo_root` and record the delta explicitly (a gate list mined from the wrong tree is a barrier that proves nothing).

## WAVE MODE (only after the WAVE GATE returned FAN_OUT)

You are the single scheduler. Run waves strictly IN ORDER; wave N+1 never starts before wave N's barrier is green. Schemas: `~/.claude-dotfiles/docs/wave-plan-schema.md` is the sole authority - when this file and that one disagree, that one wins.

### 0. Re-pin the base - EVERY wave

```bash
git -C <repo_root> rev-parse HEAD
```

That sha is this wave's `base_sha`. Re-run `--validate-plan` at it. If wave N-1 touched any path THIS wave declares, re-run PARALLELIZER instead: the plan was analyzed against a tree that no longer exists.

### 1. One worktree per chunk

```bash
git -C <repo_root> worktree add -b w<W>-<SID8>-<chunk-id> ~/.claude/wave-worktrees/<SID8>/w<W>-<chunk-id> <base_sha>
# Per-repo breadcrumb, named by a short hash of <repo_root>: one session can run waves in
# TWO repos under the same <SID8>, and a single shared .repo-root would be overwritten by
# the second repo - stranding the first repo's cleanup. Write it ONCE per repo (idempotent).
printf '%s\n' '<repo_root>' > ~/.claude/wave-worktrees/<SID8>/.repo-root-$(printf '%s' '<repo_root>' | shasum -a 256 | cut -c1-12)
```

`<SID8>` and `<base_sha>` are the LITERAL values printed earlier. The `.repo-root-<shorthash>` breadcrumb is not optional bookkeeping: it is how the SessionStart cleanup sweep finds the right repo to `worktree prune` and delete `w*-<SID8>-*` branches from if this session dies mid-wave. It is PER-REPO (filename suffixed with a short sha256 of `<repo_root>`) because one `<SID8>` dir can hold worktrees from two different repos in the same session; the sweep reads EVERY `.repo-root-*` in the dir and runs one prune + branch-delete pass per distinct repo, so no repo's cleanup is stranded.

### 2. Write the wave-state BEFORE spawning

Path: `~/.claude/parallel-waves/<SAFE_SID>-w<W>.json`. Shape: `docs/wave-plan-schema.md` §5 - `{ repo_root, base_sha, wave, impl_plan_path, merged_chunks: [], gate_list[], chunks: [{id, branch, worktree, exclusive_paths, reads}] }`. It is written first so that a session killed mid-wave leaves a recoverable record instead of orphaned worktrees nobody can attribute.

### 3. CRITICAL: spawn ALL N chunks in a SINGLE message

One `Agent` call per chunk, `subagent_type: "implementer"`, each at the model its class selects (Step 4's classification table - opus for hard/cross-layer, `model: "sonnet"` for a bounded chunk with a strong plan). Spawning them one at a time defeats the entire mechanism.

Each chunk prompt MUST carry:

- the chunk's tasks (verbatim item text) and the plan path, for context only;
- the worktree's ABSOLUTE path and the chunk's `exclusive_paths`;
- "EVERY git command uses `git -C <worktree path>` and every file edit uses absolute paths under it (your shell starts elsewhere and forgets cwd between calls)";
- "`git -C <worktree path> add <your exclusive_paths>` then commit - NEVER `git add -A`; leave nothing untracked, the checker fails an untracked-dirty worktree";
- "do NOT edit the plan file; do NOT run repo typecheck/lint/format; do NOT install dependencies. This OVERRIDES `agents/implementer.md` :18, :33-42, :45-48, :68 - the barrier owns the integrated build, and a per-chunk build against a partial tree is noise";
- the contract-freeze STOP rule: "if your chunk needs a change to a shared type, contract, or convention, STOP and report it - do not make the change. The wave will be replanned.";
- the report contract, literally: "return a short digest + your file list, not a dump".

### 4. BARRIER - in order, no step skipped

**(a) Verify.** `node ~/.claude-dotfiles/scripts/verify-parallel-wave.mjs --wave-state <state.json>`. Non-zero ⇒ HALT: preserve every worktree and branch, merge NOTHING, start no next wave, reconcile serially, then re-verify from (a).

**(b) Merge.** `bash ~/.claude-dotfiles/scripts/merge-wave.sh <state.json>` - the ONLY merge path. It re-verifies inline, merges chunks in declared order with `--no-ff`, and records each `{id, merge_sha}` into the wave-state as it goes, so a re-run resumes and skips what already merged. On conflict the tree is left CLEAN at the last successful merge tip; earlier merges stay, by design. Never hand-merge a chunk branch around this script.

**(c) Integrate.** Run the RECORDED `gate_list` plus the wave's `post_integration_commands`, with cwd = `repo_root`. Handle each command's exit as the SAME TRI-STATE the gate contract uses in Steps 3.5 / 4 / 7 - 0 = pass, 1/3 = fail, 2 = REFUSED - never collapse REFUSED into failure:

- **exit 0 (pass)** — continue.
- **exit 1 or 3 (fail)** — FAIL FORWARD: record a rework event, then ONE serial fixer repairs the INTEGRATED tree (the code is already merged; unmerging it is not the cheaper move). Re-runs of (c) do NOT re-invoke the checker.
- **exit 2 (REFUSED — the safety env-gate is not set)** — do NOT treat this as a failure and do NOT fail-forward. An env-gated assumption suite exits 2 WITHOUT its `<PROJECT>_SMOKE_ALLOW_DEV`-class var, so a healthy tree would otherwise trigger a spurious rework event + serial fixer. Report the exact gate + the env var it requires and **pause per the away-policy** (surface it for the user / the `/mission` checkpoint rather than silently skipping — an unrun gate is not a passed gate).

Barrier (c) is a LOOP: re-run it until every command is GREEN (exit 0) before teardown (d). A failed (exit 1/3) or refused (exit 2) integrate NEVER proceeds to (d) and NEVER starts wave W+1 — teardown fires ONLY on an all-green integrate, so the next wave can never begin on a red tree.

**(d) Tear down.** Per chunk: `git -C <repo_root> worktree remove <worktree>` then `git -C <repo_root> branch -d <branch>` (plain `-d` - it refuses to delete anything unmerged, which is exactly the check you want here). Delete the wave-state file. Record plan progress NOW, before the next wave: an interrupted run must never lose the record of what already landed. Then wave W+1 from step 0.

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
