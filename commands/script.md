---
description: "Generates pre-flight smoke scripts that programmatically PROVE the load-bearing assumptions of a feature/plan/refactor against real infrastructure BEFORE implementation, AND re-run as regression catchers AFTER. Use when stakes are real (production systems, user data, HIPAA / financial / safety-critical) and you cannot afford to find out by deploying. Scripts must run, be idempotent, self-clean, return deterministic exit codes, and tag synthetic data with per-run UUIDs."
argument-hint: "[plan path | feature description | blank for auto-detect from context]"
allowed-tools: "Read, Grep, Glob, Bash, Write, Edit, Task"
expected_subagents: 1
---

# /script — Prove-the-Design Smoke Script Generator

> **Mission.** Text review of plans + diffs caps at a ceiling no matter how many passes you run. Real validation comes from running real code against real infrastructure. This skill bridges the gap: it identifies the load-bearing assumptions of a feature, writes small standalone scripts that PROVE each assumption against the actual dev environment, and packages them so they re-run as regression catchers after implementation.
>
> Born from a HIPAA-grade dental-software retrofit (A3, 2026-05-22) where plan-reviewer density was 33 → 23 → 62 → 55 → ~30 → 3 across 6 passes — diminishing but never converging because text review fundamentally can't validate runtime semantics like PgBouncer GUC scoping or Prisma TransactionClient atomicity. The smoke-script layer added concrete proof for the 5 most load-bearing assumptions in ~400 lines of script, gated by an env safety flag, idempotent, self-cleaning. That pattern generalizes.

## When to use

Invoke `/script` when ANY of the following hold:
- You have a plan that depends on runtime contracts you've never measured (pool behavior, isolation levels, callback semantics, race windows, retry policy, GUC scoping, Proxy interception, instanceof across modules).
- You're about to implement something whose failure mode is silent (no exception, just wrong rows committed; cursor advances past unwritten data; audit lost; PHI leaked).
- Stakes are real — production users, patient data, money, safety-critical infrastructure.
- The plan-reviewer cycle is showing diminishing-but-non-zero returns AND each pass surfaces "this design depends on X behaving Y way" findings.
- You're scoping a multi-slice ship and need per-slice regression gates that catch breakage at the right boundary.
- You just shipped a refactor and want to LOCK IN the contract by encoding it as a re-runnable test that fails loudly if it ever drifts.

## When NOT to use

- You can write a normal unit/integration test for the assumption — write the test, not a smoke script. Smoke scripts are for things that need to run against REAL infrastructure (real DB, real pool, real worker) and are too narrow / heavyweight / setup-dependent for the standing test suite.
- The assumption can be validated by reading the code (e.g., "function X imports Y" — just grep for it).
- The stakes are low (toy project, prototype, internal tool used by 3 people).
- You haven't actually identified a load-bearing assumption — don't manufacture risks. If 5 minutes of thinking can't surface one, the project genuinely doesn't have one.

## Core philosophy (read before writing scripts)

1. **A smoke script is not a unit test.** Unit tests live in `__tests__/` and exercise pure logic against mocks. Smoke scripts live in `scripts/<feature>-smoke/`, run against the real dev environment, are gated by an explicit safety env var, and prove that a RUNTIME CONTRACT holds. Different artifact, different audience, different lifecycle.

2. **Each script proves ONE assumption.** Multi-assertion scripts are fine (e.g., A1/A2/A3 within the same script) but only when they share setup + cleanup. A script with two unrelated assumptions becomes a script with two unrelated failure modes; split it.

3. **Reality > assertions about reality.** Don't write a script that asserts "the docstring says X" — write a script that DOES X against real infra and observes the outcome. The point is to learn what the runtime actually does, not what the documentation claims.

4. **Cheap to fail, expensive to ignore.** A script that takes 5 seconds to run and fails fast saves the team weeks of debugging post-deploy. Optimize for fast feedback + crisp diagnostics, not coverage.

5. **Re-runnable forever.** Today's pre-flight script is tomorrow's regression catcher. Design every script as if a future Claude (or human) will re-run it 3 months from now on a different branch. Idempotent. Self-cleaning. Deterministic. Per-run UUID.

6. **Safety FIRST.** If a script can touch production state, it MUST be gated by an explicit env var (`<PROJECT>_SMOKE_ALLOW_DEV=true`) that refuses to run unless set. Match the existing project's safety conventions (e.g., A3 used `RLS_TESTS_ALLOW_DEV_NEON=true` which was already an A1 convention).

## Step 1 — Resolve the context

Read the input (`$ARGUMENTS`):
- **Plan path** (e.g., `tmp/ready-plans/2026-05-22-foo.md`): read the plan; extract assumptions from §Verified Repo Truths, §Locked Decisions, §Architecture Overview, §Key Pseudocode.
- **Feature description** (free-form text): treat as the problem statement; supplement by reading recent git diff + any plan files in `tmp/ready-plans/`.
- **Blank**: auto-detect from conversation history. Look for the most recent plan, the most recent /implement target, the most recent /plan-reviewer findings, the user's stated current goal. If still ambiguous, ask 1 targeted clarifying question.

## Step 2 — Identify load-bearing assumptions

For the resolved context, enumerate every assumption whose failure would COLLAPSE the implementation. Categorize each by risk class:

### The 6 categories of load-bearing assumptions

1. **FOUNDATION** — infrastructure-level contracts the entire design rests on. Examples: PgBouncer transaction-mode GUC scoping; PostgreSQL row-locking semantics; Redis SETEX TTL precision; S3 read-after-write consistency; Kafka exactly-once delivery; OS file-locking semantics. If wrong, the design is moot regardless of code.

2. **ATOMICITY** — does an operation that you THINK commits as one unit actually do so? Prisma `$transaction` callback semantics, multi-row updateMany atomicity, multi-statement transactions across pooled connections, application-level "transaction" abstractions wrapping multiple operations.

3. **API SHAPE** — does a function/type/import you depend on actually have the shape your pseudocode assumes? Helper signatures, type re-exports, return shapes (`{event, truncated}` vs bare `event`), allowlist constants, error class hierarchies, instanceof across module boundaries.

4. **SCALING** — does the design hold up under projected load? Pool connection ceilings, rate-limiter token-bucket behavior, queue throughput, lock contention, fan-out timing budgets, OOM thresholds for large payloads.

5. **TERMINATION / RECOVERY** — does the system handle failure modes correctly? Retry policy short-circuits (DeadLetterError vs generic Error), worker SIGTERM mid-frame, idle-tx timeout, partial-write reconciliation, cursor advance after crash, idempotency-key collision behavior.

6. **TEST INFRA / OBSERVABILITY** — does the test mechanism you plan to use actually work? Spy interception across Proxy boundaries (`vi.spyOn` on Prisma TransactionClient), fixture cleanup, gate env vars, CI vs local divergence.

For each assumption identified, classify it. Skip cosmetic / mechanical / tsc-catchable items (those aren't load-bearing — they're catchable in normal review).

## Step 3 — Produce the catalog table

Before writing any scripts, produce a 5-field table for review. Each row:

| # | Script filename | What it tests | Pass criteria | Fail means | How to run | Files touched |
|---|---|---|---|---|---|---|

The user (and you) should look at the table BEFORE writing scripts. If the table lists 12 scripts, you're over-building — narrow to the 3-7 most load-bearing. If it lists 1 script, you under-identified — push harder on the 6 categories.

Aim for **5-8 scripts** for a substantial feature; **3-5** for a focused refactor; **2-3** for a small change.

## Step 4 — Write the scripts (THE SAFETY PATTERN)

Every script MUST follow these 8 rules. Non-negotiable.

1. **Safety env gate.** First executable lines of the script: read a `<PROJECT>_SMOKE_ALLOW_<ENV>=true` env var; if absent, `console.error('REFUSED: ...'); process.exit(2)`. Match the project's existing safety convention if one exists (`RLS_TESTS_ALLOW_DEV_NEON`, `STRIPE_SMOKE_ALLOW_TEST_MODE`, `S3_SMOKE_ALLOW_TEST_BUCKET`, etc.).

2. **Per-run UUID.** `import { randomUUID } from 'node:crypto'; const runId = randomUUID();` Every synthetic resource name embeds `runId` so parallel runs (CI matrix, dev + colleague's laptop) never collide and cleanup is precisely scoped.

3. **Idempotent.** Re-running the script with no state changes between runs produces the same outcome (PASS or FAIL for the same reason). No "succeeds the first time, fails the second" behavior. Use upsert-style setup. Use `deleteMany({where: {action: {startsWith: prefix}}})` cleanup that tolerates multiple prior runs.

4. **Self-cleaning.** A `try { ... } finally { cleanup; client.disconnect() }` block at the top level. Cleanup deletes ALL synthetic resources tagged with this run's UUID. Cleanup failure logs `CLEANUP WARNING:` but does NOT change the exit code (real result was already determined).

5. **Deterministic exit codes.**
   - `0` — PASS (all assertions PASS).
   - `1` — FAIL (≥1 assertion FAIL; the body should print the failure list).
   - `2` — REFUSED (safety env gate not set).
   - `3` — INFRASTRUCTURE FAIL (couldn't connect to DB, network down, dependency missing). NOT a logical failure; the script couldn't even run the test.

6. **Crisp output.** On PASS: `console.log('PASS: <script-name> — N assertions (A1, A2, ...)')`. On FAIL: `console.error('FAIL: <script-name>'); for (const f of failures) console.error('  -', f);`. CI-parseable. Don't bury results in verbose logs.

7. **One assertion = one named anchor.** Inside the script, comment each assertion as `// A1 — <what it proves>`. The failure messages reference the anchor (`A1 expected X, got Y`). Diagnosing a FAIL takes ≤30 seconds.

8. **No external dependencies beyond the project's normal client.** Don't add new packages. Use what the project already has (Prisma client, fetch, http, fs). If you need a stub OD client / mock LLM, define it inline at the top of the script.

## Step 5 — Wire the run-all + README

In the same directory as the scripts:

- `run-all.sh` — bash script that runs all smoke scripts sequentially, halts on first FAIL, prints duration, exits with the first FAIL's exit code. Template:

```bash
#!/usr/bin/env bash
set -e
if [ "${<ENV_GATE>:-}" != "true" ]; then
  echo "REFUSED: set <ENV_GATE>=true to run smoke scripts" >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS=( "01-foo.mjs" "02-bar.mjs" "03-baz.mjs" )
PASS=0; START=$(date +%s)
for s in "${SCRIPTS[@]}"; do
  echo; echo "--- ${s} ---"
  if node "${SCRIPT_DIR}/${s}"; then PASS=$((PASS+1)); else exit $?; fi
done
echo; echo "PASS: ${PASS}/${#SCRIPTS[@]} in $(( $(date +%s) - START ))s"
```

- `README.md` — explains: what these scripts prove, pre-implementation gate, post-slice regression gate, how to run (individual + run-all), safety notes, exit-code semantics, output format.

## Step 6 — Suggest gate placement

After scripts are written, tell the user:

```
Pre-implementation gate (BEFORE /implement):
  bash scripts/<feature>-smoke/run-all.sh
  All 5 must PASS before implementation begins.

Post-implementation regression gate (AFTER each ship):
  Re-run after each slice ships (or after each meaningful commit).
  Same scripts; same pass criteria. Any FAIL = regression.

Optional integration:
  - Wire into CI: add `npm run smoke:<feature>` that calls run-all.sh
  - Wire into pre-merge: block PR merge if smoke fails
  - Wire into /implement: run automatically before implementation
```

## Output layout

```
scripts/
└── <feature>-smoke/
    ├── README.md
    ├── run-all.sh
    ├── 01-<assumption-name>.mjs
    ├── 02-<assumption-name>.mjs
    ├── 03-<assumption-name>.mjs
    ├── ...
    └── (optional) reference/
        └── <stubbed-data-or-fixtures>.json
```

Naming: `<NN>-<kebab-case-assumption-name>.<ext>`. Two-digit prefix for ordering. Use `.mjs` for ESM Node scripts (matches A3 pattern). Use `.ts` only if the project has a TypeScript runtime convention (`tsx`, `ts-node`).

## Integration with `/plan`

When `/plan` finalizes a plan with HIGH-RISK or LARGE-SURFACE content (criteria: ≥10 files touched, OR ≥1 new primitive in a critical module, OR ≥3 load-bearing assumptions identified during review), the /plan skill should suggest:

```
Plan finalized. Suggested next step: run `/script ./tmp/ready-plans/<filename>` to generate
pre-flight smoke scripts for the load-bearing assumptions surfaced by the plan-reviewer cycle.
Then proceed to /implement once smoke scripts pass.
```

This is additive guidance, not a forced step — /plan does not block on smoke-script generation. But for HIPAA-grade or production-critical features, it's strongly recommended.

## Integration with `/plan-reviewer`

When plan-reviewer surfaces findings of the form "this design depends on X behaving Y way" (i.e., a load-bearing assumption that hasn't been verified), it should tag them with `[SMOKE-CANDIDATE]` in the findings list. The /script skill, when invoked, can extract these as a starting catalog.

Plan-reviewer's review output template should include a `## Smoke-Script Candidates` section enumerating any `[SMOKE-CANDIDATE]` findings.

## Integration with `/implement`

If a `scripts/<feature>-smoke/run-all.sh` exists for the current feature, `/implement` should:
1. Run it BEFORE the first implementation chunk; halt if it fails.
2. Re-run it AFTER each chunk ships; report regressions.
3. Re-run it at end-of-implementation as final regression check.

This catches drift introduced by implementation that text-level impl-reviewer would miss.

## Worked example — A3 OD orchestrator retrofit

**Context:** A3 retrofitted the OpenDental sync backbone of a HIPAA-grade dental SaaS. Plan went through 6 plan-reviewer passes (density 33 → 23 → 62 → 55 → ~30 → 3) without truly converging because text review couldn't validate runtime contracts. The /script invocation identified 5 load-bearing assumptions and wrote scripts for each.

### Catalog (the 5-field table for A3)

| # | Script | Tests | Pass | Fail means | Run | Files touched |
|---|---|---|---|---|---|---|
| 01 | `01-pgbouncer-guc-scoping.mjs` | `SET LOCAL app.current_clinic_id` is tx-scoped + doesn't leak across pool connections + released on rollback | 4 assertions PASS | **ENTIRE design moot.** PgBouncer transaction-mode behavior differs from assumption → all GUC strategy must be redesigned | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-smoke/01-pgbouncer-guc-scoping.mjs` | Read-only |
| 02 | `02-withClinicContext-atomicity.mjs` | Throw inside `prisma.$transaction` callback rolls back all writes in that frame; sibling frames unaffected | 3 sentinel-presence assertions PASS | Per-page-commit atomicity contract BROKEN → cursor + upsertPage cannot commit atomically | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-smoke/02-withClinicContext-atomicity.mjs` | 3 sentinel AuditEvent rows (cleaned up) |
| 03 | `03-cluster-drain-baseline.mjs` | Existing `runEntityWithCursor` cluster-drain logic produces expected cursor advance on 100/100/25 same-DateTStamp page sequence | Cursor = baseline + 1s; upsertPage called 3× | Existing semantic differs from docstring → cursor.ts:103-119 docs wrong → must re-read before refactor | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-smoke/03-cluster-drain-baseline.mjs` | 1 OdSyncCursor row (cleaned up) |
| 04 | `04-audit-primitive-shape.mjs` | `normalizeAuditEventForBoundedWrite` returns `{event, truncated}`; throw inside `tx.auditEvent.create` propagates + rolls back surrounding tx; custom Error subclass instanceof works cross-module | 3 assertions PASS | `writeOdWritebackAuditInTx` pseudocode is fiction → must rewrite before A3.2 | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-smoke/04-audit-primitive-shape.mjs` | 1 rolled-back insert attempt; 0 committed |
| 05 | `05-deadletter-shortcircuit.mjs` | Worker job throwing `DeadLetterError` dead-letters in 1 attempt (NOT MAX_ATTEMPTS=5); generic Error retries fully | 2 JobQueue state assertions PASS | `DeadLetterError` doesn't short-circuit → WritebackAuditValidationError wrapping won't prevent retry waste → must redesign Frame 2 catch | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-smoke/05-deadletter-shortcircuit.mjs` | 2 synthetic JobQueue rows (cleaned up) |

### Categorization of those 5

- 01 → **FOUNDATION** (infrastructure contract)
- 02 → **ATOMICITY** (transactional contract)
- 03 → **API SHAPE** (existing semantic verification, also serves as regression baseline)
- 04 → **API SHAPE** (new primitive's building blocks)
- 05 → **TERMINATION / RECOVERY** (retry policy contract)

Notably absent: SCALING (deferred to a per-tenant pool baseline measurement at Chunk 0.2 — different artifact, different validation surface) and TEST INFRA (deferred to a small vi.spyOn verification during test writing).

### Outcome

5 scripts × ~80 lines avg = ~400 lines of code. If all 5 PASS → the load-bearing assumptions are validated; /implement can begin with high confidence. If any FAIL → halt + redesign affected plan section.

## STOP rules

- **No more than 8 scripts** for a single /script invocation. If you find 12 load-bearing assumptions, you're either over-classifying (some are cosmetic) or the scope is too big (split into multiple smaller features, then /script each).
- **No script over 150 lines.** If you can't prove an assumption in 150 lines, the assumption is too composite — decompose into 2-3 atomic assumptions.
- **No script that takes more than 60 seconds to run.** Smoke scripts are FAST feedback. If you need long-running validation, that's an integration test, not a smoke script.
- **No script that mutates state and doesn't clean up.** Cleanup is in `finally`. Always. If you can't clean up (e.g., script crashes mid-write), the script is wrong; redesign to use rollback-friendly operations.
- **Don't manufacture risks.** If you can't articulate "what would break if this assumption is wrong," don't write a script for it. The exercise is identifying REAL load-bearing assumptions, not maximizing script count.

## Anti-patterns to avoid

- **The "smoke test that's actually a unit test."** If you find yourself mocking the thing under test, you're writing a unit test. Move it to `__tests__/` and rewrite to use real infra.
- **The "comprehensive coverage" script.** Smoke scripts are NOT coverage. They prove specific load-bearing assumptions. Trying to cover every code path is wrong artifact.
- **The "manual cleanup" script.** Telling the user "run this DELETE statement after" defeats idempotency + safety. Cleanup is in the script.
- **The "shared global state" script.** Two scripts that depend on each other's state defeat per-script isolation. Each script sets up its own state with per-run UUID.
- **The "noisy log" script.** Verbose logs hide the pass/fail signal. Print PASS line on success, FAIL list on failure, nothing else (use `--verbose` flag if needed, default to quiet).
- **The "no env gate" script.** A script that can touch real infra and isn't gated by an env var is a footgun. Always gate.
- **The "wrong gate" script.** A script gated by an env var that's already always-true in the project context (e.g., `NODE_ENV=development`) isn't gated. The gate must be EXPLICITLY set by the human runner.

## Re-running mechanics (regression-catcher protocol)

Once smoke scripts exist for a feature, they become part of the feature's permanent test surface:

1. **After every meaningful change to feature code**, re-run the relevant smoke scripts.
2. **Pre-merge**: PR template should reference the smoke scripts; reviewer checks they were re-run + PASS.
3. **CI**: if the project has CI, add `bash scripts/<feature>-smoke/run-all.sh` as a CI job (after setting the env gate appropriately in the CI env).
4. **Post-deploy**: re-run against dev environment after each deploy as a canary; if FAIL, investigate before promoting to staging/prod.
5. **Drift detection**: if assumptions change (e.g., PgBouncer config tuning, new Prisma major version, queue lib swap), re-run all smoke scripts to confirm contracts still hold.

## Sub-agent vs in-process

`/script` runs in-process by default — most invocations only need to read the plan, write 3-8 small files, and produce a catalog. Light context.

For VERY LARGE plans (>1000 lines + multi-domain) where assumption extraction itself is non-trivial, the skill MAY delegate the extraction phase to a sub-agent (via Task tool) to keep main context lean. Pattern: spawn one sub-agent per domain (e.g., "extract DB assumptions", "extract HTTP assumptions", "extract queue assumptions"); collect catalogs; merge; then write scripts in-process. Default: in-process unless plan size + complexity demand otherwise.

## End-of-skill checklist

Before reporting done, verify:
- [ ] N scripts written, where 2 ≤ N ≤ 8.
- [ ] Each script has the 8 safety-pattern items (env gate, UUID, idempotent, self-clean, exit codes, crisp output, named assertions, no new deps).
- [ ] Catalog table presented to user with all 5 fields per script.
- [ ] `run-all.sh` + `README.md` written.
- [ ] Suggested pre-implementation + post-slice gate placement told to user.
- [ ] If `/plan-reviewer` already ran and surfaced `[SMOKE-CANDIDATE]` findings, every candidate is addressed by a script OR explicitly deferred with justification.
- [ ] User knows how to invoke `run-all.sh` (exact command with env gate prefilled).

End by telling the user: "N smoke scripts written at `scripts/<feature>-smoke/`. Run pre-flight: `<ENV_GATE>=true bash scripts/<feature>-smoke/run-all.sh`. All PASS = green light for /implement. Any FAIL = halt + diagnose."
