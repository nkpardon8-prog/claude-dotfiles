#!/usr/bin/env bash
# smoke: POST /shot returns a PNG (signature \x89PNG\r\n\x1a\n).
set -euo pipefail

: "${MACMINI_URL:?MACMINI_URL must be set}"
: "${MACMINI_TOKEN:?MACMINI_TOKEN must be set}"

OUT="$(mktemp -t macmini-shot-smoke.XXXXXX).png"
trap 'rm -f "$OUT"' EXIT

curl -sfS --max-time 15 -X POST \
  -H "Authorization: Bearer ${MACMINI_TOKEN}" \
  --output "$OUT" \
  "${MACMINI_URL}/shot"

# First 8 bytes must match PNG signature.
SIG_HEX="$(head -c 8 "$OUT" | xxd -p)"
EXPECTED="89504e470d0a1a0a"
if [[ "$SIG_HEX" != "$EXPECTED" ]]; then
  echo "shot: PNG signature mismatch (got $SIG_HEX, want $EXPECTED)" >&2
  echo "shot: response head:" >&2
  head -c 200 "$OUT" >&2
  exit 1
fi

echo "shot: ok"
