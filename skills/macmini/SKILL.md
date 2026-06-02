# macmini — drive a remote Mac mini through Chrome Remote Desktop

> **YOUR HANDS = direct CDP input** — `mcp.click_at({x,y})`, `mcp.type_text`,
> `mcp.press_key`. They reach the macOS host natively through the CRD canvas
> (re-confirmed 2026-06-01). NO gist, NO cliclick, NO on-host agent, NO
> calibration file, NO Terminal dance. (This is a clean break from the OLD
> gist-era `/macmini` — see `commands/macmini.md` → "How this differs from the
> OLD gist-era /macmini".) **YOUR EYES = `mcp.take_screenshot()`.** If you
> didn't already, read [`../../commands/macmini.md`](../../commands/macmini.md) →
> "READ THIS FIRST" — it has the mental model plus the three embedded helpers
> (canvas-rect map, shift-map, title-first bind) that make the dispatcher
> self-contained.

> **First-time agent? Read [`ONBOARDING.md`](./ONBOARDING.md)** for the read
> order and invariants. **Reality matrix:** [`docs/FINDINGS-2026-06-01.md`](./docs/FINDINGS-2026-06-01.md)
> — what's verified, what's UNVERIFIED on macOS, the "Send system keys"
> dependency, and the gist-era history (so it's diagnosable).

You drive a **Mac mini (macOS)** through the `chrome-devtools` MCP attached to
the user's real-profile Chrome (port 9222, managed by `/devtools`). CRD renders
the macOS desktop into an opaque `<canvas>`. Two interaction layers, two
toolsets — always know which one you're on.

## Two layers

| Layer | What | Toolset |
|---|---|---|
| **LAYER-1 — CRD's own chrome** | Options panel, Disconnect, Full-screen, "Synchronize clipboard", "Send system keys" | Real page DOM: `take_snapshot` + `click({uid})` by LABEL — **but on macOS the a11y tree usually exposes only `Desktop`**, so default to coordinate `click_at` on the panel / user action. Probe + fall back. See `commands/macmini/crd.md`. |
| **LAYER-2 — the macOS desktop** | Everything inside the remote screen | Opaque canvas: coordinate `click_at` + `press_key`/`type_text`; read state ONLY from screenshots. See `commands/macmini/act.md`. |

## Capability matrix

### Vision (LAYER-2) — always on

| Want to do | Tool |
|---|---|
| See the mini's screen | `mcp.take_screenshot()` |
| Wake a black screen | `mcp.press_key("Shift")` (Shift only — no char input) |

### Keyboard / keys (LAYER-2)

| Want to do | Channel |
|---|---|
| Enter / Tab / Esc / Backspace / arrows / Page* / Home / End | `mcp.press_key("<key>")` |
| App-level combo (Cmd+C/V/A, Cmd+W) | `mcp.press_key("Meta+<x>")` — forwards IF "Send system keys" is ON |
| System combo (Cmd+Space, Cmd+Tab, Cmd+H) | **forwards on macOS IF "Send system keys" is ON** — a one-time USER toggle. If nothing happens → toggle off → use the click fallback (Dock / Apple menu). |

> ⚠️ **macOS destructive-shortcut hazard:** never fire `Meta+q` / `Meta+w` /
> `Meta+Delete` except as explicitly-authorized recovery; screenshot-verify
> focus first.

### Text (LAYER-2)

| Want to do | Channel |
|---|---|
| Pure lowercase + unshifted | `mcp.type_text("<text>")` (fast path) |
| Anything with a capital or shifted symbol | `send_text()` per-char shift-map (see Text math below) |
| Unicode / emoji / bulk | v2 (clipboard/file) — out of scope v1 |
| Inject a credential | **user types it via `read -s` directly in the mini Terminal** — see "Credential safety" below |

### Mouse (LAYER-2, direct CDP)

| Want to do | Channel |
|---|---|
| Left-click a host pixel | rect helper → `mcp.click_at({x,y})` (✅ verified, large targets) |
| Double-click | `mcp.click_at({x,y, dblClick:true})` — ⚠️ UNVERIFIED on small targets |
| Right-click | **v1 gap — no CDP path on macOS.** Use the app's **menu bar** (top). Do NOT use `Shift+F10` (Windows-only). |
| Scroll | **KEYBOARD only** — PageDown/PageUp/Space/Arrow, Meta+Arrow to jump. **NEVER `drag` to scroll.** |
| Drag | `mcp.drag(...)`, same canvas-rect CSS-px space — ⚠️ UNVERIFIED, smoke-test first |

### CRD UI (LAYER-1)

| Want to do | Channel |
|---|---|
| Disconnect / Full-screen / clipboard toggle / Send-system-keys toggle | probe `take_snapshot`; if uids exist click by label; on macOS (only `Desktop`) → coordinate `click_at` or ask the user |

### Niceties (Cmd-forward, WITH click fallback — LAYER-2)

| Want to do | Channel (Cmd) | Click fallback |
|---|---|---|
| Launch an app | `Meta+Space` → confirm Spotlight on mini → `send_text("<app>")` → confirm top result matches → `Enter` | click the **Dock icon** |
| Switch window | `Meta+Tab` | click the **Dock icon** |

### Lifecycle

| Want to do | Sub-command |
|---|---|
| Bind / resume | `/macmini connect` |
| LAYER-2 desktop actions | `/macmini act <…>` |
| LAYER-1 CRD UI / status / disconnect | `/macmini crd <…>` |
| One-time setup | `/macmini setup` |

## Coordinate math (both spaces)

`getBoundingClientRect()` and `click_at` are **BOTH CSS px** → rect-derived
coords are **NOT** ÷DPR. Only a target eyeballed off a raw screenshot is ÷DPR
(screenshots save at `innerW × DPR`), and that path must also subtract the
canvas letterbox offset (`rect.x`/`rect.y`).

**The rect helper** (defined once in `act.md`; the dispatcher embeds a copy)
returns `{ dpr, rect:{x,y,w,h}, hostW, hostH }` — `{x,y,w,h}` returned EXPLICITLY
because a raw DOMRect exposes `.width`/`.height`, not `.w`/`.h`. The canvas is the
**largest by rendered area**, NO 1920 hard floor; if none is found the helper
returns `{error}` and you STOP.

```
# Host pixel (hx,hy) → click_at (CSS px, no ÷DPR):
clickX = rect.x + hx * (rect.w / hostW)
clickY = rect.y + hy * (rect.h / hostH)

# Raw-screenshot pixel → host pixel (÷DPR + subtract letterbox), THEN the above:
hx = (shot_px_x/dpr - rect.x) * (hostW / rect.w)
hy = (shot_px_y/dpr - rect.y) * (hostH / rect.h)
```

**Worked example** (verified rect this session, host `1920×1080`):
rect `{x:9.66, y:0, w:1690.66, h:951}`. To click the Apple menu at host pixel
`(15, 12)`:

```
clickX = 9.66 + 15*(1690.66/1920) = 9.66 + 13.21 = 22.87
clickY = 0    + 12*(951/1080)     = 0 + 10.57    = 10.57
mcp.click_at({ x: 22.87, y: 10.57 })   # → Apple menu dropdown opened (verified)
```

**Re-read the rect before every click** — the window can resize mid-session and
silently break reused coords. Never reuse a coord across screenshots. Never
hardcode `1920`/`1080`/the session ID — read `hostW`/`hostH` from the helper and
bind by title.

## Text math (the shift-map sender)

```
SAFE  = set("abcdefghijklmnopqrstuvwxyz0123456789 -=/.,;'`")   # type_text-safe
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

`type_text` strips Shift (capitals lowercased, shifted symbols → unshifted).
`press_key("Shift+<base>")` holds it (verified live 2026-06-01: `Shift+a`,`z`,
`Shift+5`,`Shift+\`,`Shift+'`,`Shift+\`` → `Az%|"~`). First session: smoke-test
the FULL map.

## Credential safety (the `--secure` story, preserved without gist)

The old skill's `paste --secure` never sent the secret to GitHub — it shipped a
`read -s` bootstrap. The same principle holds now, just without the gist:

- **To put a credential on the mini, the USER types it via `read -s` directly in
  the mini Terminal** (e.g. `read -s -p 'token: ' TOK; export TOK`). The agent
  never carries, echoes, or logs it.
- **Never type a secret char-by-char through the canvas** (shift-map or
  otherwise) — it would be visible in screenshots and in the agent's reasoning.
- For mini-local work that needs a secret, prefer the **mini-Claude delegation**
  recipe (below): mini Claude can read it from the mini's Keychain / 1Password
  locally without it ever crossing the canvas.

## Gotchas

| Gotcha | Reality | What to do |
|---|---|---|
| Shift strip | `type_text` drops Shift | route any capital/symbol through `send_text` |
| Window resizes mid-flow | reused coords silently miss | re-read the canvas rect before EVERY click |
| Modal blocks parent clicks | screenshot looks unchanged | modal-recovery: act on the modal or Esc |
| Cmd needs the toggle | `Meta+Space`/`Tab`/`C`/`V` forward only when "Send system keys" is ON | if a Cmd combo does nothing → toggle off → Dock fallback + surface |
| No right-click on macOS | no CDP button/modifier param; no context-menu key | use the app's **menu bar** (top) |
| No scrollbar arrows | macOS overlay scrollbars; `drag` = text-selection | scroll via PageDown/Arrow/Meta+Arrow — never drag |
| CRD a11y only `Desktop` | macOS strips the panel uids | LAYER-1 = coordinate click_at / user action (probe + fall back) |
| Two CRD sessions | Mac + Windows, same URL prefix | bind by title `plan2bid-minim4` + macOS-menu-bar screenshot; STOP if ambiguous |
| Frozen background tab | one discarded tab freezes `list_pages` itself | treat a hang as the `/devtools` trigger (user-gated) |
| Spotlight remap | Raycast/Alfred can intercept Cmd+Space | confirm Spotlight on the mini before typing; Dock fallback |

## Verified vs UNVERIFIED matrix (macOS, 2026-06-01)

| Capability | Status | Notes |
|---|---|---|
| `take_screenshot` eyes | ✅ verified | crisp |
| `click_at` reaches host (large target) | ✅ verified | Apple-menu click opened the dropdown |
| Canvas-rect coord mapping | ✅ verified | rect `{9.66,0,1690.66,951}`, both-CSS-px, no ÷DPR |
| `type_text` lowercase/unshifted | ✅ verified | (gist-era + this session) |
| `press_key("Shift+<base>")` capitals/symbols | ✅ verified | `Az%|"~` incl. `|`/`"`/`~` |
| `Meta+Space` (Cmd forwarding) | ✅ verified | opened Spotlight on the mini |
| small-target double-click | ❌ UNVERIFIED | ~50px Finder icon dblClick missed historically |
| `drag` | ❌ UNVERIFIED | smoke-test first; needed for nothing in v1 |
| right-click | ❌ no CDP path | use the menu bar |
| CRD uid-by-label (LAYER-1) | ⚠️ likely unavailable | macOS exposes only `Desktop` → coordinate/user fallback |
| Clipboard bridge (pbcopy→Cmd+V) | ❌ does not bridge under CDP | needs OS-foreground gesture; v2 |

## Delegation pattern — when to use Mac mini Claude

A `claude` Code session running on the Mac mini itself sidesteps every CRD
limitation: no Shift mangling (real keyboard), no canvas focus discipline, full
local privileges. **It needs only `type_text` + `press_key` to bootstrap — no
gist, no cliclick.** Delegate when the task is multi-step, needs sudo, involves
complex shell pipelines, or needs mini-local context (file tree, git state) more
than vision.

Recipe:

1. Focus Terminal on the mini: `launch("terminal")` (Spotlight, with guardrails)
   or click the Dock Terminal icon; screenshot to confirm a shell prompt.
2. **Requires explicit user authorization** — `--dangerously-skip-permissions`
   removes the approval gate for irreversible local actions on the user's real
   Mac. Only launch it when the user has explicitly approved running an
   autonomous mini-Claude for this task; otherwise launch plain `claude` (keeps
   approvals). Then: `mcp.type_text({text: "claude --dangerously-skip-permissions", submitKey: "Enter"})`
   — all lowercase + dashes, types intact through CRD. The flag eliminates "Allow
   / Deny" dialogs the Shift-strip pipeline can't reliably navigate.
3. Wait ~3s for the TUI; screenshot to confirm it started.
4. Deliver the prompt: type it with the `send_text` shift-map (capitals/symbols
   handled), then `Enter`. (No clipboard/gist round-trip needed.)
5. `take_screenshot` to read the response; apply the scroll discipline for long
   output (PageUp to scroll back, then End to return to the live tail before the
   next keystroke).
6. Iterate. Don't break out until the multi-step task is done — that's the point.

Mac mini Claude shares this dotfiles checkout (same skills, CLAUDE.md, MCP
servers, credentials catalog). You don't need to re-explain conventions; it has
identical context — including the macmini skill itself (don't recurse).

## Safety

You are driving a **real, logged-in Mac mini** through the user's **full real
Chrome profile** — not a sandbox.

- **Full Chrome reachable.** The MCP attaches to the user's main Chrome on port
  9222 — every other tab, login, cookie, extension. Do NOT browse / read other
  tabs, email, or DMs for "context." Only navigate outside the Mac CRD tab when
  the user explicitly asks.
- **Never** click Buy / Send / Pay / Confirm / Delete, submit forms, approve
  OAuth / 2FA, change settings, or dismiss security warnings — without explicit
  user instruction.
- **Never type into or approve a macOS auth / keychain / "app wants to control
  your computer" / "allow accessibility / screen-recording" / Gatekeeper /
  notification prompt**, and never type a CRD PIN. These can appear (esp. on
  first Spotlight launch) and may hide BEHIND the foreground app — surface to the
  user; don't blind-approve.
- **Credentials:** the user types them via `read -s` in the mini Terminal — the
  agent never carries or types a secret through the canvas.
- **Mac session only** — never select / `bringToFront` / act on the Windows CRD
  tab (`OpenDentalDev1`). STOP if you can't tell which is which.
- **Screenshot before AND after every action**; re-read the canvas rect before
  every click; never reuse coords.
- **Connection self-heal is user-gated** — `/devtools`, then wait for the user
  to `/mcp` reconnect; no auto-retry.
