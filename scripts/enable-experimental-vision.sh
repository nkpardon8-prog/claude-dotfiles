#!/bin/bash
set -euo pipefail

CONFIG="${HOME}/.claude.json"

# Pre-conditions
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed. brew install jq" >&2; exit 1
fi
if [ ! -f "$CONFIG" ]; then
  echo "ERROR: $CONFIG missing. Open Claude Code once to create it." >&2; exit 1
fi
if ! jq -e '.mcpServers."chrome-devtools"' "$CONFIG" >/dev/null 2>&1; then
  echo "ERROR: mcpServers.chrome-devtools not configured in $CONFIG." >&2; exit 1
fi

# Idempotent: only add if not already present
if jq -e '.mcpServers."chrome-devtools".args | index("--experimental-vision")' "$CONFIG" >/dev/null 2>&1; then
  echo "SKIP: --experimental-vision already present."
  exit 0
fi

# Atomic write with validation + rollback safety
TMP="${CONFIG}.tmp.$$"
BACKUP="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
trap 'rm -f "$TMP"' EXIT INT TERM

# 1. Run jq transformation into temp file.
if ! jq '.mcpServers."chrome-devtools".args += ["--experimental-vision"]' "$CONFIG" > "$TMP"; then
  echo "ERROR: jq failed. $CONFIG unchanged." >&2; exit 2
fi

# 2. Validate temp file is parseable JSON before clobbering the live config.
#    Belt-and-suspenders: if jq's output is somehow invalid, abort.
if ! jq empty "$TMP" >/dev/null 2>&1; then
  echo "ERROR: jq produced invalid JSON. $CONFIG unchanged. Temp file preserved at $TMP for inspection." >&2
  trap - EXIT INT TERM   # disable cleanup so user can inspect $TMP
  exit 3
fi

# 3. Take a backup of the live config before swapping.
cp "$CONFIG" "$BACKUP"

# 4. Atomic swap.
mv "$TMP" "$CONFIG"

echo "OK: --experimental-vision added to $CONFIG. Restart Claude Code to take effect."
echo "     Backup of original config saved at: $BACKUP"
