# Phase E Hardware Findings — 2026-04-27

These are **real-world test results** from running the auto-grant + CRD skill against a live Chrome Remote Desktop session on the user's actual Mac mini. Read this before assuming any documentation written before 2026-04-27 reflects reality.

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

## Confirmed-correct CRD selector schema

`data/crd-selectors.json` has been updated with **hardware-confirmed** selectors. Original hypotheses were wrong:

- `Synchronize clipboard` (NOT "Enable clipboard sync") — `<div role="checkbox" aria-checked>` (NOT `<mwc-switch>`)
- `Send system keys` — `<div role="checkbox" aria-checked>` (NOT `aria-pressed`)
- `Begin` — `<div role="button">` (NOT `<button>`)
- All side-panel options live under `<section role="region" aria-label="Session options">` in collapsed sections (`Show/hide section: Data transfer`, `Show/hide section: Input controls`).

`document.querySelectorAll('[role="..."]')` finds them — no shadow piercing needed. `getBoundingClientRect()` returns 0×0 when panel auto-hides (DOM unchanged, just CSS-hidden).

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
