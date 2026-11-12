#!/usr/bin/env bash
# test-mission-watchdog.sh - plan test 12: the /mission helper watchdog (detection only).
#
#   W1 idle window      - no growth in the declared paths -> exit 3 STALL (env-shortened window).
#   W2 deadline         - a non-test helper still growing at its class deadline -> exit 4.
#   W3 foreign writes   - a write OUTSIDE the declared paths does not reset the idle clock.
#   W4 done-marker      - the done-marker appearing -> exit 0.
#   W5 test run         - a suite run whose output keeps growing past its deadline is NOT ended:
#                         status says overdue (a note), the watchdog keeps watching, and done -> 0.
#   W6 negative control - growth inside a declared DIRECTORY keeps it alive past the idle window.
#   W7 usage            - bad class / missing args -> exit 2, no status file.
# Uses the script next to this file (never $HOME/.claude-dotfiles). macOS bash 3.2 compatible.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WD="$HERE/mission-watchdog.sh"
[ -f "$WD" ] || { echo "FATAL: $WD missing"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 [expected '$2', got '$1']"; }
has() { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 [missing '$1' in: $2]" ;; esac; }

T=$(mktemp -d "${TMPDIR:-/tmp}/mwd-test.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
export MISSION_LIVENESS_DIR="$T/liveness"
export MISSION_WATCHDOG_POLL_SECS=1
SID=sid-test-12

# grower <file> <seconds>: append a line every 0.5 s for <seconds>.
grower() { _g_n=$(( $2 * 2 )); while [ "$_g_n" -gt 0 ]; do echo tick >> "$1"; sleep 0.5; _g_n=$((_g_n - 1)); done; }
status_of() { cat "$MISSION_LIVENESS_DIR/$SID.watchdog.$1" 2>/dev/null; }

echo "W1 idle window -> exit 3"
: > "$T/w1.out"
MISSION_WATCHDOG_IDLE_SECS=2 bash "$WD" "$SID" w1 chunk "$T/w1.out" >/dev/null 2>&1
eq "$?" 3 "W1 no growth exits 3"
has "state=stall" "$(status_of w1)" "W1 status file says stall"
has "action=stop" "$(status_of w1)" "W1 stall asks the conductor to stop the helper"

echo "W2 class deadline -> exit 4 for a non-test helper"
: > "$T/w2.out"
grower "$T/w2.out" 8 &
GP=$!
s=$(date +%s)
MISSION_WATCHDOG_IDLE_SECS=3 MISSION_WATCHDOG_DEADLINE_SECS=3 bash "$WD" "$SID" w2 review "$T/w2.out" >/dev/null 2>&1
rc=$?; e=$(( $(date +%s) - s ))
kill "$GP" 2>/dev/null; wait "$GP" 2>/dev/null
eq "$rc" 4 "W2 growing review helper exits 4 at the deadline"
[ "$e" -lt 7 ] && ok "W2 exited near the deadline (${e}s)" || bad "W2 took ${e}s"
has "state=deadline" "$(status_of w2)" "W2 status says deadline"

echo "W3 writes outside the declared paths do not reset it"
: > "$T/w3.out"; : > "$T/w3.other"
grower "$T/w3.other" 8 &
GP=$!
MISSION_WATCHDOG_IDLE_SECS=2 bash "$WD" "$SID" w3 sweep "$T/w3.out" >/dev/null 2>&1
rc=$?
kill "$GP" 2>/dev/null; wait "$GP" 2>/dev/null
eq "$rc" 3 "W3 foreign growth still stalls"

echo "W4 done-marker -> exit 0"
: > "$T/w4.out"
( sleep 2; : > "$T/w4.done" ) &
MISSION_WATCHDOG_IDLE_SECS=10 bash "$WD" --done="$T/w4.done" "$SID" w4 chunk "$T/w4.out" >/dev/null 2>&1
eq "$?" 0 "W4 --done marker exits 0"
has "state=done" "$(status_of w4)" "W4 status says done"
: > "$T/w4b.out"
( sleep 2; : > "$MISSION_LIVENESS_DIR/$SID.watchdog.w4b.done" ) &
MISSION_WATCHDOG_IDLE_SECS=10 bash "$WD" "$SID" w4b chunk "$T/w4b.out" >/dev/null 2>&1
eq "$?" 0 "W4 default <status>.done marker exits 0"

echo "W5 a progressing test run is never ended at the deadline"
: > "$T/w5.out"
grower "$T/w5.out" 7 &
GP=$!
MISSION_WATCHDOG_IDLE_SECS=3 MISSION_WATCHDOG_DEADLINE_SECS=2 bash "$WD" "$SID" w5 suite "$T/w5.out" >/dev/null 2>&1 &
WP=$!
sleep 5
if kill -0 "$WP" 2>/dev/null; then ok "W5 still watching 3s past the deadline"; else bad "W5 watchdog exited at the deadline"; fi
has "state=overdue" "$(status_of w5)" "W5 status says overdue"
has "action=note" "$(status_of w5)" "W5 overdue is a note, not a stop"
: > "$MISSION_LIVENESS_DIR/$SID.watchdog.w5.done"
wait "$WP"; rc=$?
kill "$GP" 2>/dev/null; wait "$GP" 2>/dev/null
eq "$rc" 0 "W5 test run finishing after its deadline exits 0"

echo "W5b an overdue test run that then stops growing is still caught as STALL"
: > "$T/w5b.out"
grower "$T/w5b.out" 4 &
GP=$!
MISSION_WATCHDOG_IDLE_SECS=2 MISSION_WATCHDOG_DEADLINE_SECS=1 bash "$WD" "$SID" w5b suite "$T/w5b.out" >/dev/null 2>&1
rc=$?
wait "$GP" 2>/dev/null
eq "$rc" 3 "W5b overdue suite that goes quiet exits 3"

echo "W6 negative control: growth in a declared directory keeps it alive"
mkdir -p "$T/w6dir"
( n=0; while [ $n -lt 8 ]; do echo x > "$T/w6dir/f$n"; sleep 0.5; n=$((n+1)); done ) &
GP=$!
MISSION_WATCHDOG_IDLE_SECS=2 bash "$WD" "$SID" w6 review "$T/w6dir" >/dev/null 2>&1 &
WP=$!
sleep 3
if kill -0 "$WP" 2>/dev/null; then ok "W6 alive past the idle window while the dir grows"; else bad "W6 exited while the dir grew"; fi
wait "$GP" 2>/dev/null
wait "$WP"; eq "$?" 3 "W6 stalls once the dir stops growing"

echo "W7 usage errors"
bash "$WD" "$SID" w7 bogus "$T/w1.out" >/dev/null 2>&1; eq "$?" 2 "W7 unknown class exits 2"
bash "$WD" "$SID" w7 chunk >/dev/null 2>&1; eq "$?" 2 "W7 no paths exits 2"
bash "$WD" "$SID" "bad/label" chunk "$T/w1.out" >/dev/null 2>&1; eq "$?" 2 "W7 label with a slash exits 2"
[ -e "$MISSION_LIVENESS_DIR/$SID.watchdog.w7" ] && bad "W7 wrote a status file" || ok "W7 no status file"

echo "watchdog: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
