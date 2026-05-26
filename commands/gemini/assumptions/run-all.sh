#!/usr/bin/env bash
# Run all Gemini assumption tests in order. Halts on first FAIL or INFRA.
# Exit code = first non-pass test's code. Pre-flight gate AND regression catcher.
set -uo pipefail

if [ "${GEMINI_ATEST_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set GEMINI_ATEST_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS=(
  "00-unavailable-fallback.sh"
  "01-headless-auth-quota.sh"
  "02-plan-mode-readonly.sh"
  "03-trust-no-hang.sh"
  "04-wrapper-stdin-context.sh"
)

PASS=0
START=$(date +%s)
for t in "${TESTS[@]}"; do
  echo; echo "--- ${t} ---"
  bash "${SCRIPT_DIR}/${t}"
  rc=$?
  case "$rc" in
    0)   PASS=$((PASS+1)) ;;
    3)   echo ">> INFRA/auth: ${t} could not run. Authenticate (\`gemini\` login or GEMINI_API_KEY), then re-run. Halting." >&2; exit 3 ;;
    124|142) echo ">> TIMEOUT in ${t} → INFRASTRUCTURE FAIL. Halting." >&2; exit 3 ;;
    *)   echo ">> FAIL in ${t} (exit ${rc}). Halting." >&2; exit "$rc" ;;
  esac
done
echo; echo "PASS: ${PASS}/${#TESTS[@]} in $(( $(date +%s) - START ))s"
