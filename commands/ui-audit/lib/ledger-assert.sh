#!/bin/bash
# ledger-assert.sh — the /ui-audit Phase-4 fail-closed coverage gate.
#
# Usage:  bash ledger-assert.sh <out-dir>        (or: OUT=<out-dir> bash ledger-assert.sh)
#
# Reads <out>/ledger.json and FAILS CLOSED (exit 1, status=INCOMPLETE) when either:
#   (a) the number of ENUMERATED elements != the number with a non-null verdict
#       (something was left unverdicted — coverage is not complete), OR
#   (b) any per-state ledger count != that state's recorded INDEPENDENT visible-node count
#       (enumeration loss/truncation — not just a missing verdict).
# Offenders are listed. It appends `status=INCOMPLETE|COMPLETE` to <out>/status.txt.

set -euo pipefail

OUT="${1:-${OUT:-}}"
if [ -z "$OUT" ]; then echo "usage: bash ledger-assert.sh <out-dir>" >&2; exit 2; fi

LEDGER="$OUT/ledger.json"
STATUS_FILE="$OUT/status.txt"
if [ ! -f "$LEDGER" ]; then echo "ledger-assert: no ledger at $LEDGER" >&2; exit 2; fi
if ! command -v jq >/dev/null 2>&1; then echo "ledger-assert: jq is required" >&2; exit 2; fi

fail=0

# (a) enumerated vs verdicted
enumerated=$(jq '.elements | length' "$LEDGER")
verdicted=$(jq '[.elements[] | select(.verdict != null)] | length' "$LEDGER")
if [ "$enumerated" != "$verdicted" ]; then
  fail=1
  echo "INCOMPLETE: $enumerated enumerated element(s), but only $verdicted have a verdict." >&2
  echo "  unverdicted element keys (up to 25):" >&2
  jq -r '[.elements[] | select(.verdict == null) | .key][0:25][] | "    - " + .' "$LEDGER" >&2 || true
fi

# (b) per-state ledger count vs independent visible-node count
mismatch=$(jq -r '[.states[] | select(.ledgerCount != .independentVisibleCount)
  | "    - state " + (.id|tostring) + ": ledgerCount=" + (.ledgerCount|tostring)
    + " independentVisibleCount=" + (.independentVisibleCount|tostring)] | .[]' "$LEDGER")
if [ -n "$mismatch" ]; then
  fail=1
  echo "INCOMPLETE: per-state ledger count != independent visible-node count (enumeration loss):" >&2
  echo "$mismatch" >&2
fi

if [ "$fail" -eq 0 ]; then
  echo "status=COMPLETE" >> "$STATUS_FILE"
  echo "COMPLETE: $enumerated element(s) all verdicted; all per-state counts reconcile."
  exit 0
else
  echo "status=INCOMPLETE" >> "$STATUS_FILE"
  exit 1
fi
