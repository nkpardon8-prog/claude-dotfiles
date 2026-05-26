---
description: Self-healing chrome-devtools connector. Ensures a dedicated debug Chrome is running on port 9333, kills stale MCP processes, scrubs corrupt npx installs, and prompts /mcp reconnect. Use when chrome-devtools tool calls hang, error, stop responding, or when you just want devtools to connect.
---

# DevTools Connect (self-healing)

Goal: running `/devtools` on **any** agent should make the `chrome-devtools` MCP connect — every time, without thinking about it.

## The one constraint you must know

Since **Chrome 136 (March 2025)**, Chrome **refuses to enable remote debugging on the default profile** — a security fix so malware can't abuse CDP to steal cookies/passwords. Passing `--remote-debugging-port` to a default-profile Chrome gives you a dead endpoint (socket listens, but `/json/version` never responds → MCP hangs forever on first tool call). See ChromeDevTools/chrome-devtools-mcp issue #1830.

**Consequence:** we cannot attach to the user's *main* Chrome tabs. We run a **dedicated debug Chrome** with its own `--user-data-dir` (`~/.chrome-debug-profile`) on port **9333**. It's a separate window, but it persists — logins entered there stay across sessions. The `chrome-devtools` MCP is configured with `--browserUrl http://127.0.0.1:9333` to target it (see `~/.claude/chrome-devtools-mcp-entry.json` and `mcpServers.chrome-devtools` in `~/.claude.json`).

If you ever see `--autoConnect` back in that config, that's the broken setting — it auto-attaches to the default profile and hangs. It must be `--browserUrl http://127.0.0.1:9333`.

## Step 1: Ensure a healthy debug Chrome on 9333

Run this bash block. It launches the dedicated debug Chrome only if the endpoint isn't already healthy (idempotent).

```bash
DEBUG_PORT=9333
DEBUG_PROFILE="$HOME/.chrome-debug-profile"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

cdp_healthy() {
  curl -s --max-time 4 "http://127.0.0.1:$DEBUG_PORT/json/version" 2>/dev/null \
    | grep -q '"webSocketDebuggerUrl"'
}

if cdp_healthy; then
  echo "Debug Chrome already healthy on $DEBUG_PORT — $(curl -s --max-time 4 http://127.0.0.1:$DEBUG_PORT/json/version | grep -o '\"Browser\": \"[^\"]*\"')"
else
  echo "Debug endpoint on $DEBUG_PORT not responding — (re)launching dedicated debug Chrome..."
  # Kill any stale Chrome bound to OUR debug profile (proc alive but endpoint dead).
  # Never touches the user's main Chrome (different / default profile).
  pkill -f -- "--user-data-dir=$DEBUG_PROFILE" 2>/dev/null || true
  sleep 1
  mkdir -p "$DEBUG_PROFILE"
  if [ ! -x "$CHROME" ]; then
    echo "ERROR: Chrome not found at: $CHROME"
    echo "Edit CHROME= in this skill to your Chrome path and re-run."
  else
    nohup "$CHROME" \
      --remote-debugging-port=$DEBUG_PORT \
      --user-data-dir="$DEBUG_PROFILE" \
      --no-first-run --no-default-browser-check --hide-crash-restore-bubble \
      about:blank >/dev/null 2>&1 &
    disown
    for i in $(seq 1 10); do
      sleep 1
      cdp_healthy && break
    done
    if cdp_healthy; then
      echo "Debug Chrome up on $DEBUG_PORT — $(curl -s --max-time 4 http://127.0.0.1:$DEBUG_PORT/json/version | grep -o '\"Browser\": \"[^\"]*\"')"
    else
      echo "WARNING: debug Chrome did not come up healthy on $DEBUG_PORT after ~10s."
      echo "Check: is something else squatting port $DEBUG_PORT? ( lsof -nP -iTCP:$DEBUG_PORT )"
    fi
  fi
fi
```

## Step 2: Kill stale MCP processes + scrub corrupt installs

The MCP server must respawn fresh so it reads the current config and connects to the now-healthy 9333 endpoint.

```bash
# Phase 1 — inspect
BEFORE=$(pgrep -f 'chrome-devtools-mcp' 2>/dev/null | wc -l | tr -d ' ')
echo "Found $BEFORE chrome-devtools-mcp process(es)"
if [ "$BEFORE" -gt 0 ]; then
  pgrep -fl 'chrome-devtools-mcp' 2>/dev/null || true
fi

# Phase 2 — graceful then forceful kill
pkill -TERM -f 'chrome-devtools-mcp' 2>/dev/null || true
sleep 1
pkill -KILL -f 'chrome-devtools-mcp' 2>/dev/null || true

# Phase 3 — verify
sleep 1
SURVIVORS=$(pgrep -f 'chrome-devtools-mcp' 2>/dev/null | wc -l | tr -d ' ')
if [ "$SURVIVORS" -gt 0 ]; then
  echo "WARNING — $SURVIVORS chrome-devtools-mcp process(es) survived SIGKILL:"
  pgrep -fl 'chrome-devtools-mcp' 2>/dev/null || true
else
  echo "Clean — no chrome-devtools-mcp processes remain."
fi

# Phase 4 — best-effort npx install scrub (silent on miss).
# Removes the ENTIRE hash dir that contains chrome-devtools-mcp, not just the
# inner package dir, because deleting only the package leaves the
# node_modules/.bin/chrome-devtools-mcp symlink dangling. macOS then reports
# "Permission denied" when npx tries to invoke the broken symlink. Nuking the
# whole hash dir forces npx to rebuild the bin links cleanly.
SCRUBBED=0
for d in ~/.npm/_npx/*/; do
  if [ -e "$d/node_modules/chrome-devtools-mcp" ] || [ -L "$d/node_modules/.bin/chrome-devtools-mcp" ]; then
    rm -rf "$d" 2>/dev/null || true
    SCRUBBED=$((SCRUBBED + 1))
  fi
done
echo "npx install cache scrubbed ($SCRUBBED hash dir(s) removed)."
```

## Step 3: Print the reconnect instruction verbatim

After the bash blocks run, output the following block verbatim to the user. Do not summarize, do not paraphrase, do not add a checkmark or emoji prefix:

```
Debug Chrome is up on port 9333 and chrome-devtools MCP is cleaned.

Next step (you must do this yourself — Claude can't restart its own MCP transport mid-session):
  1. Type /mcp into the Claude Code chat input and press Enter.
  2. Find chrome-devtools in the list.
  3. Reconnect it.

It will connect to the dedicated debug Chrome (a separate window), NOT your main tabs —
Chrome 136+ blocks remote debugging on the default profile for security.
Log into your sites once in that window; the profile persists across sessions.
```

## Step 4: Sub-agent delegation for DevTools work

DevTools tool results (`take_snapshot`, `list_console_messages`, `list_network_requests`, `evaluate_script` returns, screenshots) are large and bloat the parent context fast.

**Default rule:** delegate `mcp__chrome-devtools__*` calls to a sub-agent via the `Agent` tool (`subagent_type: "general-purpose"` unless a more specific one fits). The sub-agent does the DevTools work and returns a concise summary; raw payloads stay in its context, not the main thread. When briefing it, give: the goal, the URL/tab, what to look for, what to report back (e.g. "under 200 words, just the findings").

Relax this only if the user explicitly says they want to watch the calls happen in the main thread.

## Why this exists

`chrome-devtools` MCP connecting fresh inside a session is unreliable for two compounding reasons: (1) Chrome 136+ blocks remote debugging on the default profile, so `--autoConnect` hangs forever; (2) stale MCP node processes and corrupt npx install caches wedge the server. This skill fixes both — it guarantees a dedicated debug-profile Chrome on a known port, then forces a clean MCP respawn. Idempotent and safe to run when nothing is wedged. It never touches the user's main Chrome, `claude-in-chrome`, or any other MCP server.
