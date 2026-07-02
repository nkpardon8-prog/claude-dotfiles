# Pass 4 — Reconcile (cross-family validation + merge)

You are running the **reconcile** pass of `/ui-audit`. Read `../rubric.md` first —
it is the source of truth for the four verdicts, the `MODELS-DISAGREE` bucket, and
the precedence + correlated-signal rules that this pass ENFORCES at merge time. This
pass takes the findings from all three passes (static-trace, dynamic-exercise,
vision-inspect), authored ~50/50 by Codex and Claude, and reconciles them into one
verdict set with false positives dropped and disagreements surfaced.

## The cross-model contract (never same-family self-review)
Validation is ALWAYS cross-family (god-review failure-mode #6 — a family must not
bless its own work):
- **Claude validates Codex-authored findings.**
- **Codex validates Claude-authored findings.**

And it covers **ALL THREE passes**, not just the code-reading pass (user decision
#3):
- Codex independently reads the **dynamic evidence bundles** (network-on-mount
  logs, request/response lines, cross-source values, effect-persistence proofs) from
  files and issues its own verdict on them.
- Codex independently reads the **structured vision evidence** (DOM text, computed
  styles, bounding boxes, the DOM-measurable corroborants) from files and re-judges
  those findings. (Codex cannot see pixels — it judges the structured evidence the
  vision pass wrote, `vision-inspect.md`.)
- Claude validates the Codex-authored static + evidence-judgment findings.

This gives a genuine SECOND-MODEL opinion on the dynamic and vision deltas, not only
on code-reading.

## Be RUTHLESS about false positives
The whole value of this skill collapses if it cries wolf. For each finding you
validate, ask: **is the cited mechanism actually proven, or is this "looks off"
dressed up?** Emit exactly one label per finding:
- **`CONFIRMED`** — the mechanism is real and the evidence supports the verdict.
- **`FALSE_POSITIVE`** — the mechanism does not hold up (formatting difference
  mistaken for a value mismatch, a control that DID fire a request, a constant that
  is legitimately static-by-design, a pixel finding with no real corroborant, a
  re-fetch of the display endpoint masquerading as cross-source). **Drop it, and
  COUNT it** — the dropped-FP count is reported in `AUDIT.md`, never silently
  discarded.
- **`UNCERTAIN`** — the evidence is genuinely insufficient either way → the merged
  finding becomes `UNVERIFIED`.

## Enforce the precedence + correlated-signal rules (from `rubric.md` §4) at merge
These are the governor. Apply them BEFORE finalizing any verdict:
- **`STATIC-BY-DESIGN` before convergence-to-FAKE (§4b):** if the element has no
  *intended* data binding and vision confirms structural intent, it is
  `STATIC-BY-DESIGN` (with an articulated justification) — even if two passes both
  said "no binding / no network." Do NOT let those two roll up into `FAKE-OR-DEAD`.
- **Correlated-signal dedup (§4c):** static "no data binding" + dynamic "no
  network-on-mount" are ONE correlated signal, not two. A bare constant needs an
  ADDITIONAL INDEPENDENT signal — a cross-source value mismatch OR a DOM-measurable
  vision corroborant — to be promoted to `FAKE-OR-DEAD`. If that independent second
  signal is absent, the reconciled verdict is `STATIC-BY-DESIGN` or `UNVERIFIED`,
  never `FAKE-OR-DEAD`.
- **Mechanism-dominant (§4a):** any surviving `FAKE-OR-DEAD` MUST cite a concrete
  mechanism. Strip the fake verdict from anything that cannot → downgrade to
  `UNVERIFIED`.
- **Pixel-only needs a corroborant (§4d):** a vision finding with no DOM-measurable
  corroborant is capped at `UNVERIFIED` and cannot claim cross-model validation.

## Merge mechanics
- **Merge by hash** `sha256(elementId + verdict-class)`. Findings across passes and
  families that share the same element AND the same verdict-class collapse into one
  merged finding.
- **Cross-model agreement ⇒ confidence +1 and a `(both)` tag.** When both families
  independently reach the same verdict-class for an element, bump its confidence and
  mark it `(both)`.
- **Drop `FALSE_POSITIVE`s, keep the count.** The count of dropped false positives
  is a reported metric.

## MODELS-DISAGREE — surface, never average
When the two families reach CONFLICTING verdict-classes for the same element and the
cross-validation above does not resolve the conflict to a single `CONFIRMED`
verdict, the element goes into the **`MODELS-DISAGREE`** bucket:
- It is surfaced FIRST-CLASS in `AUDIT.md` (ordered right after `FAKE-OR-DEAD`), with
  BOTH families' verdicts and their cited evidence shown side by side.
- **Never average** the two into a middle verdict, and never silently pick one. A
  human decides. (`rubric.md` §3 / §4e.)

## Output
Emit the reconciled finding set conforming to `../lib/findings.schema.json`
(`pass: "reconcile"`), where each finding carries:
- `verdict` — the final reconciled verdict per `rubric.md` §3, or the
  `MODELS-DISAGREE` bucket marker
- `validation` — `CONFIRMED` / `FALSE_POSITIVE` / `UNCERTAIN`
- `confidence` — with the `(both)` tag when cross-model agreement held
- `mechanism`, `justification` (required for `STATIC-BY-DESIGN`), `traceChain`,
  `corroborant`, `crossSourceHint`, `screenshot` — carried through from the
  contributing passes as applicable
- for `MODELS-DISAGREE`: both families' verdicts + evidence retained, not collapsed
- `note` — including the reason for any drop/downgrade

Also report the aggregate: total elements, per-verdict counts, dropped-FP count,
`MODELS-DISAGREE` count. Report-only — reconcile never fixes the app.
