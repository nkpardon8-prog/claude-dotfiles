# Agent guide — driving a Mac mini via CRD canvas + DevTools MCP

## TL;DR

You're an AI agent driving a Mac mini through a Chrome Remote Desktop (CRD) tab on the dev side, attached via chrome-devtools MCP. The CRD canvas renders the Mac mini's live desktop pixels; you control it with `press_key`, `take_screenshot`, focused canvas clicks, and the dedicated `/macmini paste` / `/macmini grab` commands for clipboard sync. `SKILL.md` is the capability map (what's on the Mac mini, scrolling primitives, delegation pattern). This file is operational tips: focus discipline, recovery from rogue keystrokes, common app-launch sequences, sign-in / permission re-grant. Read `SKILL.md` first.

---

## CRD focus discipline

Most "my keystroke didn't land where I expected" problems are focus problems. A few rules:

- **Click the canvas before any `press_key`.** Chrome may have moved focus to its own URL bar, a sidebar, an extension, or another tab between your previous DevTools call and this one. The reliable pattern:
  ```
  mcp.click('canvas', 1, 1)   # offset (1,1) into the canvas — never the center
  mcp.press_key("...")
  ```
  Use `(1, 1)` (or any non-center offset) so you don't accidentally activate something centered on the canvas. With `--experimental-vision` you can use `click_at(x, y)` for precision; without it, the MCP `click(uid)` only hits the centerpoint, which can interact with whatever's there.
- **Bring the CRD tab to front before paste.** If the dev-side user has multiple Chrome windows open, `pbcopy` then `Cmd+V` will paste into whichever Chrome window is foreground — which may not be CRD. Use `mcp.bring_to_front()` if available, or fall back to AppleScript:
  ```
  osascript -e 'tell application "Google Chrome"
    set crdWin to first window whose URL of active tab starts with "https://remotedesktop.google.com"
    set index of crdWin to 1
    activate
  end tell'
  ```
- **Spotlight (`Cmd+Space`) reliability requires fullscreen + "Send System Keys".** In windowed CRD, `Cmd+Space` typically opens dev-side Spotlight (your laptop's), not the Mac mini's. The fix is in the CRD right-edge side menu: enter Full-screen mode, then enable "Send System Keys". Both must be on. `/macmini connect` reminds you of this; `/macmini status` reports the fullscreen state.

If keystrokes are landing in the wrong place, the diagnostic order is: (1) is CRD the foreground Chrome window? (2) does the canvas have DOM focus (re-click)? (3) is fullscreen + Send System Keys on (for Cmd+Space / Cmd+Tab)?

---

## Scrolling

`SKILL.md` documents the full scroll primitive table — go there for the canonical reference. The short version: `press_key("PageDown")` and `press_key("PageUp")` are the workhorses; `press_key("End")` and `press_key("Home")` jump to bottom and top respectively (with `Meta+ArrowDown` / `Meta+ArrowUp` as fallbacks). Do NOT use the MCP `drag` tool to scroll — it's a click-drag (mousePressed → mouseMoved → mouseReleased) and Mac apps interpret it as a text selection or content drag, never as a scroll wheel.

When reading long Terminal output:

1. After each `press_key("PageDown")`, `take_screenshot` to capture that page of context.
2. Stitch screenshots top-to-bottom in your reasoning — first screenshot was the bottom of the buffer; subsequent PageUp screenshots are increasingly older content. (Or use the inverse: scroll to the top of the relevant region first, then `PageDown` your way down, capturing each page.)
3. **Return focus to the live tail before sending the next keystroke** — `press_key("End")` or repeated `press_key("PageDown")` until you're at the bottom. Otherwise the next keystroke goes into scrollback, not into the live shell, and is silently lost.

This applies to all scrollable content: long Chrome pages, log viewers, code editors, chat threads. Pattern is the same — scroll, capture, read in order, return to live tail.

---

## Recovery from rogue Cmd+modifier mishaps

Modifier-Shift confusion is real. If you're typing through CRD and a stray combination chords with what came before, you'll occasionally open something you didn't intend.

- **Stray `Cmd+,` opens System Settings (or the focused app's preferences):** `press_key("Meta+w")` closes the preferences pane. If a settings app is now in foreground, `press_key("Meta+q")` to quit it, then Spotlight back to your intended app.
- **Stray `Cmd+Shift+something` opens an Encodings panel, Help search, or other side window:** `press_key("Escape")` to dismiss, then re-focus via Spotlight.
- **General pattern when in doubt:** `press_key("Meta+q")` to close the wrong app, then `Cmd+Space` → paste the intended app name (lowercase) → Enter to refocus. If you're not sure what's even focused, `take_screenshot` first.

The user types alongside you sometimes — if you see a window you didn't open, treat it as ambient noise and recover the same way (Cmd+Q, refocus, resume).

---

## Delegation pattern — when to use Mac mini Claude

A `claude` Code session running on the Mac mini itself sidesteps every CRD limitation: no Shift mangling (it has its own real keyboard), no clipboard sync round-trips, no canvas focus discipline. Its Bash tool runs anything you'd run yourself. Delegate when:

- The task is **multi-step** (more than 2-3 paste/keystroke round-trips would be needed).
- The task **needs sudo** — Touch ID for sudo may not be configured on the Mac mini, and you absolutely cannot type a sudo password through CRD reliably (Shift mangles most passwords).
- The task involves **complex shell pipelines** that would be painful to paste-and-execute step by step (multi-line heredocs, subshell substitutions, etc.).
- The task needs **Mac mini's local context** more than visual feedback — reading a file tree, checking git status, running tests, inspecting environment variables.

Recipe:

1. Focus Terminal on the Mac mini: `Cmd+Space` (Spotlight) → `/macmini paste "terminal"` → `press_key("Enter")`.
2. `/macmini paste "claude"` → `press_key("Enter")`. Wait a few seconds for the Claude Code session to start.
3. `/macmini paste "<your instruction in lowercase prose>"` → `press_key("Enter")`. Lowercase-only because if the prose itself has to be re-typed for any reason (e.g., you needed to retry), uppercase letters won't survive CRD typing — but `/macmini paste` itself handles arbitrary content, so the lowercase rule is just a safety habit, not a hard constraint.
4. `take_screenshot` to read Mac mini Claude's response. Apply the scrolling discipline above for long responses.
5. Iterate: more paste, more screenshots. Don't break out of the Mac mini Claude session until the multi-step task is done — that's the whole point of delegation.

---

## Common app-launch sequences

All via Spotlight. Lowercase queries are CRD-safe.

| App | Sequence |
|---|---|
| Terminal | `Cmd+Space` → `/macmini paste "terminal"` → Enter |
| Chrome (Mac mini's) | `Cmd+Space` → `/macmini paste "chrome"` → Enter (or `"google chrome"` if multiple Spotlight matches) |
| Safari | `Cmd+Space` → `/macmini paste "safari"` → Enter |
| TextEdit | `Cmd+Space` → `/macmini paste "textedit"` → Enter |
| System Settings | `Cmd+Space` → `/macmini paste "system settings"` → Enter. **Do NOT use `Cmd+,`** — that opens whatever app is currently focused's preferences, which is rarely what you wanted. |
| Finder | `Cmd+Space` → `/macmini paste "finder"` → Enter (or click the Dock icon if available) |

Spotlight requires CRD fullscreen + Send System Keys (see [Focus discipline](#crd-focus-discipline)). If Spotlight fails entirely, fall back to clicking the Dock or using Cmd+Tab (also requires Send System Keys).

---

## Sign-in and permission re-grant recovery

- **`/macmini connect` returns `NEEDS_REAUTH`:** the dev-side Chrome's Google sign-in for `https://remotedesktop.google.com` has expired. Tell the user to sign back in inside the CRD tab, then re-run `/macmini connect`. You cannot sign in for them — the CRD page renders the Google sign-in form in dev Chrome's chrome, not on the Mac mini canvas.
- **`/macmini paste` reports clipboard permission denied:** Chrome's `clipboard-read` permission for `https://remotedesktop.google.com` is in `denied` state. Have the user visit `chrome://settings/content/clipboard`, find `https://remotedesktop.google.com` in the list (Add it if missing), set it to Allow. The permission persists per-origin once granted.
- **Clipboard sync seems stuck (paste arrives but is empty / stale):** the per-session "Begin" toggle in the CRD side menu may have reset. Reload the CRD tab; clipboard-read permission should still be in effect (it's persistent), but the side-menu sync needs to be re-enabled: right-edge arrow → "Enable clipboard synchronization" → Begin. Then retry `/macmini paste`.
- **`take_screenshot` returns black:** Mac mini display is asleep. `press_key("Shift")` to wake without typing anything destructive (Shift alone produces no character input but registers as a wake event), then re-screenshot. If still black, the Mac mini may be at a FileVault unlock prompt after a cold boot — escalate to the user.

---

## TCC permission recovery (Mac mini side)

macOS Privacy & Security grants for the CRD host process (Screen
Recording, Accessibility, Input Monitoring) are SIP-protected and
managed by macOS — the skill never bypasses them, only deep-links to
the right pane. They're typically a one-time grant on first install,
but a macOS major upgrade or a CRD reinstall can wipe them. Symptoms
include a black or stale `take_screenshot`, dropped keystrokes inside
the canvas, or `/macmini connect` succeeding but no real input
forwarding to the Mac mini.

Recipe:

```bash
bash ~/.claude-dotfiles/skills/macmini/scripts/open-tcc-pane.sh <screencapture|accessibility|inputmonitoring>
```

This deep-links into the correct pane in System Settings → Privacy &
Security. Toggle the CRD host (typically `Chrome Remote Desktop Host`
or `org.chromium.chromoting.me2me_host`) ON for the relevant
capability.

After re-toggling, restart the CRD host process so it picks up the new
grant:

```bash
pkill -f ChromeRemoteDesktopHost
```

The host auto-respawns via launchd. Re-run `/macmini connect` from
dev once the canvas comes back, then re-take a screenshot to confirm
input + display are working.

If you're not sure which pane is failing, run all three in sequence
(`screencapture`, then `accessibility`, then `inputmonitoring`),
toggle CRD host in each, then `pkill -f ChromeRemoteDesktopHost`
once at the end.

## Discovering CRD selectors empirically

CRD is a closed-source web app and Google ships UI changes
unannounced. When `/macmini connect` or `/macmini auto-grant ui`
reports "no aria-label match" for the Begin button, the
clipboard-sync toggle, or the Send System Keys toggle, the cached
hypotheses in `skills/macmini/data/crd-selectors.json` are stale.
Re-derive them from the live DOM with the discovery script:

1. Make sure the CRD tab is selected in chrome-devtools MCP:
   `mcp.list_pages()` → find the page where `url` starts with
   `https://remotedesktop.google.com/access/session/` → capture its
   `uid` and `mcp.select_page(uid)`.
2. Open the right-edge side menu in the canvas first if you want
   selectors for the clipboard-sync / Send System Keys toggles —
   they're not in the DOM until the menu is shown.
3. Invoke `mcp.evaluate_script` with the contents of
   `~/.claude-dotfiles/skills/macmini/scripts/discover-crd-selectors.js`
   as the `function` argument. The script does a shadow-DOM walk and
   returns a JSON string.
4. Pipe / save the JSON output directly to
   `~/.claude-dotfiles/skills/macmini/data/crd-selectors.json`. No
   markdown editing required:

```bash
cat > ~/.claude-dotfiles/skills/macmini/data/crd-selectors.json <<'JSON'
<paste the JSON output from evaluate_script here>
JSON
```

5. Re-run the failing slash command. Both `/macmini connect` (Send
   System Keys path) and `/macmini auto-grant ui` (Begin path) read
   from the JSON file at runtime, so no restart is needed.

The JSON includes a `_last_verified` ISO timestamp updated on every
discovery run — useful for spotting stale hypotheses without diffing
the whole file.

## What's NOT in this guide

- **The full capability map** — that's `SKILL.md`. What's installed on the Mac mini, the full scroll primitive table, the limitations & gotchas list, the recovery patterns. SKILL.md is always loaded with the skill so the agent has it on first reference.
- **The smoke tests** — those are in `docs/TESTING.md`. Run them before declaring the skill working on a fresh setup, and after any change to `paste.md` / `grab.md` / `connect.md`.
- **The migration recipe (Tailscale → DevTools-only)** — that's in `commands/macmini/setup.md` Migration appendix. Includes the `cleanup-mini.sh` invocation and the rollback path back to `main`.

---

## When blocked

Report cleanly to the user in lowercase prose:

1. What state did you reach? (e.g., "connected to canvas, attempting paste")
2. What failed? (e.g., "permission denied on clipboard-read")
3. What did you try? (e.g., "verified `/macmini status` shows perm = `denied`, not `prompt`")
4. What specific input do you need from them? (e.g., "open `chrome://settings/content/clipboard` and Allow `https://remotedesktop.google.com`")

Don't keep retrying through CRD if the channel is fighting you. If the canvas is unresponsive or clipboard sync is dead, the user needs to be in the loop — possibly to reload the CRD tab, sign back into Google, re-grant a permission, or physically wake the Mac mini.
