# `/script` Reference — Risk Lenses, Worked Example, Anti-Patterns

Supporting reference for the [`/script`](../commands/script.md) skill (the assumption-test generator). The command file holds the procedure; this file holds the detail you consult while classifying assumptions or when you want a worked illustration.

---

## Risk lenses (a generative checklist, NOT a strict partition)

These lenses overlap by design — they are layers of a stack and cross-cutting concerns, not disjoint buckets. Their job is to make you *think of* load-bearing assumptions you'd otherwise miss, not to file each cleanly. When in doubt which lens an assumption belongs to, it doesn't matter — what matters is that you found it.

### Mechanics lenses (what kind of runtime object misbehaves)

1. **FOUNDATION** — infrastructure-level contracts the entire design rests on. Examples: PgBouncer transaction-mode GUC scoping; PostgreSQL row-locking semantics; Redis SETEX TTL precision; S3 read-after-write consistency; Kafka exactly-once delivery; OS file-locking semantics. If wrong, the design is moot regardless of code.

2. **ATOMICITY** — does an operation that you THINK commits as one unit actually do so? Prisma `$transaction` callback semantics, multi-row `updateMany` atomicity, multi-statement transactions across pooled connections, application-level "transaction" abstractions wrapping multiple operations.

3. **API SHAPE** — does a function/type/import you depend on actually have the *structural* shape your pseudocode assumes? Helper signatures, type re-exports, return shapes (`{event, truncated}` vs bare `event`), allowlist constants, error class hierarchies, `instanceof` across module boundaries. (Value-domain *correctness* is a separate cross-cutting lens — see below.)

4. **SCALING** — does the design hold up under projected load? Pool connection ceilings, rate-limiter token-bucket behavior, queue throughput, lock contention, fan-out timing budgets, OOM thresholds for large payloads.

5. **TERMINATION / RECOVERY** — does the system handle failure modes correctly? Retry policy short-circuits (DeadLetterError vs generic Error), worker SIGTERM mid-frame, idle-tx timeout, partial-write reconciliation, cursor advance after crash, idempotency-key collision behavior.

6. **TEST INFRA** — does the test mechanism you plan to use actually work? Spy interception across Proxy boundaries (`vi.spyOn` on Prisma TransactionClient), fixture cleanup, gate env vars, CI vs local divergence. (This is meta-level — it's about the *validation apparatus*, not the system under design — so treat it as a "before you trust the test, prove the test can observe what it claims" pre-flight.)

### Cross-cutting lenses (concerns that span the whole stack)

7. **TIME / ORDERING / CAUSALITY** — clock skew between nodes; TTL / expiry boundary precision; timezone / DST in scheduled work; monotonic-vs-wall-clock for timeouts; **causal ordering / message reordering**; out-of-order event arrival. Note: a cursor advancing past unwritten data is fundamentally an *ordering / visibility* hazard, NOT an atomicity one — don't let ATOMICITY swallow ordering bugs.

8. **SECURITY / ISOLATION** — does the authorization boundary actually hold? RLS / tenant isolation genuinely enforced (no cross-tenant reads); authz check ordering (TOCTOU on permission); secret scoping; signed-URL expiry; IDOR-style cross-tenant access. For a multi-tenant HIPAA / financial system this is usually the single most load-bearing assumption — and it has historically been the easiest to omit from a mechanics-only taxonomy.

9. **MIGRATION / CONSISTENCY** — does a schema change or backfill preserve invariants? Migration reversibility; backfill convergence; dual-write consistency during a cutover window; "compensating updates always work" (they don't, reliably). High-stakes whenever the plan touches schema or moves data.

10. **VALUE-DOMAIN / ENCODING** — is the *value* correct, not just the structure? Money-as-float (use integer cents / Decimal); timezone-naive timestamps; UTF-8 / collation; `Decimal` vs `Number` across the Prisma/JS boundary; numeric overflow; JSON round-trip lossiness.

11. **OBSERVABILITY** — when this fails in production, will we be able to SEE it? Are the failure modes logged / traced / alertable? This is distinct from TEST-INFRA (which is about whether your *test* can observe behavior) — this is about whether *production* can.

For each assumption identified, name its lens(es) and skip cosmetic / mechanical / tsc-catchable items.

---

## Worked example — A3 OD orchestrator retrofit

**Context:** A3 retrofitted the OpenDental sync backbone of a HIPAA-grade dental SaaS. The plan went through 6 plan-reviewer passes (density 33 → 23 → 62 → 55 → ~30 → 3) without truly converging because text review couldn't validate runtime contracts. The `/script` invocation identified 5 load-bearing assumptions and wrote a test for each.

### Catalog (the 5-field table for A3)

| # | Test | Tests | Pass | Fail means | Run | Files touched |
|---|---|---|---|---|---|---|
| 01 | `01-pgbouncer-guc-scoping.mjs` | `SET LOCAL app.current_clinic_id` is tx-scoped + doesn't leak across pool connections + released on rollback | 4 assertions PASS | **ENTIRE design moot.** PgBouncer transaction-mode behavior differs from assumption → all GUC strategy must be redesigned | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-assumptions/01-pgbouncer-guc-scoping.mjs` | Read-only |
| 02 | `02-withClinicContext-atomicity.mjs` | Throw inside `prisma.$transaction` callback rolls back all writes in that frame; sibling frames unaffected | 3 sentinel-presence assertions PASS | Per-page-commit atomicity contract BROKEN → cursor + upsertPage cannot commit atomically | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-assumptions/02-withClinicContext-atomicity.mjs` | 3 sentinel AuditEvent rows (cleaned up) |
| 03 | `03-cluster-drain-baseline.mjs` | Existing `runEntityWithCursor` cluster-drain logic produces expected cursor advance on 100/100/25 same-DateTStamp page sequence | Cursor = baseline + 1s; upsertPage called 3× | Existing semantic differs from docstring → cursor.ts:103-119 docs wrong → must re-read before refactor | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-assumptions/03-cluster-drain-baseline.mjs` | 1 OdSyncCursor row (cleaned up) |
| 04 | `04-audit-primitive-shape.mjs` | `normalizeAuditEventForBoundedWrite` returns `{event, truncated}`; throw inside `tx.auditEvent.create` propagates + rolls back surrounding tx; custom Error subclass instanceof works cross-module | 3 assertions PASS | `writeOdWritebackAuditInTx` pseudocode is fiction → must rewrite before A3.2 | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-assumptions/04-audit-primitive-shape.mjs` | 1 rolled-back insert attempt; 0 committed |
| 05 | `05-deadletter-shortcircuit.mjs` | Worker job throwing `DeadLetterError` dead-letters in 1 attempt (NOT MAX_ATTEMPTS=5); generic Error retries fully | 2 JobQueue state assertions PASS | `DeadLetterError` doesn't short-circuit → WritebackAuditValidationError wrapping won't prevent retry waste → must redesign Frame 2 catch | `RLS_TESTS_ALLOW_DEV_NEON=true node scripts/a3-assumptions/05-deadletter-shortcircuit.mjs` | 2 synthetic JobQueue rows (cleaned up) |

### Categorization of those 5 (by lens)

- 01 → **FOUNDATION** (infrastructure contract) — also touches **SECURITY/ISOLATION** (the GUC IS the tenant boundary).
- 02 → **ATOMICITY** (transactional contract)
- 03 → **API SHAPE** + **TIME/ORDERING** (cluster-drain is a cursor-ordering semantic; also a regression baseline)
- 04 → **API SHAPE** (new primitive's building blocks)
- 05 → **TERMINATION / RECOVERY** (retry policy contract)

Notably absent: SCALING (deferred to a per-tenant pool baseline measurement — different artifact) and TEST INFRA (deferred to a small `vi.spyOn` verification during test writing).

### Outcome

5 tests × ~80 lines avg = ~400 lines. If all 5 PASS → the load-bearing assumptions are validated; /implement can begin with high confidence. If any FAIL → halt + redesign the affected plan section.

---

## Anti-patterns to avoid

- **The "assumption test that's actually a unit test."** If you find yourself mocking the thing under test, you're writing a unit test. Move it to `__tests__/` and rewrite to use real infra. (This is exactly why the safety pattern forbids behavioral stub reimplementations — a hand-rolled stub can encode the same wrong assumption the test is meant to disprove.)
- **The "comprehensive coverage" test.** Assumption tests are NOT coverage. They prove specific load-bearing assumptions. Trying to cover every code path is the wrong artifact.
- **The "manual cleanup" test.** Telling the user "run this DELETE statement after" defeats idempotency + safety. Cleanup is in the test (`finally` by runId + startup reaper by marker+age).
- **The "shared global state" test.** Two tests that depend on each other's state defeat per-test isolation. Each test sets up its own state with the stable marker + per-run UUID. (The one sanctioned exception is the single optional thin integration test.)
- **The "noisy log" test.** Verbose logs hide the pass/fail signal. Print the PASS line on success, the FAIL list on failure, nothing else (use a `--verbose` flag if needed; default to quiet).
- **The "no env gate" test.** A test that can touch real infra and isn't gated by an env var is a footgun. Always gate.
- **The "wrong gate" test.** A test gated by an env var that's already always-true in the project context (e.g., `NODE_ENV=development`) isn't gated. The gate must be EXPLICITLY set by the human runner.
- **The "green I never proved could go red" test.** A test with no negative control may be tautologically true (asserting a value equals itself, or asserting on a mocked path). A green is only trustworthy once you've shown the test goes RED when the assumption is false. (Safety rule 9.)
- **The "stale green" test.** A passing test whose environment has drifted since the green (Prisma major bump, PgBouncer retune) is lying. The `*.fingerprint.json` exists to catch this — a fingerprint mismatch means re-validate.
