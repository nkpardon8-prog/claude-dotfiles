#!/usr/bin/env bash
# run-all.sh — mission-bridge assumption tests (zero-loss contract).
# Runs every NN-*.sh sequentially, halts on first FAIL, maps a hang to
# INFRASTRUCTURE FAIL (exit 3), exits with the first failure's code.
#
# Pre-implementation gate:   bash run-all.sh   (must PASS before /implement)
# Post-implementation gate:  re-run after each ship; any FAIL = regression.
#
# 01-08 lock in the already-shipped mission-bridge contracts (all GREEN).
# 09-13 are the /mission codex-review FIX-PLAN proofs (tmp/ready-plans/2026-05-30-mission-fixes.md):
#   09 runs RED until the rebaseline-lifecycle fix lands — it IS the pre-implementation proof that
#      mission_rebaseline cannot reactivate a cleared mission today; run-all halts there until
#      /implement makes it GREEN. 10-13 are GREEN-now contract lock-ins.
set -uo pipefail

GATE="MISSION_BRIDGE_SMOKE_ALLOW_TMP"
# The suite is hermetic ($TMPDIR scratch only). run-all sets the gate for you so
# the pre-implementation gate is one command; individual tests still refuse
# without it (per the /script safety convention).
export "${GATE}=true"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS=(
  "01-log-append-atomicity.sh"
  "02-marker-and-zone-parse.sh"
  "03-lock-reclaim.sh"
  "04-mutate-atomicity.sh"
  "05-manifest-mission-path.sh"
  "06-primer-emit.sh"
  "07-append-after-torn-line.sh"
  "08-write-failure-surfaced.sh"
  "09-rebaseline-reactivates-latest.sh"
  "10-fail-idtag-attempt-scoped.sh"
  "11-write-status-parse.sh"
  "12-round-line-reroute-boundary.sh"
  "13-resume-window-survives-rotation.sh"
)

# macOS has no GNU `timeout`; use perl as a portable per-test watchdog (60s).
# Falls back to running without a watchdog if perl is unavailable.
run_one() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' 60 bash "$1"
  else
    bash "$1"
  fi
}

PASS=0; START=$(date +%s)
for t in "${TESTS[@]}"; do
  echo; echo "--- ${t} ---"
  if run_one "${SCRIPT_DIR}/${t}"; then
    PASS=$((PASS+1))
  else
    rc=$?
    # perl alarm kills with SIGALRM -> 142; GNU timeout -> 124. Either = hang.
    if [ "$rc" = 124 ] || [ "$rc" = 142 ]; then rc=3; fi
    echo "HALT: ${t} exited ${rc}" >&2
    exit "$rc"
  fi
done
echo; echo "PASS: ${PASS}/${#TESTS[@]} in $(( $(date +%s) - START ))s"
