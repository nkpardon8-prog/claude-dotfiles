# Phase E Hardware Findings — 2026-04-27 (updated 2026-04-30 with click_at validation)

These are **real-world test results** from running the auto-grant + CRD skill against a live Chrome Remote Desktop session on the user's actual Mac mini. Read this before assuming any documentation written before 2026-04-27 reflects reality.

> **Update — credential leak incident (2026-04-27, post-Phase-E).** A field instance of the skill leaked an OPENROUTER_API_KEY through `/macmini paste`'s gist transport. GitHub's secret-scanning service forwards detected keys to issuer partners; auto-revocation followed within minutes. Two keys burned this way before the team realized what was happening. The skill now hard-blocks credential-shaped payloads at Step 0 of `paste.md` and routes credential injection through `--secure` mode (gist contains only a `read -s` prompt, never the value). Full incident write-up in [`INCIDENTS.md`](./INCIDENTS.md). The findings below are unchanged — they describe the keyboard/clipboard transport reality, which is orthogonal to the secret-scanning issue.

> **Update — click_at(x,y) validated through CRD canvas (2026-04-30).** The chrome-devtools-mcp `--experimental-vision` flag was enabled and `mcp.click_at(x, y)` was tested end-to-end against the live CRD session into `plan2bid-minim4`. **CDP-injected mouse events forward through CRD's canvas to the Mac mini** — confirming the prediction in the implementation plan and closing the last big capability gap (off-center clicks on the CRD canvas were keyboard-only before this). See "click_at(x, y) forwarding through CRD canvas (validated 2026-04-30)" section below for the per-test outcome table.
>
> **[DEPRECATED 2026-05-19]** The `--experimental-vision` channel went unreliable upstream and `click_at` has been replaced by `cliclick-via-paste` as the primary mouse channel. See [`INCIDENTS.md`](./INCIDENTS.md) → "2026-05-19 — `mcp.click_at(x,y)` deprecated" for the full rationale. The validated click_at data below is preserved as historical record only.

## cliclick-via-paste (primary mouse channel, 2026-05-19)

**Status: primary.** Replaces `mcp.click_at(x, y)` as the canonical way to click, right-click, double-click, and drag on the Mac mini.

- **How it works.** The agent calls `/macmini click <sx> <sy>` (or `rclick`/`dblclick`/`drag`). The sub-command converts screenshot pixels to mini-physical pixels using calibration from `~/.config/claude/macmini-calibration.json`, builds a one-line `cliclick c:X,Y` run.sh, uploads it as a secret gist, types the lowercase clone command on the mini's canvas, and the mini executes cliclick directly on its own OS.
- **Round-trip latency.** ~6s per click (same as `/macmini paste` — they share the same gist transport). Much slower than the deprecated `click_at` (~50ms), but reliable across sessions and not subject to CRD isTrusted enforcement.
- **Runs on mini OS — no isTrusted gate.** cliclick is invoked on the mini's local OS via `bash run.sh`, which runs in the mini's normal shell context. CRD's canvas event-trust model is entirely bypassed; this is the architectural advantage over any dev-side synthetic-event approach.
- **Calibration required (one-time per mini).** Run `/macmini measure` to write `~/.config/claude/macmini-calibration.json`. The click sub-commands load this file on every call and refuse if missing or stale (>30 days or canvas dimensions changed). Re-run `/macmini measure` after toggling CRD streaming resolution or swapping the mini's display.
- **Supported actions.** Left-click, right-click, double-click, drag, modifier+click (Cmd/Shift/Option/Control via `kd:<mod> c:X,Y ku:<mod>` — atomic single shell invocation). AppleScript via `/macmini script` shares the same gist channel.
- **See.** `INCIDENTS.md` → "2026-05-19 — `mcp.click_at(x,y)` deprecated" for why this replaced click_at. `commands/macmini/click.md` (and `rclick.md`, `dblclick.md`, `drag.md`, `measure.md`) for the sub-command procedures.

---

## TL;DR — what the agent can and cannot rely on

| Capability | Reality |
|---|---|
| Screenshot the CRD canvas (`take_screenshot`) | **Works** — primary feedback channel. |
| Type lowercase + unshifted symbols (`type_text`, `press_key`) | **Works** — keystrokes forward to Mac mini. |
| Cmd+modifier system keys (`press_key('Meta+v')`, etc.) | **Works** — forwarded to Mac mini focus. |
| Type capitals or shifted symbols | **BROKEN** — Shift is stripped or remapped to wrong char. `$` → `+`, `(` → `%`, `_` → `-`, capitals → lowercase. |
| Programmatic clipboard write triggering CRD sync to Mac mini | **BROKEN** — `pbcopy` on dev side does NOT propagate to Mac mini. Synthetic Cmd+V from CDP is not a "user gesture", so CRD's `onPaste` handler never reads the clipboard to push. |
| `Synchronize clipboard` toggle = `aria-checked="true"` | Visually says ON but does NOT make programmatic writes propagate. |
| `mcp.take_snapshot()` finding CRD UI uids (Begin, toggles, Send button) | **BROKEN** — CRD's a11y tree is stripped to `ignored`. Only the canvas-wrapper textbox exposes a uid. |
| `mcp.click({uid})` on CRD controls | **BROKEN** — no uid available (see above). |
| Synthetic DOM `click()` events on CRD controls | **BROKEN** — CRD requires `isTrusted=true`. |
| `defaults write com.google.Chrome ClipboardAllowedForUrls` (user-policy without MDM) | **No-op on this Mac** — `chrome://policy` shows zero policies applied. Recommended user policy requires MDM enrollment OR `--mandatory` (sudo + write to `/Library/Managed Preferences/`). |
| `curl http://127.0.0.1:9222/json/version` | **404** — Chrome locks `/json/*` HTTP endpoints unless launched with `--remote-allow-origins=*`. The script `grant-cdp-permissions.mjs` cannot reach Chrome to call `Browser.grantPermissions`. |
| `gh gist` transport for arbitrary text | **Works** in principle — both sides authenticated to same GitHub account. Untested end-to-end this Phase E because dev → mini direction needs to type the `gh` command on mini, which is feasible since `gh gist view <id> --raw` is all unshifted lowercase. |
| Mac mini Claude delegation | Untested this Phase E (Mac mini Claude was not running at start). Available via typing `claude` in Terminal — same constraint: command and prompts must be unshifted-friendly OR delivered via gist. |

## Confirmed reliable channels (use these)

1. **Vision via `take_screenshot`** — for state, focus, dialogs, what's visible. Always-on.
2. **Lowercase + unshifted-symbol typing via `type_text`** — for shell commands that don't need capitals or shifted chars.
3. **`press_key('Meta+v')`, `press_key('Control+c')`, `press_key('Enter')`, etc.** — Cmd-modifier shortcuts forward to Mac mini if "Send System Keys" toggle was enabled previously by a real user gesture (it persists across the session).
4. **Mac mini's own local clipboard** — set by Mac mini itself (e.g. user copying from a mini-side app). Cmd+V on canvas pastes whatever's on mini's pasteboard at that moment.

## Confirmed broken paths (don't rely on these)

1. **`navigator.clipboard.writeText()` on the CRD page → CRD pushes to Mac mini** — DOES NOT FIRE. CRD's `onPaste` requires user gesture; CDP-injected events are synthetic.
2. **Dev-side `pbcopy` → CRD sync → Mac mini's pasteboard** — same root cause. `pbcopy` puts text on dev's macOS pasteboard, but CRD's web client never reads it without a user-gesture trigger.
3. **`auto-grant install` (user-policy via `defaults write`)** — silently no-ops on this Mac (no MDM). Use `--mandatory` (sudo) or skip entirely.
4. **`auto-grant cdp` (Browser.grantPermissions via WebSocket)** — script cannot find Chrome's WebSocket URL because `/json/version` returns 404. Would need Chrome relaunched with `--remote-allow-origins=*` — and that disconnects the live CRD session.
5. **`auto-grant ui` (clicking Begin / toggles)** — `take_snapshot` returns `ignored` for all CRD controls. No uids to click.

## CRD selector observations (informational only — `data/crd-selectors.json` was deleted)

Original hypotheses were wrong; the live DOM shape is:

- `Synchronize clipboard` (NOT "Enable clipboard sync") — `<div role="checkbox" aria-checked>` (NOT `<mwc-switch>`)
- `Send system keys` — `<div role="checkbox" aria-checked>` (NOT `aria-pressed`)
- `Begin` — `<div role="button">` (NOT `<button>`)
- All side-panel options live under `<section role="region" aria-label="Session options">` in collapsed sections (`Show/hide section: Data transfer`, `Show/hide section: Input controls`).

`document.querySelectorAll('[role="..."]')` finds them — no shadow piercing needed. `getBoundingClientRect()` returns 0×0 when panel auto-hides (DOM unchanged, just CSS-hidden). However the agent CANNOT reliably click them: synthetic clicks fail CRD's `isTrusted` check, and `mcp.click({uid})` is impossible because the a11y tree exposes them as `ignored`. The user clicks the two toggles (Synchronize clipboard, Send system keys) once manually at first connect; both persist across reconnects.

## Architectural recommendations

Based on these findings, the auto-grant skill needs a redesign before "seamless" is achievable:

### Short-term (use today)

- **Vision-first.** Treat the CRD canvas as a screenshot-only surface. Verify state visually before/after every action.
- **Type only lowercase + unshifted shell commands.** For anything else, route through gist.
- **gh gist as the arbitrary-text channel.** On dev: `gh gist create -f payload.txt - <<< "<content>"`. On mini: type `gh gist view <id> --raw` (all unshifted-safe) to retrieve.
- **For initial setup: ONE-TIME manual user steps.** The user clicks "Synchronize clipboard" + "Send system keys" toggles in the CRD side panel themselves. Once enabled, they persist across the session (and the agent never needs to click them again).

### Long-term (would need new design)

- **Replace the auto-grant `cdp` mode** — it can't work without Chrome relaunch. Consider documenting it as "available only if Chrome was launched with `--remote-debugging-port=9222 --remote-allow-origins=*` AND `/json/version` is reachable" — i.e. a power-user setup, not the default.
- **Replace the auto-grant `install` mode** — user-policy without MDM is theatrical. Either commit to `--mandatory` (sudo, one-time) OR document that the user must manually grant clipboard permission once via `chrome://settings/content/clipboard`.
- **Replace the auto-grant `ui` mode** — synthetic clicks fail and a11y is stripped. The only ways to click CRD's hidden controls are (a) real mouse via macOS automation (cliclick / AppleScript at hardcoded coordinates) or (b) just have the user click them once at first-time setup (they persist).

## Test artifacts (this session)

- Live CRD session: page 13 = `https://remotedesktop.google.com/access/session/...` (page index changes per session).
- Screenshots saved: `tmp/macmini-shots/phase-e-*.png`.
- All evaluate_script probes documented in chat transcript.
- Mac mini still has stale clipboard content from earlier (could not clear it because dev → mini sync is broken).

## What the user already had working before Phase E

The user's CRD session already had `Synchronize clipboard` toggle = ON and `Send system keys` toggle = ON from a prior session — persisted by CRD across reconnects. The Chrome clipboard permission for `https://remotedesktop.google.com` was also already `granted` from a prior chrome://settings prompt.

**Implication:** the auto-grant skill's main value (avoiding the "Allow clipboard" popup, clicking the Begin button) is mostly already handled by CRD's own session persistence after the user grants once. The skill's elaborate scripting layer doesn't actually need to run on a session-by-session basis — it would only be relevant for a brand-new Chrome profile or after the user clears site permissions.

---

## click_at(x, y) forwarding through CRD canvas (validated 2026-04-30)

**Setup.** chrome-devtools-mcp launched with `--autoConnect --experimental-vision` (per `~/.claude.json` + `setup.md` Step 1). Live CRD session into `plan2bid-minim4` (1920×1080 mini display, 16:9). Dev viewport: 1200×863 CSS pixels at DPR=2 (Retina MacBook). Canvas occupies (0, 94)→(1200, 769) in viewport CSS pixels — 1200×675 CSS px streaming the mini's full 1920×1080.

### Per-test outcome

| # | Test | Action | Result | Latency |
|---|---|---|---|---|
| 0 | Tool availability | ToolSearch `select:mcp__chrome-devtools__click_at` | Loaded with schema `{x, y, dblClick?, includeSnapshot?}` | n/a |
| 1 | Geometry fetch | `evaluate_script` returns `{dpr, zoom, scrollX/Y, canvas rect}` | Returned valid object; canvas rect (0, 94)→(1200, 769) | <100ms |
| 2 | Sanity click — canvas centerpoint | `click_at(600, 431)` | No error; click registered | ~50ms |
| 3 | Pixel-precise click on known target | `click_at(250, 500)` (LEFT Terminal) → `type_text("date", Enter)` | LEFT Terminal showed `Thu Apr 30 09:47:50 MDT 2026` — click successfully focused target window AND subsequent type_text landed there | ~50ms click + ~100ms type |
| 4 | Cmd-modifier alongside click_at | `press_key("Meta+Space")` | Spotlight Search bar appeared on mini; `Escape` dismissed | ~50ms each |
| 5 | Off-canvas refusal | Recipe check on (600, 50) | `inside: false`, `isCanvas: false`, occluding element `<div class="YtOxne">` (CRD UI chrome) — recipe correctly refused without firing click | n/a (refusal, not click) |
| 9 | Double-click | `click_at(966, 541, dblClick: true)` on CODEBASES desktop folder icon | Click registered without error; folder did NOT open — likely missed icon center by a few px (small target). Mechanism works; just needs more precise vision-coord estimation for ~50px desktop icons. | ~80ms |
| Bonus | dev → Mac mini Claude conversation | `click_at(700, 282)` to focus mini Claude TUI input → `type_text("hi from dev claude via click-at — please reply with one word: confirmed", Enter)` | Mac mini Claude received the message (with Shift-strip artifacts: `—` arrived as space, `:` as `;`) and replied: `● confirmed` after ~2s | ~6s end-to-end |

### Key takeaways

- **CDP-injected mouse events forward through CRD's canvas as expected.** The prediction in the implementation plan was correct: canvas mouse handlers don't enforce `isTrusted` (unlike clipboard onPaste, which DOES enforce it — that's why the credential leak channel needed `--secure` mode). `Input.dispatchMouseEvent` produces real `isTrusted=true` events at the Chromium process level, and CRD's WebRTC layer forwards them to the mini as real mouse events.
- **Click latency is ~50ms.** Roughly 100× faster than the gist-transport channel for `/macmini paste` (~6s for arbitrary text). Click is now the right primitive for any non-text interaction.
- **Geometry math works as designed.** DPR=2 conversion (`vx = sx / dpr`) lands clicks at the right canvas position. Off-canvas refusal via `getBoundingClientRect` + `elementFromPoint` correctly catches both rect-violations and CRD UI overlays.
- **Cmd-modifier still works.** Adding `--experimental-vision` did NOT break the existing `press_key("Meta+...")` path.
- **Small-target clicks need iteration.** Vision-based coord estimation has ~5-20px error tolerance. For icons smaller than ~30×30 px (desktop folder icons, traffic-light buttons), expect to need verify-after-click and potentially a second attempt with adjusted coords. The recipe's "verify after click" pattern (recommended for icons; mandatory for destructive actions) handles this.
- **Shift-strip caveat unchanged.** `type_text` still strips Shift modifiers — `:` arrives as `;`, `—` as space, capitals as lowercase. Use `/macmini paste` for arbitrary-text needs that include shifted characters. click_at doesn't change this; it's purely the keyboard pipeline.

### Per-app outcome (initial coverage; expand as more apps tested)

| App / target | Action | Result | Notes |
|---|---|---|---|
| Mac mini Terminal (focusing window via click in body) | left-click | OK | Simple window-focus is reliable |
| Mac mini Terminal (sending command after click) | type_text after click | OK | Focus transferred correctly |
| Mac mini Spotlight Search (open via Cmd+Space) | press_key | OK | Existing channel still works post-click_at |
| Mac mini Claude Code TUI (input prompt) | left-click + type_text | OK | Real-world conversation worked end-to-end |
| Mac mini Finder (desktop folder icon, ~50×50 px) | dblClick | PARTIAL | Click landed, but visual coord estimate was slightly off-target. Recipe's verify-after pattern handles this. |

### What was NOT tested in this round

- Browser zoom robustness (`Cmd+=`/`Cmd+-`) — geometry recipe handles it via `visualViewport.scale` but not exercised live.
- Window resize robustness — recipe says re-fetch on resize; not exercised live.
- In-app click on Safari (open Safari, click address bar) — skipped; mini-Claude conversation was a stronger real-world test.
- cliclick fallback for drag/right-click — not invoked; click_at covered the tested cases.
- CRD top-toolbar overlay edge case (top 60px of canvas) — not encountered during tests; recipe handles it via `elementFromPoint` check.
