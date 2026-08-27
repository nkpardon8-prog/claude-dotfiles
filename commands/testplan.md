---
description: "Generate an exhaustive, production-realistic TEST PLAN for any target — discovers what it can test with, comprehends the program's role, scales coverage to the target's archetype and risk, and emits a risk-tiered plan with honest blockers. Plans; never executes."
argument-hint: "[feature / tab / target to test | blank = infer from context]"
allowed-tools: Read, Grep, Glob, Bash, Agent, Write, WebFetch, WebSearch
---

# /testplan — capability-discovery test-plan generator

You write the most exhaustive, production-realistic TEST PLAN you can for a given target, using whatever
testing resources actually exist in THIS environment — so no meaningful way to use the program is left
unproven. **You PLAN. You never execute the tests** (and you never mutate anything while planning). This is
a sibling of `/plan`: it fans out reader/enumerator agents and emits a plan artifact — it is NOT `/plan`'s
feature-implementation plan and NOT a test *runner*.

**Domain-agnostic.** The skill adapts to any target — a web app, an HTTP API, a CLI, a library, a
background worker, an event consumer, a data migration, a protocol. Examples below use a dental/OpenDental
app because it is a rich case; those are *illustrations*, never assumptions about the target.

## Guiding principle — CORE + risk-gated EXTENSIONS (do not gold-plate)

Every emitted plan carries a small fixed **CORE**. The heavier machinery — ordering/fault catalog, contract
pinning, the full per-item recipe, parallel enumeration — is emitted **only when the target's archetype,
risk, or surface warrants it**. A trivial read-only target collapses to the core; a money / PHI / permission
/ external-write / cross-boundary target gets the full treatment. Scale is *mechanical* (the collapse rules
below), not a vibe. Producing a huge plan for a small target is a failure, not thoroughness — a plan too
heavy to run proves nothing. For a genuinely trivial target (single-persona, read-only, no boundary), the
CORE itself compresses: the role model, the arsenal inventory, and the ledger may each collapse to a single
line rather than a table — keep the honesty, drop the ceremony.

## The two honesty rules (these govern every phase below)

**1. Never predict where a limit sits.** Not from the code, not from the arithmetic, not from
experience - not even when the answer looks obvious. A ceiling is `OBSERVED` (something broke in a
run someone actually made) or `UNKNOWN`. Nothing in between; an estimate NEVER appears in a result.
Aiming a probe is a decision, not a claim - decide, then write down only what happened. Say
`OBSERVED`, never "proven": one run under one configuration saw a break, which is not the system's
ceiling.

**2. "Nothing broke" is never an answer on its own.** Before reporting that anything survived, show
the setup could have broken it. If it could not, the finding is "our setup was too small to find
out" - never "it held up". A small environment yields small limits, and a survival claim from an
underpowered test is the most misleading sentence this skill can emit. If the setup is too small,
say so plainly and offer what it would take to fill it.

---

## Phase 0 — Resolve the target + classify its archetype

1. **Resolve the target** from the argument. If blank, infer the most likely target from recent context /
   the repo and **state the assumption explicitly**. Write a one-line scope statement AND an explicit
   **out-of-scope** line (nothing is silently omitted — a stated boundary).
2. **Classify the ARCHETYPE** — this selects the actors, surfaces, and lens set for everything downstream:
   UI app · HTTP/RPC API · CLI · library/SDK · background worker / job · event/queue consumer · data
   migration · protocol / wire format · infrastructure / config. A CLI has no "role-matrix" surface; a
   library has no "UI element" surface. Do not force a web-app shape onto a non-web target.

## Phase 1 — Comprehend + recon (READ-ONLY, deny-by-default)

**Comprehend the ROLE (what makes the E2E real).** Read the intent sources and write a short model:
- **What the program is FOR**, **WHO uses it** (personas), and the **real-world JOBS** each persona
  accomplishes with it. This role model drives the journeys in Phase 3 — testing is proving the software
  does its real job, not that each widget individually responds.

**Discover the AUTHORITY (the oracle — what "correct" means). Never invent an expected result.**
- Identify the sources of truth: product spec / intent / transcript, domain rules, external-system
  contracts, security policy, invariants. Record **precedence** (which source wins on conflict) and
  **freshness** (a stale doc is flagged). Keep **intended behavior separate from observed code behavior** —
  never let a current bug become the "expected result."
- When no exact expected value is knowable, anchor on an **invariant / property / independent
  read-back-reconciliation** BEFORE declaring a gap. Only when even that is impossible is it an **oracle
  gap** (a first-class blocked item — see Phase 4, never a guess).

**Scan HISTORY (cheap, high-value).** Look for past incidents, known bugs, support reports, and prior test
blind spots — production failures reveal surfaces that specs and code structure routinely miss. Each becomes
a regression case.

**Recon the ARSENAL + the SAFE BLAST RADIUS — ZERO-mutation, deny-by-default.**
- Inventory only the capabilities **relevant to the archetype**, and check each with **read-only / metadata
  checks ONLY**. Your mutation budget while planning is **ZERO**. Classify each capability:
  `verified (read-only)` · `assumed-available (probe deferred — mutating or costly)` · `unavailable` ·
  `unsafe-to-probe`.
- Any liveness proof that would change state, authenticate, or hit an external/real system is **deferred to
  an execution-time preflight** that requires explicit user approval AND a verified disposable target —
  never done during planning.
- **Blast radius is deny-by-default:** treat every target and capability as PRODUCTION / off-limits unless
  an explicit sandbox / test-instance / throwaway signal is found. A capability that *might* be prod is
  treated as prod. (Destroying a real environment while "just planning tests" is unacceptable.)
- A **partially-verified capability creates a conditional prerequisite / blocker** and can NEVER back a
  "proven" claim.

## Phase 2 — Enumerate the surface (archetype-derived, inline-first)

- **Derive the lens set AND count from Phase 0/1** — not a fixed number. **A small / narrow target gets ONE
  inline enumeration pass, no fan-out.** Spawn parallel `Agent` lenses ONLY for a genuinely broad surface.
- Candidate lenses (pick the ones the archetype actually has): interactive elements · entry points /
  commands / routes · data flows · external round-trips / integration seams · actor & permission model ·
  the workflow catalog · (archetype-applicable) quality attributes — see the note below.
- **If you fan out:** give every lens the SAME canonical context (authority hierarchy, architecture
  baseline, evidence standard, citation rules) and a concrete **ID SCHEME** — a per-slice prefix so results
  reconcile without collision (e.g. `UI-001`, `API-001`, `WF-001`, `RISK-001`, `LIM-001`, `BLK-001`). Run a
  **reconcile pass** that adjudicates conflicts and rejects unsupported claims. If a lens agent fails,
  retry / reassign serially — closure never depends on N agents being available.
- **Closure = traceability, not "nothing new appeared":** stop when every authoritative requirement /
  invariant, every discovered entry point / state / role / seam / risk, and every archetype-applicable
  quality attribute maps to a case OR an explicit ledger gap. State the bar you used.
- **Ask where every surface's ceiling is - ungated question, collapsing answer.** Give each surface
  one of: `HUNTABLE` (a real limit worth pushing - name the probe and the signal that would count as
  the break), `NOT-WORTH-HUNTING - <reason>` (dismissed, with a reason someone can argue with), or
  `UNREACHABLE - <no instrument here reaches it>`. **One line may answer a whole surface** - a
  read-only render deserves a sentence, not a table. Never claim a path structurally cannot have a
  limit; everything runs out of something eventually. What is forbidden is silence: a surface absent
  from this answer is a hole, not a pass.
- **Quality attributes are applicable-or-explicitly-skipped, never silently dropped:** security / privacy /
  abuse, accessibility, performance / capacity, resilience / recovery, compatibility, observability /
  audit, deploy / upgrade / rollback, data lifecycle. Include the ones the target actually has; for the
  rest write one line: "N/A — <reason>." Do NOT manufacture a mandatory matrix for a target that has no
  such surface.

## Phase 3 — Design the dynamic tests (gated to what is stateful)

**Author real user JOURNEYS — with a concrete method.** For each persona, take their top jobs-to-be-done
from the Phase-1 role model, then CHAIN the specific workflows that accomplish each job end-to-end — **one
journey per job**. Each journey step names: the case IDs it touches, the role, preconditions, the data, the
seams it crosses, the expected + forbidden effects, the evidence, and the final business outcome. Journeys
are a first-class deliverable — they are what prove the program does the job it exists for.

**Design the ordering / concurrency / fault matrix — ONLY for stateful / mutating / async / external
workflows.** Read-only or pure behavior does not traverse this. For the workflows that qualify, model the
workflow as a state change (states / transitions / guards / irreversible effects), then derive the
behavior-changing orderings and faults:
- **Orderings:** Chain (A feeds B) · Conflict (A,B same record) · Interrupt/resume · Repeat (idempotency) ·
  Reverse (precondition/empty-state) · Race (concurrent) · Recover (fail → other → retry) · Undo/inverse
  (full cleanup) · Stale-view (data changed under you) · Permission-shift (access changes mid-flow) ·
  Cross-feature propagation · Resume-across-session.
- **Commit-boundary faults:** timeout BEFORE vs AFTER the external commit · lost acknowledgement after a
  real mutation succeeded · duplicate delivery / retry · dependency down / partition / throttle / crash-
  restart.
- It is smart-exhaustive: **list only the orders/faults that can change THIS workflow's outcome** — silence
  on the rest is fine (no per-permutation exclusion ledger). Never brute-force N!.

**Push classes - what "the edge" means (four lines, never four sections):**
- **Slowdown** - how much (records, tenants, concurrent actors, payload size) before it is too slow.
- **Break / data loss** - keep going past slow: a record vanishes, a duplicate appears, a job stalls forever.
- **Hostile or bizarre input** - enormous text, unusual characters, empty vs null, negatives, precision,
  boundary dates and timezones, collections that are empty or enormous.
- **The ceiling of our own testing** - paths we cannot exercise here at all, named so blind spots are
  visible rather than assumed fine.

**Name what the instrument distorts before trusting any number - a break at the instrument's own
limit is NOT a break in the target.** A client pool cap throttling concurrency below the real
ceiling; a schema built by a path that silently drops constraints; a connection that never consults
the policy under test. State the instrument-of-record beside every number, and keep cheap-local and
realistic measurements SEPARATE.

**Choose the proving level per claim — a mock cannot stand in for a real effect.** A mock proves LOCAL
behavior only; a pinned contract proves SHAPE; an integration test proves BOUNDARY behavior; a real
cross-system claim requires observation in a **safe real instance** OR is marked **BLOCKED**. Pick the
lowest level that conclusively proves *that specific claim* — but a real-effect claim is never "proven" by a
mock.

## Phase 4 — Synthesize the plan + self-lint

### CORE (always emitted)
1. **Scope + out-of-scope.** Each exclusion states rationale + risk + who approved it (no silent
   scope-laundering — you cannot hide a hard surface under "out of scope" and still claim exhaustiveness).
2. **Role model** — personas + their jobs. (Single-persona target → state it once, in Phase 1 or here, not
   both — don't re-table it.)
3. **Arsenal + safety inventory** — each capability's class; the deny-by-default blast radius; deferred
   preflights.
4. **One merged coverage table.** Each row: `case-id · claim/authority · dimensions covered · proving level ·
   risk tier · status (planned / blocked / excluded) · oracle`. Risk tier from a stated rule
   (impact × likelihood × reversibility × data-sensitivity × external-side-effects).
5. **Ceilings answer** (Phase 2's three words; may collapse to a line). Each `HUNTABLE` names its
   probe, break signal, instrument-of-record, and `OBSERVED <what broke>` or `UNKNOWN`. No branch
   writes "held up fine": a break at the instrument's own limit is `UNKNOWN - the instrument broke
   first`; no break in an undersized setup is `UNKNOWN - too small to find out`.
6. **Coverage ledger tail** — covered / out-of-scope / known oracle+access gaps. **"No access / couldn't
   test" is a BLOCKER row, never silence.** Each gap/blocker names its disposition (test / fix / documented
   deferral).
7. **Final verdict** — counts of proven / planned / blocked / excluded claims, a blunt **READY / NOT-READY**
   line, and a residual-risk statement. Never write "proven" or "exhaustive" while blockers remain;
   exhaustiveness is bounded to the declared scope + inventory.

### Risk-gated extensions (emit ONLY when archetype/risk warrants)
- **Contract-pinning section** — for each REAL producer↔consumer boundary the target has (HTTP · queue /
  event · webhook · DB schema · file · CLI · third-party callback): pin the authoritative producer's
  contract (shape, errors, optionality, versioning) and require every fixture / stub to conform, so a
  drifted mock fails loudly. Skip entirely if the target has no such boundary.
- **Ordering + fault catalog** (Phase 3) — only if stateful/mutating/async/external workflows exist. Its
  entries live in the catalog; reference them in the merged coverage table by id (one summary row) rather
  than duplicating their detail.
- **Full per-item recipe** — for the risk-bearing cases (below).

### Per-item recipe — TIERED (required fields depend on the case)
- **Every case:** `id · precondition · action · expected-result/oracle · evidence`.
- **Mutating / external / stateful cases ALSO:** `forbidden-effects · still-correct-after-reload ·
  cleanup`. Cleanup is target-specific: tagged-records + reconcile where possible; **compensation** for
  irreversible effects (payments, messages, destructive migrations); or mark the case **BLOCKED** if
  neither is available. `N/A` is allowed for pure/read-only cases *with a one-line justification*. "Delete
  what you created" is not a universal teardown.
- **A case with no available oracle is a first-class `BLOCKED — ORACLE GAP` item** (name the authority
  owner + the missing decision + the resolution action). It is NOT rejected and NOT given an invented
  oracle.

### Self-lint before emitting (tier-aware, with teeth)
- Reject the plan only if an **executable** case is missing a field **required for its tier**. `BLOCKED-*`
  items are valid and expected — do not force them to fabricate fields.
- **Adequacy check:** each high-risk case names a plausible seeded fault + the red signal it would produce.
  A case that could not fail is not a test.
- A plan of present-but-empty headings must not pass.

### Output
Write to `tmp/testplans/<YYYY-MM-DD>-<slug>.md` (collision-safe slug). If that destination is absent /
read-only — OR the plan is very small / this is a validation dry-run — RETURN the full plan in your response
instead. Suggested next step: **execute the plan
manually** (an execute-skill is future work — do not hand a test plan to `/mission`, which is a build
conductor, not a test runner).

---

## If a limit is ever HUNTED (execution is not in this version - these bind it when it is)

Planning stays zero-mutation (Phase 1). Hunting deliberately causes failures, so bind it before
building it:
- **Hunt only where the whole environment is THROWN AWAY afterward, never cleaned up afterward.** No
  per-record deletes, no cleanup scripts - deleting records one at a time is how the wrong thing
  gets deleted. Destroy the whole disposable target instead.
- **Prove you can rebuild it before you may break it.** Emit the proof; halt if absent.
- **Never production, never the live datastore, never a customer-visible shared tenant** -
  prohibitions, not defaults. A ceiling reachable only there stays `UNREACHABLE`.
- **The one real external instance stays out of the blast zone, behind a stand-in** - admissible
  only if the stand-in's fidelity was confirmed and the plan says when. Assert the RESOLVED
  endpoint, never merely that a stand-in was started.
- **Read-only measurement of a live system is PERMITTED** (counts, distributions, timings) and is
  distinct from hunting.
- **Order:** read-only preflight -> choose probes -> show exactly those for approval -> rebuild
  proof -> probe. Rebuilding before approval destroys something before consent and leaves the
  approval unable to name what it will hammer.

<!-- CONTRACT-CORE-END -->

**Truncation note:** after a compaction this file re-injects head-truncated to its first 20,000
characters. Everything above this line - the honesty rules, all five phases, the hunting constraints
- is self-sufficient. Below are the worked examples that keep output concrete rather than a
checklist: if they are missing from this turn's context, Read this file from disk before emitting a
plan.

## Worked micro-examples (fill one per section — this is what keeps output concrete, not a checklist)

> Illustrative only (a dental example); adapt the shape to the actual target.

- **Coverage-table row:** `AP-004 · "Approving a note writes provider-of-record + Complete to the record
  store (authority: product spec §Notes)" · dims: actor=doctor, data=finalized-note · proving level:
  real-instance (write-back) · risk: HIGH (clinical, external write, irreversible-ish) · status: planned ·
  oracle: read the record back from the store and assert ProvNum + status.`
- **Journey (one job, end-to-end):** *front-desk operator checks a patient in → fixes their insurance →
  eligibility check runs → the claim flows to the external record system → the schedule reflects it.*
  Business outcome: the patient is ready to be seen and the claim is queued. Steps cite `CI-001, INS-002,
  ELIG-001, CLAIM-003, SCHED-002`; forbidden effect: no duplicate claim.
- **Ordering+fault entry:** `CLAIM-003 Recover — submit claim, external system times out AFTER the write
  commits, operator retries → assert exactly ONE claim exists (idempotency key), not two.`
- **Per-item recipe (mutating):** `id CLAIM-003 · precondition: checked-in patient w/ valid coverage ·
  action: submit claim · expected: one claim row, status=queued · forbidden: no duplicate, no PHI in logs ·
  still-correct-after-reload: reopen → claim still queued · evidence: record-store read-back + log scan ·
  cleanup: tagged test-patient, reconcile + delete the queued claim (compensation) or mark BLOCKED if the
  external system has no delete.`
- **Blocked-oracle example:** `BLK-002 — "correct eligibility co-pay for plan X" has no authoritative
  expected value available (no test fixture from the payer). BLOCKED-ORACLE-GAP · owner: product ·
  resolution: obtain a payer test fixture or define the invariant (co-pay ≤ plan max).`

## The proven shape to generalize (distilled — no dependency on any one project)

Great real-world test plans (the capstone gates elite teams actually run) share this shape, and you should
reproduce it generically: **build to intent** (a source-cited inventory of every ask: `ask · source ·
status · note`); **critique every element** through its real states, not just "does it click"; **prove every
external-touching control individually against a real instance, or state "none" explicitly** (never
silence); a **disposition rule** (every finding lands durably — a test, a fix, or a documented deferral);
**scale to risk, don't gold-plate**; and a **machine-checkable completeness floor** so a skipped pass leaves
a visible hole, not a silent one. "No access is a blocker, never a skip."

## Deferred / noted-for-later (deliberately NOT in this version)

Recorded so the omissions read as intentional, not oversights: **the HUNT itself** (running the
probes - deferred until a target has a real instrument, since with none every ceiling honestly
returns `UNKNOWN`) · change-impact / diff-targeted depth · a ship / no-ship gate wired to CI ·
incident-to-regression as a formal step (partly absorbed as the Phase-1 history scan) · operability /
audit-signal assertions · a safe-synthetic test-data + tagging strategy · rollback / mixed-version /
migration safety. Add these only when a concrete target makes one load-bearing.
