#!/usr/bin/env bash
# Assumption-test runner for the /mission parallel-collision fix.
# Order: prove-the-fix behavioral tests first (03/06/07/05), advisory audit last (02).
# Pre-implementation: 03/05/06 report PENDING (exit 3) until mission_resolve_path ships;
#   07 + 02 PASS now. Post-implementation: all five must PASS.
set -uo pipefail
if [ "${MISSION_SMOKE_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set MISSION_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# timeout shim: GNU `timeout`, macOS `gtimeout`, else run bare (no hang guard).
if command -v timeout >/dev/null 2>&1; then TO=(timeout 60)
elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 60)
else TO=(env); fi   # `env` is a no-op prefix; avoids bash-3.2 empty-array+set-u error
TESTS=( "03-sid-matched-resolution.sh" "06-empty-pointer-fallthrough.sh" "07-resume-clone.sh" "05-manifest-pointer-wins.sh" "02-no-cross-bind.sh" )
PASS=0; PENDING=0; START=$(date +%s)
for t in "${TESTS[@]}"; do
  echo; echo "--- ${t} ---"
  if "${TO[@]}" bash "${SCRIPT_DIR}/${t}"; then
    PASS=$((PASS+1))
  else
    rc=$?
    [ "$rc" = 124 ] && rc=3
    if [ "$rc" = 3 ]; then
      echo "(PENDING/infra — exit 3; not a logical failure)"
      PENDING=$((PENDING+1))
      continue
    fi
    echo "HALT: ${t} exited ${rc}" >&2
    exit "$rc"
  fi
done
echo; echo "PASS: ${PASS}/${#TESTS[@]} (PENDING/infra: ${PENDING}) in $(( $(date +%s) - START ))s"
# Post-implementation the resolver EXISTS, so a PENDING (exit 3) now signals a genuine infra/regression
# problem, not the pre-impl stub path — surface it as a failure rather than a silent green.
[ "${PENDING}" -gt 0 ] && { echo "FAIL: ${PENDING} test(s) PENDING/infra — expected all ${#TESTS[@]} to PASS post-implementation" >&2; exit 1; }
exit 0
