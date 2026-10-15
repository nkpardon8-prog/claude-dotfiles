#!/usr/bin/env bash
# 12 - `list` and `find` show the windows on the owner's OTHER Macs, read from the shared folder.
#
# Before this, both read only this Mac's disk, so a window on the other Mac was invisible to them
# even though Remote Control could message it. Two fake Macs are planted beside this one: B is awake
# and signed in to the same account; C went quiet two hours ago and is signed in to another account.
#
# M1  list shows "On Test Mac B - live" with B's window
# M2  list shows C as "Mac asleep/offline, last seen ..." with its window marked offline
# M3  the different-account warning is printed for C, and NOT for B
# M4  find ranks B's window (same scoring as local) and says SendMessage to it, labelled with B
# M5  list --json carries otherMacs with a host field on each window, and accountMismatch=true
# M6  this Mac's own file is never shown as another Mac
# M7  once C reports the same account, the warning is gone
# M8  find on the sleeping Mac's window says it looks asleep/offline
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): a copy whose reader skips every other Mac and
# never compares accounts. M1, M3 and M4 must go red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_addrbook-fixture.sh"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  python3 - "$REAL_SCRIPT" "$SCRIPT" <<'PY'
import sys
s = open(sys.argv[1]).read()
for a, b in [
    ("    return sorted(h for h in hids if h != mine and HOST_ID_RE.match(h))", "    return []"),
    ("        match = None if not (my_hash and their_hash) else (my_hash == their_hash)", "        match = None"),
]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(sys.argv[2], "w").write(s)
PY
fi

NOW=$(python3 -c 'import time;print(int(time.time()))')
run_lac publish
[ -f "$WIN_DIR/test-mac-a.json" ] || { echo "INFRA: fixture publish wrote nothing: $OUT" >&2; exit 3; }
SAME=$(our_hash)
OTHER=$(printf 'some-other-account' | shasum -a 256 | awk '{print $1}')

write_host test-mac-b "Test Mac B" "$NOW" "$SAME" \
  '[{"address":"mini-billing-desk","caption":"billing desk on the mini","label":"billing desk on the mini","owns":"Stripe invoices","session_id":"s-b1","cwd_label":"summit","started_at":"","can_receive":true,"named":true}]'
write_host test-mac-c "Test Mac C" "$((NOW - 7200))" "$OTHER" \
  '[{"address":"old-reports","caption":"old reports","label":"old reports","owns":"","session_id":"s-c1","cwd_label":"reports","started_at":"","can_receive":true,"named":true}]'
run_lac publish   # the background prefetch: copies B and C into this Mac's local cache

# --- M1 / M2 / M3 / M6 ----------------------------------------------------------------------------
run_lac list
case "$OUT" in *"On Test Mac B - live"*) ;; *) fail "M1: no live section for Test Mac B" ;; esac
case "$OUT" in *"mini-billing-desk"*) ;; *) fail "M1: Test Mac B's window is not listed" ;; esac
case "$OUT" in *"On Test Mac C - Mac asleep/offline, last seen"*) ;; *) fail "M2: Test Mac C not reported asleep/offline" ;; esac
printf '%s\n' "$OUT" | grep -q "old-reports.*offline" || fail "M2: C's window is not marked offline"
[ "$(printf '%s\n' "$OUT" | grep -c "Test Mac C is signed in to a DIFFERENT claude.ai account")" = "1" ] \
  || fail "M3: the different-account warning for C is missing (or repeated)"
printf '%s\n' "$OUT" | grep -q "Test Mac B is signed in to a DIFFERENT" && fail "M3: warned about B, which shares the account"
case "$OUT" in *"On Test Mac A"*) fail "M6: this Mac's own file was listed as another Mac" ;; esac

# --- M4 -------------------------------------------------------------------------------------------
run_lac find "billing desk"
case "$OUT" in *"SendMessage to: mini-billing-desk"*) ;; *) fail "M4: find did not pick B's window: $(printf '%s' "$OUT" | head -3)" ;; esac
case "$OUT" in *"[Test Mac B]"*) ;; *) fail "M4: the match is not labelled with its Mac" ;; esac

# --- M5 -------------------------------------------------------------------------------------------
run_lac list --json
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
hosts = {h["host"]: h for h in d.get("otherMacs", [])}
assert set(hosts) == {"test-mac-b", "test-mac-c"}, sorted(hosts)
assert hosts["test-mac-b"]["windows"][0]["host"] == "test-mac-b"
assert hosts["test-mac-b"]["live"] is True and hosts["test-mac-c"]["live"] is False
assert d.get("accountMismatch") is True
' 2>/dev/null || fail "M5: list --json does not carry the other Macs correctly"

# --- M8 -------------------------------------------------------------------------------------------
run_lac find "old reports"
case "$OUT" in *"SendMessage to: old-reports"*"asleep/offline"*) ;; *) fail "M8: find did not flag the sleeping Mac" ;; esac

# --- M7 -------------------------------------------------------------------------------------------
write_host test-mac-c "Test Mac C" "$((NOW - 7200))" "$SAME" '[]'
run_lac publish
run_lac list
case "$OUT" in *"DIFFERENT claude.ai account"*) fail "M7: warning still printed after the accounts match" ;; esac

# --- verdict --------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in M1 M3 M4; do case "$FAIL_MSGS" in *"${tag}:"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: with the other-Mac reader disabled, M1/M3/M4 all went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not go red:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 12-address-book-merge" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
echo "PASS: 12-address-book-merge - 8 assertions (live + asleep sections, account warning only on mismatch, find ranks other Macs, --json host field, own file not shown)"
exit 0
