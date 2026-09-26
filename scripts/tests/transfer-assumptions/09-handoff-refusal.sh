#!/usr/bin/env bash
# 09 - transfer-send.sh refuses to send a claude chat without a fresh, correctly-marked handoff.
#   A1 no handoff at all -> refused, mentions /pre-compact.
#   A2 handoff present but 40 minutes old (limit 30) -> refused, mentions the age/limit.
#   A3 handoff present, fresh, but its END-OF-HANDOFF marker names a DIFFERENT sid -> refused.
#   A4 positive control: a fresh, correctly-marked handoff sends fine (else A1-A3 would be
#      vacuous - a script that always refuses would pass all three above).
#   A5 --dry-run with no handoff: the refusal becomes an informational "A real run would refuse"
#      line, the file list and sizes still print, exit 0, nothing written.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 09)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

fresh_case() {  # fresh_case <name> <cwd> -> writes transcript, returns sid via $CASE_SID
  local name="$1" cwd="$2"
  CASE_SID=$(tx_new_sid)
  mkdir -p "$cwd"
  tx_write_transcript "$HOME_T" "$CASE_SID" "$cwd"
}

# --- A1: no handoff -----------------------------------------------------------------------------
fresh_case A1 "$HOME_T/work/a1"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$CASE_SID" --cwd "$HOME_T/work/a1"
if [ "$TX_LAST_RC" -eq 2 ]; then
  case "$TX_LAST_ERR" in
    *"pre-compact"*) ;;
    *) fail "A1: refusal did not mention /pre-compact: $TX_LAST_ERR" ;;
  esac
else
  fail "A1: expected refuse (rc=2) with no handoff, got rc=$TX_LAST_RC: $(tx_combined)"
fi

# --- A2: stale handoff (40 minutes old, limit 30) ------------------------------------------------
fresh_case A2 "$HOME_T/work/a2"
tx_write_handoff "$HOME_T/work/a2" "$CASE_SID" 2400
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$CASE_SID" --cwd "$HOME_T/work/a2"
if [ "$TX_LAST_RC" -eq 2 ]; then
  case "$TX_LAST_ERR" in
    *"minutes old"* | *"30"*) ;;
    *) fail "A2: refusal did not mention the handoff's age/limit: $TX_LAST_ERR" ;;
  esac
else
  fail "A2: expected refuse (rc=2) with a 40-minute-old handoff, got rc=$TX_LAST_RC: $(tx_combined)"
fi

# --- A3: fresh handoff, wrong marker sid ---------------------------------------------------------
fresh_case A3 "$HOME_T/work/a3"
tx_write_handoff "$HOME_T/work/a3" "$CASE_SID" 0 "some-other-sid-entirely"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$CASE_SID" --cwd "$HOME_T/work/a3"
if [ "$TX_LAST_RC" -eq 2 ]; then
  case "$TX_LAST_ERR" in
    *"does not match"*) ;;
    *) fail "A3: refusal did not mention a marker/sid mismatch: $TX_LAST_ERR" ;;
  esac
else
  fail "A3: expected refuse (rc=2) with a mismatched marker sid, got rc=$TX_LAST_RC: $(tx_combined)"
fi

# --- A4: positive control -------------------------------------------------------------------------
fresh_case A4 "$HOME_T/work/a4"
tx_write_handoff "$HOME_T/work/a4" "$CASE_SID"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$CASE_SID" --cwd "$HOME_T/work/a4"
[ "$TX_LAST_RC" -eq 0 ] || fail "A4 (positive control): a fresh, correctly-marked handoff was refused: $(tx_combined)"

# --- A5: --dry-run with no handoff: informational, and the listing continues ---------------------
# /transfer --dry-run skips the handoff step, so a real run's handoff refusal must not end the dry
# run: it becomes one informational line, and the file list / sizes still print.
fresh_case A5 "$HOME_T/work/a5"
printf 'ctx\n' > "$HOME_T/work/a5/notes.txt"
DROP5="$HOME_T/drop-a5"
tx_run_send "$HOME_T" "$DROP5" --tool claude --sid "$CASE_SID" --cwd "$HOME_T/work/a5" --dry-run
[ "$TX_LAST_RC" -eq 0 ] || fail "A5: dry-run with no handoff exited $TX_LAST_RC (want 0; the handoff refusal is informational there): $(tx_combined)"
case "$TX_LAST_OUT" in
  *"A real run would refuse: no handoff"*) ;;
  *) fail "A5: dry-run did not print the informational 'A real run would refuse: no handoff' line: $TX_LAST_OUT" ;;
esac
case "$TX_LAST_OUT" in
  *"files:"*"10 largest:"*"$CASE_SID.jsonl"*) ;;
  *) fail "A5: dry-run stopped instead of listing the files and sizes: $TX_LAST_OUT" ;;
esac
[ -z "$(find "$DROP5" -type f 2>/dev/null)" ] || fail "A5: the dry run wrote into the drop folder"

ok_report "09-handoff-refusal" "missing handoff, a 40-minute-old handoff, and a mismatched marker sid are all refused with a specific reason; a fresh correct handoff still sends; --dry-run turns the handoff refusal into an informational line and keeps listing"
