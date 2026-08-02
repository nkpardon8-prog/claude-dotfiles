#!/usr/bin/env bash
# 03 - A1..A3: --json emits a single parseable JSON document carrying the same
#      figures the human-readable mode prints.
#
# Load-bearing because: the weekly SessionStart replay and any later automation
# consume --json. A stray print to stdout, or a divergence between the text and
# JSON renderers, would make the machine-read number quietly disagree with the
# number a human read - the worst kind of measurement bug.
#
# NEGATIVE CONTROL (synthetic injection): add a bare print() before the json.dump
# in main(), or return a different figure from the text renderer, and A1/A3 go
# RED - watched: "Extra data" / figure mismatch, exit 1.
set -uo pipefail
[ "${PARALLELSTATS_SMOKE_ALLOW_DEV:-}" != "true" ] && {
  echo "REFUSED: set PARALLELSTATS_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATS="${DIR}/../parallel-stats.py"
FIX="${DIR}/fixtures"
NAME="03-json-output-parses"

JSON_OUT="$(PARALLEL_WAVES_DIR="${FIX}/rework-log" python3 "$STATS" "$FIX" --replay --json 2>/dev/null)" \
  || { echo "INFRA: --json run failed" >&2; exit 3; }
TEXT_OUT="$(PARALLEL_WAVES_DIR="${FIX}/rework-log" python3 "$STATS" "$FIX" --replay 2>/dev/null)" \
  || { echo "INFRA: text run failed" >&2; exit 3; }

FAIL=()
# A1 - stdout is exactly one parseable JSON document, and carries every section
SHAPE="$(printf '%s' "$JSON_OUT" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception as e:
    print("UNPARSEABLE:%s" % e); raise SystemExit(0)
need = {"inputs","counting_rules","metrics","wall_clock","rework","replay"}
missing = sorted(need - set(d))
print("OK" if not missing else "MISSING:%s" % ",".join(missing))')"
[ "$SHAPE" = "OK" ] || FAIL+=("A1 --json document shape: ${SHAPE}")

# A2 - the counting rules travel WITH the numbers (the baseline artifact quotes them)
RULES="$(printf '%s' "$JSON_OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin); print(len(d.get("counting_rules") or []))' 2>/dev/null)"
[ "${RULES:-0}" -ge 5 ] || FAIL+=("A2 expected >=5 embedded counting rules, got '${RULES}'")

# A3 - JSON figures equal the text-rendered figures
J_SOLO="$(printf '%s' "$JSON_OUT" | python3 -c '
import json,sys; print(json.load(sys.stdin)["metrics"]["spawn"]["solo"])' 2>/dev/null)"
T_SOLO="$(printf '%s' "$TEXT_OUT" | sed -n 's/^  solo (width 1) : \([0-9][0-9]*\).*/\1/p')"
[ -n "$T_SOLO" ] && [ "$J_SOLO" = "$T_SOLO" ] \
  || FAIL+=("A3 solo spawn turns disagree: json='${J_SOLO}' text='${T_SOLO}'")
J_REF="$(printf '%s' "$JSON_OUT" | python3 -c '
import json,sys; print(json.load(sys.stdin)["metrics"]["codex"]["refined_solo"])' 2>/dev/null)"
T_REF="$(printf '%s' "$TEXT_OUT" | sed -n 's/^  REFINED solo *: \([0-9][0-9]*\).*/\1/p')"
[ -n "$T_REF" ] && [ "$J_REF" = "$T_REF" ] \
  || FAIL+=("A3 refined solo codex disagree: json='${J_REF}' text='${T_REF}'")

if [ ${#FAIL[@]} -gt 0 ]; then
  echo "FAIL: ${NAME}"
  for f in "${FAIL[@]}"; do echo "  - $f"; done
  exit 1
fi
cat > "${DIR}/${NAME}.fingerprint.json" <<JSON
{"json_shape":"OK","embedded_counting_rules":${RULES},"solo_spawn_agreement":${J_SOLO},"refined_codex_agreement":${J_REF},"python":"$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"}
JSON
echo "PASS: ${NAME} - 3 assertions (A1, A2, A3)"
exit 0
