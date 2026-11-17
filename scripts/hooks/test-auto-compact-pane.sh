#!/usr/bin/env bash
# Smoke test for the PANE delivery path of auto-compact (2026-10-16).
#
# Fully sandboxed: a throwaway HOME (sentinels, logs, settings, transcript all live there) and a
# STUB runpane that only records its argv and answers with canned JSON. The real runpane is never
# invoked, so no keystrokes reach any live panel. The hook runs under AUTO_COMPACT_TEST_NO_FIRE
# with AUTO_COMPACT_TEST_RUNPANE pointing at the stub.
#
# Verifies:
#   - arm writes a delivery:"pane" sentinel (panel id, runpane_bin, pane_dir) that the existing
#     readers still accept; --dry-run reports Pane mode
#   - runpane missing → NOT armed; invalid panel id → NOT armed; TERM_PROGRAM set → Terminal path
#   - Stop hook routes a Pane sentinel to the helper, which waits for TRUE idle (transcript +
#     screen + empty prompt box), types /compact once with ONE Enter, proves it was accepted
#     (Compacting spinner or transcript), queues /post-compact-resume <sid> behind it, and confirms
#     both from the transcript; sentinel retained with attempts=1
#   - regressions from 2026-11-16: Pane's composer flag misreading an empty box; a new turn
#     starting right after the Stop while the screen looks idle
#   - a lost Enter: our text is deleted (never anyone else's) and retried once; then a bounded
#     give-up that retires the sentinel and raises a visible notification
#   - a compaction that starts and stops unfinished is not retried; one that never finishes times out
#   - panel mismatch / helper in flight → no claim; give-up at attempt 3 types nothing
#   - a Terminal sentinel still takes the osascript path (no pane verbs)
#
# Exits 0 if all assertions pass, non-zero otherwise.

set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1"; fi; }

T=$(mktemp -d)
trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
FAKEHOME="$T/home"
PANEDIR="$T/pane"
mkdir -p "$FAKEHOME/.claude/progress" "$FAKEHOME/.claude/logs" "$FAKEHOME/.claude/projects/proj" "$PANEDIR/bin"
echo '{}' > "$PANEDIR/config.json"
echo '{"hooks":{"Stop":[{"hooks":[{"command":"~/.claude-dotfiles/scripts/hooks/auto-compact-after-pre-compact.sh"}]}]}}' > "$FAKEHOME/.claude/settings.json"
LOG="$FAKEHOME/.claude/logs/auto-compact.log"
TRANSCRIPT="$FAKEHOME/.claude/projects/proj/session.jsonl"
STUB="$PANEDIR/bin/runpane"
STUB_LOG="$T/stub-calls.log"

# Stub runpane: records argv and imitates a NAMED Claude session's prompt box (Pane's own
# composer detector misses it, so `composer.isPresent` is false unless STUB_PANE_UNDELIVERED=1).
#   workspace state → the panel with agentState=$STUB_AGENT_STATE (default idle; "none" = unlisted)
#   panels screen   → `──── my-session ─` / `❯ <held text>` / rule / footer. STUB_ABOVE=<row> is
#                     drawn above the box. While compacting: a "Compacting conversation…" spinner
#                     and "esc to interrupt" in the footer. STUB_PANE_UNDELIVERED=1: Pane's flag
#                     claims undelivered text although the box is empty (the 2026-11-16 misread).
#                     STUB_GHOST=<text>: Claude's grey suggestion, drawn only while the box is empty.
#   panels input --text X   → X is appended to the box
#   panels input --keys enter → submits the box: "/compact" starts a compaction (STUB_COMPACT=
#                     ok (default, 2.1.32x: nothing written until the boundary) | legacy (2.1.319:
#                     a "/compact" user line at once) | cancel (stops after 1s, lone caveat, no
#                     boundary) | hang (never finishes)); "/post-compact-resume …" is queued and
#                     runs after the boundary. STUB_ENTER_IGNORED=<n>: the first n Enters do nothing.
#   panels input --keys backspace,… → deletes that many characters
#   panels submit   → must never be called (recorded, answers ok:false)
# Every --text /compact also records whether the stub's busy turn had finished (turn_done=0|1).
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
text=""; keys=""; args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  [ "${args[$i]}" = "--text" ] && text="${args[$((i+1))]}"
  [ "${args[$i]}" = "--keys" ] && keys="${args[$((i+1))]}"
done
held() { cat "$STUB_HELD_FILE" 2>/dev/null; }
tx() { printf '%s\n' "$1" >> "$STUB_TRANSCRIPT"; }
start_compact() {
  local mode="${STUB_COMPACT:-ok}"
  if [ "$mode" = "quick-cancel" ]; then   # 2.1.319: started and cancelled before the first poll
    tx '{"type":"user","message":{"role":"user","content":"/compact"}}'
    tx '{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}'
    return
  fi
  touch "$STUB_COMPACTING"
  [ -n "${STUB_USER_TYPES:-}" ] && ( sleep 0.1; printf '%s' "$STUB_USER_TYPES" > "$STUB_HELD_FILE" ) </dev/null >/dev/null 2>&1 &
  [ "$mode" = "legacy" ] && tx '{"type":"user","message":{"role":"user","content":"/compact"}}'
  [ "$mode" = "hang" ] && return
  (
    sleep 1
    if [ "$mode" = "cancel" ]; then
      tx '{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>The command below was run directly</local-command-caveat>"}}'
    else
      tx '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}'
      [ -n "${STUB_RETIRE_SENTINEL:-}" ] && rm -f "$STUB_RETIRE_SENTINEL"
    fi
    rm -f "$STUB_COMPACTING"
    # A line queued mid-compaction runs now.
    if [ -f "$STUB_QUEUED" ]; then
      q=$(cat "$STUB_QUEUED"); rm -f "$STUB_QUEUED" "$STUB_HELD_FILE"
      tx "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"<command-name>${q%% *}</command-name>\"}}"
    fi
  ) </dev/null >/dev/null 2>&1 &   # detached from runpane's stdout, like the real compaction
}
case "$1 $2" in
  "workspace state")
    if [ "${STUB_AGENT_STATE:-idle}" = "none" ]; then echo '{"ok":true,"panes":[]}'
    else printf '{"ok":true,"panes":[{"panels":[{"panelId":"test-panel_1","agentType":"claude","agentState":"%s"}]}]}\n' "${STUB_AGENT_STATE:-idle}"; fi ;;
  "panels screen")
    python3 - "$(held)" <<'PY'
import json, os, sys
compacting = os.path.exists(os.environ["STUB_COMPACTING"])
above = "✻ Compacting conversation… (1s)" if compacting else os.environ.get("STUB_ABOVE", "")
footer = "  bypass permissions on" + (" · esc to interrupt" if compacting else "")
pane = {"isPresent": True, "hasUndeliveredText": True} if os.environ.get("STUB_PANE_UNDELIVERED") == "1" else {"isPresent": False, "hasUndeliveredText": False}
box = sys.argv[1] or os.environ.get("STUB_GHOST", "")   # grey suggestion only in an empty box
text = "output\n" + above + "\n\n───── my-session ─\n❯ " + box + "\n───────\n" + footer
print(json.dumps({"ok": True, "state": {"activityStatus": "active"}, "composer": pane, "text": text}))
PY
    ;;
  "panels input")
    if [ -n "$text" ]; then
      [ "$text" = "/compact" ] && printf 'turn_done=%s\n' "$([ -f "$STUB_TURN_DONE" ] && echo 1 || echo 0)" >> "$STUB_LOG"
      printf '%s' "$(held)$text" > "$STUB_HELD_FILE"
    elif [ "$keys" = "enter" ]; then
      case "$(held)" in "/post-compact-resume "*) [ "${STUB_RESUME_ENTER_FAIL:-0}" = "1" ] && { echo '{"ok":false}'; exit 0; } ;; esac
      n=$(cat "$STUB_ENTERS" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_ENTERS"
      if [ "$n" -le "${STUB_ENTER_IGNORED:-0}" ]; then echo '{"ok":true}'; exit 0; fi
      h=$(held)
      case "$h" in
        /compact) rm -f "$STUB_HELD_FILE"; start_compact ;;
        "/post-compact-resume "*)
          if [ -f "$STUB_COMPACTING" ]; then
            printf '%s' "$h" > "$STUB_QUEUED"   # stays visible in the box until it runs
            tx '{"type":"queue-operation","operation":"enqueue","content":"/post-compact-resume"}'
          else
            rm -f "$STUB_HELD_FILE"; tx '{"type":"user","message":{"role":"user","content":"<command-name>/post-compact-resume</command-name>"}}'
          fi ;;
      esac
    else
      n=$(printf '%s' "$keys" | tr ',' '\n' | grep -c '^backspace$'); h=$(held)
      printf '%s' "${h:0:$(( ${#h} > n ? ${#h} - n : 0 ))}" > "$STUB_HELD_FILE"
    fi
    echo '{"ok":true}' ;;
  *) echo '{"ok":false}' ;;
esac
STUBEOF
chmod +x "$STUB"
export STUB_LOG STUB_TRANSCRIPT="$TRANSCRIPT" STUB_HELD_FILE="$T/stub-held.txt" STUB_COMPACTING="$T/stub-compacting" \
  STUB_QUEUED="$T/stub-queued" STUB_ENTERS="$T/stub-enters" STUB_TURN_DONE="$T/stub-turn-done"

# Clean runner env: no inherited Pane/Terminal identity from the shell running this test.
run_env() {
  env -u PANE_PANEL_ID -u PANE_RUNPANE_BIN -u TERM_PROGRAM -u TMUX -u STY \
      -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID HOME="$FAKEHOME" "$@"
}
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck source=lib/auto-compact-sentinel.sh
HOME="$FAKEHOME" . "$ROOT/lib/auto-compact-sentinel.sh"

echo "== arm: Pane mode writes a delivery:pane sentinel =="
SID="PANESMOKE_$$"
SP="$FAKEHOME/.claude/progress/auto-compact-$SID.json"
OUT=$(run_env PATH="$SAFE_PATH" PANE_PANEL_ID="test-panel_1" PANE_RUNPANE_BIN="$STUB" CLAUDE_SESSION_ID="$SID" \
      "$ROOT/arm-auto-compact.sh" "" "nonce-abc" 2>/dev/null)
case "$OUT" in *"armed (pane panel test-panel_1"*) expect "arm prints 'armed (pane panel ...)'" 1 ;; *) bad "arm output (got '$OUT')" ;; esac
expect "sentinel file written" "$([ -f "$SP" ] && echo 1)"
expect "sentinel mode 600" "$([ "$(stat -f '%Lp' "$SP" 2>/dev/null)" = "600" ] && echo 1)"
J() { jq -r "$1" "$SP" 2>/dev/null; }
expect "delivery=pane" "$([ "$(J .delivery)" = "pane" ] && echo 1)"
expect "pane_panel_id recorded" "$([ "$(J .pane_panel_id)" = "test-panel_1" ] && echo 1)"
expect "runpane_bin recorded" "$([ "$(J .runpane_bin)" = "$STUB" ] && echo 1)"
expect "pane_dir = parent of runpane's bin/" "$([ "$(J .pane_dir)" = "$PANEDIR" ] && echo 1)"
expect "schema_version stays 3" "$([ "$(J .schema_version)" = "3" ] && echo 1)"
expect "marker_nonce kept" "$([ "$(J .marker_nonce)" = "nonce-abc" ] && echo 1)"
# Existing readers (primer, /post-compact-resume) still accept it.
expect "ac_read_sentinel_cwd accepts pane sentinel" "$([ -n "$(HOME="$FAKEHOME" ac_read_sentinel_cwd "$SP")" ] && echo 1)"
expect "ac_read_sentinel_nonce accepts pane sentinel" "$([ "$(HOME="$FAKEHOME" ac_read_sentinel_nonce "$SP")" = "nonce-abc" ] && echo 1)"
expect "ac_read_sentinel_delivery = pane" "$([ "$(HOME="$FAKEHOME" ac_read_sentinel_delivery "$SP")" = "pane" ] && echo 1)"
FIELDS=$(HOME="$FAKEHOME" ac_read_sentinel_pane "$SP")
expect "ac_read_sentinel_pane round-trips" "$([ "$FIELDS" = "test-panel_1	$STUB	$PANEDIR" ] && echo 1)"
rm -f "$SP"

echo "== arm: --dry-run reports Pane mode, writes nothing =="
OUT=$(run_env PATH="$SAFE_PATH" PANE_PANEL_ID="test-panel_1" PANE_RUNPANE_BIN="$STUB" CLAUDE_SESSION_ID="$SID" \
      "$ROOT/arm-auto-compact.sh" "--dry-run" 2>/dev/null)
case "$OUT" in *"DRY-RUN"*"pane panel test-panel_1"*) ok "dry-run reports pane panel" ;; *) bad "dry-run (got '$OUT')" ;; esac
expect "dry-run wrote no sentinel" "$([ ! -f "$SP" ] && echo 1)"

echo "== arm: Pane detected but runpane unavailable =="
OUT=$(run_env PATH="$SAFE_PATH" PANE_PANEL_ID="test-panel_1" PANE_RUNPANE_BIN="$T/nope/runpane" CLAUDE_SESSION_ID="$SID" \
      "$ROOT/arm-auto-compact.sh" "" 2>/dev/null)
case "$OUT" in *"NOT armed — Pane detected but runpane unavailable"*) ok "runpane missing → NOT armed" ;; *) bad "runpane missing (got '$OUT')" ;; esac
expect "no sentinel when runpane missing" "$([ ! -f "$SP" ] && echo 1)"

echo "== arm: runpane found on PATH when PANE_RUNPANE_BIN unset =="
OUT=$(run_env PATH="$PANEDIR/bin:$SAFE_PATH" PANE_PANEL_ID="test-panel_1" CLAUDE_SESSION_ID="$SID" \
      "$ROOT/arm-auto-compact.sh" "--dry-run" 2>/dev/null)
case "$OUT" in *"pane panel test-panel_1 via $STUB"*) ok "PATH runpane used" ;; *) bad "PATH runpane (got '$OUT')" ;; esac

echo "== arm: invalid panel id refused =="
OUT=$(run_env PATH="$SAFE_PATH" PANE_PANEL_ID='bad id;rm' PANE_RUNPANE_BIN="$STUB" CLAUDE_SESSION_ID="$SID" \
      "$ROOT/arm-auto-compact.sh" "" 2>/dev/null)
case "$OUT" in *"NOT armed"*"valid panel id"*) ok "invalid panel id → NOT armed" ;; *) bad "invalid panel id (got '$OUT')" ;; esac

echo "== arm: TERM_PROGRAM set → Terminal path, not Pane =="
OUT=$(run_env PATH="$SAFE_PATH" TERM_PROGRAM="iTerm.app" PANE_PANEL_ID="test-panel_1" PANE_RUNPANE_BIN="$STUB" CLAUDE_SESSION_ID="$SID" \
      "$ROOT/arm-auto-compact.sh" "" 2>/dev/null)
case "$OUT" in *"NOT armed"*"iTerm.app"*) ok "iTerm host still refused (Terminal guard unchanged)" ;; *) bad "iTerm host (got '$OUT')" ;; esac
OUT=$(run_env PATH="$SAFE_PATH" TERM_PROGRAM="Apple_Terminal" PANE_PANEL_ID="test-panel_1" PANE_RUNPANE_BIN="$STUB" CLAUDE_SESSION_ID="$SID" \
      "$ROOT/arm-auto-compact.sh" "--dry-run" 2>/dev/null)
case "$OUT" in *"pane panel"*) bad "Apple_Terminal went to Pane mode (got '$OUT')" ;; *) ok "Apple_Terminal stays on the Terminal path" ;; esac

# ---- Stop hook --------------------------------------------------------------------------------
export AUTO_COMPACT_TEST_NO_FIRE=1
export AUTO_COMPACT_PANE_POLL_SEC=0.2 AUTO_COMPACT_PANE_STABLE_POLLS=2 AUTO_COMPACT_PANE_KEY_GAP_SEC=0.1
export AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=5 AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC=5
export AUTO_COMPACT_PANE_RESUME_DELAY_SEC=0.2 AUTO_COMPACT_PANE_ACCEPT_SEC=2

write_pane_sentinel() {
  HOME="$FAKEHOME" ac_write_sentinel_pane "$SID" "" "/tmp" "n-$$" "test-panel_1" "$STUB" "$PANEDIR"
}
hook() {  # hook <panel-env> [extra env...]
  local penv="$1"; shift
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SID" "${HOOK_TRANSCRIPT-$TRANSCRIPT}" \
    | run_env PANE_PANEL_ID="$penv" AUTO_COMPACT_TEST_RUNPANE="$STUB" "$@" "$ROOT/auto-compact-after-pre-compact.sh"
}
wait_helper() {  # wait until the helper releases its lock (or 20s)
  local i=0
  while [ -f "${SP}.pane-helper" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  sleep 0.3
}
# Each case starts from a finished turn: the transcript ends with Claude's turn-end entries.
reset() {
  rm -f "$SP" "${SP}.attempts" "${SP}.pane-helper" "$STUB_LOG" "$STUB_HELD_FILE" "$STUB_COMPACTING" \
        "$STUB_QUEUED" "$STUB_ENTERS" "$STUB_TURN_DONE"
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}' \
    '{"type":"system","subtype":"stop_hook_summary"}' '{"type":"system","subtype":"turn_duration"}' > "$TRANSCRIPT"
  : > "$LOG"
}
compact_types() { grep -c -- '^panels input --panel test-panel_1 --text /compact --yes' "$STUB_LOG" 2>/dev/null; }
enters() { grep -c -- '--keys enter' "$STUB_LOG" 2>/dev/null; }

echo "== hook: Pane sentinel → /compact typed once, accepted, resume queued, both confirmed =="
reset; write_pane_sentinel
T0=$(date +%s)
hook "test-panel_1"
expect "hook exit 0" "$([ $? = 0 ] && echo 1)"
expect "hook returns immediately (helper detached)" "$([ $(( $(date +%s) - T0 )) -le 3 ] && echo 1)"
expect "sentinel RETAINED while the helper works" "$([ -f "$SP" ] && echo 1)"
expect "attempts=1" "$([ "$(cat "${SP}.attempts" 2>/dev/null)" = "1" ] && echo 1)"
expect "logged pane-dispatched" "$(grep -q "pane-dispatched sid=$SID" "$LOG" && echo 1)"
wait_helper
expect "/compact typed exactly once" "$([ "$(compact_types)" = "1" ] && echo 1)"
expect "panels submit never used" "$(grep -q '^panels submit' "$STUB_LOG" && echo 0 || echo 1)"
expect "exactly two Enters (one for /compact, one for the resume)" "$([ "$(enters)" = "2" ] && echo 1)"
expect "accepted from the Compacting spinner (2.1.32x writes nothing until the end)" "$(grep -q "pane-compact-accepted sid=$SID .*try=1 signal=screen-compacting" "$LOG" && echo 1)"
expect "resume typed with panels input" "$(grep -q -- "^panels input --panel test-panel_1 --text /post-compact-resume $SID --yes" "$STUB_LOG" && echo 1)"
expect "resume queued before compaction confirmed" "$(awk -v s="$SID" '$0~"pane-resume-queued sid="s{r=NR} $0~"pane-compact-confirmed sid="s{c=NR} END{exit !(r && c && r<c)}' "$LOG" && echo 1)"
expect "compaction confirmed via transcript boundary" "$(grep -q "pane-compact-confirmed sid=$SID .*signal=transcript-compact-boundary" "$LOG" && echo 1)"
expect "resume confirmed in the transcript" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"
expect "every runpane call carries --pane-dir" "$([ "$(grep -v '^turn_done=' "$STUB_LOG" | grep -vc -- "--pane-dir $PANEDIR")" = "0" ] && echo 1)"
expect "readiness logged with the transcript state" "$(grep -q "wait=pre-compact screen=ready agent/composer/transcript=idle/empty/idle" "$LOG" && echo 1)"
expect "no notification on success" "$(grep -q "notify " "$LOG" && echo 0 || echo 1)"
expect "sentinel retired by the helper once compaction is proven (no primer handoff here)" "$([ ! -f "$SP" ] && [ ! -f "${SP}.attempts" ] && grep -q "pane-sentinel-retired sid=$SID" "$LOG" && echo 1)"
: > "$STUB_LOG"; hook "test-panel_1"
expect "the next Stop types nothing (no second compaction)" "$([ ! -s "$STUB_LOG" ] && echo 1)"
expect "helper released its lock" "$([ ! -f "${SP}.pane-helper" ] && echo 1)"
expect "no osascript-path line for this sid" "$(grep -q "stop sid=$SID\|test-no-fire sid=$SID tty=" "$LOG" && echo 0 || echo 1)"

echo "== hook: Claude 2.1.319 (writes the /compact line at the start) → accepted from the transcript =="
reset; write_pane_sentinel
STUB_COMPACT=legacy hook "test-panel_1"
wait_helper
expect "accepted (transcript or screen)" "$(grep -q "pane-compact-accepted sid=$SID .*try=1" "$LOG" && echo 1)"
expect "resume confirmed" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== REGRESSION 2026-11-16 (a): Pane's flag claims text in an EMPTY box → still delivered, no extra Enter =="
reset; write_pane_sentinel
STUB_PANE_UNDELIVERED=1 hook "test-panel_1"
wait_helper
expect "our own reading of the box wins (ready)" "$(grep -q "screen=ready agent/composer/transcript=idle/empty/idle" "$LOG" && echo 1)"
expect "/compact typed once" "$([ "$(compact_types)" = "1" ] && echo 1)"
expect "never a second Enter for /compact (2 total)" "$([ "$(enters)" = "2" ] && echo 1)"
expect "resume queued and confirmed" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"
expect "no pane-gave-up" "$(grep -q "pane-gave-up" "$LOG" && echo 0 || echo 1)"

echo "== REGRESSION 2026-11-16 (b): a new turn starts right after the Stop; screen looks idle =="
reset; write_pane_sentinel
printf '%s\n' '{"type":"user","message":{"role":"user","content":"<task-notification>new comments</task-notification>"}}' >> "$TRANSCRIPT"
( sleep 2
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}' \
    '{"type":"system","subtype":"stop_hook_summary"}' >> "$TRANSCRIPT"
  touch "$STUB_TURN_DONE" ) &
STUB_AGENT_STATE=none hook "test-panel_1"
wait_helper
expect "waited: logged transcript=busy while the turn ran" "$(grep -q "screen=busy agent/composer/transcript=idle(screen)/empty/busy" "$LOG" && echo 1)"
expect "/compact typed only after the turn ended" "$(grep -q '^turn_done=1' "$STUB_LOG" && ! grep -q '^turn_done=0' "$STUB_LOG" && echo 1)"
expect "resume confirmed" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== hook: queued line waiting in the transcript → busy, nothing typed =="
reset; write_pane_sentinel
printf '%s\n' '{"type":"queue-operation","operation":"enqueue","content":"next"}' >> "$TRANSCRIPT"
AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "nothing typed while a line is queued" "$(grep -q '^panels input' "$STUB_LOG" && echo 0 || echo 1)"
expect "never-idle abort keeps the sentinel" "$(grep -q "reason=never-idle" "$LOG" && [ -f "$SP" ] && echo 1)"

echo "== hook: first Enter lost → text cleared, retyped once, delivered =="
reset; write_pane_sentinel
STUB_ENTER_IGNORED=1 hook "test-panel_1"
wait_helper
expect "logged not-accepted on try 1" "$(grep -q "pane-compact-not-accepted sid=$SID .*try=1 .*composer=text" "$LOG" && echo 1)"
expect "our text deleted with backspaces" "$(grep -q -- '--keys backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace ' "$STUB_LOG" && grep -q "pane-clear sid=$SID .*result=cleared" "$LOG" && echo 1)"
expect "/compact typed twice in total" "$([ "$(compact_types)" = "2" ] && echo 1)"
expect "accepted on try 2" "$(grep -q "pane-compact-accepted sid=$SID .*try=2" "$LOG" && echo 1)"
expect "resume confirmed" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== hook: Enter never lands → bounded: 2 tries, box left empty, sentinel retired, visible note =="
reset; write_pane_sentinel
STUB_ENTER_IGNORED=99 hook "test-panel_1"
wait_helper
expect "/compact typed exactly twice" "$([ "$(compact_types)" = "2" ] && echo 1)"
expect "box empty at the end (no stray /compact)" "$([ -z "$(cat "$STUB_HELD_FILE" 2>/dev/null)" ] && echo 1)"
expect "logged pane-gave-up" "$(grep -q "pane-gave-up sid=$SID .*reason=compact-not-accepted-after-2-tries" "$LOG" && echo 1)"
expect "visible notification" "$(grep -q "notify Auto-compact did not run" "$LOG" && echo 1)"
expect "sentinel + attempts retired" "$([ ! -f "$SP" ] && [ ! -f "${SP}.attempts" ] && echo 1)"
expect "no resume typed" "$(grep -q 'post-compact-resume' "$STUB_LOG" && echo 0 || echo 1)"
: > "$STUB_LOG"; hook "test-panel_1"
expect "a later Stop types nothing" "$([ ! -s "$STUB_LOG" ] && echo 1)"

echo "== hook: someone else's text in the box after a lost Enter → left alone =="
reset; write_pane_sentinel
( while [ ! -s "$STUB_HELD_FILE" ]; do sleep 0.05; done; sleep 0.15; printf '%s' "my own words" > "$STUB_HELD_FILE" ) &
STUB_ENTER_IGNORED=99 AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "never deleted other text" "$([ "$(cat "$STUB_HELD_FILE" 2>/dev/null)" = "my own words" ] && echo 1)"
expect "logged left-alone" "$(grep -q "pane-clear sid=$SID .*result=left-alone" "$LOG" && echo 1)"
expect "/compact typed once (box never empty again)" "$([ "$(compact_types)" = "1" ] && echo 1)"

echo "== hook: compaction starts then stops without finishing (seen live) → no retry, visible note =="
reset; write_pane_sentinel
STUB_COMPACT=cancel hook "test-panel_1"
wait_helper
expect "accepted first" "$(grep -q "pane-compact-accepted sid=$SID" "$LOG" && echo 1)"
expect "logged gave-up compaction-stopped-before-finishing" "$(grep -q "pane-gave-up sid=$SID .*reason=compaction-stopped-before-finishing" "$LOG" && echo 1)"
expect "/compact NOT retyped" "$([ "$(compact_types)" = "1" ] && echo 1)"
expect "visible notification" "$(grep -q "notify " "$LOG" && echo 1)"
expect "sentinel retired" "$([ ! -f "$SP" ] && echo 1)"

echo "== review: a line queued during the last turn, not yet taken → busy =="
reset; write_pane_sentinel
printf '%s\n' '{"type":"queue-operation","operation":"enqueue","content":"next"}' '{"type":"system","subtype":"stop_hook_summary"}' >> "$TRANSCRIPT"
AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "nothing typed while the queued line waits" "$(grep -q '^panels input' "$STUB_LOG" && echo 0 || echo 1)"

echo "== review: compaction started and stopped before the first check → accepted, never retried =="
reset; write_pane_sentinel
STUB_COMPACT=quick-cancel hook "test-panel_1"
wait_helper
expect "accepted (started-ended)" "$(grep -q "pane-compact-accepted sid=$SID .*signal=transcript-started-ended" "$LOG" && echo 1)"
expect "/compact typed once" "$([ "$(compact_types)" = "1" ] && echo 1)"
expect "gave up as stopped-before-finishing" "$(grep -q "pane-gave-up sid=$SID .*reason=compaction-stopped-before-finishing" "$LOG" && echo 1)"

echo "== review: someone types while compacting → resume NOT appended to their text =="
reset; write_pane_sentinel
STUB_USER_TYPES="hello there" hook "test-panel_1"
wait_helper
expect "resume skipped, logged" "$(grep -q "pane-resume-skipped sid=$SID .*reason=box-not-empty" "$LOG" && echo 1)"
expect "their text untouched" "$([ "$(cat "$STUB_HELD_FILE")" = "hello there" ] && echo 1)"
expect "visible notification" "$(grep -q "notify .*was not typed" "$LOG" && echo 1)"
expect "compaction still confirmed" "$(grep -q "pane-compact-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== review: the resume's Enter fails → its text cleared, visible note =="
reset; write_pane_sentinel
STUB_RESUME_ENTER_FAIL=1 hook "test-panel_1"
wait_helper
expect "resume text cleared" "$(grep -q "pane-clear sid=$SID .*step=resume result=cleared" "$LOG" && [ -z "$(cat "$STUB_HELD_FILE" 2>/dev/null)" ] && echo 1)"
expect "visible notification" "$(grep -q "notify .*could not be typed" "$LOG" && echo 1)"

echo "== hook: compaction never finishes → timeout, note, sentinel left =="
reset; write_pane_sentinel
STUB_COMPACT=hang AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "logged pane-compact-unconfirmed resume_queued=1" "$(grep -q "pane-compact-unconfirmed sid=$SID .*resume_queued=1" "$LOG" && echo 1)"
expect "no resume-confirmed without a boundary" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 0 || echo 1)"
expect "visible notification" "$(grep -q "notify " "$LOG" && echo 1)"
expect "sentinel still retained" "$([ -f "$SP" ] && echo 1)"

echo "== hook: Pane lists no agent state + finished turn → idle from the screen =="
reset; write_pane_sentinel
STUB_AGENT_STATE=none STUB_ABOVE="✻ Worked for 27s · done 5:00 PM" hook "test-panel_1"
wait_helper
expect "ready read from Claude's own screen" "$(grep -q "screen=ready agent/composer/transcript=idle(screen)/empty/idle" "$LOG" && echo 1)"
expect "resume confirmed" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== hook: spinner running → nothing typed =="
reset; write_pane_sentinel
STUB_AGENT_STATE=none STUB_ABOVE="✻ Sautéing… (26s · ↓ 2.6k tokens · thought for 5s)" AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "no input while the spinner runs" "$(grep -q '^panels input' "$STUB_LOG" && echo 0 || echo 1)"
expect "logged none/empty busy" "$(grep -q "screen=busy agent/composer/transcript=none/empty/idle" "$LOG" && echo 1)"

echo "== hook: agent still working → nothing typed =="
reset; write_pane_sentinel
STUB_AGENT_STATE=working AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "no input while working" "$(grep -q '^panels input' "$STUB_LOG" && echo 0 || echo 1)"
expect "logged never-idle" "$(grep -q "reason=never-idle" "$LOG" && echo 1)"

echo "== hook: Claude's grey suggestion in the empty box (Claude 2.1.326, live) → replaced and delivered =="
reset; write_pane_sentinel
STUB_GHOST="Now run sleep 12, then reply with just three" hook "test-panel_1"
wait_helper
expect "suggestion recognised by typing over it" "$(grep -q "pane-suggestion-replaced sid=$SID" "$LOG" && echo 1)"
expect "/compact typed once" "$([ "$(compact_types)" = "1" ] && echo 1)"
expect "resume confirmed" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== hook: the user's real draft in the box → our characters removed, never submitted =="
reset; write_pane_sentinel
printf '%s' "half-typed thought" > "$STUB_HELD_FILE"
AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=3 hook "test-panel_1"
wait_helper
expect "logged pane-draft-detected" "$(grep -q "pane-draft-detected sid=$SID" "$LOG" && echo 1)"
expect "draft left exactly as it was" "$([ "$(cat "$STUB_HELD_FILE")" = "half-typed thought" ] && echo 1)"
expect "Enter never pressed" "$([ "$(enters)" = "0" ] && echo 1)"
expect "probed once, then waited (known draft)" "$([ "$(compact_types)" = "1" ] && echo 1)"
expect "never-idle abort keeps the sentinel" "$(grep -q "reason=never-idle" "$LOG" && [ -f "$SP" ] && echo 1)"

echo "== hook: fallback signal (no transcript) = sentinel retired by primer =="
reset; write_pane_sentinel
HOOK_TRANSCRIPT="" STUB_RETIRE_SENTINEL="$SP" hook "test-panel_1"
wait_helper
expect "resume sent" "$(grep -q "post-compact-resume $SID" "$STUB_LOG" && echo 1)"
expect "signal=sentinel-retired" "$(grep -q "pane-compact-confirmed sid=$SID .*signal=sentinel-retired" "$LOG" && echo 1)"

echo "== hook: panel mismatch → abort, nothing claimed or typed =="
reset; write_pane_sentinel
hook "some-other-panel"
expect "logged pane-panel-mismatch" "$(grep -q "reason=pane-panel-mismatch" "$LOG" && echo 1)"
expect "sentinel untouched" "$([ -f "$SP" ] && echo 1)"
expect "no attempt counted" "$([ ! -f "${SP}.attempts" ] && echo 1)"
expect "stub never called" "$([ ! -s "$STUB_LOG" ] && echo 1)"

echo "== hook: helper already in flight → skip =="
reset; write_pane_sentinel
perl -e 'sleep 30' auto-compact-fake-helper "$T/" &
FAKE=$!
echo "$FAKE" > "${SP}.pane-helper"
hook "test-panel_1"
expect "logged pane-skip helper-in-flight" "$(grep -q "pane-skip sid=$SID reason=helper-in-flight" "$LOG" && echo 1)"
expect "no attempt counted" "$([ ! -f "${SP}.attempts" ] && echo 1)"
expect "stub never called" "$([ ! -s "$STUB_LOG" ] && echo 1)"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
echo "$FAKE" > "${SP}.pane-helper"   # now a dead pid → stale lock, must not block
hook "test-panel_1"
wait_helper
expect "stale lock ignored → dispatched" "$(grep -q "pane-dispatched sid=$SID" "$LOG" && echo 1)"

echo "== hook: NO_FIRE without a test runpane → helper not spawned =="
reset; write_pane_sentinel
printf '{"session_id":"%s"}' "$SID" | run_env PANE_PANEL_ID="test-panel_1" "$ROOT/auto-compact-after-pre-compact.sh"
expect "logged test-no-fire delivery=pane" "$(grep -q "test-no-fire sid=$SID delivery=pane" "$LOG" && echo 1)"
expect "retained, attempts=1" "$([ -f "$SP" ] && [ "$(cat "${SP}.attempts" 2>/dev/null)" = "1" ] && echo 1)"
expect "stub never called" "$([ ! -s "$STUB_LOG" ] && echo 1)"

echo "== hook: give-up at attempt 3 → nothing typed, visible note =="
reset; write_pane_sentinel
echo 2 > "${SP}.attempts"
hook "test-panel_1"
expect "give-up consumes the sentinel" "$([ ! -f "$SP" ] && echo 1)"
expect "attempts counter cleaned up" "$([ ! -f "${SP}.attempts" ] && echo 1)"
expect "logged give-up delivery=pane" "$(grep -q "give-up sid=$SID delivery=pane" "$LOG" && echo 1)"
expect "visible notification" "$(grep -q "notify Auto-compact gave up" "$LOG" && echo 1)"
sleep 1
expect "no helper spawned, stub never called" "$([ ! -s "$STUB_LOG" ] && ! grep -q "pane-dispatched sid=$SID" "$LOG" && echo 1)"
expect "no lock left behind" "$([ ! -f "${SP}.pane-helper" ] && echo 1)"

echo "== hook: Terminal sentinel still takes the osascript path =="
reset
HOME="$FAKEHOME" ac_write_sentinel "$SID" "/dev/ttys999" "/tmp" "t-$$"
printf '{"session_id":"%s"}' "$SID" | run_env PANE_PANEL_ID="test-panel_1" AUTO_COMPACT_TEST_RUNPANE="$STUB" "$ROOT/auto-compact-after-pre-compact.sh"
expect "no pane verbs for a Terminal sentinel" "$(grep -q 'pane-' "$LOG" && echo 0 || echo 1)"
# From inside a live claude the own-pid checks pass and the no-fire seam logs; outside one, the
# Terminal path aborts at own-claude-unresolved. Either line proves the Terminal branch ran.
expect "Terminal branch ran (test-no-fire tty= or abort own-claude)" \
  "$(grep -qE "test-no-fire sid=$SID tty=|abort sid=$SID reason=" "$LOG" && echo 1)"
expect "stub never called" "$([ ! -s "$STUB_LOG" ] && echo 1)"
rm -f "$SP" "${SP}.attempts"

echo
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
