#!/usr/bin/env bash
# 10 - tx_expire_sweep deletes uncollected bundle files (and their sidecars/failure markers)
# older than 7 days, and leaves anything newer alone.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 10)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"
mkdir -p "$DROP"

age_days() {  # age_days <file> <days>
  local secs
  secs=$(( $(date +%s) - ($2 * 86400) ))
  python3 -c "import os,sys; os.utime(sys.argv[1], (float(sys.argv[2]), float(sys.argv[2])))" "$1" "$secs"
}

OLD_TX="$DROP/oldloc0000000000.tx"
OLD_SIDE="$DROP/oldloc0000000000.tx.sha256"
OLD_FAIL="$DROP/oldloc1111111111.tx.failed"
NEW_TX="$DROP/newloc2222222222.tx"
NEW_SIDE="$DROP/newloc2222222222.tx.sha256"

printf 'old ciphertext\n' > "$OLD_TX"
printf 'format=1\nsha256=x\nsize=1\n' > "$OLD_SIDE"
printf 'reason=test\n' > "$OLD_FAIL"
printf 'new ciphertext\n' > "$NEW_TX"
printf 'format=1\nsha256=x\nsize=1\n' > "$NEW_SIDE"

for f in "$OLD_TX" "$OLD_SIDE" "$OLD_FAIL"; do age_days "$f" 8; done
for f in "$NEW_TX" "$NEW_SIDE"; do age_days "$f" 1; done

( HOME="$HOME_T" TX_DROP_DIR="$DROP" tx_expire_sweep ) 2>"$HOME_T/sweep.err"
SWEEP_ERR=$(cat "$HOME_T/sweep.err")

[ -f "$OLD_TX" ]   && fail "an 8-day-old bundle was not swept"
[ -f "$OLD_SIDE" ] && fail "an 8-day-old sidecar was not swept"
[ -f "$OLD_FAIL" ] && fail "an 8-day-old .tx.failed marker was not swept"
[ -f "$NEW_TX" ]   || fail "a 1-day-old bundle was swept (should have been kept)"
[ -f "$NEW_SIDE" ] || fail "a 1-day-old sidecar was swept (should have been kept)"

case "$SWEEP_ERR" in
  *"expired"*) ;;
  *) fail "tx_expire_sweep logged nothing about what it removed: $SWEEP_ERR" ;;
esac

LOG="$HOME_T/.claude/logs/transfer.log"
if [ -f "$LOG" ]; then
  grep -q "expire:" "$LOG" || fail "transfer.log has no expire: entries"
else
  fail "tx_log wrote nothing to $LOG during the sweep"
fi

ok_report "10-expiry-sweep" "8-day-old bundle/sidecar/.tx.failed swept, 1-day-old bundle kept, swept files logged"
