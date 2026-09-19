# Changelog — /ui-audit

## rev 4 - 2026-09-19

**Additive `--quality` mode: UI quality + consistency auditing.** Default (reality) mode behavior is
unchanged; the only edits to it are the `argument-hint` line and a new MODE DISPATCH table at the top
of `ui-audit.md`.

- New mode: `/ui-audit --quality --base=<url> [--routes=a,b,c] [--max-routes=N] [--desktop] [--expand] [--out=]`.
  Asks a different question from reality mode - not "is this element real?" but "is this screen well
  made - consistent, legible, calm, human?". A perfectly REAL element can still be a quality finding.
- **Claude-only.** Codex is never invoked in this mode: every category needs pixel perception and
  Codex is text-only. No 50/50 split, no cross-family reconcile.
- **Read-only navigation only.** The driver navigates, scrolls, and opens `<details>` by DOM property.
  It never clicks actions, never types, never submits, never enters credentials. `--expand` (clicking
  collapsed disclosure toggles) runs only with the wire-level read-only guard installed. One new tab,
  closed on exit; existing tabs are never touched.
- **Advisory, not gated.** No coverage ledger and no `COMPLETE`/`INCOMPLETE` status - the only hard
  gate is the `quality-findings.json` schema.
- New `passes/quality.md`: 13 finding categories, each with a checkable definition, the scan field
  that signals it, a severity guide, the false-positive drops, and the evidence to cite -
  `machine-text` (snake_case, kebab enums like `protected-standing-slot`, `seed:` kv leaks, ISO
  timestamps, E.164 phones where `(xxx) xxx-xxxx` belongs, UUIDs, `null`/`undefined`/`NaN`, template
  leaks, raw error internals), `format-inconsistency` (one datum, two formats - within a screen and
  across screens), `spacing-alignment` (ink-measured off-center titles, crammed headers, uneven
  gutters, overflow, silent truncation), `density` (interactive + text-node density per viewport,
  button counts, text walls, typographic variety), `text-for-symbol`, `vague-label` (a label that
  does not show its current value; unlabeled controls rank higher), `state-design` (missing or
  undesigned empty/loading/error states), `redundant-action` (a `Text` action inside the text
  thread), `long-card`, `tap-target` (<44px, with the WCAG 2.5.8 inline exception), `contrast`, 
  `variant-drift` (two looks for one role), and `cross-screen`.
- New `lib/quality-drive.mjs` + `lib/quality-scan.js`: mobile-first (390x844 @2x, touch - the targets
  are PWAs) raw-CDP driver and in-page DOM scan. Per route: bounded scroll pass, `<details>` open,
  scan injection, full-page screenshot plus viewport tiles, then a merged cross-screen format +
  button-variant census with pre-computed inconsistency candidates.
- New `lib/quality-findings.schema.json` (`ui-audit.quality-findings/1`), gated by the existing
  `validate-findings.sh` with the schema passed as the 2nd arg.
- Two driver fixes found by running it: the scroll pass no longer throws when `documentElement` is
  momentarily null during a client-side route swap (it used to lose the whole route), and **tiles are
  now captured by scrolling to the offset and shooting the real viewport** instead of
  `captureBeyondViewport` - a site with scroll-reveal animations painted everything below the fold at
  opacity 0, silently blinding the vision half of the pass.

## rev 3 — 2026-07-02

Initial release.

- Report-only, per-tab UI reality audit: enumerates the entire rendered surface of ONE tab across every reachable sub-state into a fail-closed coverage ledger; strict per-element verdicts (`REAL` / `STATIC-BY-DESIGN` / `FAKE-OR-DEAD` / `UNVERIFIED` + a `MODELS-DISAGREE` bucket) proven through three reconciled passes (static code trace, live browser x-ray, screenshot vision).
- **Browser transport = RAW CDP** (supersedes all earlier MCP/Playwright design). Node scripts (`lib/cdp.mjs`, `lib/drive.mjs`) talk to Chrome's `:9222` debug port directly via the global `WebSocket` (zero deps): `Runtime.evaluate` / `Network.*` (`getResponseBody`) / `Page.captureScreenshot`. The Playwright MCP dependency is dropped entirely; state replay = recorded text/aria descriptor re-resolved by an in-page query after a full nav reset.
- `--read-only` fails closed at the WIRE: `Fetch.enable` aborts every non-GET request. The `DESTRUCTIVE_DENY` text denylist is a secondary hint only, never the guarantee.
- Verdict authoring + evidence judgment split ~50/50 Codex(GPT-5.4)/Claude by element-id hash parity; both families persisted into one `verdicts/` dir before aggregation (silent-inert-Codex trap guard). Cross-family validation covers all three passes; disagreements surfaced, not averaged.
- Fail-closed coverage: `lib/ledger-assert.sh` exit code sets COMPLETE/INCOMPLETE; `lib/validate-findings.sh` (`ajv-cli`) hard-gates `findings.json` before `AUDIT.md`.
- Codex adapter (`lib/codex-invoke.sh`) is a verbatim copy of god-review's — pinned `model_reasoning_effort=high`, so there is no `--effort` flag.
- Outputs: `findings.json` + `AUDIT.md` (FAKE-OR-DEAD → MODELS-DISAGREE → UNVERIFIED → STATIC-BY-DESIGN → REAL summary → coverage manifest + `traversal-actions.log` summary) + full-page per-state screenshots (with per-element bounding-box coordinates in `findings.json` `box` field for downstream overlay — no boxes are drawn onto the PNGs). Handoff to `/god-review` or `/implement`.
