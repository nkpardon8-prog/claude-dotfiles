#!/usr/bin/env bash
# smoke: POST /paste sets the macOS clipboard and pbpaste reads it back verbatim.
set -euo pipefail

: "${MACMINI_URL:?MACMINI_URL must be set}"
: "${MACMINI_TOKEN:?MACMINI_TOKEN must be set}"

PAYLOAD="paste smoke test 123"

curl -sfS --max-time 5 \
  -H "Authorization: Bearer ${MACMINI_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg t "$PAYLOAD" '{text:$t}')" \
  "${MACMINI_URL}/paste" | jq -e '.ok == true' >/dev/null

# pbpaste only works locally on the Mac mini. If running against a remote URL
# this will read the LOCAL clipboard which is a useful canary when run on the
# Mac mini itself; skip silently when pbpaste isn't present.
if command -v pbpaste >/dev/null 2>&1; then
  GOT="$(pbpaste)"
  if [[ "$GOT" != "$PAYLOAD" ]]; then
    echo "paste: clipboard mismatch (expected $PAYLOAD, got $GOT)" >&2
    exit 1
  fi
fi

echo "paste: ok"
