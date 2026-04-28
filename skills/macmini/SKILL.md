# macmini — drive a remote Mac mini through Chrome Remote Desktop

> **Hardware-tested 2026-04-27.** See `docs/HARDWARE-FINDINGS-2026-04-27.md` for
> the full reality matrix. Reliable channels: vision + lowercase typing +
> Cm­d-modifier shortcuts + gh gist for arbitrary text. Auto-grant install/cdp/ui
> have been removed — they don't work in stock Chrome+CRD.

You drive a Mac mini through Chrome DevTools MCP attached to the user's running
Chrome instance. CRD renders the Mac mini desktop into a single canvas; you
control it via keyboard (`press_key`/`type_text`), screenshots
(`take_screenshot`), and **gh gist transport** for arbitrary text. There is no
side-channel server, no Tailscale, no clipboard auto-grant. CRD's "Synchronize
clipboard" and "Send system keys" toggles are clicked **once by the user** at
first connection — they persist across reconnects.

## How to send anything to the Mac mini — the channel matrix

This is your decision tree. Match the kind of thing you want to send to the row, then call the EXACT slash command or MCP tool listed. Do NOT improvise — the listed channel is the only one verified to survive CRD's keyboard pipeline (hardware-tested 2026-04-27).

| Want to send / do | Channel — call this verbatim | Why |
|---|---|---|
| **Lowercase shell command** (`ls`, `pwd`, `cd /tmp/p`, `git fetch`, `pgrep -fl foo`) | `mcp.type_text("<cmd>", "Enter")` | Lowercase + unshifted symbols (`-`, `/`, `.`, `;`, `=`, `,`, `'`, backtick, space) survive CRD intact. |
| **Single key or Cmd-shortcut** (`Enter`, `Tab`, `Esc`, `Meta+v`, `Meta+w`, `Meta+space`, `Control+c`) | `mcp.press_key("<key>")` | Forwarded by CRD's "Send system keys" (already on after one-time setup). |
| **Arbitrary text** — anything with capitals, `$@!#%^&*()`, `_+{}[]\|\\:"<>?~`, unicode, multi-line | **Run `/macmini paste "<text>"`** — by default the skill ALSO fires `Meta+v` + `Enter` after the wrapper completes, so the payload lands in the focused app. To stop at clipboard (no submit), say "just to the clipboard" / "don't submit" — the skill skips `Enter`. To re-paste the same payload into a different app, just bring the new app to focus and fire `mcp.press_key("Meta+v")` — clipboard is still valid, no new gist needed. | The skill handles the gist round-trip + auto-paste. Don't reimplement it. |
| **A whole script / bash payload** to run on Mac mini | **Run `/macmini paste`** with the script as a `bash <<'EOF' ... EOF` block, or wrap it in `cat > /tmp/p/run.sh <<'EOF' ... EOF; bash /tmp/p/run.sh` | Same gist channel; full Unicode + arbitrary chars preserved. |
| **A file** on Mac mini | Either `/macmini paste` with the content (mini ends up with `/tmp/p/<filename>`), or have mini Claude `gh gist clone` itself | gist transport is the file channel too. |
| **Read terminal output back to dev** | Two paths: (a) `mcp.take_screenshot()` for a quick visual; (b) on mini, type `<cmd> > /tmp/o.log; gh gist create -f o.log /tmp/o.log` and on dev `gh gist clone <id> /tmp/back; cat /tmp/back/o.log` | Vision OCR is unreliable for `l`/`1`/`I`, `0`/`O`. Reverse gist for verbatim text. |
| **See current screen state** | `mcp.take_screenshot()` | Always-on feedback loop. Cheap. Use liberally before/after every action. |
| **Open or resume the CRD session** | **Run `/macmini connect`** | Handles sign-in detection, device tile click, reconnect overlay. The user types the PIN themselves — the agent never types, stores, or reads the CRD PIN. |
| **Set up the skill the first time** | **Run `/macmini setup`** | One-time: MCP, gh on both sides, credentials, side-panel toggles. |
| **Quick health check** ("is the canvas up?") | **Run `/macmini status`** | Audit: CRD canvas, sign-in, clipboard permission, gh auth. |
| **Pull text from Mac mini → dev clipboard** (one-shot) | **Run `/macmini grab`** | User does Cmd+C on mini side; agent reads via `navigator.clipboard.readText()` on the CRD page. |
| **End the session** | **Run `/macmini disconnect`** | Closes the CRD tab. No server-side cleanup needed. |
| **Run multi-step Mac-mini-local work** (sudo, multi-file edits, anything where local file/git context matters more than vision) | Type `claude` in mini's Terminal (lowercase — works) and delegate to Mac mini Claude via `/macmini paste`-delivered prompts | Faster + more reliable than driving every keystroke from dev. |

**The rule that matters most:** if the string you want to send contains ANY of `A-Z`, `$@!#%^&*()_+{}[]\|\\:"<>?~`, or any non-ASCII (日本語, é, etc.), you MUST use `/macmini paste`. Don't call `mcp.type_text` with that string — CRD strips Shift and remaps shifted keys to the wrong character. Verified failure mode: `HELLO_WORLD` → `hello-world`, `$(date)` → `+%date+`, `(test)` → `;test;`.

**The other rule that matters most:** before reasoning about Mac mini state, take a screenshot. Vision is the source of truth — your assumptions about which window is focused, whether a command finished, whether a dialog is up, are wrong more often than you'd think. After `mcp.select_page(other_tab)`, you MUST `mcp.select_page(crd_uid, bringToFront: true)` before the next `take_screenshot` if you want to see the Mac mini.

## Slash commands

- `/macmini connect`          — open or resume the CRD session
- `/macmini paste "text"`     — gist-based arbitrary-text → Mac mini clipboard
- `/macmini grab`             — pull text from Mac mini's clipboard to dev (manual: Mac mini side does Cmd+C first)
- `/macmini disconnect`       — close the CRD session
- `/macmini status`           — quick "is the canvas up + signed in?" check
- `/macmini setup`            — one-time setup walkthrough

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

Practical implications (only act on these when the user EXPLICITLY asks
— do not browse opportunistically for context, atmosphere, or
"helpfulness"):

- If the user explicitly asks you to check their email or calendar, you
  can — they're accessible via `mcp.list_pages()` →
  `mcp.select_page(uid)`.
- If the user explicitly asks you to look something up, open a new tab
  via `mcp.new_page("https://...")` — it lands in the same Chrome.
- Logged-in web flows can be tested when the user asks for them — you
  have the session.

**Treat this access with care.** You're driving a real human's logged-in
browser — not a sandboxed test profile. Don't:

- Click "Buy", "Send", "Pay", "Confirm payment", or "Delete" without explicit user instruction.
- Submit forms, Confirm actions, or Approve requests outside of
  payment wording — account changes, friend/connection requests,
  membership changes, profile updates, contact removals, calendar
  invite responses, etc. — without explicit user instruction.
- Initiate password resets, account recovery flows, "forgot password"
  links, or any flow that triggers a verification email/SMS.
- Click links inside emails — phishing surface; if a link needs to be
  followed, copy the URL, surface it to the user, and let them
  approve.
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

## What's on the Mac mini (rely on these — fully dialed)

You can assume the Mac mini has the following — no setup required, no need to verify before use:

- macOS (ARM64 / Apple Silicon), user account with admin rights.
- **Claude Code installed.** Invoke it as `claude` in Terminal. **For agent-driven sessions on the mini, run it as `claude --dangerously-skip-permissions`** — this is a trusted machine fully owned by the same user, and skipping permission prompts removes the keyboard-typing dance for "Allow / Deny" dialogs that the Shift-strip pipeline can't reliably handle. The `claude` command is all lowercase so `mcp.type_text("claude --dangerously-skip-permissions", "Enter")` works directly.
- **Same GitHub account as dev** — `gh` CLI signed in. You can `gh repo clone`, `gh pr create`, `gh api`, `gh gist clone/create` without re-auth. Private repos accessible from dev are accessible here too. **This is what makes `/macmini paste` work** (gist transport requires gh on both sides — already done).
- **Same dotfiles repo loaded** — `~/.claude-dotfiles/` is checked out on the mini and tracking the same upstream as dev. Mac mini Claude has the same skills, slash commands, rules, and CLAUDE.md. So when you delegate to mini Claude, it has identical tooling — including the macmini skill itself if you ever need recursion (don't).
- **Same iCloud account** — iCloud Drive, Keychain, Notes, Reminders sync. Drop a file in `~/Library/Mobile Documents/com~apple~CloudDocs/` on either side and it appears on the other (slower than gist; gist is preferred for agent-driven transfer).
- **Chrome signed into the same Google account** — bookmarks, extensions, autofill, and `remotedesktop.google.com` device list state are mirrored. Useful for testing web flows that need a logged-in user.
- **Standard dev tools available**: Homebrew, git, go, python3, node. Don't burn keystrokes verifying `which <tool>` unless something breaks — assume they're there.
- Safari, Terminal.app, plus whatever's in the dock.

### Practical implications for the agent

- **Default to delegation for anything non-trivial.** Three+ Mac-mini-local steps, anything needing sudo, anything reading multiple files: type `claude --dangerously-skip-permissions` in mini Terminal (via `mcp.type_text`), then send the prompt via `/macmini paste`. Mac mini Claude finishes the work natively in seconds; you keep watching via vision.
- **The dotfiles parity means** mini Claude already knows project conventions, has the same MCP servers configured, and shares the credentials catalog at `~/.config/claude/credentials.md`. Don't re-explain context that's in CLAUDE.md — mini Claude has the same one.
- **For multi-step work, the typical flow is:** (1) `/macmini connect` to land in the canvas, (2) `mcp.type_text("claude --dangerously-skip-permissions", "Enter")`, (3) wait ~3s for Claude to spin up (screenshot to verify), (4) `/macmini paste "<your detailed prompt>"`, (5) press Enter, (6) screenshot every ~10s to track progress, (7) when done, gist the result back via `gh gist create` from mini side if you need verbatim output.

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

SECURITY: secret gists are unlisted but NOT encrypted — GitHub staff can
read them, they persist forever, and the URL (if leaked) gives anyone
access. NEVER pipe through gist transport:

- Anything containing tokens, passwords, or `Authorization:` headers
- `op://` references (after they've been resolved to plaintext)
- `gh auth status` or any `~/.config/` credential file content
- The output of any command that prints env vars (`env`, `printenv`)

If you need to debug a command that handles secrets, run it without
`-v` or `2>&1`; redirect the secret part to `/dev/null` and gist only
the non-sensitive structured output.

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

## Scrolling

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

## More control primitives

### Focus an app → Spotlight

`press_key("Meta+Space")` → `/macmini paste "<appname>"` → `press_key("Enter")`.
This requires CRD to be in **full-screen mode with "Send System Keys" enabled**
(set by `/macmini connect`). In windowed mode, Cmd+Space may open dev-side
Spotlight instead.

If Spotlight fails, fall back to clicking the dock or using App Switcher
(Cmd+Tab — also requires Send System Keys).

### Click somewhere specific on the canvas

The MCP `click(uid)` only clicks the centerpoint of the canvas. For
pixel-precise clicks would require the experimental `click_at(x, y)` extension, which is NOT part of the default chrome-devtools MCP surface. Treat as unavailable. Your only option for off-center
clicking is to use Mac mini's keyboard-only navigation (Tab, arrow keys).

### Run shell commands

Open Terminal via Spotlight, `/macmini paste` the command, `press_key("Enter")`.
For multi-step shell work, prefer delegation (see below).

## Delegation pattern — when to use Mac mini Claude

For any task that's multi-step, needs sudo, involves complex shell pipelines,
or where the Mac mini's local context (file tree, git state, running
processes) matters more than what's visible on screen:

1. Make sure Mac mini Terminal is focused (`mcp.press_key("Meta+space")`, `mcp.type_text("terminal", "Enter")`, screenshot to confirm).
2. `mcp.type_text("claude --dangerously-skip-permissions", "Enter")` — all lowercase + dashes, types intact through CRD. The flag eliminates "Allow / Deny" permission dialogs that the Shift-strip pipeline can't reliably navigate.
3. `take_screenshot` to confirm Claude Code's TUI started (you'll see its prompt).
4. `/macmini paste "<your instruction in lowercase prose, but capitals/symbols/unicode allowed since gist transport handles them>"` — this puts your instruction on Mac mini's clipboard.
5. **Cmd+V into the Claude prompt:** `mcp.press_key("Meta+v")` to paste the instruction.
6. `mcp.press_key("Enter")` to submit.
7. `take_screenshot` to read the response; scroll if needed (`mcp.press_key("PageUp")`).
8. Iterate as needed.

Mac mini Claude has full local privileges and shares this dotfiles checkout (same skills, same CLAUDE.md, same MCP servers, same credentials catalog at `~/.config/claude/credentials.md`). You don't need to re-explain conventions — it has identical context.

## Limitations & gotchas

- **Shift mangling on direct typing** — `mcp.type_text` strips Shift. Capitals → lowercase, `$@!#%^&*()_+{}[]|\\:"<>?~` get remapped to wrong characters. **Always use `/macmini paste` for anything other than lowercase shell commands.** Verified failure mode 2026-04-27.
- **CRD's a11y tree is stripped** — `mcp.take_snapshot()` returns `ignored` for nearly every CRD control. `mcp.click({uid})` cannot reach the side-panel toggles. The user clicks "Synchronize clipboard" + "Send system keys" ONCE manually at first connect (they persist). Don't try to automate it.
- **Programmatic clipboard sync (dev → mini) is broken** — CRD's onPaste handler requires real user gestures; CDP-injected events are synthetic. `pbcopy` on dev followed by `mcp.press_key("Meta+v")` on the canvas pastes whatever was in mini's LOCAL clipboard, not what dev just copied. **This is why `/macmini paste` uses gist transport instead.**
- **`Cmd+Tab` and `Cmd+Space` need full-screen + Send System Keys** to be reliable. The user's one-time toggle covers this.
- **Sudo prompts need physical password typing** unless Touch ID is configured on the Mac mini. For sudo-needing tasks, delegate to Mac mini Claude (`claude` in mini Terminal — lowercase command works) or have the user enter the password.
- **No built-in file transfer beyond gist** — for files use `gh gist clone` (handled by `/macmini paste`). For binaries that don't fit in a gist, host on a public URL and `curl` from mini.
- **Mini → dev clipboard direction is also brittle** — if `/macmini grab` returns empty or stale, retry; or have Mac mini Claude `pbcopy` explicitly, then run `/macmini grab` again.
- **`/macmini paste` refuses credential-shaped payloads** — Step 0 pre-scans `$ARGUMENTS` against 11 named patterns (OpenAI / Anthropic / GitHub / AWS / Slack / Google API keys, private-key blocks, Authorization headers, op:// + value pairs, high-entropy `API_KEY=...` env-var assignments). On match, refuses with `BLOCKED: payload contains apparent <pattern-name>` and offers side-channel options. The pre-scan catches casual leaks (raw env-var paste); it does NOT defeat multi-line splits, base64-wrapped secrets, or unicode confusables. Don't try to work around it — paste a script that fetches the secret from 1Password / Keychain on the mini side instead of pasting the value.
- **Clipboard re-paste is replay-only, not gist re-clone** — after `/macmini paste`, the gist is deleted in Step 7. The Mac mini's pasteboard still holds the bytes for as long as another app doesn't `Cmd+C` over it (and as long as the mini doesn't reboot). To land the same payload in a different focused app, just `mcp.press_key("Meta+v")` again. To re-clone the gist on a second mini-side process, you can't — fire a fresh `/macmini paste`.

## Recovery patterns

- **Stray Cmd+modifier opened the wrong app** → `mcp.press_key("Meta+q")` to close, Spotlight again to refocus.
- **Lost focus on canvas** → `mcp.take_snapshot()` to find the "Desktop" textbox uid, then `mcp.click({uid: <desktop_uid>})` to re-grab focus.
- **Mac mini Claude session died** → re-type `claude --dangerously-skip-permissions` via `mcp.type_text`, Enter.
- **Sign-in expired** → `/macmini connect` will detect and tell you to sign in.
- **Clipboard sync side-panel toggle reset** → the user manually re-clicks "Synchronize clipboard" and "Send system keys" in CRD's right-edge side panel. Persists.
- **Chrome clipboard permission was revoked** → user visits `chrome://settings/content/clipboard`, finds `https://remotedesktop.google.com`, sets to Allow.
- **Rogue keystrokes opened System Settings or another app mid-task** — `mcp.press_key("Meta+q")` to close, Spotlight back to the intended app, screenshot to confirm focus state before resuming.

## Security model

- **chrome-devtools MCP exposes localhost:9222.** Anything that can connect to localhost (other apps, malicious processes) gets full DevTools control over your Chrome session. Mitigation: trusted dev machine only; consider `--user-data-dir=/tmp/chrome-cdp` to isolate from your main browsing if running anything you don't trust on the same host.
- **gh gist transport ships text through GitHub.** Secret gists are unlisted but NOT encrypted. GitHub staff can read them; URL leak grants access to anyone. The `/macmini paste` command auto-deletes after successful clone+execute, but never paste tokens, `op://`-resolved values, env-var dumps, or auth headers (see `commands/macmini/paste.md` "What NOT to do").
- **Full Chrome scope.** The skill attaches to your main Chrome profile (every tab, login, cookie). Discipline rules in "Your full Chrome is also reachable" above apply — don't click Buy/Send/Pay/Confirm/OAuth/2FA without explicit user instruction. The list is hard prohibitions, not "ask first" — even if the user says "log in to X," surface the OAuth/2FA screen for them rather than approving on their behalf.
- **TCC grants for CRD's host process** are SIP-protected and managed by macOS. We never attempt to bypass; the user grants Screen Recording / Accessibility / Input Monitoring once via System Settings.
