# macmini — Testing recipes

This document drives the Phase 6 hardware test pass. The user grants the agent
access to the Mac mini via the new `/macmini connect` flow; the agent then
runs the smoke tests below in order, records actual latencies, and updates
SKILL.md / AGENT-GUIDE.md / README.md with empirical findings at the end.

## Rollback recipe (read first)

If testing reveals fundamental breakage and you want the previous
Tailscale-based version back:

- Dev side: `cd ~/.claude-dotfiles && git checkout main`. The `main` branch
  preserves the previous skill before the strip commits.
- Mac mini side: `bash skills/macmini/install/install.sh` to reinstall the
  Go server from the `main` checkout.
- The strip commits stay on the `macmini-strip` branch and can be re-attempted
  later.

## Test dependency graph

Run in this order — later tests assume earlier ones passed.

| Test | What it covers | Depends on |
|---|---|---|
| 0 | disconnect / reconnect roundtrip | none — runs first |
| 1 | small ASCII paste | 0 |
| 2 | CRD-killer payload (Shift modifier) | 1 |
| 3 | chunked sha256 paste | 1; also requires Test 7 to focus Terminal |
| 4 | manual grab (mini → dev) | 0 |
| 5 | driven grab (TextEdit) | 7 (Spotlight to open TextEdit) |
| 6 | scrolling primitives | 1 (paste a path), 7 (open file via Spotlight) |
| 7 | Spotlight focus | 0 |
| 8 | delegation to Mac mini Claude | 7 — if 7 fails, skip 8 with note |
| 9 | recovery: close + reconnect | 0 |
| 10 | asleep Mac mini | optional — only if testable |

## Pre-flight checklist (run BEFORE any smoke test)

**Bootstrap-order resolution (critical for Phase 6 first run):**

The new skill needs the new skill to ferry itself to Mac mini, which deadlocks
if anything's broken. Resolution: **the cleanup-mini.sh transport happens
BEFORE Phase 1 strips begin**, while the OLD `/macmini run` (Tailscale Go
server) is still functional and can SSH-equivalent the script to Mac mini.

Concretely, BEFORE Phase 1 deletions are merged:

- On dev: `cd ~/.claude-dotfiles && git checkout macmini-strip` (the new
  branch has cleanup-mini.sh).
- With OLD `/macmini run` still working: ferry the script with
  `/macmini run "cd ~/.claude-dotfiles && git fetch origin && git checkout
  macmini-strip && bash skills/macmini/cleanup-mini.sh"`.
- This uses the existing infrastructure to clean itself up. After this run
  completes, the Mac mini's server is gone and we proceed.

Alternative bootstrap (if OLD infra fully gone before this point):

- User opens Mac mini Terminal physically OR via CRD with manual typing.
- `cd ~/.claude-dotfiles && git fetch origin && git reset --hard
  origin/macmini-strip && bash skills/macmini/cleanup-mini.sh`.

**Standard pre-flight (after bootstrap above succeeded):**

- chrome-devtools MCP is reachable: `mcp.list_pages` returns a list (not an
  error).
- Mac mini is awake; CRD device tile visible at
  `https://remotedesktop.google.com/access`.
- `/macmini connect` lands in canvas successfully.
- `clipboard-read` permission granted on `https://remotedesktop.google.com`
  (verify via `navigator.permissions.query({name:'clipboard-read'})`).
- CRD is in fullscreen + Send System Keys enabled (verify behaviorally: a
  Cmd+Space test forwards to Mac mini Spotlight, not dev-side Spotlight).
- Mac mini cleanup verified: `/macmini paste "ps aux | grep -v grep | grep
  macmini-server"`, press Enter, take_screenshot, expected output: empty.
  Also `/macmini paste "ls -la ~/.local/bin/macmini-server 2>&1"`, expected
  `No such file or directory`.

## Smoke Test 0 — disconnect / reconnect

- **Setup:** an active CRD canvas from a fresh `/macmini connect`.
- **Action:** `/macmini disconnect` → `/macmini status` → `/macmini connect`.
- **Verify:** disconnect closes the CRD tab; status reports "not connected";
  connect re-opens and lands back in canvas.
- **Recovery on fail:** investigate which step misbehaved. If `disconnect`
  didn't close, manually close the tab and rerun status. If `connect` failed,
  check the CRD device tile is still visible at
  `https://remotedesktop.google.com/access`.

## Smoke Test 1 — small ASCII paste

- **Setup:** Test 0 passed; canvas focused.
- **Action:** focus a Mac mini Terminal (Test 7 path or click), then
  `/macmini paste "hello world"`. Press Enter.
- **Verify:** take_screenshot. The Terminal shows `hello world` typed at the
  prompt verbatim.
- **Recovery on fail:** check the dev-side `pbcopy` worked (run `pbpaste` on
  dev, should match). If pbcopy is fine but the canvas didn't receive,
  reload the CRD tab and re-enable clipboard sync.

## Smoke Test 2 — CRD-killer payload (Shift modifier)

- **Setup:** Test 1 passed.
- **Action:** `/macmini paste "HELLO_WORLD with \$special chars: |&>~ \"quoted\"
  'apostrophes' newlines\nyes"` → press Enter.
- **Verify:** the Terminal shows the payload verbatim. No `_` → `-`
  corruption, capitals preserved, special chars intact.
- **Recovery on fail:** if Shift mangling is observed, that means paste isn't
  using clipboard — verify the paste.md recipe actually does Cmd+V via
  press_key("Meta+v"), not per-character typing.

## Smoke Test 3 — chunked sha256 paste

- **Setup:** Tests 1 and 7 passed; Mac mini Terminal focused.
- **Action:**
  - On dev: `openssl rand -base64 50000 | tr -d '\n' > /tmp/payload.txt &&
    shasum -a 256 /tmp/payload.txt`. Note the hash.
  - On Mac mini Terminal (via `/macmini paste`): `cat > /tmp/received.txt`
    then Enter.
  - On dev: `/macmini paste "$(cat /tmp/payload.txt)"`.
  - On Mac mini Terminal: Ctrl+D to close `cat`, then
    `shasum -a 256 /tmp/received.txt`.
- **Verify:** the hashes match exactly. If they don't, the chunking logic
  corrupted the payload.
- **Recovery on fail:** examine paste.md chunking code — most likely a
  byte-vs-character split issue at a UTF-8 boundary (the plan flagged this:
  use the JS `[...str]` spread iterator, not bash byte slicing).

## Smoke Test 4 — manual grab (mini → dev)

- **Setup:** Test 0 passed.
- **Action:**
  - On Mac mini Terminal (paste the command):
    `echo "ROUND_TRIP_TEST_$(date +%s)" | pbcopy`. Press Enter.
  - On dev: `/macmini grab`.
- **Verify:** the returned string matches what was piped to `pbcopy` on Mac
  mini, including the timestamp.
- **Recovery on fail:** mini→dev sync is historically brittle. Reload the CRD
  tab; re-enable clipboard sync via the side menu; retry.

## Smoke Test 5 — driven grab (TextEdit, NOT Terminal)

- **Setup:** Test 7 passed.
- **Action:**
  - Spotlight to open TextEdit (`Meta+Space`, paste `textedit`, Enter).
  - In TextEdit, paste a known string (`/macmini paste "drivengrab_test_42"`)
    and press Enter or just leave it as the only content.
  - On dev: `/macmini grab driven`.
- **Verify:** the returned string contains `drivengrab_test_42`.
- **Document:** "Driven grab does NOT work for Terminal scrollback — Cmd+A
  only selects visible region or nothing in Terminal. For Terminal output,
  use manual mode." This caveat is already in SKILL.md and grab.md but
  reconfirm empirically.

## Smoke Test 6 — scrolling primitives

- **Setup:** Test 1 (paste a path) and Test 7 (focus Terminal) passed.
- **Action:**
  - In Mac mini Terminal: `/macmini paste "man bash"` → Enter.
  - take_screenshot — note the visible content (top of `man bash` page).
  - `press_key("PageDown")` × 3.
  - take_screenshot — verify content shifted down.
  - `press_key("End")` (or `Meta+ArrowDown` fallback) — should jump to
    bottom of buffer.
  - `press_key("Home")` (or `Meta+ArrowUp` fallback) — should jump to top.
- **Verify:** each scroll primitive moved the viewport in the expected
  direction. Document any that didn't work in SKILL.md table.
- **Recovery on fail:** record which keys failed; the table in SKILL.md may
  need adjustment based on app-specific behavior.

## Smoke Test 7 — Spotlight focus

- **Setup:** Test 0 passed; canvas focused.
- **Action:**
  - From a clean canvas state, `press_key("Meta+Space")`.
  - `/macmini paste "terminal"`.
  - `press_key("Enter")`.
  - take_screenshot.
- **Verify:** Terminal.app is now focused on Mac mini side (not dev side).
  Repeat with `chrome` to test multi-app focus (the second invocation must
  also forward to Mac mini, not dev).
- **Recovery on fail:** Cmd+Space probably opened dev-side Spotlight. Verify
  CRD is in fullscreen mode AND Send System Keys is enabled (right-edge
  arrow → Full-screen + "Send System Keys"). Re-test.

## Smoke Test 8 — delegation to Mac mini Claude

- **Setup:** Test 7 passed; Terminal focused on Mac mini.
- **Action:**
  - `/macmini paste "claude"` → `press_key("Enter")`.
  - Wait ~5s.
  - take_screenshot — verify the Mac mini Claude session started (banner
    visible, prompt indicator changed).
  - `/macmini paste "list files in home directory in lowercase"`.
  - `press_key("Enter")`.
  - take_screenshot — verify a response. Apply terminal-output discipline
    (scroll up if response exceeds viewport, read top-to-bottom).
- **Verify:** Mac mini Claude responded with file listing.
- **Recovery on fail:** if `claude` not on PATH on Mac mini, delegate fails
  cleanly with "command not found" — install Claude Code on Mac mini per
  setup.md migration appendix and retry. If Test 7 failed, skip this test
  with a note.

## Smoke Test 9 — recovery (close + reconnect)

- **Setup:** Test 0 passed.
- **Action:** close the CRD tab manually (`mcp.close_page` or click the
  tab's X). Then `/macmini connect`.
- **Verify:** connect re-opens and lands in canvas.
- **Valid alternate passes:** if `NEEDS_REAUTH` is returned, sign in with
  the user, re-run connect — that's a valid pass too (it exercises the
  re-auth path).
- **Note:** `NEEDS_FULLSCREEN` is NOT returned by connect.md in this initial
  implementation — fullscreen check is non-blocking; only soft-hint logged.
  Phase 6 will determine if fullscreen detection is reliable enough to
  upgrade to a blocking check.

## Smoke Test 10 — asleep Mac mini (optional)

- **Setup:** Mac mini display has gone to sleep (waited several minutes, or
  forced via `pmset displaysleepnow` if accessible).
- **Action:** take_screenshot. If output is black, `press_key("Shift")` to
  wake without typing anything destructive, retry screenshot.
- **Verify:** wake-via-Shift produces a usable canvas. Document the outcome
  (pass / fail / skipped with reason).
- **Recovery on fail:** if Shift doesn't wake the display, document the
  alternative (move mouse via canvas click, send wake-on-LAN, ask user to
  physically wake).

## Latency table

Fill in the **Actual** column during testing.

| Measurement | Expected | Actual |
|---|---|---|
| dev→mini paste sync (small) | <1s | __ms |
| dev→mini paste sync (50KB chunked) | <5s total | __ms |
| mini→dev grab sync (manual) | <2s | __ms |
| canvas focus → press_key forward | <500ms | __ms |
| first take_screenshot post-connect | <2s | __ms |

## After testing

Update `SKILL.md`, `AGENT-GUIDE.md`, and `README.md` with empirical findings:

- Latencies measured (replace placeholders with real numbers; flag any >2×
  expected).
- Edge cases discovered (e.g., scroll keys that didn't behave as expected;
  apps where driven grab worked / failed).
- Recipes that needed adjustment (e.g., sleep durations in paste.md /
  grab.md tuned to measured sync times; chunk size adjusted from 50KB if
  needed).
- The actual CRD-fullscreen detector that works (replacing the soft-hint
  Fullscreen API check in connect.md with a blocking detector).
- README.md gains a "Hardware-tested on YYYY-MM-DD" stamp with the latency
  numbers and any caveats discovered.
