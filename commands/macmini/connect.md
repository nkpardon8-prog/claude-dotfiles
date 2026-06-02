---
description: Bind the Mac mini's Chrome Remote Desktop session (title-first), handling sign-in detection, the device tile, PIN hand-off, and reconnect overlays. PIN entry is the user's job — the agent never types the PIN. Never act on the Windows CRD session.
argument-hint: ""
---

# /macmini connect — bind the Mac CRD session (title-first)

Bind the agent to the **Mac mini** Chrome Remote Desktop tab and confirm it's
live. PIN / sign-in are user-only. The goal is: end with the macOS desktop
selected, screenshot-confirmed, and a canvas present (the mount signal). Never
logs the PIN. Never screenshots the sign-in page or the PIN page.

## Two CRD sessions exist — disambiguate before ANY input

The user runs **two** CRD sessions: this **Mac mini** and a **Windows** laptop
(the `/windows` target, `OpenDentalDev1` — DO NOT TOUCH). Both URLs are
`https://remotedesktop.google.com/access/session/...`, so URL alone cannot tell
them apart. Bind by **tab title** first, confirm by **screenshot** (macOS menu
bar at top + Dock vs Windows taskbar / Start orb). **Apply this title-first
disambiguation at BOTH stages below** — the tab-selection stage AND the
device-tile stage (the Windows laptop also shows as an Online tile at
`remotedesktop.google.com/access`).

```
DEVICE_NAME = "plan2bid-minim4"   # configurable: the Mac mini's CRD tab title
```

## Steps

1. **Enumerate.** `mcp.list_pages()`.
   - **If this HANGS or errors**, a frozen/discarded background tab is freezing
     the MCP enumeration itself. Run `/devtools` and hand off — see "Self-heal"
     below. Do NOT auto-retry `list_pages`.

2. **Filter to CRD tabs.**
   ```
   crd = [p for p in pages if "remotedesktop.google.com/access/session/" in p.url]
   ```
   - If `crd` is empty → no live CRD session. Check whether a device-list tab
     (`remotedesktop.google.com/access`) is open; if so, go to step 4 to start
     one. If the user's Google session is expired, go to step 3.

3. **Detect Google sign-in (re-auth path).** `mcp.evaluate_script` with:
   ```js
   !!document.querySelector('a[href*="accounts.google.com/signin"]') ||
   /accounts\.google\.com/.test(location.href)
   ```
   If `true`:
   - **Do NOT take a screenshot** — the page may show the user's email.
   - Print: "Google session expired. Sign in inside the open Chrome window, then
     re-run `/macmini connect`."
   - Return status `NEEDS_REAUTH`.

4. **Match the Mac tab / device tile by title (title-first at BOTH stages).**
   ```
   # Stage A — tab selection:
   mac = first p in crd where DEVICE_NAME in p.title
   if mac:
       mcp.select_page({pageId: mac.id, bringToFront: true})   # title-gated → safe to foreground
   elif len(crd) == 1:
       # one CRD tab, NO title match — NOT trusted. Select READ-ONLY (no foreground)
       # so step 5 can screenshot it WITHOUT acting on a maybe-Windows tab.
       mcp.select_page({pageId: crd[0].id, bringToFront: false})
   elif len(crd) > 1:
       STOP — ask the user which tab is the Mac.
       NEVER bringToFront a tab that might be the Windows session.
   else:
       # no live session — open the device list and click the Mac tile (Stage B):
       mcp.new_page({url: "https://remotedesktop.google.com/access"})
       mcp.take_snapshot()
       # Match the tile whose label contains DEVICE_NAME. The Windows laptop ALSO
       # shows as an Online tile — do NOT click the first Online tile blindly.
       # If DEVICE_NAME is unset and multiple Online tiles exist:
       #   STOP — "Multiple device tiles visible. Set CRD_DEVICE_NAME to disambiguate."
       mcp.click({uid: <mac_tile_uid matching DEVICE_NAME>})
   ```

5. **Confirm it's the Mac (screenshot, not assumption).** `mcp.take_screenshot()`.
   - **macOS** shows a **top menu bar + Dock**. → If you selected a lone tab
     **read-only** in step 4, NOW foreground it:
     `mcp.select_page({pageId: crd[0].id, bringToFront: true})`.
   - **Windows** (the WRONG tab) shows a **bottom taskbar / Start orb**. If you
     see that, you read the Windows tab — STOP, do NOT foreground it, do NOT send
     input, ask the user.

6. **Hand off to the user for PIN entry** (only if a PIN page appeared after a
   tile click). Print, exactly:
   ```
   PIN page open. Type your CRD PIN now.
   I'll pick back up automatically once the canvas appears.
   ```
   Two cases reach here: **(a) existing-session path** — step 5 already
   screenshot-confirmed the macOS menu bar, proceed. **(b) fresh Stage-B
   tile-click path** — you EXPECT a CRD **PIN page** now (NOT the macOS desktop,
   so step 5's menu-bar check does not apply yet); do NOT screenshot the PIN page
   (privacy) — your safety is that you clicked the *title-matched* `DEVICE_NAME`
   tile in Stage B. In BOTH cases, wait for the canvas to mount via the side-panel
   labels (they appear only once the canvas is interactive — they double as a
   "toggle-exists" check). **These labels also exist on the *Windows* CRD panel,
   so AFTER the canvas mounts you MUST screenshot-confirm a macOS menu bar before
   any input (step 7)** — the mount signal alone does not prove it's the Mac:
   ```
   mcp.wait_for({text: ["Send system keys", "Synchronize clipboard"], timeout: 120000})
   ```
   If the timeout fires: take a screenshot; check whether the canvas is up but
   the panel labels just aren't visible (panel collapsed):
   `mcp.evaluate_script({function: "() => !!document.querySelector('canvas')"})`.
   If the canvas is up, proceed to step 8. Otherwise abort:
   `PIN entry timed out. Re-run /macmini connect when ready.`

7. **Overlay / lock detection — BEFORE any keypress.** If you see a
   **"Reconnect" / "Session ended"** overlay, a **CRD PIN** prompt, or a
   **macOS sign-in / lock** screen:
   - **Reconnect overlay only:** `mcp.take_snapshot()`; if a node named
     `Reconnect` is present, click it and re-await the mount signal:
     ```
     mcp.click({uid: <reconnect_uid>})
     mcp.wait_for({text: ["Send system keys"], timeout: 30000})
     ```
   - **Sign-in / lock / PIN:** surface it to the user and STOP. PIN and sign-in
     are user-only — never type into them, never screenshot-and-read a credential
     field, never approve. **Press NOTHING** — even a single `Shift` wakes a
     macOS lock screen and surfaces its password box. Hand back to the user.

8. **Wake a genuine black/idle screen.** Only after step 7 has ruled out a
   lock / sign-in / overlay: if the canvas is black or blank,
   `mcp.press_key("Shift")`. **Shift only** — no character input; never
   Enter / Space / a letter. If you cannot tell idle from locked, surface to the
   user instead of pressing anything.

9. **Mount signal (concrete).** Confirm the session is usable:
   - `DEVICE_NAME` is in the bound tab's title (or single-CRD + macOS menu bar
     confirmed), AND
   - the canvas-rect helper returns a non-error rect (a remote canvas exists).
     This is the SAME helper as `act.md` / `macmini.md` — keep the copies
     identical:
   ```js
   meta = mcp.evaluate_script({ function: `() => {
     const cs = [...document.querySelectorAll('canvas')]
       .map(e => { const r = e.getBoundingClientRect();
                   return { x:r.x, y:r.y, w:r.width, h:r.height, bw:e.width, bh:e.height }; })
       .filter(o => o.w > 200 && o.h > 200)
       .sort((a,b) => b.w*b.h - a.w*a.h);
     if (!cs.length) return { error: "no remote canvas found" };
     const c = cs[0];
     return { dpr: window.devicePixelRatio, rect:{x:c.x,y:c.y,w:c.w,h:c.h}, hostW:c.bw, hostH:c.bh };
   }` })
   if meta.error: STOP — no remote canvas; the feed isn't live yet (likely a
                  reconnect/sign-in overlay). Surface to the user.
   else: bound + live. Ready for LAYER-2 actions.
   ```

10. **First-time toggles (USER, ONE-TIME).** If this is the user's first
    connection in a fresh CRD profile, two toggles in CRD's right-edge side panel
    need to be ON: **"Synchronize clipboard"** (Data transfer section) and
    **"Send system keys"** (Input controls section). "Send system keys" is
    **load-bearing** — without it, `Cmd+Space`/`Cmd+Tab`/`Cmd+C`/`Cmd+V` do NOT
    forward to the mini. Both persist across reconnects. The agent usually CANNOT
    click them (macOS CRD a11y exposes only the `Desktop` textbox — see `crd.md`
    for the coordinate/user fallback).

    Print one-time hint: `If this is your first connection in this CRD profile,
    hover the right edge of the canvas, set 'Synchronize clipboard' and 'Send
    system keys' to ON. They persist from now on. "Send system keys" is required
    for Cmd+Space / Cmd+Tab to reach the mini.`

11. **Done.** Print: `Connected. Channel matrix in macmini.md — vision /
    lowercase typing / send_text shift-map for capitals & symbols / click_at for
    the mouse.`

## Self-heal — user-gated `/devtools` handoff

The chrome-devtools connection is owned by `/devtools` (real-profile debug
Chrome on port 9222). When it's unhealthy:

- **Trigger:** any chrome-devtools call **hangs** or **errors**, or `list_pages`
  returns empty when a CRD tab should exist. The #1 cause is a single frozen /
  discarded background tab that stalls the whole enumeration — and that hang
  freezes `list_pages` itself, so treat a hang (not only an empty result) as the
  trigger.
- **Action:** run `/devtools`. Then **STOP and wait for the user to `/mcp`
  reconnect.** Do NOT auto-retry in a loop — the reconnect is a user gesture.
- After the user reconnects, resume from step 1.

## What `connect` never does

- Never types or reads a CRD PIN.
- Never screenshots the sign-in page (may show the user's email) or the PIN page.
- Never types into a macOS sign-in / auth / keychain / accessibility prompt.
- Never `bringToFront`s a tab that could be the Windows session, and never clicks
  the Windows device tile.
- Never starts a brand-new CRD session without first confirming (title + macOS
  menu bar) that it's the Mac.
