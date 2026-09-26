#!/usr/bin/env bash
# 02 - a Codex rollout plus its history_base PARENT round-trip to the same dated path under a
# sandboxed CODEX_HOME. Proves A2 (the parent-following collector) without touching the owner's
# real ~/.codex.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 02)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT

DROP="$HOME_T/drop"
CODEX_HOME="$HOME_T/.codex"
PARENT_ID=$(tx_new_uuid)
CHILD_ID=$(tx_new_uuid)
DATED="sessions/2026/01/15"
mkdir -p "$CODEX_HOME/$DATED"

PARENT_FILE="$CODEX_HOME/$DATED/rollout-2026-01-15T09-00-00-$PARENT_ID.jsonl"
CHILD_FILE="$CODEX_HOME/$DATED/rollout-2026-01-15T09-30-00-$CHILD_ID.jsonl"
python3 - "$PARENT_FILE" "$HOME_T/work" <<'PY'
import json, sys
path, cwd = sys.argv[1:3]
with open(path, "w") as fh:
    fh.write(json.dumps({"payload": {"cwd": cwd, "id": "parent"}}) + "\n")
    fh.write(json.dumps({"payload": {"content": "parent turn: base fact is ORANGE-99"}}) + "\n")
PY
python3 - "$CHILD_FILE" "$HOME_T/work" "$PARENT_ID" <<'PY'
import json, sys
path, cwd, parent = sys.argv[1:4]
with open(path, "w") as fh:
    fh.write(json.dumps({"payload": {"cwd": cwd, "id": "child", "history_base": parent}}) + "\n")
    fh.write(json.dumps({"payload": {"content": "child turn: continuing from ORANGE-99"}}) + "\n")
PY
mkdir -p "$HOME_T/work"

P_SHA=$(tx_sha "$PARENT_FILE"); P_MT=$(tx_mtime "$PARENT_FILE")
C_SHA=$(tx_sha "$CHILD_FILE"); C_MT=$(tx_mtime "$CHILD_FILE")

( export CODEX_HOME; HOME="$HOME_T" TX_DROP_DIR="$DROP" CODEX_HOME="$CODEX_HOME" "$TX_SEND" --tool codex --sid "$CHILD_ID" \
    >"$HOME_T/.send.out" 2>"$HOME_T/.send.err" )
RC=$?
OUT=$(cat "$HOME_T/.send.out"); ERR=$(cat "$HOME_T/.send.err")
[ "$RC" -eq 0 ] || { echo "INFRA: codex send failed (rc=$RC): $OUT $ERR" >&2; exit 3; }
CODE=$(printf '%s\n' "$OUT" | sed -n 's/^CODE=//p' | head -1)
LOC=$(printf '%s\n' "$OUT" | sed -n 's/^LOCATOR=//p' | head -1)
[ -n "$CODE" ] || { echo "INFRA: codex send printed no CODE: $OUT $ERR" >&2; exit 3; }
[ -f "$DROP/$LOC.tx" ] || { echo "INFRA: bundle missing after codex send" >&2; exit 3; }

rm -f "$PARENT_FILE" "$CHILD_FILE"

( HOME="$HOME_T" TX_DROP_DIR="$DROP" CODEX_HOME="$CODEX_HOME" "$TX_RESUME" "$CODE" --no-exec \
    >"$HOME_T/.recv.out" 2>"$HOME_T/.recv.err" )
RC=$?
OUT=$(cat "$HOME_T/.recv.out"); ERR=$(cat "$HOME_T/.recv.err")
if [ "$RC" -ne 0 ]; then
  fail "resumework exited $RC: $OUT $ERR"
else
  [ -f "$PARENT_FILE" ] || fail "history_base PARENT rollout was not restored at $PARENT_FILE"
  [ -f "$CHILD_FILE" ]  || fail "child rollout was not restored at $CHILD_FILE"
  if [ -f "$PARENT_FILE" ]; then
    [ "$(tx_sha "$PARENT_FILE")" = "$P_SHA" ] || fail "parent rollout content differs after restore"
    [ "$(tx_mtime "$PARENT_FILE")" = "$P_MT" ] || fail "parent rollout mtime not preserved"
    grep -q "ORANGE-99" "$PARENT_FILE" || fail "restored parent rollout lost its content marker"
  fi
  if [ -f "$CHILD_FILE" ]; then
    [ "$(tx_sha "$CHILD_FILE")" = "$C_SHA" ] || fail "child rollout content differs after restore"
    [ "$(tx_mtime "$CHILD_FILE")" = "$C_MT" ] || fail "child rollout mtime not preserved"
  fi
  [ -f "$DROP/$LOC.tx" ] && fail "codex bundle was not deleted after restore"
fi

ok_report "02-codex-roundtrip" "child rollout + history_base parent both restored byte-identical under a sandboxed CODEX_HOME"
