# Pass 3 — Vision Inspect (screenshot perception + DOM corroboration)

You are running the **vision-inspect** pass of `/ui-audit`. Read `../rubric.md`
first — it is the source of truth for element types, verdicts, and the precedence
rules. This pass looks at the actual rendered pixels and flags what code-tracing and
network logs cannot see: things that are visually broken, fake-looking, or
contradictory on screen.

## Who perceives what (model split)
- **True pixel perception is Claude's.** Claude `Read`s the screenshot files
  captured via `Page.captureScreenshot` and describes what is actually visible.
  Codex (`exec`, text-only) CANNOT see pixels.
- **Codex cross-checks the STRUCTURED vision evidence** — the DOM text, computed
  styles, bounding boxes, and measurable corroborants written to files — in the
  reconcile pass (user decision #3). So every pixel observation you make MUST be
  paired with the structured, DOM-measurable evidence that lets the other family
  re-judge it from files. A finding that lives ONLY in the pixels, with no DOM
  measurement, cannot be cross-validated and is capped at `UNVERIFIED`.

## What to look for (visual defects)
Inspect each element / region for:
- **Placeholder / lorem text** — "Lorem ipsum", "TODO", "placeholder", "Coming
  soon", dummy names, `{{ }}` template leftovers.
- **Broken / missing image** — a broken-image glyph, blank box where an image
  should be, an avatar that failed to load.
- **Clipping / overlap** — text cut off, elements overlapping, content spilling out
  of its container, unreadable due to collision.
- **Empty-state-that-should-have-content** — a panel/table/region that is clearly
  meant to hold data but renders empty (no rows, no chart, blank card).
- **Value mismatch vs other on-screen values** — a displayed number that
  contradicts another number visible on the same screen (a total that doesn't sum
  its parts, two stats that should agree but don't).
- **Obviously fake** — a value that is a suspicious round/placeholder constant, a
  chart that is visibly a flat/sample shape, UI that looks mocked.

## THE HARD RULE — pixel-only findings need a DOM-measurable corroborant
A finding that only the pixels support does NOT get to be `FAKE-OR-DEAD` (and cannot
claim cross-model validation, `rubric.md` §4d). To survive as anything stronger than
`UNVERIFIED`, EACH pixel-only finding type MUST be backed by its required
DOM-measurable corroborant:

| Pixel observation                         | REQUIRED DOM-measurable corroborant                          |
|-------------------------------------------|--------------------------------------------------------------|
| Overlap / collision                       | **bounding-box intersection** (two rects actually intersect) |
| Broken / missing image                    | **`naturalWidth === 0`** on the `<img>`                       |
| Empty-state (content expected, none shown)| **zero child text** in the region where content is expected   |
| Clipping / cut-off text                   | `scrollWidth/Height > clientWidth/Height` (overflow measured) |
| Value mismatch vs another on-screen value | both values read from the DOM + a normalized numeric compare  |
| Placeholder / lorem                       | the literal placeholder string present in DOM text            |

**No corroborant ⇒ downgrade the finding to `UNVERIFIED`.** Do not emit
`FAKE-OR-DEAD` for a purely-perceived defect. Capture the corroborant measurement
(via the driver's `Runtime.evaluate`) into the structured evidence so Codex can
re-judge it from the file.

## Precedence (from `rubric.md` §4)
- **`STATIC-BY-DESIGN` first (§4b):** a placeholder logo, an intentional empty
  starter state, or decorative chrome that is MEANT to look sparse is not "fake."
  If vision confirms structural intent and there is no intended data binding, it is
  `STATIC-BY-DESIGN` with an articulated justification — decided before any
  fake call.
- **Correlated-signal dedup (§4c):** your vision corroborant is exactly the kind of
  "independent second signal" that can promote a bare constant (static "no binding"
  + dynamic "no network-on-mount", which together are ONE signal) to `FAKE-OR-DEAD`.
  But ONLY when your corroborant is DOM-measurable and genuinely independent —
  e.g. a measured value-mismatch or a measured empty-state where content is
  expected. A vague "looks fake" is NOT that second signal.
- **Mechanism-dominant (§4a):** "looks off" with no measurable corroborant →
  `UNVERIFIED`, never `FAKE-OR-DEAD`.

## Output
Emit one **INTERMEDIATE per-element verdict record** per element (keyed by the ledger
`id`/`elementId`, `pass: "vision-inspect"`) — NOT the final `findings.json`. Phase 5
assembles these intermediate records into the schema-shaped `findings.json`; the schema
(now `additionalProperties: true`, requiring only `id` + `verdict`) carries the
intermediate fields (`corroborant`, `mechanism`, `justification`, …) through. For each
record include:
- `verdict` per `rubric.md` §3 (respecting the downgrade-to-`UNVERIFIED` rule above)
- `mechanism` — the visual defect type (e.g. `broken-image`, `overlap`,
  `empty-state`, `value-mismatch`, `placeholder`), or `null`
- `corroborant` — the DOM measurement that survives the finding (e.g.
  `"naturalWidth===0"`, `"bbox intersect A∩B"`, `"0 child text nodes"`,
  `"scrollWidth 480 > clientWidth 320"`), or `null` if none (then verdict must be
  `UNVERIFIED`)
- `screenshot` — the path to the screenshot file the observation came from
- `justification` — REQUIRED and non-empty when `verdict` is `STATIC-BY-DESIGN`
- `note` — anything the reconcile pass needs (including why a finding was
  downgraded to `UNVERIFIED` for lack of a corroborant)
