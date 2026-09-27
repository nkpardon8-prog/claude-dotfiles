#!/usr/bin/env bash
# 24 - resumework's iCloud nudge: while it waits for the bundle, `brctl monitor com.apple.CloudDocs`
#      runs in the background, and it is ALWAYS stopped when the wait ends. A stub brctl on PATH
#      records its pid + argv and then sleeps (as the real monitor does) so the test can prove it died.
#
#   A  bundle never arrives (--wait 3): started with exactly `monitor com.apple.CloudDocs`, and dead
#      once resumework has given up (die path).
#   B  resumework is TERMinated mid-wait: brctl is dead right after (trap path).
#   C  resumework is KILLed (-9, no traps run): the watchdog still stops brctl within a few seconds.
#   D  a normal restore (bundle present): brctl is dead by the time resumework returns.
#   E  a drop folder outside iCloud Drive (the tests' usual TX_DROP_DIR): brctl is never started.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 24)
cleanup() {
  for p in $(cat "$HOME_T"/brctl.*.pid 2>/dev/null); do kill "$p" 2>/dev/null; done
  rm -rf "$HOME_T"
}
trap cleanup EXIT
ICLOUD="$HOME_T/Library/Mobile Documents/com~apple~CloudDocs/claude-transfers"
mkdir -p "$ICLOUD" "$HOME_T/stub"
cat > "$HOME_T/stub/brctl" <<EOF
#!/bin/bash
n=\$(date +%s%N 2>/dev/null || date +%s)\$\$
echo "\$*" > "$HOME_T/brctl.\$n.args"
echo "\$\$" > "$HOME_T/brctl.\$n.pid"
exec sleep 300
EOF
chmod +x "$HOME_T/stub/brctl"
STUBPATH="$HOME_T/stub:$PATH"

started() { ls "$HOME_T"/brctl.*.pid >/dev/null 2>&1; }
alive() { local p; for p in $(cat "$HOME_T"/brctl.*.pid 2>/dev/null); do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
reset_stub() { for p in $(cat "$HOME_T"/brctl.*.pid 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -f "$HOME_T"/brctl.*; }
wait_started() { local i=0; while ! started && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done; started; }
dead_within() { local i=0; while alive && [ "$i" -lt $(( $1 * 5 )) ]; do sleep 0.2; i=$((i + 1)); done; ! alive; }
CODE=$(tx_new_code)

# ---------------------------------------------------------------- A: never arrives
( HOME="$HOME_T" TX_DROP_DIR="$ICLOUD" PATH="$STUBPATH" "$TX_RESUME" "$CODE" --wait 3 >/dev/null 2>&1 )
if ! started; then
  fail "A: brctl was never started while waiting on an iCloud drop folder"
else
  [ "$(cat "$HOME_T"/brctl.*.args | head -1)" = "monitor com.apple.CloudDocs" ] || fail "A: brctl got argv '$(cat "$HOME_T"/brctl.*.args | head -1)'"
  dead_within 2 || fail "A: brctl is still running after resumework gave up waiting"
fi
reset_stub

# ---------------------------------------------------------------- B: TERM mid-wait
HOME="$HOME_T" TX_DROP_DIR="$ICLOUD" PATH="$STUBPATH" "$TX_RESUME" "$CODE" --wait 60 >/dev/null 2>&1 &
RP=$!
if wait_started; then
  kill -TERM "$RP"; wait "$RP" 2>/dev/null
  dead_within 2 || fail "B: brctl survived a TERMinated resumework"
else
  kill "$RP" 2>/dev/null; fail "B: brctl was not started"
fi
reset_stub

# ---------------------------------------------------------------- C: KILL -9 mid-wait (no traps)
HOME="$HOME_T" TX_DROP_DIR="$ICLOUD" PATH="$STUBPATH" "$TX_RESUME" "$CODE" --wait 60 >/dev/null 2>&1 &
RP=$!
if wait_started; then
  kill -KILL "$RP"; wait "$RP" 2>/dev/null
  dead_within 5 || fail "C: brctl survived a kill -9 of resumework (the watchdog did not stop it)"
else
  kill "$RP" 2>/dev/null; fail "C: brctl was not started"
fi
reset_stub

# ---------------------------------------------------------------- D: a normal restore
ROOT="$HOME_T/work/proj"
tx_init_origin "$HOME_T/origin.git" "$ROOT" >/dev/null
ROOT=$(cd -P "$ROOT" && pwd -P)
SID=$(tx_new_sid)
tx_write_transcript "$HOME_T" "$SID" "$ROOT"
tx_write_handoff "$ROOT" "$SID"
tx_run_send "$HOME_T" "$ICLOUD" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send failed: $(tx_combined)" >&2; exit 3; }
( HOME="$HOME_T" TX_DROP_DIR="$ICLOUD" PATH="$STUBPATH" "$TX_RESUME" "$TX_LAST_CODE" --no-exec >"$HOME_T/d.out" 2>&1 )
D_RC=$?
[ "$D_RC" -eq 0 ] || fail "D: the restore failed (rc=$D_RC): $(tr '\n' '|' < "$HOME_T/d.out")"
started || fail "D: brctl was not started for an iCloud drop folder"
alive && fail "D: brctl is still running after a successful restore returned"
reset_stub

# ---------------------------------------------------------------- E: outside iCloud
mkdir -p "$HOME_T/plain-drop"
( HOME="$HOME_T" TX_DROP_DIR="$HOME_T/plain-drop" PATH="$STUBPATH" "$TX_RESUME" "$CODE" --wait 2 >/dev/null 2>&1 )
started && fail "E: brctl was started for a drop folder outside iCloud Drive"

ok_report "24-icloud-nudge" "brctl monitor com.apple.CloudDocs runs only while waiting on an iCloud drop folder and is stopped on give-up, TERM, kill -9 (watchdog) and a normal restore; never started outside iCloud"
