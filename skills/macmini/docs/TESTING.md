# macmini smoke tests

Run these end-to-end on a fresh setup, and after any change to `paste.md` / `connect.md` / `grab.md` / `setup.md`. Each test has a precondition, an action, an explicit verification step, and a recovery hint on failure.

## Test 1 — `gh` authenticated on both sides

**Precondition:** Mac mini reachable via CRD; canvas live (`/macmini connect` returned OK).

**Action:**

1. Dev side: `gh auth status` (run via the dev shell).
2. Mac mini side: bring Terminal forward, then `mcp.type_text("gh auth status", "Enter")` and `mcp.take_screenshot()`.
3. Compare the GitHub login string from each side.

**Verify:** Both sides report the same `Logged in to github.com account <user>` line.

**Recovery on fail:**
- Dev not authed: `gh auth login` on dev.
- Mini not authed: have user open Mac mini Terminal manually and run `brew install gh && gh auth login`. Device flow needs a browser; the agent can't do this.
- Different accounts: pick one (likely dev's), reauth the other side.

## Test 2 — `/macmini paste` round-trip (gist transport)

**Precondition:** Test 1 passed; CRD canvas live; Mac mini Terminal focused.

**Action:**

```
/macmini paste "HELLO_WORLD with $special chars: |&>~ and 日本語 émoji"
```

After paste reports `pasted N chars via gist <id> (deleted)`:

```
mcp.type_text("pbpaste", "Enter")
mcp.take_screenshot()
```

**Verify:** The screenshot's Terminal output equals the original input byte-for-byte: `HELLO_WORLD with $special chars: |&>~ and 日本語 émoji`. Capitals, `$`, `|`, `&`, `>`, `~`, unicode all intact.

**Recovery on fail:**
- Output is empty: paste's `bash run.sh` didn't run because mini Terminal lost focus. Re-focus mini Terminal, retry.
- Output is mangled or truncated: heredoc terminator collision (1-in-2^64; should never hit). Retry.
- Output is from a previous paste: clone command went to wrong app. Bring Terminal forward, retry.
- `gh: command not found` or `gist clone 404`: see Test 1 recovery.

## Test 3 — Vision feedback loop

**Precondition:** CRD canvas live.

**Action:** `mcp.take_screenshot()`. Review the screenshot to confirm the Mac mini desktop is visible (wallpaper, dock, Terminal window if open).

**Verify:** Image is non-black, shows recognizable macOS chrome.

**Recovery on fail:**
- Black image: mini display asleep. `mcp.press_key("Shift")` to wake without typing anything destructive, retry.
- Wrong page: `mcp.list_pages()`, find the CRD page, `mcp.select_page({pageId, bringToFront: true})`, retry.

## Test 4 — Lowercase keystroke forwarding

**Precondition:** CRD canvas live; Mac mini Terminal focused.

**Action:** `mcp.type_text("clear; pwd", "Enter")` then screenshot.

**Verify:** Screenshot shows the Terminal cleared, then a single line with the Mac mini's home directory path.

**Recovery on fail:** keystrokes not landing on mini → "Send system keys" toggle off in CRD side panel. User manually re-toggles it on. Retry.

## Test 5 — Cmd-modifier shortcut forwarding

**Precondition:** CRD canvas live; Mac mini Terminal focused; some short text in mini's clipboard (run Test 2 first).

**Action:** `mcp.press_key("Meta+v")` then `mcp.press_key("Enter")` then screenshot.

**Verify:** The text from Test 2 was pasted as a command (likely "command not found" since it's not a shell command, but the text itself appears verbatim in Terminal).

**Recovery on fail:** "Send system keys" toggle off → user toggles on, retry.

## Test 6 — Sign-in detection

**Precondition:** none — dev Chrome may or may not be signed into Google.

**Action:** `/macmini connect` from a state where the user has signed out of Google in the dev Chrome.

**Verify:** Returns `NEEDS_REAUTH` and prints the sign-in prompt without screenshotting (the sign-in page may show the user's email).

**Recovery on fail:** if the command screenshots the sign-in page, the agent has a PII regression. File a bug.

## Test 7 — Spotlight focus discipline

**Precondition:** CRD canvas live.

**Action:** `mcp.press_key("Meta+space")` then `mcp.type_text("terminal", "Enter")` then `mcp.take_screenshot()`.

**Verify:** Mac mini's Terminal is now the foreground app (not dev's Terminal).

**Recovery on fail:** Cmd+Space went to dev Chrome instead of mini → "Send system keys" off OR CRD canvas wasn't focused. Run Test 4 first to confirm keystroke forwarding, then retry.

## Latency table (fill in during testing)

| Measurement | Expected | Actual |
|---|---|---|
| `/macmini paste` (small payload) | <8s end-to-end (gist create + clone + bash) | __s |
| `/macmini paste` (50KB payload) | <12s | __s |
| keyboard forward latency (single keystroke visible on mini) | <500ms | __ms |
| first `take_screenshot` after `/macmini connect` | <2s | __s |

## After testing

Document any new failure mode in `commands/macmini/connect.md`, `commands/macmini/paste.md`, or `commands/macmini/grab.md` "Errors" sections. Update the channel matrix in `SKILL.md` if a previously-allowed character class turns out to mangle, or a previously-broken channel becomes reliable.
