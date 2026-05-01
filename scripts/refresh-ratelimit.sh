#!/usr/bin/env bash
# ~/.claude/refresh-ratelimit.sh
# Fetches Anthropic rate-limit headers via a 1-token Haiku call and writes
# ~/.claude/ratelimit.json. Token comes from macOS keychain service
# "Claude Code-credentials" (same store Claude Code itself uses).
# Costs ~1 input token per call; called at most once per 5 minutes.

set -uo pipefail

CACHE_FILE="$HOME/.claude/ratelimit.json"
TMP_FILE="$HOME/.claude/ratelimit.json.tmp.$$"
LOCK_DIR="/tmp/claude-ratelimit.lock"

# ── Mutex via mkdir (atomic on all POSIX filesystems) ────────────────────────
acquire_lock() {
  local retries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # If lock is stale (older than 30 s), remove it
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -f "%m" "$LOCK_DIR" 2>/dev/null \
                                  || stat -c "%Y" "$LOCK_DIR" 2>/dev/null \
                                  || echo "$(date +%s)") ))
    if [ "$lock_age" -gt 30 ]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    retries=$((retries + 1))
    [ "$retries" -ge 5 ] && exit 0   # another process is handling it — bail silently
    sleep 1
  done
}

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock
trap release_lock EXIT

# ── Read OAuth token from macOS keychain ─────────────────────────────────────
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['claudeAiOauth']['accessToken'])
except Exception:
    sys.exit(1)
" 2>/dev/null) || { echo "refresh-ratelimit: keychain read failed" >&2; exit 1; }

[ -z "$TOKEN" ] && { echo "refresh-ratelimit: empty token" >&2; exit 1; }

# ── POST 1-token request; capture response headers ───────────────────────────
HEADERS=$(curl -sS -D - \
  -o /dev/null \
  --max-time 15 \
  -X POST "https://api.anthropic.com/v1/messages" \
  -H "authorization: Bearer $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}' \
  2>&1) || { echo "refresh-ratelimit: curl failed" >&2; exit 1; }

# ── Parse header values (case-insensitive grep) ───────────────────────────────
parse_header() {
  # $1 = header name fragment (lowercase)
  echo "$HEADERS" | grep -i "$1" | head -1 | awk -F': ' '{print $2}' | tr -d '\r\n '
}

FIVE_H_RESET=$(parse_header "ratelimit-unified-5h-reset")
FIVE_H_UTIL=$(parse_header "ratelimit-unified-5h-utilization")
FIVE_H_STATUS=$(parse_header "ratelimit-unified-5h-status")
SEVEN_D_RESET=$(parse_header "ratelimit-unified-7d-reset")
SEVEN_D_UTIL=$(parse_header "ratelimit-unified-7d-utilization")
SEVEN_D_STATUS=$(parse_header "ratelimit-unified-7d-status")

# Require the two numeric utilization fields at minimum
if [ -z "$FIVE_H_UTIL" ] || [ -z "$SEVEN_D_UTIL" ]; then
  echo "refresh-ratelimit: missing utilization headers — headers received:" >&2
  echo "$HEADERS" | grep -i ratelimit >&2
  exit 1
fi

NOW=$(date +%s)

# ── Write atomically ──────────────────────────────────────────────────────────
python3 - <<PYEOF
import json, os

data = {
    "fetched_at":     $NOW,
    "five_h_reset":   int("${FIVE_H_RESET:-0}") if "${FIVE_H_RESET:-0}" else None,
    "five_h_util":    float("${FIVE_H_UTIL}"),
    "five_h_status":  "${FIVE_H_STATUS:-unknown}",
    "seven_d_reset":  int("${SEVEN_D_RESET:-0}") if "${SEVEN_D_RESET:-0}" else None,
    "seven_d_util":   float("${SEVEN_D_UTIL}"),
    "seven_d_status": "${SEVEN_D_STATUS:-unknown}",
}

tmp = "$TMP_FILE"
with open(tmp, "w") as f:
    json.dump(data, f)
    f.write("\n")
os.replace(tmp, "$CACHE_FILE")
PYEOF

echo "refresh-ratelimit: updated $CACHE_FILE" >&2
