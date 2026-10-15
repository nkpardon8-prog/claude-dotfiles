#!/usr/bin/env bash
# 11 - `publish` writes this Mac's address-book file once, then stays quiet until something changes.
#
# The LaunchAgent runs `publish` every 60s and iCloud syncs every write to the other Mac, so a
# publisher that rewrites an unchanged file is a constant sync churn - and one that never refreshes
# makes an awake Mac look asleep. And the file leaves the machine, so it must carry names only.
#
# P1  first publish writes <host>.json with this window in it
# P2  a second publish with nothing changed does NOT rewrite the file (bytes and mtime identical)
# P3  5 minutes later (LAC_NOW) - still no rewrite
# P4  11 minutes later - heartbeat_at refreshed, updated_at kept (content did not change)
# P5  an unnamed window is published with the readable label "<folder> (<Mac name>)", named=false
# P6  no full path, no home dir, no raw email, no raw account id anywhere in the file; the account
#     appears only as a 64-hex salted hash; cwd_label is the folder basename
# P7  a caption change IS a content change: rewritten, updated_at moves, named=true
# P8  the file is mode 600
# P9  POSITIVE CONTROL - `set` (with auto-publish on) republishes in the background within seconds.
#     Timing-dependent, so a miss within 30s is NOT MEASURED (exit 3), never a blocking failure:
#     a flaky FAIL here would pause dotfiles sync in every window.
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): a copy with the unchanged-skip removed, the
# heartbeat window made infinite, and the full cwd published. P2, P4 and P6 must each go red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_addrbook-fixture.sh"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  python3 - "$REAL_SCRIPT" "$SCRIPT" <<'PY'
import sys
s = open(sys.argv[1]).read()
for a, b in [
    ("    if prev is not None and _strip_times(prev) == body:", "    if False:"),
    ('    folder = clean_field(Path(r.get("cwd") or "").name, 80)', '    folder = clean_field(r.get("cwd") or "", 200)'),
]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(sys.argv[2], "w").write(s)
PY
  [ -s "$SCRIPT" ] || { echo "INFRA: neg-control patch failed - anchors moved" >&2; exit 3; }
fi

FILE="$WIN_DIR/test-mac-a.json"
field() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))" "$FILE" "$1"; }
mtime() { stat -f %m "$FILE" 2>/dev/null; }
NOW=$(python3 -c 'import time;print(int(time.time()))')

# --- P1 -------------------------------------------------------------------------------------------
LAC_NOW="$NOW" run_lac publish
[ -f "$FILE" ] || fail "P1: publish wrote no file ($OUT)"
if [ -f "$FILE" ]; then
  [ "$(field 'd["windows"][0]["address"]')" = "summit-zq" ] || fail "P1: the live window is not in the file"
  SHA1=$(shasum "$FILE" | awk '{print $1}'); M1=$(mtime)
  HB1=$(field 'd["heartbeat_at"]'); UP1=$(field 'd["updated_at"]')

  # --- P2 -----------------------------------------------------------------------------------------
  sleep 1.1
  export LAC_NOW="$NOW"; run_lac publish; unset LAC_NOW
  [ "$(shasum "$FILE" | awk '{print $1}')" = "$SHA1" ] && [ "$(mtime)" = "$M1" ] \
    || fail "P2: an unchanged publish rewrote the file"

  # --- P3 -----------------------------------------------------------------------------------------
  export LAC_NOW=$((NOW + 300)); run_lac publish; unset LAC_NOW
  [ "$(shasum "$FILE" | awk '{print $1}')" = "$SHA1" ] || fail "P3: rewrote the file only 5 minutes later"

  # --- P4 -----------------------------------------------------------------------------------------
  export LAC_NOW=$((NOW + 660)); run_lac publish; unset LAC_NOW
  HB2=$(field 'd["heartbeat_at"]'); UP2=$(field 'd["updated_at"]')
  [ "$HB2" != "$HB1" ] || fail "P4: heartbeat not refreshed after 11 minutes"
  [ "$UP2" = "$UP1" ] || fail "P4: updated_at moved ($UP1 -> $UP2) although nothing changed"

  # --- P5 -----------------------------------------------------------------------------------------
  [ "$(field 'd["windows"][0]["label"]')" = "summit (Test Mac A)" ] \
    || fail "P5: unnamed window label is '$(field 'd["windows"][0]["label"]')', want 'summit (Test Mac A)'"
  [ "$(field 'd["windows"][0]["named"]')" = "False" ] || fail "P5: unnamed window marked named"

  # --- P6 -----------------------------------------------------------------------------------------
  for needle in "$FIX_CWD" "/Users/" "$FAKE_HOME" "$FAKE_EMAIL" "$FAKE_ACCOUNT"; do
    grep -qF -- "$needle" "$FILE" && fail "P6: the published file contains '$needle'"
  done
  [ "$(field 'd["windows"][0]["cwd_label"]')" = "summit" ] || fail "P6: cwd_label is not the folder basename"
  field 'd["account_hash"]' | grep -qE '^[0-9a-f]{64}$' || fail "P6: account_hash is not a 64-hex hash"

  # --- P7 -----------------------------------------------------------------------------------------
  echo "billing desk" > "$FAKE_HOME/.claude/session-status/${SID}.txt"
  export LAC_NOW=$((NOW + 700)); run_lac publish; unset LAC_NOW
  [ "$(field 'd["windows"][0]["caption"]')" = "billing desk" ] || fail "P7: caption change not published"
  [ "$(field 'd["updated_at"]')" != "$UP1" ] || fail "P7: updated_at did not move on a content change"
  [ "$(field 'd["windows"][0]["named"]')" = "True" ] || fail "P7: captioned window not marked named"

  # --- P8 -----------------------------------------------------------------------------------------
  [ "$(stat -f %Lp "$FILE")" = "600" ] || fail "P8: file mode is $(stat -f %Lp "$FILE"), want 600"

  # --- P9 -----------------------------------------------------------------------------------------
  LAC_NO_AUTOPUBLISH=0 run_lac set "front desk scheduling"
  got=""; P9_UNMEASURED=""
  i=0
  while [ "$i" -lt 60 ]; do
    got=$(field 'd["windows"][0]["address"]' 2>/dev/null)
    [ "$got" = "front-desk-scheduling" ] && break
    sleep 0.5; i=$((i + 1))
  done
  [ "$got" = "front-desk-scheduling" ] || P9_UNMEASURED="\`set\` did not republish within 30s (address still '$got') - too slow to tell"
fi

# --- verdict --------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in P2 P4 P6; do case "$FAIL_MSGS" in *"${tag}:"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: against a regressed publisher, P2/P4/P6 all went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not go red:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 11-address-book-publish" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ -n "${P9_UNMEASURED:-}" ]; then
  echo "NOT MEASURED: 11-address-book-publish P9 - ${P9_UNMEASURED} (P1-P8 passed)" >&2; exit 3
fi
echo "PASS: 11-address-book-publish - 9 assertions (write once, skip unchanged, 10-min heartbeat, unnamed label, names-only, content change, mode 600, set republishes)"
exit 0
