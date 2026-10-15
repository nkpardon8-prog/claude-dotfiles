#!/usr/bin/env bash
# 13 - Another Mac's file that cannot be read right now must never hang `list` or `find`.
#
# In iCloud Drive a file can be a placeholder whose content is still in the cloud; opening it can
# block until the download finishes, and `list` runs from hooks and agents that cannot wait. A FIFO
# with no writer is used as the stand-in because opening one blocks forever - the worst case.
#
# X1  remote file is a never-answering FIFO: `list` returns within the alarm, shows the CACHED copy
#     of that Mac's windows, and says "may be out of date"
# X2  `find` in the same state also returns, and still finds the cached window
# X3  only an iCloud stub (.<host>.json.icloud) exists: cached copy + "not downloaded from iCloud yet"
# X4  remote file unreadable (mode 000): cached copy, no crash
# X5  a Mac never seen before, whose file is a FIFO and has no cache: reported unreadable, no hang
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): a copy that reads the remote file directly
# (no child process, no timeout). X1 must go red - as a hang caught by the alarm.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAC_ALARM=8
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
run_lac publish
write_host test-mac-b "Test Mac B" "$NOW" "$(our_hash)" \
  '[{"address":"mini-billing-desk","caption":"billing desk on the mini","owns":"","session_id":"s-b1","cwd_label":"summit","started_at":"","can_receive":true,"named":true}]'
run_lac list   # prime the cache with a good copy
case "$OUT" in *"mini-billing-desk"*) ;; *) echo "INFRA: priming list did not see Test Mac B: $OUT" >&2; exit 3 ;; esac

B="$WIN_DIR/test-mac-b.json"

# --- X1 -------------------------------------------------------------------------------------------
rm -f "$B"; mkfifo "$B"
run_lac list
if [ "$RC" = 142 ]; then
  fail "X1: list HUNG on a placeholder file (killed by the ${LAC_ALARM}s alarm)"
else
  case "$OUT" in *"mini-billing-desk"*) ;; *) fail "X1: the cached window was not shown" ;; esac
  case "$OUT" in *"may be out of date"*) ;; *) fail "X1: did not say the list may be out of date" ;; esac
fi

# --- X2 -------------------------------------------------------------------------------------------
run_lac find "billing desk"
if [ "$RC" = 142 ]; then fail "X2: find HUNG on a placeholder file"
else case "$OUT" in *"SendMessage to: mini-billing-desk"*) ;; *) fail "X2: find lost the cached window" ;; esac; fi

# --- X3 -------------------------------------------------------------------------------------------
rm -f "$B"; : > "$WIN_DIR/.test-mac-b.json.icloud"
run_lac list
case "$OUT" in *"not downloaded from iCloud yet"*"may be out of date"*) ;; *) fail "X3: an iCloud stub did not fall back to the cache with a note" ;; esac
case "$OUT" in *"mini-billing-desk"*) ;; *) fail "X3: the cached window was not shown" ;; esac
rm -f "$WIN_DIR/.test-mac-b.json.icloud"

# --- X4 -------------------------------------------------------------------------------------------
printf '{}' > "$B"; chmod 000 "$B"
run_lac list
[ "$RC" = 0 ] || fail "X4: list exited $RC on an unreadable file"
case "$OUT" in *"mini-billing-desk"*"may be out of date"*|*"may be out of date"*"mini-billing-desk"*) ;; *) fail "X4: unreadable file did not fall back to the cache" ;; esac
chmod 600 "$B"

# --- X5 -------------------------------------------------------------------------------------------
mkfifo "$WIN_DIR/test-mac-d.json"
run_lac list
if [ "$RC" = 142 ]; then fail "X5: list HUNG on a never-seen Mac's placeholder"
else case "$OUT" in *"On test-mac-d"*"could not read its address book"*) ;; *) fail "X5: an uncached unreadable Mac was not reported" ;; esac; fi

# --- verdict --------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  case "$FAIL_MSGS" in
    *"X1: list HUNG"*)
      echo "NEG-CONTROL OK: reading the file directly hangs, and X1 caught it (${FAIL_N} failed)"
      printf '%s' "$FAIL_MSGS"; exit 0 ;;
  esac
  echo "NEG-CONTROL BROKEN: X1 did not report a hang" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 13-address-book-placeholder" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
echo "PASS: 13-address-book-placeholder - 5 assertions (FIFO placeholder, find, iCloud stub, unreadable file, uncached Mac - never a hang, cached fallback says out of date)"
exit 0
