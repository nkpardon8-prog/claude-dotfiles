---
description: Drive a remote Mac mini through Chrome Remote Desktop via the chrome-devtools MCP. Self-resolving — invoke with no sub-command or just reference /macmini in plain English; the agent pre-flights, auto-connects if needed, and infers the right action from context.
argument-hint: "[free-form request, e.g. \"open chrome and check my email\"]"
---

# /macmini — Mac mini Remote

You're driving a Mac mini through Chrome Remote Desktop using the chrome-devtools MCP attached to the user's running Chrome. No daemons, no servers, no Tailscale — just keyboard / vision / `gh gist` transport.

**The full capability map is in `~/.claude-dotfiles/skills/macmini/SKILL.md`.** Read that first. This file is the dispatcher.

## Self-resolution

When the user invokes `/macmini` (with or without arguments) **or references the Mac mini in plain English** ("send X to the mini", "on the mac mini do Y", "use /macmini to do Z"):

1. **Pre-flight.** `mcp.list_pages()` — find the CRD canvas page (URL starts with `https://remotedesktop.google.com/access/session/`). If found, `mcp.select_page({pageId, bringToFront: true})` and skip step 2.
2. **Auto-connect if needed.** If no live canvas, run the `/macmini connect` flow (see `commands/macmini/connect.md`). The user types the PIN themselves when prompted; the agent waits for the canvas to mount.
3. **Vision check.** `mcp.take_screenshot()` to confirm the Mac mini desktop is visible. If black, `mcp.press_key("Shift")` to wake.
4. **Infer the action.** Use the capability matrix below.

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
| Type a lowercase shell command | `mcp.type_text("<cmd>", "Enter")` |
| Press Enter / Tab / Esc / arrow / Page* / Home / End | `mcp.press_key("<key>")` |
| Cmd-shortcut (Cmd+V, Cmd+W, Cmd+Q, Cmd+Space, Cmd+Tab) | `mcp.press_key("Meta+<x>")` |

### Text (anything with capitals, symbols, unicode, multi-line)

| Want to do | Channel |
|---|---|
| Put bytes on mini's clipboard + auto-paste+Enter | `/macmini paste "<text>"` |
| Same, clipboard only (no Enter) | `/macmini paste "<text>"` + "don't submit" |
| Inject a credential | `/macmini paste --secure <ENV_NAME>` |
| Re-fire last paste into another app | `/macmini paste --repaste` |
| Read mini's clipboard back to dev | `/macmini grab` |

### Mouse (cliclick on the mini via gist transport)

| Want to do | Channel |
|---|---|
| Left-click at screenshot pixel (sx, sy) | `/macmini click <sx> <sy>` |
| Right-click | `/macmini rclick <sx> <sy>` |
| Double-click | `/macmini dblclick <sx> <sy>` |
| Drag from (sx1, sy1) to (sx2, sy2) | `/macmini drag <sx1> <sy1> <sx2> <sy2>` |
| Cmd-click / Shift-click / Opt-click / Ctrl-click | `/macmini click <sx> <sy> --mod cmd\|shift\|opt\|ctrl` |
| Move cursor without clicking | `/macmini script 'do shell script "/opt/homebrew/bin/cliclick m:X,Y"'` (rare; usually unnecessary) |

Coordinates `(sx, sy)` are **screenshot pixels** — what `mcp.take_screenshot()` returns naturally. Conversion to mini-physical pixels happens inside each sub-command using cached calibration (`~/.config/claude/macmini-calibration.json`). Run `/macmini measure` once per mini to produce that file; all click sub-commands refuse with a clear error if it is missing or stale.

### Anything cliclick can't do

| Want to do | Channel |
|---|---|
| Activate an app by name | `/macmini script 'tell application "Safari" to activate'` |
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
