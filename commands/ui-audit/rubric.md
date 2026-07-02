# `/ui-audit` — Reality Rubric (source of truth for all three passes)

This file is the shared oracle. Every pass (`static-trace`, `dynamic-exercise`,
`vision-inspect`) and the `reconcile` merge read their definitions from here.
It is model-neutral: Codex (`exec`, text-only, reads evidence bundles from files)
and Claude (Agents, plus true pixel perception) apply the SAME bar and the SAME
verdict vocabulary. If a pass prompt and this file disagree, this file wins.

The mission is a **fail-closed reality audit** of one rendered tab/screen: for
every element, decide whether what the pixels claim is backed by a real
mechanism, or whether it is a constant, a corpse, or a lie. "Looks done" is a
hypothesis about behavior, never evidence of it — we prove reality by tracing the
wire, not by trusting the label.

---

## 1. Element taxonomy

Every visible element is classified into exactly one type. The type selects which
proof-of-real bar applies. `classify()` (in `lib/enumerate.js`) assigns the type;
this table defines what each means and which bar governs it.

| Type       | What it is                                              | Bar family      |
|------------|---------------------------------------------------------|-----------------|
| `text`     | Free text / copy / headings                             | data OR static  |
| `stat`     | A single displayed metric / KPI / number                | **data**        |
| `chart`    | A plotted series (recharts wrapper/surface, or canvas)  | **data (chart)**|
| `table`    | Rows/cells of tabular data                              | **data**        |
| `button`   | Clickable control that acts (submit/save/toggle/open)   | **interactive** |
| `link`     | Navigational anchor / route change                      | **interactive** |
| `input`    | Text field / select / checkbox / radio / slider         | **interactive** |
| `badge`    | Status pill / count chip / label with a value           | **data**        |
| `image`    | `<img>` / background image / avatar                      | **asset**       |
| `icon`     | Small decorative `<svg>` (lucide-react etc.)            | **static**      |
| `progress` | Progress bar / spinner / meter with a value             | **data**        |
| `region`   | Structural container / layout / background / empty slot | **structural**  |

Classification notes (mirror `enumerate.js`, do not re-derive):
- A `chart` is an element under `.recharts-wrapper` / `.recharts-surface`, or a
  `<canvas>`. A **bare small `<svg>` is an `icon`, not a chart** (lucide-react
  renders icons as `<svg>`). Do not flag icons on the data bar.
- `region` covers backgrounds, wrappers, and empty slots. A region is a first-class
  record (full coverage) but is judged structurally, not on the data bar — its only
  reality question is "should this container hold content, and is it empty when it
  should not be?" (see `vision-inspect.md`, empty-state).

---

## 2. Proof-of-real bar, per bar family

A verdict of `REAL` requires MEETING the bar for the element's family. Falling
short does not automatically mean `FAKE-OR-DEAD` — see §4 precedence.

### 2a. Interactive (`button`, `link`, `input`)
**Bar:** an action fires a real request that succeeds AND whose effect persists.

- The interaction must produce a network request (non-GET for a mutation, or a
  route/data fetch for navigation) that returns **2xx**, AND
- the **effect must persist after an INDEPENDENT REFETCH** — re-read the affected
  state from a fresh load / a separate query, and confirm the change is still there.

A **toast, a spinner that clears, or any optimistic-UI cue is NOT proof.** Optimistic
UI shows success before (or without) the server confirming; a toast can fire on a
handler that never hit the network. The proof is: request → 2xx → effect survives an
independent refetch. (This is why the dynamic pass uses `stableForMs` re-checks and
an explicit post-action refetch, not just the first success cue.)

- A control that fires **no request at all** on interaction → dead handler →
  `FAKE-OR-DEAD` (mechanism: dead click).
- A control that fires a request that **4xx/5xx**es (and is not an expected,
  handled validation path) → `FAKE-OR-DEAD`.
- A navigation `link` is `REAL` when it produces the route change / data load it
  claims; a link that changes nothing → `FAKE-OR-DEAD`.
- Under `--read-only`, mutating controls are NOT clicked; they are verdicted from
  static + vision only and, absent a mechanism failure, resolve to `UNVERIFIED`
  (not `REAL` — we did not prove the effect) or `STATIC-BY-DESIGN` where justified.

### 2b. Data (`stat`, `table`, `badge`, `progress`, and `text` that shows a value)
**Bar:** two independent prongs — PROVENANCE and CROSS-SOURCE — both must hold.

1. **Provenance (network-on-mount present).** When the tab mounts, a backing
   request must have fetched the data this element displays. Capture the
   network-on-mount from the LIVE network log. A data element that shows a value
   but fired **NO backing request on mount** is client-side static → the canonical
   hardcoded-value catch (the hardcoded-`$85` case). Missing provenance is a strong
   suspect signal, resolved per §4.
2. **Cross-source match.** Compare the displayed value against a **DIFFERENT source
   than the display path** — a DB/Prisma read or a canonical endpoint — **never by
   re-fetching the same display endpoint** (re-fetching cannot catch a stubbed,
   seeded, or constant-returning endpoint; it just re-confirms the stub). The
   displayed value must field-map to the independent source's value.

- **Normalize before compare.** `"$85"` vs `85.0`, `"1,234"` vs `1234`, trimmed
  whitespace, case, date formats — normalize both sides first so formatting
  differences never produce a false `FAKE`.
- Where **no independent source exists** to cross-check, do NOT declare `REAL` on
  provenance alone — record `UNVERIFIED` with a note. Provenance proves a fetch
  happened; only cross-source proves the value is honest.
- Displayed value **≠** cross-source value (after normalization) → mechanism
  (displayed ≠ canonical) → `FAKE-OR-DEAD`.

### 2c. Chart (`chart`)
**Bar:** the plotted series comes from a real endpoint, not a literal array.

- The series data must originate from a network-fetched source (provenance as in
  §2b), NOT from a hardcoded literal array baked into the component. A chart whose
  points are a constant in-code array is `FAKE-OR-DEAD` (or `STATIC-BY-DESIGN` only
  if it is an explicitly-labelled illustrative/sample chart — justified per §4).
- Where feasible, cross-source the series' shape/endpoints against the canonical
  source (§2b prong 2). Where not, provenance-present + a real endpoint is the
  minimum, and absence of an independent check is noted (do not over-claim).

### 2d. Asset (`image`)
**Bar:** the asset actually loads. Broken/missing image ⇒ `naturalWidth === 0`
(DOM-measurable) ⇒ `FAKE-OR-DEAD`. A placeholder/lorem image that is intentional
scaffolding is `STATIC-BY-DESIGN` only with justification.

### 2e. Static (`icon`, decorative `text`, `region` chrome)
**Bar:** these have no *intended* data binding. Their honest verdict is
`STATIC-BY-DESIGN` — but only with an articulated justification (§4). An icon or a
constant label is not "fake"; it was never claiming to be dynamic.

### 2f. Structural (`region`)
Judged on the empty-state question only (§1 note, and `vision-inspect.md`): a
container that is *meant* to hold content but renders zero child text where content
is expected ⇒ suspect ⇒ resolved per §4 with a DOM corroborant.

---

## 3. The verdict vocabulary

Every element gets exactly ONE of four verdicts. A fifth label, `MODELS-DISAGREE`,
is a reconciliation BUCKET, not a per-element intrinsic verdict.

- **`REAL`** — the element MEETS its proof-of-real bar (§2). Interactive: proven
  request→2xx→persisted effect. Data: provenance present AND cross-source match.
  Chart: series from a real endpoint. This is an evidenced pass, never a default.

- **`STATIC-BY-DESIGN`** — the element is a constant / label / decoration / icon /
  intentional scaffold with **no *intended* data binding**, and this is correct.
  **Requires an articulated justification** — name WHY it has no binding and what
  structural intent vision confirms (e.g. "app title in header; static by design;
  vision confirms it is chrome, not a data slot"). **Never a silent pass.** This is
  the escape hatch that stops logos, nav labels, and icons from being flagged.

- **`FAKE-OR-DEAD`** — the element **claims a behavior/value it does not back**.
  MUST cite a concrete mechanism failure: dead click (no request), request that
  errors, no network-on-mount for a data element, displayed ≠ cross-source value,
  placeholder/lorem/broken image (`naturalWidth===0`), or a chart from a literal
  array. "Looks off" alone is NEVER `FAKE-OR-DEAD`.

- **`UNVERIFIED`** — we could not prove OR disprove reality. No independent
  cross-source existed; the element was unreachable this run; a state hit the
  `--max-enum-passes` cap; a `--read-only` mutating control could not be exercised;
  or a pixel-only finding lacked a DOM corroborant. Bounded incompleteness is
  surfaced as `UNVERIFIED`, **never as silence and never as a false `REAL`**.

- **`MODELS-DISAGREE`** (reconcile bucket) — the two model families reached
  conflicting verdict-classes for the same element and reconciliation did not
  resolve it. Surfaced first-class for human eyes, **never averaged** into a middle
  verdict. Defined operationally in `reconcile.md`.

---

## 4. Precedence & correlated-signal rules (the false-positive governor)

These rules are the hard part — they stop the audit from crying wolf. All three
passes and `reconcile.md` apply them identically.

### 4a. Mechanism-dominant
`FAKE-OR-DEAD` MUST cite a concrete mechanism failure (§3). A subjective "looks
off" with no mechanism → `UNVERIFIED`, never `FAKE-OR-DEAD`.

### 4b. STATIC-BY-DESIGN is evaluated BEFORE convergence-to-FAKE
Before concluding an element is `FAKE-OR-DEAD` for lacking a data binding, first
ask: **does it have an *intended* binding at all?** A constant/label/icon/decorative
region with no intended binding, where vision confirms structural intent, is
`STATIC-BY-DESIGN` — and this check runs FIRST. Only elements that DO claim a
dynamic value/behavior are eligible for `FAKE-OR-DEAD`. This ordering is what keeps
logos and nav labels out of the fake bucket.

### 4c. Correlated-signal dedup (the two-signals rule for constants)
Static-trace "no data binding found" and dynamic "no network-on-mount" are the
**SAME underlying observation** — both restate "this element is a constant." They
are **ONE correlated signal, not two independent corroborating signals.** Therefore
a bare constant does NOT convergence-promote to `FAKE-OR-DEAD` on those two alone.

To move a constant from `STATIC-BY-DESIGN` to `FAKE-OR-DEAD`, you need an
**ADDITIONAL, INDEPENDENT signal**, one of:
- a **cross-source value mismatch** (displayed value ≠ canonical/DB value, §2b), or
- a **DOM-measurable vision corroborant** that the constant is wrong in context
  (e.g. it visibly contradicts another on-screen value, and the contradiction is
  DOM-measurable, not merely perceived).

Absent that independent second signal, a constant with a plausible design intent
resolves to `STATIC-BY-DESIGN` (with justification), not `FAKE-OR-DEAD`.

### 4d. Pixel-only findings need a DOM-measurable corroborant
A finding that only one model can PERCEIVE (true pixel vision, Claude) does not get
to claim cross-model validation. To survive as anything stronger than `UNVERIFIED`,
a pixel-only finding needs a DOM-measurable corroborant (overlap ⇒ bounding-box
intersection; broken image ⇒ `naturalWidth===0`; empty-state ⇒ zero child text
where content expected). No corroborant ⇒ downgrade to `UNVERIFIED`. (Full table in
`vision-inspect.md`.)

### 4e. Disagreement is first-class
When the two families produce conflicting verdict-classes and reconciliation cannot
resolve it, the element goes to the `MODELS-DISAGREE` bucket, surfaced for a human.
Never average two verdicts into a third.

---

## 5. Confidence & merge (summary; full mechanics in `reconcile.md`)
- Findings merge by hash `sha256(elementId + verdict-class)`.
- Cross-model agreement on a verdict-class ⇒ confidence **+1** and a `(both)` tag.
- Cross-family validation labels each finding `CONFIRMED` / `FALSE_POSITIVE` /
  `UNCERTAIN`; `FALSE_POSITIVE`s are dropped and **counted** (the count is reported,
  never silently discarded).

---

## 6. Report ordering (so real fakes are not buried)
`AUDIT.md` orders sections: **`FAKE-OR-DEAD` → `MODELS-DISAGREE` → `UNVERIFIED` →
`STATIC-BY-DESIGN` justifications → `REAL` summary → coverage manifest +
`traversal-actions.log` summary.** The header reflects `COMPLETE` / `INCOMPLETE`
from `ledger-assert.sh`'s exit code. Report-only — the skill never fixes.
