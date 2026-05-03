---
description: Use as last resort when no CLI / MCP / native tool can interact with the GUI surface (permission dialogs, accept/confirm modals, apps without CLI). Self-resolving — invoke directly or reference in plain English.
argument-hint: "[free-form request, e.g. \"click the Allow button\" or \"accept that prompt\"]"
---

# /desktop — Local macOS screen control

You're driving the local macOS screen via vision + `screencapture` + `cliclick`. Take a screenshot, identify a target with vision, click it at logical coords. Use as a fallback when no CLI / MCP / native tool can reach the GUI surface.

**Full capability map:** `~/.claude-dotfiles/skills/desktop/SKILL.md` — read first.
**Operational rules:** `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md` — Retina math, safety classifier, verification loop. **You must consult this for every click.**

## Self-resolution

When the user invokes `/desktop` (with or without arguments) **or references the screen in plain English** ("click that Allow button", "accept the prompt", "screenshot the window"):

1. **Pre-flight.** Read `/tmp/desktop/permissions.json` if present. If `cliclick_installed_checked_at_ms` is < 1h old, skip the cliclick check; **always re-probe TCC** (probe is fast, TCC can be revoked anytime). On any missing perms → route to `/desktop setup`.
2. **Take a fresh screenshot.** Run `/desktop shot`. Never act on a screenshot older than 2 seconds (measured from `last.json.timestamp_ms`, NOT file mtime).
3. **Vision identifies the target.** Read `/tmp/desktop/last.png`. Return `{x_pixel, y_pixel, label}`.
4. **Apply the safety classifier** (full table in AGENT-GUIDE → "Hybrid safety classifier"). Auto-fire only on the narrow whitelist; everything else confirms.
5. **Convert pixel → logical coords** via `x_logical = round(x_pixel / scale)`, scale read from `/tmp/desktop/last.json`.
6. **Act + verify.** Click via cliclick → sleep 0.4s → re-snap → vision-compare expected state.

## Routing table

| User intent | Sub-command |
|---|---|
| "screenshot" / "show me the screen" / "what's on screen?" | `/desktop shot` |
| "click X" / "accept that" / "dismiss the prompt" / "press the Allow button" | `/desktop click "<target>"` |
| "type X" / "enter X in the field" | `/desktop type "<text>"` |
| "press return" / "press cmd+w" / "hit escape" | `/desktop key <name-or-combo>` |
| "is desktop ready?" / "check perms" | `/desktop status` |
| "set up desktop" / "install cliclick" / "grant perms" | `/desktop setup` |

## Hard rules

- **Always re-snap before clicking.** If `last.json.timestamp_ms` is missing or > 2000ms old, run `/desktop shot` first.
- **Retina math is mandatory.** `screencapture` returns physical pixels; `cliclick` consumes logical points. `x_logical = round(x_pixel / scale)`. Forgetting this misses by half on Retina.
- **Auto-fire list is closed.** Only OK / Allow / Accept / Continue / Got it / Close / Dismiss / Not Now / Later / Skip / Maybe Later auto-fire. Anything else (including **Cancel** and **Don't Allow**) confirms with the user first.
- **Destructive labels (Delete / Remove / Discard / Erase / Quit Without Saving / Don't Save / Move to Trash / Empty / Reset / Forget / Uninstall) require explicit warning** before clicking.
- **Never type credentials.** `/desktop type` confirms with the user, always. Detect long base64-ish blobs / `sk-` prefix / `Bearer ` and refuse without explicit user opt-in.
- **Verify after every action.** If the world doesn't change, sleep 0.6s, re-snap once more. If still no change → abort, report current state.
- **Dialog-aware key presses.** When a dialog/modal/sheet is on screen, even "safe" keys like return and escape can confirm/cancel destructively. Re-classify to confirm in those cases.
- **No multi-monitor in v1.** `screencapture -x` captures the main display only.

## Sub-commands

| Sub-command | Purpose |
|---|---|
| `/desktop shot` | Capture screenshot + scale sidecar. Foundation for everything. |
| `/desktop click "<target>"` | Vision-guided click with Retina math + safety classifier. |
| `/desktop type "<text>"` | Type text. Always confirms first. |
| `/desktop key <key-or-combo>` | Press key or combo. Dialog-aware classifier. |
| `/desktop status` | Preflight: cliclick installed? TCC granted? Detected scale? |
| `/desktop setup` | One-time setup: brew install cliclick + TCC walkthrough. |

## See also

- Capability map: `~/.claude-dotfiles/skills/desktop/SKILL.md`
- Agent operational guide: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md`
- Architecture & troubleshooting: `~/.claude-dotfiles/skills/desktop/README.md`
