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
> - **Coordinates are derived per click, never reused.** Re-read the canvas rect
>   before every click (the window can resize mid-flow and silently break reused
>   coords). Screenshot before AND after.
>
> The three load-bearing snippets — the canvas-rect helper, the capital/symbol
> shift-map, and the title-first pre-flight — are **embedded inline below** so
> this file is self-contained. Depth refs (dotfiles only, not on the deployed
> path): `skills/macmini/SKILL.md`, `ONBOARDING.md`, `docs/FINDINGS-2026-06-01.md`.

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
| Per-mini `/macmini measure` calibration file | **No calibration** — map via the live canvas rect (embedded helper). |
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
4. **Infer the action** from the capability matrix below. Re-read the canvas rect
   before any click (see embedded helper).

## EMBEDDED HELPER — the ONE canvas-rect mapping (use this for every click_at)

LAYER-2 clicks map a known macOS-host pixel into CSS-px canvas coordinates.
`getBoundingClientRect()` and `click_at` are **BOTH CSS px**, so rect-derived
coords are **NOT** divided by DPR. (Verified rect this session:
`{x:9.66, y:0, w:1690.66, h:951}`, host streams `1920×1080` with a small
horizontal letterbox.) Call this fresh before each click sequence:

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

# Click a KNOWN macOS-host pixel (hx,hy) in hostW×hostH space.
# rect & click_at are BOTH CSS px → NO ÷DPR here:
clickX = meta.rect.x + hx * (meta.rect.w / meta.hostW)
clickY = meta.rect.y + hy * (meta.rect.h / meta.hostH)
mcp.click_at({ x: clickX, y: clickY })

# Click something you EYEBALLED off a raw screenshot (shots are innerW×DPR):
# convert the screenshot pixel to a host pixel FIRST (÷DPR + subtract the
# canvas letterbox offset rect.x/rect.y), then feed it through the formula above:
#   hx = (shot_px_x/meta.dpr - meta.rect.x) * (meta.hostW / meta.rect.w)
#   hy = (shot_px_y/meta.dpr - meta.rect.y) * (meta.hostH / meta.rect.h)

# Before firing, optionally occlusion-check (CRD's auto-hiding toolbar can sit
# over the top ~60px / bottom ~30px of the canvas) — see act.md "canvas-click".
take_screenshot()   # verify. Re-read meta before the NEXT click — window can resize mid-flow.
```

## EMBEDDED HELPER — type anything (capitals + symbols) via the shift-map

`type_text` strips Shift (capitals lowercased, shifted symbols → unshifted).
`press_key("Shift+<base>")` HOLDS the modifier and forwards it (verified live
2026-06-01: `Shift+a`,`z`,`Shift+5`,`Shift+\`,`Shift+'`,`Shift+\`` → `Az%|"~` —
capital + the risky `|`/`"`/`~` all correct). Route per character:

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
| App-level shortcut (Cmd+C/V/A, Cmd+W) | `mcp.press_key("Meta+<x>")` — forwards IF "Send system keys" is ON |
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

### Mouse — LAYER-2 (direct CDP, via the embedded rect helper)

| Want to do | Channel |
|---|---|
| Left-click a host pixel | rect helper → `mcp.click_at({x,y})` (✅ verified on large targets) |
| Double-click | `mcp.click_at({x,y, dblClick:true})` — ⚠️ **UNVERIFIED** on small targets (a ~50px Finder icon dblClick missed historically); smoke-test |
| Right-click | **documented v1 gap.** No CDP path on macOS — `click_at` has no button/modifier param and there is NO macOS context-menu key (`Shift+F10` is Windows-only — do NOT use it here). **Substitute: use the app's menu bar (top, `click_at`-reachable).** |
| Scroll | **KEYBOARD only** — `PageDown`/`PageUp`/`Space`/`ArrowDown`, `Meta+ArrowDown/Up` to jump. **NEVER `drag` to scroll** (macOS reads it as text-selection). |
| Drag | `mcp.drag(...)` in the canvas-rect CSS-px space — ⚠️ **UNVERIFIED**; smoke-test first session |

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
