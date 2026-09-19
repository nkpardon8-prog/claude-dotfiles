# Quality Pass - UI Quality + Consistency Rubric (`/ui-audit --quality`)

This is the rubric for the **additive** `--quality` mode. It is a different question from the default
mode: the default mode asks *"is this element REAL or FAKE/DEAD?"*; this mode asks *"is this screen
**well made** - consistent, legible, calm, human?"*. An element can be perfectly REAL and still be a
quality finding (a real, live, correctly-wired phone number rendered as `+16505551234`).

**Report-only. Read-only navigation only.** The quality driver navigates, scrolls, and opens
`<details>` by DOM property. It never clicks actions, never types, never submits, never enters
credentials. Findings describe; they never fix.

**Claude-only pass.** Every finding in this mode needs pixel perception (Codex is text-only), so the
quality mode does **not** invoke Codex at all. There is no cross-family reconcile here.

---

## The two evidence families (both are required)

| Family | Source | What it proves |
|---|---|---|
| **DOM measurement** | `lib/quality-scan.js` injected per route -> `$OUT/quality/<slug>.<viewport>.scan.json`, merged into `$OUT/quality/census.json` | Numbers: boxes, px offsets, contrast ratios, counts, regex matches. Objective, cheap, complete. |
| **Vision** | Claude `Read`s `$OUT/screenshots/<slug>.<viewport>.png` (and `.tile-N.png` for tall pages) | Judgment: does it *look* wrong, is this label actually vague **in context**, is this action nonsensical **here**. |

### The corroboration rule (mirrors default-mode Invariant 5)

- A **measured** finding (a scan array entry) may be reported on the measurement alone, but it MUST
  carry the measured number in its evidence, and vision MUST NOT contradict it. If the screenshot
  shows the measurement is a false positive (a `kebab-enum` hit that is really a hyphenated English
  phrase; a 30px tap target that is a decorative inline link), **drop it** and count the drop.
- A **pixel-only** finding (nothing in the scan JSON fired) is reportable only at `severity: low`
  unless you can point at a *specific* scan field that supports it (a box, a gutter value, a density
  count). "Looks cramped" with no box is not a finding; "looks cramped, and `headers[2].flags`
  contains `crammed-against-neighbor` at `gapPx: 3`" is.
- Never invent a selector or a box. Copy them verbatim from the scan JSON. If you are reporting a
  vision-only finding with no scan entry, set `selector: null` and give the screenshot + pixel region.

### Severity scale (shared by every category)

| Severity | Meaning |
|---|---|
| `critical` | The screen is unusable or actively misleading for its user: an error/raw exception shown as content, a control unreachable at 390px, a value a person would act on wrongly. |
| `high` | A person will notice, misread, or stumble every time: raw machine text in a primary field, the same datum formatted two ways on ONE screen, a tap target under 24px, contrast under the WCAG minimum on body text. |
| `medium` | Noticeable sloppiness that costs trust but not comprehension: inconsistency across screens, uneven gutters, an off-center title, an undesigned empty state. |
| `low` | A polish item, or a pixel-only observation with no measured corroborant. |
| `info` | Recorded context, not a defect (census totals, "this screen has 4 button variants and that is intentional"). |

Severity is **not** the scan's `severity` field verbatim. The scan grades the *pattern*; you grade
the *instance in context*. A `snake-case` hit inside a developer-only debug panel is `low`; the same
hit in the client name field is `high`. Say so in the evidence when you move it.

---

## Scan output (what `quality-scan.js` gives you)

Top level of each `<slug>.<viewport>.scan.json` (`schema: "ui-audit.quality-scan/1"`):

`url`, `path`, `title`, `scannedAt`, `viewport{w,h,dpr,scrollX,scrollY}`, `document{scrollWidth,scrollHeight,lang}`,
`summary{...}`, then the arrays/objects the categories below name:
`machineText`, `formatCensus{phones,dates,times,money}`, `density`, `tapTargets`, `headers`, `gutters`,
`overflow`, `truncation`, `contrast`, `vagueLabels`, `unlabeledControls`, `iconCandidates`,
`duplicateActions`, `selfReferentialActions`, `buttonVariants`, `longCards`, `textWalls`, `stateText`,
`loadingIndicators`, `disclosures`, `truncatedLists`.

Every box is `{x, y, w, h}` in **page CSS px at that viewport** (scroll offsets already added), so it
maps onto the full-page PNG directly (multiply by `viewport.dpr` for PNG pixels). `truncatedLists` names
any array that hit the per-array cap (default 60) - if a key appears there, say "at least N" in the
report, never a bare count.

`census.json` (`mergeCensus`) adds the cross-screen view: `formats{phones,dates,times,money}` with
per-style `count`/`routes`/`samples`, `buttonVariants` (merged by style signature), `machineTextByKind`,
and `crossScreenInconsistencies` (pre-computed candidates: one `datum` rendered in 2+ styles across
routes, plus `button-variant` entries where one label has 2+ style signatures).

---

## Finding categories

Each category gives: **Definition** (checkable), **Signal** (the scan field to read), **Severity guide**,
**Evidence to cite**. The `category` value in `quality-findings.json` is the bolded id.

### 1. `machine-text` - raw machine text leaking into the UI

**Definition.** A string a *program* wrote that a *person* is now reading: an identifier, an enum
value, a serialization format, or a language-level nullish token, displayed where prose or a formatted
value belongs.

**Signal.** `machineText[]` - each entry is `{kind, severity, match, text, selector, box, inAttribute}`.
Kinds emitted: `uuid`, `iso-timestamp`, `iso-date`, `epoch-ms`, `e164-phone`, `js-nullish`
(`undefined`/`NaN`/`null`/`[object Object]`/`Invalid Date`), `template-leak` (`{{x}}`, `${x}`, `<% %>`),
`error-internals` (`TypeError`, stack frames, `ECONNREFUSED`, `status code 500`), `kv-leak`
(`seed:abc`, `kind:foo`), `screaming-snake` (`PROTECTED_STANDING_SLOT`), `snake-case`
(`protected_standing_slot`), `kebab-enum` (`protected-standing-slot`), `camel-case`, and
`file-path-or-url-internal` (`localhost:3000`, `/api/...`).

**Severity guide.**
- `critical` - `error-internals`, `template-leak`, or `js-nullish` in place of a real value a user acts on.
- `high` - `uuid`, `epoch-ms`, `e164-phone` where a person's phone number belongs, `screaming-snake` /
  `snake-case` / `kv-leak` in a label, status chip, or name field, `iso-timestamp` shown as a time.
- `medium` - `kebab-enum` and `iso-date` in secondary/metadata positions; internal paths in a tooltip.
- `low` - `camel-case`, or any hit in a place only an operator sees.

**Drop (false positive) when vision shows.** A hyphenated English phrase caught by `kebab-enum`
(`day-to-day`, `follow-up-call`), a deliberate code sample, an email/URL (already masked by the scan),
a brand spelled `iPhone`/`eBay` (already allow-listed), or a date field that is genuinely an ISO input
control. Count every drop in the run summary.

**Evidence to cite.** `kind`, the exact `match`, the enclosing `text`, `selector`, `box`, the route,
and what it should read instead (`+16505551234` -> `(650) 555-1234`; `protected-standing-slot` ->
`Protected standing slot`). The E.164 -> `(xxx) xxx-xxxx` rewrite is the default expectation for any
US 10-digit number displayed to a person.

### 2. `format-inconsistency` - one datum, two formats

**Definition.** The same *kind* of value (phone, date, time, money, person name) is rendered in more
than one style. **On one screen** (`formatCensus.<kind>.inconsistentOnThisScreen === true`) this is
worse than across screens; across screens is still a finding.

**Signal.** Per route: `formatCensus.{phones,dates,times,money}` -> `{styles: {<style>: {count, samples[]}}, distinctStyles, inconsistentOnThisScreen}`.
Cross-screen: `census.json` -> `formats` and `crossScreenInconsistencies[]` (`{datum, styles, routes, dominantStyle}`).

**Severity guide.**
- `high` - two styles for one datum **within a single screen**, or a phone rendered `e164` anywhere a
  `paren` phone also exists in the app.
- `medium` - two styles across screens (the `crossScreenInconsistencies` rows).
- `low` - a stylistic split that is arguably intentional (a compact table column vs a detail header).

**Legitimate coexistence (not a finding on its own).** Relative + absolute dates ("2h ago" in a list,
"March 3, 2026" on the detail) - `mergeCensus` already excludes the `relative` style from the
cross-screen flag. A currency code suffix in an invoice vs `$` elsewhere can be intentional; say so.

**Evidence to cite.** The datum, every style seen with its `count`, the `dominantStyle` (the one to
standardize on), 2-3 `samples` with `route`/`match`/`selector`/`box`, and the single recommended format.

### 3. `spacing-alignment` - spacing + alignment inconsistency

**Definition.** Measured geometry that contradicts the layout's own intent: a title that means to be
centered but is not, an element jammed against a neighbor, page gutters that differ block to block,
content running past the viewport, content clipped with no way to read it.

**Signal.**
- `headers[]` -> `{inkBox, containerBox, centerOffsetPx, leftGapPx, rightGapPx, textAlign, nearestInteractive{gapPx,dxPx,dyPx,label}, flags[]}`.
  Flags: `off-center` (centered intent, `|centerOffsetPx|` between 2 and 40), `crammed-against-neighbor`
  (`gapPx` < 8), `overlaps-neighbor` (`gapPx` 0), `touches-viewport-top`, `touches-viewport-edge`.
  The offset is measured on the text **ink** (a Range), not the block box, so a full-width `h1` is
  measured honestly.
- `gutters` -> `{left:{px:count}, right:{px:count}, distinctLeft, distinctRight}`.
- `overflow` -> `{horizontalScroll, documentScrollWidth, viewportWidth, offenders[]}` (offenders are the
  innermost elements past the viewport edge, with intentional horizontal scrollers and parked fixed
  drawers already excluded).
- `truncation[]` -> `{axis, ellipsis, lineClamp, hiddenPx, fullTextReachable}`.

**Severity guide.**
- `critical` - `overflow.horizontalScroll === true` at 390px (the page scrolls sideways on a phone), or
  `overlaps-neighbor` on a control a user must hit.
- `high` - a truncation entry with `ellipsis: false` and `fullTextReachable: false` (text silently cut
  with no tooltip, no expander, no link), or any `offenders[]` entry hiding an interactive element.
- `medium` - `off-center` titles, `crammed-against-neighbor`, `distinctLeft >= 4` (four or more distinct
  left gutters inside one screen is unevenness, not rhythm), `touches-viewport-edge`.
- `low` - a 2-4px off-center title, or a `lineClamp` truncation where the full text is reachable.

**Evidence to cite.** The measured number and the box: `centerOffsetPx: 17 (ink x=138..252, container
center=195)`, `nearestInteractive.gapPx: 3 ("Call")`, `gutters.left: {16: 22, 20: 3, 24: 9}`,
`overRightPx: 34`, `hiddenPx: 61`. Always name the viewport.

### 4. `density` - over-busy screen

**Definition.** Too much competing for attention in one viewport: interactive elements, text nodes,
buttons, or typographic variety past what a person can scan.

**Signal.** `density` -> `interactiveTotal`, `interactiveFirstViewport`, `buttonsTotal`,
`buttonsFirstViewport`, `linksTotal`, `inputsTotal`, `textNodesFirstViewport`, `wordsFirstViewport`,
`interactivePerViewport`, `pageHeightInViewports`, `distinctFontSizes`/`fontSizes`,
`distinctTextColors`, `distinctFontFamilies`/`fontFamilies`. Plus `textWalls[]` (`{words, approxLines, box}`,
only leaf blocks of 60+ words) and `duplicateActions[]` (one label repeated 2+ times outside nav).

**Thresholds** (mobile, 390x844 - these are the trip-wires, vision confirms):
- `interactiveFirstViewport > 20` or `buttonsFirstViewport > 8` -> crowded first screen.
- `interactivePerViewport > 18` -> sustained density down the page.
- `wordsFirstViewport > 180` -> a wall before the user has done anything.
- `distinctFontSizes > 8` or `distinctFontFamilies > 2` -> typographic noise (a design-system smell).
- Any `textWalls` entry with `approxLines > 12` and no heading structure inside it.

**Severity guide.** `high` when two or more thresholds trip on the same screen and vision confirms the
screen reads as a slab. `medium` for a single threshold. `low` for `distinctFontSizes` alone (a
utility-class stack inflates this honestly). `info` when the density is a dense-by-design data table
and vision shows it is well-organized.

**Evidence to cite.** The counts, which threshold tripped, and the vision read of *what* is competing
("11 buttons above the fold: 4 filter chips, 3 tab controls, 2 primary CTAs, 2 icon actions").

### 5. `text-for-symbol` - text where a symbol would do

**Definition.** A control whose entire visible label is a word with a universally-understood icon, in a
position where the word costs horizontal room that the screen does not have (toolbars, card action
rows, list-row affordances, tab bars).

**Signal.** `iconCandidates[]` -> `{selector, label, box}` - an interactive element whose visible text
matches the iconable set (`back`, `close`, `menu`, `search`, `delete`, `call`, `text`, `message`,
`email`, `next`, `previous`, `add`, `edit`, `share`, `copy`, `download`, `refresh`, `filter`, `sort`,
`expand`, `collapse`, `more`, ...) **and that contains no `svg`/`img`/icon element**.

**Severity guide.** `medium` when the control sits in a cramped row (corroborate with a `spacing-alignment`
flag or a `box` narrower than ~96px in a row of 3+ siblings). `low` otherwise. Never higher - this is a
polish call.

**Do not report** when the word IS the right affordance: a primary CTA (`Book a lesson`), a destructive
confirm (`Delete` in a dialog - a bare trash glyph there is worse), a nav tab label, or the only text in
an otherwise iconographic screen where the word is the accessibility anchor. An icon-only control still
needs an `aria-label`; say so in the suggested fix.

**Evidence to cite.** The label, its `box` width, its neighbors in the same row, and the proposed glyph.

### 6. `vague-label` - a label that does not show its current value

**Definition.** A control whose label names the *action class* but not the *thing or its state*, in a
place where the user needs the current value to decide: settings rows, filter chips, selectors,
disclosure headers. The test: **can the user tell what the setting is set to without tapping it?**

**Signal.** `vagueLabels[]` -> `{selector, label, box, showsCurrentValue: false}`. The scan matches the
vague set (`edit`, `change`, `set`, `select`, `choose`, `options`, `settings`, `more`, `manage`,
`update`, `configure`, `view`, `details`, `click here`, `submit`, `ok`, `go`, `open`, `continue`,
`learn more`, ...). `showsCurrentValue` is always `false` from the scan - **vision decides whether the
value is shown adjacently** (a right-aligned value, a subtitle, a chip). If it is, drop the finding.
Also read `unlabeledControls[]` (an interactive element with no accessible name at all) - that is a
**separate, higher** finding: `severity: high`, it is unusable with a screen reader and ambiguous with eyes.

**Severity guide.**
- `high` - `unlabeledControls` entries; a `Change`/`Edit` row in settings with no value anywhere near it.
- `medium` - a vague label with the value present but far away or low-contrast.
- `low` - `View`/`Details` on a card that is self-evidently about one entity.

**Evidence to cite.** The label, the `box`, what the vision read shows adjacent to it, and the rewrite:
`Edit` -> `Hourly rate - $100` (label carries the value), `Settings` -> `Notification settings`.

### 7. `state-design` - missing or undesigned empty / loading / error state

**Definition.** A region whose zero-, pending-, or failed-data presentation is bare text, or absent
entirely where one is needed.

**Signal.** `stateText[]` -> `{kind: 'empty'|'loading'|'error-generic', text, selector, box,
hasIconOrImage, hasAction, bareText}`. Plus `loadingIndicators{ariaBusy, skeletons, spinners}`.
Vision is load-bearing here: the scan can only find the *text*.

**Severity guide.**
- `critical` - an `error-generic` entry whose text is a raw exception (cross-reference `machineText`
  `error-internals` at the same `box`) or that offers no retry on a screen that cannot function without the data.
- `high` - an `error-generic` with `hasAction: false` (a dead end: the user is told it failed and given
  nothing to do).
- `medium` - an `empty` entry with `bareText: true` and `hasAction: false` ("No messages" alone, no
  illustration, no "Start a conversation"); a screen whose list is empty with **no** `stateText` entry
  at all (nothing rendered - check the screenshot for a blank region).
- `low` - an `empty` state with an action but no illustration; a `loading` state that is a bare word
  rather than a skeleton (`loadingIndicators.skeletons === 0` while a spinner/`Loading...` is present).

**Evidence to cite.** The kind, the literal text, `hasIconOrImage`/`hasAction`/`bareText`, the vision
description of the region, and the three-part fix (what it should say, what it should show, what the
user should be able to do next).

### 8. `redundant-action` - an action that makes no sense in this context

**Definition.** A control that offers what the user is already doing or already has: a `Text` action
inside the text thread, a `Call` button on the active-call screen, a `Clients` link on the clients page
(outside nav), two buttons with the same label doing the same thing in one view.

**Signal.** `selfReferentialActions[]` -> `{selector, label, box, matchedContextWord}` (the label equals
a word from the route path or the `h1`, with a small synonym map: inbox/thread -> text, message, sms;
calls -> call, phone). Nav, tablists, and footers are already excluded (an active nav item is
legitimately self-named). `duplicateActions[]` -> `{label, count, selectors[]}` for the repeated-control case.

**Vision decides.** The scan gives the candidate; only the screenshot shows whether the action is truly
redundant (a `Text` button in a thread header may legitimately mean "compose to a different number" -
if so, the finding becomes a `vague-label`: the label does not say that).

**Severity guide.** `medium` for a genuinely redundant action (clutter, and a moment of "wait, what
would that do?"). `high` when tapping it would plausibly do something *destructive or confusing*
(re-open a duplicate thread, start a second call). `low` for a duplicate label that is a real second
instance in a list.

**Evidence to cite.** The label, `matchedContextWord`, the `box`, the vision read of the surrounding
context, and whether the fix is removal or re-labeling.

### 9. `long-card` - long uncollapsed card

**Definition.** A card/row/panel taller than about three quarters of the viewport that presents itself
as one unit, with no disclosure to collapse it - so the list it lives in cannot be scanned.

**Signal.** `longCards[]` -> `{selector, box, heightInViewports, words, interactiveInside, hasDisclosure}`
(innermost only; page wrappers excluded).

**Severity guide.**
- `high` - `heightInViewports >= 1.5` with `hasDisclosure: false` **inside a list of siblings** (vision
  confirms there are more cards below): the user cannot see two items at once.
- `medium` - `heightInViewports` 0.75-1.5 with `hasDisclosure: false`.
- `low` - a long card that is the *only* content of a detail screen (it is the page, not a list item).

**Evidence to cite.** `heightInViewports`, `words`, `interactiveInside`, whether siblings exist, and the
suggested collapse point (what stays in the summary line).

### 10. `tap-target` - touch target below 44px

**Definition.** An interactive element whose hit box is under 44x44 CSS px at the mobile viewport
(Apple HIG / WCAG 2.5.5 AAA; 24px is the WCAG 2.5.8 AA floor).

**Signal.** `tapTargets[]` -> `{selector, label, tag, box, w, h, inlineTextLink, severityHint}`. A
checkbox/radio is already measured at its `<label>` size, and `inlineTextLink: true` marks the WCAG
2.5.8 inline-text exception (a link inside a sentence).

**Severity guide.** Take `severityHint` and adjust in context:
- `high` - `min(w,h) < 24` on a primary or destructive action.
- `medium` - under 44px but at least 24px, or under 24px on a secondary control.
- `low` - `inlineTextLink: true` (exempt by spec; report only as a cluster, once).
- Escalate to `critical` if two sub-44px targets are within 8px of each other (mis-tap risk) - check
  neighboring boxes for overlap in the `y` band.

**Evidence to cite.** `w x h`, the `label`, the `box`, and the neighbor distance when escalating. Report
per control, but collapse a row of identical icon buttons into one finding naming the count.

### 11. `contrast` - text contrast below WCAG AA

**Definition.** Rendered text whose computed foreground-on-effective-background ratio is below 4.5:1
(3:1 for large text: >=24px, or >=18.66px bold).

**Signal.** `contrast[]` -> `{selector, text, box, color, background, ratio, required, fontSize,
fontWeight, count, disabledLooking}`. Alpha is composited down the ancestor chain; elements over a
gradient or background image are **skipped** by the scan (`effectiveBg` returns null) - those are
vision-only calls at `low`.

**Severity guide.**
- `critical` - `ratio < 3` on body text a user must read to act.
- `high` - `ratio < required` on any non-decorative text, `count >= 5` (a systemic token, not a one-off).
- `medium` - a single near-miss (`ratio` within 0.5 of `required`).
- `low` - `disabledLooking: true` (disabled controls are exempt from WCAG 1.4.3 - report as info unless
  the element is not actually disabled), or a vision-only call over an image background.

**Evidence to cite.** `ratio` vs `required`, `color` on `background`, `fontSize`/`fontWeight`, the
`count` (how many nodes share the pair), and the minimum color change that clears the bar.

### 12. `variant-drift` - inconsistent component variants for one role

**Definition.** Two or more visual treatments for controls that play the **same role** (primary action,
secondary action, destructive, chip), within a screen or across screens. One role, one look.

**Signal.** Per route: `buttonVariants[]` -> `{signature, count, samples[{label, selector, box}]}` where
the signature is `background | color | radius | border | font-size | weight | height-bucket | text-transform`.
Cross-screen: `census.json` -> `buttonVariants` merged by signature with `routes[]`, and
`crossScreenInconsistencies[]` entries with `datum: 'button-variant'` (**the strongest machine signal**:
the *same label* carrying two different signatures). Supporting: `density.distinctFontSizes`,
`distinctTextColors`, `distinctFontFamilies`.

**Vision assigns the role.** The scan cannot tell a primary from a secondary; you can. Report only when
vision says two variants are doing the same job.

**Severity guide.**
- `high` - a `datum: 'button-variant'` cross-screen entry (one label, two looks - e.g. `Save` is a
  filled pill on `/settings` and a bordered rectangle on `/clients`).
- `medium` - 5+ distinct signatures on one screen, or two primaries with different radii/heights.
- `low` - a size-only difference (a compact variant in a dense row is legitimate).

**Evidence to cite.** The signatures side by side (name the differing properties, not the whole string),
the labels and routes, the sample boxes, and which variant should win (usually the highest `count`).

### 13. `cross-screen` - cross-screen inconsistency (the report's own section)

Not a separate detection so much as a **required output section**. Every finding drawn from
`census.json` (`crossScreenInconsistencies`, merged `formats`, merged `buttonVariants`, and
`machineTextByKind` where one `kind` appears on 3+ routes) is reported **once, at the app level**, with
every affected route listed - never repeated per screen. Categories that feed it: `format-inconsistency`,
`variant-drift`, `machine-text` (systemic kinds), `state-design` (different empty-state treatments for
the same kind of list).

Severity: take the max of the per-screen instances, then add one level if it spans 3+ routes (systemic
sloppiness costs more trust than a single slip).

---

## What this pass does NOT do

- It does not judge whether an element is wired to real data (that is default mode).
- It does not click actions, submit forms, or log in.
- It does not rewrite copy or CSS. Every finding carries a **suggested fix** as a sentence, not a patch.
- It does not fail the run on findings. The quality mode is advisory; there is no coverage gate and no
  `COMPLETE`/`INCOMPLETE` status. The only hard gate is the `quality-findings.json` schema.

## Per-screen ranking

Within each screen, rank findings by: severity first, then **measured magnitude** (a 34px overflow beats
a 6px one; `ratio 2.1` beats `ratio 4.3`), then breadth (`count` / how many nodes share the defect).
Report every `critical` and `high`. Cap `low` at the 5 most useful per screen and note the remainder as
a count, so the report stays readable.
