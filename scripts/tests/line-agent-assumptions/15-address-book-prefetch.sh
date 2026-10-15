#!/usr/bin/env bash
# 15 - "Always synced": the background prefetch keeps a local copy; list/find read only that copy.
#
# A foreground read of an iCloud placeholder can take longer than any reasonable wait (live: "still
# downloading from iCloud (no answer in 2s)" on the MacBook for the mini's file). So the LaunchAgent's
# `publish` reads every other Mac's file fully in the background and updates the cache; `list`/`find`
# never touch iCloud when a cached copy exists.
#
# R1  publish copies another Mac's file into the local cache (content identical)
# R2  list shows it with "synced ... ago"
# R3  the other Mac changes its file: list keeps showing the CACHED copy until the next publish,
#     then shows the change - proof list reads the cache, not iCloud
# R4  an unchanged file is not rewritten into the cache (mtime identical)
# R5  live/asleep comes from the heartbeat INSIDE the file: a fresh sync of a 2-hour-old heartbeat
#     still reads "asleep/offline"
# R6  publish --no-prefetch (the background publish /line and the hook use) does not touch the cache
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): a copy whose publish never prefetches and whose
# reader reads iCloud directly every time. R1 and R3 must go red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_addrbook-fixture.sh"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  python3 - "$REAL_SCRIPT" "$SCRIPT" <<'PY'
import sys
s = open(sys.argv[1]).read()
for a, b in [("            prefetch_other_hosts(d, verbose)\n", "            pass\n"),
             ("        data = _read_cache(hid)\n        problem = str(st.get(\"problem\") or \"\")\n",
              "        data = None\n        problem = str(st.get(\"problem\") or \"\")\n")]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(sys.argv[2], "w").write(s)
PY
fi

CACHE="$ROOT/icloud/.claude-windows-cache"
CB="$CACHE/test-mac-b.json"
NOW=$(python3 -c 'import time;print(int(time.time()))')
WIN1='[{"address":"mini-billing-desk","caption":"billing desk on the mini","owns":"","session_id":"s-b1","cwd_label":"summit","started_at":"","can_receive":true,"named":true}]'
WIN2='[{"address":"late-addition","caption":"late addition","owns":"","session_id":"s-b2","cwd_label":"summit","started_at":"","can_receive":true,"named":true}]'
write_host test-mac-b "Test Mac B" "$NOW" "" "$WIN1"

# --- R1 -------------------------------------------------------------------------------------------
run_lac publish
if [ -f "$CB" ] && cmp -s <(python3 -m json.tool "$CB") <(python3 -m json.tool "$WIN_DIR/test-mac-b.json"); then :; else
  fail "R1: publish did not prefetch Test Mac B's file into the local cache"
fi

# --- R2 -------------------------------------------------------------------------------------------
run_lac list
case "$OUT" in *"On Test Mac B - live"*"synced "*" ago"*) ;; *) fail "R2: list does not show B as live with a synced note" ;; esac

# --- R4 (before changing anything) ----------------------------------------------------------------
M0=$(stat -f %m "$CB" 2>/dev/null); sleep 1.1
run_lac publish
[ "$(stat -f %m "$CB" 2>/dev/null)" = "$M0" ] || fail "R4: an unchanged file was rewritten into the cache"

# --- R3 -------------------------------------------------------------------------------------------
write_host test-mac-b "Test Mac B" "$NOW" "" "$WIN2"
run_lac list
case "$OUT" in *"late-addition"*) fail "R3: list read iCloud directly instead of the cache" ;; esac
case "$OUT" in *"mini-billing-desk"*) ;; *) fail "R3: list lost the cached window before the next sync" ;; esac
run_lac publish
run_lac list
case "$OUT" in *"late-addition"*) ;; *) fail "R3: the next publish did not bring the change into the cache" ;; esac

# --- R6 -------------------------------------------------------------------------------------------
write_host test-mac-b "Test Mac B" "$NOW" "" "$WIN1"
SHA6=$(shasum "$CB" | awk '{print $1}')
run_lac publish --no-prefetch
[ "$(shasum "$CB" | awk '{print $1}')" = "$SHA6" ] || fail "R6: publish --no-prefetch touched the cache"

# --- R5 -------------------------------------------------------------------------------------------
write_host test-mac-b "Test Mac B" "$((NOW - 7200))" "" "$WIN1"
run_lac publish
run_lac list
case "$OUT" in *"On Test Mac B - Mac asleep/offline, last seen"*) ;; *) fail "R5: a fresh sync of an old heartbeat did not read as asleep/offline" ;; esac

# --- verdict --------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in R1 R3; do case "$FAIL_MSGS" in *"${tag}:"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: without prefetch and with direct reads, R1 and R3 went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not go red:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 15-address-book-prefetch" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
echo "PASS: 15-address-book-prefetch - 6 assertions (prefetch into cache, synced note, list reads cache only, no rewrite when unchanged, heartbeat from file content, --no-prefetch leaves cache alone)"
exit 0
