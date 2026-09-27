#!/usr/bin/env bash
# 21 - DELTA SENDS, receiver side: every assumed_present entry is checked, and a mismatch is reported,
#      never a failure and never touched.
#
#   After a first round trip (so the sender records what "B" has), A sends again; the bundle leaves
#   out tmp/same.md, tmp/gone.md, tmp/changed.md and tmp/linked.md. Then, on "B":
#     gone.md    deleted after the last transfer       -> "missing here", NOT recreated
#     changed.md edited here                           -> "differs here", B's content kept as is
#     linked.md  replaced by a symlink                 -> "differs here", the symlink left as is
#     same.md    untouched                             -> counted as verified identical
#   resumework exits 0, the dry run and the checklist name both kinds of mismatch, and TRANSFER.<sid>.md
#   carries the "Not re-sent (the other Mac assumed you already had it) - differs/missing here" list.
#   The state then records the SENDER's sha256 for every assumed file (what the sender holds).
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 21)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

ROOT="$HOME_T/work/proj"
tx_init_origin "$HOME_T/origin.git" "$ROOT" >/dev/null
ROOT=$(cd -P "$ROOT" && pwd -P)
printf 'tmp/\n' > "$ROOT/.gitignore"; git -C "$ROOT" add .gitignore; git -C "$ROOT" commit -q -m ignore; git -C "$ROOT" push -q
mkdir -p "$ROOT/tmp"
for n in same gone changed linked; do printf 'A copy of %s\n' "$n" > "$ROOT/tmp/$n.md"; done
SID=$(tx_new_sid)
tx_write_transcript "$HOME_T" "$SID" "$ROOT"
tx_write_handoff "$ROOT" "$SID"

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send 1 failed: $(tx_combined)" >&2; exit 3; }
tx_run_resume "$HOME_T" "$DROP" "$TX_LAST_CODE" --no-exec
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: resume 1 failed: $(tx_combined)" >&2; exit 3; }

tx_write_handoff "$ROOT" "$SID"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send 2 failed: $(tx_combined)" >&2; exit 3; }
C2="$TX_LAST_CODE"; L2="$TX_LAST_LOC"
tx_open_bundle "$C2" "$L2" "$DROP" "$HOME_T/dec2" || { echo "INFRA: cannot open bundle 2" >&2; exit 3; }
[ "$(tx_mget "$HOME_T/dec2/manifest.json" 'len(m["assumed_present"])')" = 4 ] \
  || { echo "INFRA: send 2 did not assume the 4 files present: $(tx_mget "$HOME_T/dec2/manifest.json" 'm["delta"]')" >&2; exit 3; }
A_SHA_GONE=$(tx_sha "$ROOT/tmp/gone.md")

# "B" drifts after the last transfer.
rm -f "$ROOT/tmp/gone.md"
printf 'B edited this\n' > "$ROOT/tmp/changed.md"; B_CHANGED=$(tx_sha "$ROOT/tmp/changed.md")
printf 'elsewhere\n' > "$HOME_T/elsewhere.md"; rm -f "$ROOT/tmp/linked.md"; ln -s "$HOME_T/elsewhere.md" "$ROOT/tmp/linked.md"

tx_run_resume "$HOME_T" "$DROP" "$C2" --dry-run
DRY=$(tx_combined)
case "$DRY" in *"1 identical here, 1 missing here, 2 different here"*) ;; *) fail "dry-run does not count 1 identical / 1 missing / 2 different: $(printf '%s' "$DRY" | grep -i 'not re-sent')" ;; esac
case "$DRY" in *"missing:   $ROOT/tmp/gone.md"*) ;; *) fail "dry-run does not name the missing file" ;; esac
case "$DRY" in *"different: $ROOT/tmp/changed.md"*) ;; *) fail "dry-run does not name the differing file" ;; esac

tx_run_resume "$HOME_T" "$DROP" "$C2" --no-exec
OUT=$(tx_combined)
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "resumework FAILED on assumed_present mismatches (rc=$TX_LAST_RC): $(printf '%s' "$OUT" | tr '\n' '|')"
else
  [ -e "$ROOT/tmp/gone.md" ] && fail "the missing assumed file was recreated (nothing carried its bytes)"
  [ "$(tx_sha "$ROOT/tmp/changed.md")" = "$B_CHANGED" ] || fail "the differing assumed file was touched"
  [ -L "$ROOT/tmp/linked.md" ] || fail "the symlink standing where an assumed file was is gone"
  [ "$(cat "$HOME_T/elsewhere.md")" = elsewhere ] || fail "the symlink's target was written through"
  ls "$ROOT/tmp" | grep -q 'changed.md\.\(bak\|from\)' && fail "a .bak/.from copy was made for an assumed file"
  case "$OUT" in *"Not re-sent (the other Mac assumed you already had it) - differs/missing here"*) ;; *) fail "the checklist does not carry the not-re-sent heading" ;; esac
  case "$OUT" in *"$ROOT/tmp/gone.md  (missing here)"*) ;; *) fail "the checklist does not name gone.md as missing here" ;; esac
  case "$OUT" in *"$ROOT/tmp/changed.md  (differs here)"*) ;; *) fail "the checklist does not name changed.md as differing here" ;; esac
  case "$OUT" in *"$ROOT/tmp/linked.md  (differs here)"*) ;; *) fail "the checklist does not name the symlinked linked.md as differing here" ;; esac
  case "$OUT" in *"4 ride-along file(s) were not re-sent"*"1 verified identical"*) ;; *) fail "the checklist does not count 1 of 4 verified identical" ;; esac
  TF="$ROOT/TRANSFER.$SID.md"
  grep -q "Not re-sent (the other Mac assumed you already had it) - differs/missing here" "$TF" || fail "TRANSFER notes lack the not-re-sent list"
  grep -qF "$ROOT/tmp/gone.md  (missing here)" "$TF" || fail "TRANSFER notes do not name gone.md"
  grep -qF "$ROOT/tmp/changed.md  (differs here)" "$TF" || fail "TRANSFER notes do not name changed.md"
  SF=$(tx_state_path "$HOME_T" "$ROOT")
  [ "$(tx_mget "$SF" 'm["role"]')" = receive ] || fail "the state after resumework is not role=receive"
  [ "$(tx_mget "$SF" 'm["files"]["'"$ROOT"'/tmp/gone.md"]["sha256"]')" = "$A_SHA_GONE" ] \
    || fail "the receiver state does not record the SENDER's sha256 for an assumed file"
fi

ok_report "21-assumed-present-report" "missing / edited / symlinked assumed files are reported (dry-run, checklist, TRANSFER notes), never fail the restore and are never touched; the identical one is counted; the receiver state records the sender's sha256"
