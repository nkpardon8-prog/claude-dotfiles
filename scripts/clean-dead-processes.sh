#!/bin/bash
# Dead process cleanup — kills orphaned MCP servers, stale dev servers, and debug Chrome instances.
# Run manually or via cron every 2 days.

LOGFILE="$HOME/.claude/logs/process-cleanup.log"
mkdir -p "$(dirname "$LOGFILE")"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting dead process cleanup..." >> "$LOGFILE"

killed=0

kill_group() {
  local label="$1"
  local pattern="$2"
  local pids
  pids=$(ps aux | grep -E "$pattern" | grep -v grep | awk '{print $2}')
  if [ -n "$pids" ]; then
    echo "$pids" | xargs kill -9 2>/dev/null
    count=$(echo "$pids" | wc -l | tr -d ' ')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Killed $count × $label" >> "$LOGFILE"
    killed=$((killed + count))
  fi
}

# Browser MCP servers
kill_group "chrome-devtools-mcp"  "chrome-devtools-mcp"
kill_group "playwright-mcp"       "playwright-mcp"
kill_group "npm exec chrome-devtools-mcp" "npm exec chrome-devtools-mcp"
kill_group "npm exec @playwright/mcp"     "npm exec @playwright/mcp"

# Debug Chrome instances (spawned by chrome-devtools MCP)
kill_group "Chrome (chrome-debug)" "chrome-debug"

# Orphaned MCP servers from dead Claude sessions
# Only kills instances with no living parent claude process
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $2}')
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$ppid" ] && ! ps -p "$ppid" > /dev/null 2>&1; then
    kill -9 "$pid" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Killed orphaned MCP pid=$pid (dead parent $ppid)" >> "$LOGFILE"
    killed=$((killed + 1))
  fi
done < <(ps aux | grep -E 'fraim-framework.*mcp|cyanheads.*git-mcp|fraim mcp|git-mcp-server' | grep -v grep)

# Stale next/vite/tsx dev servers older than 2 days (running time > 2880 minutes)
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $2}')
  elapsed=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
  # etime format: [[dd-]hh:]mm:ss — flag anything with a day component
  if echo "$elapsed" | grep -qE '^[0-9]+-'; then
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    kill -9 "$pid" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Killed stale dev server pid=$pid elapsed=$elapsed cmd=$(echo "$cmd" | cut -c1-80)" >> "$LOGFILE"
    killed=$((killed + 1))
  fi
done < <(ps aux | grep -E 'next-server|vite|tsx watch' | grep -v grep)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done. Total killed: $killed" >> "$LOGFILE"
echo "Dead process cleanup complete. $killed processes killed. Log: $LOGFILE"
