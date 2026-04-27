---
description: Open or resume a Chrome Remote Desktop session to the Mac mini, handling sign-in detection, PIN entry (1-input or 6-input), and reconnect overlays.
argument-hint: ""
---

# /macmini connect

## What this does

Drives the chrome-devtools MCP to land you in the Mac mini's CRD canvas. Detects an expired Google sign-in, locates the device tile, races canvas-vs-PIN to handle the case where CRD remembered the PIN, enters the PIN (handling both the single-input and 6-input variants of CRD's PIN page), and dismisses any reconnect overlay. Never logs the PIN. Never screenshots the PIN page or the sign-in page (the latter may show the user's email).

---

## Selectors

```yaml
crd:
  url: https://remotedesktop.google.com/access
  device_tile: '[aria-label="${CRD_DEVICE_NAME}"]'      # CRD-side aria-label, NOT Tailscale name
  device_tile_fallback: '[aria-label*="${CRD_DEVICE_NAME}"]'
  pin_input_single: 'input[type="tel"], input[autocomplete="one-time-code"]'
  pin_inputs_six: 'input[inputmode="numeric"][maxlength="1"]'
  connect_button: 'button[aria-label="Connect"]'
  canvas: 'canvas'
  reconnect_overlay: 'button[aria-label*="Reconnect"]'
  sign_in_indicator: 'input[type="email"], a[href*="accounts.google.com/signin"]'
```

---

## Sequence

### 1. Load credentials (idempotent)

```
/load-creds CRD_PIN,CRD_MAC_MINI_HOSTNAME,CRD_DEVICE_NAME,CRD_SERVER_TOKEN
```

If any of these resolve empty, abort and tell the user to fix `~/.config/claude/credentials.md` and the 1Password vault entries before re-running.

### 2. Find or open the CRD tab

Use `mcp.list_pages`. Pick the first tab whose URL starts with `https://remotedesktop.google.com/`. If found, `mcp.select_page(tab)`. Otherwise:

- `mcp.new_page()`
- `mcp.navigate_page("https://remotedesktop.google.com/access")`

### 3. Detect Google sign-in (re-auth path)

Run `mcp.evaluate_script` with:

```js
!!document.querySelector('input[type="email"]') ||
!!document.querySelector('a[href*="accounts.google.com/signin"]')
```

If `true`:

- **Do NOT take a screenshot** — the page may show the user's email in the email input field.
- Print: "Google session expired in the Claude-CRD profile. Sign in inside the open Chrome window, then re-run `/macmini connect`."
- Return status `NEEDS_REAUTH`. (Google does not allow automated re-auth — this requires the user.)

### 4. Warm-path check — already in canvas?

```js
!!document.querySelector('canvas') &&
!document.querySelector('button[aria-label*="Reconnect"]')
```

If `true`: run `macmini-client health` to cross-check the side-channel, then return `OK`.

### 5. Locate device tile

- `mcp.wait_for('[aria-label="${CRD_DEVICE_NAME}"]', 8s)` — exact match first.
- On miss: `mcp.wait_for('[aria-label*="${CRD_DEVICE_NAME}"]', 8s)` — substring fallback.
- On miss again: take a screenshot of the device-list page (this page is PIN-safe), then abort with an actionable error: "Device tile `${CRD_DEVICE_NAME}` not found. Check that the Mac mini is online at https://remotedesktop.google.com/access and that `CRD_DEVICE_NAME` matches the EXACT name shown on the tile."

### 6. Click the tile

`mcp.click(<device tile selector that matched>)`.

### 7. Race: canvas vs PIN input

Run two `wait_for` calls in parallel:

- `mcp.wait_for('canvas', 30s)` — branch A: PIN was remembered, you're already in.
- `mcp.wait_for('input[type="tel"], input[autocomplete="one-time-code"], input[inputmode="numeric"][maxlength="1"]', 8s)` — branch B: PIN entry needed.

Whichever resolves first wins. If branch A wins, jump to step 11.

### 8. PIN entry — handle both variants

Determine which PIN UI is showing:

```js
document.querySelectorAll('input[inputmode="numeric"][maxlength="1"]').length
```

- If the count is `>= 6` → **6-input variant**:
  - `mcp.click('input[inputmode="numeric"][maxlength="1"]')` — focuses the first input.
  - For each digit in `${CRD_PIN}`: `mcp.press_key(digit)`.
- Else → **single-input variant**:
  - `mcp.fill('input[type="tel"], input[autocomplete="one-time-code"]', "${CRD_PIN}")`.

**NEVER log `${CRD_PIN}` in any output, error message, or screenshot caption.**

### 9. Submit

CRD often auto-submits when 6 digits land. Check if you're already on the canvas:

```js
!!document.querySelector('canvas')
```

If `false`: `mcp.click('button[aria-label="Connect"]')`.

Then `mcp.wait_for('canvas', 30s)`.

### 10. Failure-path screenshots over the PIN page

If you must take a debug screenshot while the PIN field is on screen, **first** overlay the PIN-input region with a black rectangle via `mcp.evaluate_script`:

```js
(() => {
  const sels = ['input[type="tel"]', 'input[autocomplete="one-time-code"]',
                'input[inputmode="numeric"][maxlength="1"]'];
  for (const s of sels) {
    document.querySelectorAll(s).forEach(el => {
      const r = el.getBoundingClientRect();
      const d = document.createElement('div');
      d.style.cssText = `position:fixed;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;background:#000;z-index:2147483647;`;
      document.body.appendChild(d);
    });
  }
})()
```

Or just skip the screenshot for that state. **Sign-in screen: never screenshot.**

### 11. Focus discipline

```
mcp.click('canvas', 1, 1)
```

Tiny offset into the canvas to put keyboard focus on it (so subsequent `press_key` calls go to the Mac mini, not a stray DOM control).

### 12. Reconnect overlay check

```js
!!document.querySelector('button[aria-label*="Reconnect"]')
```

If `true`:

- `mcp.click('button[aria-label*="Reconnect"]')`
- `mcp.wait_for('canvas', 30s)`

### 13. Side-channel handshake

```bash
macmini-client health
```

Must return `ok=true` within 2s. If it fails, the visual session is up but the data side-channel isn't reachable — tell the user to run `/macmini status` to localize the failure (Tailscale vs server process).

### 14. Done

Return `OK`.

---

## PII rules summary

- NEVER log `${CRD_PIN}` anywhere.
- NEVER screenshot the sign-in page (may show user email).
- NEVER screenshot the PIN page without the black-rect overlay; preferably skip entirely.
- On success, no screenshot is taken automatically.
