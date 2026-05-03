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
| Take screenshot | `screencapture -x` (built-in) |
| Get pixel dims | `sips -g pixelWidth/Height` (built-in) |
| Get logical dims | `python3 -c 'from AppKit import NSScreen; ...'` (primary) → `system_profiler SPDisplaysDataType` (fallback) |
| Click | `cliclick c:X,Y` (brew install cliclick) |
| Type | `cliclick t:'text'` |
| Key press | `cliclick kp:<name>` (with `kd:`/`ku:` for modifiers) |
| Open System Settings | `open "x-apple.systempreferences:..."` (built-in) |
| Verify | second `screencapture` + vision compare |

## Sub-commands

| Sub-command | Purpose |
|---|---|
| `/desktop shot` | Capture + sidecar metadata. Foundation primitive. |
| `/desktop click "<target>"` | Vision-guided click with Retina math + safety classifier. |
| `/desktop type "<text>"` | Type text. Always confirms first. |
| `/desktop key <key-or-combo>` | Press key or combo. Dialog-aware classifier. |
| `/desktop status` | Preflight: cliclick? perms? scale? |
| `/desktop setup` | brew install + TCC walkthrough. |

## See also

- Dispatcher: `~/.claude-dotfiles/commands/desktop.md`
- Operational rules: `docs/AGENT-GUIDE.md`
- Architecture & troubleshooting: `README.md`
