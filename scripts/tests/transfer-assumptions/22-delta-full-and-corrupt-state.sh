#!/usr/bin/env bash
# 22 - DELTA SENDS fail safe toward sending MORE, and the format bump is enforced.
#
#   A  --full, with a valid state that would otherwise leave everything out: every ride-along file
#      ships, assumed_present is empty, full_reason is "--full"; the state is still rewritten after.
#   B  a corrupt state file (not JSON) -> full send ("unreadable or corrupt"); a state for another
#      repo root, and one with a malformed entry -> full send; an unreadable (mode 000) one -> full.
#   C  a sent state whose bundle the expiry sweep removed uncollected is forgotten (next send full).
#   D  resumework refuses a format-3 (older) and a format-5 (newer) bundle with the
#      "update the dotfiles on both Macs" message, changing nothing.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 22)
cleanup() { chmod -R u+rwX "$HOME_T" 2>/dev/null; rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

ROOT="$HOME_T/work/proj"
tx_init_origin "$HOME_T/origin.git" "$ROOT" >/dev/null
ROOT=$(cd -P "$ROOT" && pwd -P)
printf 'tmp/\n' > "$ROOT/.gitignore"; git -C "$ROOT" add .gitignore; git -C "$ROOT" commit -q -m ignore; git -C "$ROOT" push -q
mkdir -p "$ROOT/tmp"
for i in 1 2 3 4 5; do printf 'ride-along %s\n' "$i" > "$ROOT/tmp/r$i.md"; done
SID=$(tx_new_sid)
tx_write_transcript "$HOME_T" "$SID" "$ROOT"
SF=$(tx_state_path "$HOME_T" "$ROOT")

send_open() {  # send_open <tag> [send args...] -> manifest at $HOME_T/dec-<tag>/manifest.json
  local tag="$1"; shift
  tx_write_handoff "$ROOT" "$SID"
  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT" "$@"
  [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send $tag failed: $(tx_combined)" >&2; exit 3; }
  tx_open_bundle "$TX_LAST_CODE" "$TX_LAST_LOC" "$DROP" "$HOME_T/dec-$tag" || { echo "INFRA: cannot open bundle $tag" >&2; exit 3; }
  M="$HOME_T/dec-$tag/manifest.json"
}
collect() { tx_run_resume "$HOME_T" "$DROP" "$TX_LAST_CODE" --no-exec; [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: resume failed: $(tx_combined)" >&2; exit 3; }; }
n_ride_shipped() { tx_mget "$M" 'len([f for f in m["files"] if f["kind"] in ("context", "untracked")])'; }

send_open 0; collect                                          # baseline round trip -> a valid state
send_open 1; LOC1="$TX_LAST_LOC"
[ "$(tx_mget "$M" 'm["delta"]["mode"]')" = delta ] || { echo "INFRA: the control send was not a delta send" >&2; exit 3; }
[ "$(tx_mget "$M" 'len(m["assumed_present"])')" -ge 5 ] || { echo "INFRA: the control send assumed too little" >&2; exit 3; }
collect

# ---------------------------------------------------------------- A: --full
send_open A --full
[ "$(tx_mget "$M" 'm["delta"]["mode"]')" = full ] || fail "A: --full did not produce a full send"
[ "$(tx_mget "$M" 'm["delta"]["full_reason"]')" = "--full" ] || fail "A: full_reason is not --full"
[ "$(tx_mget "$M" 'len(m["assumed_present"])')" = 0 ] || fail "A: --full still assumed files present"
[ "$(n_ride_shipped)" -ge 5 ] || fail "A: --full did not ship every ride-along file"
[ "$(tx_mget "$SF" 'm["sent_locator"]')" = "$TX_LAST_LOC" ] || fail "A: the state was not rewritten after a --full send"
collect

# ---------------------------------------------------------------- B: corrupt / foreign / unreadable state
expect_full() {  # expect_full <label> <reason-substring>
  send_open "$1"
  [ "$(tx_mget "$M" 'm["delta"]["mode"]')" = full ] || fail "B($1): not a full send"
  case "$(tx_mget "$M" 'm["delta"]["full_reason"]')" in *"$2"*) ;; *) fail "B($1): full_reason lacks '$2': $(tx_mget "$M" 'm["delta"]["full_reason"]')" ;; esac
  [ "$(n_ride_shipped)" -ge 5 ] || fail "B($1): not every ride-along file shipped"
  case "$TX_LAST_ERR" in *"full send"*) ;; *) fail "B($1): the send summary does not say full send" ;; esac
  collect
}
printf '{ not json' > "$SF"; expect_full corrupt "unreadable or corrupt"
python3 - "$SF" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["root"] = "/somewhere/else"; json.dump(s, open(sys.argv[1], "w"))
PY
expect_full foreign "another repo root"
python3 - "$SF" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); k = next(iter(s["files"])); s["files"][k]["sha256"] = "nothex"; json.dump(s, open(sys.argv[1], "w"))
PY
expect_full badentry "bad entry"
chmod 000 "$SF"; expect_full unreadable "unreadable or corrupt"; chmod 600 "$SF" 2>/dev/null
[ "$(stat -f %Lp "$SF")" = 600 ] || fail "B: the state was not rewritten 600 after an unreadable one"

# ---------------------------------------------------------------- C: sweep forgets an uncollected send
send_open C; LOCC="$TX_LAST_LOC"
[ "$(tx_mget "$SF" 'm["sent_locator"]')" = "$LOCC" ] || { echo "INFRA: state does not carry send C's locator" >&2; exit 3; }
old=$(( $(date +%s) - 8 * 86400 ))
for f in "$DROP/$LOCC.tx" "$DROP/$LOCC.tx.sha256"; do python3 -c "import os,sys; os.utime(sys.argv[1], (float(sys.argv[2]),) * 2)" "$f" "$old"; done
( HOME="$HOME_T"; TX_DROP_DIR="$DROP"; tx_expire_sweep ) 2>/dev/null
[ -e "$DROP/$LOCC.tx" ] && { echo "INFRA: the sweep did not remove the aged bundle" >&2; exit 3; }
[ -e "$SF" ] && fail "C: the expiry sweep removed an uncollected bundle but kept the state that assumed it was delivered"

# ---------------------------------------------------------------- D: format 3 / 5 refused
send_open D
CD="$TX_LAST_CODE"; LD="$TX_LAST_LOC"
for fmt in 3 5; do
  W="$HOME_T/refmt-$fmt"; mkdir -p "$W"; ( cd "$W" && tar -xzf "$HOME_T/dec-D/inner.tgz" )
  python3 - "$W/manifest.json" "$fmt" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["format"] = int(sys.argv[2]); json.dump(m, open(sys.argv[1], "w"))
PY
  ( cd "$W" && COPYFILE_DISABLE=1 tar -czf "$W/inner.tgz" manifest.json payload git )
  tx_encrypt "$W/inner.tgz" "$DROP/$LD.tx" "$CD" || { echo "INFRA: re-encrypt failed" >&2; exit 3; }
  printf 'format=1\nsha256=%s\nsize=%s\n' "$(tx_sha "$DROP/$LD.tx")" "$(stat -f %z "$DROP/$LD.tx")" > "$DROP/$LD.tx.sha256"
  before=$(tx_sha "$ROOT/TRANSFER.$SID.md")
  tx_run_resume "$HOME_T" "$DROP" "$CD" --no-exec --wait 0
  [ "$TX_LAST_RC" -eq 2 ] || fail "D: a format-$fmt bundle was not refused (rc=$TX_LAST_RC)"
  case "$(tx_combined)" in *"unsupported bundle format $fmt"*"update the dotfiles on both Macs"*) ;; *) fail "D: format-$fmt refusal lacks the update-both-Macs message" ;; esac
  [ "$(tx_sha "$ROOT/TRANSFER.$SID.md")" = "$before" ] || fail "D: a refused format-$fmt bundle changed the TRANSFER notes"
done

ok_report "22-delta-full-and-corrupt-state" "--full ships everything and still records state; corrupt, foreign-root, bad-entry and unreadable states all fall back to a full send; the expiry sweep forgets a state whose bundle was never collected; format 3 and 5 bundles are refused with the update-both-Macs message"
