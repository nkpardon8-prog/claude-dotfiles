#!/usr/bin/env bash
# 01 - A1..A4: parallel-stats counts spawn/codex turns correctly on the fixture,
#      with message.id groups MERGED ACROSS JSONL RECORDS.
#
# Load-bearing because: the whole baseline is a ratio of solo to batched turns.
# If groups were keyed per JSONL record instead of per message.id, the fixture's
# 3-wide batch (which deliberately spans TWO records) would be miscounted as a
# 2-wide plus a 1-wide solo - inflating "solo" and manufacturing the very waste
# the tool exists to measure.
#
# NEGATIVE CONTROL (controllable precondition): re-key grouping per record (or
# split the fixture's msg_a04 into two distinct message ids) and A1/A2/A3 go RED
# - watched: spawn turns 4->5, solo 3->4, width histogram gains a width-2 entry,
# exit 1.
set -uo pipefail
[ "${PARALLELSTATS_SMOKE_ALLOW_DEV:-}" != "true" ] && {
  echo "REFUSED: set PARALLELSTATS_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATS="${DIR}/../parallel-stats.py"
FIX="${DIR}/fixtures"
NAME="01-solo-vs-batched-counts"
[ -f "$STATS" ] || { echo "INFRA: missing ${STATS}" >&2; exit 3; }

OUT="$(PARALLEL_WAVES_DIR="${FIX}/rework-log" python3 "$STATS" "$FIX" --json 2>/dev/null)" \
  || { echo "INFRA: parallel-stats.py did not run" >&2; exit 3; }

read -r SPAWN SOLO BATCHED HIST CODEX RAW REF DEP <<EOF
$(printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin); s=d["metrics"]["spawn"]; c=d["metrics"]["codex"]
print(s["turns"], s["solo"], s["batched"],
      ",".join("%s:%s"%(k,v) for k,v in sorted(s["width_histogram"].items())),
      c["turns"], c["raw_solo"], c["refined_solo"], c["dependency_flagged"])')
EOF

FAIL=()
# A1 - spawn turn totals (4 groups: 1 solo lens, 1 three-wide batch, 2 solo implementers)
[ "$SPAWN" = "4" ]   || FAIL+=("A1 spawn turns expected 4, got '${SPAWN}'")
[ "$SOLO" = "3" ]    || FAIL+=("A1 solo spawn turns expected 3, got '${SOLO}'")
[ "$BATCHED" = "1" ] || FAIL+=("A1 batched spawn turns expected 1, got '${BATCHED}'")
# A2 - width histogram: exactly three width-1 and one width-3, nothing else
[ "$HIST" = "1:3,3:1" ] || FAIL+=("A2 width histogram expected '1:3,3:1', got '${HIST}'")
# A3 - the 3-wide group is the one whose message.id spans two JSONL records
SPANNED="$(printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("yes" if d["metrics"]["spawn"]["width_histogram"].get("3") == 1 else "no")')"
[ "$SPANNED" = "yes" ] || FAIL+=("A3 the two-record message.id did not merge into one width-3 group")
# A4 - codex turn accounting
[ "$CODEX" = "1" ] || FAIL+=("A4 codex turns expected 1, got '${CODEX}'")
[ "$RAW" = "1" ]   || FAIL+=("A4 raw solo codex expected 1, got '${RAW}'")
[ "$REF" = "1" ]   || FAIL+=("A4 refined solo codex expected 1, got '${REF}'")
[ "$DEP" = "0" ]   || FAIL+=("A4 dependency-flagged expected 0, got '${DEP}'")

if [ ${#FAIL[@]} -gt 0 ]; then
  echo "FAIL: ${NAME}"
  for f in "${FAIL[@]}"; do echo "  - $f"; done
  exit 1
fi
cat > "${DIR}/${NAME}.fingerprint.json" <<JSON
{"spawn_turns":${SPAWN},"spawn_solo":${SOLO},"spawn_batched":${BATCHED},"width_histogram":"${HIST}","codex_turns":${CODEX},"codex_raw_solo":${RAW},"codex_refined_solo":${REF},"grouping":"message.id merged across records"}
JSON
echo "PASS: ${NAME} - 4 assertions (A1, A2, A3, A4)"
exit 0
