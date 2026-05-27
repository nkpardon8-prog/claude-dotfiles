# /devtools — changelog

## 2026-05-27 — fix the silent hang: wake discarded/frozen tabs before connecting (Step 1.5)

**Problem:** `chrome-devtools` tool calls hung **forever** (observed: a `list_pages` spinner running 3h+) even though everything looked healthy — Chrome up on 9222, `/json/version` responding, all 28 real tabs present in `/json/list`, `initialize` succeeding (tools listed fine). Only the first *tool call* hung.

**Root cause (new, 4th failure mode):** Chrome freezes/discards background tabs to save memory; a frozen tab's CDP target stops answering. On connect, chrome-devtools-mcp's `detectOpenDevToolsWindows()` (`build/src/McpContext.js`) probes **every** page target in one `Promise.all` with no timeout (`page.hasDevTools()` / `page.openDevTools()`). A single unresponsive tab hangs the entire enumeration → the tool call never returns.

**How it was proven:**
- Clean throwaway browser (3 targets): `list_pages` responded in 4s ✅. User's real browser (68–72 targets, 30 heavy tabs): hung indefinitely ❌. Same server/install/Node — only the browser state differed.
- Debug log (`--logFile`, `DEBUG=*`) signature: `Connected Puppeteer` prints, then silence → stuck in page enumeration, not the socket connect.
- Per-tab CDP `Runtime.evaluate` probe found 5/28 tabs unresponsive (discarded background tabs: a Google sign-in, GitHub, Gmail, claude.ai, a netlify login).
- `curl /json/activate/<id>` on each woke them (5→0 unresponsive). `list_pages` then completed in 8s with **all 28 tabs intact**.

**Fix (now permanent in `commands/devtools.md`):** added **Step 1.5** — before the `/mcp` reconnect, activate every page target (`/json/activate/<id>`) to wake discarded tabs, with an optional `ws`-based responsiveness check and a fallback to close a genuinely-crashed tab. Documented as failure mode #4. Tabs are preserved (the prior instinct to "just use fewer tabs / a blank profile" was rejected — the user wants their real open tabs accessible).

**Verified:** MCP enumerated all live tabs (Loom, Supabase ×3, Gemini, GitHub ×3, ChatGPT, Neon ×2, Netlify, Google Docs, flowsurge.ai, …) in 8s after waking.

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
