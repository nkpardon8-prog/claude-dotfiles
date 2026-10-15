#!/usr/bin/env bash
# 13 - Another Mac's file that cannot be read right now must never hang `list`, `find` or `publish`.
#
# In iCloud Drive a file can be a placeholder whose content is still in the cloud; opening it can
# block until the download finishes. `list`/`find` read only the local cache the background
# prefetch keeps, and read iCloud directly (short timeout) only for a Mac with no cached copy yet.
# A FIFO with no writer stands in for a placeholder because opening one blocks forever.
#
# X1  cached Mac whose file is now a FIFO: `list` shows the cached windows, no hang
# X2  `find` in the same state finds the cached window
# X3  a never-cached Mac whose file is a FIFO: reported unreadable within the alarm
# X4  a never-cached Mac with only an iCloud stub (.<host>.json.icloud): "not downloaded from iCloud yet"
# X5  the prefetch (`publish`) over a FIFO gives up at its timeout, keeps the cached copy, and the
#     problem shows up as "may be out of date" once the cache ages
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): a copy that reads the file directly (no child
# process, no timeout). X3 and X5 must go red - as hangs caught by the alarm.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAC_ALARM=20   # a real hang is forever; 20s only keeps a loaded machine from reading as one
. "$HERE/_addrbook-fixture.sh"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  python3 - "$REAL_SCRIPT" "$SCRIPT" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = "    if timeout is None:\n        try:\n            timeout = float(os.environ.get(\"LAC_REMOTE_READ_TIMEOUT\")"
assert s.count(a) == 1
s = s.replace(a, "    if path.exists():\n        return json.loads(path.read_text()), \"\"\n" + a)
open(sys.argv[2], "w").write(s)
PY
fi

NOW=$(python3 -c 'import time;print(int(time.time()))')
write_host test-mac-b "Test Mac B" "$NOW" "" \
  '[{"address":"mini-billing-desk","caption":"billing desk on the mini","owns":"","session_id":"s-b1","cwd_label":"summit","started_at":"","can_receive":true,"named":true}]'
run_lac publish   # prefetch seeds the cache with a good copy
CACHED="$ROOT/icloud/.claude-windows-cache/test-mac-b.json"
[ -f "$CACHED" ] || { echo "INFRA: the priming prefetch did not cache Test Mac B: $OUT" >&2; exit 3; }
CACHED_SHA=$(shasum "$CACHED" | awk '{print $1}')

B="$WIN_DIR/test-mac-b.json"
rm -f "$B"; mkfifo "$B"

# --- X1 -------------------------------------------------------------------------------------------
run_lac list
if [ "$RC" = 142 ]; then fail "X1: list HUNG with a cached Mac whose file is a placeholder"
else case "$OUT" in *"mini-billing-desk"*) ;; *) fail "X1: the cached window was not shown" ;; esac; fi

# --- X2 -------------------------------------------------------------------------------------------
run_lac find "billing desk"
if [ "$RC" = 142 ]; then fail "X2: find HUNG"
else case "$OUT" in *"SendMessage to: mini-billing-desk"*) ;; *) fail "X2: find lost the cached window" ;; esac; fi

# --- X3 -------------------------------------------------------------------------------------------
mkfifo "$WIN_DIR/test-mac-d.json"
run_lac list
if [ "$RC" = 142 ]; then fail "X3: list HUNG on a never-cached Mac's placeholder"
else case "$OUT" in *"On test-mac-d"*"could not read its address book"*) ;; *) fail "X3: an uncached unreadable Mac was not reported" ;; esac; fi
rm -f "$WIN_DIR/test-mac-d.json"

# --- X4 -------------------------------------------------------------------------------------------
: > "$WIN_DIR/.test-mac-e.json.icloud"
run_lac list
case "$OUT" in *"On test-mac-e"*"not downloaded from iCloud yet"*) ;; *) fail "X4: an iCloud stub was not reported as not downloaded yet" ;; esac
rm -f "$WIN_DIR/.test-mac-e.json.icloud"

# --- X5 -------------------------------------------------------------------------------------------
LAC_PREFETCH_TIMEOUT=1 run_lac publish
if [ "$RC" = 142 ]; then
  fail "X5: publish HUNG prefetching a placeholder"
else
  [ "$(shasum "$CACHED" | awk '{print $1}')" = "$CACHED_SHA" ] || fail "X5: a failed prefetch changed the cached copy"
  export LAC_NOW=$((NOW + 600)); run_lac list; unset LAC_NOW
  case "$OUT" in *"On Test Mac B"*"may be out of date"*) ;; *) fail "X5: an aged cache was not flagged as possibly out of date" ;; esac
fi

# --- verdict --------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in X3 X5; do case "$FAIL_MSGS" in *"${tag}: "*"HUNG"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: reading the file directly hangs, and X3/X5 caught it (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not report a hang:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 13-address-book-placeholder" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
echo "PASS: 13-address-book-placeholder - 5 assertions (cached Mac behind a placeholder, find, uncached placeholder, iCloud stub, prefetch timeout keeps the cache - never a hang)"
exit 0
