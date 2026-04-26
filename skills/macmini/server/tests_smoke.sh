#!/usr/bin/env bash
# Top-level smoke runner. Discovers per-handler smoke.sh scripts under
# internal/handlers/*/smoke.sh, runs each in sorted order, aborts on first
# failure with the failing handler name.
set -euo pipefail

: "${MACMINI_URL:?MACMINI_URL must be set, e.g. http://macmini.tail-XXXX.ts.net:8765}"
: "${MACMINI_TOKEN:?MACMINI_TOKEN must be set (Bearer token for macmini-server)}"

# Resolve the directory of this script so we can run from anywhere.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Precheck: server is up.
if ! curl -sfS --max-time 5 "${MACMINI_URL}/health" >/dev/null; then
  echo "smoke: precheck failed — ${MACMINI_URL}/health is not responding" >&2
  exit 2
fi

shopt -s nullglob
SCRIPTS=("$DIR"/internal/handlers/*/smoke.sh)
if [[ ${#SCRIPTS[@]} -eq 0 ]]; then
  echo "smoke: no handler smoke scripts found under $DIR/internal/handlers/*/smoke.sh" >&2
  exit 2
fi

# Sort for deterministic order, then push the admin handler to the end because
# it mutates server-side state (token rotation). Skip admin entirely unless
# MACMINI_SMOKE_ADMIN=1 — rotating the token mid-test stream would invalidate
# MACMINI_TOKEN for any later run.
IFS=$'\n' SORTED=($(printf '%s\n' "${SCRIPTS[@]}" | sort))
unset IFS

NON_ADMIN=()
ADMIN=()
for s in "${SORTED[@]}"; do
  if [[ "$(basename "$(dirname "$s")")" == "admin" ]]; then
    ADMIN+=("$s")
  else
    NON_ADMIN+=("$s")
  fi
done
SORTED=("${NON_ADMIN[@]}")
if [[ "${MACMINI_SMOKE_ADMIN:-0}" == "1" ]]; then
  SORTED+=("${ADMIN[@]}")
fi

FAIL=()
for s in "${SORTED[@]}"; do
  HANDLER="$(basename "$(dirname "$s")")"
  echo "=== smoke: $HANDLER ==="
  if ! bash "$s"; then
    echo "smoke: FAILED in handler '$HANDLER' (script: $s)" >&2
    FAIL+=("$HANDLER")
    break
  fi
done

if [[ ${#FAIL[@]} -gt 0 ]]; then
  exit 1
fi

echo "smoke: all handlers passed"
