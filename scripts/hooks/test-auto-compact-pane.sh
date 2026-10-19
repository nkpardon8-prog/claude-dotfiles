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
#   - Stop hook routes a Pane sentinel to the helper: submit /compact, then — only after a
#     /compact — /post-compact-resume <sid> queued right behind it (as Terminal does), confirmed only
#     after the compact_boundary; sentinel retained with attempts=1
#   - compaction never confirmed → no resume-confirmed; sentinel-retired fallback signal works
#   - panel mismatch / helper in flight → no claim; give-up at attempt 3
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

# Stub runpane: records argv and answers with canned JSON.
#   workspace state → the panel with agentState=$STUB_AGENT_STATE (default idle)
#   panels screen   → an idle empty composer. STUB_CAPTION=1 imitates a NAMED Claude session:
#                     Pane reports isPresent:false and the text shows `──── name ─` / `❯\u00a0`.
#                     STUB_HELD=<text> puts text in that composer; STUB_ABOVE=<row> is drawn just
#                     above the prompt box (Claude's spinner / "Worked for" row).
#   panels submit   → verified "taken"; with STUB_CAPTION=1 → blocked composer-unknown (nothing typed);
#                     STUB_UNVERIFIED=1 → typed but ok:true/verifiedSubmitted:false (seen live);
#                     STUB_STUCK=1 → same reply but the Enter did not land: the text sits in the
#                     composer until a separate `input --keys enter` (seen live, 2nd run)
#   panels input    → ok
# Effects: delivering `/compact` (submit, or input --text) appends a compact_boundary line to the
# transcript (STUB_WRITE_BOUNDARY=1) and/or deletes the sentinel like the primer does
# (STUB_RETIRE_SENTINEL=<path>); delivering `/post-compact-resume` appends a queue line at once
# and the command line 1.5s later (after the boundary).
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
text=""; args=("$@"); for ((i=0;i<${#args[@]};i++)); do [ "${args[$i]}" = "--text" ] && text="${args[$((i+1))]}"; done
effects() {
  if [ "$text" = "/compact" ]; then
    if [ "${STUB_WRITE_BOUNDARY:-0}" = "1" ]; then
      ( sleep 0.5; echo '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual"}}' >> "$STUB_TRANSCRIPT" ) &
    fi
    if [ -n "${STUB_RETIRE_SENTINEL:-}" ]; then ( sleep 0.5; rm -f "$STUB_RETIRE_SENTINEL" ) & fi
  fi
  # Queued mid-compaction: Claude records it early, then runs it after the boundary.
  case "$text" in "/post-compact-resume "*)
    echo '{"type":"queue-operation","operation":"enqueue","content":"/post-compact-resume"}' >> "$STUB_TRANSCRIPT"
    ( sleep 1.5; echo '{"type":"user","message":{"content":"<command-name>/post-compact-resume</command-name>"}}' >> "$STUB_TRANSCRIPT" ) & ;;
  esac
}
case "$1 $2" in
  "workspace state")
    printf '{"ok":true,"panes":[{"panels":[{"panelId":"test-panel_1","agentType":"claude","agentState":"%s","running":true}]}]}\n' "${STUB_AGENT_STATE:-idle}" ;;
  "panels screen")
    if [ "${STUB_CAPTION:-0}" = "1" ]; then
      python3 -c 'import json,os; print(json.dumps({"ok":True,"state":{"activityStatus":"active"},"composer":{"isPresent":False,"hasUndeliveredText":False},"text":"output\n"+os.environ.get("STUB_ABOVE","")+"\n\u2500\u2500\u2500\u2500\u2500 my-session \u2500\n\u276f\u00a0"+(open(os.environ["STUB_HELD_FILE"]).read() if os.path.isfile(os.environ["STUB_HELD_FILE"]) else os.environ.get("STUB_HELD",""))+"\n\u2500\u2500\u2500\u2500\u2500\u2500\u2500\n  ctx 9%"}))'
    else
      echo '{"ok":true,"state":{"activityStatus":"idle"},"composer":{"isPresent":true,"hasUndeliveredText":false}}'
    fi ;;
  "panels submit")
    if [ "${STUB_STUCK:-0}" = "1" ]; then
      printf '%s' "$text" > "$STUB_HELD_FILE"
      echo '{"ok":true,"verifiedSubmitted":false}'
    elif [ "${STUB_UNVERIFIED:-0}" = "1" ]; then
      effects
      echo '{"ok":true,"verifiedSubmitted":false}'
    elif [ "${STUB_CAPTION:-0}" = "1" ]; then
      echo '{"ok":false,"verifiedSubmitted":false,"inputBytes":0,"blocked":{"kind":"composer-unknown"}}'
    else
      effects
      echo '{"ok":true,"verifiedSubmitted":true,"delivery":{"state":"taken","evidence":"screen"}}'
    fi ;;
  "panels input")
    # STUB_RESUME_HELD=1: a resume typed mid-compaction stays visible after Enter (queued, seen live)
    if [ "${STUB_RESUME_HELD:-0}" = "1" ]; then
      case "$text" in "/post-compact-resume "*) printf '%s' "$text" > "$STUB_HELD_FILE"; echo '{"ok":true}'; exit 0 ;; esac
      if [ -z "$text" ] && grep -q '^/post-compact-resume ' "$STUB_HELD_FILE" 2>/dev/null; then
        text=$(cat "$STUB_HELD_FILE"); effects; echo '{"ok":true}'; exit 0
      fi
    fi
    if [ -z "$text" ] && [ -s "$STUB_HELD_FILE" ]; then text=$(cat "$STUB_HELD_FILE"); rm -f "$STUB_HELD_FILE"; fi
    effects
    echo '{"ok":true}' ;;
  *) echo '{"ok":false}' ;;
esac
STUBEOF
chmod +x "$STUB"
export STUB_LOG STUB_TRANSCRIPT="$TRANSCRIPT" STUB_HELD_FILE="$T/stub-held.txt"

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
export AUTO_COMPACT_PANE_POLL_SEC=0.2 AUTO_COMPACT_PANE_STABLE_POLLS=2
export AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=5 AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC=5
export AUTO_COMPACT_PANE_RESUME_DELAY_SEC=0.2

write_pane_sentinel() {
  HOME="$FAKEHOME" ac_write_sentinel_pane "$SID" "" "/tmp" "n-$$" "test-panel_1" "$STUB" "$PANEDIR"
}
hook() {  # hook <panel-env> [extra env...]
  local penv="$1"; shift
  printf '{"session_id":"%s","transcript_path":"%s"}' "$SID" "${HOOK_TRANSCRIPT-$TRANSCRIPT}" \
    | run_env PANE_PANEL_ID="$penv" AUTO_COMPACT_TEST_RUNPANE="$STUB" "$@" "$ROOT/auto-compact-after-pre-compact.sh"
}
wait_helper() {  # wait until the helper releases its lock (or 15s)
  local i=0
  while [ -f "${SP}.pane-helper" ] && [ "$i" -lt 75 ]; do sleep 0.2; i=$((i+1)); done
}
reset() { rm -f "$SP" "${SP}.attempts" "${SP}.pane-helper" "$STUB_LOG" "$STUB_HELD_FILE"; : > "$TRANSCRIPT"; : > "$LOG"; }

echo "== hook: Pane sentinel → helper submits /compact, then resume after confirmed compaction =="
reset; write_pane_sentinel
T0=$(date +%s)
STUB_WRITE_BOUNDARY=1 hook "test-panel_1"
expect "hook exit 0" "$([ $? = 0 ] && echo 1)"
expect "hook returns immediately (helper detached)" "$([ $(( $(date +%s) - T0 )) -le 3 ] && echo 1)"
expect "sentinel RETAINED for retry" "$([ -f "$SP" ] && echo 1)"
expect "attempts=1" "$([ "$(cat "${SP}.attempts" 2>/dev/null)" = "1" ] && echo 1)"
expect "logged pane-dispatched" "$(grep -q "pane-dispatched sid=$SID" "$LOG" && echo 1)"
wait_helper
SUBMITS=$(grep '^panels submit' "$STUB_LOG" 2>/dev/null)
expect "exactly one submit (only /compact)" "$([ "$(printf '%s\n' "$SUBMITS" | grep -c .)" = "1" ] && echo 1)"
expect "1st submit is /compact to the panel" "$(printf '%s\n' "$SUBMITS" | sed -n 1p | grep -q -- '--panel test-panel_1 --text /compact --yes' && echo 1)"
expect "resume typed directly, never via the slow submit" "$(grep -q -- "^panels input --panel test-panel_1 --text /post-compact-resume $SID --yes" "$STUB_LOG" && ! grep -q -- "^panels submit .*post-compact-resume" "$STUB_LOG" && echo 1)"
expect "every runpane call carries --pane-dir" "$([ "$(grep -vc -- "--pane-dir $PANEDIR" "$STUB_LOG")" = "0" ] && echo 1)"
expect "readiness read before /compact (workspace state + screen)" "$(sed -n 1,2p "$STUB_LOG" | grep -q '^workspace state' && sed -n 1,2p "$STUB_LOG" | grep -q '^panels screen' && echo 1)"
expect "resume confirmed in the transcript" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"
expect "compaction confirmed via transcript boundary" "$(grep -q "pane-compact-confirmed sid=$SID .*signal=transcript-compact-boundary" "$LOG" && echo 1)"
expect "resume queued right behind /compact (no post-compact idle wait)" "$(grep -q "wait=post-compact" "$LOG" && echo 0 || echo 1)"
expect "resume queued before compaction confirmed" "$(awk -v s="$SID" '$0~"step=resume" && $0~s{r=NR} $0~"pane-compact-confirmed sid="s{c=NR} END{exit !(r && c && r<c)}' "$LOG" && echo 1)"
expect "helper released its lock" "$([ ! -f "${SP}.pane-helper" ] && echo 1)"
expect "no osascript-path line for this sid" "$(grep -q "stop sid=$SID\|test-no-fire sid=$SID tty=" "$LOG" && echo 0 || echo 1)"

echo "== hook: NAMED Claude session (Pane composer-unknown) → panels input fallback =="
reset; write_pane_sentinel
STUB_CAPTION=1 STUB_WRITE_BOUNDARY=1 hook "test-panel_1"
wait_helper
expect "submit tried first for /compact" "$(grep -q -- '^panels submit --panel test-panel_1 --text /compact' "$STUB_LOG" && echo 1)"
expect "fallback typed /compact via panels input" "$(grep -q -- '^panels input --panel test-panel_1 --text /compact --yes' "$STUB_LOG" && echo 1)"
expect "Enter sent as a separate key press" "$(grep -q -- '^panels input --panel test-panel_1 --keys enter --yes' "$STUB_LOG" && echo 1)"
expect "logged pane-submit-fallback" "$(grep -q "pane-submit-fallback sid=$SID .*step=compact" "$LOG" && echo 1)"
expect "resume typed via panels input after confirmed compaction" "$(grep -q -- "^panels input --panel test-panel_1 --text /post-compact-resume $SID --yes" "$STUB_LOG" && echo 1)"
expect "resume confirmed in the transcript" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"
expect "our parser saw the named composer as ready" "$(grep -q "wait=pre-compact screen=ready agent/composer=idle/empty" "$LOG" && echo 1)"

echo "== hook: queued resume stays visible in the composer (seen live) → counted as queued =="
reset; write_pane_sentinel
STUB_CAPTION=1 STUB_RESUME_HELD=1 STUB_WRITE_BOUNDARY=1 hook "test-panel_1"
wait_helper
expect "resume logged as queued, not failed" "$(grep -q "pane-submitted sid=$SID .*step=resume .*queued behind compaction" "$LOG" && echo 1)"
expect "no pane-submit-failed for the resume" "$(grep -q "pane-submit-failed sid=$SID .*step=resume" "$LOG" && echo 0 || echo 1)"
expect "Enter pressed once for the resume (never queued twice)" "$([ "$(grep -c -- '--keys enter' "$STUB_LOG")" = "2" ] && echo 1)"
expect "resume confirmed in the transcript" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== hook: submit ok but UNVERIFIED (seen live) → no retype, resume after confirmed compaction =="
reset; write_pane_sentinel
STUB_CAPTION=1 STUB_UNVERIFIED=1 STUB_WRITE_BOUNDARY=1 hook "test-panel_1"
wait_helper
expect "logged submit-unverified for /compact" "$(grep -q "pane-submitted sid=$SID .*step=compact via=submit-unverified" "$LOG" && echo 1)"
expect "/compact NOT retyped via panels input" "$(grep -q -- '^panels input --panel test-panel_1 --text /compact' "$STUB_LOG" && echo 0 || echo 1)"
expect "exactly one /compact delivery" "$([ "$(grep -c -- '--text /compact ' "$STUB_LOG")" = "1" ] && echo 1)"
expect "resume typed right behind /compact" "$(grep -q -- "^panels input --panel test-panel_1 --text /post-compact-resume $SID --yes" "$STUB_LOG" && echo 1)"
expect "resume confirmed in the transcript" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"
expect "no pane-submit-failed" "$(grep -q "pane-submit-failed sid=$SID" "$LOG" && echo 0 || echo 1)"

echo "== hook: submit ok, UNVERIFIED, text left in composer (seen live) → Enter pressed, not retyped =="
reset; write_pane_sentinel
STUB_CAPTION=1 STUB_STUCK=1 STUB_WRITE_BOUNDARY=1 hook "test-panel_1"
wait_helper
expect "logged pane-submit-unverified composer_after=text" "$(grep -q "pane-submit-unverified sid=$SID .*step=compact composer_after=text" "$LOG" && echo 1)"
expect "Enter pressed as its own key" "$(grep -q -- '^panels input --panel test-panel_1 --keys enter --yes' "$STUB_LOG" && echo 1)"
expect "/compact typed exactly once" "$([ "$(grep -c -- '--text /compact ' "$STUB_LOG")" = "1" ] && echo 1)"
expect "logged pane-submitted via=submit-enter" "$(grep -q "pane-submitted sid=$SID .*step=compact via=submit-enter" "$LOG" && echo 1)"
expect "compaction confirmed" "$(grep -q "pane-compact-confirmed sid=$SID" "$LOG" && echo 1)"
expect "resume confirmed in the transcript" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== hook: Pane lists no agent state (other repo's panel, seen live) + finished turn → idle from the screen =="
reset; write_pane_sentinel
STUB_AGENT_STATE=none STUB_CAPTION=1 STUB_ABOVE="✻ Worked for 27s · done 5:00 PM" STUB_WRITE_BOUNDARY=1 hook "test-panel_1"
wait_helper
expect "ready read from Claude's own screen" "$(grep -q "wait=pre-compact screen=ready agent/composer=idle(screen)/empty" "$LOG" && echo 1)"
expect "/compact delivered" "$(grep -q -- '--text /compact ' "$STUB_LOG" && echo 1)"
expect "resume confirmed in the transcript" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 1)"

echo "== hook: Pane lists no agent state + spinner running → nothing typed =="
reset; write_pane_sentinel
STUB_AGENT_STATE=none STUB_CAPTION=1 STUB_ABOVE="✻ Sautéing… (26s · ↓ 2.6k tokens · thought for 5s)" AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "no submit/input while the spinner runs" "$(grep -qE '^panels (submit|input)' "$STUB_LOG" && echo 0 || echo 1)"
expect "logged none/empty busy" "$(grep -q "screen=busy agent/composer=none/empty" "$LOG" && echo 1)"

echo "== hook: agent still working → nothing typed =="
reset; write_pane_sentinel
STUB_AGENT_STATE=working AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "no submit/input while working" "$(grep -qE '^panels (submit|input)' "$STUB_LOG" && echo 0 || echo 1)"
expect "logged composer-not-ready-pre-compact" "$(grep -q "reason=composer-not-ready-pre-compact" "$LOG" && echo 1)"

echo "== hook: text already in a named composer → nothing typed =="
reset; write_pane_sentinel
STUB_CAPTION=1 STUB_HELD="half-typed thought" AUTO_COMPACT_PANE_READY_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "user's draft is never appended to" "$(grep -qE '^panels (submit|input)' "$STUB_LOG" && echo 0 || echo 1)"
expect "logged idle/text" "$(grep -q "agent/composer=idle/text" "$LOG" && echo 1)"

echo "== hook: no confirmed compaction → resume queued, never confirmed =="
reset; write_pane_sentinel
AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "/compact submitted" "$(grep -q -- '--text /compact' "$STUB_LOG" && echo 1)"
expect "resume queued once (as Terminal does)" "$([ "$(grep -c 'post-compact-resume' "$STUB_LOG")" = "1" ] && echo 1)"
expect "logged pane-compact-unconfirmed resume_queued=1" "$(grep -q "pane-compact-unconfirmed sid=$SID .*resume_queued=1" "$LOG" && echo 1)"
expect "no resume-confirmed without a boundary" "$(grep -q "pane-resume-confirmed sid=$SID" "$LOG" && echo 0 || echo 1)"
expect "sentinel still retained" "$([ -f "$SP" ] && echo 1)"

echo "== hook: fallback signal (no transcript) = sentinel retired by primer =="
reset; write_pane_sentinel
HOOK_TRANSCRIPT="" STUB_RETIRE_SENTINEL="$SP" hook "test-panel_1"
wait_helper
expect "resume sent after sentinel retirement" "$(grep -q "post-compact-resume $SID" "$STUB_LOG" && echo 1)"
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
STUB_WRITE_BOUNDARY=1 hook "test-panel_1"
wait_helper
expect "stale lock ignored → dispatched" "$(grep -q "pane-dispatched sid=$SID" "$LOG" && echo 1)"

echo "== hook: NO_FIRE without a test runpane → helper not spawned =="
reset; write_pane_sentinel
printf '{"session_id":"%s"}' "$SID" | run_env PANE_PANEL_ID="test-panel_1" "$ROOT/auto-compact-after-pre-compact.sh"
expect "logged test-no-fire delivery=pane" "$(grep -q "test-no-fire sid=$SID delivery=pane" "$LOG" && echo 1)"
expect "retained, attempts=1" "$([ -f "$SP" ] && [ "$(cat "${SP}.attempts" 2>/dev/null)" = "1" ] && echo 1)"
expect "stub never called" "$([ ! -s "$STUB_LOG" ] && echo 1)"

echo "== hook: give-up at attempt 3 =="
reset; write_pane_sentinel
echo 2 > "${SP}.attempts"
STUB_WRITE_BOUNDARY=1 hook "test-panel_1"
expect "give-up consumes the sentinel" "$([ ! -f "$SP" ] && echo 1)"
expect "attempts counter cleaned up" "$([ ! -f "${SP}.attempts" ] && echo 1)"
expect "logged give-up delivery=pane" "$(grep -q "give-up sid=$SID delivery=pane" "$LOG" && echo 1)"
wait_helper

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
