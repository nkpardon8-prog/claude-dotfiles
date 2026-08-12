#!/usr/bin/env bash
# run-all.sh — line-agent-communicator assumption tests.
# Pre-implementation gate AND post-ship regression gate for the peer-directory / reachability fix.
#
# Unlike the sibling session-correlation runner, this one does NOT halt on the first FAIL. Some tests
# are authored RED as a pre-implementation gate for a fix that has not landed - halting on them would
# hide their siblings behind a known defect and make the suite useless as a gate. So: run all, tally,
# then report the expected-red ones separately from real regressions.
#
# EXIT CODES - the caller distinguishes "a defense regressed" from "we could not measure":
#   0 = every test NOT listed in EXPECTED_RED passed.
#   1 = a genuine assertion failure. The pre-commit hook BLOCKS on this, and only this.
#   3 = no genuine failures, but one or more tests could not run (missing python3, no live claude
#       window for 05's positive control, a listener that never bound, a fixture process that died,
#       a 120s timeout on a loaded machine).
#
# WHY 3 IS NOT 1 (the concrete failure): infra/skip results used to be appended to
# RED_UNEXPECTED_MSGS, and the final `if [ -n "$RED_UNEXPECTED_MSGS" ]` exits 1 - so 7 passes plus
# one exit-3 skip exited 1. The pre-commit hook's "exit 3 must not block" valve was therefore dead,
# and a 1 there makes dotfiles-sync take its COMMIT FAILED branch, which writes
# ~/.claude/.dotfiles-sync-paused and stops ALL dotfiles syncing in EVERY window until a human
# deletes it. A transient probe failure must never be able to do that.
#
# 02-05 are correctness assumptions (time comparison, fixture validity, socket liveness, comm
# matching). 06-08 are SECURITY regressions and are a different kind of thing: each encodes an
# attack that was demonstrated to work, so a re-reddening there is not a flaky probe - it is the
# defense being gone. Each carries a negative control that was run and observed red.
#
# 09 is a DATA-LOSS gate: retention may only ever delete a reply that is already-read AND old, and
# it exists because a reaper on a guaranteed-delivery mailbox destroys undelivered answers silently
# if that AND ever degrades to an OR. Same shape as 06-08 - a re-reddening means the guard is gone.
set -uo pipefail
if [ "${LINE_AGENT_TESTS_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bounded-run shim: GNU `timeout`, macOS `gtimeout`, else perl's alarm (macOS ships no timeout(1)).
# alarm survives exec, so `exec @ARGV` still dies on SIGALRM -> exit 142; GNU timeout uses 124.
# The array is never empty - a `TO=(env)` style no-op prefix is required because bash 3.2 aborts on
# `"${TO[@]}"` for an EMPTY array under `set -u`.
if command -v timeout >/dev/null 2>&1; then TO=(timeout 120)
elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 120)
else TO=(perl -e 'alarm shift; exec @ARGV' 120); fi

TESTS=(
  "02-starttime-comparison.sh"
  "03-fake-home-fixture.sh"
  "04-stale-socket-reachability.sh"
  "05-comm-overmatch.sh"
  "06-forged-registry-whois.sh"
  "07-banner-injection.sh"
  "08-dropbox-symlink.sh"
  "09-reply-retention.sh"
)
# The two tests that are red until the fix ships. Empty this list as each one is fixed.
# Emptied 2026-08-12: 04 and 05 were authored RED on purpose (they encoded the orphaned-socket and
# path-substring defects). Both defects are fixed and both tests now pass, so they gate from here on
# — a re-reddening is a regression, not a known state. Anything listed here is a test whose failure
# is tolerated, which is one edit away from a suite that proves nothing; keep it empty.
EXPECTED_RED=" "

# Counters + strings, NOT arrays: on macOS bash 3.2 `${#arr[@]}` on an EMPTY array under `set -u`
# aborts with "unbound variable" - and the empty case here is the everything-passed case.
PASS=0; SKIP=0; RED_EXPECTED=0; RED_UNEXPECTED=0
RED_EXPECTED_MSGS=""; RED_UNEXPECTED_MSGS=""; SKIP_MSGS=""
START=$(date +%s)

for t in "${TESTS[@]}"; do
  echo; echo "--- ${t} ---"
  rc=0
  "${TO[@]}" bash "${SCRIPT_DIR}/${t}" || rc=$?
  # A timeout is an infrastructure result, not a verdict: on a loaded machine a 120s cap says
  # nothing about the defense. It joins the skips, NOT the failures.
  TIMED_OUT=""
  { [ "$rc" = 124 ] || [ "$rc" = 142 ]; } && { rc=3; TIMED_OUT=" (120s timeout)"; }
  case "$rc" in
    0) PASS=$((PASS+1)) ;;
    3) SKIP=$((SKIP+1))
       SKIP_MSGS="${SKIP_MSGS}  - ${t}: exit 3 - could not run${TIMED_OUT}, no verdict
"
       ;;
    *) case "$EXPECTED_RED" in
         *" ${t} "*)
           RED_EXPECTED=$((RED_EXPECTED+1))
           RED_EXPECTED_MSGS="${RED_EXPECTED_MSGS}  - ${t}: exit ${rc} - KNOWN DEFECT (pre-fix)
"
           ;;
         *)
           RED_UNEXPECTED=$((RED_UNEXPECTED+1))
           RED_UNEXPECTED_MSGS="${RED_UNEXPECTED_MSGS}  - ${t}: exit ${rc}
"
           ;;
       esac ;;
  esac
done

echo
echo "PASS: ${PASS}/${#TESTS[@]} in $(( $(date +%s) - START ))s   (failed: ${RED_UNEXPECTED}, not measured: ${SKIP}, known-red: ${RED_EXPECTED})"

if [ -n "$RED_EXPECTED_MSGS" ]; then
  echo
  echo "KNOWN DEFECTS (pre-fix) - ${RED_EXPECTED} test(s), not gating today:"
  printf '%s' "$RED_EXPECTED_MSGS"
  echo "  These are the regression catchers for the fix. When the fix lands they must go green;"
  echo "  empty EXPECTED_RED in this file at that moment so they gate from then on."
fi

if [ -n "$SKIP_MSGS" ]; then
  echo >&2
  echo "NOT MEASURED - ${SKIP} test(s) could not run (infrastructure, not a regression):" >&2
  printf '%s' "$SKIP_MSGS" >&2
fi

if [ -n "$RED_UNEXPECTED_MSGS" ]; then
  echo >&2
  echo "FAILED - ${RED_UNEXPECTED} unexpected failure(s), ${SKIP} not measured:" >&2
  printf '%s' "$RED_UNEXPECTED_MSGS" >&2
  exit 1
fi

# Skips with no genuine failure: report 3 so the caller can tell "nothing regressed" from
# "nothing was proven". The pre-commit hook treats anything that is not 1 as non-blocking.
if [ "$SKIP" -gt 0 ]; then
  echo "INCOMPLETE - ${PASS} passed, ${SKIP} not measured, 0 failed." >&2
  exit 3
fi

exit 0
