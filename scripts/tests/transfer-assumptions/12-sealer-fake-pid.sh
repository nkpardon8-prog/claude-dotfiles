#!/usr/bin/env bash
# 12 - --seal-after-exit: validates and prints the code immediately, then a detached sealer waits
# for the chat's own process to exit before writing the bundle. TX_SEAL_PID (dev-only) substitutes
# a short-lived real process for "the claude process this chat is running in", so the test proves
# the wait-then-package behavior without a real Claude Code session.
#
#   A1 the code/locator print immediately, before the fixture process has exited.
#   A2 no bundle exists yet while the fixture process is still alive.
#   A3 once the fixture process exits, the sealer packages within a bounded wait, and the
#      restored TRANSFER notes record that A closed before sealing (sealed_after_exit_at proof).
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 12)
FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

SID=$(tx_new_sid)
CWD="$HOME_T/work/proj"
mkdir -p "$CWD"
tx_write_transcript "$HOME_T" "$SID" "$CWD"
tx_write_handoff "$CWD" "$SID"

sleep 3 &
FAKE_PID=$!
sleep 0.2
kill -0 "$FAKE_PID" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }

OUT=$(mktemp "${TMPDIR:-/tmp}/tx12-out.XXXXXX"); ERR=$(mktemp "${TMPDIR:-/tmp}/tx12-err.XXXXXX")
( HOME="$HOME_T" TX_DROP_DIR="$DROP" TRANSFER_TESTS_ALLOW_DEV=true TX_SEAL_PID="$FAKE_PID" \
    "$TX_SEND" --tool claude --sid "$SID" --cwd "$CWD" --seal-after-exit >"$OUT" 2>"$ERR" )
RC=$?
LAUNCH_OUT=$(cat "$OUT"); LAUNCH_ERR=$(cat "$ERR"); rm -f "$OUT" "$ERR"
[ "$RC" -eq 0 ] || { echo "INFRA: --seal-after-exit launcher failed (rc=$RC): $LAUNCH_OUT $LAUNCH_ERR" >&2; exit 3; }

CODE=$(printf '%s\n' "$LAUNCH_OUT" | sed -n 's/^CODE=//p' | head -1)
LOC=$(printf '%s\n' "$LAUNCH_OUT" | sed -n 's/^LOCATOR=//p' | head -1)
[ -n "$CODE" ] && [ -n "$LOC" ] || fail "A1: --seal-after-exit did not print CODE/LOCATOR immediately"

[ -f "$DROP/$LOC.tx" ] && fail "A2: the bundle already exists while the fixture process is still alive"
kill -0 "$FAKE_PID" 2>/dev/null || echo "note: fixture process exited earlier than expected; A2 was not exercised meaningfully" >&2

# Bounded wait for the sealer to notice the fixture exiting and package (fixture sleeps ~3s total).
DEADLINE=$(( $(date +%s) + 30 ))
while [ ! -f "$DROP/$LOC.tx" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do sleep 1; done
[ -f "$DROP/$LOC.tx" ] || { echo "INFRA: sealer never wrote a bundle within 30s" >&2; exit 3; }
kill -0 "$FAKE_PID" 2>/dev/null && fail "A3: the bundle appeared while the fixture process was STILL alive"

tx_run_resume "$HOME_T" "$DROP" "$CODE" --no-exec
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "resumework exited $TX_LAST_RC restoring the sealed bundle: $(tx_combined | tr '\n' '|')"
else
  # The stdout summary only spells out "sealed after its chat exited" in --dry-run mode; the real
  # restore's proof lives in TRANSFER.<sid>.md's "Restored on B" section (checked below).
  TF="$CWD/TRANSFER.$SID.md"
  if [ -f "$TF" ]; then
    grep -q "A closed: the sending chat exited" "$TF" || fail "A3: TRANSFER.$SID.md does not record proof that A closed before sealing"
  else
    fail "A3: no TRANSFER.$SID.md was written"
  fi
fi

ok_report "12-sealer-fake-pid" "code prints immediately, no bundle while the fixture process lives, sealer packages after it exits and records sealed_after_exit_at proof"
