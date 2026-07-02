# Changelog — /ui-audit

## rev 3 — 2026-07-02

Initial release.

- Report-only, per-tab UI reality audit: enumerates the entire rendered surface of ONE tab across every reachable sub-state into a fail-closed coverage ledger; strict per-element verdicts (`REAL` / `STATIC-BY-DESIGN` / `FAKE-OR-DEAD` / `UNVERIFIED` + a `MODELS-DISAGREE` bucket) proven through three reconciled passes (static code trace, live browser x-ray, screenshot vision).
- **Browser transport = RAW CDP** (supersedes all earlier MCP/Playwright design). Node scripts (`lib/cdp.mjs`, `lib/drive.mjs`) talk to Chrome's `:9222` debug port directly via the global `WebSocket` (zero deps): `Runtime.evaluate` / `Network.*` (`getResponseBody`) / `Page.captureScreenshot`. The Playwright MCP dependency is dropped entirely; state replay = recorded text/aria descriptor re-resolved by an in-page query after a full nav reset.
- `--read-only` fails closed at the WIRE: `Fetch.enable` aborts every non-GET request. The `DESTRUCTIVE_DENY` text denylist is a secondary hint only, never the guarantee.
- Verdict authoring + evidence judgment split ~50/50 Codex(GPT-5.4)/Claude by element-id hash parity; both families persisted into one `verdicts/` dir before aggregation (silent-inert-Codex trap guard). Cross-family validation covers all three passes; disagreements surfaced, not averaged.
- Fail-closed coverage: `lib/ledger-assert.sh` exit code sets COMPLETE/INCOMPLETE; `lib/validate-findings.sh` (`ajv-cli`) hard-gates `findings.json` before `AUDIT.md`.
- Codex adapter (`lib/codex-invoke.sh`) is a verbatim copy of god-review's — pinned `model_reasoning_effort=high`, so there is no `--effort` flag.
- Outputs: `findings.json` + `AUDIT.md` (FAKE-OR-DEAD → MODELS-DISAGREE → UNVERIFIED → STATIC-BY-DESIGN → REAL summary → coverage manifest + `traversal-actions.log` summary) + annotated screenshots. Handoff to `/god-review` or `/implement`.
