# windows — drive a remote Windows laptop through Chrome Remote Desktop

> **YOUR HANDS = direct CDP input** — `mcp.click_at({x,y})`, `mcp.type_text`,
> `mcp.press_key`. They reach the Windows host natively through the CRD canvas.
> NO gist, NO cliclick, NO on-host agent, NO calibration file, NO Terminal
> dance. (`/macmini` historically used gist/cliclick; it's now a direct-CDP
> twin of this skill.) **YOUR EYES =
> `mcp.take_screenshot()`.** If you didn't already, read
> [`../../commands/windows.md`](../../commands/windows.md) → "READ THIS FIRST" —
> it has the mental model plus the three embedded helpers (canvas-rect map,
> shift-map, title-first bind) that make the dispatcher self-contained.

> **First-time agent? Read [`ONBOARDING.md`](./ONBOARDING.md)** for the read
> order and invariants. **Reality matrix:** [`docs/FINDINGS-2026-05-31.md`](./docs/FINDINGS-2026-05-31.md)
> — what's verified, what's assumed, and the two `/macmini` conflicts to
> re-check at runtime.

You drive a **Windows 11 laptop** (running OpenDental) through the
`chrome-devtools` MCP attached to the user's real-profile Chrome (port 9222,
managed by `/devtools`). CRD renders the Windows desktop into an opaque
`<canvas>`. Two interaction layers, two toolsets — always know which one you're
on.

## Two layers

| Layer | What | Toolset |
|---|---|---|
| **LAYER-1 — CRD's own chrome** | Options panel, dialogs, Disconnect, Full-screen, "Synchronize clipboard", "Press Ctrl + Alt + Del", "Press PrtScr" | Real page DOM: `take_snapshot` + `click({uid})`, **match by LABEL text** (uids are per-snapshot — never hardcode). a11y `ignored`? → coordinate fallback. See `commands/windows/crd.md`. |
| **LAYER-2 — the Windows desktop** | Everything inside the remote screen | Opaque canvas: coordinate `click_at` + `press_key`/`type_text`; read state ONLY from screenshots. See `commands/windows/act.md`. |

## Capability matrix

### Vision (LAYER-2) — always on

| Want to do | Tool |
|---|---|
| See the Windows screen | `mcp.take_screenshot()` |
| Wake a black screen | `mcp.press_key("Shift")` (Shift only — no char input) |

### Keyboard / keys (LAYER-2)

| Want to do | Channel |
|---|---|
| Enter / Tab / Esc / Backspace / arrows / Page* / Home / End | `mcp.press_key("<key>")` |
| App-level combo (Ctrl+V/C/A) | `mcp.press_key("Control+<x>")` — forwards fine |
| System combo (Win, Alt+Tab, Ctrl+Alt+Del) | **swallowed by CRD** — use click niceties / CRD DOM buttons instead |

### Text (LAYER-2)

| Want to do | Channel |
|---|---|
| Pure lowercase + unshifted | `mcp.type_text("<text>")` (fast path) |
| Anything with a capital or shifted symbol | `send_text()` per-char shift-map (see Coordinate & text math below) |
| Unicode / emoji / bulk | v2 (clipboard/file) — out of scope v1 |

### Mouse (LAYER-2, direct CDP)

| Want to do | Channel |
|---|---|
| Left-click a host pixel | rect helper → `mcp.click_at({x,y})` |
| Double-click | `mcp.click_at({x,y, dblClick:true})` |
| Right-click | `mcp.press_key("Shift+F10")` — opens at the **focused element**, not a pixel (NO right-click param on `click_at`). To target an element, `click_at` it first to focus (a real click — screenshot-verify, obey modal/PHI rules), then `Shift+F10`. |
| Scroll | PageDown/Arrow with pane focus, or click scrollbar arrows; thumb-drag experimental |
| Drag | `mcp.drag(...)`, same canvas-rect CSS-px space — **UNVERIFIED**, smoke-test first |

### CRD UI (LAYER-1)

| Want to do | Channel |
|---|---|
| Disconnect / Full-screen / clipboard toggle / Ctrl+Alt+Del / PrtScr | `take_snapshot` → `click({uid})` by **label** |

### Niceties (clicks, not system keys — LAYER-2)

| Want to do | Channel |
|---|---|
| Launch an app | click Start orb → `send_text("<app>")` → `press_key("Enter")` |
| Switch window | click the app's taskbar icon |

### Lifecycle

| Want to do | Sub-command |
|---|---|
| Bind / resume | `/windows connect` |
| LAYER-2 desktop actions | `/windows act <…>` |
| LAYER-1 CRD UI / status / disconnect | `/windows crd <…>` |

## Coordinate math (both spaces)

`getBoundingClientRect()` and `click_at` are **BOTH CSS px** → rect-derived
coords are **NOT** ÷DPR. Only a target eyeballed off a raw screenshot is ÷DPR
(screenshots save at `innerW × DPR`), and that path must also subtract the
canvas letterbox offset (`rect.x`/`rect.y`).

**The rect helper** (defined once in `act.md`; the dispatcher embeds a copy)
returns `{ dpr, rect:{x,y,w,h}, hostW, hostH }` — note `{x,y,w,h}` is returned
EXPLICITLY because a raw DOMRect exposes `.width`/`.height`, not `.w`/`.h`. The
canvas is picked as the **largest by rendered area** (`w*h`), with **NO 1920
hard floor**; if none is found the helper returns `{error}` and you STOP (don't
guess a canvas).

```
# Host pixel (hx,hy) → click_at (CSS px, no ÷DPR):
clickX = rect.x + hx * (rect.w / hostW)
clickY = rect.y + hy * (rect.h / hostH)

# Raw-screenshot pixel → host pixel (÷DPR + subtract letterbox), THEN the above:
hx = (shot_px_x/dpr - rect.x) * (hostW / rect.w)
hy = (shot_px_y/dpr - rect.y) * (hostH / rect.h)
```

**Worked letterbox example** (observed live with "Scale to fit", innerW=1710):
the canvas rect was `x0 y12 w1710 h962` and the host streams `1920×1080`. To
click host pixel `(960, 540)` (screen center):

```
clickX = 0   + 960*(1710/1920) = 855.0
clickY = 12  + 540*(962/1080)  = 12 + 481.0 = 493.0
mcp.click_at({ x: 855.0, y: 493.0 })
```

Naive "fraction of viewport" math would put y at `540*(982/1080)≈491` from the
top of the *page*, ignoring the 12px letterbox — wrong. **Always use the canvas
rect**, and **re-read it before every click** (the window resizes mid-session —
verified: 980→1710 innerW silently broke reused coords and cost missed clicks).

## Text math (the shift-map sender)

```
SAFE  = set("abcdefghijklmnopqrstuvwxyz0123456789 -_=/.,;:'`")   # type_text-safe
SHIFT = {'!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0',
         '_':'-','+':'=','{':'[','}':']','|':'\\',':':';','"':"'",'<':',','>':'.','?':'/','~':'`'}
def send_text(s):
  if every ch in s in SAFE and s has NO uppercase: mcp.type_text(s)
  else:
    for ch in s:
      if 'A'<=ch<='Z':  mcp.press_key("Shift+"+ch.lower())
      elif ch in SHIFT: mcp.press_key("Shift+"+SHIFT[ch])
      elif ch==' ':     mcp.type_text(" ")
      else:             mcp.type_text(ch)
```

`type_text` strips Shift (verified: `Hello, World! @#$(test)_+` →
`hello, world1 2349test0-+`). `press_key("Shift+<base>")` holds it (verified
`Shift+h`,`i`,`Shift+5` → `Hi%`).

## Gotchas

| Gotcha | Reality | What to do |
|---|---|---|
| Shift strip | `type_text` drops Shift; capitals lowercased, shifted symbols → unshifted | route via `send_text` shift-map for any capital/symbol |
| Window resizes mid-flow | reused coords silently miss | re-read the canvas rect before EVERY click; never reuse |
| Modal blocks parent clicks | Win32 modal eats clicks behind it; screenshot looks unchanged | modal-recovery rule: act on the modal or Esc; don't re-click same coords |
| System keys swallowed | Win/Alt+Tab/Ctrl+Alt+Del don't forward | clicks (Start orb, taskbar icon) + CRD DOM buttons |
| No right-click param | `click_at` schema is `{x,y,dblClick,includeSnapshot}` | `press_key("Shift+F10")` |
| Two CRD sessions | Mac + Windows, same URL prefix | bind by title `OpenDentalDev1` + taskbar screenshot; STOP if ambiguous |
| Frozen background tab | one discarded tab freezes `list_pages` itself | treat a hang as the `/devtools` trigger (user-gated) |
| No mouse-wheel tool | — | scroll via PageDown/Arrow or scrollbar-arrow clicks |
| `drag` unverified | not tested against this host | smoke-test first session; it doubles as scrollbar-thumb |

## Verified vs Assumed matrix

| Capability | Status | Notes |
|---|---|---|
| `take_screenshot` eyes | ✅ verified | crisp |
| `click_at` reaches host | ✅ verified | toggled a checkbox, focused a field — re-check first session (macmini conflict) |
| Canvas-rect coord mapping | ✅ verified | `getBoundingClientRect`, both-CSS-px, no ÷DPR |
| `type_text` lowercase/unshifted | ✅ verified | `30`→`309` |
| `press_key("Shift+<base>")` for capitals/symbols | ⚠️ partial | only `Hi%` (3 chars) live-verified — smoke-test the FULL map |
| `press_key` single keys / Ctrl combos | ✅ verified | Enter/Esc/Backspace/Control+v |
| System keys (Win/Alt+Tab) | ✅ verified swallowed | use clicks instead |
| CRD uid-by-label (LAYER-1) | ✅ verified this session | closed a dialog + panel by uid — but macmini saw `ignored`; probe + fall back |
| `drag` / scrollbar-thumb | ❌ unverified | smoke-test first session |
| Clipboard bridge (pbcopy→Ctrl+V) | ❌ does not bridge under CDP | needs OS-foreground focus; v2 |

## Safety

You are driving a **real, logged-in Windows machine** through the user's **full
real Chrome profile** — not a sandbox.

- **OpenDental = live PHI by default.** Do NOT infer Demo-vs-live from a
  screenshot. Treat all patient data as HIPAA-sensitive. Only practice freely
  after the user explicitly confirms the Demo DB this session.
- **Your full Chrome is also reachable.** The MCP attaches to the user's main
  Chrome on port 9222 — every other tab (inbox, calendar, docs), same logins,
  cookies, autofill, extensions. Do NOT browse / read other tabs, email, or DMs
  for "context." Only navigate outside the Windows CRD tab when the user
  explicitly asks.
- **Never** click Buy / Send / Pay / Confirm / Delete, submit forms, approve
  OAuth / 2FA, change settings, or dismiss security warnings — without explicit
  user instruction.
- **Never type into or approve Windows UAC / sign-in / credential prompts**, and
  never type a CRD PIN. Surface them to the user (the Windows analog of
  macmini's OAuth prohibition).
- **Windows session only** — never select / `bringToFront` / act on the Mac CRD
  tab. STOP if you can't tell which is which.
- **Screenshot before AND after every action**; re-read the canvas rect before
  every click; never reuse coords.
- **Connection self-heal is user-gated** — `/devtools`, then wait for the user
  to `/mcp` reconnect; no auto-retry.
