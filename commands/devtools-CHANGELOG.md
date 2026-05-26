# /devtools — changelog

## 2026-05-25 — connect to the user's real profile + tabs (port 9222)

**Problem:** `chrome-devtools` MCP hung on first tool call and never reached the user's real tabs.

**Root causes found (3):**
1. MCP launched with `--autoConnect`, which targets the **default** Chrome profile. Chrome 136+ (Mar 2025) blocks remote debugging on the default profile for security → socket listens but `/json/version` never responds → infinite hang. (Ref: chrome-devtools-mcp #1830.)
2. Launching from a copied profile hit the **"Who's using Chrome?" profile picker** → 0 windows/0 tabs, only a `browser_ui` target.
3. Stale `chrome-devtools-mcp` node procs + corrupt npx install cache wedged the server.

**Fix (now permanent in `commands/devtools.md`):**
- One-time SETUP migrates the real profile (`~/Library/Application Support/Google/Chrome`) into a non-default dir `~/.chrome-debug-profile` (rsync minus caches, ~5GB). Keeps logins, bookmarks, extensions, and the `Sessions/` data for tab restore. Sets `session.restore_on_startup=1` and disables the profile picker.
- MCP config (`~/.claude.json` `mcpServers.chrome-devtools` + mirror `~/.claude/chrome-devtools-mcp-entry.json`) changed from `--autoConnect` → `--browserUrl http://127.0.0.1:9222`.
- `/devtools` is self-healing: launches the debug Chrome on 9222 with `--user-data-dir=~/.chrome-debug-profile --profile-directory=Default --restore-last-session` if the endpoint is unhealthy, then kills stale MCP procs + scrubs npx cache. User does the `/mcp` reconnect (harness can't restart its own MCP transport mid-session).

**Verified:** 18 real tabs (Supabase, Claude, ChatGPT, GitHub, Gemini, user sites) restored and reachable on 9222.

**Going forward:** open this Chrome via `/devtools` or the `chrome-debug` alias — NOT the dock icon (the dock icon opens the default profile, which can't be debugged).

### History
- Earlier same day: introduced a self-healing dedicated *blank* debug profile on port 9333. Superseded by the 9222 real-profile migration above.
- Original: skill only killed stale MCP procs and assumed Chrome was already running with a debug port.
