---
description: Drive a remote Windows laptop (OpenDental) through Chrome Remote Desktop via the chrome-devtools MCP. Self-resolving — invoke with no sub-command or just reference /windows in plain English; the agent pre-flights, binds the Windows CRD tab by title, and infers the right action from context. No gist, no cliclick, no on-host agent, no calibration — clicks are direct CDP click_at into the CRD canvas.
argument-hint: "[free-form request, e.g. \"open notepad and type a note\"]"
---

# /windows — Windows Laptop Remote

> **READ THIS FIRST — if you do nothing else, read this section.**
>
> You are driving a **Windows 11 laptop** through Chrome Remote Desktop. The
> CRD tab in the user's real-profile Chrome is a live feed of the Windows
> desktop, rendered into an opaque `<canvas>`.
>
> - **Your eyes** are `mcp.take_screenshot()` on the CRD page.
> - **Your hands are direct CDP input** — `mcp.click_at({x,y})`,
>   `mcp.type_text(...)`, `mcp.press_key(...)`. These reach the Windows host
>   natively. There is NO gist, NO cliclick, NO on-host agent, NO calibration
>   file, NO Terminal-foreground dance. (This is the big simplification over
>   `/macmini` — see the callout below.)
> - **Two interaction layers, two toolsets — always know which one you're on:**
>   - **LAYER-1 — CRD's own chrome** (options panel, dialogs, Disconnect,
>     Full-screen, "Synchronize clipboard", "Press Ctrl + Alt + Del",
>     "Press PrtScr"). This is real page DOM → `mcp.take_snapshot()` +
>     `mcp.click({uid})`, **matching the control by its LABEL text each
>     snapshot** (uids are per-snapshot — never hardcode them).
>   - **LAYER-2 — the Windows desktop itself** is the opaque `<canvas>` →
>     coordinate `mcp.click_at()` + `press_key`/`type_text`, reading state
>     ONLY from screenshots.
> - **Bind to the Windows session by TAB TITLE first** (`OpenDentalDev1`,
>   configurable). NEVER `select_page`/`bringToFront` a tab that might be the
>   **Mac** CRD session (the `/macmini` target). Two CRD sessions exist; both
>   are `remotedesktop.google.com/access/session/...` URLs. If you cannot tell
>   which tab is Windows → **STOP and ask.**
> - **Coordinates are derived per click, never reused.** Re-read the canvas
>   rect before every click (the window can resize mid-flow and silently break
>   reused coords — verified incident). Screenshot before AND after.
>
> The three load-bearing snippets — the canvas-rect helper, the capital/symbol
> shift-map, and the title-first pre-flight — are **embedded inline below** so
> this file is self-contained. Depth refs (dotfiles only, not on the deployed
> path): `skills/windows/SKILL.md`, `ONBOARDING.md`, `docs/FINDINGS-2026-05-31.md`.

## How this differs from /macmini (read if you know /macmini)

`/windows` is the leaner, safer sibling. **Negate every macmini mechanic:**

| `/macmini` | `/windows` |
|---|---|
| Hands = `cliclick` on the mini via `gh gist` transport (bypasses CRD's `isTrusted` gate) | Hands = **direct CDP `mcp.click_at({x,y})`** into the CRD canvas — verified reaching the Windows host this session. NO gist, NO cliclick. |
| Arbitrary text = `gh gist` paste channel | Arbitrary text = **per-char `press_key("Shift+<base>")`** with a US shift-map (embedded below). NO gist, NO GitHub, NO credential-leak surface. |
| Per-session `/macmini measure` calibration file | **No calibration** — map via the live canvas rect (embedded helper). |
| Terminal-foreground "dance" + run.sh + on-host agent | **None.** Click the pixel, screenshot to verify. |
| `Cmd+Tab` / `Cmd+Space` niceties via system keys | System keys (Win/Alt+Tab) are **swallowed by CRD** — niceties use **clicks**: Start orb, taskbar icons; Ctrl+Alt+Del/PrtScr = CRD DOM buttons. |

Two things `/macmini` learned that `/windows` must RE-CHECK at runtime (both
worked on this Windows session — see `docs/FINDINGS-2026-05-31.md`): (1) macmini
deprecated `click_at` as unreliable, but it works here — run the toggle-and-
confirm smoke test first session. (2) macmini found CRD's a11y tree `ignored`,
but uids worked here — probe with `take_snapshot` and fall back to coordinates
if `ignored`.

## Self-resolution

When the user invokes `/windows` (with or without arguments) **or references the
Windows laptop / OpenDental in plain English** ("on the windows machine do X",
"in OpenDental click Y", "use /windows to do Z"):

1. **Pre-flight bind (title-first).** `mcp.list_pages()`. Filter to CRD pages
   (`url` contains `https://remotedesktop.google.com/access/session/`).
   - **Title match:** the CRD page whose `title` contains `DEVICE_NAME` (default
     `"OpenDentalDev1"` — configurable) is the Windows tab →
     `mcp.select_page({pageId, bringToFront:true})`.
   - **No title match, exactly one CRD tab — NOT trusted yet.** Select it
     **read-only** first: `mcp.select_page({pageId, bringToFront:false})` (this
     sets it as screenshot context WITHOUT foregrounding/focusing it). Screenshot.
     Only if it shows a **Windows 11 taskbar** (Start orb + tray clock `M/D/YYYY`)
     do you then `mcp.select_page({pageId, bringToFront:true})` and proceed. If it
     shows a **macOS menu bar / Dock**, you read the **Mac** tab → STOP, never
     foreground it, never input, ask the user.
   - **No title match, multiple CRD tabs → STOP and ask** which is Windows. NEVER
     `bringToFront` a tab that might be the Mac session.
   - **If `list_pages` HANGS or errors** (a frozen/discarded background tab can
     freeze the enumeration itself) → run `/devtools` and hand off (see Hard
     rules). Do NOT auto-retry.
2. **Overlay / lock check FIRST — before any keypress.** `mcp.take_screenshot()`.
   If you see a **"Reconnect" / "Session ended"** overlay, a **CRD PIN** prompt,
   or a **Windows sign-in / lock** screen → surface to the user and STOP; PIN /
   sign-in is user-only. **Press NOTHING** — even `Shift` wakes a Windows lock
   screen and lands focus on its credential box.
3. **Wake only a genuine idle/blank desktop.** Only after step 2 has ruled out a
   lock / sign-in / overlay: if the canvas is black/blank, `mcp.press_key("Shift")`
   to wake — **Shift only** (no character input; never Enter/Space/letters). If
   it's black and you cannot tell idle from locked, surface to the user instead
   of pressing anything.
4. **Infer the action** from the capability matrix below. Re-read the canvas rect
   before any click (see embedded helper).

## EMBEDDED HELPER — the ONE canvas-rect mapping (use this for every click_at)

LAYER-2 clicks map a known Windows-host pixel into CSS-px canvas coordinates.
`getBoundingClientRect()` and `click_at` are **BOTH CSS px**, so rect-derived
coords are **NOT** divided by DPR. Call this fresh before each click sequence:

```js
// mcp.evaluate_script({ function: "() => { ... }" })   ← named-arg call shape
() => {
  const cs = [...document.querySelectorAll('canvas')]
    .map(e => { const r = e.getBoundingClientRect();
                // return {x,y,w,h} EXPLICITLY — DOMRect has .width/.height, not .w/.h
                return { x:r.x, y:r.y, w:r.width, h:r.height, bw:e.width, bh:e.height }; })
    .filter(o => o.w > 200 && o.h > 200)
    .sort((a,b) => b.w*b.h - a.w*a.h);   // largest by RENDERED area; NO 1920 hard floor
  if (!cs.length) return { error: "no remote canvas found" };
  const c = cs[0];
  return { dpr: window.devicePixelRatio, rect: {x:c.x,y:c.y,w:c.w,h:c.h}, hostW: c.bw, hostH: c.bh };
}
```

Consumer (reads `.w`/`.h`, which the helper returned explicitly):

```
meta = evaluate_script(helper)
if meta.error: STOP and tell the user (do NOT throw or guess a canvas)

# Click a KNOWN Windows-host pixel (hx,hy) in hostW×hostH space.
# rect & click_at are BOTH CSS px → NO ÷DPR here:
clickX = meta.rect.x + hx * (meta.rect.w / meta.hostW)
clickY = meta.rect.y + hy * (meta.rect.h / meta.hostH)
mcp.click_at({ x: clickX, y: clickY })

# Click something you EYEBALLED off a raw screenshot (shots are innerW×DPR):
# convert the screenshot pixel to a host pixel FIRST (÷DPR + subtract the
# canvas letterbox offset rect.x/rect.y), then feed it through the formula above:
#   hx = (shot_px_x/meta.dpr - meta.rect.x) * (meta.hostW / meta.rect.w)
#   hy = (shot_px_y/meta.dpr - meta.rect.y) * (meta.hostH / meta.rect.h)

take_screenshot()   # verify. Re-read meta before the NEXT click — window can resize mid-flow.
```

## EMBEDDED HELPER — type anything (capitals + symbols) via the shift-map

`type_text` strips Shift (verified: `Hello, World! @#$(test)_+` → `hello, world1 2349test0-+`).
`press_key("Shift+<base>")` HOLDS the modifier and forwards it (verified
`Shift+h`,`i`,`Shift+5` → `Hi%`). Route per character:

```
SAFE  = set("abcdefghijklmnopqrstuvwxyz0123456789 -_=/.,;:'`")   # type_text-safe: lowercase + unshifted
SHIFT = {'!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0',
         '_':'-','+':'=','{':'[','}':']','|':'\\',':':';','"':"'",'<':',','>':'.','?':'/','~':'`'}

def send_text(s):
  if every ch in s is in SAFE and s has NO uppercase:
    mcp.type_text(s)                         # fast path
  else:
    for ch in s:
      if 'A' <= ch <= 'Z':  mcp.press_key("Shift+" + ch.lower())
      elif ch in SHIFT:     mcp.press_key("Shift+" + SHIFT[ch])
      elif ch == ' ':       mcp.type_text(" ")   # verified; do NOT press_key("Space") here
      else:                 mcp.type_text(ch)     # unshifted punct via verified type_text, not press_key(ch)
# Unicode/emoji/bulk = v2 (clipboard/file). First session: smoke-test the FULL shift-map (see below).
```

## EMBEDDED — title-first bind pre-flight (never touch the Mac tab)

```
DEVICE_NAME = "OpenDentalDev1"   # configurable: the Windows device's CRD tab title
pages = mcp.list_pages()         # if this HANGS/errors → /devtools handoff (frozen-tab)
crd   = [p for p in pages if "remotedesktop.google.com/access/session/" in p.url]
win   = first p in crd where DEVICE_NAME in p.title
if win:
    mcp.select_page({pageId: win.id, bringToFront: true})
    screenshot; confirm Windows taskbar (Start orb + tray clock M/D/YYYY)
elif len(crd) == 1:
    # NOT trusted yet — read-only select (does NOT foreground) to screenshot-confirm
    mcp.select_page({pageId: crd[0].id, bringToFront: false})
    screenshot
    if Windows taskbar:  mcp.select_page({pageId: crd[0].id, bringToFront: true})  # now bind
    else (macOS menu bar/Dock):  STOP — that's the Mac tab; never foreground/input
else:
    STOP — ask the user which tab is Windows (NEVER bringToFront a maybe-Mac tab)
# Lock/overlay check BEFORE any keypress (even Shift wakes a Windows lock screen):
if a Reconnect / Session-ended / sign-in / lock / PIN screen is shown:
    surface to user; STOP; press NOTHING
elif bound canvas is black/blank (genuine idle, not locked):
    mcp.press_key("Shift")   # safe wake, no char input
```

## Capability matrix (the agent's single source of truth)

Match the request to its row; use the listed channel; don't improvise.

### Vision (always on, always free) — LAYER-2

| Want to do | Tool |
|---|---|
| See the Windows screen | `mcp.take_screenshot()` |
| Wait for something to render | screenshot + brief wait + screenshot |
| Wake a black screen | `mcp.press_key("Shift")` (Shift only — no char input) |

### Keyboard / single keys — LAYER-2

| Want to do | Channel |
|---|---|
| Press Enter / Tab / Esc / Backspace / arrows / Page* / Home / End | `mcp.press_key("<key>")` |
| App-level shortcut (Ctrl+V, Ctrl+C, Ctrl+A) | `mcp.press_key("Control+<x>")` — forwards fine |
| System combo (Win, Alt+Tab, Ctrl+Alt+Del) | **swallowed by CRD** — do NOT use press_key. Win launch = click Start orb; window switch = click taskbar icon; Ctrl+Alt+Del = CRD DOM button (LAYER-1) |

### Text — LAYER-2

| Want to do | Channel |
|---|---|
| Type pure lowercase + unshifted | `mcp.type_text("<text>")` (fast path) |
| Type ANYTHING with a capital or shifted symbol | `send_text()` per-char shift-map (embedded above) |
| Unicode / emoji / bulk paste | v2 (clipboard/file) — out of scope v1 |

### Mouse — LAYER-2 (direct CDP, via the embedded rect helper)

| Want to do | Channel |
|---|---|
| Left-click a host pixel | rect helper → `mcp.click_at({x,y})` |
| Double-click | `mcp.click_at({x,y, dblClick:true})` |
| Right-click | `mcp.press_key("Shift+F10")` — opens the context menu at the **current keyboard focus / selection**, NOT at a pixel (there is NO right-click param on click_at; schema is `{x,y,dblClick,includeSnapshot}`). To target a specific element, `click_at` it FIRST to focus it — that positioning click is a **real** click (screenshot-verify it, obey the modal/PHI rules) — then `Shift+F10`. |
| Scroll | focus the pane → `press_key("PageDown")`/`"ArrowDown"`, or click the scrollbar arrow buttons. Thumb-drag is experimental (smoke-test `drag` first). No mouse-wheel tool exists. |
| Drag | `mcp.drag(...)` in the same canvas-rect CSS-px space — **UNVERIFIED**, smoke-test first session |

### CRD UI — LAYER-1 (page DOM, uid-by-label)

| Want to do | Channel |
|---|---|
| Disconnect / Full-screen / clipboard toggle | `take_snapshot` → `click({uid})` matching label `"Disconnect"` / `"Full-screen"` / `"Synchronize clipboard"` |
| Ctrl+Alt+Del / PrtScr | `click({uid})` matching label `"Press Ctrl + Alt + Del"` / `"Press PrtScr"` |
| (a11y `ignored`?) | fall back to coordinate `click_at` on the panel, or ask the user to toggle — see `crd.md` |

### Niceties (clicks, not system keys) — LAYER-2

| Want to do | Channel |
|---|---|
| Launch an app | click the **Start orb** → `send_text("<app>")` → `press_key("Enter")` |
| Switch window | click the app's **taskbar icon** |

### Lifecycle

| Want to do | Sub-command |
|---|---|
| Bind / resume the session | `/windows connect` |
| Close it | `/windows disconnect` |
| Health check | `/windows status` |
| LAYER-2 actions | `/windows act <…>` |
| LAYER-1 CRD UI | `/windows crd <…>` |

## Hard rules / safety

- **Windows session only.** Match title `OpenDentalDev1`; confirm the taskbar;
  never select / `bringToFront` / act on the Mac CRD tab; **STOP if ambiguous.**
- **Screenshot before AND after every `click_at`. Re-read the canvas rect before
  each click. Never reuse coords across screenshots** — the window resizes
  mid-flow (verified incident).
- **Modal-recovery rule:** screenshot before+after; if the screen is unchanged
  AND a dialog is visible, the click hit a modal-blocked region — act on the
  modal or press `Esc`; do NOT silently re-click the same coords.
- **OpenDental = live PHI by default.** Do not infer Demo-vs-live from a
  screenshot; only practice freely after the user explicitly confirms the Demo
  DB this session.
- **Real logged-in machine + full real Chrome profile reachable.** Don't click
  Buy / Send / Pay / Confirm / Delete, change settings, approve OAuth/2FA,
  dismiss security warnings, or browse / read other Chrome tabs / email / DMs —
  without explicit user instruction.
- **Verify the EXPECTED state change after any authorized state-changing click**
  (Send / Confirm / Save / Delete, form submits). The "after" screenshot must
  show the *specific* intended change — and no unintended one. "The screen
  changed" is NOT proof the right thing happened.
- **Never type into or approve Windows UAC / sign-in / credential prompts**, and
  never type a CRD PIN — surface to the user.
- **Connection self-heal is user-gated.** If a chrome-devtools call hangs/errors
  or `list_pages` returns empty, run `/devtools`, then **wait for the user to
  `/mcp` reconnect**. No auto-retry loop. (The frozen-tab hang freezes
  `list_pages` itself, so treat a hang — not just an empty result — as the
  `/devtools` trigger.)

## First-session smoke tests (run once, on a safe scratch field)

1. **click_at reaches host** — toggle a harmless checkbox / focus a field;
   screenshot-confirm. (Covers the macmini "click_at deprecated/unreliable"
   conflict — verified working here, but re-check.)
2. **Full shift-map** — `send_text("!@#$%^&*()_+{}|:\"<>?~ Az")` into a scratch
   field; screenshot-confirm EVERY char. (Only `Hi%` was live-verified.)
3. **drag** — drag a scrollbar thumb a known distance; screenshot-confirm. If it
   fails → scroll falls back to PageDown / arrow-button click.
4. **CRD a11y** — `take_snapshot`; confirm CRD controls expose clickable uids; if
   `ignored`, switch LAYER-1 to the coordinate fallback.

## Sub-commands (for explicit invocation)

| Sub-command | Purpose |
|---|---|
| `/windows connect` | Bind the Windows session by title; `/devtools` handoff; Shift-wake; mount signal. PIN is user-only. |
| `/windows act <action>` | LAYER-2 desktop: `click` / `double` / `right` / `type` / `key` / `scroll` / `launch` / `switch` — all via the one rect helper. |
| `/windows crd <action>` | LAYER-1 CRD UI by uid-label: panel, Ctrl+Alt+Del, PrtScr, Full-screen, clipboard toggle, plus `disconnect` and `status`. |
| `/windows disconnect` | Click the CRD "Disconnect" button by label. (Lives in `crd.md`.) |
| `/windows status` | Health audit: tab present? title match? canvas rect ok? clipboard-sync checked? hang/frozen-tab probe? (Lives in `crd.md`.) |

> **Delegation posture:** inline vision is the point of this skill, so reading
> screenshots and acting on them stays in-thread. Heavy page enumeration (a big
> `list_pages`, a deep `take_snapshot` dump) may be delegated, but never split a
> click→screenshot→verify loop across agents.

## See also (dotfiles only — NOT on the deployed `~/.claude/` path)

- Runtime reference: [`skills/windows/SKILL.md`](../skills/windows/SKILL.md)
- Cold-start read order + invariants: [`skills/windows/ONBOARDING.md`](../skills/windows/ONBOARDING.md)
- Verified-vs-assumed reality + the two `/macmini` conflicts: [`skills/windows/docs/FINDINGS-2026-05-31.md`](../skills/windows/docs/FINDINGS-2026-05-31.md)
- Sibling skill (architectural ancestor): [`commands/macmini.md`](./macmini.md)
- Connection self-heal: `/devtools`
