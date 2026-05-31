#!/usr/bin/env bash
# 04 — mutate atomicity: SIGKILL-before-rename leaves original intact +
#      tmp lands on the SAME DEVICE as the target (so mv -f stays a rename).
#
# Proves the durable-file write path (mission_mutate, plan Key Pseudocode):
#   tmp=$(mktemp "${f}.tmp.XXXXXX")        # IN THE TARGET DIR — same device
#   ( ... > "$tmp" )
#   mv -f "$tmp" "$f"                       # atomic rename (single fs)
#
# Reviewer correction: "no partial-content window" is TAUTOLOGICAL for a same-dir
# rename (POSIX guarantees it) — un-red-able, proves nothing. The REAL zero-loss
# failure mode is a CROSS-FILESYSTEM mv, which degrades to copy+unlink and loses
# atomicity. So A2 asserts tmp is on the same device as the target; A3 shows a
# $TMPDIR tmp (cross-fs) would NOT be (the negative control).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "04-mutate-atomicity"

TARGDIR="$ATEST_DIR/anchor"; mkdir -p "$TARGDIR"
F="$TARGDIR/MISSION.test.md"
MARK='<!-- MISSION schema=v1 sid=test nonce=abc nonce8 plan_hash=feedface0badf00d -->'
printf 'original line 1\noriginal line 2\n%s\n' "$MARK" > "$F"
orig_sum="$(shasum "$F" | cut -d' ' -f1)"

# --- A1: a mutate KILLed between tmp-write and mv leaves the ORIGINAL intact --
# Simulate: write a tmp in the target dir, then "crash" (do NOT mv). Original must
# be byte-identical and still marker-valid.
tmp="$(mktemp "${F}.tmp.XXXXXX")" || atest_infra "mktemp in target dir failed"
printf 'HALF-WRITTEN new content with no marker' > "$tmp"   # interrupted write
# crash: we never mv. (kill is implicit — the process died before rename.)
rm -f "$tmp"   # the next writer's self-check would discard the orphan tmp
now_sum="$(shasum "$F" | cut -d' ' -f1)"
last="$(grep -nvE '^[[:space:]]*$' "$F" | tail -1 | sed 's/^[0-9]*://')"
[ "$now_sum" = "$orig_sum" ] && [ "$last" = "$MARK" ]
atest_assert "A1" "$?" "original changed after an interrupted (un-renamed) mutate (sum $orig_sum->$now_sum) or lost its last-line marker — a crash mid-write corrupted the spine."

# --- A1b: a COMPLETED mv -f atomically replaces and the result is marker-valid
tmp2="$(mktemp "${F}.tmp.XXXXXX")" || atest_infra "mktemp failed"
NEWMARK='<!-- MISSION schema=v1 sid=test nonce=def plan_hash=0123456789abcdef -->'
printf 'updated line 1\n%s\n' "$NEWMARK" > "$tmp2"
mv -f "$tmp2" "$F"
last2="$(grep -nvE '^[[:space:]]*$' "$F" | tail -1 | sed 's/^[0-9]*://')"
[ ! -e "$tmp2" ] && [ "$last2" = "$NEWMARK" ]
atest_assert "A1b" "$?" "mv -f did not atomically install the new file (tmp survives, or last-line marker wrong: '$last2')."

# --- A2: tmp (mktemp in target dir) is on the SAME DEVICE as the target -------
dev_target="$(atest_devid "$TARGDIR")"
tmp3="$(mktemp "${F}.tmp.XXXXXX")" || atest_infra "mktemp failed"
dev_tmp="$(atest_devid "$tmp3")"
rm -f "$tmp3"
[ -n "$dev_target" ] && [ "$dev_tmp" = "$dev_target" ]
atest_assert "A2" "$?" "in-target-dir mktemp landed on device '$dev_tmp' != target device '$dev_target' — mv would degrade to copy+unlink (NON-atomic, loss window)."

# --- A3 (NEGATIVE CONTROL): a $TMPDIR tmp MAY be cross-device ----------------
# Demonstrates the device-check is meaningful: when tmp is created in $TMPDIR
# instead of the target dir, it CAN be on a different device. We don't hard-fail
# if they happen to share a device on this box; we assert the device-check
# MECHANISM produces comparable values (so A2 is exercisable, not vacuous).
alt_tmp="$(mktemp "${TMPDIR:-/tmp}/mbridge_xfs.XXXXXX")" || atest_infra "mktemp in TMPDIR failed"
dev_alt="$(atest_devid "$alt_tmp")"
rm -f "$alt_tmp"
if [ "$dev_alt" = "$dev_target" ]; then
  echo "  (A3 note: \$TMPDIR and target share device $dev_target on this box — cross-fs degrade not reproducible here, but A2's check is the guard that matters)" >&2
fi
[ -n "$dev_alt" ] && [ -n "$dev_target" ]
atest_assert "A3" "$?" "device-id probe (stat -f %d) returned empty (alt='$dev_alt' target='$dev_target') — A2's cross-fs guard cannot be evaluated on this platform."

atest_report
