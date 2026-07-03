---
description: Drive a remote Mac mini through Chrome Remote Desktop via the chrome-devtools MCP. Self-resolving — invoke with no sub-command or just reference /macmini in plain English; the agent pre-flights, binds the Mac CRD tab by title, and infers the right action from context. No gist, no cliclick, no on-host agent, no calibration — clicks are direct CDP click_at into the CRD canvas.
argument-hint: "[free-form request, e.g. \"open chrome and check my email\"]"
---

# /macmini — Mac mini Remote

> **READ THIS FIRST — if you do nothing else, read this section.**
>
> You are driving a **Mac mini (macOS)** through Chrome Remote Desktop. The
> CRD tab in the user's real-profile Chrome is a live feed of the mini's
> desktop, rendered into an opaque `<canvas>`.
>
> - **Your eyes** are `mcp.take_screenshot()` on the CRD page.
> - **Your hands are direct CDP input** — `mcp.click_at({x,y})`,
>   `mcp.type_text(...)`, `mcp.press_key(...)`. These reach the macOS host
>   natively (re-confirmed live 2026-06-01: Apple-menu click + shift-map +
>   `Cmd+Space`). There is NO gist, NO cliclick, NO on-host agent, NO
>   calibration file, NO Terminal-foreground dance. (See "How this differs from
>   the OLD /macmini" below — this is a clean break.)
> - **Two interaction layers, two toolsets — always know which one you're on:**
>   - **LAYER-1 — CRD's own chrome** (options panel, Disconnect, Full-screen,
>     "Synchronize clipboard", "Send system keys"). This is real page DOM →
>     `mcp.take_snapshot()` + `mcp.click({uid})`, **matching the control by its
>     LABEL text each snapshot**. ⚠️ On macOS, CRD's a11y tree usually exposes
>     ONLY the `Desktop` textbox — uid mode is **likely unavailable**; default
>     LAYER-1 to coordinate clicks / user action (probe + fall back — see
>     `crd.md`). This is the OPPOSITE of `/windows`.
>   - **LAYER-2 — the macOS desktop itself** is the opaque `<canvas>` →
>     coordinate `mcp.click_at()` + `press_key`/`type_text`, reading state
>     ONLY from screenshots.
> - **Bind to the Mac session by TAB TITLE first** (`plan2bid-minim4`,
>   configurable `CRD_DEVICE_NAME`). NEVER `select_page`/`bringToFront` a tab
>   that might be the **Windows** CRD session (the `/windows` target,
>   `OpenDentalDev1`). Two CRD sessions exist; both are
>   `remotedesktop.google.com/access/session/...` URLs. If you cannot tell which
>   tab is the Mac → **STOP and ask.**
> - **Coordinates are derived per click, never reused.** Re-read `crdMeta()`
>   before every click (the window can resize mid-flow and silently break reused
>   coords). Screenshot before AND after.
>
> The load-bearing snippets — the `crdMeta`/`crdMap` precision helpers (loupe +
> crosshair), the capital/symbol shift-map, and the title-first pre-flight — are
> **embedded inline below** so this file is self-contained. Depth refs (dotfiles
> only, not on the deployed path): `skills/macmini/SKILL.md`, `ONBOARDING.md`,
> `docs/FINDINGS-2026-06-01.md`, `../windows/docs/FINDINGS-2026-07-02-precision.md`.

## How this differs from the OLD gist-era /macmini (read if you knew it)

The old `/macmini` believed CRD's `isTrusted` gate **blocked** synthetic CDP
clicks on the macOS host, so it routed every click through `cliclick` on the
mini's own OS, delivered via a `gh gist` transport, and every capital/symbol
through that same gist channel. **That premise is wrong (or stale) for this
setup** — direct `click_at` reaches the host (verified 2026-06-01). The whole
gist/cliclick edifice is gone. **Negate every old mechanic:**

| OLD `/macmini` (gist era) | NEW `/macmini` (direct CDP) |
|---|---|
| Hands = `cliclick` on the mini via `gh gist` transport (to dodge `isTrusted`) | Hands = **direct CDP `mcp.click_at({x,y})`** into the CRD canvas — verified reaching the macOS host. NO gist, NO cliclick, NO GitHub. |
| Arbitrary text = `gh gist` paste channel (`/macmini paste`) | Arbitrary text = **per-char `press_key("Shift+<base>")`** with a US shift-map (embedded below). NO gist. |
| Per-mini `/macmini measure` calibration file | **No calibration** — map via the live canvas rect (`crdMeta`/`crdMap`, embedded below). |
| Terminal-foreground "dance" + `run.sh` + on-host cliclick | **None.** Click the pixel, screenshot to verify. |
| `--secure`/`read -s` credential injection over gist | To put a credential on the mini, the **user types it via `read -s` directly in the mini Terminal**. The agent never carries/echoes it, never types a secret char-by-char through the canvas. (Story preserved — only the gist transport is gone.) |
| AppleScript via `/macmini script` (gist-delivered) | Out of scope v1 (gist removed). If a genuine AppleScript need resurfaces it's a separate, opt-in channel — not this skill. |

**macOS bonus over `/windows`:** Cmd system keys **forward** here (verified
`Cmd+Space`), so app-launch / window-switch / copy-paste can use real shortcuts
— **but only when CRD's "Send system keys" toggle is ON** (a one-time USER
gesture; see `setup.md`). Every Cmd nicety has a **click fallback**; if a Cmd
combo does nothing, that toggle is off → surface to the user.

## Self-resolution

When the user invokes `/macmini` (with or without arguments) **or references the
Mac mini in plain English** ("on the mac mini do X", "send X to the mini", "use
/macmini to do Z"):

1. **Pre-flight bind (title-first).** `mcp.list_pages()`. Filter to CRD pages
   (`url` contains `https://remotedesktop.google.com/access/session/`).
   - **Title match:** the CRD page whose `title` contains `DEVICE_NAME` (default
     `"plan2bid-minim4"` — configurable) is the Mac tab →
     `mcp.select_page({pageId, bringToFront:true})`.
   - **No title match, exactly one CRD tab — NOT trusted yet.** Select it
     **read-only** first: `mcp.select_page({pageId, bringToFront:false})` (sets
     it as screenshot context WITHOUT foregrounding it). Screenshot. Only if it
     shows a **macOS menu bar (top) + Dock** do you then
     `mcp.select_page({pageId, bringToFront:true})` and proceed. If it shows a
     **Windows 11 taskbar / Start orb**, you read the **Windows** tab → STOP,
     never foreground it, never input, ask the user.
   - **No title match, multiple CRD tabs → STOP and ask** which is the Mac.
     NEVER `bringToFront` a tab that might be the Windows session.
   - **If `list_pages` HANGS or errors** (a frozen/discarded background tab can
     freeze the enumeration itself) → run `/devtools` and hand off (see Hard
     rules). Do NOT auto-retry.
2. **Overlay / lock check FIRST — before any keypress.** `mcp.take_screenshot()`.
   If you see a **"Reconnect" / "Session ended"** overlay, a **CRD PIN** prompt,
   or a **macOS sign-in / lock** screen → surface to the user and STOP; PIN /
   sign-in is user-only. **Press NOTHING** — even `Shift` wakes a macOS lock
   screen and lands focus on its password box.
3. **Wake only a genuine idle/blank desktop.** Only after step 2 has ruled out a
   lock / sign-in / overlay: if the canvas is black/blank,
   `mcp.press_key("Shift")` to wake — **Shift only** (no character input; never
   Enter/Space/letters). If it's black and you cannot tell idle from locked,
   surface to the user instead of pressing anything.
4. **Infer the action** from the capability matrix below. Re-read `crdMeta()`
   before any click (see the Precision targeting section).

## Precision targeting (LAYER-2)

The ONE way to turn "a target on the mini's screen" into a reliable `click_at`.
`crdMap` supersedes the old canvas-rect helper — one callable for host / normalized /
screenshot space. `getBoundingClientRect()` and `click_at` are **BOTH CSS px**; the
transform never divides host/CSS by DPR — only the **screenshot** path does (a native
screenshot is innerW×DPR = DEVICE px). (Verified rect on this mini:
`{x:9.66, y:0, w:1690.66, h:951}`, host streams `1920×1080` with a small horizontal
letterbox.) The loupe was proven on the Windows twin (Demo DB, 96% / 26 trials); on
macOS **re-run the readback probe first** (see the macOS deltas below).

**Inject via `mcp.evaluate_script`. It is STATELESS for definitions** — each call
re-includes the WHOLE block below, then `return` the one call you need, e.g.
`() => { /* whole block */ ; return crdLoupe(277,47); }`. Overlay DOM persists across
calls; function defs do not. This block is byte-identical to `skills/_shared/crd-precision.js`
and to the `/windows` copy (single source, embedded twice — re-embed both on any edit).

```js
// Select the remote CRD canvas: largest by RENDERED area; decoys render 0x0 (area>40000 drops them).
function _crdPickCanvas() {
  return [...document.querySelectorAll('canvas')]
    .map(e => { const r = e.getBoundingClientRect();
                return { e, x:r.x, y:r.y, w:r.width, h:r.height, bw:e.width, bh:e.height }; })
    .filter(o => o.w * o.h > 40000)          // rendered area; decoys render 0x0
    .sort((a, b) => b.w * b.h - a.w * a.h)[0];
}

// Live geometry. EXPLICIT flat shape — DOMRect exposes .width/.height, not .w/.h. sx/sy = CSS-px per host-px.
function crdMeta() {
  const c = _crdPickCanvas();
  if (!c) return { error: 'no remote canvas found' };
  return {
    rectX: c.x, rectY: c.y, rectW: c.w, rectH: c.h,   // CSS-px canvas rect
    hostW: c.bw, hostH: c.bh,                          // backing store == host stream res
    dpr: window.devicePixelRatio,
    sx: c.w / c.bw, sy: c.h / c.bh                     // CSS-px per host-px
  };
}

// Map host | norm | shot -> {clickX,clickY,host}. SHOT space is DEVICE px -> /dpr. Supersedes the rect helper.
function crdMap(target, meta) {
  const m = meta || crdMeta();
  if (m.error) return m;
  let hx, hy;
  if (target.host)      { hx = target.host.x;             hy = target.host.y; }
  else if (target.norm) { hx = target.norm.x * m.hostW;   hy = target.norm.y * m.hostH; }
  else if (target.shot) { hx = (target.shot.x / m.dpr - m.rectX) / m.sx;   // SHOT = DEVICE px
                          hy = (target.shot.y / m.dpr - m.rectY) / m.sy; }
  else return { error: 'target needs {host}|{norm}|{shot}' };
  return { clickX: m.rectX + hx * m.sx, clickY: m.rectY + hy * m.sy, host: { x: hx, y: hy } };
}

// Magnifier overlay (id __crd_loupe__), imageSmoothing OFF, returns its own src/overlay rects (no hand math).
// Placed top-right, below the CRD toolbar occlusion band. sub-20px: half=40,zoom=8; larger: half=90,zoom=5.
function crdLoupe(cx, cy, half, zoom) {
  if (half == null) half = 40;
  if (zoom == null) zoom = 8;
  const c = _crdPickCanvas();
  if (!c) return { error: 'no remote canvas found' };
  const srcX = cx - half, srcY = cy - half, srcW = 2 * half, srcH = 2 * half;
  const ovW = srcW * zoom, ovH = srcH * zoom;
  const ovX = Math.max(10, window.innerWidth - ovW - 10);   // top-RIGHT
  const ovY = 70;                                           // clear of the top ~60px band
  const old = document.getElementById('__crd_loupe__');
  if (old) old.remove();
  const cv = document.createElement('canvas');
  cv.id = '__crd_loupe__';
  cv.width = ovW; cv.height = ovH;
  Object.assign(cv.style, {
    position: 'fixed', left: ovX + 'px', top: ovY + 'px',
    width: ovW + 'px', height: ovH + 'px',
    zIndex: '2147483647', pointerEvents: 'none',
    border: '2px solid #ff2d55', boxShadow: '0 0 0 1px #000'
  });
  const ctx = cv.getContext('2d');
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(c.e, srcX, srcY, srcW, srcH, 0, 0, ovW, ovH);
  document.body.appendChild(cv);
  return { srcX, srcY, srcW, srcH, ovX, ovY, ovW, ovH };
}

// Inverse-map an in-loupe screenshot pixel (DEVICE px) back to host space.
function crdLoupeUnmap(px, py, loupe, dpr) {
  const cssX = px / dpr, cssY = py / dpr;                 // device px -> CSS px
  const fx = (cssX - loupe.ovX) / loupe.ovW;             // fraction across the overlay
  const fy = (cssY - loupe.ovY) / loupe.ovH;
  return { x: loupe.srcX + fx * loupe.srcW, y: loupe.srcY + fy * loupe.srcH };
}

// Crosshair overlay (id __crd_cross__) at a HOST point — pure-DOM confirm BEFORE any click.
function crdCrosshair(hx, hy) {
  const m = crdMeta();
  if (m.error) return m;
  const clickX = m.rectX + hx * m.sx, clickY = m.rectY + hy * m.sy;
  const old = document.getElementById('__crd_cross__');
  if (old) old.remove();
  const bar = (w, h, l, t, color) => {
    const d = document.createElement('div');
    Object.assign(d.style, {
      position: 'fixed', left: l + 'px', top: t + 'px', width: w + 'px', height: h + 'px',
      background: color, zIndex: '2147483647', pointerEvents: 'none'
    });
    return d;
  };
  const box = document.createElement('div');
  box.id = '__crd_cross__';
  Object.assign(box.style, { position: 'fixed', left: '0', top: '0', zIndex: '2147483647', pointerEvents: 'none' });
  const arm = 12;
  box.appendChild(bar(2 * arm, 1, clickX - arm, clickY, '#ff2d55'));   // horizontal arm
  box.appendChild(bar(1, 2 * arm, clickX, clickY - arm, '#ff2d55'));   // vertical arm
  box.appendChild(bar(3, 3, clickX - 1, clickY - 1, '#00e5ff'));       // center dot
  document.body.appendChild(box);
  return { clickX, clickY };
}

// Remove both overlays. Always call before click_at.
function crdClearOverlays() {
  const l = document.getElementById('__crd_loupe__'); if (l) l.remove();
  const x = document.getElementById('__crd_cross__'); if (x) x.remove();
  return { cleared: true };
}
```

### Per-target procedure

**(a) Keyboard-first is the DEFAULT.** If the target is reachable by Tab / a menu-bar
accelerator / type-to-search / a Cmd shortcut (when "Send system keys" is on), use a
keystroke — deterministic and no stray-click risk. Reserve the pixel path for genuinely
**canvas-only** targets.

**(b) Canvas-only targets — the closed loop (proven 96% on the Windows twin):**
1. **Coarse-locate.** Estimate the host point from a screenshot via
   `crdMap({shot:{x,y}})` (screenshot px are DEVICE px), or from a known anchor.
2. **Loupe.** `crdLoupe(hx,hy)` → screenshot → read the exact target pixel in the
   magnified overlay → `crdLoupeUnmap(px,py,loupe,dpr)` for the refined host point.
3. **Crosshair-confirm.** `crdCrosshair(hx,hy)` → screenshot → verify the center dot sits
   on the target BEFORE committing. Nudge and re-confirm on a miss (≤2 corrections).
4. **Clear.** `crdClearOverlays()`.
5. **Click.** `click_at({x:clickX, y:clickY})` from `crdMap`.
6. **Verify the SPECIFIC reaction** AND no unintended change.

### Grid-cell refinement

Do NOT eyeball a lookalike cell in a dense grid — anchor row/column spacing off a known
highlighted/labeled reference cell in the same grid, measure the pitch once (host-px per
row/column), and index from the anchor. On the Windows twin, index-from-anchor hit 12/12
with 0 corrections after calibration where coarse loupe-only reads missed a 19px row.

### Tuning defaults

- **Loupe:** sub-20px targets → `half=40, zoom=8`; larger targets → `half=90, zoom=5`.
- **Corrections budget:** ≤2 crosshair nudges; if still off, re-loupe rather than thrash.

### macOS deltas (vs the Windows twin)

- **Re-run the readback probe on the mac before trusting the loupe.** The loupe relies on
  a same-origin `drawImage`+`getImageData` readback of the remote canvas returning
  non-black; that was proven on Windows CRD, NOT yet on macOS CRD. First session on the
  mini: `crdLoupe` a known region, screenshot, and confirm the overlay shows the crisp
  magnified host content (not a black square) before relying on it.
- **CRD auto-hiding toolbar occlusion (preserved caveat).** The toolbar can sit over the
  top ~60px / bottom ~30px of the canvas. `crdLoupe` is anchored at `ovY=70` to stay clear
  of the top band; when placing a crosshair or reading near those bands, occlusion-check
  (see `act.md` "canvas-click").
- **No right-click** — `Shift+F10` is Windows-only; use the app's menu bar. a11y exposes
  only `Desktop` (LAYER-1 stays coordinate/user fallback) — unchanged by this section.

### Gotchas (fold into every run)

- **Trusted Types enforced** — `element.innerHTML = …` THROWS on the CRD page. The
  overlays use `createElement`/`appendChild`/`.style` only; never add innerHTML.
- **`hover` is uid-only** — no coordinate hover, so no streamed cursor to servo against.
  Confirm with the **crosshair overlay**, not cursor-servoing.
- **`take_screenshot` may return a filePath** (temp file instead of inline when the page
  is bound read-only) — Read the file. Both paths occur; handle both.
- **Re-read `crdMeta()` before the NEXT click** — the window can resize mid-flow.

## EMBEDDED HELPER — type anything (capitals + symbols) via the shift-map

`type_text` strips Shift (capitals lowercased, shifted symbols → unshifted).
`press_key("Shift+<base>")` HOLDS the modifier and forwards it (verified live
2026-06-01: `Shift+a`,`z`,`Shift+5`,`Shift+\`,`Shift+'`,`Shift+\`` → `Az%|"~` —
capital + the risky `|`/`"`/`~` all correct). Route per character:

```
SAFE  = set("abcdefghijklmnopqrstuvwxyz0123456789 -=/.,;'`")   # type_text-safe: lowercase + unshifted
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

## EMBEDDED — title-first bind pre-flight (never touch the Windows tab)

```
DEVICE_NAME = "plan2bid-minim4"   # configurable: the Mac mini's CRD tab title
pages = mcp.list_pages()          # if this HANGS/errors → /devtools handoff (frozen-tab)
crd   = [p for p in pages if "remotedesktop.google.com/access/session/" in p.url]
mac   = first p in crd where DEVICE_NAME in p.title
if mac:
    mcp.select_page({pageId: mac.id, bringToFront: true})
    screenshot; confirm macOS menu bar (top) + Dock
elif len(crd) == 1:
    # NOT trusted yet — read-only select (does NOT foreground) to screenshot-confirm
    mcp.select_page({pageId: crd[0].id, bringToFront: false})
    screenshot
    if macOS menu bar/Dock:  mcp.select_page({pageId: crd[0].id, bringToFront: true})  # now bind
    else (Windows taskbar/Start orb):  STOP — that's the Windows tab; never foreground/input
else:
    STOP — ask the user which tab is the Mac (NEVER bringToFront a maybe-Windows tab)
# Lock/overlay check BEFORE any keypress (even Shift wakes a macOS lock screen):
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
| See the mini's screen | `mcp.take_screenshot()` |
| Wait for something to render | screenshot + brief wait + screenshot |
| Wake a black screen | `mcp.press_key("Shift")` (Shift only — no char input) |

### Keyboard / single keys — LAYER-2

| Want to do | Channel |
|---|---|
| Press Enter / Tab / Esc / Backspace / arrows / Page* / Home / End | `mcp.press_key("<key>")` |
| App-level shortcut (Cmd+C/V/A) | `mcp.press_key("Meta+<x>")` — forwards IF "Send system keys" is ON. (Cmd+W/Cmd+Q are destructive — see hazard note below, not for casual use.) |
| System combo (Cmd+Space, Cmd+Tab, Cmd+H) | `mcp.press_key("Meta+Space")` / `"Meta+Tab"` — **forwards on macOS IF "Send system keys" is ON** (a one-time USER toggle). If nothing happens → toggle is off → use the click fallback (Dock icon / Apple menu) and surface to the user. |

> ⚠️ **macOS destructive-shortcut hazard:** never fire `Meta+q` / `Meta+w` /
> `Meta+Delete` except as explicitly-authorized recovery, and screenshot-verify
> which app has focus FIRST.

### Text — LAYER-2

| Want to do | Channel |
|---|---|
| Type pure lowercase + unshifted | `mcp.type_text("<text>")` (fast path) |
| Type ANYTHING with a capital or shifted symbol | `send_text()` per-char shift-map (embedded above) |
| Unicode / emoji / bulk paste | v2 (clipboard/file) — out of scope v1 |
| Inject a credential | **user types it via `read -s` directly in the mini Terminal** — agent never carries/echoes it (see SKILL.md / FINDINGS) |

### Mouse — LAYER-2 (direct CDP, via `crdMap` / the Precision targeting section)

| Want to do | Channel |
|---|---|
| Left-click a host pixel | `crdMap` → `mcp.click_at({x,y})` (✅ verified on large targets) |
| Precise-click a small canvas-only target (12-20px) | loupe → crosshair-confirm → clear → `click_at` (see Precision targeting; re-run the readback probe on the mac first) |
| Double-click | `mcp.click_at({x,y, dblClick:true})` — ⚠️ **UNVERIFIED** on small targets (a ~50px Finder icon dblClick missed historically); smoke-test |
| Right-click | **documented v1 gap.** No CDP path on macOS — `click_at` has no button/modifier param and there is NO macOS context-menu key (`Shift+F10` is Windows-only — do NOT use it here). **Substitute: use the app's menu bar (top, `click_at`-reachable).** |
| Scroll | **KEYBOARD only** — `PageDown`/`PageUp`/`Space`/`ArrowDown`, `Meta+ArrowDown/Up` to jump. **NEVER `drag` to scroll** (macOS reads it as text-selection). |
| Drag | `mcp.drag(...)` in the `crdMap` CSS-px space — ⚠️ **UNVERIFIED**; smoke-test first session |

### CRD UI — LAYER-1 (page DOM)

| Want to do | Channel |
|---|---|
| Disconnect / Full-screen / clipboard toggle / Send-system-keys toggle | `take_snapshot` → if labeled uids exist, `click({uid})` by label; **on macOS the a11y tree usually shows only `Desktop`** → fall back to coordinate `click_at` on the panel, or ask the user. See `crd.md`. |

### Niceties (Cmd-forward, WITH click fallbacks) — LAYER-2

| Want to do | Channel (Cmd) | Click fallback |
|---|---|---|
| Launch an app | `Meta+Space` (Spotlight) → screenshot-confirm Spotlight opened ON THE MINI → `send_text("<app>")` → screenshot-confirm the top result matches → `Enter` | click the **Dock icon** (or Apple menu → app) |
| Switch window | `Meta+Tab` (Cmd+Tab) | click the app's **Dock icon** |
| Copy / paste | `Meta+c` / `Meta+v` | (none; ASCII typing covers most cases) |

> **Spotlight guardrails (load-bearing):** between `Meta+Space` and
> `send_text(app)`, screenshot-confirm Spotlight opened **on the mini canvas**
> (not dev-side Chrome). Before `Enter`, screenshot-confirm the top result row
> **text matches the intended app** — fuzzy-match + Enter can launch the WRONG
> app (destructive on a real machine). If `Meta+Space` opens nothing or
> dev-side Spotlight, the "Send system keys" toggle is off OR Spotlight is
> remapped (Raycast/Alfred) → use the Dock fallback and surface to the user.

### Lifecycle

| Want to do | Sub-command |
|---|---|
| Bind / resume the session | `/macmini connect` |
| LAYER-2 desktop actions | `/macmini act <…>` |
| LAYER-1 CRD UI / status / disconnect | `/macmini crd <…>` |
| First-time setup | `/macmini setup` |

## Hard rules / safety

- **Mac session only.** Match title `plan2bid-minim4` + confirm the macOS menu
  bar (top) / Dock; never select / `bringToFront` / act on the **Windows** CRD
  tab (`OpenDentalDev1`); **STOP if ambiguous.** (Symmetric to `/windows` never
  touching the Mac.)
- **Screenshot before AND after every `click_at`. Re-read the canvas rect before
  each click. Never reuse coords across screenshots** — the window can resize
  mid-flow and silently break reused coords.
- **Modal-recovery rule:** screenshot before+after; if the screen is unchanged
  AND a dialog is visible, the click hit a modal-blocked region — act on the
  modal or press `Esc`; do NOT silently re-click the same coords.
- **Verify the EXPECTED state change after any authorized state-changing click**
  (Send / Confirm / Save / Delete, form submits). The "after" screenshot must
  show the *specific* intended change — and no unintended one. "The screen
  changed" is NOT proof the right thing happened.
- **Real logged-in machine + full real Chrome profile reachable.** Don't click
  Buy / Send / Pay / Confirm / Delete, change settings, approve OAuth/2FA,
  dismiss security warnings, or browse / read other Chrome tabs / email / DMs —
  without explicit user instruction.
- **macOS permission dialogs are user-only.** Never type into or approve a macOS
  **auth / keychain / "app wants to control your computer" / "allow
  accessibility / screen-recording"** / Gatekeeper / notification prompt — and
  never type a CRD PIN. These can appear (esp. on first Spotlight launch) and
  may hide BEHIND the foreground app — surface to the user; don't blind-approve.
- **Lock/sign-in/overlay check BEFORE any wake key; wake = `Shift` only.**
- **Connection self-heal is user-gated.** If a chrome-devtools call hangs/errors
  or `list_pages` returns empty, run `/devtools`, then **wait for the user to
  `/mcp` reconnect**. No auto-retry loop. (The frozen-tab hang freezes
  `list_pages` itself, so treat a hang — not just an empty result — as the
  `/devtools` trigger.)

## First-session smoke tests (run once, on a safe scratch surface)

1. **click_at reaches host** — click the **Apple menu** (host ~15,12); confirm
   the dropdown (About This Mac / System Settings / Sleep / …); `Escape`.
   (Covers the historical "click_at deprecated/unreliable" conflict from the
   gist era — verified working 2026-06-01, but re-check.)
2. **Full shift-map** — `send_text("!@#$%^&*()_+{}|:\"<>?~ Az")` into Spotlight;
   screenshot every char; `Escape`. (Only `Az%|"~` was live-verified.)
3. **Cmd forwarding** — `Meta+Space` opens Spotlight ON THE MINI (verified);
   confirms the launch/switch/copy-paste niceties (and that "Send system keys"
   is on).
4. **CRD a11y** — `take_snapshot`; do CRD controls expose labeled uids, or only
   `Desktop`? On macOS, expect **only `Desktop`** → LAYER-1 uses the coordinate
   / user fallback (see `crd.md`).
5. **UNVERIFIED interactions** — if a flow needs them, smoke-test first:
   small-target double-click, `drag`. Right-click has no CDP path (use the menu
   bar). Mark results in your reasoning.

## Sub-commands (for explicit invocation)

| Sub-command | Purpose |
|---|---|
| `/macmini connect` | Bind the Mac session by title; PIN hand-off (user-only); reconnect-overlay; Shift-wake after a lock check; canvas mount signal. |
| `/macmini act <action>` | LAYER-2 desktop: `click` / `double` / `type` / `key` / `scroll` / `launch` / `switch` — all via the one rect helper. (Right-click = documented gap.) |
| `/macmini crd <action>` | LAYER-1 CRD UI (coordinate/user fallback on macOS), plus `disconnect` and `status`. |
| `/macmini setup` | One-time: MCP via `/devtools`, the two CRD side-panel toggles, optional `CRD_DEVICE_NAME`, first connect. |

> **Delegation posture:** inline vision is the point of this skill, so reading
> screenshots and acting on them stays in-thread. Heavy page enumeration (a big
> `list_pages`, a deep `take_snapshot` dump) may be delegated, but never split a
> click→screenshot→verify loop across agents. For many sequential mini-LOCAL
> actions (sudo, multi-file, git), prefer the **mini-Claude delegation** recipe
> in `skills/macmini/SKILL.md` (`claude --dangerously-skip-permissions` on the
> mini — needs only `type_text`+`press_key`, no gist).

## See also (dotfiles only — NOT on the deployed `~/.claude/` path)

- Runtime reference: [`skills/macmini/SKILL.md`](../skills/macmini/SKILL.md)
- Cold-start read order + invariants: [`skills/macmini/ONBOARDING.md`](../skills/macmini/ONBOARDING.md)
- Verified-vs-UNVERIFIED reality + the gist-era history: [`skills/macmini/docs/FINDINGS-2026-06-01.md`](../skills/macmini/docs/FINDINGS-2026-06-01.md)
- Sibling skill (direct-CDP twin): [`commands/windows.md`](./windows.md)
- Connection self-heal: `/devtools`
