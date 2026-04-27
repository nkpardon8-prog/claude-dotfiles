---
description: Open or resume a Chrome Remote Desktop session to the Mac mini, handling sign-in detection and reconnect overlays. PIN entry is the user's job — the agent never types the PIN.
argument-hint: ""
---

# /macmini connect

## What this does

Drives the chrome-devtools MCP to land you in the Mac mini's CRD canvas. Detects an expired Google sign-in, locates the device tile, clicks it, then **waits for the user to type the PIN themselves**. After the canvas mounts, dismisses any reconnect overlay and focuses the canvas. Never logs the PIN. Never screenshots the PIN page or the sign-in page.

**PIN entry is intentionally user-only.** Storing the CRD PIN in 1Password and replaying it through the canvas is doable but adds a credential the user has to maintain, and it's dead simple to type six digits when the page comes up. The agent's job is to land the user on the PIN page and hand off; the user types; the agent picks back up once the canvas is live.

---

## Sequence

### 1. Find or open the CRD tab

`mcp.list_pages()`. Pick the first page whose URL starts with `https://remotedesktop.google.com/`. If found, `mcp.select_page({pageId, bringToFront: true})`. Otherwise:

- `mcp.new_page({url: "https://remotedesktop.google.com/access"})`

### 2. Detect Google sign-in (re-auth path)

`mcp.evaluate_script` with:

```js
!!document.querySelector('a[href*="accounts.google.com/signin"]') ||
/accounts\.google\.com/.test(location.href)
```

If `true`:

- **Do NOT take a screenshot** — the page may show the user's email.
- Print: "Google session expired. Sign in inside the open Chrome window, then re-run `/macmini connect`."
- Return status `NEEDS_REAUTH`.

### 3. Warm-path check — already in canvas?

```js
!!document.querySelector('canvas') &&
!document.querySelector('button[aria-label*="Reconnect"]')
```

If canvas present and no Reconnect overlay, jump to step 7 (focus discipline).

### 4. Locate and click the device tile

If the user has set `CRD_DEVICE_NAME` in `~/.config/claude/credentials.md`, load it via `/load-creds CRD_DEVICE_NAME` and use it for matching. If not set, take a snapshot and use the first device tile (button-role node whose label contains "Online" or matches the user's known mini name from prior sessions).

```
mcp.take_snapshot()
```

Find a node whose name matches `${CRD_DEVICE_NAME}` (exact, then substring). If neither matches and there's only one Online device tile in the snapshot, click it (single-mini case). If multiple match and `CRD_DEVICE_NAME` is unset, abort with: `Multiple Mac mini tiles visible. Set CRD_DEVICE_NAME in ~/.config/claude/credentials.md to disambiguate.`

```
mcp.click({uid: <device_tile_uid>})
```

### 5. Hand off to the user for PIN entry

Print to the user, exactly:

```
PIN page open. Type your CRD PIN now.
I'll pick back up automatically once the canvas appears.
```

Then wait for the canvas to mount via:

```
mcp.wait_for({text: ["Send system keys", "Synchronize clipboard"], timeout: 120000})
```

The 120-second timeout is generous — gives the user time to find their PIN, type it, and dismiss any "Trust this device" prompt. The "Send system keys" / "Synchronize clipboard" labels live in the side panel and only appear once the canvas is interactive, so they're a reliable canvas-mounted signal.

If the timeout fires:

- Take a screenshot. Check whether the canvas is up but the side panel labels just aren't visible (panel collapsed): `mcp.evaluate_script({function: "() => !!document.querySelector('canvas')"})`. If the canvas is up, proceed to step 6.
- Otherwise abort: `PIN entry timed out. Re-run /macmini connect when ready.`

### 6. Reconnect overlay check

```
mcp.take_snapshot()
```

If a node named `Reconnect` is present, click it:

```
mcp.click({uid: <reconnect_uid>})
mcp.wait_for({text: ["Send system keys"], timeout: 30000})
```

### 7. Focus the canvas

The canvas exposes one usable a11y node — the textbox wrapper named `Desktop`. Take a snapshot, find that uid, click it:

```
mcp.take_snapshot()
mcp.click({uid: <desktop_textbox_uid>})
```

Fallback if the snapshot doesn't surface it: `mcp.evaluate_script({function: "() => { const c = document.querySelector('canvas'); if (c) c.focus(); return !!c; }"})`.

### 8. First-time toggles (USER, ONE-TIME)

If this is the user's first connection in a fresh CRD profile, two toggles in CRD's right-edge side panel need to be ON: **"Synchronize clipboard"** (Data transfer section) and **"Send system keys"** (Input controls section). Both persist across reconnects — once on, stay on. The agent CANNOT click them (CRD strips its own a11y tree, and synthetic clicks fail the `isTrusted` check).

Print one-time hint: `If this is your first connection in this CRD profile, hover the right edge of the canvas, click 'Synchronize clipboard' and 'Send system keys' to ON. They persist from now on.`

### 9. Done

Print: `Connected. Channel matrix in SKILL.md — vision / lowercase typing / /macmini paste for arbitrary text.`

---

## PII rules summary

- NEVER type, log, store, or read the CRD PIN. The user types it themselves in step 5.
- NEVER screenshot the sign-in page (may show user email).
- NEVER screenshot the PIN page during step 5 — wait for the canvas instead.
- On success, no screenshot is taken automatically.
