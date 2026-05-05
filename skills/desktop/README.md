# /desktop — Architecture, install, troubleshooting

## Install

1. Install cliclick:
   ```
   brew install cliclick
   ```

2. Grant macOS TCC permissions to your terminal app (whichever runs Claude Code):
   - **Screen Recording**: System Settings → Privacy & Security → Screen Recording → toggle on for your terminal.
   - **Accessibility**: System Settings → Privacy & Security → Accessibility → toggle on for your terminal.
   - **Restart your terminal app** after granting (TCC doesn't pick up changes until restart).

3. Run `/desktop status` to verify.

## File layout

```
~/.claude-dotfiles/
├── commands/
│   ├── desktop.md          (dispatcher — tool hierarchy + routing)
│   └── desktop/
│       ├── shot.md         (full-screen capture + sidecar)
│       ├── window.md       (window-only capture for focused vision targeting)
│       ├── click.md        (vision-guided click with Retina math)
│       ├── type.md         (type text)
│       ├── key.md          (key press / combo — dialog-aware)
│       ├── status.md       (preflight + optional smoke test)
│       └── setup.md        (one-time onboarding)
└── skills/desktop/
    ├── SKILL.md            (capability map + channel matrix)
    ├── README.md           (this file)
    └── docs/AGENT-GUIDE.md (operational rules: tiers, Retina, safety, AppleScript recipes, parser, auto-pilot, recovery, smoke test)

~/.claude/commands/         (auto-mirrored from dotfiles via hook; the running CLI reads here)
├── desktop.md
└── desktop/{shot,window,click,type,key,status,setup}.md
```

Skills are NOT mirrored to `~/.claude/` — referenced by absolute path from the command files.

## Architecture

Single dispatcher routes to small sub-commands, each one a primitive that does exactly one thing. Sub-commands compose:

```
/desktop click "Allow button"
   │
   ├─ /desktop status       (preflight; cliclick cached 1h, TCC always re-probed)
   ├─ /desktop shot         (capture + sidecar)
   ├─ vision identifies     (agent reads PNG, returns x_pixel, y_pixel, label)
   ├─ safety classify       (auto-fire / confirm / destructive)
   ├─ retina math           (x_logical = round(x_pixel / scale))
   ├─ cliclick c:X,Y
   ├─ sleep 0.4s
   ├─ /desktop shot         (verify snapshot)
   └─ vision compare        (dialog gone? expected change? else retry once at +1s, then abort)
```

The dispatcher is dumb — it routes. All intelligence lives in (a) the agent's vision and reasoning, and (b) the AGENT-GUIDE rules.

## Troubleshooting

**"Click missed by half"** → Retina math wasn't applied. Every click coord must be `x_pixel / scale`. Read `scale` from `/tmp/desktop/last.json`. See AGENT-GUIDE → Coordinate handling.

**"Nothing happens when I click"** → Accessibility TCC denied. Run `/desktop status`. If denied: System Settings → Privacy & Security → Accessibility → toggle your terminal on, restart terminal.

**"Screenshot shows only wallpaper"** → Screen Recording TCC denied. Run `/desktop status`. Same fix path with the Screen Recording pane.

**"Deep link in /desktop setup doesn't open System Settings"** → macOS version drift. Manual nav: System Settings → Privacy & Security → scroll to Screen Recording / Accessibility.

**"`cliclick: command not found`"** → `brew install cliclick` not run, or shell PATH missing brew. On Apple Silicon brew lives at `/opt/homebrew/bin`; on Intel `/usr/local/bin`. Add to `$PATH` in your shell rc.

**"Stale screenshot from prior session"** → `rm /tmp/desktop/last.{png,json}`. Or just run `/desktop shot` to refresh.

**"Sidecar shows `scale_source: assumed_retina`"** → Both AppKit and system_profiler failed. Scale defaulted to 2.0. Likely fine on Retina; will be wrong on a 1x external monitor. Diagnose: try `python3 -c 'from AppKit import NSScreen; print(NSScreen.mainScreen())'` — if it errors, pyobjc isn't installed (rare; ships with system Python on macOS 11+).

**"Cursor jumps to top-left during status check"** → Expected. The Accessibility probe (`cliclick m:1,1`) moves the cursor to verify TCC. Brief, harmless, visible.

**"Sidecar timestamp_ms is `%3N` instead of a number"** → Someone used `date +%s%3N` instead of the Python timestamp. BSD `date` on macOS doesn't support `%3N`. Fix: `python3 -c 'import time; print(int(time.time()*1000))'`.

## Limitations (v1)

- Main display only (no `-D <n>`).
- No drag-and-drop (deferred; future hook is `cliclick dd:X1,Y1 du:X2,Y2`).
- No window-specific capture.
- No screen recording / video.
- Credential redaction in `/desktop type` is best-effort heuristic, not a guarantee.
