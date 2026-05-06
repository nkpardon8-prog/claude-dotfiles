# god-review CRITERIA — Single Source of Truth

This file is read by the orchestrator (`god-review.md`) AND every principle subagent and broad reviewer.
**Do not redefine any taxonomy in individual principle files.** Each principle file's Scoring Criteria section says:
"See CRITERIA.md for confidence/severity definitions; the thresholds below are principle-specific."

---

## Confidence Taxonomy

Every finding must carry exactly one confidence tag. Choose the one that fits, not the most alarming.

| Tag | Meaning |
|---|---|
| `[definite]` | You have read the code and are certain this is a real issue. Reproducible without further research. |
| `[likely]` | Strong signal but requires one more verification step (e.g., need to confirm caller, confirm env config) that you cannot complete in read-only mode. |
| `[investigate]` | Suspicious pattern that warrants a human look. Could be intentional or context-dependent. Do NOT suppress it — report it in Minor unless overridden. |

**Quality over quantity. Every finding should be worth acting on. Do not flood the report with low-signal investigate items.**

---

## Standard Section Mapping

After confidence promotion is applied (see Promotion Priority Order below), map findings to sections:

| Confidence (post-promotion) | Category (non-special) | Section |
|---|---|---|
| `[definite]` | anything except MISSING / ASSUMPTION / CONTRADICTION | Critical |
| `[likely]` | anything except MISSING / ASSUMPTION / CONTRADICTION | Important |
| `[investigate]` | anything except MISSING / ASSUMPTION / CONTRADICTION | Minor |

### Override Rules

The following categories **override section assignment regardless of confidence level**:

| Category | Assigned Section | Notes |
|---|---|---|
| `MISSING` | Gaps | Anything entirely absent from the codebase |
| `ASSUMPTION` | Assumptions | Implicit assumption baked into the code or design |
| `CONTRADICTION` | Contradictions | Two parts of the system disagree with each other |

---

## Category Enum

Every finding must carry exactly one category from this list. Choose the narrowest applicable.

```
BUG                  — Incorrect behavior, wrong output, data corruption
LOGIC                — Flawed business logic, wrong algorithm, off-by-one
ARCHITECTURE         — Structural / coupling / layering concern
SECURITY             — Injection, auth bypass, data exposure (generic; use specific if available)
MISSING              — Entirely absent: missing guard, missing handler, missing test, missing feature
ASSUMPTION           — Implicit assumption baked into code with no validation
CONTRADICTION        — Two parts of the system disagree (doc vs. code, schema vs. model, etc.)
FRAGILITY            — Works now but breaks under foreseeable conditions
RACE_CONDITION       — Concurrency hazard, missing lock, TOCTOU
ERROR_HANDLING       — Error swallowed, wrong status code, missing fallback
TYPE_ERROR           — Runtime or compile-time type mismatch
CROSS_LAYER_GAP      — DB↔API↔frontend data contract mismatch
DATA_INTEGRITY       — Missing transaction, orphaned data, missing cascade
ASYNC                — Missing await, unhandled promise, callback hell
COUPLING             — Tight coupling, violation of separation of concerns
DEAD_CODE            — Unreachable code, unused export, deleted-but-imported
SLOPPINESS           — Magic numbers, console.log left in, commented-out code, TODO left in prod
PROD_READINESS       — Missing rate limit, timeout, circuit breaker, retry logic
SCALABILITY          — N+1 query, unbounded query, missing index, O(n²) hot path
DOC_ERROR            — Documentation contradicts or omits actual behavior
NAMING               — Misleading or inconsistent name
CONVENTION           — Deviation from project/repo conventions
DUPLICATION          — Duplicated logic, copy-paste across modules
COMPLEXITY           — Unnecessary abstraction, over-engineered, hard to read
INJECTION            — SQL injection, command injection, template injection
AUTH_BYPASS          — Missing auth check, broken access control
IDOR                 — Insecure direct object reference
DATA_LEAK            — PII/secret in logs, response, or error message
MISSING_SAFEGUARD    — Missing guard rail (e.g., no max size on upload, no pagination cap)
MISSING_VALIDATION   — User input accepted without validation
RESILIENCE           — Missing retry, missing fallback, single point of failure
RATE_LIMIT           — Missing or insufficient rate limiting
IDEMPOTENCY          — Non-idempotent operation that should be idempotent
BROWSER_BUG          — Browser-specific rendering or JS execution issue
```

---

## Risk-Level Taxonomy

Applies to the finding's blast radius and recoverability, independently of section placement.

| Risk | Meaning |
|---|---|
| `LOW` | Cosmetic, style, no user impact. Reversible trivially. |
| `MED` | Affects developer experience, test reliability, or minor user UX. Reversible with a single commit. |
| `HIGH` | Affects correctness, data quality, or security surface. Requires careful fix + verification. |
| `CRITICAL` | Data loss, auth bypass, secret exposure, or production outage risk. Must fix before next deploy. |

---

## PASS / WARN / FAIL Aggregator

Used in the Meta-Review section of the final report and in Phase 1 baseline gate status.

| Verdict | Condition |
|---|---|
| `PASS` | Zero `CRITICAL` risk findings AND zero `[definite]` findings in Critical section |
| `WARN` | One or more `[definite]` findings in Critical section, OR one or more `HIGH` risk findings, AND no `CRITICAL` risk findings |
| `FAIL` | One or more `CRITICAL` risk findings. Immediate human attention required. |

---

## Principle Index

All 23 principles classified into tiers. **Tier 1 = always promote on hit** (single-level confidence promotion before section assignment). Tier 2 = standard severity, no promotion. Stack-gating applies regardless of tier — a stack-gated principle self-skips in Phase 1 if its signal is empty.

| Principle | Tier | Stack gate | Promotion |
|---|---|---|---|
| single-pattern | 1 | always-on | yes |
| secret-leak | 1 | always-on | yes |
| prompt-injection | 1 | always-on | yes |
| hallucinated-imports | 1 | always-on | yes |
| test-deletion | 1 | always-on | yes |
| ci-yaml-tampering | 1 | always-on | yes |
| reuse | 2 | always-on | no |
| clarity | 2 | always-on | no |
| scope | 2 | always-on | no |
| antipatterns | 2 | always-on | no |
| documentation | 2 | always-on | no |
| circular-deps | 2 | always-on | no |
| dead-code-conservatism | 2 | always-on | no |
| architecture-backend | 2 | HAS_AUTHED_HANDLER OR HAS_BACKEND_PROJECT | no |
| architecture-frontend | 2 | HAS_APP_ROUTER | no |
| self-contained | 2 | HAS_UI_PROJECT | no |
| tanstack-query | 2 | HAS_TANSTACK_QUERY | no |
| perf-heuristic | 2 | always-on | no |
| perf-benchmark | 2 | HAS_BENCH_SCRIPT | no |
| dead-end-detector | 1 | always-on | yes |
| info-loss-detector | 1 | always-on | yes |
| contradiction-detector | 1 | always-on | yes |
| gap-detector | 1 | always-on | yes |

The `--ruthless` flag activates `claude-ruthless-redteam` as a 4th broad reviewer in Layer A alongside the standard 3 Claude broad reviewers. This reviewer uses a skeptic-first prompt (see `broad-reviewers/claude-ruthless-redteam.md`) and its findings require Codex confirmation for cross-model promotion per Locked Decision #8.

---

## Promotion Priority Order

**Maximum 1 promotion per finding total.** Promotions elevate confidence by exactly one level (`[investigate]→[likely]`, `[likely]→[definite]`). A `[definite]` finding cannot be promoted further.

Apply in this order — stop at the first rule that fires:

1. **Cross-model agreement `(both)`** — finding reported by at least one Claude source AND at least one Codex source (after pre-promotion hash-merge). Promotes by +1 level. If this fires, skip rules 2 and 3.
2. **Single-pattern / failure-class promotion** — finding's principle is Tier 1 (see table above). Promotes by +1 level. If this fires, skip rule 3.
3. **Codex-validator CONFIRMED** — Codex verification pass returned `CONFIRMED` for this finding. Promotes by +1 level.

If none of the three fire, no promotion is applied.

**Note on MISSING / ASSUMPTION / CONTRADICTION findings:** Promotion still applies to confidence (which affects risk level and how urgently the finding is worded), but section assignment is always overridden by the category — these always land in Gaps / Assumptions / Contradictions regardless of confidence level.
