#!/bin/bash
# test-pickup-time.sh - fixture-based test for scripts/pickup-time.py.
# Resolved from THIS FILE's location (not $HOME) so it works on a CI runner
# where HOME differs from the developer machine - same discipline as
# test-lint-skill-size.sh, which regressed exactly this way once.
#
# Portable: no BSD `date -v` / `stat -f`. All epochs are computed with
# python3's zoneinfo against a pinned TZ so the assertions are correct on
# both macOS and a Linux CI runner. Pins TZ=America/Los_Angeles and
# PICKUP_NOW so every case is deterministic; PICKUP_NO_REFRESH=1 so no case
# ever shells out to the real ~/.claude/refresh-ratelimit.sh.
#
# bash 3.2 compatible.

set -u

_TPT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$_TPT_REPO/scripts/pickup-time.py"
[ -f "$SCRIPT" ] || { echo "FATAL: pickup-time.py not found at $SCRIPT (repo root resolved to $_TPT_REPO)" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pickup-time-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

TZ="America/Los_Angeles"
export TZ
export PICKUP_NO_REFRESH=1

pass=0; fail=0
check() { # check <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); else
        echo "FAIL: $1 (expected [$2] got [$3])" >&2; fail=$((fail+1)); fi
}

# epoch <Y> <M> <D> <h> <m> - epoch seconds for a LA wall-clock moment, computed
# with python3's zoneinfo rather than any `date` flavor.
epoch() {
    python3 -c "
import datetime, zoneinfo, sys
y,mo,d,h,mi = (int(x) for x in sys.argv[1:6])
print(int(datetime.datetime(y,mo,d,h,mi,tzinfo=zoneinfo.ZoneInfo('America/Los_Angeles')).timestamp()))
" "$1" "$2" "$3" "$4" "$5"
}

field() { # field <json> <key> - tiny stdlib-only JSON field reader
    python3 -c "
import json, sys
print(json.loads(sys.argv[1])[sys.argv[2]])
" "$1" "$2"
}

run() { # run <arg...> -> stdout captured in $OUT, rc in $RC
    OUT=$(PICKUP_NOW="$NOW" python3 "$SCRIPT" "$@" 2>"$TMP/err")
    RC=$?
    ERR=$(cat "$TMP/err")
}

RATELIMIT="$TMP/ratelimit.json"

mkrl() { # mkrl <fetched_at> <five_reset|null> <five_util|null> <five_status|null> <seven_reset|null> <seven_util|null> <seven_status|null>
    python3 -c "
import json, sys
def n(v):
    return None if v == 'null' else (float(v) if '.' in v else int(v))
def s(v):
    return None if v == 'null' else v
data = {
    'fetched_at': int(sys.argv[1]),
    'five_h_reset': n(sys.argv[2]),
    'five_h_util': None if sys.argv[3]=='null' else float(sys.argv[3]),
    'five_h_status': s(sys.argv[4]),
    'seven_d_reset': n(sys.argv[5]),
    'seven_d_util': None if sys.argv[6]=='null' else float(sys.argv[6]),
    'seven_d_status': s(sys.argv[7]),
}
open(sys.argv[8], 'w').write(json.dumps(data))
" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$RATELIMIT"
}

# ── Bare hour, ambiguous AM/PM (Task 2, bullet 1) ─────────────────────────────
NOW=$(epoch 2026 9 26 16 48)   # 4:48 PM
run 5:40
check "bare 5:40 at 4:48 PM -> 17:40 today" "0" "$RC"
check "bare 5:40 at 4:48 PM -> 17:40 today (epoch)" "$(epoch 2026 9 26 17 40)" "$(field "$OUT" fire_epoch)"

NOW=$(epoch 2026 9 26 18 0)    # 6:00 PM
run 5:40
check "bare 5:40 at 6:00 PM -> 05:40 tomorrow" "0" "$RC"
check "bare 5:40 at 6:00 PM -> 05:40 tomorrow (epoch)" "$(epoch 2026 9 27 5 40)" "$(field "$OUT" fire_epoch)"

NOW=$(epoch 2026 9 26 6 0)     # 6:00 AM
run 5:40am
check "5:40am at 6 AM -> tomorrow" "0" "$RC"
check "5:40am at 6 AM -> tomorrow (epoch)" "$(epoch 2026 9 27 5 40)" "$(field "$OUT" fire_epoch)"

# ── Equivalent spellings (Task 2, bullet 2) ───────────────────────────────────
NOW=$(epoch 2026 9 26 12 0)
run 17:40;    E1=$(field "$OUT" fire_epoch)
run 5:40pm;   E2=$(field "$OUT" fire_epoch)
run "5:40 pm"; E3=$(field "$OUT" fire_epoch)
check "17:40 == 5:40pm" "$E1" "$E2"
check "17:40 == '5:40 pm'" "$E1" "$E3"

run 5pm
check "5pm works" "0" "$RC"
check "5pm -> 17:00" "$(epoch 2026 9 26 17 0)" "$(field "$OUT" fire_epoch)"

NOW=$(epoch 2026 9 26 11 0)   # 11:00 AM
run 12:30
check "12:30 at 11 AM -> 12:30 today" "0" "$RC"
check "12:30 at 11 AM -> 12:30 today (epoch)" "$(epoch 2026 9 26 12 30)" "$(field "$OUT" fire_epoch)"

# Deliberately NOT exactly midnight: "today at 00:00" would already be in the
# past relative to a now of exactly 00:00 and roll to tomorrow, which would
# make this case indistinguishable from the midnight-crossing case below.
NOW=$(epoch 2026 9 26 20 0)   # 8:00 PM
run 12am
check "12am -> 00:00 (next midnight)" "$(epoch 2026 9 27 0 0)" "$(field "$OUT" fire_epoch)"
run 12pm
check "12pm -> 12:00 (next noon)" "$(epoch 2026 9 27 12 0)" "$(field "$OUT" fire_epoch)"

# ── Rejected forms (Task 2, bullet 3) ─────────────────────────────────────────
NOW=$(epoch 2026 9 26 12 0)
for bad in 13pm 17:40pm 25:99 5:60 soon; do
    run "$bad"
    check "'$bad' is rejected" "2" "$RC"
done

# ── Relative times (Task 2, bullet 4) ─────────────────────────────────────────
NOW=$(epoch 2026 9 26 12 0)
run +90m
check "+90m -> exit 0" "0" "$RC"
# 12:00 + 90m = 13:30, a :30 mark - computed times step one minute off it (early-fire quirk).
check "+90m -> now + 5400, nudged off :30" "$((NOW + 5460))" "$(field "$OUT" fire_epoch)"
run +95m
check "+95m -> now + 5700 (not on :00/:30, unchanged)" "$((NOW + 5700))" "$(field "$OUT" fire_epoch)"
run 1:30pm
check "typed 1:30pm stays exact (no nudge)" "$(epoch 2026 9 26 13 30)" "$(field "$OUT" fire_epoch)"

# A typed time under the 2-minute lead rolls to its next occurrence - with a warning, never silently.
NOW=$(epoch 2026 9 26 17 39)
run 5:40pm
check "5:40pm at 5:39 PM -> tomorrow" "$(epoch 2026 9 27 17 40)" "$(field "$OUT" fire_epoch)"
case "$(field "$OUT" warnings)" in *"under 2 minutes"*) r=yes ;; *) r=no ;; esac
check "5:40pm at 5:39 PM warns about the rollover" "yes" "$r"
NOW=$(epoch 2026 9 26 12 0)

run +1m
check "+1m -> exit 2 (under lead time)" "2" "$RC"

run +200h
check "+200h -> exit 2 (over 7 days)" "2" "$RC"

# ── Auto mode (Task 2, bullet 5) ──────────────────────────────────────────────
NOW=$(epoch 2026 9 26 12 0)
FIVE_RESET=$((NOW + 3600))
SEVEN_RESET=$((NOW + 5 * 86400))

run_auto() { OUT=$(PICKUP_NOW="$NOW" PICKUP_RATELIMIT_FILE="$RATELIMIT" python3 "$SCRIPT" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

mkrl "$NOW" "$FIVE_RESET" 0.9 "allowed" "$SEVEN_RESET" 0.5 "allowed"
run_auto
check "auto: five_h_reset + 180 (exit)" "0" "$RC"
check "auto: five_h_reset + 180 (epoch)" "$((FIVE_RESET + 180))" "$(field "$OUT" fire_epoch)"

mkrl "$NOW" "$FIVE_RESET" 0.9 "allowed" "$SEVEN_RESET" 0.5 "allowed_warning"
run_auto
check "auto: seven_d_status allowed_warning -> still 5-hour" "$((FIVE_RESET + 180))" "$(field "$OUT" fire_epoch)"

mkrl "$NOW" "$FIVE_RESET" 0.9 "allowed" "$SEVEN_RESET" 0.5 "unknown"
run_auto
check "auto: seven_d_status unknown -> still 5-hour" "$((FIVE_RESET + 180))" "$(field "$OUT" fire_epoch)"

mkrl "$NOW" "$FIVE_RESET" 0.9 "allowed" "$SEVEN_RESET" 0.9 "rejected"
run_auto
check "auto: seven_d_status rejected -> weekly reset" "$((SEVEN_RESET + 180))" "$(field "$OUT" fire_epoch)"
check "auto: weekly reset carries a warning" "1" "$(python3 -c "import json,sys; print(1 if json.loads(sys.argv[1])['warnings'] else 0)" "$OUT")"

mkrl "$NOW" "null" 0.9 "allowed" "$SEVEN_RESET" 0.5 "allowed"
run_auto
check "auto: null reset -> exit 2" "2" "$RC"

mkrl "$((NOW - 4000))" "$FIVE_RESET" 0.9 "allowed" "$SEVEN_RESET" 0.5 "allowed"
run_auto
check "auto: stale beyond 3600s -> exit 2" "2" "$RC"

mkrl "$NOW" "$((NOW - 100))" 0.9 "allowed" "$SEVEN_RESET" 0.5 "allowed"
run_auto
check "auto: reset in the past -> exit 2" "2" "$RC"

rm -f "$RATELIMIT"
run_auto
check "auto: missing file -> exit 2" "2" "$RC"

mkrl "$NOW" "$FIVE_RESET" 0.2 "allowed" "$SEVEN_RESET" 0.5 "allowed"
run_auto
check "auto: low util -> a warning" "1" "$(python3 -c "import json,sys; print(1 if json.loads(sys.argv[1])['warnings'] else 0)" "$OUT")"

# ── :30 warning, fire time unchanged (Task 2, bullet 6) ───────────────────────
NOW=$(epoch 2026 9 26 12 0)
run 5:30pm
check "a :30 time still fires exactly" "$(epoch 2026 9 26 17 30)" "$(field "$OUT" fire_epoch)"
check "a :30 time carries a warning" "1" "$(python3 -c "import json,sys; print(1 if json.loads(sys.argv[1])['warnings'] else 0)" "$OUT")"

# ── Midnight crossing a year boundary (Task 2, bullet 7a) ────────────────────
NOW=$(epoch 2026 12 31 23 0)
run 1:00am
check "Dec 31 -> Jan 1 crossing pins the new year" "0" "$RC"
check "Dec 31 -> Jan 1 crossing (epoch)" "$(epoch 2027 1 1 1 0)" "$(field "$OUT" fire_epoch)"

# ── DST day in LA (Task 2, bullet 7b): 2026-11-01 is when PDT -> PST switches ─
NOW=$(epoch 2026 11 1 12 0)
run 5:40pm
check "DST day: 5:40pm resolves to the correct epoch" "0" "$RC"
check "DST day: 5:40pm epoch matches zoneinfo directly" "$(epoch 2026 11 1 17 40)" "$(field "$OUT" fire_epoch)"

# ── backup = fire + 20 min (Task 2, bullet 8) ─────────────────────────────────
NOW=$(epoch 2026 9 26 12 0)
run 5:40pm
FIRE=$(field "$OUT" fire_epoch)
BACKUP=$(field "$OUT" backup_epoch)
check "backup_cron = fire + 20 min" "$((FIRE + 1200))" "$BACKUP"

echo "test-pickup-time: $pass passed, $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
