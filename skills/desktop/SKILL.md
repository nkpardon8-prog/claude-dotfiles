# /desktop — Local macOS Screen Control

A modular slash-command family that lets Claude Code take over the local Mac screen via vision + screenshots + coordinate clicks. The local-machine sibling of `/macmini` (which drives a remote Mac via Chrome Remote Desktop).

## When to use

- A GUI prompt is blocking progress and there's no CLI / MCP equivalent (macOS permission dialog, app-specific confirm modal, app with no scriptable surface).
- You need to dismiss / accept / continue a dialog as part of a larger task.
- The user explicitly asks you to click / type / press something on screen.

## When NOT to use

- The task has a CLI / MCP / native equivalent — use those first.
- The target is on a remote machine — use `/macmini`.
- Sensitive operations like entering passwords, confirming financial transactions, OAuth grants, 2FA approvals — bounce back to the user.

## Architecture

```
User says: "click the Allow button"
           │
           ▼
/desktop dispatcher
           │
   ┌───────┼────────┐
   ▼       ▼        ▼
status  shot     click ──▶ cliclick c:X,Y ──▶ verify (re-shot)
                  │                              │
                  └──[safety classifier]─────────┘
```

State at `/tmp/desktop/`:
- `last.png` — most recent screenshot
- `last.json` — `{path, timestamp_ms, pixel_w, pixel_h, logical_w, logical_h, scale, scale_source, display}`
- `permissions.json` — TCC + cliclick install state

## Channel matrix

| Action | Tool |
|---|---|
| Take screenshot (full) | `screencapture -x` (built-in) |
| Take screenshot (window-only) | `screencapture -x -l <id>` (id via Quartz / pyobjc) |
| Get pixel dims | `sips -g pixelWidth/Height` (built-in) |
| Get logical dims | `python3 -c 'from AppKit import NSScreen; ...'` (primary) → `system_profiler SPDisplaysDataType` (fallback) |
| Open URL / launch app (Tier 0) | `open <url>` / `open -a <app>` (built-in) |
| Scriptable app action (Tier 1) | `osascript -e 'tell application "<App>" to ...'` (built-in) |
| UI scripting click-by-name (Tier 2) | `osascript -e 'tell application "System Events" to click button "<X>" of window 1 of process "<App>"'` |
| Vision-click (Tier 3/4) | `cliclick c:X,Y` (brew install cliclick) |
| Type | `cliclick t:'text'` (letters/digits/symbols all use t:) |
| Key press (named) | `cliclick kp:<name>` — return, esc, tab, arrow-*, f1–f16, etc. |
| Key combo (mods + letter) | `cliclick kd:<mod> t:'<char>' ku:<mod>` — letters/digits use t:, NOT kp: |
| Open System Settings | `open "x-apple.systempreferences:..."` (built-in) |
| Verify | second `screencapture` + vision compare |

## Sub-commands

| Sub-command | Purpose |
|---|---|
| `/desktop shot` | Full-screen screenshot + sidecar metadata. Foundation primitive. |
| `/desktop window <app>` | Window-only screenshot for higher-accuracy vision targeting. |
| `/desktop click "<target>"` | Vision-guided click with Retina math + safety classifier. |
| `/desktop type "<text>"` | Type text. Confirms unless under auto-pilot mode (see AGENT-GUIDE). |
| `/desktop key <combo>` | Press key or combo. Combo-string parser (`cmd+shift+s` etc.). |
| `/desktop status` | Preflight: cliclick? TCC? scale? Quartz? Optional `--smoke-test`. |
| `/desktop setup` | brew install + TCC walkthrough. |

## See also

- Dispatcher: `~/.claude-dotfiles/commands/desktop.md`
- Operational rules: `docs/AGENT-GUIDE.md`
- Architecture & troubleshooting: `README.md`
