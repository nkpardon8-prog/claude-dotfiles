---
description: Kill stale chrome-devtools MCP processes and prompt the user to /mcp reconnect. Use when chrome-devtools tool calls hang, error, or stop responding.
---

# DevTools Reset

The empirically-proven fix when Claude Code's `chrome-devtools` MCP refuses to connect is to kill every existing `chrome-devtools-mcp` process on the machine and then have the user manually reconnect it via `/mcp`. This skill automates the kill + cleanup half.

This skill does **not** touch Chrome the browser. It assumes Chrome is already running with `--remote-debugging-port`. It only kills the MCP server side.

## Step 1: Kill stale processes + scrub corrupt installs

Run this bash block. Output goes straight to the user — let them see the PIDs and counts.

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

## Step 2: Print the reconnect instruction verbatim

After the bash block runs, output the following block verbatim to the user. Do not summarize, do not paraphrase, do not add a checkmark or emoji prefix:

```
chrome-devtools MCP processes cleaned.

Next step (you must do this yourself — Claude can't restart its own MCP transport mid-session):
  1. Type /mcp into the Claude Code chat input and press Enter.
  2. Find chrome-devtools in the list.
  3. Reconnect it.

Assumption: Chrome is already running with --remote-debugging-port.
If not, launch Chrome with that flag before reconnecting.
```

## Why this exists

Connecting `chrome-devtools` MCP fresh inside a Claude Code session is unreliable — it frequently hangs or errors on first tool call. The reliable workaround is a full kill of every existing `chrome-devtools-mcp` node process plus a scrub of any corrupt npx install cache. The skill is **idempotent** — safe to run when nothing is wedged. It never touches Chrome the browser, `claude-in-chrome`, or any other MCP server.
