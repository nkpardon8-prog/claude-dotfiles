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
4. **Infer the action.** Use the routing table below.

## Routing table

| User intent | Channel |
|---|---|
| "connect" / "open the mini" | `/macmini connect` |
| "disconnect" / "close session" | `/macmini disconnect` |
| "status" / "is the mini up?" | `/macmini status` |
| "send X" / "paste X" / "put X on mini's clipboard" — non-secret | `/macmini paste "<X>"` (gist transport) |
| "set the API key on the mini" / "deploy with my OPENROUTER key" / anything involving a credential value | `/macmini paste --secure <ENV_VAR_NAME>` (the agent surfaces a `read -s` prompt on the mini, the user types the secret directly — the value never enters a gist or git history) |
| "what's on mini's clipboard?" / "grab" | `/macmini grab` |
| "what's on the screen?" / "show me" | `mcp.take_screenshot()` direct |
| "type lowercase command" / "run ls/pwd" | `mcp.type_text("<cmd>", "Enter")` |
| "press Enter / Cmd+V / Cmd+space" | `mcp.press_key("<key>")` |
| "open <app>" / "switch to <app>" | Spotlight: `press_key("Meta+space")` → `type_text("<app lowercase>", "Enter")` |
| Multi-step / sudo / multi-file work | Delegate to Mac mini Claude: `type_text("claude --dangerously-skip-permissions", "Enter")`, screenshot to confirm, then `/macmini paste` the prompt → Cmd+V → Enter |
| Any text with capitals / `$@!#%` / unicode | **Always** `/macmini paste`, never `type_text` |

## Hard rules

- **CRD strips Shift on outbound keystrokes.** Capitals and shifted symbols arrive corrupted via `type_text`. Anything not pure-lowercase-unshifted must go through `/macmini paste`.
- **NEVER put credentials in a default `/macmini paste`.** GitHub runs secret-scanning on every gist (including unlisted/secret) and forwards detections to issuer partners (OpenAI, Anthropic, OpenRouter, AWS, Google Cloud, Stripe, Twilio, Slack, ~50 others) within minutes. Auto-revocation typically lands in <5 minutes. Deleting the gist does not unwind it. **Real incident: two OpenRouter keys were burned in <10 minutes each by routing them through `/macmini paste` deploy scripts.** For credential injection use `/macmini paste --secure <ENV_VAR_NAME>` — that mode never puts the value in a gist, the user pastes the secret directly into the mini Terminal at a `read -s` prompt.
- **If the user asks you to "deploy with the API key" or similar, route the credential separately.** Step 1: rewrite their deploy script to reference `$ENV_VAR_NAME` instead of the literal value, push the script via default `/macmini paste`. Step 2: run `/macmini paste --secure ENV_VAR_NAME` to inject the value. Step 3: have the deploy script `source ~/.config/claude/secrets/ENV_VAR_NAME` (or `export ENV_VAR_NAME="$(cat ~/.config/claude/secrets/ENV_VAR_NAME)"`) before running.
- **PIN entry is user-only.** The agent never types, stores, or reads the CRD PIN. When the PIN page appears, hand off to the user.
- **Programmatic clipboard sync (dev → mini) is broken.** CDP-injected `Cmd+V` doesn't trigger CRD's onPaste handler — that's why `/macmini paste` uses gist transport, not `pbcopy`.
- **Don't browse opportunistically.** The chrome-devtools MCP attaches to the user's full Chrome — every tab, every login. Only navigate / click outside the CRD tab when the user explicitly asks. Never click Buy / Send / Pay / Confirm / OAuth / 2FA / security-warning prompts without explicit user instruction.

## Sub-commands (for explicit invocation)

| Sub-command | Purpose |
|-------------|---------|
| `/macmini connect` | Open or resume the CRD session. PIN is user-only. |
| `/macmini paste "<text>"` | gist-based arbitrary-text channel — survives capitals, symbols, unicode, multi-line. |
| `/macmini grab` | Pull text from Mac mini's clipboard back to dev (manual mode). |
| `/macmini disconnect` | Close the CRD tab. |
| `/macmini status` | Quick health audit (canvas, sign-in, clipboard permission, gh auth). |
| `/macmini setup` | One-time setup walkthrough (MCP, gh on both sides, side-panel toggles). |

## See also

- Capability map & channel matrix: [`skills/macmini/SKILL.md`](../skills/macmini/SKILL.md)
- Hardware-tested findings: [`skills/macmini/docs/HARDWARE-FINDINGS-2026-04-27.md`](../skills/macmini/docs/HARDWARE-FINDINGS-2026-04-27.md)
- Architecture & troubleshooting: [`skills/macmini/README.md`](../skills/macmini/README.md)
- Agent operational guide: [`skills/macmini/docs/AGENT-GUIDE.md`](../skills/macmini/docs/AGENT-GUIDE.md)
