---
description: Index of /macmini sub-commands. Self-resolving — if invoked with no sub-command, or referenced anywhere in the user's message, the agent pre-flights, auto-connects if needed, and infers the right sub-command from context.
argument-hint: "[free-form request, e.g. \"open chrome and check my email\"]"
---

# /macmini

You're driving a Mac mini through Chrome Remote Desktop via the chrome-devtools MCP. Read `~/.claude-dotfiles/skills/macmini/SKILL.md` for the full channel matrix and capabilities. This file is the **dispatcher** — when the user invokes `/macmini` (with or without arguments) or references "the mac mini" in plain English, follow the routing logic below.

## Self-resolution rules

When the user references `/macmini` in any of these forms:

- `/macmini` (no args) — print the sub-command list at the bottom of this file, then ask what they want to do.
- `/macmini <free-form request>` — dispatch per the routing table below.
- Plain English: "use /macmini to do X", "on the mac mini, do X", "send X to the mini" — same routing table.

Do NOT make the user type a sub-command name. The agent picks the right one based on intent.

## Pre-flight (always run first, before any sub-command logic)

1. `mcp.list_pages()` — find a page whose URL starts with `https://remotedesktop.google.com/access/session/`. That's the live CRD canvas. If found, `mcp.select_page({pageId, bringToFront: true})` and skip step 2.
2. If no live canvas: silently run the `/macmini connect` flow (see `commands/macmini/connect.md`). The user will be prompted to type the PIN if it's the first connection in this Chrome session. Wait for the canvas, then continue.
3. `mcp.take_screenshot()` — vision check that you actually see the Mac mini desktop. If the screenshot is black, `mcp.press_key("Shift")` to wake the display, retry once.

## Routing table

| User says / asks | Dispatch to | How to handle |
|---|---|---|
| "connect" / "open the mini" / "start a session" | `/macmini connect` | Run connect flow. If already connected, print `Already connected.` and return. |
| "disconnect" / "close" / "end session" | `/macmini disconnect` | Close the CRD tab. |
| "status" / "is the mini up?" / "health check" | `/macmini status` | Audit table. |
| "send <text>" / "paste <text>" / "put X on mini's clipboard" | `/macmini paste "<text>"` | gist transport. Pre-flight first. |
| "grab" / "what's on mini's clipboard" / "pull text from mini" | `/macmini grab` | Read `navigator.clipboard.readText()` on CRD page. |
| "screenshot" / "what's on the screen" / "show me" | `mcp.take_screenshot()` direct | No sub-command. |
| "type <lowercase command>" / "run <ls/pwd/etc>" | `mcp.type_text("<cmd>", "Enter")` | Direct keyboard. Verify lowercase + unshifted-only first. |
| "press <key>" / "Cmd+<X>" / Spotlight / Cmd-Tab / etc. | `mcp.press_key("<key>")` | Direct. |
| "open <app>" / "switch to <app>" | Spotlight: `press_key("Meta+space")` → `type_text("<app lowercase>", "Enter")` | Verify with screenshot. |
| Multi-step / sudo / multi-file work / "do <complex thing>" | Delegate to Mac mini Claude | `type_text("claude --dangerously-skip-permissions", "Enter")`, wait, screenshot to confirm Claude TUI started, then `/macmini paste "<full instruction>"`, `press_key("Meta+v")`, `press_key("Enter")`. |
| "ssh / scp / send a file to mini" | `/macmini paste` with file content, OR have the user iCloud-Drive it | Mac mini has same iCloud account. |
| "is the mini awake / asleep" | `mcp.take_screenshot()` then check for black/blank | Wake with `press_key("Shift")` if black. |
| Any text containing capitals, `$@!#%^&*()_+{}[]\|\\:"<>?~`, unicode | **Always** `/macmini paste`, NEVER `type_text` | CRD strips Shift; direct typing corrupts these. |

## Disambiguation

If the request is ambiguous (e.g., "send this to the mini" — paste-into-clipboard, or paste-and-execute?), screenshot first to see what app is focused on the mini, then pick the most plausible interpretation. If still unclear, ask the user one short question — never guess on destructive intent (`rm`, `git push`, `kill`, `sudo`).

## Sub-command list (for `/macmini` no-args invocation)

- `/macmini connect` — open or resume the CRD session. PIN entry is user-only (the agent never types the PIN).
- `/macmini paste "text"` — gist-based arbitrary-text channel. Survives capitals, symbols, unicode, multi-line.
- `/macmini grab` — pull text from Mac mini's clipboard back to dev (manual mode).
- `/macmini disconnect` — close the CRD session.
- `/macmini status` — quick health audit (CRD canvas, sign-in, clipboard permission, gh auth).
- `/macmini setup` — first-time configuration walkthrough.

## Capability map

For the full capability map — what's on the Mac mini, how to scroll, when to delegate to Mac mini Claude, limitations, recovery patterns — read `~/.claude-dotfiles/skills/macmini/SKILL.md`. That file is always loaded with the skill and is the agent's first read.
