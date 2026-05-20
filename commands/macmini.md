---
description: Drive a remote Mac mini through Chrome Remote Desktop via the chrome-devtools MCP. Self-resolving — invoke with no sub-command or just reference /macmini in plain English; the agent pre-flights, auto-connects if needed, and infers the right action from context.
argument-hint: "[free-form request, e.g. \"open chrome and check my email\"]"
---

# /macmini — Mac mini Remote

> **READ THIS FIRST — if you do nothing else, read this section.**
>
> You are driving a Mac mini through Chrome Remote Desktop. The CRD tab in
> the user's Chrome is a live video feed of the mini's screen.
>
> - **Your eyes** are `mcp.take_screenshot()` on the CRD page.
> - **Your hands are NOT chrome-devtools MCP clicks.** They are
>   **`/macmini click <sx> <sy>`** and its siblings (`rclick`, `dblclick`,
>   `drag`, `script`). These run `cliclick` / `osascript` on the **mini's
>   own OS**, dispatched through the existing `gh gist` transport. This is
>   what bypasses CRD's `isTrusted` gate that breaks every synthetic
>   dev-side click.
> - **Your typed keystrokes** (`mcp.type_text` / `mcp.press_key`) DO reach
>   the mini — they go to whichever app is foreground ON THE MINI. They
>   are how you deliver the `gh gist clone …; bash run.sh` command into
>   the mini Terminal.
> - **The non-obvious mental model:** every click cycle is `dev builds
>   gist → types clone-and-run into mini Terminal → run.sh fires
>   cliclick on the mini → screenshot to verify`. You are NOT clicking
>   pixels in the CRD canvas; you are running cliclick on the mini.
>
> The full capability map is in
> [`~/.claude-dotfiles/skills/macmini/SKILL.md`](../skills/macmini/SKILL.md).
> This file is the dispatcher and the workflow primer.

## Self-resolution

When the user invokes `/macmini` (with or without arguments) **or references the Mac mini in plain English** ("send X to the mini", "on the mac mini do Y", "use /macmini to do Z"):

1. **Pre-flight.** `mcp.list_pages()` — find the CRD canvas page (URL starts with `https://remotedesktop.google.com/access/session/`). If found, `mcp.select_page({pageId, bringToFront: true})` and skip step 2.
2. **Auto-connect if needed.** If no live canvas, run the `/macmini connect` flow (see `commands/macmini/connect.md`). The user types the PIN themselves when prompted; the agent waits for the canvas to mount.
3. **Vision check.** `mcp.take_screenshot()` to confirm the Mac mini desktop is visible. If black, `mcp.press_key("Shift")` to wake.
4. **Calibration check** (only if you might click). Confirm `~/.config/claude/macmini-calibration.json` exists. If missing, run `/macmini measure` once.
5. **Infer the action.** Use the capability matrix below.

## Capability matrix (the agent's single source of truth)

When the user references "the mini" or invokes /macmini, look at the request and find its row below. Use the listed channel. Don't improvise.

### Vision (always free, always on)

| Want to do | Tool |
|---|---|
| See the mini's screen | `mcp.take_screenshot()` |
| Wait for something to render | screenshot + sleep + screenshot |

### Keyboard (direct — lowercase + unshifted only)

| Want to do | Channel |
|---|---|
| Type a lowercase shell command into the foreground mini app | `mcp.type_text("<cmd>", "Enter")` |
| Press Enter / Tab / Esc / arrow / Page* / Home / End | `mcp.press_key("<key>")` |
| Cmd-shortcut (Cmd+V, Cmd+W, Cmd+Q, Cmd+Space, Cmd+Tab, Cmd+H) | `mcp.press_key("Meta+<x>")` — works IF "Send System Keys" was enabled in CRD's side panel during /macmini setup |

### Text (anything with capitals, symbols, unicode, multi-line)

| Want to do | Channel |
|---|---|
| Put bytes on mini's clipboard + auto-paste+Enter | `/macmini paste "<text>"` |
| Same, clipboard only (no Enter) | `/macmini paste "<text>"` + "don't submit" |
| Inject a credential | `/macmini paste --secure <ENV_NAME>` |
| Re-fire last paste into another app | `/macmini paste --repaste` |
| Read mini's clipboard back to dev | `/macmini grab` |

### Mouse (cliclick on the mini via gist transport — THIS IS YOUR HANDS)

| Want to do | Channel |
|---|---|
| Left-click at screenshot pixel (sx, sy) | `/macmini click <sx> <sy>` |
| Right-click | `/macmini rclick <sx> <sy>` |
| Double-click | `/macmini dblclick <sx> <sy>` |
| Drag from (sx1, sy1) to (sx2, sy2) | `/macmini drag <sx1> <sy1> <sx2> <sy2>` |
| Cmd-click / Shift-click / Opt-click / Ctrl-click | `/macmini click <sx> <sy> --mod cmd\|shift\|opt\|ctrl` |
| Move cursor without clicking | `/macmini script 'do shell script "/opt/homebrew/bin/cliclick m:X,Y"'` (rare; usually unnecessary) |

Coordinates `(sx, sy)` are **screenshot pixels** — what `mcp.take_screenshot()` returns. The sub-command converts to mini-physical pixels internally using cached calibration (`~/.config/claude/macmini-calibration.json`). Run `/macmini measure` once per mini to produce that file; click sub-commands refuse with a clear error if it is missing or stale.

### Anything cliclick can't do (AppleScript / System Events)

| Want to do | Channel |
|---|---|
| Activate / focus an app by name | `/macmini script 'tell application "Safari" to activate'` |
| Open a URL in Chrome | `/macmini script 'tell app "Google Chrome" to open location "https://..."'` |
| Pick a menu item | `/macmini script 'tell app "System Events" to tell process "X" to click menu item ...'` |
| Window management (move, resize, focus by title) | `/macmini script <applescript>` |
| Anything else macOS-automation-shaped | `/macmini script <applescript>` |

### Multi-step / shell-heavy

| Want to do | Channel |
|---|---|
| 3+ shell commands needing sudo, files, or complex pipelines | Delegate: type `claude --dangerously-skip-permissions` in mini Terminal, then `/macmini paste` your prompt. Mini Claude runs cliclick + bash natively at ~50ms/action. |

### Session lifecycle

| Want to do | Channel |
|---|---|
| Open the CRD canvas | `/macmini connect` |
| Close it | `/macmini disconnect` |
| Health check | `/macmini status` |
| First-time setup | `/macmini setup` |
| Recalibrate click coords | `/macmini measure` |

## Hard rules

- **NEVER `/macmini paste` a credential value.** Use `--secure`. `paste.md` Step 0 hard-gates this. GitHub runs secret-scanning on every gist (including secret/unlisted) and forwards detections to issuer partners (OpenAI, Anthropic, OpenRouter, AWS, ~50 others); auto-revocation lands within minutes. Deleting the gist does NOT unwind it.
- **ALWAYS screenshot before AND after any `/macmini click` / `rclick` / `dblclick` / `drag` / `script`** — vision is the receipt that the action landed.
- **For destructive UI clicks** (Delete, Send, Pay, Confirm), the agent MUST screenshot after AND verify the expected state change. If the change didn't happen, retry once with adjusted coords; do not proceed blindly.
- **~6s per click** is the gist round-trip cost. For iterative GUI work (form filling, wizard steps), delegate to mini Claude instead (`claude --dangerously-skip-permissions` in mini Terminal, then `/macmini paste` your prompt).

---

## The Workflow Primer — read this before your first click

Driving the mini in practice requires a small "dance" between Terminal and the target app. Here is the canonical sequence — do it this way and clicks land:

### 1. Mac mini Terminal must be foreground to receive the clone command

Every `/macmini click` (and every other gist-based sub-command) starts by typing this into the mini Terminal:

```
rm -rf /tmp/macmini-X; gh gist clone <ID> /tmp/macmini-X; bash /tmp/macmini-X/run.sh
```

If Terminal is NOT the foreground app on the mini, those keystrokes land in whatever app IS foreground — eBay's search box, Chrome's URL bar, anything. That is the single most common failure mode. **Before every gist round-trip, look at a screenshot and confirm the mini Terminal is foreground.**

### 2. How to get Terminal foreground in CRD (windowed mode tricks)

| You see | Do this |
|---|---|
| Terminal already visible & focused (cursor blinking in prompt) | Nothing — proceed to type. |
| Chrome / any other app covering Terminal | `mcp.press_key("Meta+Tab")` — Cmd+Tab cycles to the most-recently-used other app. If Terminal was MRU, it surfaces. |
| Cmd+Tab cycled to the wrong app | `mcp.press_key("Meta+h")` — Cmd+H hides the foreground app, revealing whatever's behind. Useful when Terminal is "behind" multiple windows. |
| Still can't reach Terminal | `/macmini script 'tell application "Terminal" to activate'` — uses the gist channel itself to focus Terminal. Requires Terminal-already-foreground to send… so this is only useful as a "stay-on-top" cap at the end of each run.sh, not as a way to bootstrap. |

`Meta+Tab`, `Meta+H`, `Meta+Space` only reach the mini if **CRD's "Send System Keys" toggle is ON**. This is a one-time user action done during `/macmini setup`. If a Cmd-shortcut is silently going to dev side instead of the mini, that toggle was never enabled — surface that to the user.

### 3. The run.sh template that always works

Inside the gist's `run.sh`, follow this pattern. It encodes three real-world fixes:

```bash
#!/bin/bash
set -uo pipefail
CB=/opt/homebrew/bin/cliclick      # Apple Silicon path (primary)
[ -x "$CB" ] || CB=/usr/local/bin/cliclick   # Intel fallback
[ -x "$CB" ] || { echo "ERR: cliclick not installed"; exit 4; }

# (1) Activate the TARGET app FIRST so the click lands on its window content.
osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1

# (2) Sleep 0.6s — NOT 0.4s. macOS WindowServer may eat the first click
# after app activation as a "focus this window" event. 0.6s is the
# empirically-stable wait.
sleep 0.6

# (3) Fire the cliclick action(s).
"$CB" c:$MINI_X,$MINI_Y

# (4) Bring Terminal back to the front so the NEXT gist clone command
# can be typed. Without this, every subsequent click cycle requires
# the user (or you) to Cmd+Tab back to Terminal.
osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1

echo OK
```

The four numbered comments above are load-bearing. Don't drop them.

### 4. Verifying the click

`mcp.type_text` followed by `mcp.wait_for(["OK"])` doesn't always see the `OK` — Terminal output can scroll off-viewport during a long `gh gist clone`. Recovery: take a screenshot. If you don't see `OK`, **press `Meta+H` to hide whatever's on top** — Terminal's full output is usually behind it, and you can read the Pre/Post cursor positions and exit code directly.

After confirming `OK`, screenshot Chrome (or whatever target app you clicked) to verify the click had its intended effect — the page navigated, the menu opened, the form filled.

### 5. The two TCC prompts you will hit ONCE per mini

- **Accessibility (cliclick's prompt).** First time cliclick runs on a mini, macOS shows a prompt: *"Terminal would like to control this computer using accessibility features."* User must click **Open System Settings** → enable Terminal under Privacy & Security → Accessibility. **Persistent after grant.** Mentioned in `/macmini setup` Step 1b.
- **Automation (AppleScript's prompt).** First time AppleScript controls a NEW target app (Chrome, Safari, Finder, …), macOS shows: *"Terminal wants access to control X."* User clicks **Allow**. One-time **per app pair**, persistent after grant.

If a click silently fails (cliclick exit 0 but nothing happens) and neither dialog is visible, the dialog may be hidden behind the foreground app — Cmd+H to reveal, then have the user Allow.

### 6. Cleanup is automatic

Each gist-based sub-command deletes its own gist at the end (Step 7 / final cleanup). If a sub-command aborts mid-way, you can manually `gh gist delete <ID> --yes` from dev. Lingering gists are a security smell — keep the list lean via `gh gist list --limit 20`.

### 7. When to NOT use /macmini click

Pixel clicks are ~6 seconds each (gist round-trip). For workflows that need many actions in sequence:

- **More than 3-4 clicks?** Delegate to mini Claude: `mcp.type_text("claude --dangerously-skip-permissions", "Enter")` in mini Terminal, screenshot to confirm it started, then `/macmini paste "<your full prompt>"` and let it work natively (~50ms/action).
- **Form filling with many fields?** Use a single AppleScript via `/macmini script` to JavaScript-inject into Chrome (`tell application "Google Chrome" to execute javascript "document.querySelector(...).value = ..." in active tab`). Requires "Allow JavaScript from Apple Events" in Chrome's View > Developer menu.
- **Window management beyond focusing?** Use `/macmini script` with AppleScript bounds setters. Faster and more precise than dragging title bars.

---

## Sub-commands (for explicit invocation)

| Sub-command | Purpose |
|---|---|
| `/macmini connect` | Open or resume the CRD session. PIN is user-only. |
| `/macmini paste "<text>"` | gist-based arbitrary-text channel — survives capitals, symbols, unicode, multi-line. |
| `/macmini grab` | Pull text from Mac mini's clipboard back to dev (manual mode). |
| `/macmini disconnect` | Close the CRD tab. |
| `/macmini status` | Quick health audit (canvas, sign-in, clipboard permission, gh auth, calibration freshness). |
| `/macmini setup` | One-time setup walkthrough (MCP, gh on both sides, cliclick, Accessibility TCC, measure). |
| `/macmini click <sx> <sy>` | Left-click at screenshot pixel. Optional `--mod cmd\|shift\|opt\|ctrl`. |
| `/macmini rclick <sx> <sy>` | Right-click at screenshot pixel. |
| `/macmini dblclick <sx> <sy>` | Double-click at screenshot pixel. |
| `/macmini drag <sx1> <sy1> <sx2> <sy2>` | Click-drag between two screenshot pixels. |
| `/macmini script "<applescript>"` | Run AppleScript on the mini via gist transport. |
| `/macmini measure` | One-time calibration — writes `~/.config/claude/macmini-calibration.json`. |

## See also

- Capability map & channel matrix: [`skills/macmini/SKILL.md`](../skills/macmini/SKILL.md)
- Hardware-tested findings: [`skills/macmini/docs/HARDWARE-FINDINGS-2026-04-27.md`](../skills/macmini/docs/HARDWARE-FINDINGS-2026-04-27.md)
- Architecture & troubleshooting: [`skills/macmini/README.md`](../skills/macmini/README.md)
- Agent operational guide: [`skills/macmini/docs/AGENT-GUIDE.md`](../skills/macmini/docs/AGENT-GUIDE.md)
- Cold-start file map and read order: [`skills/macmini/ONBOARDING.md`](../skills/macmini/ONBOARDING.md)
