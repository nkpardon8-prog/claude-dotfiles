#!/usr/bin/env bash
# 03 — The wrapper never hangs on an untrusted workspace (the "never block a caller" invariant).
#
# Gemini CLI prompts to "trust" an unfamiliar workspace folder. Under headless `-p`
# with no stdin "yes", that prompt could hang forever — silently blocking every caller
# (master-review, god-review). The wrapper passes --skip-trust and a perl timeout to
# prevent this. `--help` cannot prove the runtime doesn't hang; a wall-clock test can.
#
# A1 — wrapper invoked against a brand-new, never-seen dir RETURNS within a wall-clock
#      bound (timeout + margin) instead of hanging. (We assert it returns, not that the
#      model answered — an [empty] from missing auth still counts as "did not hang".)
#
# NEGATIVE CONTROL (synthetic): the perl SIGALRM timeout was independently verified to
#   fire (`alarm N; exec sleep 10` → rc 142 at N seconds). If the wrapper ignored the
#   timeout, this test's wall-clock guard (2x GEMINI_TIMEOUT) would itself trip → FAIL.
set -uo pipefail

if [ "${GEMINI_ATEST_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set GEMINI_ATEST_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi

WRAPPER="$HOME/.claude-dotfiles/commands/gemini/lib/gemini-invoke.sh"
[ -f "$WRAPPER" ] || { echo "INFRA FAIL: wrapper not found" >&2; exit 3; }
command -v "${GEMINI_BIN:-gemini}" >/dev/null 2>&1 || { echo "INFRA FAIL: gemini binary missing" >&2; exit 3; }

# A fresh dir the CLI has provably never trusted (unique per run).
WORK="$(mktemp -d -t gemini_atest_03_XXXX)"
OUT="$(mktemp -t gemini_atest_03out_XXXX)"
trap 'rm -rf "$WORK" "$OUT"' EXIT

INNER_TO=25          # wrapper's own per-call timeout
GUARD=$((INNER_TO * 2 + 20))   # outer wall-clock guard — if we hit this, the wrapper hung

start=$(date +%s)
GEMINI_TIMEOUT="$INNER_TO" perl -e 'alarm shift; exec @ARGV' "$GUARD" \
  bash "$WRAPPER" "$OUT" "Reply with the word ok." "$WORK"
guard_rc=$?
elapsed=$(( $(date +%s) - start ))

failures=()
# guard_rc 142 = our outer guard killed a hung wrapper.
[ "$guard_rc" = "142" ] && failures+=("A1 wrapper HUNG: outer guard fired at ${GUARD}s (likely a trust/auth prompt blocking)")
[ "$elapsed" -gt "$GUARD" ] && failures+=("A1 elapsed ${elapsed}s exceeded guard ${GUARD}s")

if [ "${#failures[@]}" -eq 0 ]; then
  echo "PASS: 03-trust-no-hang — 1 assertion (A1 returned in ${elapsed}s on an untrusted dir, no hang)"
  exit 0
else
  echo "FAIL: 03-trust-no-hang"; for f in "${failures[@]}"; do echo "  - $f"; done; exit 1
fi
