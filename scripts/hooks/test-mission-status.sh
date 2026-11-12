#!/usr/bin/env bash
# test-mission-status.sh - /mission status lines, per-part token totals and MORNING.md, from a
# canned log (mission-status-fixtures/). Each check has a negative control where one makes sense.
#
#   S1 status lines   - one line per part: outcome, tier, wall/budget, live wait, tokens, rounds,
#                       sweeps, escapes; parked shows reason + disposition + range; deferred shown.
#   S2 log reading    - rotated archives (.txt and .gz) are read before the live log; only the
#                       current generation (after the last MISSION-REBASELINED) counts.
#   S3 tokens by tag  - helpers by the m<N> tag in their description, conductor turns by the part
#                       named in the mission-write.sh lines that turn wrote, Codex runs by the tag in
#                       codex-runs.<sid>.tsv; a Codex run with no total is "tokens unknown", never 0;
#                       untagged work shows as unattributed. Negative control: drop a tag.
#   S4 MORNING.md     - landed, waiting on the push list (only this mission's lines), parked and why,
#                       deferred, stacked unlanded parts in order; rewritten, never appended; short.
#   S5 stop           - a MISSION-CLEARED line shows in the report header.
# Uses the script next to this file (never $HOME/.claude-dotfiles). macOS bash 3.2 compatible.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MS="$HERE/lib/mission-status.sh"
FX="$HERE/mission-status-fixtures"
[ -f "$MS" ] || { echo "FATAL: $MS missing"; exit 2; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
eq()    { [ "$1" = "$2" ] && ok "$3" || bad "$3 [expected '$2', got '$1']"; }
has()   { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 [missing '$1' in: $2]" ;; esac; }
hasnt() { case "$2" in *"$1"*) bad "$3 [unexpected '$1']" ;; *) ok "$3" ;; esac; }
line_of() { printf '%s\n' "$2" | grep -F -- "$1" | head -1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/mst-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
T0=1762790400
export TZ=UTC
export MISSION_STATUS_NOW=$((T0 + 600 * 60))
export MISSION_PROJECTS_DIR="$T/projects"
export MISSION_PUSH_QUEUE="$T/push-queue.md"
export MISSION_PLANTED_FILE="$T/planted.jsonl"
export MISSION_LIVENESS_DIR="$T/liveness"
SID=fx
R="$T/root"

build() {
  rm -rf "$T/root" "$T/projects" "$T/liveness"
  mkdir -p "$R/.mission-backups" "$R/tmp/mission" "$T/projects/-fx-root/$SID/subagents"
  cp "$FX/log-archive.txt" "$R/.mission-backups/MISSION.$SID.log.20251110T020000Z.txt"
  cp "$FX/log-live.txt" "$R/MISSION.$SID.log"
  cp "$FX/escaped.md" "$R/.mission-escaped.md"
  cp -R "$FX/codex" "$R/tmp/mission/codex"
  cp "$FX/codex-runs.tsv" "$R/tmp/mission/codex-runs.$SID.tsv"
  cp "$FX/transcripts/main.jsonl.txt" "$T/projects/-fx-root/$SID.jsonl"
  for h in h1 h2 h3; do
    cp "$FX/transcripts/agent-$h.jsonl.txt" "$T/projects/-fx-root/$SID/subagents/agent-$h.jsonl"
    cp "$FX/transcripts/agent-$h.meta.json" "$T/projects/-fx-root/$SID/subagents/agent-$h.meta.json"
  done
  cp "$FX/push-queue.md" "$MISSION_PUSH_QUEUE"
  cp "$FX/planted.jsonl.txt" "$MISSION_PLANTED_FILE"
  cp -R "$FX/liveness" "$MISSION_LIVENESS_DIR"
}

echo "S1 status lines"
build
OUT=$(bash "$MS" status "$SID" "$R" 2>&1)
has "mission $SID: active, 5 parts (2 done, 1 parked, 1 deferred, 1 open)" "$OUT" "S1 header counts"
eq "$(line_of 'part 1 ' "$OUT")" "part 1 recipe-lint: done | tier low | wall 100m/120m | live 15m | tokens 2.7k | plan 2 review 1 close 1 | sweeps 0 | escapes 1" "S1 part 1 line"
eq "$(line_of 'part 2 ' "$OUT")" "part 2 budget-clock: done | tier high | wall 140m/480m | live 0m | tokens 546k (+1 codex run, tokens unknown) | plan 1 review 2 close 1 | sweeps 2 (1 dirty) | escapes 1" "S1 part 2 line"
eq "$(line_of 'part 3 ' "$OUT")" "part 3 park-flow: parked (over-budget, isolated, range cccc2222dddd..eeee3333ffff) | tier normal | wall 140m/300m | live 0m | tokens 0 | plan 1 review 1 close 0 | sweeps 0 | escapes 0" "S1 part 3 parked line"
eq "$(line_of 'part 4 ' "$OUT")" "part 4 stack-next: deferred | tier - | wall - | live 0m | tokens 0 | plan 0 review 0 close 0 | sweeps 0 | escapes 0" "S1 part 4 deferred line"
eq "$(line_of 'part 5 ' "$OUT")" "part 5 status-lines: open | tier normal | wall 190m/300m | live 20m (waiting) | tokens 3.0k | plan 1 review 2 close 0 | sweeps 0 | escapes 0" "S1 part 5 open line"
has "unattributed tokens: 160" "$OUT" "S1 unattributed line"
has "watchdog m5-review-r2: stall (stop the helper)" "$OUT" "S1 live watchdog problem shown"
hasnt "m1-suite" "$OUT" "S1 finished watchdog not shown"
has "planted-bug: caught (2025-11-09)" "$OUT" "S1 planted-bug result"
rm -f "$MISSION_PLANTED_FILE"
has "planted-bug: never run" "$(bash "$MS" status "$SID" "$R" 2>&1)" "S1 planted-bug never run"

echo "S2 log reading"
build
hasnt "part 9" "$OUT" "S2 earlier generation ignored"
gzip "$R/.mission-backups/MISSION.$SID.log.20251110T020000Z.txt"
OUT2=$(bash "$MS" status "$SID" "$R" 2>&1)
eq "$OUT2" "$OUT" "S2 gz archive reads the same as txt"
rm -f "$R/.mission-backups/"*
OUT3=$(bash "$MS" status "$SID" "$R" 2>&1)
hasnt "part 1 recipe-lint: done" "$OUT3" "S2 negative control: without the archive part 1's start is gone"
NOPE=$(bash "$MS" status nosuch "$R" 2>&1); rc=$?
eq "$rc" 1 "S2 missing log exits 1"
has "no mission log" "$NOPE" "S2 missing log says so"

echo "S3 tokens by tag"
build
TOK=$(bash "$MS" tokens "$SID" "$R" 2>&1)
has "part 1: 2700 (conductor 1200, helpers 1500, codex 0)" "$TOK" "S3 part 1 = conductor turn + tagged helper (stream repeat counted once)"
has "part 2: 546267 (conductor 300, helpers 0, codex 545967; 1 codex run tokens unknown)" "$TOK" "S3 part 2 = wake turn + codex run dir"
has "part 5: 3000 (conductor 0, helpers 2000, codex 1000)" "$TOK" "S3 part 5 = m5- tagged helper + codex file"
has "unattributed: 160 (conductor 10, helpers 100, codex 50)" "$TOK" "S3 untagged work is unattributed"
sed -i.bak 's/m1 implement chunk A/implement chunk A/' "$T/projects/-fx-root/$SID/subagents/agent-h1.meta.json"
TOK2=$(bash "$MS" tokens "$SID" "$R" 2>&1)
has "part 1: 1200 (conductor 1200, helpers 0, codex 0)" "$TOK2" "S3 negative control: untagged helper leaves part 1"
has "unattributed: 1660 (conductor 10, helpers 1600, codex 50)" "$TOK2" "S3 negative control: it lands in unattributed"
rm -rf "$T/projects"
has "tokens unknown (no transcript)" "$(bash "$MS" status "$SID" "$R" 2>&1)" "S3 no transcript is unknown, not zero"

echo "S4 MORNING.md"
build
MO=$(bash "$MS" morning "$SID" "$R" 2>&1)
M="$R/tmp/mission/MORNING.md"
[ -f "$M" ] && ok "S4 MORNING.md written" || bad "S4 MORNING.md missing"
eq "$(printf '%s\n' "$MO" | wc -l | tr -d ' ')" 1 "S4 stdout is one summary line for the notification"
has "Mission $SID: 2 done, 1 parked, 1 deferred, 1 open" "$MO" "S4 summary line"
B=$(cat "$M")
has "Landed: part 1 recipe-lint (aaaa1111bbbb)" "$B" "S4 landed part"
has "Waiting on the push list: part 2 budget-clock (cccc2222dddd)" "$B" "S4 waiting part"
has "part 2 budget-clock | waiting" "$B" "S4 its push-queue line is quoted"
hasnt "unrelated work" "$B" "S4 other windows' push lines not listed"
has "Parked: part 3 park-flow - over-budget; disposition isolated; range cccc2222dddd..eeee3333ffff" "$B" "S4 parked and why"
has "Deferred: part 4 stack-next" "$B" "S4 deferred part"
has "Stacked unlanded parts, in order: part 2 (cccc2222dddd)" "$B" "S4 stack"
has "part 5 status-lines: open" "$B" "S4 per-part lines"
has "Watchdog: m5-review-r2 stall" "$B" "S4 watchdog problem needs attention"
[ "$(wc -l < "$M" | tr -d ' ')" -le 40 ] && ok "S4 one short screen (<= 40 lines)" || bad "S4 longer than 40 lines"
bash "$MS" morning "$SID" "$R" >/dev/null 2>&1
eq "$(grep -c '^# Mission morning report' "$M")" 1 "S4 rewritten, not appended"
sed -i.bak 's/part 1 recipe-lint | landed aaaa1111bbbb/part 1 recipe-lint | waiting/' "$MISSION_PUSH_QUEUE"
bash "$MS" morning "$SID" "$R" >/dev/null 2>&1
has "Stacked unlanded parts, in order: part 1 (aaaa1111bbbb), part 2 (cccc2222dddd)" "$(cat "$M")" "S4 stack lists unlanded parts in part order"
hasnt "Landed: part 1" "$(cat "$M")" "S4 negative control: waiting part is not landed"
grep -v 'budget-clock' "$FX/push-queue.md" > "$MISSION_PUSH_QUEUE"
bash "$MS" morning "$SID" "$R" >/dev/null 2>&1
has "Not on the push list yet: part 2 budget-clock (cccc2222dddd)" "$(cat "$M")" "S4 done part missing from the push list is flagged"

echo "S5 stop"
build
printf '\t[mission] MISSION-CLEARED status=could-not reason=all-parts-parked\n' >> "$R/MISSION.$SID.log"
bash "$MS" morning "$SID" "$R" >/dev/null 2>&1
has "Mission state: stopped (could-not, all-parts-parked)" "$(cat "$R/tmp/mission/MORNING.md")" "S5 stop reason in the header"

echo "status: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
