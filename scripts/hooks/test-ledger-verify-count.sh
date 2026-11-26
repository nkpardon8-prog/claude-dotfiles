#!/usr/bin/env bash
# test-ledger-verify-count.sh - runs the /codex-review ledger count block (Step 6e), extracted
# verbatim from commands/codex-review.md, on synthetic verify output. An unresolved high-risk
# finding (UNCERTAIN | BLOCKING) must count as blocking, or bank-review would bank the round clean.
set -euo pipefail
DOC="$(cd "$(dirname "$0")/../.." && pwd)/commands/codex-review.md"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BLOCK="$(awk '/^V="\$RUN_DIR\/codex-verify.txt"/{on=1} on{print} on&&/^areas=/{exit}' "$DOC")"
[ -n "$BLOCK" ] || { echo "FAIL could not extract the count block"; exit 1; }
pass=0; fail=0
run() { # run <name> <expected "blocking tagged"> <verify-file-content>
  printf '%s\n' "$3" > "$T/codex-verify.txt"
  got="$(RUN_DIR="$T" bash -c "$BLOCK"'
echo "$blocking $tagged"')"
  if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: expected '$2' got '$got'"; fi
}
run "unresolved high-risk counts" "1 1" "F1 | UNCERTAIN | BLOCKING | - | auth.ts:40 token check reads config we cannot see -> unauthenticated read
TAG | AUTH-CONFIG-BYPASS | new | IMPL | server/src/auth | depends on unverified config
Verdict: needs-fixes"
run "confirmed + nonblocking" "1 1" "F1 | CONFIRMED | BLOCKING | - | ran npm test -> claims.test.ts fails at 12
F2 | UNCERTAIN | NONBLOCKING | - | -
F3 | FALSE_POSITIVE | NONBLOCKING | - | -
N1 | CONFIRMED | NONBLOCKING | MINOR LOGIC a.ts:3 naming | -
TAG | CLAIM-TOTAL | repeat | IMPL | server/src/claims | wrong total
Verdict: needs-fixes"
run "final-sweep uncertain blocking" "1 0" "N1 | UNCERTAIN | BLOCKING | CRITICAL SECURITY phi.ts:9 logs name | trace: req -> logger.info(patient) -> stdout
Verdict: needs-fixes"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
