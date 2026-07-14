<!-- GOLDEN REFERENCE — proves /testplan COLLAPSES to the core for a trivial read-only target.
     The three risk-gated extensions (ordering/fault catalog, contract-pinning, mutating recipe fields)
     are correctly OMITTED, each with a stated reason. Lean is a success here, not a shortfall. -->

# Test Plan — Static "About" Page

*single inline enumeration pass (no fan-out) · CORE-only (trivial read-only target)*

## Phase 0 — Target + archetype
- **Archetype:** UI app (display-only slice). No API, CLI, worker, queue, migration, or protocol surface.
- **Risk profile:** minimal — no money, PHI, permissions, external writes, or cross-boundary state.

## 1. Scope + out-of-scope
**In scope:** one static "About" page — a single `<h1>`, one paragraph of body copy, and one external link
that opens in a new tab. Pure render; reads no data, calls nothing.
**Out of scope (stated, not laundered):** the external link's *destination* (third-party, not owned — see
BLK-1); backend/API/auth/data/state (none exist by definition); pixel-fidelity styling (behavior, not layout).

## 2. Role model
- **Persona:** Visitor (unauthenticated). **Job:** read who/what this is about, and optionally follow the
  link out in a new tab without losing the page. That single job is the entire E2E.

## 3. Arsenal + safety inventory
*Read-only reasoning only; mutation budget = ZERO; deny-by-default (no sandbox signal → treated as prod, nothing run).*
- DOM-render assertion + link-attribute read → `assumed-available (probe deferred)` — the core proving tools.
- Live browser to click the external link → `unsafe-to-probe` (hits a real host) → deferred to an
  execution-time preflight with user approval.

## 4. Coverage table
| case-id | claim / authority | proving level | risk | status | oracle |
|---|---|---|---|---|---|
| AB-001 | heading renders with intended text (spec) | rendered-DOM | LOW | planned | one `<h1>` == expected string |
| AB-002 | paragraph renders intended copy (spec) | rendered-DOM | LOW | planned | paragraph text == spec |
| AB-003 | link renders correct `href` (spec) | attribute read | LOW | planned | `href` === intended URL |
| AB-004 | link opens new tab safely (`target=_blank` + `rel=noopener`) (security invariant) | attribute read | LOW-MED | planned | `target=_blank` AND `rel` has `noopener` |
| AB-005 | pure display — no network/data call, no console errors (invariant) | render + net/console watch | LOW | planned | zero fetch/XHR fired, no thrown errors |

*Adequacy: AB-004 fails loudly if `rel` is missing (reverse-tabnabbing red signal); AB-005 fails if any
network request is observed — proving the page isn't secretly non-static.*

## 5. Coverage ledger
- **Covered:** all five surface elements map to a case. Closure: every content requirement + the one
  security invariant maps to a case.
- **Blockers:** **BLK-1 — external link destination:** whether the URL still resolves is unknowable from
  inside this target (owner: content/product; disposition: documented deferral + optional live-click
  preflight). Not a silent skip.

## 6. Final verdict
- **Claims:** 5 planned · 0 proven (this is a plan) · 1 blocked-by-scope (BLK-1) · 3 excluded (declared).
- **READY / NOT-READY:** **READY to execute** — runnable as-is with a DOM-render + attribute-read harness;
  no blocker prevents the five in-scope cases. (Not "proven" — execution is the next step.)
- **Residual risk:** near-zero within scope; only the external destination can drift (BLK-1).

**Extensions deliberately omitted** (no surface for them): contract-pinning (no producer↔consumer boundary);
ordering/concurrency/fault catalog (nothing stateful/mutating/async); mutating recipe fields
`forbidden-effects / still-correct-after-reload / cleanup` (all cases pure read-only → `N/A`, justified).

**Next step:** execute the five cases with a render harness. Do not hand to `/mission` (a build conductor,
not a test runner).
