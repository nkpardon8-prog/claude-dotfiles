# /windows act — LAYER-2 Windows desktop actions (direct CDP)

LAYER-2 is the **Windows desktop itself**, rendered into an opaque `<canvas>`.
You drive it with coordinate `mcp.click_at()` + `press_key`/`type_text`, and you
read state ONLY from `mcp.take_screenshot()`. (For CRD's own UI — Disconnect,
panel, clipboard toggle, Ctrl+Alt+Del — that's LAYER-1, see `crd.md`.)

Every coordinate action runs through the ONE rect helper defined here. Nothing
else duplicates it.

## THE ONE rect helper (defined once, here)

`getBoundingClientRect()` and `click_at` are **BOTH CSS px**, so rect-derived
coords are **NOT** divided by DPR. Returns `{x,y,w,h}` EXPLICITLY (a raw DOMRect
has `.width`/`.height`, not `.w`/`.h`).

```js
// mcp.evaluate_script({ function: "() => { ... }" })   ← named-arg call shape
() => {
  const cs = [...document.querySelectorAll('canvas')]
    .map(e => { const r = e.getBoundingClientRect();
                return { x:r.x, y:r.y, w:r.width, h:r.height, bw:e.width, bh:e.height }; })
    .filter(o => o.w > 200 && o.h > 200)
    .sort((a,b) => b.w*b.h - a.w*a.h);   // largest by RENDERED area; NO 1920 hard floor
  if (!cs.length) return { error: "no remote canvas found" };
  const c = cs[0];
  return { dpr: window.devicePixelRatio, rect: {x:c.x,y:c.y,w:c.w,h:c.h}, hostW: c.bw, hostH: c.bh };
}
```

### Map a host pixel → click_at (CSS px, no ÷DPR)

```
meta = mcp.evaluate_script(helper)        # RE-READ before EVERY click sequence
if meta.error: STOP — tell the user (do NOT throw or guess a canvas)
clickX = meta.rect.x + hx * (meta.rect.w / meta.hostW)
clickY = meta.rect.y + hy * (meta.rect.h / meta.hostH)
mcp.click_at({ x: clickX, y: clickY })
```

### Map a screenshot pixel → host pixel (only when you eyeballed off a raw shot)

Screenshots save at `innerW × DPR`, so a shot pixel must be ÷DPR AND have the
canvas letterbox offset (`rect.x`/`rect.y`) subtracted before it's a host pixel:

```
hx = (shot_px_x/meta.dpr - meta.rect.x) * (meta.hostW / meta.rect.w)
hy = (shot_px_y/meta.dpr - meta.rect.y) * (meta.hostH / meta.rect.h)
# then feed (hx,hy) through the host-pixel→click_at formula above.
```

**Hard rule:** re-read `meta` before every click. The window can resize mid-flow
(verified: 980→1710 innerW silently broke reused coords). Never reuse a coord
across screenshots.

## The actions

### `click <target>`

```
meta = evaluate_script(helper)            # fresh
take_screenshot()                         # BEFORE state
resolve (hx,hy) for the target            # host pixel; map → clickX,clickY
mcp.click_at({ x: clickX, y: clickY })
take_screenshot()                         # AFTER state — did it land?
```

**Modal-recovery rule (verbatim):** *screenshot before+after; if unchanged AND a
dialog is visible, the click hit a modal-blocked region — act on the modal or
press Esc; do NOT silently re-click the same coords.* (Win32 modals block clicks
on the parent window — verified with OpenDental's eServices EConnector modal.)

**Verify-the-change rule:** for any authorized state-changing click (Send /
Confirm / Save / Delete / submit), the AFTER screenshot must show the *specific*
expected change — and no unintended one. "The screen changed" is NOT proof the
right thing happened.

### `double <target>`

Same mapping, then `mcp.click_at({ x: clickX, y: clickY, dblClick: true })`.
Screenshot before+after.

### `right <target>`

There is **NO right-click param** on `click_at` (its schema is
`{x,y,dblClick,includeSnapshot}`). `Shift+F10` opens the context menu at the
**current keyboard focus / selection**, NOT at a pixel — so to target a specific
element you must focus it first with a real left-click:

```
meta = evaluate_script(helper)
take_screenshot()                         # BEFORE
mcp.click_at({ x: clickX, y: clickY })    # positioning click = a REAL click:
take_screenshot()                         #   verify it focused the intended element;
                                          #   obey the modal-recovery + PHI rules.
                                          #   Do NOT do this on Buy/Send/Delete-class targets.
mcp.press_key("Shift+F10")                # context menu opens at the now-focused element
take_screenshot()                         # AFTER — confirm the menu opened
```

### `type <text>`

Use the shift-map sender (`type_text` strips Shift; `press_key("Shift+<base>")`
forwards it). Click/focus the target field first, screenshot to confirm focus.

```
SAFE  = set("abcdefghijklmnopqrstuvwxyz0123456789 -_=/.,;:'`")
SHIFT = {'!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0',
         '_':'-','+':'=','{':'[','}':']','|':'\\',':':';','"':"'",'<':',','>':'.','?':'/','~':'`'}
def send_text(s):
  if every ch in s in SAFE and s has NO uppercase: mcp.type_text(s)        # fast path
  else:
    for ch in s:
      if 'A' <= ch <= 'Z':  mcp.press_key("Shift+" + ch.lower())
      elif ch in SHIFT:     mcp.press_key("Shift+" + SHIFT[ch])
      elif ch == ' ':       mcp.type_text(" ")    # verified; NOT press_key("Space")
      else:                 mcp.type_text(ch)      # unshifted punct via type_text, not press_key(ch)
```

### `key <key>`

App-level single keys / combos via `mcp.press_key(...)`:
`Enter`, `Tab`, `Esc`, `Backspace`, arrows, `Page*`, `Home`, `End`,
`Control+v`/`Control+c`/`Control+a` (forward fine).

**System combos are swallowed by CRD** — `Win`/`Meta`, `Alt+Tab`,
`Ctrl+Alt+Del` do NOT reach Windows via `press_key`. Use the click-based
niceties instead (`launch`, `switch`) and the CRD DOM buttons in `crd.md` for
Ctrl+Alt+Del / PrtScr.

### `scroll <up|down>`

No mouse-wheel tool exists. In priority order:

1. **App-level keys** (when the content pane has focus — click into it first):
   `mcp.press_key("PageDown")` / `"PageUp"` / `"ArrowDown"` / `"ArrowUp"`.
   (Verified these forward fine.)
2. **Scrollbar arrow buttons** — `click` the up/down arrow at the end of the
   target window's scrollbar (map via the rect helper like any other pixel).
3. **Thumb-drag (EXPERIMENTAL):** `mcp.drag(...)` the scrollbar thumb. `drag` is
   UNVERIFIED — smoke-test it first session. Its coordinate space is the **same
   canvas-rect CSS px** as `click_at` (map both endpoints through the helper).
   If the `drag` smoke test fails, fall back to (1)/(2).

### `launch <app>`

Win/Start is a system key (swallowed) — launch with clicks, not `Meta`:

```
meta = evaluate_script(helper)
# Start orb anchor: derive per session from a screenshot (bottom taskbar, left
# of the search pill). Do NOT hardcode a pixel — map the eyeballed location
# through the rect helper.
click the Start orb
take_screenshot()                  # confirm the Start menu opened
if Start menu did NOT open: retry one icon-width to the right (taskbar anchors
                            drift); screenshot again
send_text("<app>")                 # type the app name into Start search
mcp.press_key("Enter")
take_screenshot()                  # confirm the app launched
```

### `switch <window>`

Alt+Tab is swallowed — switch by clicking the app's **taskbar icon** (map the
eyeballed icon location through the rect helper; screenshot before+after).

## Invariants for every act

- Re-read the canvas rect before every click sequence; never reuse coords.
- Screenshot before AND after every action.
- Apply the modal-recovery rule — an unchanged screenshot is not proof of a
  wrong coordinate; it may be a modal.
- OpenDental is live PHI by default; don't practice freely until the user
  confirms the Demo DB this session. Never click Buy/Send/Pay/Confirm/Delete or
  type into a Windows UAC/sign-in prompt without explicit instruction.
