# /desktop — Agent Operational Guide

Canonical reference for /desktop runtime behavior. Sub-commands link here. **Consult before every click.**

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

- Vision identifies the Allow button center at `(2400, 1100)` (physical pixels).
- `scale = 2.0`. Logical: `(1200, 550)`.
- Execute: `cliclick c:1200,550`.

If you forget to divide, you click at `(2400, 1100)` logical — way off-screen on a 1512×982 logical screen, missing entirely.

### `screencapture -R` is also physical pixels

If passing a region (`-R "X,Y,W,H"`), the values are physical. Don't pass logical coords here. **Quote the arg.**

### Scale source priority

`last.json.scale_source`: `appkit` (most reliable) → `system_profiler` → `assumed_retina` (treat as a guess).

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
if label matches DESTRUCTIVE:  confirm with EXPLICIT WARNING, then fire
if label matches CONFIRM:      confirm with summary, then fire
else (unknown label):          confirm with summary "click <label> at (x,y)?", then fire
```

### Why "Cancel" / "Don't Allow" are NOT auto-fire

Both are destructive in many contexts: Cancel discards an in-progress save; Don't Allow permanently denies a permission the user might be trying to grant.

### Why deferral labels (Not Now / Later / Skip / Maybe Later) ARE auto-fire

Semantically equivalent — they all defer without committing or destroying state.

### Edge cases

- Single-word match in a destructive context (e.g., "OK" on a "Delete Forever?" dialog) → reclassify as DESTRUCTIVE based on surrounding modal text. **Surrounding destructive keyword overrides button label class.**
- Non-English locale → confirm. Don't guess translations.
- Multiple matches on screen → see "Disambiguation" below.

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
take fresh screenshot (or use last.json if < 2s old, timestamp_ms validated as integer)
detect: is dialog/modal/sheet visible?

if key in SAFE_KEYS:                 fire immediately
if key in DIALOG_SENSITIVE:
    if dialog visible:               confirm (show what dialog is focused)
    else:                            fire
if ANY_MODIFIER_COMBO:               always confirm (cmd+w / cmd+q / cmd+z destructive)
```

### Multi-modifier syntax (release in REVERSE order)

```
cliclick kd:cmd kd:shift t:'s' ku:shift ku:cmd
```

This is Cmd+Shift+S. **Letters/digits use `t:`, NOT `kp:`** (cliclick's `kp:` only accepts the named-key list — `return`, `esc`, `tab`, `arrow-*`, `f1–f16`, etc.). Release modifiers in reverse order — failing to do so can leave them stuck on some macOS versions.

## Combo-string parser

User-friendly input: `cmd+shift+s`. Translate to cliclick syntax at runtime.

### Spec

```
parse_combo(s):
  if not s.strip():
    error("Malformed combo: empty input. Expected form: [mod+]key, e.g. cmd+s or return.")

  tokens = s.lower().strip().split('+')
  ALLOWED_MODS = {'cmd','ctrl','alt','shift','fn'}
  mods = [t for t in tokens[:-1] if t in ALLOWED_MODS]
  unknown = [t for t in tokens[:-1] if t not in ALLOWED_MODS]
  if unknown:
    error(f"Unknown modifier(s): {unknown}. Allowed: cmd, ctrl, alt, shift, fn.")

  last = tokens[-1]
  if last in ALLOWED_MODS:
    error(f"Combo ends with bare modifier '{last}'. Expected form: [mod+]key.")

  NAMED_KEYS = {'return','esc','tab','space','enter',
                'arrow-up','arrow-down','arrow-left','arrow-right',
                'page-up','page-down','home','end',
                'delete','fwd-delete',
                'f1'..'f16', 'num-0'..'num-9'}

  parts = [f'kd:{m}' for m in mods]
  if last in NAMED_KEYS:
    parts.append(f'kp:{last}')
  else:
    # single char (letter / digit / shifted symbol). Lowercased above.
    # cliclick + held shift produces uppercase/shifted glyph correctly.
    parts.append(f"t:'{last}'")
  parts.extend([f'ku:{m}' for m in reversed(mods)])

  return 'cliclick ' + ' '.join(parts)
```

### Examples

```
cmd+shift+s    → cliclick kd:cmd kd:shift t:'s' ku:shift ku:cmd     (Shift produces uppercase S)
cmd+shift+S    → cliclick kd:cmd kd:shift t:'s' ku:shift ku:cmd     (lowercased; same result)
cmd+w          → cliclick kd:cmd t:'w' ku:cmd
cmd+return     → cliclick kd:cmd kp:return ku:cmd
return         → cliclick kp:return
cmd+!          → cliclick kd:cmd t:'!' ku:cmd                       (symbol passes through)
""             → ERROR: empty input
cmd+           → ERROR: trailing modifier with no key
cmd+meta+s     → ERROR: unknown modifier 'meta'
```

## Verification loop

Mandatory after every click / type / key. Catches: vision misidentified target, click landed in dead space, app didn't respond, unexpected dialog appeared.

```
sleep 0.4
/desktop shot   (or /desktop window <app> if focused capture is appropriate)
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

If verify shows an unexpected dialog (e.g., macOS "want to control this computer" TCC prompt over the original target) → **STOP, do NOT click through it.** Report to user — they need to grant the permission first.

## Auto-pilot mode

```
auto_pilot_active(user_request) → bool:
  triggers if EITHER:
    (A) user described a multi-step flow with concrete content for any typing steps
        (e.g. "open Messages, send Arezu 'bruh'") — explicit content + named action
        IS the authorization; or
    (B) user explicitly stated completion authorization
        ("send it" / "go" / "do it").

  if active: do NOT confirm typing the user-stated content; do NOT confirm clicks
             on unknown labels that fit the described task.

  STILL confirm on (auto-pilot does NOT override these):
    - destructive labels (Delete / Discard / Erase / Move to Trash / etc.)
    - ambiguous targets (multiple visible candidates match the user's description)
    - credential-shaped typing values (sk-…, Bearer …, JWT-pattern, long base64)
    - unexpected dialogs in verify-after snapshot
    - actions OUTSIDE the user-described scope
```

**Auto-pilot intentionally OVERRIDES `/desktop type`'s "always confirm" rule** for content the user explicitly stated. This is a deliberate exception, not an accident. Credential-shaped values still confirm even under auto-pilot.

## Disambiguation

When vision identifies multiple plausible matches for the user's described target, **ask before clicking.** Don't pick.

Concrete: search for "Arezu" in Messages may return a 1-on-1 conversation AND a group chat. The user said "message Arezu" — singular. Ask: "1-on-1 with Arezu, or the group?"

Apply to:
- Search dropdowns with multiple matches
- Multiple visible buttons with similar labels (e.g. two "OK" buttons in different windows)
- Multiple instances of an app's window

## State hygiene

Before starting any /desktop flow, take a fresh screenshot and explicitly note:
- Which app is currently frontmost?
- Are there any open modals, sheets, or compose windows?
- Are there any unexpected system dialogs (TCC prompts, update notifications)?

Don't assume the previous flow's state was cleaned up. If a stale compose window from a prior interrupted flow is detected, **surface it to the user** — never silently dismiss (could discard work). Common scenario: a previous session tried to compose an iMessage and was interrupted; the New Message draft is still focused.

## Recovery primitives

Escape hatches when state goes sideways:

| Combo | Effect |
|---|---|
| `Esc` | Dismiss menu / popover / dropdown |
| `Cmd+W` | Close current window (NOT the app) |
| `Cmd+Period` | Cancel current operation (Mac universal cancel) |
| `Cmd+Z` | Undo last action |
| `Cmd+Shift+Z` | Redo |

Recovery actions are **auto-fire** (they're escape hatches, not destructive in themselves). Caveat: `Cmd+Z` after a *destructive* action does NOT retroactively make the destructive action OK to fire without confirmation — destructive labels still confirm UP FRONT.

## AppleScript recipes (Tier 1 / Tier 2)

Higher-tier alternatives to vision-clicking. Test the snippet, fall through to vision-click if it errors. All require Accessibility TCC (same grant as cliclick — no new permission).

### Messages — send iMessage

```bash
osascript -e 'tell application "Messages" to send "<message>" to buddy "<recipient name>" of service "iMessage"'
```

Failure modes: recipient has no iMessage handle (errors); name doesn't match a buddy exactly; service is "SMS" instead of "iMessage". Fallback to send via phone number: `... to participant "+1234567890"`.

### Mail — compose + send

```bash
osascript <<'EOS'
tell application "Mail"
  set newMsg to make new outgoing message with properties {subject:"<subj>", content:"<body>", visible:false}
  tell newMsg to make new to recipient with properties {address:"recipient@example.com"}
  send newMsg
end tell
EOS
```

Failure modes: Mail not configured, account offline, recipient SMTP rejection.

### Notes — create note

```bash
osascript -e 'tell application "Notes" to make new note with properties {name:"<title>", body:"<html-or-plain-body>"}'
```

Notes uses HTML for `body`; plain text works but lacks formatting. Defaults to the default account's first folder.

### Calendar — add event

```bash
osascript <<'EOS'
tell application "Calendar"
  tell calendar "<calendar name>"
    make new event with properties {summary:"<title>", start date:date "Monday, May 5, 2026 10:00 AM", end date:date "Monday, May 5, 2026 11:00 AM"}
  end tell
end tell
EOS
```

Failure modes: calendar name mismatch, date format locale-sensitive (use the format Calendar.app shows in its own UI for the user's locale).

### Reminders — add reminder

```bash
osascript -e 'tell application "Reminders" to make new reminder with properties {name:"<title>", body:"<notes>"}'
```

Add `due date:date "..."` for a deadline.

### System Events — click button by name (Tier 2)

For scriptable apps where the button has an accessible name:

```bash
osascript -e 'tell application "System Events" to click button "Send" of window 1 of process "Messages"'
```

Failure modes: button name mismatch (silent error in some cases); button is in a sheet not a window; element is a `static text` styled as a button (use `click static text "Send" ...`). Fall through to Tier 3/4 vision-click on error.

### List available UI elements (debugging)

```bash
osascript -e 'tell application "System Events" to tell process "<App>" to get every UI element of window 1'
```

## Region & window capture

Default: `/desktop shot` (full screen).

**Use `/desktop window <app>`** when:
- A specific app is the target.
- Other windows or the dock could distract vision.
- The full screen is too large for accurate small-target identification.

**Use `screencapture -x -R "X,Y,W,H"` directly** when:
- Targeting a small UI element within a captured app window.
- Need to crop to a specific toolbar / panel / sub-region.

Pattern: take `/desktop shot` first → identify the rough region of interest in physical pixels → re-capture that region → re-target on the cropped image. Vision is much more accurate on a focused image.

**When to skip cropping (use full-screen):**
- Suspicious of state (unexpected modals, TCC prompts)
- Need to see the menu bar or dock
- Need cross-window context (e.g. comparing two windows)

## Common GUI surfaces

### macOS permission dialogs

Buttons typically: `Don't Allow` (left), `Allow` (right). Sometimes `OK` only.
- AUTO_FIRE on `Allow` / `OK` if user explicitly asked you to grant permission.
- CONFIRM on `Don't Allow` always.

### Generic OK / Cancel sheets

`OK` AUTO_FIRE; `Cancel` CONFIRM.

### App quit-without-saving

`Save` AUTO_FIRE (preserves work); `Don't Save` DESTRUCTIVE (confirm with explicit warning); `Cancel` CONFIRM.

### Search-dropdown navigation

Arrow-key behavior in search dropdowns is **app-specific**:
- Spotlight: arrow-down auto-focuses the first result.
- Many app-local search dropdowns (Messages, Mail): arrow-down does NOT auto-focus; the field stays focused.
- When in doubt: take a verify screenshot after the first arrow-down. If no visual highlight appears, click the desired result directly via vision instead.

### How to ignore the terminal in screenshots

The terminal running Claude Code will usually appear in screenshots — that's expected. Vision must target the actual app surface, not the terminal's representation. If the only visible surface is the terminal, the target app probably isn't visible / focused — bring it forward (`open -a <app>`) before targeting.

## Smoke test (opt-in pipeline validation)

Run via `/desktop status --smoke-test` (or natural-language "run a smoke test"). **Always confirms with the user before running** — moves the cursor and opens Calculator.

Procedure (keyboard-driven; vision-clicking small Calculator buttons would re-introduce the same accuracy problem the test is meant to validate):

```
1. confirm with user.
2. open -a Calculator
3. sleep 1.0                          (let Calculator gain focus)
4. cliclick t:'1'                     (keyboard input — no vision needed)
5. cliclick t:'+'                     (cliclick handles shifted symbols natively in t:)
6. cliclick t:'1'
7. cliclick kp:return                 ('=' on macOS Calculator triggers via Return)
8. sleep 0.4
9. /desktop window Calculator
10. vision reads the DISPLAY REGISTER (NOT a keypad button — the large numeric area at the top of the window).
11. report PASS if register reads "2", FAIL with the actual value otherwise.
12. cliclick kd:cmd t:'w' ku:cmd      (close Calculator; auto-fire — user opted in)
```

If `/desktop window` fails (Quartz unavailable), fall back to `/desktop shot` and crop to the Calculator region via vision before reading the display.

The smoke test validates the full pipeline: TCC, scale detection, cliclick keyboard input, screencapture, vision read. ~5 seconds end-to-end.

## Multi-monitor (deferred)

`screencapture -x` captures the main display only by default. Future: `-D <n>` flag to select display by ID from `system_profiler SPDisplaysDataType`. Sidecar would need a `display: <n>` field; scale derived per-display.

## Drag-and-drop (deferred)

cliclick syntax: `cliclick dd:X1,Y1 du:X2,Y2` (mouse-down at start, mouse-up at end). Both coords logical. Add as `/desktop drag` when needed.

## Troubleshooting TCC deep links

If `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"` doesn't open the right pane (macOS version drift):

1. System Settings → Privacy & Security
2. Scroll to "Screen Recording" or "Accessibility"
3. Toggle the relevant terminal app
4. Restart the terminal (TCC takes effect after restart)
