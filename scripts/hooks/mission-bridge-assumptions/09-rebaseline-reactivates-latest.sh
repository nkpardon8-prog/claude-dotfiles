#!/usr/bin/env bash
# 09 — rebaseline REACTIVATES a cleared mission via the latest [mission] lifecycle line.
# Fix-plan CRITICAL #1. Calls the REAL mission_rebaseline against a hermetic scratch mission.
#
# Load-bearing contract (mission.md active-iff rule + post-compact-resume reactivation,
# mission.md:286-287): the mission is "active" iff the LATEST `[mission]` lifecycle line in
# the LOG is NOT MISSION-CLEARED. So after a clear, mission_rebaseline MUST append a NEWER
# `[mission]` lifecycle line — otherwise a cleared-then-rebaselined mission stays dead forever
# (adopt-mode (c) + explicit-build reactivation both depend on this).
#
# NEGATIVE CONTROL (controllable precondition — the assertion IS its own red/green):
#   RED  against current code: mission_rebaseline (lib:921) logs a PLAIN ledger line
#        "PLAN rebaselined (hash re-stamped)" with idtag rebaseline-<hash> and NO `[mission]`
#        token, so the latest `[mission]` line stays MISSION-CLEARED → A1 FAILS.
#   GREEN after the fix: rebaseline emits a `[mission]` reactivation lifecycle line → A1 PASSES.
# (Do NOT assert an invented `status=active` literal — the load-bearing property is
#  "latest lifecycle line is not a clear", robust to the exact token wording the fix chooses.)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "09-rebaseline-reactivates-latest"

. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh" 2>/dev/null \
  || atest_infra "cannot source mission-bridge.sh"

SID="atest09"
ROOT="$ATEST_DIR/anchor"; mkdir -p "$ROOT"
LOG="$ROOT/MISSION.${SID}.log"

mission_create "$SID" "$ROOT" "MISSION MODE: build — original plan" >/dev/null 2>&1 \
  || atest_infra "mission_create failed"
# Clear it: the latest [mission] lifecycle line becomes MISSION-CLEARED (state = dead).
mission_log_append "$SID" "$ROOT" "[mission] MISSION-CLEARED reason=test-done" "m-clear" >/dev/null 2>&1 \
  || atest_infra "log clear append failed"

# setup sanity — before rebaseline the latest [mission] line IS the clear.
pre_latest=$(grep '\[mission\] ' "$LOG" 2>/dev/null | tail -1)
case "$pre_latest" in
  *MISSION-CLEARED*) : ;;
  *) atest_infra "setup: expected MISSION-CLEARED as latest lifecycle line, got: '$pre_latest'" ;;
esac

# THE FIX UNDER TEST: rebaseline must reactivate the cleared mission.
mission_rebaseline "$SID" "$ROOT" "MISSION MODE: build — rebaselined plan" >/dev/null 2>&1 \
  || atest_infra "mission_rebaseline returned nonzero"

# --- A1: the LATEST [mission] lifecycle line is no longer MISSION-CLEARED -----------
post_latest=$(grep '\[mission\] ' "$LOG" 2>/dev/null | tail -1)
case "$post_latest" in
  *MISSION-CLEARED*|"") _a1=1 ;;   # still dead (clear is latest, or no lifecycle line) → RED
  *)                    _a1=0 ;;   # a newer lifecycle line reactivated it → GREEN
esac
atest_assert "A1" "$_a1" "after rebaseline the latest [mission] lifecycle line is still a clear (or none): '${post_latest}' — mission_rebaseline emits no reactivating [mission] lifecycle line (lib:921), so a cleared mission can NEVER reactivate (adopt (c) / explicit-build stuck dead)."

# --- A2: rebaseline appended a NEW [mission] lifecycle line after the clear ---------
# Setup wrote exactly ONE [mission] line (the clear). A reactivating rebaseline adds >=1 more.
nlc=$(grep -c '\[mission\] ' "$LOG" 2>/dev/null | tr -d ' ')
[ -n "$nlc" ] && [ "$nlc" -ge 2 ]
atest_assert "A2" "$?" "rebaseline did not append a new [mission] lifecycle line (count=${nlc:-0}, expected >=2) — the active-iff rule has nothing to key reactivation on."

atest_report
