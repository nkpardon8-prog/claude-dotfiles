# Agent guide — driving a Mac mini via CRD canvas + DevTools MCP

## TL;DR

You're an AI agent driving a Mac mini through a Chrome Remote Desktop (CRD) tab on the dev side, attached via chrome-devtools MCP. The CRD canvas renders the Mac mini's live desktop pixels; you control it with `press_key`, `take_screenshot`, focused canvas clicks, and the dedicated `/macmini paste` / `/macmini grab` commands for clipboard sync. `SKILL.md` is the capability map (what's on the Mac mini, scrolling primitives, delegation pattern). This file is operational tips: focus discipline, recovery from rogue keystrokes, common app-launch sequences, sign-in / permission re-grant. Read `SKILL.md` first.

---

## CRD focus discipline

Most "my keystroke didn't land where I expected" problems are focus problems. A few rules:

- **Click the canvas before any `press_key`.** Chrome may have moved focus to its own URL bar, a sidebar, an extension, or another tab between your previous DevTools call and this one. The reliable pattern:
  ```
  mcp.take_snapshot()                 # locate the canvas element's uid
  mcp.click({uid: <canvas_uid>})      # click by uid (the only click form chrome-devtools MCP exposes)
  mcp.press_key("...")
  ```
  If the canvas isn't in the a11y snapshot, fall back to `mcp.evaluate_script({function: "() => { const c = document.querySelector('canvas'); if (c) c.focus(); return !!c; }"})`. The canvas wrapper textbox (`name="Desktop"`) usually IS in the snapshot — match by name and use that uid.
- **Bring the CRD tab to front before paste.** If the dev-side user has multiple Chrome windows open, `pbcopy` then `Cmd+V` will paste into whichever Chrome window is foreground — which may not be CRD. Use `mcp.select_page({pageIdx: <crd_page.idx>, bringToFront: true})` (this is the only "bring to front" the MCP exposes — there is no separate `bring_to_front` tool). For OS-level Chrome window activation, fall back to AppleScript:
  ```
  osascript -e 'tell application "Google Chrome" to activate'
  # Or, for more precision (raises the CRD-bearing window specifically):
  osascript -e 'tell application "Google Chrome"
    set crdWin to first window whose URL of active tab starts with "https://remotedesktop.google.com"
    set index of crdWin to 1
    activate
  end tell'
  ```
- **Spotlight (`Cmd+Space`) reliability requires fullscreen + "Send System Keys".** In windowed CRD, `Cmd+Space` typically opens dev-side Spotlight (your laptop's), not the Mac mini's. The fix is in the CRD right-edge side menu: enter Full-screen mode, then enable "Send System Keys". Both must be on. `/macmini connect` reminds you of this; `/macmini status` reports the fullscreen state.

If keystrokes are landing in the wrong place, the diagnostic order is: (1) is CRD the foreground Chrome window? (2) does the canvas have DOM focus (re-click)? (3) is fullscreen + Send System Keys on (for Cmd+Space / Cmd+Tab)?

---

## Scrolling

`SKILL.md` documents the full scroll primitive table — go there for the canonical reference. The short version: `press_key("PageDown")` and `press_key("PageUp")` are the workhorses; `press_key("End")` and `press_key("Home")` jump to bottom and top respectively (with `Meta+ArrowDown` / `Meta+ArrowUp` as fallbacks). Do NOT use the MCP `drag` tool to scroll — it's a click-drag (mousePressed → mouseMoved → mouseReleased) and Mac apps interpret it as a text selection or content drag, never as a scroll wheel.

When reading long Terminal output:

1. After each `press_key("PageDown")`, `take_screenshot` to capture that page of context.
2. Stitch screenshots top-to-bottom in your reasoning — first screenshot was the bottom of the buffer; subsequent PageUp screenshots are increasingly older content. (Or use the inverse: scroll to the top of the relevant region first, then `PageDown` your way down, capturing each page.)
3. **Return focus to the live tail before sending the next keystroke** — `press_key("End")` or repeated `press_key("PageDown")` until you're at the bottom. Otherwise the next keystroke goes into scrollback, not into the live shell, and is silently lost.

This applies to all scrollable content: long Chrome pages, log viewers, code editors, chat threads. Pattern is the same — scroll, capture, read in order, return to live tail.

---

## Clicking on the canvas

`mcp.click_at({x, y})` is the agent's pixel-precise click tool. It requires `--experimental-vision` enabled in the chrome-devtools-mcp config (see `commands/macmini/setup.md` Step 1). Use it to click on anything visible on the Mac mini's screen — buttons, icons, links, custom-rendered UI.

### The four-step recipe

#### 1. Screenshot + identify

```
mcp.take_screenshot()
```

Look at the image, pick the target, estimate `(sx, sy)` in screenshot pixels.

#### 2. Fetch geometry (cache for the click; refetch if anything changed)

```
mcp.evaluate_script({
  function: "() => { const cs = [...document.querySelectorAll('canvas')].sort((a,b) => b.width*b.height - a.width*a.height); const c = cs[0]; if (!c) return {error: 'no canvas'}; const r = c.getBoundingClientRect(); const zoom = (window.visualViewport && window.visualViewport.scale) || (window.outerWidth / window.innerWidth) || 1; return { dpr: window.devicePixelRatio, zoom, scrollX: window.scrollX, scrollY: window.scrollY, canvas: { x: r.x, y: r.y, width: r.width, height: r.height, right: r.right, bottom: r.bottom } }; }"
})
```

If the result is `{error: 'no canvas'}`, REFUSE and re-screenshot — CRD page hasn't loaded or you're on the wrong tab. If multiple canvases exist (rare; happens with overlay/cursor canvases), the snippet picks the largest by area, which is the streaming canvas.

`zoom` primary source is `visualViewport.scale` (the actual current zoom factor, including pinch-zoom on touch devices). Fallback to `outerWidth/innerWidth` for older browsers; final fallback `1` if both unavailable. At default browser state (zoom 100%, no devtools open, no scrollbars), `zoom === 1.0`.

**Scroll-guard.** If `scrollX !== 0 || scrollY !== 0` in the geometry result, the CRD page is scrolled — the screenshot and click coord systems are desynced. REFUSE: "CRD page is scrolled — click coords would land at the wrong position. Scroll the CRD page to top-left first (Cmd+Home or click the canvas and press Home), then re-fetch geometry." This is rare in normal use (the CRD page is usually the bare canvas with no scrollable content).

Refetch geometry whenever any of these happen since the last fetch: window resize, fullscreen toggle, side-panel toggle, browser zoom change (`Cmd+0`/`Cmd+`/`Cmd-`), tab switch, page reload, devtools panel open/close (changes `window.innerWidth`), or > 5 minutes elapsed.

#### 3. Convert + verify on-canvas + verify non-occluded

```
# Step 3a: convert screenshot pixels to viewport CSS pixels
total_scale = dpr * zoom
vx = round(sx / total_scale)
vy = round(sy / total_scale)

# Step 3b: verify inside canvas rect (note: < not <= for right/bottom — DOM rect right edge is exclusive)
if not (canvas.x <= vx < canvas.x + canvas.width and
        canvas.y <= vy < canvas.y + canvas.height):
    REFUSE: "Click target (sx, sy) → viewport (vx, vy) falls outside CRD canvas region. Re-screenshot and retry."

# Step 3c: verify the canvas is the topmost element at that point (no popup/toolbar/notification overlay)
# IMPORTANT: chrome-devtools-mcp evaluate_script in this skill uses inline string interpolation, NOT a separate `args:` parameter (matches existing AGENT-GUIDE.md usage). Compose the function string with vx/vy substituted.
mcp.evaluate_script({
  function: `() => { const cs = [...document.querySelectorAll('canvas')].sort((a,b) => b.width*b.height - a.width*a.height); const target = cs[0]; const el = document.elementFromPoint(${vx}, ${vy}); return { isCanvas: el === target, actualTag: el ? el.tagName : null, actualClass: el ? el.className : null }; }`
})
# Inspect the result:
#   isCanvas === true → safe to click.
#   isCanvas === false → canvas is occluded at (vx, vy). The actualTag/actualClass tell you what's on top (BUTTON, DIV with role="dialog", etc.). REFUSE the click.
```

#### 3d. CRD's own UI overlay edge case

CRD shows a top toolbar (~60px tall) on mouse activity for ~3 seconds, and may show a bottom strip in some configurations. Both render INSIDE the canvas rect — `getBoundingClientRect` doesn't catch them, but step 3c's `elementFromPoint` check WILL catch them (when the toolbar is on top, `elementFromPoint` returns a CRD-toolbar `div` instead of the canvas, so the occlusion check refuses).

For clicks within the top 60px or bottom 30px of the canvas (where CRD UI overlays appear), do NOT skip step 3c — let it refuse. The recovery flow:

1. **First**: take a fresh screenshot. If CRD's toolbar/strip is visible in the screenshot, the overlay is up.
2. **Wait 3 seconds** without sending any input (CRD's UI auto-hides on inactivity). Re-screenshot to confirm it's gone.
3. **Re-fetch geometry** (the canvas rect doesn't change but the occlusion state does), re-run step 3c. If `isCanvas === true` now, proceed to step 4.
4. **If after 3 seconds the overlay is still up** (rare; happens during CRD reconnect attempts), fall back to the mini-side equivalent: open Spotlight (`mcp.press_key("Meta+space")`), navigate to the target via keyboard, or delegate the action to Mac mini Claude.

Do NOT use a "benign click" to dismiss the overlay — that would loop (the click itself triggers CRD UI to reappear).

#### 4. Click

```
mcp.click_at({ x: vx, y: vy })
# Optional: { x, y, dblClick: true } for double-click.
# Optional: { x, y, includeSnapshot: true } to get a post-click DOM snapshot back.
```

`click_at` rounds to nearest integer internally. Sub-pixel coords from non-integer DPR (1.25, 1.5, 2.5) are fine.

### Verify after the click

Vision is good for buttons (16-30px error tolerance) but less reliable for icons (5px tolerance). Verifying after every click is recommended; the cases below are MANDATORY:

**Mandatory verify-after contexts** — agent MUST take a screenshot after the click and confirm the expected state change. If the change didn't happen, retry with adjusted coords; do NOT proceed:

- OAuth approve / consent screens
- Payment confirmation (Buy / Pay / Confirm payment)
- Destructive actions (Delete, Discard, Close-tab-with-unsaved, Move-to-Trash)
- Send-message / Send-email / Post / Publish
- File-overwrite confirmations
- 2FA / biometric prompts (if these surface inside the canvas)
- Any "Are you sure?" dialog

For non-mandatory cases (focus changes, app launches, scrolling), verify-after is recommended but not enforced.

### Modifier + click is NOT supported via click_at

Cmd-click, Shift-click, Option-click via separate `press_key("Meta")` + `click_at(...)` calls is RACY — modifier-down state is not held across MCP-call boundaries. Use cliclick instead (atomic single shell command). See fallback section below.

### Fallback: cliclick on the mini side

`click_at` is single-point left-click only. For drag, right-click, modifier+click, or any case where `click_at` empirically fails to propagate through CRD, fall back to `cliclick` on the mini side. cliclick is OS-level on the mini — guaranteed to work, but slower (one `/macmini paste` round-trip per call) and requires a one-time install + Accessibility TCC.

#### One-time mini-side setup

```
brew install cliclick
```

Then System Settings → Privacy & Security → Accessibility → enable Terminal.app (or whichever process invokes cliclick).

#### Coord system — cliclick uses mini PHYSICAL pixels

cliclick coords are **mini-screen physical pixels** (not canvas pixels and not mini CSS pixels). The canvas-to-mini-screen scale is **NOT 1:1** in the general case — CRD's resolution setting (Auto / 1080p / 720p / Match local) and bandwidth target affect the streamed canvas resolution. Treat the scale as unknown until measured per-mini.

**Measure-once procedure** (run once per mini, cache result in HARDWARE-FINDINGS):

1. On mini Terminal: run `system_profiler SPDisplaysDataType | grep Resolution` to get the mini's physical resolution (e.g., `2560 x 1440`).
2. From the agent: fetch `canvas.width` and `canvas.height` from the geometry recipe in step 2 above.
3. Compute scale: `scale_x = mini_physical_width / canvas.width`, `scale_y = mini_physical_height / canvas.height`. (On a Retina mini with CRD at "Match local," these may differ from 1:1 because Retina logical-vs-physical pixels.)
4. Verify by issuing `cliclick m:100,100` (move cursor to mini-physical 100,100) and observing where the cursor lands on the canvas — should be at approximately `(100/scale_x, 100/scale_y)` in canvas pixels.
5. Cache the scale factor in `docs/HARDWARE-FINDINGS-2026-04-27.md` so the agent doesn't re-measure each session.

If unmeasured, the agent should NOT assume 1:1 — either run the measure procedure or stick to keyboard navigation for that scenario.

#### Coord conversion (after measurement)

```
# Starting from screenshot pixels (sx, sy):
canvas_local_x = (sx / total_scale) - canvas.x
canvas_local_y = (sy / total_scale) - canvas.y
mini_physical_x = canvas_local_x * scale_x
mini_physical_y = canvas_local_y * scale_y

# Then issue:
cliclick c:mini_physical_x,mini_physical_y
```

#### Syntax (all unshifted-safe; the agent types these via /macmini paste)

| Action | Command |
|---|---|
| Left click | `cliclick c:x,y` |
| Right click | `cliclick rc:x,y` |
| Double click | `cliclick dc:x,y` |
| Drag | `cliclick dd:x1,y1 du:x2,y2` |
| Cmd-click | `cliclick kd:cmd c:x,y ku:cmd` |
| Shift-click | `cliclick kd:shift c:x,y ku:shift` |
| Move (no click) | `cliclick m:x,y` |

#### When to fall back vs. retry click_at

- click_at returned an MCP error → check `~/.claude.json` has `--experimental-vision`; restart Claude Code; retry once.
- click_at succeeded but mini didn't react → CRD didn't forward the event (or wrong coords). Re-verify geometry, retry once. If still nothing, fall back to cliclick.
- Need drag / right-click / modifier-click → cliclick directly, no click_at attempt.
- App fails consistently with click_at but works with cliclick → log per-app failure in `docs/INCIDENTS.md` so future agents know.

---

## Recovery from rogue Cmd+modifier mishaps

Modifier-Shift confusion is real. If you're typing through CRD and a stray combination chords with what came before, you'll occasionally open something you didn't intend.

- **Stray `Cmd+,` opens System Settings (or the focused app's preferences):** `press_key("Meta+w")` closes the preferences pane. If a settings app is now in foreground, `press_key("Meta+q")` to quit it, then Spotlight back to your intended app.
- **Stray `Cmd+Shift+something` opens an Encodings panel, Help search, or other side window:** `press_key("Escape")` to dismiss, then re-focus via Spotlight.
- **General pattern when in doubt:** `press_key("Meta+q")` to close the wrong app, then `Cmd+Space` → paste the intended app name (lowercase) → Enter to refocus. If you're not sure what's even focused, `take_screenshot` first.

The user types alongside you sometimes — if you see a window you didn't open, treat it as ambient noise and recover the same way (Cmd+Q, refocus, resume).

---

## Delegation pattern — when to use Mac mini Claude

A `claude` Code session running on the Mac mini itself sidesteps every CRD limitation: no Shift mangling (it has its own real keyboard), no clipboard sync round-trips, no canvas focus discipline. Its Bash tool runs anything you'd run yourself. Delegate when:

- The task is **multi-step** (more than 2-3 paste/keystroke round-trips would be needed).
- The task **needs sudo** — Touch ID for sudo may not be configured on the Mac mini, and you absolutely cannot type a sudo password through CRD reliably (Shift mangles most passwords).
- The task involves **complex shell pipelines** that would be painful to paste-and-execute step by step (multi-line heredocs, subshell substitutions, etc.).
- The task needs **Mac mini's local context** more than visual feedback — reading a file tree, checking git status, running tests, inspecting environment variables.

Recipe:

1. Focus Terminal on the Mac mini: `Cmd+Space` (Spotlight) → `/macmini paste "terminal"` → `press_key("Enter")`.
2. `/macmini paste "claude"` → `press_key("Enter")`. Wait a few seconds for the Claude Code session to start.
3. `/macmini paste "<your instruction in lowercase prose>"` → `press_key("Enter")`. Lowercase-only because if the prose itself has to be re-typed for any reason (e.g., you needed to retry), uppercase letters won't survive CRD typing — but `/macmini paste` itself handles arbitrary content, so the lowercase rule is just a safety habit, not a hard constraint.
4. `take_screenshot` to read Mac mini Claude's response. Apply the scrolling discipline above for long responses.
5. Iterate: more paste, more screenshots. Don't break out of the Mac mini Claude session until the multi-step task is done — that's the whole point of delegation.

---

## Common app-launch sequences

All via Spotlight. Lowercase queries are CRD-safe.

| App | Sequence |
|---|---|
| Terminal | `Cmd+Space` → `/macmini paste "terminal"` → Enter |
| Chrome (Mac mini's) | `Cmd+Space` → `/macmini paste "chrome"` → Enter (or `"google chrome"` if multiple Spotlight matches) |
| Safari | `Cmd+Space` → `/macmini paste "safari"` → Enter |
| TextEdit | `Cmd+Space` → `/macmini paste "textedit"` → Enter |
| System Settings | `Cmd+Space` → `/macmini paste "system settings"` → Enter. **Do NOT use `Cmd+,`** — that opens whatever app is currently focused's preferences, which is rarely what you wanted. |
| Finder | `Cmd+Space` → `/macmini paste "finder"` → Enter (or click the Dock icon if available) |

Spotlight requires CRD fullscreen + Send System Keys (see [Focus discipline](#crd-focus-discipline)). If Spotlight fails entirely, fall back to clicking the Dock or using Cmd+Tab (also requires Send System Keys).

---

## Sign-in and permission re-grant recovery

- **`/macmini connect` returns `NEEDS_REAUTH`:** the dev-side Chrome's Google sign-in for `https://remotedesktop.google.com` has expired. Tell the user to sign back in inside the CRD tab, then re-run `/macmini connect`. You cannot sign in for them — the CRD page renders the Google sign-in form in dev Chrome's chrome, not on the Mac mini canvas.
- **`/macmini paste` reports clipboard permission denied:** Chrome's `clipboard-read` permission for `https://remotedesktop.google.com` is in `denied` state. Have the user visit `chrome://settings/content/clipboard`, find `https://remotedesktop.google.com` in the list (Add it if missing), set it to Allow. The permission persists per-origin once granted.
- **`/macmini paste` returns but mini's clipboard is wrong / stale:** mini Terminal lost focus when the clone command was typed. Bring Terminal forward via Spotlight (`mcp.press_key("Meta+space")` → `mcp.type_text("terminal", "Enter")`), screenshot to confirm a shell prompt is visible, then retry `/macmini paste`. (Reminder: dev → mini clipboard sync via CRD is broken; gist is the only reliable channel.)
- **`take_screenshot` returns black:** Mac mini display is asleep. `press_key("Shift")` to wake without typing anything destructive (Shift alone produces no character input but registers as a wake event), then re-screenshot. If still black, the Mac mini may be at a FileVault unlock prompt after a cold boot — escalate to the user.

---

## TCC permission recovery (Mac mini side)

macOS Privacy & Security grants for the CRD host process (Screen
Recording, Accessibility, Input Monitoring) are SIP-protected and
managed by macOS — the skill never bypasses them, only deep-links to
the right pane. They're typically a one-time grant on first install,
but a macOS major upgrade or a CRD reinstall can wipe them. Symptoms
include a black or stale `take_screenshot`, dropped keystrokes inside
the canvas, or `/macmini connect` succeeding but no real input
forwarding to the Mac mini.

Recipe (manual — there's no helper script anymore; tell the user where to go):

1. On the dev side: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"` opens the Screen Recording pane. For Accessibility use `Privacy_Accessibility`; for Input Monitoring use `Privacy_ListenEvent` on macOS 13 and earlier or `Privacy_InputMonitoring` on macOS 14+ (Sonoma+).
2. The user toggles the CRD host (typically `Chrome Remote Desktop Host` or `org.chromium.chromoting.me2me_host`) ON for the relevant capability.

If running this recipe ON the Mac mini via /macmini paste delegation, paste a script that wraps the right `open` URL for the Mac mini's macOS major (detect via `sw_vers -productVersion`).

After re-toggling, restart the CRD host process so it picks up the new
grant:

```bash
pkill -f ChromeRemoteDesktopHost
```

The host auto-respawns via launchd. Re-run `/macmini connect` from
dev once the canvas comes back, then re-take a screenshot to confirm
input + display are working.

If you're not sure which pane is failing, run all three in sequence
(`screencapture`, then `accessibility`, then `inputmonitoring`),
toggle CRD host in each, then `pkill -f ChromeRemoteDesktopHost`
once at the end.

## CRD's a11y tree is stripped — design implications

CRD's main canvas exposes only one usable a11y node (the textbox wrapper). Every interesting control — Begin, Synchronize clipboard, Send system keys, Show remote keyboard, Pin options panel — appears in `mcp.take_snapshot()` output as `ignored`. There's no uid to pass to `mcp.click({uid})`.

This is intentional CRD behavior: they strip a11y to prevent automation tools from clicking through the desktop session boundary. The only ways to click those controls are:

1. **Real mouse via macOS automation** — AppleScript `tell application "System Events" to click at {x, y}`, OR `cliclick c:x,y`. Requires Accessibility TCC. Brittle (depends on viewport coordinates).
2. **The user clicks once at first connect.** Both toggles ("Synchronize clipboard" and "Send system keys") persist across reconnects. This is the chosen approach.

For the agent: do NOT try to click CRD's side-panel controls programmatically. If the user reports the toggles got reset (rare — only happens on profile rebuild or "Forget device"), tell them which two toggles to flip and where to find them.

If CRD's UI changes and you need to discover new selectors for documentation purposes (NOT to click), use `mcp.evaluate_script` with a shadow-DOM walker that filters by `[role="button"]` and `[role="checkbox"]` — `document.querySelectorAll('[role="..."]')` reaches them (no shadow piercing required, despite the a11y stripping).

## What's NOT in this guide

- **The full capability map** — that's `SKILL.md`. What's installed on the Mac mini, the full scroll primitive table, the limitations & gotchas list, the recovery patterns. SKILL.md is always loaded with the skill so the agent has it on first reference.
- **The smoke tests** — those are in `docs/TESTING.md`. Run them before declaring the skill working on a fresh setup, and after any change to `paste.md` / `grab.md` / `connect.md`.
- **The migration recipe (Tailscale → DevTools-only)** — that's in `commands/macmini/setup.md` Migration appendix. Includes the `cleanup-mini.sh` invocation and the rollback path back to `main`.

---

## When blocked

Report cleanly to the user in lowercase prose:

1. What state did you reach? (e.g., "connected to canvas, attempting paste")
2. What failed? (e.g., "permission denied on clipboard-read")
3. What did you try? (e.g., "verified `/macmini status` shows perm = `denied`, not `prompt`")
4. What specific input do you need from them? (e.g., "open `chrome://settings/content/clipboard` and Allow `https://remotedesktop.google.com`")

Don't keep retrying through CRD if the channel is fighting you. If the canvas is unresponsive or clipboard sync is dead, the user needs to be in the loop — possibly to reload the CRD tab, sign back into Google, re-grant a permission, or physically wake the Mac mini.
