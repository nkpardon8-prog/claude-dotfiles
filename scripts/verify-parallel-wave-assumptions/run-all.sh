#!/usr/bin/env bash
# run-all.sh - verify-parallel-wave / merge-wave assumption tests.
# Pre-implementation gate AND post-change regression gate for scripts/verify-parallel-wave.mjs
# and scripts/merge-wave.sh. Halts on the first FAIL; maps a hang (exit 124/142) to
# INFRASTRUCTURE FAIL (exit 3).
set -uo pipefail
if [ "${WAVECHECK_SMOKE_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set WAVECHECK_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# pt_run - portable timeout (macOS has no timeout(1)). COPY of
# ~/.claude-dotfiles/scripts/lib/portable-timeout.sh - KEEP THE TWO IN SYNC.
# exit 124 = timed out (child's whole process GROUP got TERM, then KILL after 2s).
pt_run() {  # pt_run <secs> <cmd...>
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=2 "$1" "${@:2}"
    return $?
  fi
  perl -e '
    my $t = shift;
    my $pid = fork;
    if (!$pid) { setpgrp(0,0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 };
    alarm $t;
    waitpid $pid, 0;
    exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
  ' "$@"
}

TESTS=(
  "01-validate-plan-golden.sh"
  "02-validate-plan-base-sha.sh"
  "03-validate-plan-ids-width.sh"
  "04-validate-plan-path-syntax.sh"
  "05-validate-plan-subtree-prefix.sh"
  "06-validate-plan-disjointness.sh"
  "07-validate-plan-command-allowlist.sh"
  "08-validate-plan-confidence-serial.sh"
  "09-wave-state-worktree-rules.sh"
  "10-wave-state-touched-rules.sh"
  "11-wave-state-repo-root-rules.sh"
  "12-events-and-reason-tokens.sh"
  "13-merge-wave-happy-resume.sh"
  "14-merge-wave-refusal-and-resume.sh"
  "15-merge-wave-conflict-abort.sh"
  "16-wave-state-plan-binding.sh"
  "17-merge-wave-branch-and-reasons.sh"
)
PASS=0; START=$(date +%s)
for t in "${TESTS[@]}"; do
  echo; echo "--- ${t} ---"
  if pt_run 120 bash "${SCRIPT_DIR}/${t}"; then
    PASS=$((PASS+1))
  else
    rc=$?
    { [ "$rc" = 124 ] || [ "$rc" = 142 ]; } && rc=3   # timeout/hang -> INFRASTRUCTURE FAIL
    echo "HALT: ${t} exited ${rc}" >&2
    exit "$rc"
  fi
done
echo; echo "PASS: ${PASS}/${#TESTS[@]} in $(( $(date +%s) - START ))s"
