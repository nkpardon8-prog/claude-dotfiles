#!/usr/bin/env bash
# 05 - A1..A3: the rework.log reader reads real events, DROPS fixture-sourced
#      events, and tolerates an absent log.
#
# Load-bearing because: rework rate is the anti-Goodhart counterweight to
# wall-clock. If the hermetic suites' own synthetic events leaked into the
# count, every suite run would inflate the rework number and make the wave
# machinery look worse (or, after a rename, better) than it is. And an absent
# log is the NORMAL state until the machinery ships - if that raised an error,
# the weekly replay would fail closed from day one and nobody would see a
# baseline at all.
#
# NEGATIVE CONTROL (controllable precondition): flip the fixture event's
# repo_root off the "-assumptions/fixtures" substring and A2 goes RED - watched:
# events 3->4, dropped 1->0, exit 1.
set -uo pipefail
[ "${PARALLELSTATS_SMOKE_ALLOW_DEV:-}" != "true" ] && {
  echo "REFUSED: set PARALLELSTATS_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATS="${DIR}/../parallel-stats.py"
FIX="${DIR}/fixtures"
NAME="05-rework-log-read"
[ -f "${FIX}/rework-log/rework.log" ] || { echo "INFRA: missing rework fixture" >&2; exit 3; }

EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/parallel-stats-rework-XXXXXX")" || exit 3
trap 'rm -rf "$EMPTY"' EXIT

read_log() {  # $1 = PARALLEL_WAVES_DIR
  PARALLEL_WAVES_DIR="$1" python3 "$STATS" "$FIX" --json 2>/dev/null | python3 -c '
import json,sys
r=json.load(sys.stdin)["rework"]
print(r["present"], r["events"], r["dropped_fixture"], r["malformed"],
      len(r["by_reason"]))'
}

WITH="$(read_log "${FIX}/rework-log")" || { echo "INFRA: fixture-log run failed" >&2; exit 3; }
WITHOUT="$(read_log "$EMPTY")"         || { echo "INFRA: absent-log run failed" >&2; exit 3; }

FAIL=()
# A1 - real events are read, parsed, and bucketed by reason
[ "$WITH" = "True 3 1 0 3" ] \
  || FAIL+=("A1/A2 fixture log expected 'present=True events=3 dropped=1 malformed=0 reasons=3', got '${WITH}'")
# A2 - the event whose repo_root contains "-assumptions/fixtures" is dropped
DROPPED="$(printf '%s' "$WITH" | cut -d' ' -f3)"
[ "$DROPPED" = "1" ] || FAIL+=("A2 expected exactly 1 fixture-sourced event dropped, got '${DROPPED}'")
# A3 - an absent log is normal, not an error
[ "$WITHOUT" = "False 0 0 0 0" ] \
  || FAIL+=("A3 absent log expected 'present=False 0 0 0 0', got '${WITHOUT}'")
PARALLEL_WAVES_DIR="$EMPTY" python3 "$STATS" "$FIX" >/dev/null 2>&1 \
  || FAIL+=("A3 absent log changed the exit code (must stay 0)")

if [ ${#FAIL[@]} -gt 0 ]; then
  echo "FAIL: ${NAME}"
  for f in "${FAIL[@]}"; do echo "  - $f"; done
  exit 1
fi
cat > "${DIR}/${NAME}.fingerprint.json" <<JSON
{"with_fixture_log":"${WITH}","with_absent_log":"${WITHOUT}","drop_rule":"repo_root contains -assumptions/fixtures","schema":"jsonl one event per line"}
JSON
echo "PASS: ${NAME} - 3 assertions (A1, A2, A3)"
exit 0
