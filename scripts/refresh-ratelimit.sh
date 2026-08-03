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
# The extracted values are UNTRUSTED (they come off the wire). They are never
# interpolated into any interpreter's program text - see the python3 call below.
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
# SECURITY: every value below originates in a raw HTTP response header, i.e. off
# this machine. Nothing is interpolated into the program text - the heredoc
# delimiter is QUOTED ('PYEOF') so the shell performs no expansion inside it, and
# all values arrive via argv. Python then coerces each field to its declared type
# (int / float / status token) and refuses to write anything it cannot coerce, so
# ~/.claude/ratelimit.json can only ever hold well-typed values for the consumer
# (scripts/statusline.sh). Key set is a contract with that consumer - changing a
# key here means changing it there in the same commit.
python3 - \
  "$TMP_FILE" "$CACHE_FILE" "$NOW" \
  "${FIVE_H_RESET:-}" "${FIVE_H_UTIL:-}" "${FIVE_H_STATUS:-}" \
  "${SEVEN_D_RESET:-}" "${SEVEN_D_UTIL:-}" "${SEVEN_D_STATUS:-}" <<'PYEOF'
import json, os, re, sys

tmp, cache, now = sys.argv[1], sys.argv[2], sys.argv[3]
five_reset, five_util, five_status = sys.argv[4], sys.argv[5], sys.argv[6]
seven_reset, seven_util, seven_status = sys.argv[7], sys.argv[8], sys.argv[9]

# \Z not $ - `$` also matches just before a trailing newline, so "allowed\n"
# would otherwise be accepted verbatim into the cache.
STATUS_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}\Z")


def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def as_status(value):
    return value if STATUS_RE.match(value or "") else "unknown"


five_util_num = as_float(five_util)
seven_util_num = as_float(seven_util)
if five_util_num is None or seven_util_num is None:
    sys.stderr.write("refresh-ratelimit: non-numeric utilization header - not writing cache\n")
    sys.exit(1)

data = {
    "fetched_at":     as_int(now) or 0,
    "five_h_reset":   as_int(five_reset),
    "five_h_util":    five_util_num,
    "five_h_status":  as_status(five_status),
    "seven_d_reset":  as_int(seven_reset),
    "seven_d_util":   seven_util_num,
    "seven_d_status": as_status(seven_status),
}

with open(tmp, "w") as f:
    json.dump(data, f)
    f.write("\n")
os.replace(tmp, cache)
PYEOF

RC=$?
if [ "$RC" -ne 0 ]; then
  rm -f "$TMP_FILE" 2>/dev/null || true
  echo "refresh-ratelimit: cache write failed (exit $RC)" >&2
  exit "$RC"
fi

echo "refresh-ratelimit: updated $CACHE_FILE" >&2
