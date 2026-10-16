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
#     confirmed compaction — /post-compact-resume <sid>; sentinel retained with attempts=1
#   - no resume when compaction is never confirmed; sentinel-retired fallback signal works
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

# Stub runpane: records argv, answers screen with an idle empty composer, answers submit with a
# verified "taken" delivery. On `/compact` it simulates the compaction finishing by appending a
# compact_boundary line to the transcript (STUB_WRITE_BOUNDARY=1) and/or deleting the sentinel
# like post-compact-primer.sh does (STUB_RETIRE_SENTINEL=<path>).
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "panels screen")
    echo '{"ok":true,"state":{"activityStatus":"idle"},"composer":{"isPresent":true,"hasUndeliveredText":false}}' ;;
  "panels submit")
    text=""; while [ $# -gt 0 ]; do [ "$1" = "--text" ] && { text="$2"; shift; }; shift; done
    if [ "$text" = "/compact" ]; then
      if [ "${STUB_WRITE_BOUNDARY:-0}" = "1" ]; then
        ( sleep 0.5; echo '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual"}}' >> "$STUB_TRANSCRIPT" ) &
      fi
      if [ -n "${STUB_RETIRE_SENTINEL:-}" ]; then ( sleep 0.5; rm -f "$STUB_RETIRE_SENTINEL" ) & fi
    fi
    echo '{"ok":true,"verifiedSubmitted":true,"delivery":{"state":"taken","evidence":"screen"}}' ;;
  *) echo '{"ok":false}' ;;
esac
STUBEOF
chmod +x "$STUB"
export STUB_LOG STUB_TRANSCRIPT="$TRANSCRIPT"

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
reset() { rm -f "$SP" "${SP}.attempts" "${SP}.pane-helper" "$STUB_LOG"; : > "$TRANSCRIPT"; : > "$LOG"; }

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
expect "exactly two submits" "$([ "$(printf '%s\n' "$SUBMITS" | grep -c .)" = "2" ] && echo 1)"
expect "1st submit is /compact to the panel" "$(printf '%s\n' "$SUBMITS" | sed -n 1p | grep -q -- '--panel test-panel_1 --text /compact --yes' && echo 1)"
expect "2nd submit is /post-compact-resume <sid>" "$(printf '%s\n' "$SUBMITS" | sed -n 2p | grep -q -- "--text /post-compact-resume $SID --yes" && echo 1)"
expect "every runpane call carries --pane-dir" "$([ "$(grep -vc -- "--pane-dir $PANEDIR" "$STUB_LOG")" = "0" ] && echo 1)"
expect "screen polled before /compact" "$(sed -n 1p "$STUB_LOG" | grep -q '^panels screen' && echo 1)"
expect "compaction confirmed via transcript boundary" "$(grep -q "pane-compact-confirmed sid=$SID .*signal=transcript-compact-boundary" "$LOG" && echo 1)"
expect "helper released its lock" "$([ ! -f "${SP}.pane-helper" ] && echo 1)"
expect "no osascript-path line for this sid" "$(grep -q "stop sid=$SID\|test-no-fire sid=$SID tty=" "$LOG" && echo 0 || echo 1)"

echo "== hook: no confirmed compaction → resume NOT sent =="
reset; write_pane_sentinel
AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC=2 hook "test-panel_1"
wait_helper
expect "/compact submitted" "$(grep -q -- '--text /compact' "$STUB_LOG" && echo 1)"
expect "resume NOT submitted" "$(grep -q 'post-compact-resume' "$STUB_LOG" && echo 0 || echo 1)"
expect "logged pane-compact-unconfirmed" "$(grep -q "pane-compact-unconfirmed sid=$SID" "$LOG" && echo 1)"
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
