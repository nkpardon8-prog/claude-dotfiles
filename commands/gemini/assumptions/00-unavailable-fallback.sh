#!/usr/bin/env bash
# 00 — Wrapper safety fallback (AUTH-INDEPENDENT, always runnable).
#
# Proves the "never block a caller" invariant: the wrapper writes a precise marker
# and exits 0 whether the binary is MISSING or merely SILENT. This is the one test
# that runs green before you've authenticated — run it first to confirm the harness.
#
# A1 — missing binary  → output starts with [unavailable], exit 0.
# A2 — present-but-silent binary (`false`) → output does NOT claim [unavailable]
#      (it is [empty]); exit 0. This is the negative control proving the [unavailable]
#      marker is not spuriously emitted.
#
# NEGATIVE CONTROL: A2 is the controllable-precondition red route for A1 — pointing
# GEMINI_BIN at a real binary that emits nothing must NOT yield [unavailable]; if the
# wrapper mislabeled it, A2 fails. Together A1+A2 prove the marker discriminates.
set -uo pipefail

if [ "${GEMINI_ATEST_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set GEMINI_ATEST_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi

WRAPPER="$HOME/.claude-dotfiles/commands/gemini/lib/gemini-invoke.sh"
[ -f "$WRAPPER" ] || { echo "INFRA FAIL: wrapper not found at $WRAPPER" >&2; exit 3; }

RUN_ID="$(uuidgen 2>/dev/null || echo "$$")"
OUT="$(mktemp -t gemini_atest_00_XXXX)"
trap 'rm -f "$OUT"' EXIT

failures=()

# A1 — missing binary
GEMINI_BIN="/nonexistent/gemini-$RUN_ID" bash "$WRAPPER" "$OUT" "ping" "$PWD"
rc=$?
[ "$rc" = "0" ] || failures+=("A1 expected exit 0, got $rc")
head -n1 "$OUT" | grep -q '^\[unavailable\]' || failures+=("A1 expected [unavailable] marker, got: $(head -c 80 "$OUT")")

# A2 — present-but-silent binary (negative control)
GEMINI_BIN="false" bash "$WRAPPER" "$OUT" "ping" "$PWD"
rc=$?
[ "$rc" = "0" ] || failures+=("A2 expected exit 0, got $rc")
if head -n1 "$OUT" | grep -q '^\[unavailable\]'; then
  failures+=("A2 negative control breached: silent binary wrongly labeled [unavailable]")
fi

if [ "${#failures[@]}" -eq 0 ]; then
  echo "PASS: 00-unavailable-fallback — 2 assertions (A1 missing→[unavailable], A2 silent→not-[unavailable])"
  exit 0
else
  echo "FAIL: 00-unavailable-fallback"
  for f in "${failures[@]}"; do echo "  - $f"; done
  exit 1
fi
