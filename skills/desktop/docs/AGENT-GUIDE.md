# /desktop — Agent Operational Guide

This is the canonical reference for /desktop runtime behavior. Sub-commands link here. **You must consult this for every click.**

## Coordinate handling

`screencapture` returns **physical pixels**. `cliclick` consumes **logical points**. On Retina displays the ratio is 2.0 (1 logical point = 2 physical pixels).

### Formula

```
scale = pixel_w / logical_w     # from /tmp/desktop/last.json
x_logical = round(x_pixel / scale)
y_logical = round(y_pixel / scale)
```

Always read `scale` from `last.json` — never hardcode.

### Worked example (Retina, scale 2.0)

- Vision identifies the Allow button center at `(2400, 1100)` in the screenshot (physical pixels).
- `scale = 2.0`.
- Logical: `x_logical = 1200, y_logical = 550`.
- Execute: `cliclick c:1200,550`.

If you forget to divide, you'll click at `(2400, 1100)` logical — which on a 1512×982 logical screen is way off-screen, missing entirely.

### `screencapture -R` is also physical pixels

If passing a region (`-R "X,Y,W,H"`), the values are physical pixels too. Don't pass logical coords here. **Quote the arg** to prevent shell word-splitting.

### Scale source priority

`last.json.scale_source` tells you where scale came from:
- `appkit` — pyobjc / NSScreen (most reliable).
- `system_profiler` — parsed from `system_profiler SPDisplaysDataType` "UI Looks like:" line.
- `assumed_retina` — both above failed; defaulted to 2.0. Treat as a guess; warn if you see this.

## Hybrid safety classifier

Every click runs through this. Auto-fire is a closed, narrow whitelist; everything else confirms.

### Label classes

```
AUTO_FIRE_LABELS    = /^(OK|Allow|Accept|Continue|Got it|Close|Dismiss|Not Now|Later|Skip|Maybe Later)$/i
CONFIRM_LABELS      = /^(Cancel|Don't Allow|Stop|Quit|Sign Out|Log Out)$/i
DESTRUCTIVE_LABELS  = /(Delete|Remove|Discard|Erase|Quit Without Saving|Don't Save|Move to Trash|Empty|Reset|Forget|Uninstall)/i
```

### Decision flow

```
if label matches AUTO_FIRE:    fire immediately, then verify
if label matches DESTRUCTIVE:  confirm with EXPLICIT WARNING ("about to <Delete> — proceed?"), then fire
if label matches CONFIRM:      confirm with summary, then fire
else (unknown label):          confirm with summary "click <label> at (x,y)?", then fire
```

### Why "Cancel" and "Don't Allow" are NOT auto-fire

Both are destructive in many contexts:
- "Cancel" on a "Save changes?" dialog discards work.
- "Don't Allow" on a permission prompt permanently denies the permission the user may be trying to grant.

If the user explicitly asked you to dismiss / cancel a specific dialog, the confirmation is fast (yes/no). If you're acting autonomously, the confirmation is the safety net.

### Why deferral labels (Not Now / Later / Skip / Maybe Later) ARE auto-fire

Semantically equivalent — they all defer without committing or destroying state.

### Edge cases

- Label is a single word match but in a destructive context (e.g., "OK" on a "Delete Forever?" dialog) → vision should detect the surrounding context and reclassify as DESTRUCTIVE. **When the surrounding modal text contains a destructive keyword, treat the action as destructive regardless of the button label.**
- Label is in a non-English locale → confirm. Don't try to translate; ask the user.
- Multiple matches on screen → ask user which one.

## Key-press classifier

Sub-command: `/desktop key`. Apply before every key press.

### Key classes

```
SAFE_KEYS          = {tab, space, arrow-up, arrow-down, arrow-left, arrow-right, page-up, page-down, home, end}
DIALOG_SENSITIVE   = {return, esc, delete, fwd-delete}
ANY_MODIFIER_COMBO = anything with kd:cmd / kd:ctrl / kd:alt
```

### Decision flow

```
take fresh screenshot (or use last.json if < 2s old)
detect: is dialog/modal/sheet visible?

if key in SAFE_KEYS:                 fire immediately
if key in DIALOG_SENSITIVE:
    if dialog visible:               confirm (show what dialog is focused)
    else:                            fire
if ANY_MODIFIER_COMBO:               always confirm (cmd+w / cmd+q / cmd+z destructive)
```

### Multi-modifier syntax (release in REVERSE order)

```
cliclick kd:cmd kd:shift kp:s ku:shift ku:cmd
```

This is Cmd+Shift+S. The release order matters — failing to release in reverse can leave modifiers stuck down on some macOS versions.

## Verification loop

Mandatory after every click / type / key. Catches: vision misidentified target, click landed in dead space, app didn't respond, unexpected dialog appeared.

```
sleep 0.4
/desktop shot
vision-compare to expectation:
  - clicked dialog button → expect dialog gone
  - clicked app element → expect cursor / focus / content change
  - typed text → expect content visible in field
  - pressed key → expect appropriate effect

if no observable change:
    sleep 0.6        # one retry, +1.0s total
    /desktop shot
    if STILL no change → ABORT, report current state
```

If the verify snapshot shows an unexpected dialog (e.g., macOS "want to control your computer" TCC prompt popped up over the original target) → **STOP, do NOT click through it.** Report to user — they need to grant the permission first.

## Common GUI surfaces

### macOS permission dialogs ("X wants to access Y")

- Buttons typically: `Don't Allow` (left), `Allow` (right). Sometimes `OK` only.
- AUTO_FIRE on `Allow` / `OK` if user explicitly asked you to grant permission.
- CONFIRM on `Don't Allow` always.

### Generic OK / Cancel sheets

- `OK` AUTO_FIRE.
- `Cancel` CONFIRM.

### App quit-without-saving

- `Save` AUTO_FIRE (preserves work).
- `Don't Save` DESTRUCTIVE — confirm with explicit warning.
- `Cancel` CONFIRM.

### How to ignore the terminal in screenshots

The terminal running Claude Code will usually appear in screenshots — that's expected. Vision must target the actual app surface, not the terminal's representation of anything. If the only visible surface is the terminal, the target app probably isn't visible / focused — ask the user to bring it forward.

## Multi-monitor (deferred to v2)

`screencapture -x` captures the main display only by default. To extend later: `screencapture -x -D <n>` where `<n>` is the display ID from `system_profiler SPDisplaysDataType`. Sidecar would need a `display: <n>` field and scale derived per-display.

## Drag-and-drop (deferred to v2)

cliclick syntax: `cliclick dd:X1,Y1 du:X2,Y2` (mouse-down at start, mouse-up at end). With Retina math both coords must be logical. Add as `/desktop drag` when needed.

## Troubleshooting TCC deep links

If `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"` doesn't open the right pane (macOS version drift), manual nav:

1. System Settings → Privacy & Security
2. Scroll to "Screen Recording" or "Accessibility"
3. Toggle the relevant terminal app

Restart the terminal after granting.
