# Pass 1 — Static Trace (model-neutral)

You are running the **static-trace** pass of `/ui-audit`. This prompt is used
IDENTICALLY by both families: Codex (`codex exec -s read-only --cd <repo>`) and
Claude Agents. Read `../rubric.md` first — it is the source of truth for element
types, the proof-of-real bar, the four verdicts, and the precedence rules. This
pass never touches the browser; it reads code only.

## Goal
For each enumerated element in the batch, **follow the wire through the source code**
and emit the causal chain from the pixel to its ultimate backing (a real API/DB, a
cosmetic constant, or a suspicious gap). You are forming a HYPOTHESIS about reality
that the dynamic + vision passes will confirm or refute. Distrust the label; trace
the binding.

## What you receive
- The element's record from `ledger.json`: `elementId`, `type` (per `rubric.md` §1),
  `domPath`, human-readable label, `statePath`, and any `data-*` / test-id / text
  descriptor captured in-page.
- Read access to the repository (Codex: `-s read-only --cd <repo>`; Claude: Read/
  Grep/Glob). The evidence bundle dir lives INSIDE the repo so it is reachable.

## The trace you must produce (per element)
Follow this chain as far as the code allows, recording `file:line` at each hop:

1. **Element → component/prop.** Find the JSX/template node that renders this
   element (match on the label text, `data-*`, test-id, or structural path). Note
   which prop/variable supplies its displayed value or its click handler.
2. **Prop → hook/query.** Trace the value/handler back to its source hook or state.
3. **Hook/query → data call.** Trace to the actual network call.
4. **Data call → API route.** Identify the server route/handler the call targets.
5. **Route → service/DB.** Trace to the service function and ultimately the DB/ORM
   read or write (or the external system). This is the "ground" of the wire.

Stop when you reach the ground (DB/ORM/external call), a **hardcoded constant**
(the value is a literal in code with no fetch), or a **dead end** (a handler that
does nothing, a prop wired to a constant, an import that resolves to a stub).

### React + TanStack Query + axios + recharts hints
This is the primary stack (`rubric.md`, dentall). Look for:
- **Value/query:** `useQuery({ queryKey, queryFn })` / `useSuspenseQuery` in
  `client/src/lib/queries/*` (the canonical data-fetching layer). The `queryFn`
  usually calls an `api.*()` wrapper.
- **API wrapper:** `client/src/lib/api.ts` (or `lib/api/*`) — an axios instance
  (`api.get('/foo')`, `api.post(...)`). The path argument is your route key.
- **Route:** map the axios path to `server/src/routes/*` (Express). The handler
  validates → calls a service.
- **Service/DB:** `server/src/**/service*.ts` → Prisma (`prisma.model.findMany`,
  `.create`, `.update`) or an external client (OD write-back, WorkOS, etc.).
- **Chart:** a recharts `<LineChart>/<BarChart data={...}>` — trace `data`. If
  `data` is a `useQuery` result → real-candidate; if `data` is a literal `[{...}]`
  array in the file → **cosmetic (literal series)**, flag suspicious.
- **Handler:** `onClick`/`onSubmit` → mutation (`useMutation`) → `api.post/put/
  delete` → route. A handler that only sets local state or only fires a toast with
  NO network call → **cosmetic / dead** hypothesis.

### Generic fallback (non-React or unknown stack)
If the stack is not React/TanStack: trace by the same shape — rendered node →
bound variable → the function that populates it → the HTTP/data call → the
server handler → the data store. Use Grep/Glob on the label, the value string,
`fetch(`, `axios`, `useEffect`, route strings, and handler names. If you cannot
find ANY binding after a genuine search, that is itself the finding (constant /
cosmetic hypothesis), not a reason to stay silent.

## Hypothesis vocabulary (per element)
Classify each traced element as exactly one:
- **`real`** — a complete chain reaches a real fetch/mutation and a data store /
  external system. (Static trace can only make this a *candidate* — the dynamic
  pass proves it.)
- **`cosmetic`** — the value/handler resolves to a constant, literal array, or a
  handler with no network effect, AND this looks INTENDED (label, icon, sample).
  Maps toward `STATIC-BY-DESIGN` — but include the justification hint.
- **`suspicious`** — it CLAIMS a dynamic value/behavior but the trace finds no
  binding, a dead handler, a literal where a fetch is implied, or a mismatch
  between the displayed value and any nearby constant. Maps toward `FAKE-OR-DEAD`
  — but per `rubric.md` §4c this is ONE correlated signal; the dynamic/vision pass
  must supply the independent second signal before it converges to fake.

Also emit, when found, a **cross-source hint** the dynamic pass can use: the
canonical endpoint or DB model+field that independently holds this element's value
(`rubric.md` §2b prong 2). This is how the dynamic pass avoids re-fetching the
display endpoint.

## Precedence you must honor (from `rubric.md` §4)
- Decide `cosmetic` (static-by-design candidate) BEFORE calling anything
  `suspicious` — a constant with plausible design intent is not a fake (§4b).
- "No binding found" is a SINGLE signal; never assert `FAKE-OR-DEAD` from the
  static trace alone (§4c). Your job is the hypothesis + the file:line evidence and
  the cross-source hint; reconciliation converges it.

## OUTPUT CONTRACT — CRITICAL
Output **ONLY a JSON array** conforming to `../lib/findings.schema.json`. One array
element per audited element. **NO markdown code fence. NO prose before or after. NO
commentary.** The first character of your output must be `[` and the last `]`.

This is a hard machine contract: Phase 2 runs `jq` / `ajv-cli` on your output and
**degrades the entire batch to Claude on any parse failure** (this is why assumption
test A6 exists — Codex MUST emit parseable JSON-only). If you cannot complete an
element, still emit a well-formed object for it with verdict `UNVERIFIED` and a
`note` explaining why — never emit prose, never emit a partial/unfenced fragment.

Each object carries at minimum (see the schema for the authoritative field list):
- `elementId`, `type`, `domPath`, `label`, `statePath`
- `pass`: `"static-trace"`
- `hypothesis`: `"real" | "cosmetic" | "suspicious"`
- `verdict`: your provisional verdict from `rubric.md` §3 (this pass rarely emits a
  final `REAL`; use `UNVERIFIED` when only the dynamic pass can confirm)
- `mechanism`: the concrete reason (for `suspicious`/`cosmetic`), or `null`
- `traceChain`: an ordered array of `"file:line — what"` hops
- `crossSourceHint`: the independent endpoint/DB field to check, or `null`
- `justification`: REQUIRED and non-empty when `hypothesis` is `cosmetic` (the
  static-by-design articulation, `rubric.md` §3 / §4b)
- `note`: free text for anything the reconcile pass needs (or the UNVERIFIED reason)
