# macmini — drive a remote Mac mini through Chrome Remote Desktop

You're driving a Mac mini through Chrome DevTools MCP attached to the user's
running Chrome instance. CRD renders the Mac mini desktop into a single canvas;
you control it via keyboard (press_key), screenshots (take_screenshot), and a
focused click on the canvas. Paste payloads via the dedicated /macmini paste
command which uses CRD's built-in clipboard sync.

## Slash commands

- `/macmini connect`          — open or resume the CRD session
- `/macmini paste "text"`     — send text to Mac mini's clipboard, then Cmd+V
- `/macmini grab`             — pull text from Mac mini's clipboard to dev (manual: Mac mini side does Cmd+C first)
- `/macmini grab driven`      — same, but auto-sends Cmd+A then Cmd+C on canvas (fragile — see Limitations)
- `/macmini disconnect`       — close the CRD session
- `/macmini status`           — quick "is the canvas up + signed in?" check

## What's on the Mac mini

You can assume the Mac mini has:

- macOS (ARM64 / Apple Silicon)
- A user account with admin rights
- **Claude Code installed** — invoke it as `claude` from Terminal. This is the
  delegation target for anything multi-step, anything needing sudo, or anything
  where local file/git context matters more than visual feedback.
- **Same GitHub account as dev** — `gh` CLI is signed in to the same user. You
  can `gh repo clone`, `gh pr create`, `gh api`, etc. without re-auth. Private
  repos accessible from dev are accessible here too.
- **Same iCloud account as dev** — iCloud Drive, Keychain, Notes, Reminders all
  sync. Useful for moving files between machines without setting up file
  transfer (drop in `~/Library/Mobile Documents/com~apple~CloudDocs/`).
- **Chrome installed and signed into the same Google account** — so any
  bookmarks, extensions, autofill, and `remotedesktop.google.com` device list
  state are mirrored. Useful for testing web flows that need a logged-in user.
- Standard dev tools: Homebrew, git, go, python3, node (verify before assuming
  specific tools by running `which <tool>` via paste-into-Terminal)
- Safari, Terminal.app, plus whatever's in the dock

## How to control it

### Paste long text → /macmini paste

For ANY payload with mixed case, special chars (`_:$|&>~`), JSON, code, or
longer than 20 chars, ALWAYS use `/macmini paste`. Direct typing via `press_key`
mangles the Shift modifier — `HELLO_WORLD` arrives as `hello-world`. Paste
bypasses this because it's a bytes-blob event, not character-by-character.

### Type single keys / shortcuts → press_key

Reliable: arrow keys, Page Up/Down, Home/End, Space, Enter, Tab, Escape,
Cmd+single-letter (Cmd+V, Cmd+W, Cmd+Q, Cmd+S, Cmd+Tab, Cmd+Space).
Unreliable: per-character typing of capitals or `_:$|&>~` (Shift mangling).

### See the screen → take_screenshot

Captures the CRD canvas, which is the actual Mac mini desktop pixels.
Use this liberally to verify state before/after actions.

### Scroll to see content beyond the viewport

**You can and should scroll.** If you take a screenshot and don't see what you
need, scroll and screenshot again. Stitch context across multiple screenshots.

| To do this | Press this |
|---|---|
| Scroll one screenful down | `press_key("PageDown")` or `press_key("Space")` |
| Scroll one screenful up | `press_key("PageUp")` or `press_key("Shift+Space")` |
| Scroll one line | `press_key("ArrowDown")` / `press_key("ArrowUp")` |
| Jump to bottom of document | `press_key("End")` (or `press_key("Meta+ArrowDown")`) |
| Jump to top of document | `press_key("Home")` (or `press_key("Meta+ArrowUp")`) |
| Read a long Terminal output | `press_key("PageDown")` × N, screenshot between presses |

DO NOT use the MCP `drag` tool to scroll — it's a click-drag, not a scroll
wheel; Mac apps interpret it as text selection or content drag.

### Terminal output discipline — scroll up before concluding

The first screenshot of a remote terminal (CRD canvas, VNC, ssh in a TUI)
captures only the bottom of the buffer. Most agent or command output is
longer than one viewport. Apply this discipline whenever the visible
terminal could plausibly have produced more output than fits in one page —
which is almost always for any non-trivial response:

1. **Assume there is content above the viewport.** Don't draw conclusions
   from one screenshot.
2. **Scroll up** via `press_key("PageUp")` (or `Shift+PageUp` in some
   terminals; `Meta+ArrowUp` jumps to top of buffer in many apps) and take
   additional screenshots until you reach the top of the relevant response.
   In Terminal.app, scrollback is searched with `Cmd+F`.
3. **Read screenshots in order from oldest (top) to newest (bottom)** before
   deciding next action.
4. **For structured output** (tables, JSON, full reports, diffs) do not
   trust a partial view — capture all of it across multiple screenshots.
5. **Return focus to the live tail before sending the next keystroke** —
   `press_key("End")` or `press_key("PageDown")` until you're back at the
   bottom. Otherwise input goes into scrollback and is lost.

This applies symmetrically to any scrollable content — long Chrome pages,
chat threads, log viewers, code editors. Same pattern: scroll up, capture,
read in order, return to live tail.

### Focus an app → Spotlight

`press_key("Meta+Space")` → `/macmini paste "<appname>"` → `press_key("Enter")`.
This requires CRD to be in **full-screen mode with "Send System Keys" enabled**
(set by `/macmini connect`). In windowed mode, Cmd+Space may open dev-side
Spotlight instead.

If Spotlight fails, fall back to clicking the dock or using App Switcher
(Cmd+Tab — also requires Send System Keys).

### Click somewhere specific on the canvas

The MCP `click(uid)` only clicks the centerpoint of the canvas. For
pixel-precise clicks, the MCP needs to be started with `--experimental-vision`
which exposes `click_at(x, y)`. If it isn't, your only option for off-center
clicking is to use Mac mini's keyboard-only navigation (Tab, arrow keys).

### Run shell commands

Open Terminal via Spotlight, `/macmini paste` the command, `press_key("Enter")`.
For multi-step shell work, prefer delegation (see below).

## Delegation pattern — when to use Mac mini Claude

For any task that's multi-step, needs sudo, involves complex shell pipelines,
or where the Mac mini's local context (file tree, git state, running
processes) matters more than what's visible on screen:

1. `/macmini paste "claude"`   (focus a Terminal first via Spotlight)
2. `press_key("Enter")`
3. Wait for the Mac mini Claude session to start
4. `/macmini paste "<your instruction in lowercase prose>"`
5. `press_key("Enter")`
6. `take_screenshot` to read the response; scroll if needed
7. Iterate as needed

Lowercase prose forwards through CRD reliably. Mac mini Claude has full
local privileges and can do anything you'd do in a normal Claude Code session
on that machine.

## Limitations & gotchas

- **Shift mangling on direct typing** — always paste for shifted characters.
- **`Cmd+Tab` and `Cmd+Space` need full-screen + Send System Keys** to be
  reliable; `/macmini connect` sets this for you.
- **Sudo prompts need physical password typing** unless Touch ID is configured
  on the Mac mini (it isn't by default). For sudo-needing tasks, delegate to
  Mac mini Claude or have the user enter the password.
- **No built-in file transfer** — paste a `curl` URL into Mac mini and have
  it download. For binaries, host on a public URL or have Mac mini Claude
  fetch from a known location.
- **Clipboard sync ceiling ~64KB** — `/macmini paste` chunks anything larger;
  recipient must concatenate.
- **Mini → dev clipboard direction is brittle** — if `/macmini grab` returns
  empty or stale, retry; or have Mac mini Claude `pbcopy` explicitly first.
- **Driven grab (`/macmini grab driven`)** does NOT work for Terminal
  scrollback — Cmd+A only selects visible region or nothing in Terminal. Use
  manual mode for Terminal output.

## Recovery patterns

- **Stray Cmd+modifier opened the wrong app** → `press_key("Meta+q")` to
  close, Spotlight again to refocus.
- **Lost focus on canvas** → `mcp.click(canvas_uid)` (or `click_at(1,1)` if
  `--experimental-vision`) to re-grab focus.
- **Mac mini Claude session died** → re-paste `claude`, press Enter.
- **Sign-in expired** → `/macmini connect` will detect and tell you to sign in.
- **Clipboard sync stopped working** → reload the CRD tab, re-enable sync via
  the side menu (right-edge arrow → "Enable clipboard synchronization" →
  Begin); permission grant should still be in effect. If permission itself
  was revoked, visit `chrome://settings/content/clipboard`, find
  `https://remotedesktop.google.com`, set to Allow.
- **Rogue keystrokes opened System Settings or another app mid-task** —
  Cmd+Q to close, Spotlight back to the intended app, `pwd` or `clear` in
  Terminal to re-confirm focus state before resuming.
