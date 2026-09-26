#!/usr/bin/env bash
# 04 - what travels and what never does (owner policy 2026-09-26: "just move everything"), proven
# both ways:
#   Part 1 (defaults): machine-bound state (auto-compact sentinel, mission liveness, a tick lock,
#     prod.lock, a pid file, a keychain file, a live unix socket) and heavy dirs (node_modules -
#     top-level and nested - dist, .next, coverage) are ALL absent from the bundle and absent on B
#     after a real restore. Everything else untracked or ignored DOES travel and lands
#     byte-identical on B: .env, tmp/ creds and .env files, a 30-day-old ignored tmp/ file (mtime
#     kept), an ignored file outside tmp/, an untracked yarn.lock. The secret-named files are
#     listed in the dry-run and in the manifest's secret_named_files_moved; excluded_secret_names
#     is empty. Another chat's sid-keyed handoff/TRANSFER files and a nested repo stay behind.
#   Part 2 (TX_TEST_DISABLE_EXCLUDES=1): the SAME machine-bound + heavy set, with the dev-only
#     knob, now DOES travel - watched failing, so the guard is proven real rather than vacuous.
#   Part 3: symlinks inside the repo that point OUTSIDE it (a file and a dir) are never followed.
#   Part 4: memory notes NAMED like secrets travel; secret-shaped CONTENT (in memory and in a repo
#     file) no longer refuses - the send succeeds, the manifest records file + rule (never the
#     text), and resumework lists the hits in TRANSFER.<sid>.md as FYI.
#   Part 5: the sanity caps - a file over the per-file cap is left out and listed, --force takes
#     it; a total over the cap refuses, --force sends.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 04)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

unpack() {  # unpack <code> <locator> <dir> - decrypt + untar a bundle for inspection
  mkdir -p "$3"
  tx_decrypt "$DROP/$2.tx" "$3/inner.tgz" "$1" || return 1
  ( cd "$3" && tar -xzf inner.tgz )
}
in_payload() {  # in_payload <unpacked> <repo dir> <relpath> - bundles store PHYSICAL paths (/private/var/...)
  local p
  p=$(cd -P "$2" 2>/dev/null && pwd -P) || p="$2"
  [ -e "$1/payload/abs$p/$3" ]
}
mjson() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2], {"m": m})))' "$1" "$2"; }

GITIGNORE='.env
tmp/
node_modules/
dist/
.next/
coverage/
*.pid
local-notes/
'

plant_machine_bound() {  # plant_machine_bound <wt> <sid> - the never-travel set (relative paths on stdout)
  local wt="$1" sid="$2"
  printf 'x\n' > "$wt/auto-compact-$sid.marker"
  printf 'x\n' > "$wt/mission-liveness-$sid.json"
  printf 'x\n' > "$wt/tick.$sid.lock"
  printf 'x\n' > "$wt/prod.lock"
  printf '4242\n' > "$wt/server.pid"
  printf 'kc\n' > "$wt/login.keychain-db"
  mkdir -p "$wt/node_modules/pkg" "$wt/client/node_modules/x" "$wt/dist" "$wt/.next" "$wt/coverage"
  printf 'module.exports = 1;\n' > "$wt/node_modules/pkg/index.js"
  printf 'module.exports = 2;\n' > "$wt/client/node_modules/x/y.js"
  printf 'bundle\n' > "$wt/dist/bundle.js"
  printf 'cache\n' > "$wt/.next/cache.txt"
  printf 'TN:\n' > "$wt/coverage/lcov.info"
  printf '%s\n' "auto-compact-$sid.marker" "mission-liveness-$sid.json" "tick.$sid.lock" "prod.lock" \
    "server.pid" "login.keychain-db" "node_modules/pkg/index.js" "client/node_modules/x/y.js" \
    "dist/bundle.js" ".next/cache.txt" "coverage/lcov.info"
}

# ------------------------------------------------------------------ Part 1: defaults
origin="$HOME_T/origin.git"; wt="$HOME_T/work/proj"
SID=$(tx_new_sid); OTHER=$(tx_new_sid)
tx_init_origin "$origin" "$wt" >/dev/null
printf '%s' "$GITIGNORE" > "$wt/.gitignore"
git -C "$wt" add .gitignore && git -C "$wt" commit -q -m ignore && git -C "$wt" push -q origin HEAD 2>/dev/null
NEVER=$(plant_machine_bound "$wt" "$SID")
python3 -c 'import os, socket, sys
os.makedirs(sys.argv[1], exist_ok=True); os.chdir(sys.argv[1])
socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).bind("dev.sock")' "$wt/tmp" \
  || { echo "INFRA(Part1): could not create a unix socket fixture" >&2; exit 3; }
NEVER="$NEVER
tmp/dev.sock"
mkdir -p "$wt/tmp/od-test" "$wt/tmp/telnyx" "$wt/local-notes/deep"
printf 'SECRET=abc123\n' > "$wt/.env"
printf 'od-creds-secret\n' > "$wt/tmp/od-test/creds.local.env"
printf 'telnyx-secret\n' > "$wt/tmp/telnyx/x-dev.env"
printf 'a month old\n' > "$wt/tmp/old-notes.md"
touch -t "$(date -v-30d '+%Y%m%d%H%M.%S')" "$wt/tmp/old-notes.md"
OLD_MT=$(tx_mtime "$wt/tmp/old-notes.md")
printf 'ignored, outside tmp\n' > "$wt/local-notes/deep/n.md"
printf 'untracked note\n' > "$wt/notes.txt"
printf '# yarn lockfile v1\n' > "$wt/yarn.lock"
TRAVEL=".env tmp/od-test/creds.local.env tmp/telnyx/x-dev.env tmp/old-notes.md local-notes/deep/n.md notes.txt yarn.lock"
printf 'other chat\n' > "$wt/CLAUDE.local.$OTHER.md"
printf 'other chat\n' > "$wt/TRANSFER.$OTHER.md"
mkdir -p "$wt/vendor-repo" && git -C "$wt/vendor-repo" init -q && printf 'nested\n' > "$wt/vendor-repo/nested-file.txt"
tx_write_handoff "$wt" "$SID"
tx_write_transcript "$HOME_T" "$SID" "$wt"
SAVE="$HOME_T/save1"; mkdir -p "$SAVE"
for r in $TRAVEL; do mkdir -p "$SAVE/$(dirname "$r")"; cp -p "$wt/$r" "$SAVE/$r"; done

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$wt" --dry-run
[ "$TX_LAST_RC" -eq 0 ] || fail "Part1: dry-run exited $TX_LAST_RC: $(tx_combined)"
DRY_OUT="$TX_LAST_OUT"
case "$DRY_OUT" in *"secret-named files that travel"*) ;; *) fail "Part1: dry-run has no 'secret-named files that travel' list" ;; esac
for n in "- .env" "- tmp/od-test/creds.local.env" "- tmp/telnyx/x-dev.env"; do
  case "$DRY_OUT" in *"$n"*) ;; *) fail "Part1: dry-run did not list '$n' as travelling" ;; esac
done
case "$DRY_OUT" in *"will NOT travel"*) fail "Part1: dry-run claims a secret-named file will not travel" ;; esac

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$wt"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA(Part1): send failed: $(tx_combined)" >&2; exit 3; }
CODE="$TX_LAST_CODE"; LOC="$TX_LAST_LOC"
dec="$HOME_T/decoy1"
unpack "$CODE" "$LOC" "$dec" || { echo "INFRA(Part1): decrypt failed" >&2; exit 3; }
while IFS= read -r r; do
  [ -n "$r" ] || continue
  in_payload "$dec" "$wt" "$r" && fail "Part1: machine-bound/heavy $r is inside the bundle (must never travel)"
done <<EOF
$NEVER
EOF
for r in $TRAVEL; do
  in_payload "$dec" "$wt" "$r" || fail "Part1: $r is missing from the bundle (everything untracked/ignored must travel)"
done
for r in "CLAUDE.local.$OTHER.md" "TRANSFER.$OTHER.md" "vendor-repo/nested-file.txt"; do
  in_payload "$dec" "$wt" "$r" && fail "Part1: $r (another chat's state / a nested repo) travelled"
done
M="$dec/manifest.json"
[ "$(mjson "$M" 'm["excluded_secret_names"]')" = "[]" ] || fail "Part1: excluded_secret_names is not empty: $(mjson "$M" 'm["excluded_secret_names"]')"
MOVED=$(mjson "$M" 'm["secret_named_files_moved"]')
for n in '".env"' '"tmp/od-test/creds.local.env"' '"tmp/telnyx/x-dev.env"'; do
  case "$MOVED" in *"$n"*) ;; *) fail "Part1: secret_named_files_moved lacks $n: $MOVED" ;; esac
done
case "$(mjson "$M" '[s["reason"] for s in m["skipped"]]')" in
  *other-chat-state*) ;; *) fail "Part1: the manifest does not record the other chat's files as other-chat-state" ;;
esac
rm -rf "$dec"

mv "$wt" "$wt.A-final"
git clone -q "$origin" "$wt" 2>/dev/null
tx_run_resume "$HOME_T" "$DROP" "$CODE" --no-exec
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA(Part1): resumework failed: $(tx_combined)" >&2; exit 3; }
while IFS= read -r r; do
  [ -n "$r" ] || continue
  { [ -e "$wt/$r" ] || [ -S "$wt/$r" ]; } && fail "Part1: machine-bound/heavy $r was restored on B"
done <<EOF
$NEVER
EOF
for r in $TRAVEL; do
  if [ ! -f "$wt/$r" ]; then fail "Part1: $r was not restored on B"
  elif [ "$(tx_sha "$wt/$r")" != "$(tx_sha "$SAVE/$r")" ]; then fail "Part1: $r differs on B"
  fi
done
[ "$(tx_mtime "$wt/tmp/old-notes.md")" = "$OLD_MT" ] || fail "Part1: the 30-day-old tmp/ file's mtime was not preserved"
grep -q 'Secret-named files that travelled' "$wt/TRANSFER.$SID.md" 2>/dev/null \
  || fail "Part1: TRANSFER.$SID.md does not list the secret-named files that travelled"
grep -q 'did NOT travel' "$wt/TRANSFER.$SID.md" 2>/dev/null && fail "Part1: TRANSFER.$SID.md claims a secret-named file did not travel"

# ------------------------------------------------------------------ Part 2: excludes disabled
origin2="$HOME_T/origin2.git"; wt2="$HOME_T/work/proj2"
SID2=$(tx_new_sid)
tx_init_origin "$origin2" "$wt2" >/dev/null
printf '%s' "$GITIGNORE" > "$wt2/.gitignore"
git -C "$wt2" add .gitignore && git -C "$wt2" commit -q -m ignore && git -C "$wt2" push -q origin HEAD 2>/dev/null
NEVER2=$(plant_machine_bound "$wt2" "$SID2")
tx_write_handoff "$wt2" "$SID2"
tx_write_transcript "$HOME_T" "$SID2" "$wt2"
( HOME="$HOME_T" TX_DROP_DIR="$DROP" TRANSFER_TESTS_ALLOW_DEV=true TX_TEST_DISABLE_EXCLUDES=1 \
    "$TX_SEND" --tool claude --sid "$SID2" --cwd "$wt2" >"$HOME_T/.p2.out" 2>"$HOME_T/.p2.err" )
RC=$?
OUT2=$(cat "$HOME_T/.p2.out"); ERR2=$(cat "$HOME_T/.p2.err")
if [ "$RC" -ne 0 ]; then
  fail "Part2: send with excludes disabled unexpectedly refused/errored (rc=$RC): $OUT2 $ERR2"
else
  CODE2=$(printf '%s\n' "$OUT2" | sed -n 's/^CODE=//p' | head -1)
  LOC2=$(printf '%s\n' "$OUT2" | sed -n 's/^LOCATOR=//p' | head -1)
  dec2="$HOME_T/decoy2"
  if unpack "$CODE2" "$LOC2" "$dec2" 2>/dev/null; then
    want=0; found=0
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      want=$((want + 1))
      in_payload "$dec2" "$wt2" "$r" && found=$((found + 1))
    done <<EOF
$NEVER2
EOF
    [ "$found" -eq "$want" ] || fail "Part2 (negative control): with excludes disabled, expected all $want planted machine-bound/heavy files to be included but only $found were - the guard's test-only bypass may itself be broken"
  else
    fail "Part2: INFRA - could not decrypt the excludes-disabled bundle"
  fi
  rm -rf "$dec2"
fi

# ------------------------------------------------------------------ Part 3: symlinks never followed
origin3="$HOME_T/origin3.git"; wt3="$HOME_T/work/proj3"
SID3=$(tx_new_sid)
tx_init_origin "$origin3" "$wt3" >/dev/null
mkdir -p "$wt3/tmp" "$HOME_T/outside-dir-3"
printf 'outside the repo\n' > "$HOME_T/outside-3.txt"
printf 'outside the repo too\n' > "$HOME_T/outside-dir-3/inside-3.txt"
ln -s "$HOME_T/outside-3.txt" "$wt3/tmp/escape-link"
ln -s "$HOME_T/outside-dir-3" "$wt3/tmp/escape-dir"
printf 'see tmp/../../outside-3.txt and tmp/ok-3.md\n' > "$wt3/TRANSFER.$SID3.md"
printf 'fine\n' > "$wt3/tmp/ok-3.md"
tx_write_handoff "$wt3" "$SID3"
tx_write_transcript "$HOME_T" "$SID3" "$wt3"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID3" --cwd "$wt3"
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "Part3: send failed: $(tx_combined)"
else
  dec3="$HOME_T/decoy3"
  unpack "$TX_LAST_CODE" "$TX_LAST_LOC" "$dec3" || { echo "INFRA(Part3): decrypt failed" >&2; exit 3; }
  for n in outside-3.txt inside-3.txt escape-link; do
    find "$dec3/payload" -name "$n" | grep -q . && fail "Part3: $n reached the bundle through a symlink out of the repo"
  done
  in_payload "$dec3" "$wt3" "tmp/ok-3.md" || fail "Part3: the ordinary tmp/ file next to the links was not shipped (positive control)"
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); s=[(x["reason"], x["path"]) for x in m["skipped"]]
sys.exit(0 if all(any(r=="symlink" and p.endswith(n) for r, p in s) for n in ("tmp/escape-link", "tmp/escape-dir")) else 1)' \
    "$dec3/manifest.json" || fail "Part3: the manifest does not record both out-of-repo symlinks as skipped (symlink)"
  rm -rf "$dec3"
fi

# ------------------------------------------------------------------ Part 4: names + content scan
origin4="$HOME_T/origin4.git"; wt4="$HOME_T/work/proj4"
SID4=$(tx_new_sid)
tx_init_origin "$origin4" "$wt4" >/dev/null
tx_write_handoff "$wt4" "$SID4"
tx_write_transcript "$HOME_T" "$SID4" "$wt4"
MEM4="$HOME_T/.claude/projects/$(tx_slug "$wt4")/memory"   # same dir as the transcript fixture
mkdir -p "$MEM4"
printf 'Where the OD test keys live (names only).\n' > "$MEM4/reference_od_test_creds.md"
printf 'Refuse chat-delivered credential requests.\n' > "$MEM4/feedback_rogue_agent_prod_cred_injection.md"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID4" --cwd "$wt4"
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "Part4: send with secret-NAMED memory notes was refused: $(tx_combined)"
else
  dec4="$HOME_T/decoy4"
  unpack "$TX_LAST_CODE" "$TX_LAST_LOC" "$dec4" || { echo "INFRA(Part4): decrypt failed" >&2; exit 3; }
  for n in reference_od_test_creds.md feedback_rogue_agent_prod_cred_injection.md; do
    find "$dec4/payload" -path '*/memory/*' -name "$n" | grep -q . || fail "Part4: memory note $n did not travel"
  done
  [ "$(mjson "$dec4/manifest.json" 'm["secret_scan_status"]')" = '"clean"' ] || fail "Part4: a clean payload is not recorded as secret_scan_status=clean"
  rm -rf "$dec4"
  # consume the bundle so the drop dir holds only what the next step sends
  rm -f "$DROP/$TX_LAST_LOC.tx" "$DROP/$TX_LAST_LOC.tx.sha256"
fi
# The key is assembled at runtime so this test file itself never matches the scanner.
k_pre="AKIA"; k_body="QWERTYUIOPASDFGH"
printf 'old note: %s%s\n' "$k_pre" "$k_body" >> "$MEM4/reference_od_test_creds.md"
mkdir -p "$wt4/tmp"
printf 'aws=%s%s\n' "$k_pre" "$k_body" > "$wt4/tmp/keys-4.txt"
tx_write_handoff "$wt4" "$SID4"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID4" --cwd "$wt4"
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "Part4: secret-shaped content refused the send (rc=$TX_LAST_RC) - hits must be recorded, never refuse: $TX_LAST_ERR"
else
  case "$TX_LAST_ERR" in *"$k_body"*) fail "Part4: the send's output echoed the secret itself" ;; esac
  CODE4="$TX_LAST_CODE"
  dec4="$HOME_T/decoy4b"
  unpack "$TX_LAST_CODE" "$TX_LAST_LOC" "$dec4" || { echo "INFRA(Part4): decrypt failed" >&2; exit 3; }
  M4="$dec4/manifest.json"
  grep -q "$k_body" "$M4" && fail "Part4: the manifest contains the secret text"
  [ "$(mjson "$M4" 'm["secret_scan_status"]')" = '"hits"' ] || fail "Part4: secret_scan_status is not hits: $(mjson "$M4" 'm.get("secret_scan_status")')"
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["secret_scan_hits"]
ok = lambda n: any(x["file"].endswith(n) and x["rule"] == "AWS access key id" for x in h)
sys.exit(0 if ok("memory/reference_od_test_creds.md") and ok("tmp/keys-4.txt") else 1)' "$M4" \
    || fail "Part4: secret_scan_hits does not record both files with rule 'AWS access key id': $(mjson "$M4" 'm["secret_scan_hits"]')"
  in_payload "$dec4" "$wt4" "tmp/keys-4.txt" || fail "Part4: the repo file with a scanner hit did not travel"
  rm -rf "$dec4"
  mv "$wt4" "$wt4.A-final"
  git clone -q "$origin4" "$wt4" 2>/dev/null
  tx_run_resume "$HOME_T" "$DROP" "$CODE4" --no-exec
  if [ "$TX_LAST_RC" -ne 0 ]; then
    fail "Part4: resumework failed: $(tx_combined)"
  else
    TF4="$wt4/TRANSFER.$SID4.md"
    grep -q 'Secret-scan hits' "$TF4" 2>/dev/null || fail "Part4: TRANSFER notes have no 'Secret-scan hits' FYI section"
    grep -q 'reference_od_test_creds.md  (AWS access key id)' "$TF4" 2>/dev/null \
      || fail "Part4: TRANSFER notes do not list the memory note's hit with its rule"
    grep -q 'tmp/keys-4.txt  (AWS access key id)' "$TF4" 2>/dev/null \
      || fail "Part4: TRANSFER notes do not list the repo file's hit with its rule"
    grep -q "$k_body" "$TF4" 2>/dev/null && fail "Part4: the TRANSFER notes contain the secret text"
    [ "$(cat "$wt4/tmp/keys-4.txt" 2>/dev/null)" = "aws=$k_pre$k_body" ] || fail "Part4: the repo file with the hit was not restored as-is"
  fi
fi

# ------------------------------------------------------------------ Part 5: sanity caps
origin5="$HOME_T/origin5.git"; wt5="$HOME_T/work/proj5"
SID5=$(tx_new_sid)
tx_init_origin "$origin5" "$wt5" >/dev/null
mkdir -p "$wt5/tmp"
python3 -c 'import sys; open(sys.argv[1], "w").write("b" * 5000)' "$wt5/tmp/big-5.bin"
printf 'small\n' > "$wt5/tmp/small-5.txt"
tx_write_handoff "$wt5" "$SID5"
tx_write_transcript "$HOME_T" "$SID5" "$wt5"
send5() { ( HOME="$HOME_T" TX_DROP_DIR="$DROP" TRANSFER_TESTS_ALLOW_DEV=true "$@" "$TX_SEND" --tool claude --sid "$SID5" --cwd "$wt5" $SEND5_ARGS >"$HOME_T/.p5.out" 2>"$HOME_T/.p5.err" ); }
SEND5_ARGS="--dry-run"; send5 env TX_TEST_FILE_CAP_BYTES=1000
grep -q 'over the per-file cap' "$HOME_T/.p5.out" && grep -q 'big-5.bin' "$HOME_T/.p5.out" \
  || fail "Part5: dry-run does not list the file over the per-file cap: $(cat "$HOME_T/.p5.out")"
SEND5_ARGS=""; send5 env TX_TEST_FILE_CAP_BYTES=1000
if [ $? -ne 0 ]; then fail "Part5: a file over the per-file cap refused the send: $(cat "$HOME_T/.p5.err")"
else
  c=$(sed -n 's/^CODE=//p' "$HOME_T/.p5.out"); l=$(sed -n 's/^LOCATOR=//p' "$HOME_T/.p5.out")
  unpack "$c" "$l" "$HOME_T/decoy5" || { echo "INFRA(Part5): decrypt failed" >&2; exit 3; }
  in_payload "$HOME_T/decoy5" "$wt5" "tmp/big-5.bin" && fail "Part5: the file over the per-file cap travelled without --force"
  in_payload "$HOME_T/decoy5" "$wt5" "tmp/small-5.txt" || fail "Part5: the small file next to it did not travel"
  rm -rf "$HOME_T/decoy5"; rm -f "$DROP/$l.tx" "$DROP/$l.tx.sha256"
fi
tx_write_handoff "$wt5" "$SID5"
SEND5_ARGS="--force"; send5 env TX_TEST_FILE_CAP_BYTES=1000
if [ $? -ne 0 ]; then fail "Part5: --force send failed: $(cat "$HOME_T/.p5.err")"
else
  c=$(sed -n 's/^CODE=//p' "$HOME_T/.p5.out"); l=$(sed -n 's/^LOCATOR=//p' "$HOME_T/.p5.out")
  unpack "$c" "$l" "$HOME_T/decoy5" || { echo "INFRA(Part5): decrypt failed" >&2; exit 3; }
  in_payload "$HOME_T/decoy5" "$wt5" "tmp/big-5.bin" || fail "Part5: --force did not include the file over the per-file cap"
  rm -rf "$HOME_T/decoy5"; rm -f "$DROP/$l.tx" "$DROP/$l.tx.sha256"
fi
tx_write_handoff "$wt5" "$SID5"
SEND5_ARGS=""; send5 env TX_TEST_TOTAL_CAP_BYTES=3000
RC5=$?
[ "$RC5" -eq 2 ] || fail "Part5: a total over the cap did not refuse (rc=$RC5)"
grep -q 'cap' "$HOME_T/.p5.err" || fail "Part5: the total-cap refusal does not say why: $(cat "$HOME_T/.p5.err")"
SEND5_ARGS="--force"; send5 env TX_TEST_TOTAL_CAP_BYTES=3000
[ $? -eq 0 ] || fail "Part5: --force did not override the total cap: $(cat "$HOME_T/.p5.err")"

ok_report "04-exclusions-negative-control" "machine-bound state (sentinel/liveness/locks/pid/keychain/socket) and heavy dirs never travel, while .env/creds/old and ignored files travel byte-identical and are named in the manifest; the excludes-disabled dev knob demonstrably lets the never-travel set through; out-of-repo symlinks are not followed; scanner hits never refuse and are recorded as file + rule in the manifest and the TRANSFER notes; per-file and total caps hold and --force lifts them"
