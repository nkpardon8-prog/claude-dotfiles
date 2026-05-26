---
description: "Generates pre-flight assumption tests that programmatically PROVE the load-bearing assumptions of a feature/plan/refactor against real infrastructure BEFORE implementation, AND re-run as regression catchers AFTER. Use when stakes are real (production systems, user data, HIPAA / financial / safety-critical) and you cannot afford to find out by deploying. Tests must run, be idempotent, self-clean, return deterministic exit codes, and tag synthetic data with a stable namespace marker + per-run UUID."
argument-hint: "[plan path | feature description | blank for auto-detect from context]"
allowed-tools: "Read, Grep, Glob, Bash, Write, Edit, Task"
expected_subagents: 2
---

# /script — Prove-the-Design Assumption-Test Generator

> **Mission.** Text review of plans + diffs caps at a ceiling no matter how many passes you run. Real validation comes from running real code against real infrastructure. This skill bridges the gap: it identifies the load-bearing assumptions of a feature, writes small standalone tests that PROVE each assumption against the actual dev environment, and packages them so they re-run as regression catchers after implementation.
>
> These are **assumption tests** — kept *learning tests* (Grenning, *Clean Code* ch.8) triggered by a *spike's* question (Beck) and selected via a *riskiest-assumption* lens. They are **not** "smoke tests" (which are broad-and-shallow — these are narrow-and-deep) and **not** disposable "spikes" ("spike" = the investigation act only; the artifact you keep is a learning test). The names matter for credibility.
>
> Born from a HIPAA-grade dental-software retrofit (A3, 2026-05-22) where plan-reviewer density was 33 → 23 → 62 → 55 → ~30 → 3 across 6 passes — diminishing but never converging because text review fundamentally can't validate runtime semantics like PgBouncer GUC scoping or Prisma TransactionClient atomicity. The assumption-test layer added concrete proof for the 5 most load-bearing assumptions in ~400 lines, gated by an env safety flag, idempotent, self-cleaning. (See the A3 worked example in `docs/script-reference.md`.)

## When to use

Invoke `/script` when ANY of the following hold:
- You have a plan that depends on runtime contracts you've never measured (pool behavior, isolation levels, callback semantics, race windows, retry policy, GUC scoping, Proxy interception, instanceof across modules).
- You're about to implement something whose failure mode is silent (no exception, just wrong rows committed; cursor advances past unwritten data; audit lost; PHI leaked).
- Stakes are real — production users, patient data, money, safety-critical infrastructure.
- The plan-reviewer cycle is showing diminishing-but-non-zero returns AND each pass surfaces "this design depends on X behaving Y way" findings.
- You're scoping a multi-slice ship and need per-slice regression gates that catch breakage at the right boundary.
- You just shipped a refactor and want to LOCK IN the contract by encoding it as a re-runnable test that fails loudly if it ever drifts.

## When NOT to use

- You can write a normal unit/integration test for the assumption — write the test, not an assumption test. Assumption tests are for things that need to run against REAL infrastructure (real DB, real pool, real worker) and are too narrow / heavyweight / setup-dependent for the standing test suite.
- The assumption can be validated by reading the code (e.g., "function X imports Y" — just grep for it).
- The stakes are low (toy project, prototype, internal tool used by 3 people).
- You haven't actually identified a load-bearing assumption — don't manufacture risks. If 5 minutes of thinking can't surface one, the project genuinely doesn't have one.

## Core philosophy (read before writing tests)

1. **An assumption test is not a unit test.** Unit tests live in `__tests__/` and exercise pure logic against mocks. Assumption tests live in `scripts/<feature>-assumptions/`, run against the real dev environment, are gated by an explicit safety env var, and prove that a RUNTIME CONTRACT holds. Different artifact, different audience, different lifecycle.

2. **Each test proves ONE assumption.** Multi-assertion tests are fine (e.g., A1/A2/A3 within the same test) but only when they share setup + cleanup. A test with two unrelated assumptions becomes a test with two unrelated failure modes; split it.
   - **One exception — the thin integration test.** You MAY write *exactly one* optional test that wires 2-3 already-proven contracts together in the implementation's *actual call order* (the walking-skeleton thread) to catch composition bugs the isolated tests can't. Keep it explicitly distinct from the per-assumption tests AND from a unit/integration test. Cap at one; per-assumption isolation stays the default.

3. **Reality > assertions about reality.** Don't write a test that asserts "the docstring says X" — write a test that DOES X against real infra and observes the outcome. The point is to learn what the runtime actually does, not what the documentation claims.

4. **Cheap to fail, expensive to ignore.** A test that takes 5 seconds to run and fails fast saves the team weeks of debugging post-deploy. Optimize for fast feedback + crisp diagnostics, not coverage.

5. **Re-runnable forever.** Today's pre-flight test is tomorrow's regression catcher. Design every test as if a future Claude (or human) will re-run it 3 months from now on a different branch. Idempotent. Self-cleaning. Deterministic. Stable marker + per-run UUID.

6. **Safety FIRST.** If a test can touch production state, it MUST be gated by an explicit env var (`<PROJECT>_SMOKE_ALLOW_DEV=true`) that refuses to run unless set. Match the existing project's safety conventions (e.g., A3 used `RLS_TESTS_ALLOW_DEV_NEON=true`). *(Gate var names keep the `_SMOKE_ALLOW_` form to match real per-project conventions; this is a deliberate exception to the assumption-test rename, not a miss.)*

## Step 1 — Resolve the context

Read the input (`$ARGUMENTS`):
- **Plan path** (e.g., `tmp/ready-plans/2026-05-22-foo.md`): read the plan; extract assumptions from §Verified Repo Truths, §Locked Decisions, §Architecture Overview, §Key Pseudocode.
- **Feature description** (free-form text): treat as the problem statement; supplement by reading recent git diff + any plan files in `tmp/ready-plans/`.
- **Blank**: auto-detect from conversation history. Look for the most recent plan, the most recent /implement target, the most recent /plan-reviewer findings, the user's stated current goal. If still ambiguous, ask 1 targeted clarifying question.

## Step 2 — Identify load-bearing assumptions

For the resolved context, enumerate every assumption whose failure would COLLAPSE the implementation, and classify each through the **risk lenses**. The lenses are a generative checklist (not a strict partition — they overlap by design; their job is to make you think of candidates):

- **Mechanics lenses:** FOUNDATION · ATOMICITY · API-SHAPE · SCALING · TERMINATION/RECOVERY · TEST-INFRA.
- **Cross-cutting lenses:** TIME/ORDERING/CAUSALITY · SECURITY/ISOLATION · MIGRATION/CONSISTENCY · VALUE-DOMAIN/ENCODING · OBSERVABILITY.

**Full lens catalog, with what each covers and examples, lives in `docs/script-reference.md`.** Read it when classifying. Skip cosmetic / mechanical / tsc-catchable items (those aren't load-bearing — they're catchable in normal review). For a HIPAA / multi-tenant system, the SECURITY/ISOLATION lens (tenant isolation actually enforced) is usually the single most load-bearing.

## Step 3 — Produce the catalog table

Before writing any tests, produce a 5-field table for review. Each row:

| # | Test filename | What it tests | Pass criteria | Fail means | How to run | Files touched |
|---|---|---|---|---|---|---|

The user (and you) should look at the table BEFORE writing tests. If the table lists 12 tests, you're over-building — narrow to the 3-7 most load-bearing. If it lists 1 test, you under-identified — push harder on the lenses.

Aim for **5-8 tests** for a substantial feature; **3-5** for a focused refactor; **2-3** for a small change.

## Step 3.5 — Adversarial catalog review (ALWAYS, run in parallel)

A passing test proves "this stated proposition held once." If the proposition is **mis-framed**, the test faithfully proves an irrelevant fact and *increases* false confidence. So every invocation runs one adversarial review of the catalog BEFORE writing tests — and to keep the skill fast, it runs **in parallel** with scaffolding.

1. Spawn ONE `plan-reviewer` sub-agent (via `Task`) with a **self-contained override prompt** — do NOT rely on the agent's default plan-file frame. Paste the catalog table inline and ask:
   > "Below is a catalog of proposed assumption tests for an upcoming implementation. For EACH row, answer: would a passing test actually de-risk the plan, or is the assumption mis-stated, tautological, or already verifiable by reading code? Return the revised rows (drop/merge/sharpen as needed) with a one-line reason per change. Output only the revised catalog table + a short notes list."
2. **While the review is in flight, scaffold in parallel:** create `scripts/<feature>-assumptions/`, the `run-all.sh` skeleton (Step 5), and the `README.md` skeleton.
3. When the review returns, revise the catalog per its feedback, then proceed to write the actual tests (Step 4). **After the catalog is final, backfill the scaffolded skeletons** — replace `run-all.sh`'s placeholder `TESTS=()` array and the README's test list with the real, revised filenames (the skeleton's `01-foo.mjs`/`02-bar.mjs` placeholders must not survive).

## Step 4 — Write the tests (THE SAFETY PATTERN)

Every test MUST follow these rules. Non-negotiable.

1. **Safety env gate.** First executable lines: read a `<PROJECT>_SMOKE_ALLOW_<ENV>=true` env var; if absent, `console.error('REFUSED: ...'); process.exit(2)`. Match the project's existing safety convention if one exists (`RLS_TESTS_ALLOW_DEV_NEON`, `STRIPE_SMOKE_ALLOW_TEST_MODE`, `S3_SMOKE_ALLOW_TEST_BUCKET`, etc.).

2. **Per-run UUID + stable namespace marker.** `import { randomUUID } from 'node:crypto'; const runId = randomUUID();` Every synthetic resource name embeds BOTH `runId` (so parallel runs never collide and this run's cleanup is precisely scoped) AND a constant namespace marker (e.g. a `__atest__` prefix) plus an inserted-at timestamp (so a LATER run can find and reap orphans from a PRIOR crashed run — the per-run UUID alone cannot do this).

3. **Idempotent.** Re-running with no state changes produces the same outcome (PASS or FAIL for the same reason). No "succeeds the first time, fails the second." Use upsert-style setup. Use marker-prefixed `deleteMany` cleanup that tolerates multiple prior runs.

4. **Self-cleaning + startup orphan-reaper.** A `try { ... } finally { cleanup; client.disconnect() }` block cleans THIS run's resources by `runId`. Additionally, AT STARTUP, reap orphans from prior crashed runs keyed on `namespace marker + age threshold` (rows older than e.g. 1h tagged with the marker) — because `finally` does not survive SIGKILL / OOM / power loss. Cleanup failure logs `CLEANUP WARNING:` but does NOT change the exit code.

5. **Deterministic exit codes.**
   - `0` — PASS (all assertions PASS).
   - `1` — FAIL (≥1 assertion FAIL; the body should print the failure list).
   - `2` — REFUSED (safety env gate not set).
   - `3` — INFRASTRUCTURE FAIL (couldn't connect to DB, network down, dependency missing, OR a hang/timeout). NOT a logical failure; the test couldn't even run.

6. **Crisp output.** On PASS: `console.log('PASS: <test-name> — N assertions (A1, A2, ...)')`. On FAIL: `console.error('FAIL: <test-name>'); for (const f of failures) console.error('  -', f);`. CI-parseable. Don't bury results in verbose logs.

7. **One assertion = one named anchor.** Inside the test, comment each assertion as `// A1 — <what it proves>`. The failure messages reference the anchor (`A1 expected X, got Y`). Diagnosing a FAIL takes ≤30 seconds.

8. **Minimal dependencies.** Prefer the project's existing client (Prisma client, fetch, http, fs). Stubs are permitted ONLY for collaborators that are NOT the assumption under test, and MUST be thin pass-throughs to real infra, never behavioral reimplementations (a hand-rolled stub that encodes the same assumption you're trying to prove is the "assumption test that's actually a unit test" anti-pattern — see `docs/script-reference.md`).

9. **Prove it can go RED (negative control).** A green is worthless if the test would pass even when the assumption is false. At authoring time, confirm the test exits `1` when the assumption is violated, by ONE of two routes:
   - **Controllable precondition:** flip the input/state the assumption depends on and confirm exit 1.
   - **Infra-fixed contract** (e.g. PgBouncer pool mode you can't reconfigure at author time): inject a synthetic wrong value into the test's OWN assertion path and confirm the failure-detection fires.
   A test that cannot be made to go RED by either route is proving nothing — fix it. Record the route in a `// NEGATIVE CONTROL:` comment.

10. **Environment fingerprint.** On PASS, print and persist (to a committed `<NN>-<name>.fingerprint.json` beside the test) the **assumption-relevant** facts the result depends on — e.g. the PgBouncer test records `{pgbouncer_mode, pg_version}`, NOT a generic blob of `node_version`/`schema_hash` that churns benignly. A future re-run compares fingerprints: a mismatch means the environment drifted → **re-validate** (never auto-fail).

11. **Read-only by default for FOUNDATION probes.** Where an assumption is verifiable without writes (read-after-write reads, GUC scoping reads), prefer a read-only / least-privilege connection to shrink the blast radius.

## Step 5 — Wire the run-all + README

In the same directory as the tests:

- `run-all.sh` — runs all tests sequentially, halts on first FAIL, prints duration, maps a hang (timeout, exit 124) to INFRASTRUCTURE FAIL (exit 3), exits with the first failure's code. Template:

```bash
#!/usr/bin/env bash
set -uo pipefail
if [ "${<ENV_GATE>:-}" != "true" ]; then
  echo "REFUSED: set <ENV_GATE>=true to run assumption tests" >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS=( "01-foo.mjs" "02-bar.mjs" "03-baz.mjs" )
PASS=0; START=$(date +%s)
for t in "${TESTS[@]}"; do
  echo; echo "--- ${t} ---"
  if timeout 60 node "${SCRIPT_DIR}/${t}"; then
    PASS=$((PASS+1))
  else
    rc=$?; [ "$rc" = 124 ] && rc=3   # timeout/hang → INFRASTRUCTURE FAIL
    exit "$rc"
  fi
done
echo; echo "PASS: ${PASS}/${#TESTS[@]} in $(( $(date +%s) - START ))s"
```

- `README.md` — explains: what these tests prove, pre-implementation gate, post-slice regression gate, how to run (individual + run-all), safety notes, exit-code semantics, output format, and the fingerprint files.

## Step 6 — Suggest gate placement

After tests are written, tell the user:

```
Pre-implementation gate (BEFORE /implement):
  bash scripts/<feature>-assumptions/run-all.sh
  All N must PASS before implementation begins.

Post-implementation regression gate (AFTER each ship):
  Re-run after each slice ships (or after each meaningful commit).
  Same tests; same pass criteria. Any FAIL = regression.

Optional integration:
  - Wire into CI: add `npm run assumptions:<feature>` that calls run-all.sh
  - Wire into pre-merge: block PR merge if assumption tests fail
  - Wire into /implement: run automatically before implementation
```

## Output layout

```
scripts/
└── <feature>-assumptions/
    ├── README.md
    ├── run-all.sh
    ├── 01-<assumption-name>.mjs
    ├── 01-<assumption-name>.fingerprint.json
    ├── 02-<assumption-name>.mjs
    ├── ...
    └── (optional) reference/
        └── <stubbed-data-or-fixtures>.json
```

Naming: `<NN>-<kebab-case-assumption-name>.<ext>`. Two-digit prefix for ordering. Use `.mjs` for ESM Node tests (matches A3 pattern). Use `.ts` only if the project has a TypeScript runtime convention (`tsx`, `ts-node`).

## Integration with `/plan`

`/plan` Step 5 ALWAYS emits a visible assumption-test assessment (it reads the plan-reviewer's `## Assumption-Test Candidates` section). When that surfaces candidates, the user is pointed here. `/plan` never auto-generates tests — it surfaces the decision; `/script` does the work.

## Integration with `/plan-reviewer`

When plan-reviewer surfaces findings of the form "this design depends on X behaving Y way" (a load-bearing assumption that hasn't been verified), it tags them `[ASSUMPTION-TEST]` and ALWAYS emits a `## Assumption-Test Candidates` section (listing them, or `_None surfaced_`). When invoked, `/script` extracts these tagged findings as its starting catalog.

## Integration with `/implement`

If a `scripts/<feature>-assumptions/run-all.sh` exists for the current feature, `/implement` should:
1. Run it BEFORE the first implementation chunk; halt if it fails.
2. Re-run it AFTER each chunk ships; report regressions.
3. Re-run it at end-of-implementation as final regression check.

This catches drift introduced by implementation that text-level impl-reviewer would miss.

## STOP rules

- **No more than 8 tests** for a single /script invocation. If you find 12 load-bearing assumptions, you're either over-classifying (some are cosmetic) or the scope is too big (split into smaller features, then /script each).
- **No test over 150 lines.** If you can't prove an assumption in 150 lines, the assumption is too composite — decompose into 2-3 atomic assumptions.
- **No test that takes more than 60 seconds to run.** Assumption tests are FAST feedback. (run-all.sh enforces this via `timeout 60`.) If you need long-running validation, that's an integration test.
- **No test that mutates state without cleanup.** Cleanup is in `finally` (by runId) + startup reaper (by marker+age). Always. For assumptions whose side effects CANNOT be rolled back (real Stripe charge, S3 PUT, consumed queue message), use **tag-and-reap + a hard environment-disposability check** (refuse to run unless the target is provably a disposable dev/test environment) rather than refusing to test them.
- **Don't manufacture risks.** If you can't articulate "what would break if this assumption is wrong," don't write a test for it.

## Re-running mechanics (regression-catcher protocol)

Once assumption tests exist for a feature, they become part of the feature's permanent test surface:

1. **After every meaningful change to feature code**, re-run the relevant tests.
2. **Pre-merge**: PR template references the tests; reviewer checks they were re-run + PASS.
3. **CI**: add `bash scripts/<feature>-assumptions/run-all.sh` as a CI job (after setting the env gate in the CI env).
4. **Post-deploy**: re-run against dev after each deploy as a canary; if FAIL, investigate before promoting.
5. **Drift detection**: each test's `*.fingerprint.json` records the assumption-relevant environment facts at PASS time. On re-run, a fingerprint mismatch (e.g. PgBouncer config tuned, Prisma major bumped) means the environment drifted → **re-validate** before trusting the green. This converts drift from a human-memory problem into a detectable diff.

## Sub-agent vs in-process

The **adversarial catalog review (Step 3.5) always runs as one sub-agent** on every invocation (counted in `expected_subagents`). The rest of the skill runs in-process — read the plan, write 3-8 small files, produce a catalog.

For VERY LARGE plans (>1000 lines + multi-domain) where assumption extraction itself is non-trivial, the skill MAY additionally delegate the extraction phase to sub-agents (one per domain) to keep main context lean, then merge and write in-process. That extra delegation is optional and separate from the always-on catalog review.

## End-of-skill checklist

Before reporting done, verify:
- [ ] N tests written, where 2 ≤ N ≤ 8 (plus at most one thin integration test).
- [ ] Each test has the safety-pattern items (env gate, UUID + stable marker, idempotent, self-clean + startup reaper, exit codes, crisp output, named anchors, minimal deps, **negative control proven**, **fingerprint persisted**).
- [ ] Negative control recorded in a `// NEGATIVE CONTROL:` comment on each test (controllable-flip or synthetic-injection route).
- [ ] Each test typechecks/parses clean via a standalone check (`node --check` / `tsc --noEmit <file>`) — assumption-test dirs are often outside the project's build `include`.
- [ ] Catalog table presented to user (with all 5 fields) AND run through the adversarial review (Step 3.5).
- [ ] `run-all.sh` (with `timeout 60` + 124→3 remap) + `README.md` written.
- [ ] Suggested pre-implementation + post-slice gate placement told to user.
- [ ] If `/plan-reviewer` surfaced `[ASSUMPTION-TEST]` findings, every candidate is addressed by a test OR explicitly deferred with justification.
- [ ] User knows how to invoke `run-all.sh` (exact command with env gate prefilled).

End by telling the user: "N assumption tests written at `scripts/<feature>-assumptions/`. Run pre-flight: `<ENV_GATE>=true bash scripts/<feature>-assumptions/run-all.sh`. All PASS = green light for /implement. Any FAIL = halt + diagnose."

---

> **Reference:** the full risk-lens catalog, the A3 worked example, and the anti-patterns live in [`docs/script-reference.md`](../docs/script-reference.md). Read it when classifying assumptions or when you need a worked illustration.
