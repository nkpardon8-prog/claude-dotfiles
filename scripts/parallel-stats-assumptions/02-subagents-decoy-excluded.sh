#!/usr/bin/env bash
# 02 - A1..A3: subagent transcripts are excluded from the counts (rule R1),
#      whether they are reached via a directory walk or named EXPLICITLY.
#
# Load-bearing because: every subagent writes its own transcript full of tool
# calls, and a subagent spawned one-at-a-time by the orchestrator is not an
# orchestrator scheduling decision. Counting them would silently double-count
# and would make a solo-heavy orchestrator look busy and parallel.
#
# NEGATIVE CONTROL (controllable precondition): drop the "/subagents/" filter in
# collect_inputs() and A1/A2/A3 go RED - watched: transcripts counted 1->2,
# spawn turns 4->7, codex turns 1->3, exit 1.
set -uo pipefail
[ "${PARALLELSTATS_SMOKE_ALLOW_DEV:-}" != "true" ] && {
  echo "REFUSED: set PARALLELSTATS_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATS="${DIR}/../parallel-stats.py"
FIX="${DIR}/fixtures"
DECOY="${FIX}/session-a/subagents/agent-01.jsonl"
NAME="02-subagents-decoy-excluded"
[ -f "$DECOY" ] || { echo "INFRA: missing decoy ${DECOY}" >&2; exit 3; }

probe() {  # $@ = args to parallel-stats
  PARALLEL_WAVES_DIR="${FIX}/rework-log" python3 "$STATS" "$@" --json 2>/dev/null \
    | python3 -c '
import json,sys
d=json.load(sys.stdin); i=d["inputs"]
print(len(i["counted"]), len(i["excluded_subagents"]),
      d["metrics"]["spawn"]["turns"], d["metrics"]["codex"]["turns"])'
}

DIRONLY="$(probe "$FIX")"           || { echo "INFRA: dir run failed" >&2; exit 3; }
WITHDECOY="$(probe "$FIX" "$DECOY")" || { echo "INFRA: explicit-decoy run failed" >&2; exit 3; }

FAIL=()
# A1 - a directory argument never recurses into <session>/subagents/
[ "$DIRONLY" = "1 0 4 1" ] || FAIL+=("A1 dir walk expected 'counted=1 excluded=0 spawn=4 codex=1', got '${DIRONLY}'")
# A2 - an EXPLICITLY named subagent transcript is excluded, and said so
[ "$WITHDECOY" = "1 1 4 1" ] || FAIL+=("A2 explicit decoy expected 'counted=1 excluded=1 spawn=4 codex=1', got '${WITHDECOY}'")
# A3 - naming the decoy changes no metric (the decoy carries 3 spawns + 2 codex turns)
D_SPAWN="$(printf '%s' "$DIRONLY"   | cut -d' ' -f3)"
W_SPAWN="$(printf '%s' "$WITHDECOY" | cut -d' ' -f3)"
D_CODEX="$(printf '%s' "$DIRONLY"   | cut -d' ' -f4)"
W_CODEX="$(printf '%s' "$WITHDECOY" | cut -d' ' -f4)"
[ "$D_SPAWN" = "$W_SPAWN" ] || FAIL+=("A3 spawn turns changed when the decoy was named (${D_SPAWN} vs ${W_SPAWN})")
[ "$D_CODEX" = "$W_CODEX" ] || FAIL+=("A3 codex turns changed when the decoy was named (${D_CODEX} vs ${W_CODEX})")

if [ ${#FAIL[@]} -gt 0 ]; then
  echo "FAIL: ${NAME}"
  for f in "${FAIL[@]}"; do echo "  - $f"; done
  exit 1
fi
cat > "${DIR}/${NAME}.fingerprint.json" <<JSON
{"dir_walk":"${DIRONLY}","explicit_decoy":"${WITHDECOY}","decoy_tool_calls_ignored":5,"rule":"R1 exclude any path containing /subagents/"}
JSON
echo "PASS: ${NAME} - 3 assertions (A1, A2, A3)"
exit 0
