#!/usr/bin/env bash
# 06 - a wrong code, a tampered ciphertext, and a tampered inner file all fail safely and delete
# nothing.
#   A1 tx_decrypt itself, called with the right bundle but the WRONG code: rc 3, 0-byte output
#      removed (unit-level, the crypto-level "wrong code" case).
#   A2 resumework with a mistyped (different-locator) code: the bundle it was looking for is a
#      DIFFERENT file, so it correctly reports not-found; the ORIGINAL bundle is untouched.
#   A3 a single ciphertext byte flipped: the sidecar sha256 check catches it before decryption is
#      even attempted; refused, nothing deleted.
#   A4 the ciphertext round-trips fine (same code, correctly re-encrypted) but ONE inner payload
#      file's bytes were changed: the manifest's per-file sha256 catches it; refused, nothing
#      placed on B.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 06)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

SID=$(tx_new_sid)
CWD="$HOME_T/work/proj"
mkdir -p "$CWD"
tx_write_transcript "$HOME_T" "$SID" "$CWD"
tx_write_handoff "$CWD" "$SID"

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$CWD"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send failed: $(tx_combined)" >&2; exit 3; }
CODE="$TX_LAST_CODE"; LOC="$TX_LAST_LOC"
ORIG_TX_SHA=$(tx_sha "$DROP/$LOC.tx")
ORIG_SIDE_SHA=$(tx_sha "$DROP/$LOC.tx.sha256")

# --- A1: tx_decrypt with the WRONG code -----------------------------------------------------
WRONG_CODE="TX-0000-0000-0000-0001"
[ "$(tx_normalize "$WRONG_CODE")" != "$(tx_normalize "$CODE")" ] || { echo "INFRA: wrong code collided with the real one" >&2; exit 3; }
OUTFILE="$HOME_T/decrypt-attempt.tgz"
tx_decrypt "$DROP/$LOC.tx" "$OUTFILE" "$WRONG_CODE"
RC=$?
[ "$RC" -eq 3 ] || fail "A1: tx_decrypt with the wrong code returned rc=$RC, want 3"
[ -e "$OUTFILE" ] && fail "A1: tx_decrypt left a 0-byte (or any) output file behind on failure"

# --- A2: resumework, a mistyped code (different locator) ------------------------------------
tx_run_resume "$HOME_T" "$DROP" "$WRONG_CODE" --wait 1
[ "$TX_LAST_RC" -ne 0 ] || fail "A2: resumework succeeded with a wrong code"
case "$(tx_combined)" in
  *"not recognized"* | *"not found"*) ;;
  *) fail "A2: resumework's error did not say the code/bundle was not recognized: $(tx_combined | tr '\n' '|')" ;;
esac
[ "$(tx_sha "$DROP/$LOC.tx")" = "$ORIG_TX_SHA" ] || fail "A2: the ORIGINAL bundle was modified by a failed wrong-code attempt"
[ "$(tx_sha "$DROP/$LOC.tx.sha256")" = "$ORIG_SIDE_SHA" ] || fail "A2: the original sidecar was modified"

# --- A3: flip a ciphertext byte -------------------------------------------------------------
cp "$DROP/$LOC.tx" "$HOME_T/tx.saved"
python3 -c "
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(100)
    b = f.read(1)
    f.seek(100)
    f.write(bytes([b[0] ^ 0xFF]))
" "$DROP/$LOC.tx"
tx_run_resume "$HOME_T" "$DROP" "$CODE" --wait 5
[ "$TX_LAST_RC" -ne 0 ] || fail "A3: resumework succeeded against a tampered ciphertext"
case "$(tx_combined)" in
  *corrupt* | *checksum* | *altered*) ;;
  *) fail "A3: refusal did not mention corruption/checksum: $(tx_combined | tr '\n' '|')" ;;
esac
cp "$HOME_T/tx.saved" "$DROP/$LOC.tx"   # restore for A4

# --- A4: valid envelope (same code, correct sidecar), but ONE inner file was altered ---------
dec="$HOME_T/tamper-work"; mkdir -p "$dec"
tx_decrypt "$DROP/$LOC.tx" "$dec/inner.tgz" "$CODE" || { echo "INFRA(A4): decrypt failed" >&2; exit 3; }
( cd "$dec" && tar -xzf inner.tgz )
TARGET_REL=$(python3 -c "
import json
m = json.load(open('$dec/manifest.json'))
for f in m['files']:
    if f['kind'] == 'session' and f['path'].endswith('.jsonl'):
        print(f['path']); break
")
[ -n "$TARGET_REL" ] || { echo "INFRA(A4): could not find a session file in the manifest" >&2; exit 3; }
printf 'TAMPERED\n' >> "$dec/payload/$TARGET_REL"
( cd "$dec" && COPYFILE_DISABLE=1 tar -czf new-inner.tgz manifest.json payload git )
NEWTX="$HOME_T/new.tx"
tx_encrypt "$dec/new-inner.tgz" "$NEWTX" "$CODE" || { echo "INFRA(A4): re-encrypt failed" >&2; exit 3; }
NEWSHA=$(tx_sha "$NEWTX"); NEWSIZE=$(stat -f %z "$NEWTX")
cp "$NEWTX" "$DROP/$LOC.tx"
printf 'format=1\nsha256=%s\nsize=%s\n' "$NEWSHA" "$NEWSIZE" > "$DROP/$LOC.tx.sha256"

# On B, so a false PASS could not be explained by the original transcript still sitting there.
rm -f "$CWD"/*.jsonl 2>/dev/null
SLUG=$(tx_slug "$CWD")
rm -f "$HOME_T/.claude/projects/$SLUG/$SID.jsonl"

tx_run_resume "$HOME_T" "$DROP" "$CODE" --wait 5
[ "$TX_LAST_RC" -ne 0 ] || fail "A4: resumework succeeded despite a tampered inner file"
case "$(tx_combined)" in
  *checksum* | *altered* | *damaged*) ;;
  *) fail "A4: refusal did not mention a checksum/altered/damaged file: $(tx_combined | tr '\n' '|')" ;;
esac
[ -f "$HOME_T/.claude/projects/$SLUG/$SID.jsonl" ] && fail "A4: the tampered file was placed on B despite the manifest mismatch"
rm -rf "$dec"

ok_report "06-wrong-code-and-tamper" "wrong code (tx_decrypt rc3 + resumework not-found), tampered ciphertext (sidecar catch), tampered inner file (manifest sha256 catch) - all refuse, nothing changes"
