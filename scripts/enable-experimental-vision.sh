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

# Atomic write
TMP="${CONFIG}.tmp.$$"
trap 'rm -f "$TMP"' EXIT INT TERM
jq '.mcpServers."chrome-devtools".args += ["--experimental-vision"]' "$CONFIG" > "$TMP"
mv "$TMP" "$CONFIG"
echo "OK: --experimental-vision added to $CONFIG. Restart Claude Code to take effect."
