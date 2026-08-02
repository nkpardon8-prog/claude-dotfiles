#!/usr/bin/env bash
# 04 - A1..A4: --replay runs and emits the DECOMPOSED wave-gate table (every
#      condition, evaluated-vs-assumed, coverage denominators) plus the
#      would-have-fired nudge counts.
#
# Load-bearing because: the Tasks 5-11 build decision rests on "how often would
# the wave gate have opened". A single aggregate percentage would hide that some
# conditions (working-tree cleanliness, stale waves) are NOT recorded in
# transcripts and are being CREDITED as open. The decomposition plus the "upper
# bound" label is what keeps that number honest.
#
# NEGATIVE CONTROL (controllable precondition): drop a row from WAVE_CONDITIONS
# or remove the "UPPER BOUND" label and A2/A3 go RED - watched: missing condition
# row / missing headline label, exit 1.
set -uo pipefail
[ "${PARALLELSTATS_SMOKE_ALLOW_DEV:-}" != "true" ] && {
  echo "REFUSED: set PARALLELSTATS_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATS="${DIR}/../parallel-stats.py"
FIX="${DIR}/fixtures"
NAME="04-replay-decomposed-table"

OUT="$(PARALLEL_WAVES_DIR="${FIX}/rework-log" python3 "$STATS" "$FIX" --replay 2>/dev/null)" \
  || { echo "INFRA: --replay run failed" >&2; exit 3; }
JSON_OUT="$(PARALLEL_WAVES_DIR="${FIX}/rework-log" python3 "$STATS" "$FIX" --replay --json 2>/dev/null)" \
  || { echo "INFRA: --replay --json run failed" >&2; exit 3; }

FAIL=()
# A1 - the replay section exists at all
printf '%s' "$OUT" | grep -q "WOULD THE WAVE GATE HAVE OPENED?" \
  || FAIL+=("A1 wave-gate replay section missing")
printf '%s' "$OUT" | grep -q "WOULD-HAVE-FIRED NUDGES" \
  || FAIL+=("A1 nudge replay section missing")

# A2 - every condition is a row, and every row carries a coverage denominator
for cond in chunks_ge_2 not_no_review repo_root_clean pct_known_le_60 no_stale_wave repo_root_ok; do
  printf '%s' "$OUT" | grep -qE "^  ${cond} .*[0-9]+/[0-9]+$" \
    || FAIL+=("A2 condition row missing or has no coverage denominator: ${cond}")
done

# A3 - the headline is labelled an upper bound, and unevaluable conditions are
#      visibly credited as assumed-open rather than silently counted
printf '%s' "$OUT" | grep -q "UPPER BOUND:" || FAIL+=("A3 headline is not labelled UPPER BOUND")
ASSUMED="$(printf '%s' "$JSON_OUT" | python3 -c '
import json,sys
c=json.load(sys.stdin)["replay"]["wave_gate"]["conditions"]
print(sum(1 for r in c.values() if r["assumed_open"] > 0))')"
[ "${ASSUMED:-0}" -ge 2 ] \
  || FAIL+=("A3 expected >=2 assumed-open conditions on the fixture, got '${ASSUMED}'")

# A4 - the fixture's deliberate serial shapes fire the nudges they should
read -r T1 T2 PHASES OPENUB <<EOF
$(printf '%s' "$JSON_OUT" | python3 -c '
import json,sys
r=json.load(sys.stdin)["replay"]; n=r["nudges"]["totals"]; g=r["wave_gate"]
print(n["open_tasks_3plus"], n["consecutive_solo_spawns"],
      g["implement_phases"], g["phases_gate_open_upper_bound"])')
EOF
[ "${T1:-0}" -ge 1 ] || FAIL+=("A4 open-tasks nudge should have fired once (3 open tasks + solo spawn), got '${T1}'")
[ "${T2:-0}" -ge 1 ] || FAIL+=("A4 consecutive-solo-spawn nudge should have fired, got '${T2}'")
[ "${PHASES:-0}" = "1" ] || FAIL+=("A4 expected 1 /implement phase in the fixture, got '${PHASES}'")
[ "${OPENUB:-0}" = "1" ] || FAIL+=("A4 expected the fixture phase to count as gate-open, got '${OPENUB}'")

if [ ${#FAIL[@]} -gt 0 ]; then
  echo "FAIL: ${NAME}"
  for f in "${FAIL[@]}"; do echo "  - $f"; done
  exit 1
fi
cat > "${DIR}/${NAME}.fingerprint.json" <<JSON
{"conditions_rows":6,"assumed_open_conditions":${ASSUMED},"nudge_open_tasks":${T1},"nudge_consecutive_solo":${T2},"implement_phases":${PHASES},"gate_open_upper_bound":${OPENUB}}
JSON
echo "PASS: ${NAME} - 4 assertions (A1, A2, A3, A4)"
exit 0
