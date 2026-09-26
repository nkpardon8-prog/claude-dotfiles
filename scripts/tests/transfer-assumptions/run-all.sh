#!/usr/bin/env bash
# run-all.sh - transfer-assumptions suite runner. Pre-implementation gate AND post-ship regression
# net for /transfer + resumework (scripts/transfer/*). Modeled on
# scripts/tests/line-agent-assumptions/run-all.sh - same gate, same bounded-run shim, same
# exit-code vocabulary, same reason (a transient probe failure must never be able to trip
# dotfiles-sync's "commit failed, pause everything" branch).
#
# EXIT CODES:
#   0 = every test passed.
#   1 = a genuine assertion failure. The pre-commit hook BLOCKS on this, and only this.
#   3 = no genuine failures, but one or more tests could not run (missing tool, INFRA setup that
#       could not be built). Never a failure verdict.
#
# 99-resume-keeps-sid.sh is NEVER included here - it costs a real model call and is run by a
# human, deliberately, with TRANSFER_LIVE_CLAUDE=1.
set -uo pipefail
if [ "${TRANSFER_TESTS_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bounded-run shim: GNU `timeout`, macOS `gtimeout`, else perl's alarm (macOS ships no timeout(1)).
if command -v timeout >/dev/null 2>&1; then TO=(timeout 120)
elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 120)
else TO=(perl -e 'alarm shift; exec @ARGV' 120); fi

TESTS=(
  "01-claude-roundtrip.sh"
  "02-codex-roundtrip.sh"
  "03-git-state-roundtrip.sh"
  "04-exclusions-negative-control.sh"
  "05-public-repo-guard.sh"
  "06-wrong-code-and-tamper.sh"
  "07-identity-and-path-refusal.sh"
  "08-memory-merge.sh"
  "09-handoff-refusal.sh"
  "10-expiry-sweep.sh"
  "11-reverse-transfer.sh"
  "12-sealer-fake-pid.sh"
  "13-separate-worktree.sh"
  "14-git-backout.sh"
  "15-alias-reverse.sh"
  "16-install-app-marker.sh"
)

# Counters + strings, NOT arrays: macOS bash 3.2's `${#arr[@]}` on an EMPTY array under `set -u`
# aborts with "unbound variable" - and the all-passed case is exactly the empty-array case.
PASS=0; SKIP=0; FAILN=0
FAIL_MSGS=""; SKIP_MSGS=""
START=$(date +%s)

for t in "${TESTS[@]}"; do
  echo; echo "--- ${t} ---"
  rc=0
  "${TO[@]}" bash "${SCRIPT_DIR}/${t}" || rc=$?
  TIMED_OUT=""
  { [ "$rc" = 124 ] || [ "$rc" = 142 ]; } && { rc=3; TIMED_OUT=" (120s timeout)"; }
  case "$rc" in
    0) PASS=$((PASS + 1)) ;;
    2) SKIP=$((SKIP + 1)); SKIP_MSGS="${SKIP_MSGS}  - ${t}: exit 2 - REFUSED (gate not set?)${TIMED_OUT}
" ;;
    3) SKIP=$((SKIP + 1)); SKIP_MSGS="${SKIP_MSGS}  - ${t}: exit 3 - could not run${TIMED_OUT}, no verdict
" ;;
    *) FAILN=$((FAILN + 1)); FAIL_MSGS="${FAIL_MSGS}  - ${t}: exit ${rc}${TIMED_OUT}
" ;;
  esac
done

echo
echo "PASS: ${PASS}/${#TESTS[@]} in $(( $(date +%s) - START ))s   (failed: ${FAILN}, not measured: ${SKIP})"

if [ -n "$SKIP_MSGS" ]; then
  echo >&2
  echo "NOT MEASURED - ${SKIP} test(s) could not run (infrastructure, not a regression):" >&2
  printf '%s' "$SKIP_MSGS" >&2
fi

if [ -n "$FAIL_MSGS" ]; then
  echo >&2
  echo "FAILED - ${FAILN} unexpected failure(s), ${SKIP} not measured:" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

if [ "$SKIP" -gt 0 ]; then
  echo "INCOMPLETE - ${PASS} passed, ${SKIP} not measured, 0 failed." >&2
  exit 3
fi

exit 0
