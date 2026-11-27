#!/bin/bash
# test-settings-drift-check.sh - drives scripts/settings-drift-check.py against fixture settings in a
# temp HOME (using the REAL template's _sync_required block), and its wiring in rules-in-force.py.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$DIR/settings-drift-check.py"
RIF="$DIR/hooks/rules-in-force.py"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude-dotfiles" "$T/.claude"
cp "$DIR/../settings.json.template" "$T/.claude-dotfiles/settings.json.template"
CANARY="sk-canary-7f3a9c1e5b"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; printf -- '---- output:\n%s\n----\n' "$2"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "$2";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "$2";; *) ok "$1";; esac; }
lines(){ [ "$(printf '%s' "$2" | grep -c '')" = "$3" ] && ok "$1" || bad "$1" "$2"; }
# settings fixture: the required values plus a secret-looking key; $1 = python edits to apply to d
fixture(){ python3 - "$T/.claude/settings.json" "$CANARY" "${1:-}" <<'PY'
import json, sys
d = {"env": {"API_TOKEN": sys.argv[2]}, "subagentPromptCacheTtl": "1h",
     "skillListingBudgetFraction": 0.01, "awaySummaryEnabled": False}
exec(sys.argv[3])
open(sys.argv[1], "w").write(json.dumps(d))
PY
}
run(){ HOME="$T" python3 "$CHECK"; echo "rc=$?"; }

fixture
o=$(run); [ "$o" = "rc=0" ] && ok "1 matching -> no output, exit 0" || bad "1 matching -> no output, exit 0" "$o"

fixture 'del d["subagentPromptCacheTtl"]'
o=$(run)
has   "2 missing key named"          "$o" "subagentPromptCacheTtl is absent, should be \"1h\""
has   "2 drift headline"             "$o" "SETTINGS DRIFT on "
has   "2 fix line"                   "$o" "Fix: back up ~/.claude/settings.json"
hasnt "2 only drifted key named"     "$o" "awaySummaryEnabled"
has   "2 exit 0"                     "$o" "rc=0"
lines "2 one block (2 lines + rc)"   "$o" 3

fixture 'd["skillListingBudgetFraction"] = 0.05; d["awaySummaryEnabled"] = 0'
o=$(run)
has   "3 wrong number named"         "$o" "skillListingBudgetFraction is 0.05, should be 0.01"
has   "3 0 is not false"             "$o" "awaySummaryEnabled is 0, should be false"

fixture 'd["autoCompactEnabled"] = False'
o=$(run)
has   "4 autoCompactEnabled false named" "$o" "autoCompactEnabled is false, should be absent"
fixture 'd["autoCompactEnabled"] = True'
o=$(run); [ "$o" = "rc=0" ] && ok "4 autoCompactEnabled true is fine" || bad "4 autoCompactEnabled true is fine" "$o"

printf '{"env": {"API_TOKEN": "%s"}, broken' "$CANARY" > "$T/.claude/settings.json"
o=$(run)
has   "5 malformed -> warning"       "$o" "is not valid JSON"
lines "5 one warning line + rc"      "$o" 2

fixture 'd["subagentPromptCacheTtl"] = sys.argv[2]; d.pop("awaySummaryEnabled")'
o=$(run)
hasnt "6 long local value never echoed (canary)" "$o" "$CANARY"
has   "6 long value shown as type"   "$o" "subagentPromptCacheTtl is a different str,"
for f in 'pass' 'del d["skillListingBudgetFraction"]' 'd["autoCompactEnabled"] = False'; do
  fixture "$f"; o=$(run); hasnt "6 canary absent ($f)" "$o" "$CANARY"
done

# wiring: rules-in-force.py session-start (main window) carries the drift; a worker's compaction does not
export RIF_STATE_DIR="$T/rif" RIF_GLOBAL_FILE="$T/g.md" RIF_RULES_DIR="$T/rules" RIF_LOG="$T/rif.log" RIF_NO_CODEX=1 RIF_NO_FETCH=1
printf 'Rules version: 2026-11-27.\n' > "$RIF_GLOBAL_FILE"
fixture 'd["autoCompactEnabled"] = False'
o=$(printf '{"session_id":"s1","cwd":"%s","source":"startup"}' "$T" | HOME="$T" python3 "$RIF" session-start)
has   "7 session-start carries drift" "$o" "autoCompactEnabled is false"
has   "7 rules line still printed"    "$o" "Rules loaded: global 2026-11-27"
o=$(printf '{"session_id":"s1","agent_id":"a1","cwd":"%s","source":"compact"}' "$T" | HOME="$T" python3 "$RIF" session-start)
hasnt "7 worker compaction skips drift" "$o" "SETTINGS DRIFT"
fixture
o=$(printf '{"session_id":"s2","cwd":"%s","source":"startup"}' "$T" | HOME="$T" python3 "$RIF" session-start)
hasnt "7 no drift -> no drift text"   "$o" "SETTINGS DRIFT"

# cost: the in-process check stays well under 50 ms
ms=$(HOME="$T" python3 -c "
import importlib.util, time
s = importlib.util.spec_from_file_location('m', '$CHECK'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
t = time.perf_counter(); m.report(); print(int((time.perf_counter() - t) * 1000))")
[ "$ms" -lt 50 ] && ok "8 report() took ${ms} ms (< 50)" || bad "8 report() took ${ms} ms" ""

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
