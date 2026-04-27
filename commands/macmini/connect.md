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
  sign_in_indicator: 'a[href*="accounts.google.com/signin"]'
```

---

## Sequence

### 1. Load credentials (idempotent)

```
/load-creds CRD_PIN,CRD_DEVICE_NAME
```

If either of these resolves empty, abort and tell the user to fix `~/.config/claude/credentials.md` and the 1Password vault entries before re-running.

### 2. Find or open the CRD tab

Use `mcp.list_pages`. Pick the first tab whose URL starts with `https://remotedesktop.google.com/`. If found, `mcp.select_page(tab)`. Otherwise:

- `mcp.new_page()`
- `mcp.navigate_page("https://remotedesktop.google.com/access")`

### 3. Detect Google sign-in (re-auth path)

Run `mcp.evaluate_script` with:

```js
!!document.querySelector('a[href*="accounts.google.com/signin"]') ||
/accounts\.google\.com/.test(location.href)
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

If canvas present and no Reconnect overlay, return `OK`.

### 5. Locate device tile

`mcp.take_snapshot()` and find a node whose label matches `CRD_DEVICE_NAME` exactly, then substring. The chrome-devtools MCP only exposes `wait_for({text})` and `click({uid})` — there is NO selector-based wait_for / click. Match against snapshot labels:

- Exact match: line in snapshot has `name="${CRD_DEVICE_NAME}"` (or `aria-label`).
- Substring fallback: line contains `${CRD_DEVICE_NAME}` anywhere in its label.

If neither matches, `mcp.wait_for({text: ["${CRD_DEVICE_NAME}"], timeout: 8000})`. If still missing: take a screenshot of the device-list page (PIN-safe), then abort with: `Device tile '${CRD_DEVICE_NAME}' not found. Check that the Mac mini is online at https://remotedesktop.google.com/access and that CRD_DEVICE_NAME matches the EXACT name shown on the tile.`

### 6. Click the tile

`mcp.click({uid: <device_tile_uid_from_snapshot>})`.

### 7. Race: canvas vs PIN input

Use `mcp.wait_for({text: [...], timeout: ...})` with text strings expected on each branch:

- Branch A (canvas mounted, no PIN needed): `mcp.wait_for({text: ["Send system keys", "Synchronize clipboard"], timeout: 30000})` — these labels live in the side panel and only appear once connected.
- Branch B (PIN screen): `mcp.wait_for({text: ["Enter PIN", "Connect"], timeout: 8000})`.

Whichever resolves first wins. If branch A wins, jump to step 11.

### 8. PIN entry — handle both variants

Determine which PIN UI is showing via `mcp.evaluate_script`:

```js
document.querySelectorAll('input[inputmode="numeric"][maxlength="1"]').length
```

- If the count is `>= 6` → **6-input variant**: `take_snapshot`, find the first PIN-input uid, `mcp.click({uid: <pin0>})` to focus, then for each digit in `${CRD_PIN}` call `mcp.press_key(digit)`.
- Else → **single-input variant**: take_snapshot, find the input uid (it'll have name "Enter PIN" or similar), `mcp.fill({uid: <input_uid>, value: "${CRD_PIN}"})`.

**NEVER log `${CRD_PIN}` in any output, error message, or screenshot caption.**

### 9. Submit

CRD often auto-submits when 6 digits land. Check via `mcp.evaluate_script`:

```js
!!document.querySelector('canvas')
```

If `false`: take_snapshot, find the Connect button uid, `mcp.click({uid: <connect_uid>})`. Then `mcp.wait_for({text: ["Send system keys"], timeout: 30000})` (the side-panel labels appear once the canvas is interactive).

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

Focus the canvas so subsequent `press_key` calls go to the Mac mini (not a stray DOM control). Per HARDWARE-FINDINGS, the canvas exposes only one usable a11y node — the textbox wrapper "Desktop". Take a snapshot, find the textbox uid (it has `name="Desktop"` and is `focusable`), and click it:

```
mcp.take_snapshot()           # locate the "Desktop" textbox uid
mcp.click({uid: <desktop_textbox_uid>})
```

If the textbox isn't in the snapshot, fall back to `mcp.evaluate_script({function: "() => { const c = document.querySelector('canvas'); if (c) c.focus(); return !!c; }"})`.

### 12. First-time toggles (USER, ONE-TIME)

If this is the user's first connection in a fresh CRD profile, they need to manually click two toggles in CRD's right-edge side panel: **"Synchronize clipboard"** (Data transfer section) and **"Send system keys"** (Input controls section). Both persist across reconnects — once on, stay on. The agent CANNOT click them (CRD strips its own a11y tree, and synthetic clicks fail the `isTrusted` check). Print to the user one-time: `If this is your first connection in this CRD profile, hover the right edge of the canvas, click 'Synchronize clipboard' and 'Send system keys' to ON. Persists from now on.`

### 13. Reconnect overlay check

`mcp.take_snapshot()` and look for a node whose name matches `Reconnect`. If found, `mcp.click({uid: <reconnect_uid>})`, then `mcp.wait_for({text: ["Send system keys"], timeout: 30000})`.

### 14. Done

Print: `Connected to Mac mini. See SKILL.md for the channel matrix (vision / lowercase typing / /macmini paste for arbitrary text).`

---

## PII rules summary

- NEVER log `${CRD_PIN}` anywhere.
- NEVER screenshot the sign-in page (may show user email).
- NEVER screenshot the PIN page without the black-rect overlay; preferably skip entirely.
- On success, no screenshot is taken automatically.
