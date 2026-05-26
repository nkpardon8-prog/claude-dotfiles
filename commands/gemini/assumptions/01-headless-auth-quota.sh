#!/usr/bin/env bash
# 01 — Headless auth + quota actually serves a `-p` call (via the wrapper).
#
# The load-bearing premise of the whole feature: a non-interactive `gemini -p`
# returns real model text on the configured auth (free AI Pro OAuth, or GEMINI_API_KEY).
# `--help` cannot prove this — only a live call can.
#
# A1 — wrapper exits 0 (always true by design; asserted as a guard).
# A2 — output is non-empty and is NOT an [empty]/[timeout]/[unavailable] marker,
#      i.e. the model genuinely answered. ("Answer correctness" is deliberately NOT
#      asserted — not machine-checkable in a smoke test.)
#
# NEGATIVE CONTROL: the un-authenticated state IS the red route — with no creds the
# wrapper emits [empty], so A2 fails. Proven below by the auth pre-check exiting 3.
set -uo pipefail

if [ "${GEMINI_ATEST_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set GEMINI_ATEST_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi

WRAPPER="$HOME/.claude-dotfiles/commands/gemini/lib/gemini-invoke.sh"
[ -f "$WRAPPER" ] || { echo "INFRA FAIL: wrapper not found at $WRAPPER" >&2; exit 3; }

# Auth pre-check: distinguish "not set up yet" (INFRA, exit 3) from "set up but broken".
if [ -z "${GEMINI_API_KEY:-}" ] && [ ! -f "$HOME/.gemini/oauth_creds.json" ]; then
  echo "INFRA: not authenticated — run \`gemini\` once and sign in with your Google AI Pro account (or export GEMINI_API_KEY). See README." >&2
  exit 3
fi

OUT="$(mktemp -t gemini_atest_01_XXXX)"
trap 'rm -f "$OUT"' EXIT

bash "$WRAPPER" "$OUT" "Reply with exactly the single word: pong" "$PWD"
rc=$?

failures=()
[ "$rc" = "0" ] || failures+=("A1 expected exit 0, got $rc")
if head -n1 "$OUT" | grep -qE '^\[(empty|timeout|unavailable)\]'; then
  failures+=("A2 model did not answer — got marker: $(head -n1 "$OUT")")
elif [ ! -s "$OUT" ]; then
  failures+=("A2 output empty")
fi

if [ "${#failures[@]}" -eq 0 ]; then
  echo "PASS: 01-headless-auth-quota — 2 assertions (A1 exit 0, A2 model answered: '$(head -c 40 "$OUT" | tr '\n' ' ')')"
  exit 0
else
  echo "FAIL: 01-headless-auth-quota"; for f in "${failures[@]}"; do echo "  - $f"; done; exit 1
fi
