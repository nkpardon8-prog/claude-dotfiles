# /macmini act — LAYER-2 macOS desktop actions (direct CDP)

LAYER-2 is the **macOS desktop itself**, rendered into an opaque `<canvas>`.
You drive it with coordinate `mcp.click_at()` + `press_key`/`type_text`, and you
read state ONLY from `mcp.take_screenshot()`. (For CRD's own UI — Disconnect,
panel, clipboard toggle — that's LAYER-1, see `crd.md`.)

Every coordinate action runs through the ONE rect helper defined here. Nothing
else duplicates it.

## THE ONE rect helper (defined once, here)

`getBoundingClientRect()` and `click_at` are **BOTH CSS px**, so rect-derived
coords are **NOT** divided by DPR. Returns `{x,y,w,h}` EXPLICITLY (a raw DOMRect
has `.width`/`.height`, not `.w`/`.h`). (Verified rect this session:
`{x:9.66, y:0, w:1690.66, h:951}`, host `1920×1080`.)

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
and silently break reused coords. Never reuse a coord across screenshots.

### Occlusion check (the AGENT-GUIDE canvas-click recipe — port)

Before a click on the top ~60px or bottom ~30px of the canvas, verify the target
is not covered by CRD's auto-hiding toolbar overlay. Use `elementFromPoint` at
the **CSS-px click point** (`clickX,clickY`) and confirm it resolves to the
remote `<canvas>`, not a CRD-UI `<div>`:

```js
mcp.evaluate_script({ function: `() => {
  const cs = [...document.querySelectorAll('canvas')].sort((a,b)=>b.width*b.height-a.width*a.height);
  const target = cs[0];
  const el = document.elementFromPoint(${clickX}, ${clickY});
  return { isCanvas: el === target, actualTag: el ? el.tagName : null };
}` })
```

If `isCanvas === false`: CRD's toolbar is overlapping the target. Wait ~3s
(it auto-hides on inactivity) and re-check once; if still occluded, surface to
the user — do NOT fire the click blind.

## The actions

### `click <target>`

```
meta = evaluate_script(helper)            # fresh
take_screenshot()                         # BEFORE state
resolve (hx,hy) for the target            # host pixel; map → clickX,clickY
(if near a canvas edge) occlusion-check   # see above
mcp.click_at({ x: clickX, y: clickY })
take_screenshot()                         # AFTER state — did it land?
```

**Modal-recovery rule (verbatim):** *screenshot before+after; if unchanged AND a
dialog is visible, the click hit a modal-blocked region — act on the modal or
press Esc; do NOT silently re-click the same coords.*

**Verify-the-change rule:** for any authorized state-changing click (Send /
Confirm / Save / Delete / submit), the AFTER screenshot must show the *specific*
expected change — and no unintended one. "The screen changed" is NOT proof the
right thing happened.

✅ Single large-target left-click is **verified** (clicked the Apple menu,
2026-06-01). Small targets are less certain — verify-after and re-aim if needed.

### `double <target>`

Same mapping, then `mcp.click_at({ x: clickX, y: clickY, dblClick: true })`.
Screenshot before+after.

⚠️ **UNVERIFIED on small targets.** A ~50px Finder desktop-icon double-click
missed historically (the mechanism worked; the coord estimate was off by a few
px). Smoke-test on a known target before relying on it; verify-after and re-aim.

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

Verified live 2026-06-01: `Az%|"~` (capital + `|`/`"`/`~`). First session,
smoke-test the FULL map. **Credentials are NOT typed char-by-char through the
canvas** — the user types them via `read -s` directly in the mini Terminal (see
SKILL.md / FINDINGS).

### `key <key>`

App-level single keys / combos via `mcp.press_key(...)`:
`Enter`, `Tab`, `Esc`, `Backspace`, arrows, `Page*`, `Home`, `End`,
`Control+v`/`Control+a`, and the **macOS Cmd combos** `Meta+c`/`Meta+v`/`Meta+a`
etc. **Cmd combos forward on macOS IF CRD's "Send system keys" toggle is ON.**
If a Cmd combo does nothing, that toggle is off → surface to the user.

⚠️ **macOS destructive-shortcut hazard:** never fire `Meta+q` / `Meta+w` /
`Meta+Delete` except as explicitly-authorized recovery, and screenshot-verify
which app has focus FIRST.

### `right <target>` — documented v1 GAP

There is **NO CDP path to right-click on macOS.** `click_at` has no
button/modifier param (its schema is `{x,y,dblClick,includeSnapshot}`), so
`Control+click` is not expressible, and there is **NO macOS context-menu key**
(`Shift+F10` is **Windows-only** — do NOT use it here; it does nothing on macOS).

**Substitute:** use the app's **menu bar** (the macOS menu bar at the top of the
canvas is `click_at`-reachable). Almost every context-menu action also lives in a
top menu. Click the menu-bar title, then the item. If a flow genuinely requires
a right-click and the menu bar can't substitute, surface it to the user as an
out-of-scope v1 gap.

### `scroll <up|down>` — KEYBOARD only

macOS uses overlay scrollbars (no persistent arrow buttons) and reads a `drag` as
text-selection. **NEVER `drag` to scroll.** Click into the content pane to focus
it first, then:

| To do this | Press |
|---|---|
| Scroll one screenful down | `mcp.press_key("PageDown")` or `"Space"` |
| Scroll one screenful up | `mcp.press_key("PageUp")` or `"Shift+Space"` |
| Scroll one line | `mcp.press_key("ArrowDown")` / `"ArrowUp"` |
| Jump to bottom | `mcp.press_key("End")` or `"Meta+ArrowDown"` |
| Jump to top | `mcp.press_key("Home")` or `"Meta+ArrowUp"` |

Reading long output: `PageDown` × N with a screenshot between presses; stitch
top-to-bottom. **Return focus to the live tail** (`End` / repeated `PageDown`)
before the next keystroke, or it lands in scrollback and is lost.

### `launch <app>` — Spotlight (Cmd-forward) with guardrails + Dock fallback

```
mcp.press_key("Meta+Space")          # Cmd+Space — forwards IF "Send system keys" is ON
take_screenshot()                    # GUARDRAIL 1: confirm Spotlight opened ON THE MINI canvas
                                     #   (not dev-side Chrome). If nothing / dev-side Spotlight:
                                     #   toggle is off OR Spotlight is remapped (Raycast/Alfred)
                                     #   → use the Dock fallback below; surface to the user.
send_text("<app>")                   # type the app name (shift-map sender)
take_screenshot()                    # GUARDRAIL 2: confirm the TOP result row TEXT matches the
                                     #   intended app. Fuzzy-match + Enter can launch the WRONG
                                     #   app — destructive on a real machine. If it doesn't match,
                                     #   refine the query or Escape; do NOT press Enter.
mcp.press_key("Enter")
take_screenshot()                    # confirm the app launched
```

**Dock fallback:** if Cmd+Space is intercepted, click the app's **Dock icon**
(map the eyeballed icon location through the rect helper), or Apple menu →
Recent Items. Screenshot before+after.

### `switch <window>` — Cmd+Tab (Cmd-forward) with Dock fallback

`mcp.press_key("Meta+Tab")` cycles to the most-recently-used other app
(forwards IF "Send system keys" is ON). Screenshot to confirm the right app
came forward. **Fallback:** click the app's **Dock icon**.

## Invariants for every act

- Re-read the canvas rect before every click sequence; never reuse coords.
- Screenshot before AND after every action.
- Apply the modal-recovery rule — an unchanged screenshot is not proof of a
  wrong coordinate; it may be a modal.
- Real logged-in machine. Never click Buy/Send/Pay/Confirm/Delete, change
  settings, approve OAuth/2FA, or type into a macOS auth / keychain /
  accessibility / sign-in prompt — without explicit instruction. macOS
  permission dialogs may hide behind the foreground app; surface, don't
  blind-approve.
