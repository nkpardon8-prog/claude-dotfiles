#!/usr/bin/env bash
# smoke: GET /health returns ok=true. No auth required.
set -euo pipefail

: "${MACMINI_URL:?MACMINI_URL must be set, e.g. http://macmini.tail-XXXX.ts.net:8765}"

curl -sfS --max-time 5 "${MACMINI_URL}/health" | jq -e '.ok == true and (.version | type == "string") and (.uptime_seconds | type == "number")' >/dev/null

echo "health: ok"
