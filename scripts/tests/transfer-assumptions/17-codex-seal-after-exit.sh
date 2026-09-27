#!/usr/bin/env bash
# 17 - --seal-after-exit for --tool codex (the Codex /transfer skill's send). A throwaway `sleep`
# stands in for the Codex process (--source-pid), a sandboxed CODEX_HOME holds the rollout, and a
# python process holding $CODEX_HOME/thread-writer-locks/<id>.lock open stands in for Codex's
# per-chat lock (held by the window, or by the shared background server for ~60 s after the last
# window closes - the only "closed" signal when the chat runs on that server).
#
#   A  pid only: CODE/LOCATOR print at once; no bundle while the pid lives; lines appended to the
#      rollout AFTER the send started are in the restored rollout; the TRANSFER notes travel and
#      record that the chat closed before sealing.
#   B  pid + held lock: an immediate send refuses while the lock is held; with --seal-after-exit the
#      bundle does NOT appear when the pid dies but the lock is still held, and does once it is
#      released (the leftover, unheld lock file does not block); the late line travels.
#   C  refusals: no codex process above the shell and no --source-pid; --source-pid without
#      --seal-after-exit.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
command -v lsof >/dev/null 2>&1 || { echo "INFRA: lsof missing" >&2; exit 3; }

HOME_T=$(tx_sandbox 17)
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"
export CODEX_HOME="$HOME_T/.codex"
CWD="$HOME_T/work/proj"
mkdir -p "$CWD" "$CODEX_HOME/sessions/2026/09/26" "$CODEX_HOME/thread-writer-locks"

new_rollout() {  # new_rollout <id> -> path; a minimal rollout whose first line names the cwd
  local f="$CODEX_HOME/sessions/2026/09/26/rollout-2026-09-26T21-00-00-$1.jsonl"
  python3 - "$f" "$CWD" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps({"type": "session_meta", "payload": {"cwd": sys.argv[2], "id": "x"}}) + "\n")
    fh.write(json.dumps({"type": "response_item", "payload": {"content": "early turn: KIWI-11"}}) + "\n")
PY
  printf '%s' "$f"
}
append_turn() { printf '%s\n' "{\"type\":\"response_item\",\"payload\":{\"content\":\"$2\"}}" >> "$1"; }

launch() {  # launch <id> [extra args] -> $L_RC $L_OUT $L_ERR $L_CODE $L_LOC
  local o e
  o=$(mktemp "${TMPDIR:-/tmp}/tx17-out.XXXXXX"); e=$(mktemp "${TMPDIR:-/tmp}/tx17-err.XXXXXX")
  local id="$1"; shift
  ( HOME="$HOME_T" TX_DROP_DIR="$DROP" TRANSFER_TESTS_ALLOW_DEV=true TX_TEST_SEAL_TIMEOUT=90 \
      "$TX_SEND" --tool codex --sid "$id" --cwd "$CWD" "$@" >"$o" 2>"$e" )
  L_RC=$?; L_OUT=$(cat "$o"); L_ERR=$(cat "$e"); rm -f "$o" "$e"
  L_CODE=$(printf '%s\n' "$L_OUT" | sed -n 's/^CODE=//p' | head -1)
  L_LOC=$(printf '%s\n' "$L_OUT" | sed -n 's/^LOCATOR=//p' | head -1)
}

wait_bundle() {  # wait_bundle <loc> <secs> -> rc 0 once the bundle + sidecar exist
  local end=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    [ -f "$DROP/$1.tx" ] && [ -f "$DROP/$1.tx.sha256" ] && return 0
    sleep 1
  done
  return 1
}

restore_check() {  # restore_check <label> <code> <rollout> <marker>
  local label="$1" code="$2" roll="$3" marker="$4"
  rm -f "$roll" "$CWD/TRANSFER.$SID.md.restored-check"
  mv "$CWD/TRANSFER.$SID.md" "$HOME_T/TRANSFER.$SID.orig"
  tx_run_resume "$HOME_T" "$DROP" "$code" --no-exec
  if [ "$TX_LAST_RC" -ne 0 ]; then
    fail "$label: resumework exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"
    return
  fi
  [ -f "$roll" ] || { fail "$label: the rollout was not restored at $roll"; return; }
  grep -q "KIWI-11" "$roll" || fail "$label: the restored rollout lost its early turn"
  grep -q "$marker" "$roll" || fail "$label: the restored rollout lacks the turn appended after the send started ($marker) - the sealer did not collect the FINAL rollout"
  if [ -f "$CWD/TRANSFER.$SID.md" ]; then
    grep -q "NOTES-PAPAYA" "$CWD/TRANSFER.$SID.md" || fail "$label: the TRANSFER notes arrived without their content"
    grep -q "A closed: the sending chat exited" "$CWD/TRANSFER.$SID.md" || fail "$label: TRANSFER notes do not record that the chat closed before sealing"
  else
    fail "$label: the TRANSFER notes did not travel"
  fi
}

# ---------------------------------------------------------------- A: pid only
SID=$(tx_new_uuid)
ROLL=$(new_rollout "$SID")
printf '# Transfer notes - %s\nNOTES-PAPAYA\n' "$SID" > "$CWD/TRANSFER.$SID.md"
sleep 120 & FAKE=$!; PIDS="$PIDS $FAKE"
launch "$SID" --seal-after-exit --source-pid "$FAKE"
if [ "$L_RC" -ne 0 ] || [ -z "$L_CODE" ] || [ -z "$L_LOC" ]; then
  fail "A: the launcher did not print CODE/LOCATOR at once (rc=$L_RC): $L_OUT $L_ERR"
else
  sleep 2
  [ -f "$DROP/$L_LOC.tx" ] && fail "A: a bundle exists while the Codex stand-in process is still alive"
  append_turn "$ROLL" "late turn after send: MANGO-7"
  kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
  if wait_bundle "$L_LOC" 30; then
    restore_check A "$L_CODE" "$ROLL" "MANGO-7"
  else
    fail "A: no bundle within 30 s after the Codex stand-in exited (sealer log: $(tail -3 "$HOME_T/.claude/logs/transfer-sealer-$L_LOC.log" 2>/dev/null | tr '\n' '|'))"
  fi
fi

# ---------------------------------------------------------------- B: pid + held chat lock
SID=$(tx_new_uuid)
ROLL=$(new_rollout "$SID")
printf '# Transfer notes - %s\nNOTES-PAPAYA\n' "$SID" > "$CWD/TRANSFER.$SID.md"
LOCK="$CODEX_HOME/thread-writer-locks/$SID.lock"
python3 -c 'import sys, time; f = open(sys.argv[1], "a"); time.sleep(120)' "$LOCK" & HOLDER=$!; PIDS="$PIDS $HOLDER"
_end=$(( $(date +%s) + 10 ))
while [ -z "$(lsof -t -- "$LOCK" 2>/dev/null)" ] && [ "$(date +%s)" -lt "$_end" ]; do sleep 0.2; done
[ -n "$(lsof -t -- "$LOCK" 2>/dev/null)" ] || { echo "INFRA: lock holder never opened $LOCK" >&2; exit 3; }

launch "$SID"
[ "$L_RC" -eq 2 ] || fail "B: an immediate send of a chat whose lock is held should refuse (rc=$L_RC)"
printf '%s' "$L_ERR" | grep -q "still open" || fail "B: the refusal does not say the chat is still open: $L_ERR"

sleep 120 & FAKE=$!; PIDS="$PIDS $FAKE"
launch "$SID" --seal-after-exit --source-pid "$FAKE"
if [ "$L_RC" -ne 0 ] || [ -z "$L_CODE" ]; then
  fail "B: the launcher failed (rc=$L_RC): $L_OUT $L_ERR"
else
  printf '%s' "$L_ERR" | grep -q "chat lock" || fail "B: the launcher did not say it watches the chat lock: $L_ERR"
  kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
  sleep 4
  [ -f "$DROP/$L_LOC.tx" ] && fail "B: the bundle appeared while the chat lock was still held (the pid alone is not 'closed')"
  append_turn "$ROLL" "late turn while lock held: GUAVA-3"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  [ -f "$LOCK" ] || { echo "INFRA: the leftover lock file vanished; the unheld-lock case was not exercised" >&2; exit 3; }
  if wait_bundle "$L_LOC" 30; then
    restore_check B "$L_CODE" "$ROLL" "GUAVA-3"
  else
    fail "B: no bundle within 30 s after the chat lock was released (a leftover, unheld lock file must not block)"
  fi
fi

# ---------------------------------------------------------------- C: refusals
SID=$(tx_new_uuid)
new_rollout "$SID" >/dev/null
# Detached (own session, reparented to launchd), so no codex process can sit above the send even
# when this suite itself runs inside Codex.
RCF="$HOME_T/c.rc"; ERRF="$HOME_T/c.err"
HOME="$HOME_T" TX_DROP_DIR="$DROP" TRANSFER_TESTS_ALLOW_DEV=true \
  perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); select(undef, undef, undef, 0.5);
                   exec "/bin/bash", "-c", q{"$0" --tool codex --sid "$1" --cwd "$2" --seal-after-exit >/dev/null 2>"$3"; echo $? > "$4"},
                        @ARGV' "$TX_SEND" "$SID" "$CWD" "$ERRF" "$RCF"
_end=$(( $(date +%s) + 30 ))
while [ ! -s "$RCF" ] && [ "$(date +%s)" -lt "$_end" ]; do sleep 0.3; done
if [ ! -s "$RCF" ]; then
  echo "INFRA: the detached no-ancestor send never finished" >&2; exit 3
fi
[ "$(cat "$RCF")" = 2 ] || fail "C: with no codex process above the shell and no --source-pid the send should refuse (rc=$(cat "$RCF"))"
grep -q "no Codex process found" "$ERRF" || fail "C: the no-ancestor refusal does not explain itself: $(cat "$ERRF")"
ls "$DROP"/*.tx 2>/dev/null | grep -q . && fail "C: a bundle was written after a refusal"

launch "$SID" --source-pid "$$"
[ "$L_RC" -eq 2 ] || fail "C: --source-pid without --seal-after-exit should refuse (rc=$L_RC)"

ok_report "17-codex-seal-after-exit" "codex --seal-after-exit prints the code at once, waits for the Codex process AND its chat lock, ships the final rollout (turns added after the send) plus TRANSFER notes; refuses with no codex ancestor and on a misused --source-pid"
