#!/usr/bin/env bash
# 08 — write failure is DETECTED and SURFACED, never silently swallowed (NEW).
#
# THE central zero-loss invariant + the deliberate fail-LOUD exception to
# ctx-gate's fail-open posture. If an append/mutate/lock/backup fails (read-only
# dir, ENOSPC, permission), the implementation MUST return non-zero so the caller
# surfaces it — a swallowed failure means an entry the agent THINKS it recorded is
# gone, with no signal. The chain primitives are "observational, never block", so
# the mission writer must NOT inherit that silence.
#
# This test proves the underlying shell idioms actually RETURN FAILURE under a
# forced write failure (so the implementation CAN detect + surface it):
#   A1 — `printf ... >> "$f"` into a read-only dir returns non-zero.
#   A2 — `mkdir "$lock"` in a read-only dir returns non-zero (lock acquire fails
#        loudly rather than appearing to succeed).
#   A3 — `mktemp "$f.XXXXXX"` in a read-only dir returns non-zero (the mutate
#        path's atomic-write setup fails detectably, so the original is untouched).
#   A4 — a function that checks `>>`'s rc and returns it propagates the failure
#        (the surfacing contract), and the ORIGINAL file is unchanged.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "08-write-failure-surfaced"

# A read-only directory is the cheap, deterministic way to force write failure
# (no hdiutil/ENOSPC needed). Created under our scratch dir; cleaned by trap.
RO="$ATEST_DIR/readonly"
mkdir -p "$RO"
# pre-seed a file we expect to remain UNCHANGED after failed writes.
# Two distinct denial mechanisms, because they gate different operations:
#   - read-only FILE (chmod 444) denies appending to existing content (A1/A4)
#   - read-only DIR  (chmod 555) denies creating new entries: lock/mktemp (A2/A3)
SEED="$RO/MISSION.test.log"
printf 'rec:000\tpre-existing entry\n' > "$SEED"
seed_sum="$(shasum "$SEED" | cut -d' ' -f1)"
chmod 444 "$SEED" || atest_infra "cannot chmod seed file read-only"
chmod 555 "$RO"   || atest_infra "cannot chmod scratch dir read-only"

# Guard: if running as root, read-only dirs are bypassable -> can't force failure.
if [ "$(id -u 2>/dev/null)" = "0" ]; then
  chmod 755 "$RO" 2>/dev/null
  atest_infra "running as root — read-only dir does not deny writes; cannot test write-failure surfacing"
fi

# --- A1: append into read-only dir returns non-zero --------------------------
( printf '%s\n' "rec:001	new entry" >> "$SEED" ) 2>/dev/null
_rc=$?
[ "$_rc" != "0" ]
atest_assert "A1" "$?" "append into a read-only dir returned rc=0 — a failed write would look successful (silent loss)."

# --- A2: lock mkdir in read-only dir returns non-zero ------------------------
mkdir "$RO/.claude-mission-test.lock" 2>/dev/null
_rc=$?
[ "$_rc" != "0" ]
atest_assert "A2" "$?" "mkdir-lock in a read-only dir returned rc=0 — lock acquire would falsely appear to succeed."

# --- A3: mktemp in read-only dir returns non-zero ----------------------------
_tmp="$(mktemp "$SEED.tmp.XXXXXX" 2>/dev/null)"; _rc=$?
[ "$_rc" != "0" ] || [ -z "$_tmp" ]
atest_assert "A3" "$?" "mktemp in a read-only dir succeeded (rc=$_rc tmp='$_tmp') — the atomic-write setup would not fail loudly."

# --- A4: surfacing contract — wrapper propagates rc + original untouched -----
guarded_append() { # mirrors what mission_log_append MUST do
  if printf '%s\n' "$2" >> "$1" 2>/dev/null; then return 0; fi
  echo "mission-log: append FAILED for $1 (write error)" >&2   # LOUD
  return 7
}
guarded_append "$SEED" "rec:002	should fail" 2>/dev/null
_rc=$?
now_sum="$(shasum "$SEED" | cut -d' ' -f1)"
[ "$_rc" = "7" ] && [ "$now_sum" = "$seed_sum" ]
atest_assert "A4" "$?" "guarded append did not surface failure (rc=$_rc, want 7) or mutated the original (sum $seed_sum -> $now_sum) — fail-LOUD contract violated."

# restore perms so cleanup can remove the dir
chmod 755 "$RO" 2>/dev/null || true

atest_report
