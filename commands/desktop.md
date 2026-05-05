---
description: Self-resolving local-mac control. Tries CLI/AppleScript first; vision-clicks only when no scriptable handle exists. Handles permission dialogs, accept/confirm modals, and apps without CLI. Invoke directly or reference in plain English.
argument-hint: "[free-form request, e.g. \"click the Allow button\" or \"send Arezu 'bruh' on iMessage\"]"
---

# /desktop — Local macOS screen control

Drive the local macOS GUI. **Try the highest-tier tool that reaches the target — vision-clicking is the LAST resort, not the default.**

**Full capability map:** `~/.claude-dotfiles/skills/desktop/SKILL.md`
**Operational rules:** `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md` — Retina math, safety classifier, AppleScript recipes, combo-string parser, auto-pilot, recovery primitives. **Consult before every click.**

## Tool hierarchy

Pick the highest tier that fits the task. Emit a one-line trace `[desktop] Tier <N>: <tool>` so the routing is observable.

| Tier | Use when | Tool |
|---|---|---|
| **0** | Open a URL, launch an app | `open <url>` / `open -a <app>` |
| **1** | Action in a scriptable Mac app (Messages send, Mail compose, Notes create, Calendar add, Reminders add) | `osascript -e 'tell application "<App>" to ...'` — see AGENT-GUIDE → AppleScript recipes |
| **2** | Click a NAMED button in a scriptable app's window | `osascript -e 'tell application "System Events" to click button "<Name>" of window 1 of process "<App>"'` |
| **3** | Vision-target an element in ONE app's window (cropped image = better accuracy) | `/desktop window <app>` → `/desktop click "<target>"` |
| **4** | Full-screen vision-click (system dialogs, no scriptable handle) | `/desktop shot` → `/desktop click "<target>"` |

### When to skip /desktop entirely

- "Open eBay search for X" → Tier 0: `open "https://www.ebay.com/sch/i.html?_nkw=..."`
- "Send Arezu 'bruh' on iMessage" → Tier 1: `osascript -e 'tell application "Messages" to send "bruh" to buddy "Arezu" of service "iMessage"'`
- "Click the Send button in Messages" → Tier 2: `osascript -e 'tell application "System Events" to click button "Send" of window 1 of process "Messages"'`
- "Click the Allow button on a system permission dialog" → Tier 4 (no scriptable handle on system dialogs): `/desktop click "Allow"`

If a higher-tier attempt fails (AppleScript errors, button name mismatch), fall through to the next tier and emit a new trace.

## Self-resolution

When the user invokes `/desktop` (or references the screen in plain English):

1. **Pre-flight.** Read `/tmp/desktop/permissions.json`. cliclick check cached 1h; **always re-probe TCC** (probe < 200ms; TCC can revoke anytime). Missing perms → `/desktop setup`.
2. **State hygiene.** If a prior /desktop flow may have left state (orphaned compose, unexpected modal), take a fresh screenshot and surface it before proceeding. Don't silently dismiss — could discard work.
3. **Decide tier.** Per the Tool hierarchy above. Emit `[desktop] Tier <N>: <tool>` trace.
4. **Execute.**
   - **Tier 0–2:** run the shell command. On failure, fall through to next tier with new trace.
   - **Tier 3–4:** shot / window → vision identify → safety classify (AGENT-GUIDE) → Retina-convert (`x_logical = round(x_pixel / scale)`) → cliclick → verify (re-snap + compare).

## Routing table (for Tier 3/4)

If you've decided vision-click is the right tier, here's how to pick the sub-command:

| User intent | Sub-command |
|---|---|
| "screenshot" / "show me the screen" | `/desktop shot` (full-screen) |
| "screenshot just <app>" / focused capture | `/desktop window <app>` |
| "click X" / "accept that" / "dismiss the prompt" | `/desktop click "<target>"` |
| "type X" | `/desktop type "<text>"` |
| "press return" / "press cmd+w" / "hit escape" | `/desktop key <combo>` |
| "is desktop ready?" / "check perms" | `/desktop status` (add `--smoke-test` for end-to-end pipeline check) |
| "set up desktop" / "install cliclick" / "grant perms" | `/desktop setup` |

## Hard rules

- **NEVER ask the user which sub-command to use.** The user types `/desktop <free-form description>` or describes the task in plain English ("send Arezu 'bruh'", "click the Allow button", "screenshot Chrome"). YOU pick the tier and sub-command from the Tool hierarchy + Routing table above. Sub-commands (`shot`, `window`, `click`, `type`, `key`, `status`, `setup`) are internal primitives, not required user syntax. Only mention a sub-command name to the user when reporting what you did.
- **Try higher tiers first.** Don't reach for vision-click when `osascript` would do it in one line.
- **Always re-snap before clicking.** Stale screenshots (> 2s by `last.json.timestamp_ms`, validated as integer) → `/desktop shot` or `/desktop window` first.
- **Retina math is mandatory.** `x_logical = round(x_pixel / scale)`. Forgetting it misses by half on Retina (the #1 failure mode).
- **Auto-fire list is closed.** Only OK / Allow / Accept / Continue / Got it / Close / Dismiss / Not Now / Later / Skip / Maybe Later. Cancel and Don't Allow CONFIRM.
- **Destructive labels** (Delete / Remove / Discard / Erase / Quit Without Saving / Don't Save / Move to Trash / Empty / Reset / Forget / Uninstall) require explicit warning before clicking.
- **Verify after every action.** No observable change in 0.4s → sleep 0.6s, re-snap once more. Still nothing → abort.
- **Dialog-aware key presses.** Return / Esc / Delete / Fwd-delete reclassify to confirm when a dialog is visible.
- **Auto-pilot mode** (per AGENT-GUIDE → "Auto-pilot mode") suppresses per-step typing confirmations when the user described a complete end-to-end task with content (e.g. "send Arezu 'bruh'"). Destructive / ambiguous / credential-shaped values still confirm.

## Sub-commands

| Sub-command | Purpose |
|---|---|
| `/desktop shot` | Full-screen screenshot + scale sidecar. Foundation primitive. |
| `/desktop window <app>` | Window-only screenshot for higher-accuracy vision targeting. |
| `/desktop click "<target>"` | Vision-guided click with Retina math + safety classifier. |
| `/desktop type "<text>"` | Type text. Confirms unless under auto-pilot mode (see AGENT-GUIDE). |
| `/desktop key <combo>` | Press key or combo. Combo-string parser (`cmd+shift+s` etc.) per AGENT-GUIDE. |
| `/desktop status` | Preflight: cliclick? TCC? scale? Quartz? Optional `--smoke-test` end-to-end check. |
| `/desktop setup` | One-time setup: brew install cliclick + TCC walkthrough. |

## See also

- Capability map: `~/.claude-dotfiles/skills/desktop/SKILL.md`
- Agent operational guide: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md`
- Architecture & troubleshooting: `~/.claude-dotfiles/skills/desktop/README.md`
