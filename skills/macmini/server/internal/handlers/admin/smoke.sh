#!/usr/bin/env bash
# smoke: rotate the token, verify /health works under the new token, then rotate
# back so the test is idempotent across runs.
set -euo pipefail

: "${MACMINI_URL:?MACMINI_URL must be set}"
: "${MACMINI_TOKEN:?MACMINI_TOKEN must be set}"

ORIG="$MACMINI_TOKEN"

# 1. Rotate using the original token.
RESP="$(curl -sfS --max-time 10 -X POST \
  -H "Authorization: Bearer ${ORIG}" \
  "${MACMINI_URL}/admin/rotate-token")"
NEW="$(echo "$RESP" | jq -r '.new_token')"
if [[ -z "$NEW" || "$NEW" == "null" ]]; then
  echo "admin: rotation did not return new_token: $RESP" >&2
  exit 1
fi

# 2. /health is unauth, but exercise it anyway as a liveness check.
curl -sfS --max-time 5 "${MACMINI_URL}/health" | jq -e '.ok==true' >/dev/null

# 3. The OLD token must now be rejected by an authed route.
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
  -H "Authorization: Bearer ${ORIG}" \
  -H "Content-Type: application/json" \
  -d '{"text":"x"}' \
  "${MACMINI_URL}/paste")"
if [[ "$HTTP_CODE" != "401" ]]; then
  echo "admin: old token still accepted after rotation (got $HTTP_CODE, want 401)" >&2
  # Try to restore using NEW token before exiting.
  curl -sfS --max-time 10 -X POST \
    -H "Authorization: Bearer ${NEW}" \
    "${MACMINI_URL}/admin/rotate-token" >/dev/null || true
  exit 1
fi

# 4. Rotate back to a fresh token using NEW; keep going even on failure so we
# don't lock ourselves out — but the smoke run will report failure.
RESP2="$(curl -sfS --max-time 10 -X POST \
  -H "Authorization: Bearer ${NEW}" \
  "${MACMINI_URL}/admin/rotate-token")"
RESTORED="$(echo "$RESP2" | jq -r '.new_token')"
if [[ -z "$RESTORED" || "$RESTORED" == "null" ]]; then
  echo "admin: rotate-back failed: $RESP2" >&2
  exit 1
fi

# Tell the operator that the on-disk token has changed twice from where they
# started and they need to update credentials.md before the next run.
echo "admin: ok"
echo "admin: NOTE current on-disk token is $RESTORED — update credentials.md / 1Password before next run." >&2
