#!/usr/bin/env bash
# 21 - a stalled iCloud Drive never wedges `publish`, and publishes never pile up behind a stuck one.
#
# 2026-11-11, Nick's Mac mini: one publish hung for hours in the kernel on chmod of the iCloud
# folder while holding the publish lock; every later publish (one a minute) blocked on that lock,
# 111 processes piled up, the Mac's heartbeat froze at 19:00 and the MacBook marked it offline.
#
# S1  a publish whose iCloud write stalls returns within the iCloud deadline (not the stall time)
# S2  ...and still refreshed the LOCAL cache, which is what the ssh relay hands the other Mac
# S3  ...and the stall is recorded as a publish error (loud, not silent)
# S4  a publish that cannot get the lock (holder stuck) gives up within the lock wait and logs it
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): a copy whose iCloud write is unbounded and whose
# lock wait is the old blocking flock. S1 and S4 must go red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_addrbook-fixture.sh"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  python3 - "$REAL_SCRIPT" "$SCRIPT" <<'PY'
import sys
s = open(sys.argv[1]).read()
for a, b in [
    ('        _icloud_bounded(put, "writing this Mac\'s entry")', '        put()'),
    ('        with file_lock_timed(cache_dir() / "publish", PUBLISH_LOCK_WAIT_SEC) as held:',
     '        with file_lock_timed(cache_dir() / "publish", 10**6) as held:'),
]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(sys.argv[2], "w").write(s)
PY
  [ -s "$SCRIPT" ] || { echo "INFRA: neg-control patch failed - anchors moved" >&2; exit 3; }
fi

CACHE_FILE="$CACHE_DIR_EXPECTED/test-mac-a.json"
LOG_FILE="$(HOME="$FAKE_HOME" LAC_WINDOWS_DIR="$WIN_DIR" python3 "$SCRIPT" address-book-paths 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["publish_log"])')"

# --- S1-S3: stalled iCloud write ------------------------------------------------------------------
rm -f "$CACHE_FILE"
export LAC_TEST_ICLOUD_STALL=8 LAC_ICLOUD_OP_TIMEOUT=2 LAC_ALARM=20
run_lac publish -v
unset LAC_TEST_ICLOUD_STALL LAC_ICLOUD_OP_TIMEOUT
python3 -c "import sys;sys.exit(0 if float('$ELAPSED') < 6 else 1)" \
  || fail "S1: a stalled iCloud write held publish for ${ELAPSED}s (deadline 2s)"
[ -s "$CACHE_FILE" ] || fail "S2: the local cache was not refreshed while iCloud was stalled"
printf '%s' "$OUT" | grep -q "FAILED (TimeoutError)" \
  || fail "S3: the stall was not reported as a publish failure ($OUT)"

# --- S4: lock held by a stuck publish -------------------------------------------------------------
LOCK="$CACHE_DIR_EXPECTED/publish.lock"
mkdir -p "$CACHE_DIR_EXPECTED"
python3 - "$LOCK" <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[1], "a+"); fcntl.flock(fh.fileno(), fcntl.LOCK_EX); time.sleep(15)
PY
HOLDER=$!
sleep 1
export LAC_PUBLISH_LOCK_WAIT=2 LAC_ALARM=12
run_lac publish
unset LAC_PUBLISH_LOCK_WAIT
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
python3 -c "import sys;sys.exit(0 if float('$ELAPSED') < 6 else 1)" \
  || fail "S4: publish waited ${ELAPSED}s on a stuck lock holder (wait 2s) - publishes would pile up"
grep -q "publish skipped: another publish held the lock" "$LOG_FILE" 2>/dev/null \
  || fail "S4: giving up on the lock was not logged"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in S1 S4; do case "$FAIL_MSGS" in *"${tag}:"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: against an unbounded publisher, S1/S4 went RED (${FAIL_N} failed)"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not go red:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 21-address-book-stall" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
echo "PASS: 21-address-book-stall - 4 assertions (S1 stalled iCloud bounded, S2 cache still fresh, S3 stall reported, S4 stuck lock not piled on)"
exit 0
