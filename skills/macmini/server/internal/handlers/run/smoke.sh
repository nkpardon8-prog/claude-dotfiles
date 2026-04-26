#!/usr/bin/env bash
# smoke: /run buffered + timeout, /run/stream NDJSON.
set -euo pipefail

: "${MACMINI_URL:?MACMINI_URL must be set}"
: "${MACMINI_TOKEN:?MACMINI_TOKEN must be set}"

# 1. buffered echo
RESP="$(curl -sfS --max-time 10 \
  -H "Authorization: Bearer ${MACMINI_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command":"echo hi"}' \
  "${MACMINI_URL}/run")"

echo "$RESP" | jq -e '.exit_code == 0 and (.stdout | startswith("hi"))' >/dev/null || {
  echo "run: buffered echo failed: $RESP" >&2
  exit 1
}

# 2. buffered timeout — assert exit 124 and no orphan processes.
SENTINEL="macmini-smoke-$(date +%s)-$$"
RESP="$(curl -sfS --max-time 15 \
  -H "Authorization: Bearer ${MACMINI_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg s "$SENTINEL" '{command: ("sleep 30 # " + $s), timeout_seconds: 2}')" \
  "${MACMINI_URL}/run")"

echo "$RESP" | jq -e '.exit_code == 124' >/dev/null || {
  echo "run: timeout did not produce exit 124: $RESP" >&2
  exit 1
}

# Give the kill-group 3s to complete.
sleep 3
if pgrep -f "$SENTINEL" >/dev/null 2>&1; then
  echo "run: orphan process still alive after timeout (sentinel=$SENTINEL)" >&2
  pgrep -af "$SENTINEL" >&2 || true
  exit 1
fi

# 3. streaming counter — assert 3 stdout lines + final exit event.
NDJSON="$(curl -sfS --max-time 15 -N \
  -H "Authorization: Bearer ${MACMINI_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command":"for i in 1 2 3; do echo $i; sleep 0.1; done"}' \
  "${MACMINI_URL}/run/stream")"

LINES="$(echo "$NDJSON" | jq -c 'select(.stream=="stdout")' | wc -l | tr -d ' ')"
if [[ "$LINES" -lt 3 ]]; then
  echo "run: expected >=3 stdout lines, got $LINES" >&2
  echo "$NDJSON" >&2
  exit 1
fi

if ! echo "$NDJSON" | jq -e 'select(.event=="exit") | .code == 0' >/dev/null; then
  echo "run: streaming did not produce exit event with code 0" >&2
  echo "$NDJSON" >&2
  exit 1
fi

echo "run: ok"
