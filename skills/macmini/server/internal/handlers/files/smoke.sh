#!/usr/bin/env bash
# smoke: round-trip a small file through /files/push and /files/pull, verify sha256.
set -euo pipefail

: "${MACMINI_URL:?MACMINI_URL must be set}"
: "${MACMINI_TOKEN:?MACMINI_TOKEN must be set}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/payload.bin"
DST="$WORK/payload.pulled.bin"
REMOTE="/tmp/macmini-skill/files-smoke.bin"

# 4 KiB of pseudo-random bytes
head -c 4096 /dev/urandom > "$SRC"
WANT_SHA="$(shasum -a 256 "$SRC" | awk '{print $1}')"

PUSH_RESP="$(curl -sfS --max-time 30 \
  -H "Authorization: Bearer ${MACMINI_TOKEN}" \
  -F "file=@${SRC}" \
  -F "remote_path=${REMOTE}" \
  -F "overwrite=true" \
  "${MACMINI_URL}/files/push")"

GOT_PUSH_SHA="$(echo "$PUSH_RESP" | jq -r '.sha256')"
if [[ "$GOT_PUSH_SHA" != "$WANT_SHA" ]]; then
  echo "files: push sha256 mismatch (want $WANT_SHA, got $GOT_PUSH_SHA)" >&2
  exit 1
fi

curl -sfS --max-time 30 \
  -H "Authorization: Bearer ${MACMINI_TOKEN}" \
  --output "$DST" \
  --dump-header "$WORK/headers.txt" \
  "${MACMINI_URL}/files/pull?remote_path=${REMOTE}"

GOT_PULL_SHA="$(shasum -a 256 "$DST" | awk '{print $1}')"
if [[ "$GOT_PULL_SHA" != "$WANT_SHA" ]]; then
  echo "files: pull sha256 mismatch (want $WANT_SHA, got $GOT_PULL_SHA)" >&2
  exit 1
fi

# Header sha matches too (lower-case match — curl preserves case in dump-header).
HDR_SHA="$(awk -F': ' 'tolower($1)=="x-sha256"{gsub(/\r/,""); print $2}' "$WORK/headers.txt" | tail -n1)"
if [[ -n "$HDR_SHA" && "$HDR_SHA" != "$WANT_SHA" ]]; then
  echo "files: X-SHA256 header mismatch (want $WANT_SHA, got $HDR_SHA)" >&2
  exit 1
fi

echo "files: ok"
