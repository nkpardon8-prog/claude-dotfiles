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

## Your full Chrome is also reachable

The chrome-devtools MCP attaches to your existing Chrome instance via
`--remote-debugging-port=9222`. That means you control:

- The CRD tab (the Mac mini canvas) — main use case.
- **EVERY OTHER TAB the user has open.** Inbox, calendar, docs,
  whatever. Same Chrome session, same logins, same cookies, same
  autofill, same extensions.
- The user's full browsing context. Bookmarks, history, saved
  passwords (if you ask Chrome to autofill — DON'T read the password
  store directly).

Practical implications:

- Need to check the user's email or calendar mid-task? Just
  `mcp.list_pages()` lists ALL tabs; `mcp.select_page(uid)` switches
  to one.
- Need to look something up? Open a new tab via
  `mcp.new_page("https://...")` — it lands in the same Chrome.
- Need to test a logged-in web flow? You already have the session.

**Treat this access with care.** You're driving a real human's logged-in
browser — not a sandboxed test profile. Don't:

- Click "Buy", "Send", "Pay", "Confirm payment", or "Delete" without explicit user instruction.
- Read DM threads, email contents, or sensitive documents for context unless the user asks.
- Modify settings, install/remove extensions, or change passwords.
- Approve OAuth consent screens, 2FA approval prompts, or biometric prompts.
- Dismiss security warnings (cert errors, phishing warnings, mixed-content blocks) without surfacing them to the user first.
- Read or copy values from `chrome://settings/passwords`,
  `chrome://settings/autofill`, or any password manager extension.

If the user wants isolation, they can opt into a separate Chrome via
`--user-data-dir=/tmp/chrome-cdp` (documented in setup.md). The
DEFAULT, deliberately, is to attach to their main Chrome — that's
what makes the skill seamless. But the privilege comes with the
discipline above.

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

## Vision is your primary feedback loop

You are driving the Mac mini THROUGH ITS SCREEN. The whole reason this
skill exists (and not SSH) is that you have a live video feed of the
target machine. Use it. Vision is your eyes — keep them on.

### Default loop for any action

```
take_screenshot           # before-state: what's the screen showing now?
[do the thing]            # paste, press_key, click, navigate, etc.
take_screenshot           # after-state: did it land?
[verify visually]         # is the focused window the one you intended?
                          # did the text appear? did the menu close?
                          # is there an error dialog? a permission prompt?
```

### Page-selection footgun (CRITICAL)

`take_screenshot` captures the page that's currently selected via
`select_page` — NOT necessarily the CRD tab. If you navigate away to
check Gmail or any other tab, the next screenshot lands on THAT tab,
not the Mac mini desktop.

**Rule:** at the start of every session, capture the CRD tab's `uid`
into a variable. After any `select_page(other_tab)` call, you MUST
`select_page(crd_uid)` BEFORE the next `take_screenshot` if you intend
to verify Mac mini state. If you forget, you'll be reasoning about
the wrong screen.

```
crd_uid = first page where url starts with "https://remotedesktop.google.com/access/session/"
# ... agent does whatever ...
# Wants to check Mac mini state again:
mcp.select_page(crd_uid)   # MUST do this first
mcp.take_screenshot()      # now this captures the Mac mini canvas
```

This isn't paranoid — it's how you avoid the failure mode of "I sent
the keystrokes, I assume they worked, I'm now operating against a
mental model that diverged from reality 4 steps ago." Without
screenshots you ARE that other agent.

### When vision matters most

- **Before any `press_key`** — verify the right app/window has focus.
  CRD's keystrokes go to whatever's focused on the Mac mini, not the
  app you THINK is focused.
- **After `Cmd+Space`** — Spotlight may have opened on dev-side
  Chrome instead of Mac mini. Screenshot to confirm Mac mini Spotlight
  is showing.
- **After `Cmd+Tab`** — verify you cycled to the intended app, not a
  hidden window.
- **After typing a command in Terminal** — verify the prompt is in
  the right shell (zsh vs bash vs Python REPL vs `claude` REPL).
- **After pasting** — verify the paste landed in the intended field
  (sometimes focus shifts mid-paste).
- **After CRD reconnects** — verify which Mac mini state you've
  reconnected to (locked screen vs logged-in vs prior app state).
- **When ANYTHING UNEXPECTED happens** — first action: screenshot,
  read it carefully, recover from observed state. Never recover from
  imagined state.

### Combining vision with structured text feedback

For STRUCTURED OUTPUT (logs, JSON, long terminal stdout, command
results), screenshot OCR is unreliable — fonts are small, characters
ambiguous (`l`/`1`/`I`, `0`/`O`), usernames similar-looking. Use the
gist-transport pattern (next section) for verbatim text round-trip.

**See also:** the "Terminal output discipline — scroll up before
concluding" section (later in this file) covers the related case of
reading multi-page terminal scrollback. Vision says "screenshot to
verify state"; that section says "scroll up + screenshot multiple to
read the full output." They're complementary — screenshot to know the
command finished; gist (or scroll-then-screenshot) to read what it
printed.

But keep screenshotting too — vision tells you "the command finished
and the prompt is back" while gist tells you "here's exactly what it
printed." Both are useful, often together. Vision is never optional;
gist is supplementary for cases where text fidelity matters.

### Anti-patterns

- **Acting on assumed state.** "I just pressed Enter, so the dialog
  must be closed." Maybe. Screenshot.
- **Single screenshot then 5 actions.** State drifts. Screenshot
  between meaningful actions, not just at session start.
- **Skipping screenshots because the previous action was simple.**
  The simple actions are the ones that silently fail (focus shifted,
  modifier mangled, wrong window in front).
- **Reading screenshot ONCE and proceeding.** When something looks
  off, screenshot AGAIN — terminal output may still be streaming,
  windows may still be animating. Wait + reshoot.

## Agent operational discipline (real-world CRD lessons)

### Direct typing — unshifted chars ONLY

`press_key` types one character at a time. CRD strips Shift modifiers,
so ANY character that requires Shift gets corrupted to its unshifted
base.

**Note:** the table below is for **US keyboard layout**. International
layouts may differ (e.g. AZERTY, QWERTZ shift-mapping is different);
when in doubt, ALWAYS paste rather than type.

| Affected (US layout) | Becomes |
|---|---|
| `:` | `;` |
| `\|` | `\` |
| `&` | `7` |
| `_` | `-` |
| `~` | backtick |
| `< > ( ) ? " * + { } [ ] ^ ! @ # $ %` | corresponding unshifted |

URLs (`https://`), pipes (`|`), shell substitution (`$()`), variable
refs (`$VAR`), redirection (`>`), and most code break under direct
typing.

**Rule:** for ANY string with mixed case OR any of the affected chars
OR length > 20 chars, use `/macmini paste` — never `press_key` per
char.

**Allowed for direct `press_key`:** lowercase letters, digits, `-`,
`/`, `.`, `;`, `=`, `,`, `'`, backtick, space, single function keys
(Enter, Tab, Escape, Arrow*, Page*, Home, End), Cmd+single-letter
shortcuts (`Meta+v`, `Meta+w`, `Meta+q`, `Meta+space`, `Meta+tab`).

### Reading STRUCTURED output — gist transport supplements vision

(For visual state — focus, window position, dialog presence, what's on
screen — keep using `take_screenshot`. See "Vision is your primary
feedback loop" above; this section is about lossless text round-trip
for command output, not a replacement for vision.)

When the Mac mini produces verbatim text you need character-perfect
(logs, JSON, long stdout, command results), screenshot OCR is
unreliable: small terminal fonts, ambiguous characters (`l` vs `1` vs
`I`, `0` vs `O`), unusual usernames. Route it through GitHub Gists:

```bash
# On Mac mini (paste this in via /macmini paste):
# NOTE: omit -p — the default is a SECRET gist (unlisted, requires the
# URL or gh auth to access). -p makes the gist PUBLICLY LISTED, which
# leaks any tokenized stdout, internal hostnames, or sensitive content.
my-script-that-prints-stuff 2>&1 | gh gist create -f output.log -

# On dev side (read it):
gh gist list --limit 1
gh gist clone <id> /tmp/macmini-output
cat /tmp/macmini-output/output.log
```

This works because both machines are signed into the same `gh` account
(per "What's on the Mac mini" — same GitHub account as dev). Secret
gists are accessible only to the gh-authenticated user. Round-trip
is roughly 5 seconds and produces verbatim, lossless text.

**Caveat:** `gh gist clone` ignores `--filename` when there's only one
file in the gist; the cloned file keeps the source filename you used
in `-f`. So pick filenames you'll recognize on the dev side.

### Scripting on the Mac mini — defensive patterns

When pasting bash commands or scripts in via `/macmini paste`, follow
these rules to avoid silent failures:

1. **Use `$HOME` not `~`** — tilde expansion sometimes fails inside
   here-docs, scripts pasted into TUIs, and pipelines. `$HOME` always
   works.
2. **`pkill -9` before restarts** — long-running processes (uvicorn,
   nohup'd daemons) hold ports. A simple `pkill <name>` may not free
   them; `pkill -9 <name>` then a 1-second sleep then restart.
3. **One-line chained commands in unshifted-chars-only when typing** —
   if you somehow can't paste and must type:
   ```
   rm -rf /tmp/x ; gh gist clone <id> /tmp/x ; bash /tmp/x/<file>.sh
   ```
   This pattern (rm + clone + bash) avoids URLs, redirection, and
   substitution while still letting you transport arbitrary content
   via gist.
4. **Hardcode IDs over substitution** — `gui/501` beats `gui/$(id -u)`
   when typing direct (`$(...)` is shifted-char heavy and frequently
   mangles).
5. **`launchctl bootstrap` errors are opaque** — when you see "Could
   not find specified service" or "Unsupported target specifier",
   enumerate first: `launchctl print gui/$(id -u) | grep <label>` (or
   hardcode the user ID per item 4).
6. **Editable Python installs need cache nuke** — for repos installed
   as `pip install -e .`, `git pull` doesn't always pick up changes.
   Recipe: `pkill -9 uvicorn ; find . -name __pycache__ -delete ; uv pip install -e . ; nohup uv run uvicorn ...`
7. **launchd plist filenames vary by app** — for cloudflared and
   similar, don't hardcode: `find $HOME/Library/LaunchAgents -iname "*cloudflar*"` then operate on the discovered path.

### What NOT to attempt (current setup)

These have been tried and don't work in the CURRENT setup. If a future
setup change adds them, update this list:

- **SSH back to Mac mini over Tailscale** — port 22 is closed by default
  on this setup; `ssh 100.x.x.x` times out. Use Mac mini Claude
  (delegation pattern) instead. (If `tailscale ssh` is later enabled
  on the tailnet, this becomes available.)
- **Reverse netcat dev → Mac mini** — macOS Application Firewall on dev
  blocks unsolicited inbound; `nc -l` listeners on dev don't receive
  Mac mini connections in the default firewall config.
- **Tailscale `file cp` / `tailscale ssh`** — not configured on this
  setup. Use the gist transport pattern above. (If Taildrop is later
  enabled, prefer it for binary transfer.)
- **CRD-canvas synthetic clicks via `evaluate_script`** —
  `isTrusted=false`, rejected by the canvas. ALWAYS use
  `mcp.click({uid})` after `take_snapshot()`. This is architectural
  (CDP `Input.dispatchMouseEvent` vs DOM `el.click()`), not a setup
  limitation.

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
