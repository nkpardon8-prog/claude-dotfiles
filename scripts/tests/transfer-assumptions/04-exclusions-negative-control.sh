#!/usr/bin/env bash
# 04 - what never travels, proven both ways:
#   Part 1 (defaults): auto-compact/mission-liveness/lock/tick-lock/node_modules/.env and two
#     tmp/ secret files are ALL absent from the bundle and absent on B after a real restore; the
#     .env-shaped names are surfaced in the dry-run's "left behind" list.
#   Part 2 (TX_TEST_DISABLE_EXCLUDES=1, non-secret set only): the SAME defense, disabled under the
#     dev-only test knob, now lets the non-secret planted files through - watched failing once, so
#     the guard is proven real rather than vacuous. (The secret-named files are exercised
#     separately since disabling the name filter still leaves the independent secret-scan refusing
#     the whole send - see the assertion below.)
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 04)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

plant() {  # plant <wt> - every excluded artifact, plus tmp/ secret files, as untracked content
  local wt="$1"
  printf 'x\n' > "$wt/auto-compact-$SID.marker"
  printf 'x\n' > "$wt/mission-liveness-$SID.json"
  printf 'x\n' > "$wt/tick.$SID.lock"
  printf 'x\n' > "$wt/prod.lock"
  mkdir -p "$wt/node_modules/pkg"
  printf 'module.exports = 1;\n' > "$wt/node_modules/pkg/index.js"
  printf 'SECRET=abc123\n' > "$wt/.env"
  mkdir -p "$wt/tmp/od-test" "$wt/tmp/telnyx"
  printf 'od-creds-secret\n' > "$wt/tmp/od-test/creds.local.env"
  printf 'telnyx-secret\n' > "$wt/tmp/telnyx/x-dev.env"
}

# ------------------------------------------------------------------ Part 1: defaults, exclusions ON
origin="$HOME_T/origin.git"; wt="$HOME_T/work/proj"
SID=$(tx_new_sid)
tx_init_origin "$origin" "$wt" >/dev/null
plant "$wt"
tx_write_handoff "$wt" "$SID"
tx_write_transcript "$HOME_T" "$SID" "$wt"

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$wt" --dry-run
DRY_OUT="$TX_LAST_OUT"
case "$DRY_OUT" in
  *"tmp/od-test/creds.local.env"*) ;;
  *) fail "Part1: dry-run did not list tmp/od-test/creds.local.env as left-behind" ;;
esac
case "$DRY_OUT" in
  *"tmp/telnyx/x-dev.env"*) ;;
  *) fail "Part1: dry-run did not list tmp/telnyx/x-dev.env as left-behind" ;;
esac
case "$DRY_OUT" in
  *".env"*) ;;
  *) fail "Part1: dry-run did not list .env as left-behind" ;;
esac

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$wt"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA(Part1): send failed: $(tx_combined)" >&2; exit 3; }
CODE="$TX_LAST_CODE"; LOC="$TX_LAST_LOC"

dec="$HOME_T/decoy1"; mkdir -p "$dec"
tx_decrypt "$DROP/$LOC.tx" "$dec/inner.tgz" "$CODE" || { echo "INFRA(Part1): decrypt failed" >&2; exit 3; }
( cd "$dec" && tar -xzf inner.tgz )
for name in "auto-compact-$SID.marker" "mission-liveness-$SID.json" "tick.$SID.lock" "prod.lock" \
            "node_modules/pkg/index.js" ".env" "tmp/od-test/creds.local.env" "tmp/telnyx/x-dev.env"; do
  if find "$dec/payload" -name "$(basename "$name")" 2>/dev/null | grep -q .; then
    fail "Part1: $name was found inside the bundle payload (should be excluded)"
  fi
done
rm -rf "$dec"

mv "$wt" "$wt.A-final"
git clone -q "$origin" "$wt" 2>/dev/null
tx_run_resume "$HOME_T" "$DROP" "$CODE" --no-exec
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA(Part1): resumework failed: $(tx_combined)" >&2; exit 3; }
for name in "auto-compact-$SID.marker" "mission-liveness-$SID.json" "tick.$SID.lock" "prod.lock" \
            "node_modules/pkg/index.js" ".env" "tmp/od-test/creds.local.env" "tmp/telnyx/x-dev.env"; do
  [ -e "$wt/$name" ] && fail "Part1: $name was restored on B (should have been excluded)"
done

# ------------------------------------------------------------------ Part 2: excludes disabled
# Non-secret set only: with TX_TEST_DISABLE_EXCLUDES=1 the secret-scan is UNCHANGED and would
# still refuse a send that carries .env content, so this half proves the never-names filter alone.
origin2="$HOME_T/origin2.git"; wt2="$HOME_T/work/proj2"
SID2=$(tx_new_sid)
tx_init_origin "$origin2" "$wt2" >/dev/null
printf 'x\n' > "$wt2/auto-compact-$SID2.marker"
printf 'x\n' > "$wt2/mission-liveness-$SID2.json"
printf 'x\n' > "$wt2/tick.$SID2.lock"
mkdir -p "$wt2/node_modules/pkg"
printf 'module.exports = 1;\n' > "$wt2/node_modules/pkg/index.js"
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
  dec2="$HOME_T/decoy2"; mkdir -p "$dec2"
  if tx_decrypt "$DROP/$LOC2.tx" "$dec2/inner.tgz" "$CODE2" 2>/dev/null; then
    ( cd "$dec2" && tar -xzf inner.tgz )
    found=0
    for name in "auto-compact-$SID2.marker" "mission-liveness-$SID2.json" "tick.$SID2.lock" "node_modules/pkg/index.js"; do
      find "$dec2/payload" -name "$(basename "$name")" 2>/dev/null | grep -q . && found=$((found + 1))
    done
    [ "$found" -eq 4 ] || fail "Part2 (negative control): with excludes disabled, expected all 4 planted files to be included but only $found were - the guard's test-only bypass may itself be broken"
  else
    fail "Part2: INFRA - could not decrypt the excludes-disabled bundle"
  fi
  rm -rf "$dec2"
fi

# ------------------------------------------------------------------ Part 3: '..' context references
# The TRANSFER notes name "tmp/../../outside-3.txt", which from the worktree climbs OUT of the repo
# to a real file. The reference must be rejected by name (unsafe-reference) and never shipped.
origin3="$HOME_T/origin3.git"; wt3="$HOME_T/work/proj3"
SID3=$(tx_new_sid)
tx_init_origin "$origin3" "$wt3" >/dev/null
mkdir -p "$wt3/tmp"
printf 'outside the repo\n' > "$HOME_T/outside-3.txt"
printf 'see tmp/../../outside-3.txt and tmp/ok-3.md\n' > "$wt3/TRANSFER.$SID3.md"
printf 'fine\n' > "$wt3/tmp/ok-3.md"
tx_write_handoff "$wt3" "$SID3"
tx_write_transcript "$HOME_T" "$SID3" "$wt3"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID3" --cwd "$wt3"
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "Part3: send failed: $(tx_combined)"
else
  dec3="$HOME_T/decoy3"; mkdir -p "$dec3"
  tx_decrypt "$DROP/$TX_LAST_LOC.tx" "$dec3/inner.tgz" "$TX_LAST_CODE" || { echo "INFRA(Part3): decrypt failed" >&2; exit 3; }
  ( cd "$dec3" && tar -xzf inner.tgz )
  find "$dec3/payload" -name 'outside-3.txt' | grep -q . && fail "Part3: a '..' context reference pulled a file from outside the repo into the bundle"
  find "$dec3/payload" -name 'ok-3.md' | grep -q . || fail "Part3: the ordinary tmp/ context file next to it was not shipped (positive control)"
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); sys.exit(0 if any(r=="unsafe-reference" and ".." in p for r,p in [(s["reason"],s["path"]) for s in m["skipped"]]) else 1)' \
    "$dec3/manifest.json" || fail "Part3: the manifest does not record the rejected '..' reference as unsafe-reference"
  rm -rf "$dec3"
fi

# ------------------------------------------------------------------ Part 4: memory is not name-filtered
# A memory note NAMED like a secret (the real reference_od_test_creds.md shape) is Claude state and
# must travel; its CONTENT is still scanned, so a secret-shaped line in memory refuses the send.
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
  dec4="$HOME_T/decoy4"; mkdir -p "$dec4"
  tx_decrypt "$DROP/$TX_LAST_LOC.tx" "$dec4/inner.tgz" "$TX_LAST_CODE" || { echo "INFRA(Part4): decrypt failed" >&2; exit 3; }
  ( cd "$dec4" && tar -xzf inner.tgz )
  for n in reference_od_test_creds.md feedback_rogue_agent_prod_cred_injection.md; do
    find "$dec4/payload" -path '*/memory/*' -name "$n" | grep -q . || fail "Part4: memory note $n was dropped by the secret NAME filter"
  done
  rm -rf "$dec4"
fi
# The key is assembled at runtime so this test file itself never matches the scanner.
k_pre="AKIA"; k_body="QWERTYUIOPASDFGH"
printf 'old note: %s%s\n' "$k_pre" "$k_body" >> "$MEM4/reference_od_test_creds.md"
tx_write_handoff "$wt4" "$SID4"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID4" --cwd "$wt4"
[ "$TX_LAST_RC" -eq 2 ] || fail "Part4: a secret-shaped line inside a memory note did not refuse the send (rc=$TX_LAST_RC)"
case "$TX_LAST_ERR" in
  *"Claude/Codex state"*"reference_od_test_creds.md"*) ;;
  *) fail "Part4: the content-scan refusal did not name the memory note: $TX_LAST_ERR" ;;
esac
case "$TX_LAST_ERR" in *"$k_body"*) fail "Part4: the refusal message echoed the secret itself" ;; esac

ok_report "04-exclusions-negative-control" "auto-compact/mission-liveness/locks/node_modules/.env/tmp-secrets excluded by default and absent on B; excludes-disabled dev knob demonstrably lets the non-secret set through; a '..' context reference is rejected (unsafe-reference); secret-NAMED memory notes travel but their content is still scanned"
