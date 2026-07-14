<!-- GOLDEN REFERENCE — proves /testplan fires the FULL MACHINERY for a mutating + external-boundary +
     irreversible target: derived lenses, a real user journey per job, a 9-entry ordering/fault catalog
     (each outcome-changing), contract-pinning scoped to the real boundary, a tiered per-item recipe,
     FOUR BLOCKED rows (oracle + access gaps), and a NOT-READY verdict with counts. A vacuous
     present-but-empty-headings plan would FAIL the skill's adequacy self-lint. -->

# Test Plan — Account Settings (email change · password change · 2FA/TOTP · account delete)

## Phase 0 — Target + archetype
**Scope:** prove an authenticated owner can, in-session, (a) change email with external re-verification
gating activation, (b) change password, (c) enable TOTP 2FA, (d) delete their account — across HTTP API, DB,
and the external email provider, including the ordering/fault interactions between the four mutations.
**Out-of-scope (stated):** unauthenticated sign-up/login/reset happy-paths; the provider's delivery infra
(we own the send request + link consumption); multi-actor/admin; UI layout.
**Archetype:** HTTP API over a stateful account aggregate with two external seams (email provider; TOTP
time). Single persona → no UI-element lens, no role-matrix (stated N/A, not dropped).

## Phase 1 — Comprehend + recon (read-only, deny-by-default)
**Role model — single persona (stated once here):** the authenticated account owner. Jobs → J1 migrate email
safely · J2 rotate password + evict sessions · J3 enroll authenticator · J4 erase account. This is a
security-critical self-service surface — every op is an account-takeover or account-loss vector.
**Authority precedence:** security/auth invariants > product spec > email-provider contract > observed code
(last, never promoted to "expected"). Invariants (the read-back oracles where no exact value exists):
- INV-1 email activation is gated (old email active until verified; exactly one active email).
- INV-2 verification token single-use + bound + expiring.
- INV-3 no auth power from an unconfirmed factor (provisioned-unconfirmed TOTP never satisfies a challenge).
- INV-4 deleted is terminal (no token/session/link reads/mutates/resurrects; no orphan rows).
- INV-5 uniqueness holds at activation time, not just request time.
- INV-6 idempotency: every external side-effect at-most-once under retry/duplicate.
**History scan (known bug-classes for this shape → regression cases):** replayable link (ORD-05);
verify∥delete race (ORD-07); send-after-commit double token (ORD-04); stale/superseded token (ORD-06);
password change doesn't evict sessions (PW-03); delete leaves orphan pending-token (ORD-03); TOTP clock-skew
(TF-04).
**Arsenal + blast radius:** every capability `assumed-available (probe deferred)` or `unavailable` — nothing
`verified` (no infra to inspect); nothing may back a "proven" claim. Deny-by-default: API/DB/provider treated
as PRODUCTION until an explicit sandbox signal; zero mutation while planning; every mutating/external check
deferred to an execution-time preflight (user approval + verified disposable target). Needed (all deferred):
sacrificial-account provisioner, sandbox inbox, scoped DB read-back, deterministic TOTP generator, clock
control, log/secret scanner, provider send-log.

## Phase 2 — Surface enumeration (single inline pass; fan-out not warranted)
**Entry points:** EP-01 `GET /account/settings` (read) · EP-02 `POST /account/email/change` · EP-03
`GET|POST /account/email/verify?token` · EP-04 `POST /account/password/change` · EP-05 `POST /account/2fa/enroll`
· EP-06 `POST /account/2fa/confirm` · EP-07 `POST /account/delete`.
**Seams:** email-provider send (EP-02); TOTP shared-secret-time (no network). **Actor:** session owner (role
matrix N/A). **State:** `current_email`, `pending_email`+`token`+`expiry`, `password_hash`, `totp_secret`+
`totp_confirmed`, `recovery_codes`, `account_status`, `sessions[]`.
**Quality attributes (applicable-or-skipped):** security/privacy/abuse APPLICABLE (primary); observability/
audit APPLICABLE; resilience APPLICABLE; data-lifecycle APPLICABLE (hard vs soft delete → BLK-02);
accessibility N/A (API); perf N/A for correctness (rate-limiting under security); deploy/rollback N/A.
**Closure bar:** every EP, transition, INV-1…6, named history bug, and applicable quality attribute maps to a
row or a ledger gap.

## Phase 3 — Dynamic design
**State model:** `ACTIVE` →(EP-02)→ `ACTIVE+email-pending` →(EP-03 valid)→ `ACTIVE(swapped)` | (expiry/
supersede)→ `ACTIVE`. 2FA: `no-2fa` →(EP-05)→ `provisioned-unconfirmed` →(EP-06 valid)→ `active`. Terminal:
(EP-07)→ `DELETED` (irreversible pending BLK-02). Guards: EP-04/07 require re-auth; EP-03 requires unexpired/
unsuperseded/unconsumed token bound to account+email; EP-06 requires code in window for the provisioned secret.

**Journeys (one per job):**
- **J1 migrate email safely** — EP-02 to new → assert login still old + DB unchanged (INV-1) → consume token
  (EP-03) → assert swapped + token consumed → replay link → rejected (ORD-05). Outcome: identity moves only
  after a real round-trip; never dual-addressed/takeover-able.
- **J2 rotate password + evict** — 2 sessions → EP-04 valid → hash rotated, session B invalidated (PW-03);
  wrong current-pw → rejected (PW-02). Outcome: a compromise rotation actually locks out the attacker.
- **J3 enroll authenticator** — EP-05 → unconfirmed secret grants NO 2FA power (INV-3, TF-02) → EP-06 valid →
  active (TF-01) → replay code rejected (TF-03) → past-window rejected (TF-04). Outcome: factor gains power
  only on proof of possession; abandoned enrollment never locks the user out.
- **J4 erase account** (per-run sacrificial account) — EP-07 re-auth → terminal, sessions dead, pending token
  purged, provider reconciled (INV-4) → post-delete endpoints fail closed (DEL-03). Outcome: leaving is clean
  and total — no ghost tokens/sessions.

**Ordering / fault catalog (only outcome-changing entries):**
| ID | Kind | Setup → event | Oracle |
|---|---|---|---|
| ORD-01 | Supersede | EP-02→A, then EP-02→B before verifying A | only B's token live; A's stale link does NOT activate; one pending email |
| ORD-02 | Chain | enable-2FA then change-password | rotation still needs current-pw; does pw-change demand a 2FA challenge? → BLK-01 |
| ORD-03 | Undo/propagation | EP-02 (token outstanding) → EP-07 delete | delete purges token; later click = 404, never resurrects (INV-4/5) |
| ORD-04 | Commit-boundary fault | send times out AFTER provider accepts → client retries | at-most-one token + at-most-one delivered link (idempotency key); read provider log |
| ORD-05 | Replay | consume EP-03 token twice | 2nd rejected; swapped exactly once (INV-2/6) |
| ORD-06 | Expiry/stale | EP-02 → advance clock past expiry → EP-03 | rejected; email unchanged; fresh EP-02 required |
| ORD-07 | Race | verify ∥ delete | serialized to one terminal truth; never an activated email on a deleted account |
| ORD-08 | Concurrent conflict | two concurrent EP-04 | both re-check current-pw; valid-transition last-write-wins; no torn hash |
| ORD-09 | Reverse/precondition | EP-03 w/ no pending; EP-06 w/ no enrollment | clean rejection, empty-state safe, no partial write |

**Proving level per claim:** input validation → mock/unit; send shape + provider errors → pinned contract +
integration stub; token single-use / session invalidation / activation-gating / delete-terminality /
at-most-once send → real disposable instance with DB/provider read-back (a mock cannot prove these). No
sandbox → BLOCKED.

## Phase 4 — Synthesized plan

### Risk-gated extension — Contract-pinning: the email SEND boundary
Pin the provider's producer contract; fixtures must conform or fail loudly: request shape (recipient,
template, token/URL, **idempotency key** — load-bearing for ORD-04); response/error taxonomy (`202`+message-id;
`4xx invalid-recipient` must surface, not swallow; `429` retry-after; `5xx` retryable — a stub returning `200`
for an invalid recipient is a contract violation → test fails); delivery/bounce webhook (hard-bounce on the
pending email must not silently activate/strip); API version pinned (freshness check). EP-03 is OUR contract,
pinned by INV-2, not the provider's.

### CORE — merged coverage table (risk = impact×likelihood×reversibility×data-sensitivity×external-effects)
| id | claim / authority | proving level | risk | status | oracle |
|---|---|---|---|---|---|
| EM-01 | change-email mints pending + single-use token, triggers send | integration (pinned) | HIGH | planned | DB pending set, current unchanged; 1 send |
| EM-02 | new email NOT active pre-verify (INV-1) | real instance | HIGH | planned | login = OLD email |
| EM-03 | valid token activates once (INV-2/6) | real instance | HIGH | planned | current=new; token consumed |
| EM-04 | old email freed after swap (INV-5) | real instance | MED | planned | old now assignable |
| EM-05 | replay/expired/superseded/foreign token rejected (INV-2) | real instance | HIGH | planned | 2nd/expired/stale/cross-account → reject, no swap |
| EM-06 | change to taken email rejected at activation (INV-5) | real instance | HIGH | planned | collision at EP-03 → reject |
| PW-01 | correct current-pw + strong new rotates hash | real instance | HIGH | planned | hash changed; new pw authenticates |
| PW-02 | wrong current-pw / weak new rejected | mock + real | HIGH | planned | no rotation |
| PW-03 | password change invalidates OTHER sessions | real instance | HIGH | planned | session B 401 after rotation |
| TF-01 | confirmed TOTP activates 2FA | real instance | HIGH | planned | confirmed=true; challenge required |
| TF-02 | unconfirmed secret grants NO 2FA power (INV-3) | real instance | HIGH | planned | challenge not demanded pre-confirm |
| TF-03 | TOTP code single-use in window | real instance | HIGH | planned | reused code rejected |
| TF-04 | clock-skew window bounded (RFC6238) | real + clock | MED | planned | just-outside rejected, just-inside accepted |
| TF-05 | recovery codes issued once, hashed, never logged | real + log scan | HIGH | planned | not in logs; stored hashed |
| DEL-01 | re-auth-gated delete → terminal (INV-4) | real (sacrificial) | HIGH | planned | account terminal |
| DEL-02 | delete purges sessions+tokens, reconciles provider (INV-4) | real instance | HIGH | planned | no rows reference acct |
| DEL-03 | post-delete every endpoint fails closed (INV-4) | real instance | HIGH | planned | EP-01/03/04 → 401/404 |
| ORD-01…09 | ordering/fault catalog (by id) | mock→real per row | HIGH | planned | per catalog |
| QA-01 | no secret/PAN/PHI in logs | log scan | HIGH | planned | scan clean |
| QA-02 | each mutation emits a redacted audit event | real instance | MED | planned | audit rows present |
| QA-03 | send/password/TOTP attempts rate-limited | real instance | MED | planned | N+1 throttled |
| QA-04 | uniqueness doesn't enable account enumeration | integration | MED | planned | error identical taken vs free |

### Per-item recipe — TIERED (representative)
- **EM-03** (mutating/external) · precond: sacrificial ACTIVE acct + pending request + token from sandbox ·
  action: GET EP-03?token · oracle: DB current=new, token consumed · forbidden: no 2nd send, token not
  reusable, no plaintext-email logging beyond policy, no other field mutated · reload: EP-01 shows new, no
  pending · cleanup: tagged acct (marker+UUID), reconcile pending+token rows to none.
- **PW-03** (mutating/security) · precond: sessions A(initiator),B · action: EP-04 valid · oracle: hash
  rotated, B→401 · forbidden: B still authorized; pw value in logs · reload: B cannot refresh · cleanup:
  tagged acct; reset or discard.
- **DEL-01/02/03** (irreversible) · precond: **freshly provisioned per-run sacrificial account** existing
  ONLY to be destroyed · action: EP-07 re-auth · oracle: terminal; sessions dead; tokens purged; provider
  reconciled; endpoints fail closed · forbidden: any surviving row; any resurrecting link · reload: re-query
  → not found · cleanup: **compensation, NOT "delete what you created"** — account already gone; obligation
  flips to *assert no orphans remain*; if no provisioner → **BLOCKED (BLK-03)**, never run on a real account.
- **ORD-04** (commit-boundary/external) · precond: inject post-accept send timeout · action: EP-02, retry ·
  oracle: exactly one live token, at-most-one delivered (idempotency key) · forbidden: two tokens · reload:
  single pending row · cleanup: tagged acct; void the pending token.
- **EP-01 / GET settings** (read-only) · precond: authed session · action: GET · oracle: current state ·
  forbidden/reload/cleanup: **N/A — pure read** (justified).

### CORE — coverage ledger (gaps are BLOCKER rows, never silence)
| id | gap / blocker | disposition |
|---|---|---|
| BLK-01 | ORACLE GAP — does password change invalidate an outstanding email-verify token and/or require a fresh 2FA challenge? No spec decision. | BLOCKED-ORACLE-GAP · owner: product/security · resolve then convert to ORD-02 assertion |
| BLK-02 | ORACLE GAP — is delete HARD or SOFT (grace/undelete)? Determines whether DELETED is terminal or a reversible state. | BLOCKED-ORACLE-GAP · owner: product/legal (retention) · define policy; if soft, add undelete states |
| BLK-03 | ACCESS GAP — no verified disposable-account provisioner / sandbox inbox / DB read-back (deny-by-default). | BLOCKED-ACCESS · owner: test infra · stand up sacrificial provisioner + sandbox email + scoped read-back behind the preflight |
| BLK-04 | ACCESS GAP — no clock-control for token-expiry (ORD-06) and TOTP-window (TF-04). | BLOCKED-ACCESS · owner: test infra · injectable clock or short test TTLs |

### Final verdict
**Claims: proven 0 · planned 24 (+9 ordering/fault) · blocked 4 · excluded 4 (scoped, with rationale).**
**READY / NOT-READY: NOT-READY to certify** — this is a plan, nothing is proven; two blockers are ORACLE gaps
(BLK-01/02) whose answers change what correct behavior IS, and two are ACCESS gaps (BLK-03/04) blocking every
real-instance/boundary claim. Executable once a disposable instance + sandbox email + clock-control land and
product answers BLK-01/02.
**Residual risk if shipped as-is:** the highest-value cases (EM-05 replay, ORD-03/07 delete-vs-verify race,
ORD-04 send-after-commit idempotency, PW-03 session eviction) can ONLY be proven at the real boundary — an
untested ship leaves account-takeover and account-resurrection surfaces unverified. Exhaustiveness is bounded
to the declared scope + a deferred, unverified arsenal — not an absolute claim.

**Next step:** execute manually after the BLK-03/04 preflight is approved and BLK-01/02 answered; do not hand
to `/mission` (a build conductor, not a test runner).
