#!/bin/bash
# Tests for line-ensure-settings.py's one-time settings (apply once, merge, never re-add after an undo).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude"
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
run() { HOME="$T" LINE_SETTINGS_FILE="$T/.claude/settings.json" python3 "$HERE/line-ensure-settings.py" --quiet >/dev/null; }
j() { python3 -c "import json,sys;d=json.load(open('$T/.claude/settings.json'));print($1)"; }

echo '{"skillOverrides":{"mine":"off"},"skillListingBudgetFraction":0.05,"deniedMcpServers":[{"serverName":"x"}]}' > "$T/.claude/settings.json"
run
ok "keeps the owner's own override" '[ "$(j "d[\"skillOverrides\"][\"mine\"]")" = off ]'
ok "hides an internal sub-file" '[ "$(j "d[\"skillOverrides\"][\"god-review:CRITERIA\"]")" = user-invocable-only ]'
ok "hides an owner-only command" '[ "$(j "d[\"skillOverrides\"][\"commit\"]")" = user-invocable-only ]'
ok "never hides pre-compact" '[ "$(j "\"pre-compact\" in d[\"skillOverrides\"]")" = False ]'
ok "budget back to 0.01" '[ "$(j "d[\"skillListingBudgetFraction\"]")" = 0.01 ]'
ok "keeps existing denied server and adds Apollo/Drive/Calendar" \
   '[ "$(j "sorted(e[\"serverName\"] for e in d[\"deniedMcpServers\"])")" = "[\x27claude.ai Apollo.io\x27, \x27claude.ai Google Calendar\x27, \x27claude.ai Google Drive\x27, \x27x\x27]" ]'
ok "done-marker written" '[ -f "$T/.claude/progress/settings-once.json" ]'

# Owner undoes one entry by hand: it must stay undone.
python3 -c "import json;p='$T/.claude/settings.json';d=json.load(open(p));d['deniedMcpServers']=[e for e in d['deniedMcpServers'] if e['serverName']!='claude.ai Google Drive'];del d['skillOverrides']['commit'];json.dump(d,open(p,'w'))"
run
ok "undone connector block stays undone" '[ "$(j "\"claude.ai Google Drive\" in [e[\"serverName\"] for e in d[\"deniedMcpServers\"]]")" = False ]'
ok "undone skill hide stays undone" '[ "$(j "\"commit\" in d[\"skillOverrides\"]")" = False ]'

echo; [ "$fails" -eq 0 ] && echo "all passed" || echo "$fails FAILED"; exit $((fails>0))
