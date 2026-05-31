#!/usr/bin/env bash
# run-all.sh — session-correlation assumption tests.
# Pre-implementation gate AND post-ship regression gate for the bulletproof session-correlation fix.
# Halts on first FAIL; maps a hang (timeout, exit 124) to INFRASTRUCTURE FAIL (exit 3).
set -uo pipefail
if [ "${CORRELATION_TESTS_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set CORRELATION_TESTS_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS=(
  "01-own-claude-pid-resolution.sh"
  "02-foreground-leader-pid-pinned.sh"
  "03-pid-identity-reuse-defense.sh"
  "04-pid-tty-derivation-edge.sh"
  "05-resume-idempotency-marker.sh"
  "06-toctou-tty-format-parity.sh"
)
# macOS has no timeout(1); use perl alarm as the bounded-run wrapper (matches arm-auto-compact.sh).
run_bounded() { perl -e 'alarm shift; exec @ARGV' 60 bash "$1"; }   # exit 142 on SIGALRM
PASS=0; START=$(date +%s)
for t in "${TESTS[@]}"; do
  echo; echo "--- ${t} ---"
  if run_bounded "${SCRIPT_DIR}/${t}"; then
    PASS=$((PASS+1))
  else
    rc=$?
    { [ "$rc" = 124 ] || [ "$rc" = 142 ]; } && rc=3   # timeout/hang -> INFRASTRUCTURE FAIL
    echo "HALT: ${t} exited ${rc}" >&2
    exit "$rc"
  fi
done
echo; echo "PASS: ${PASS}/${#TESTS[@]} in $(( $(date +%s) - START ))s"
