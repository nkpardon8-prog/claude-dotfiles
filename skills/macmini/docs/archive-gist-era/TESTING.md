> **SUPERSEDED by direct-CDP 2026-06-01.** This document describes the OLD
> gist/cliclick-era `/macmini`, which no longer exists. Preserved for history
> and diagnosis only. Still-true macOS-substrate facts were harvested into
> `../FINDINGS-2026-06-01.md`. Do NOT treat anything here as the current model.

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

## Test 8 — Credential pre-scan blocks correctly (REGRESSION CHECK)

**Precondition:** none — runs on the dev side only, no canvas needed.

**Note on test fixtures.** The dotfiles repo has a five-layer secret-scan defense (see `scripts/secret-scan.sh`); writing literal credential-shaped strings into this file would be blocked at commit. So this test describes payloads by **pattern reference** rather than literal example. To run the test, construct a payload matching each pattern at runtime — do not hardcode a literal example into a tracked file.

**Action:** for each pattern below, construct a payload matching it (via your own scratch buffer, not committed to git), then invoke `/macmini paste "<that payload>"`. Verify the skill aborts at Step 0 with the exact `═══ BLOCKED ═══` banner naming the pattern.

| Pattern # | Pattern name | Payload shape (refer to paste.md Step 0 table for exact regex) | Expected match |
|---|---|---|---|
| 1 | `anthropic-key` | Anthropic-prefix + 16+ chars from `[A-Za-z0-9_-]` | `anthropic-key` |
| 2 | `openai-key` | OpenAI/OpenRouter-prefix (NOT anthropic) + 16+ chars from `[A-Za-z0-9_-]` | `openai-key` |
| 3 | `github-token` | `gh[pousr]_` prefix + 20+ chars from `[A-Za-z0-9_]` | `github-token` |
| 4 | `aws-access-key` | AWS access-key prefix (`AKIA` or `ASIA`) + exactly 16 uppercase-alphanumeric chars | `aws-access-key` |
| 6 | `slack-token` | `xox[baprs]-` prefix + 10+ chars from `[A-Za-z0-9-]` | `slack-token` |
| 7 | `google-api-key` | Google API key prefix + exactly 35 chars from `[0-9A-Za-z_-]` | `google-api-key` |
| 8 | `private-key-block` | Literal PEM/SSH/PKCS8 BEGIN-PRIVATE-KEY armor line | `private-key-block` |
| 9 | `auth-header` | `Authorization:` or `X-API-Key:` header with a 12+ char value | `auth-header` |
| 10 | `1password-resolved` | An `op://` ref string in the same payload as a 20+ char alphanumeric run | `1password-resolved` |
| 11 | `high-entropy-env-credential` | `API_KEY=` (or PASSWORD/PASSPHRASE/PRIVATE_KEY/SECRET_KEY/ACCESS_KEY) followed by 20+ non-placeholder chars | `high-entropy-env-credential` |

**Verify:** the skill aborts at Step 0 with the exact `═══ ... BLOCKED: ... ═══` banner. The matched pattern name and number are named in the error. The error points at `--secure <ENV_VAR_NAME>` mode. The skill must NOT proceed to Step 1 or upload anything to GitHub.

**Negative cases** that should NOT trigger the block (verify these proceed past Step 0):

| Payload (safe to write — these are designed to evade the patterns) | Reason |
|---|---|
| `API_KEY=YOUR_KEY_HERE` | placeholder (allowed by the negative-lookahead) |
| `the SECRET = see vault entry foo-bar-baz-quux` | prose, no `=` cred pattern with high-entropy value |
| `PASSWORD=<fill in>` | placeholder (allowed) |
| `API_KEY=test_local_dev_value` | placeholder prefix `test_` (allowed) |
| `Hello, World!` | benign text (allowed) |

**Recovery on fail:** if a positive case slips through, the regex needs tightening. If a negative case is incorrectly blocked, the placeholder allow-list (Step 0 pattern #11) needs widening. Edit `paste.md` Step 0 patterns table; do NOT relax the broader threat-model gate.

## Test 9 — `--secure` mode end-to-end

**Precondition:** Tests 1, 3, 7 passed (gh auth on both sides; gist transport works; Spotlight focus works).

**Action:**

1. `/macmini paste --secure SMOKE_TEST_KEY` from the dev side.
2. The skill should:
   - Skip the credential pre-scan (no value in `$ARGUMENTS`, just the env-var name).
   - Build a `secure.sh` containing only the `read -s` prompt + atomic write to `~/.config/claude/secrets/SMOKE_TEST_KEY`.
   - Upload as a SECRET gist; verify gist filename is exactly `secure.sh`.
   - Type the lowercase clone+execute command on the mini side.
3. Wait for the mini Terminal to show `Paste SMOKE_TEST_KEY now (cursor will appear blank), then press Enter:`.
4. **User pastes** a fake test value (any plausible 32-char hex string — NOT a real credential).
5. Skill verifies via `mcp.take_screenshot()` that `OK: wrote /Users/<user>/.config/claude/secrets/SMOKE_TEST_KEY` is visible.
6. Skill types `mcp.type_text("stat -f %Lp ~/.config/claude/secrets/SMOKE_TEST_KEY && wc -c < ~/.config/claude/secrets/SMOKE_TEST_KEY", "Enter")`.

**Verify:**

- Screenshot shows `600` on one line (mode 0600 — owner read/write only) and the byte count of the test value on the next line.
- The test value is **NOT** visible anywhere on screen (suppressed by `read -s`).
- The agent's typed command echoes the env var NAME but never the value.
- The gist URL appears nowhere in the agent's output (or appears only in the deletion confirmation, AFTER Step 7 deleted it).

**Re-run** `/macmini paste --secure SMOKE_TEST_KEY` with a different fake value. Verify atomic rotation: the file is overwritten with the new value, mode 0600 preserved, no temp-file artifacts left in `~/.config/claude/secrets/`.

**Cleanup:** on the mini Terminal, `rm ~/.config/claude/secrets/SMOKE_TEST_KEY`. (Don't leave fake credentials lying around even in tests.)

**Recovery on fail:**
- If `$ARGUMENTS` parsing failed (`ENV_NAME` empty): regression in the `set -- $ARGUMENTS` block. Re-check paste.md Step 0a.
- If gist filename is wrong (anything other than `secure.sh`): the `RUN_FILE` basename was changed, breaking the typed clone command. Restore `secure.sh`.
- If file mode is not 0600: `umask 077` was missing or the atomic-mv pattern broke. Re-check the `SECURE_BOOTSTRAP` heredoc.
- If value is visible on screen: `read -rs` flag dropped or PROMPT was emitted with `>&1` instead of `>&2`. Re-check the bootstrap script.

## Latency table (fill in during testing)

| Measurement | Expected | Actual |
|---|---|---|
| `/macmini paste` (small payload) | <8s end-to-end (gist create + clone + bash) | __s |
| `/macmini paste` (50KB payload) | <12s | __s |
| keyboard forward latency (single keystroke visible on mini) | <500ms | __ms |
| first `take_screenshot` after `/macmini connect` | <2s | __s |

## After testing

Document any new failure mode in `commands/macmini/connect.md`, `commands/macmini/paste.md`, or `commands/macmini/grab.md` "Errors" sections. Update the channel matrix in `SKILL.md` if a previously-allowed character class turns out to mangle, or a previously-broken channel becomes reliable.
