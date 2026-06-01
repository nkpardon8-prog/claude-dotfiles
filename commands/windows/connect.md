# /windows connect — bind the Windows CRD session (title-first)

Bind the agent to the **Windows** Chrome Remote Desktop tab and confirm it's
live. This never opens a new CRD session and never types a PIN — sign-in / PIN
is user-only. The goal is: end with the Windows desktop selected, screenshot-
confirmed, and a canvas present (the mount signal).

## Two CRD sessions exist — disambiguate before ANY input

The user runs **two** CRD sessions: a **Mac mini** (the `/macmini` target — DO
NOT TOUCH) and this **Windows** laptop. Both URLs are
`https://remotedesktop.google.com/access/session/...`, so URL alone cannot tell
them apart. Bind by **tab title** first, confirm by **taskbar screenshot**.

```
DEVICE_NAME = "OpenDentalDev1"   # configurable: the Windows device's CRD tab title
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
   - If `crd` is empty → no CRD session is open. Surface to the user: they must
     open / resume the Windows CRD session themselves (and type the PIN). The
     agent does not start one.

3. **Match the Windows tab by title.**
   ```
   win = first p in crd where DEVICE_NAME in p.title
   if win:
       mcp.select_page({pageId: win.id, bringToFront: true})   # title-gated → safe to foreground
   elif len(crd) == 1:
       # one CRD tab, NO title match — NOT trusted. Select READ-ONLY (no foreground)
       # so you can screenshot it WITHOUT acting on a maybe-Mac tab. Step 4 must
       # confirm a Windows taskbar BEFORE you foreground or input.
       mcp.select_page({pageId: crd[0].id, bringToFront: false})
   else:
       STOP — ask the user which tab is Windows.
       NEVER bringToFront a tab that might be the Mac session.
   ```

4. **Confirm it's Windows (screenshot, not assumption).** `mcp.take_screenshot()`.
   - **Windows 11** shows a **bottom taskbar**: Start orb, Search pill, Copilot,
     system tray with a date in `M/D/YYYY`. → If you selected a lone tab
     **read-only** in step 3, NOW foreground it:
     `mcp.select_page({pageId: crd[0].id, bringToFront: true})`.
   - **macOS** (the WRONG tab) shows a **top menu bar / Dock**. If you see that,
     you read the Mac tab — STOP, do NOT foreground it, do NOT send input, ask
     the user.

5. **Overlay / lock detection — BEFORE any keypress.** If you see a
   **"Reconnect" / "Session ended"** overlay, a **CRD PIN** prompt, or a
   **Windows sign-in / lock** screen:
   - Surface it to the user and STOP. **PIN and sign-in are user-only** — never
     type into them, never screenshot-and-read a credential field, never approve.
   - **Press NOTHING** — even a single `Shift` wakes a Windows lock screen and
     surfaces its password box. Do not screenshot-loop hoping it clears; hand
     back to the user and wait.

6. **Wake a genuine black/idle screen.** Only after step 5 has ruled out a
   lock / sign-in / overlay: if the canvas is black or blank,
   `mcp.press_key("Shift")`. **Shift only** — no character input; never
   Enter / Space / a letter. If you cannot tell idle from locked, surface to the
   user instead of pressing anything.

7. **Mount signal (concrete).** Confirm the session is usable:
   - `DEVICE_NAME` is in the bound tab's title (or single-CRD + taskbar
     confirmed), AND
   - the canvas-rect helper returns a non-error rect (a remote canvas exists).
     This is the SAME helper as `act.md` / `windows.md` — keep the copies
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
- Never types into a Windows sign-in / UAC / credential prompt.
- Never `bringToFront`s a tab that could be the Mac session.
- Never starts a brand-new CRD session on the user's behalf.
