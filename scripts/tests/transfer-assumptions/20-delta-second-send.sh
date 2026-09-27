#!/usr/bin/env bash
# 20 - DELTA SENDS: a second send leaves out the ride-along files the other Mac already has.
#
#   A  first send from a repo: full ("no record yet"), every ride-along file ships, assumed_present
#      is empty; resumework then records the sender's files in ~/.claude/transfer-state (dir 700,
#      file 600, role=receive).
#   B  second send: unchanged ignored ("context") AND untracked ("untracked") files are NOT in the
#      bundle and are listed under assumed_present with their sha256 + size; a changed file and a new
#      file DO ship; the send summary says how many files/bytes were left out; the state now says
#      role=send with this send's locator. resumework restores it cleanly and says how many it
#      verified identical.
#   C  the previous send was never collected (its bundle is still in the drop folder) -> the next
#      send is a full one and says why.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 20)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

ROOT="$HOME_T/work/proj"
tx_init_origin "$HOME_T/origin.git" "$ROOT" >/dev/null
ROOT=$(cd -P "$ROOT" && pwd -P)
printf 'tmp/\n' > "$ROOT/.gitignore"; git -C "$ROOT" add .gitignore; git -C "$ROOT" commit -q -m ignore; git -C "$ROOT" push -q
mkdir -p "$ROOT/tmp"
for i in 01 02 03 04 05 06 07 08 09 10; do
  python3 -c "import os,sys; open(sys.argv[1],'wb').write(os.urandom(4096))" "$ROOT/tmp/f$i.bin"
done
printf 'untracked notes\n' > "$ROOT/notes.txt"
printf 'DB_PASSWORD=x\n' > "$ROOT/.env.local"

SID=$(tx_new_sid)
tx_write_transcript "$HOME_T" "$SID" "$ROOT"
tx_write_handoff "$ROOT" "$SID"

# ---------------------------------------------------------------- A: first send is full
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send 1 failed: $(tx_combined)" >&2; exit 3; }
C1="$TX_LAST_CODE"; L1="$TX_LAST_LOC"
tx_open_bundle "$C1" "$L1" "$DROP" "$HOME_T/dec1" || { echo "INFRA: cannot open bundle 1" >&2; exit 3; }
M1="$HOME_T/dec1/manifest.json"
[ "$(tx_mget "$M1" 'm["format"]')" = 4 ] || fail "A: manifest format is not 4"
[ "$(tx_mget "$M1" 'm["delta"]["mode"]')" = full ] || fail "A: the first send is not a full send"
case "$(tx_mget "$M1" 'm["delta"]["full_reason"]')" in *"no record"*) ;; *) fail "A: the first send's full_reason does not say there is no record yet" ;; esac
[ "$(tx_mget "$M1" 'len(m["assumed_present"])')" = 0 ] || fail "A: the first send assumed files present"
[ "$(tx_mget "$M1" 'len([f for f in m["files"] if f.get("abs","").startswith("'"$ROOT"'/tmp/f")])')" = 10 ] \
  || fail "A: not every ride-along file shipped on the first send"
case "$TX_LAST_ERR" in *"full send"*) ;; *) fail "A: the send summary does not say it was a full send" ;; esac

tx_run_resume "$HOME_T" "$DROP" "$C1" --no-exec
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: resume 1 failed: $(tx_combined)" >&2; exit 3; }
SF=$(tx_state_path "$HOME_T" "$ROOT")
if [ ! -f "$SF" ]; then
  fail "A: resumework wrote no delta state at $SF"
else
  [ "$(stat -f %Lp "$SF")" = 600 ] || fail "A: the state file is not mode 600 ($(stat -f %Lp "$SF"))"
  [ "$(stat -f %Lp "$(dirname "$SF")")" = 700 ] || fail "A: the state dir is not mode 700"
  [ "$(tx_mget "$SF" 'm["role"]')" = receive ] || fail "A: the state after resumework is not role=receive"
  [ "$(tx_mget "$SF" 'm["root"]')" = "$ROOT" ] || fail "A: the state does not name the repo root"
  [ "$(tx_mget "$SF" 'm["files"]["'"$ROOT"'/tmp/f03.bin"]["sha256"]')" = "$(tx_sha "$ROOT/tmp/f03.bin")" ] \
    || fail "A: the state does not record tmp/f03.bin's sha256"
  case "$SF" in "$HOME_T/.claude/transfer-state/"*) ;; *) fail "A: the state is not under ~/.claude/transfer-state" ;; esac
fi

# ---------------------------------------------------------------- B: second send is a delta
python3 -c "import os,sys; open(sys.argv[1],'wb').write(os.urandom(4096))" "$ROOT/tmp/f01.bin"   # changed
printf 'brand new\n' > "$ROOT/tmp/new.md"                                                        # new
tx_write_handoff "$ROOT" "$SID"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send 2 failed: $(tx_combined)" >&2; exit 3; }
C2="$TX_LAST_CODE"; L2="$TX_LAST_LOC"; ERR2="$TX_LAST_ERR"
tx_open_bundle "$C2" "$L2" "$DROP" "$HOME_T/dec2" || { echo "INFRA: cannot open bundle 2" >&2; exit 3; }
M2="$HOME_T/dec2/manifest.json"
shipped() { tx_mget "$M2" '"'"$1"'" in [f.get("abs") for f in m["files"]]'; }
assumed() { tx_mget "$M2" '"'"$1"'" in [a["path"] for a in m["assumed_present"]]'; }
[ "$(tx_mget "$M2" 'm["delta"]["mode"]')" = delta ] || fail "B: the second send is not a delta send ($(tx_mget "$M2" 'm["delta"]'))"
for i in 02 03 04 05 06 07 08 09 10; do
  [ "$(shipped "$ROOT/tmp/f$i.bin")" = False ] || fail "B: unchanged tmp/f$i.bin was shipped again"
  [ "$(assumed "$ROOT/tmp/f$i.bin")" = True ] || fail "B: unchanged tmp/f$i.bin is not listed in assumed_present"
  [ -e "$HOME_T/dec2/payload/abs$ROOT/tmp/f$i.bin" ] && fail "B: tmp/f$i.bin is in the payload"
done
[ "$(assumed "$ROOT/notes.txt")" = True ] || fail "B: the unchanged untracked file is not assumed present"
[ "$(assumed "$ROOT/.env.local")" = True ] || fail "B: the unchanged .env.local is not assumed present"
[ "$(shipped "$ROOT/tmp/f01.bin")" = True ] || fail "B: the changed tmp/f01.bin did not ship"
[ "$(shipped "$ROOT/tmp/new.md")" = True ] || fail "B: the new tmp/new.md did not ship"
[ "$(tx_mget "$M2" '[a for a in m["assumed_present"] if a["path"].endswith("/tmp/f05.bin")][0]["sha256"]')" = "$(tx_sha "$ROOT/tmp/f05.bin")" ] \
  || fail "B: assumed_present does not carry the file's sha256"
[ "$(tx_mget "$M2" '[a for a in m["assumed_present"] if a["path"].endswith("/tmp/f05.bin")][0]["size"]')" = 4096 ] \
  || fail "B: assumed_present does not carry the file's size"
[ "$(tx_mget "$M2" '".env.local" in m["secret_named_files_moved"] and ".env.local" not in m["excluded_secret_names"]')" = True ] \
  || fail "B: an assumed-present secret-named file is reported as one to reload"
case "$ERR2" in *"delta send"*"11 ride-along file(s)"*"not re-sent"*) ;; *) fail "B: the send summary does not report the 11 files left out: $(printf '%s' "$ERR2" | grep -i delta)" ;; esac
[ "$(tx_mget "$SF" 'm["role"]')" = send ] || fail "B: the state after send 2 is not role=send"
[ "$(tx_mget "$SF" 'm["sent_locator"]')" = "$L2" ] || fail "B: the state does not carry send 2's locator"
[ "$(tx_mget "$SF" 'm["files"]["'"$ROOT"'/tmp/f01.bin"]["sha256"]')" = "$(tx_sha "$ROOT/tmp/f01.bin")" ] \
  || fail "B: the state does not record the changed file's new sha256"

tx_run_resume "$HOME_T" "$DROP" "$C2" --no-exec
if [ "$TX_LAST_RC" -ne 0 ]; then fail "B: resume 2 exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"
else
  case "$(tx_combined)" in *"11 ride-along file(s) were not re-sent"*"11 verified identical"*) ;; *) fail "B: resumework does not report 11 files verified identical" ;; esac
  case "$(tx_combined)" in *"differs/missing here"*) fail "B: resumework reports differing/missing files when all were identical" ;; esac
fi

# ---------------------------------------------------------------- C: uncollected previous send
tx_write_handoff "$ROOT" "$SID"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send 3 failed: $(tx_combined)" >&2; exit 3; }
L3="$TX_LAST_LOC"
[ -f "$DROP/$L3.tx" ] || { echo "INFRA: bundle 3 missing" >&2; exit 3; }
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send 4 failed: $(tx_combined)" >&2; exit 3; }
tx_open_bundle "$TX_LAST_CODE" "$TX_LAST_LOC" "$DROP" "$HOME_T/dec4" || { echo "INFRA: cannot open bundle 4" >&2; exit 3; }
[ "$(tx_mget "$HOME_T/dec4/manifest.json" 'm["delta"]["mode"]')" = full ] || fail "C: a send after an uncollected send was not full"
case "$(tx_mget "$HOME_T/dec4/manifest.json" 'm["delta"]["full_reason"]')" in *"never collected"*) ;; *) fail "C: the full_reason does not say the previous send was never collected" ;; esac

ok_report "20-delta-second-send" "first send full + receiver state 600/700; second send leaves unchanged context/untracked/.env files out (assumed_present with sha256+size), ships changed + new files, summary counts them, receiver verifies all identical; an uncollected previous send forces a full send"
