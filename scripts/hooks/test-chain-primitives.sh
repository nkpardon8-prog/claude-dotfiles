#!/usr/bin/env bash
# test-chain-primitives.sh — regression harness for lib/handoff-chain.sh
#
# Mirrors the convention of test-ctx-gate.sh / verify-test-integrity.sh / test-auto-compact.sh:
# emits a final `PASS: N  FAIL: M` line so other harness runners can parse it.
#
# Covered cases:
#   - chain_manifest_read returns rc=1 on truly first run (no manifest, no ledger)
#   - chain_manifest_write writes a valid JSON manifest; chain_manifest_read round-trips
#   - chain_manifest_write rejects invalid JSON on stdin (returns 1, leaves no garbage)
#   - chain_ledger_append uses a REAL tab delimiter (not literal "\t")
#   - chain_ledger_append produces 9 fields per line with key=value prefixes positions 2-9
#   - chain_ledger_append sanitizes embedded \t / \n in field values to underscore
#   - chain_manifest_read auto-recovers from a corrupt manifest using the ledger
#   - Recovery preserves the north_star verbatim via the ledger's `north_star_first_120` field
#   - chain_manifest_path / chain_ledger_path reject empty or hostile sids
#
# Idempotent: every test uses a unique SID and cleans up afterward.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/handoff-locate.sh"
. "$ROOT/lib/handoff-chain.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "${2:-}"; }

cleanup_sid() {
  local s="$1"
  rm -f "$HOME/.claude/chains/${s}.json" "$HOME/.claude/chains/${s}.log" \
        "$HOME/.claude/chains/.${s}.json."* 2>/dev/null || true
}

UNIQ="test-chain-$$-$(date +%s)"

echo
echo "=== chain primitives regression harness ==="
echo

# ---------------- 1: first-run detection ----------------
SID="${UNIQ}-firstrun"
cleanup_sid "$SID"
chain_manifest_read "$SID" >/dev/null 2>&1; rc=$?
if [ "$rc" = "1" ]; then pass "first-run rc=1 with no manifest and no ledger"
else fail "first-run" "expected rc=1, got rc=$rc"; fi

# ---------------- 2: write + read round-trip ----------------
SID="${UNIQ}-roundtrip"
cleanup_sid "$SID"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LHP="/tmp/CLAUDE.local.${SID}.md"
if jq -nc --arg sid "$SID" --arg st "$NOW" --arg lhp "$LHP" \
  '{chain_id:$sid, started_at:$st, north_star:"round-trip goal",
    north_star_source:"arguments", current_seq:1, last_handoff_path:$lhp,
    last_heartbeat_at:$st, status:"active", host:"test"}' \
  | chain_manifest_write "$SID"; then
  READ_NS=$(chain_manifest_read "$SID" 2>/dev/null | jq -r '.north_star')
  if [ "$READ_NS" = "round-trip goal" ]; then pass "manifest round-trip"
  else fail "manifest round-trip" "got '$READ_NS'"; fi
else fail "manifest write" "non-zero exit"; fi
cleanup_sid "$SID"

# ---------------- 3: write rejects invalid JSON ----------------
SID="${UNIQ}-badjson"
cleanup_sid "$SID"
if printf 'not json {{{' | chain_manifest_write "$SID" 2>/dev/null; then
  fail "invalid-json rejected" "write returned 0 for garbage"
else
  if [ ! -f "$HOME/.claude/chains/${SID}.json" ]; then pass "invalid-json rejected + no file"
  else fail "invalid-json rejected" "garbage file left behind"; fi
fi
cleanup_sid "$SID"

# ---------------- 4: ledger uses real tab delimiter (not literal "\t") ----------------
# NOTE: `od -c` DISPLAYS real tab bytes (0x09) as `\t`, so we can't grep `od` output for that.
# Instead: look for the two-byte literal sequence backslash+t (0x5C 0x74) directly in the raw
# file. A real tab won't match; a buggy `printf '\t'` in a non-ANSI-C-quoting context would.
SID="${UNIQ}-realtab"
cleanup_sid "$SID"
chain_ledger_append "$SID" "$NOW" "seq=1" "ctx_pct=78" "elapsed=0h 0m" "status=active" \
  "next=tab test" "files=1" "commits=0" "north_star_first_120=tab test goal"
if LC_ALL=C grep -q $'\\\\t' "$HOME/.claude/chains/${SID}.log" 2>/dev/null; then
  fail "real-tab delimiter" "literal backslash-t sequence found in ledger raw bytes"
else
  # Additional positive proof: awk -F'\t' must split to 9 fields. (Literal "\t" would yield 1.)
  NF_REAL=$(awk -F'\t' 'NR==1{print NF}' "$HOME/.claude/chains/${SID}.log")
  if [ "$NF_REAL" = "9" ]; then pass "real-tab delimiter (no literal bs-t bytes; NF=9 via awk -F'\\t')"
  else fail "real-tab delimiter" "no literal bs-t but NF=$NF_REAL (expected 9)"; fi
fi
cleanup_sid "$SID"

# ---------------- 5: ledger has 9 fields ----------------
SID="${UNIQ}-nf"
cleanup_sid "$SID"
chain_ledger_append "$SID" "$NOW" "seq=1" "ctx_pct=78" "elapsed=0h 0m" "status=active" \
  "next=nf check" "files=1" "commits=0" "north_star_first_120=nf goal"
NF=$(awk -F'\t' 'NR==1{print NF}' "$HOME/.claude/chains/${SID}.log")
if [ "$NF" = "9" ]; then pass "ledger has 9 fields"
else fail "ledger field count" "got $NF, expected 9"; fi
cleanup_sid "$SID"

# ---------------- 6: ledger sanitizes embedded \t and \n in field values ----------------
SID="${UNIQ}-sanitize"
cleanup_sid "$SID"
EVIL=$(printf 'a\tb\nc')
chain_ledger_append "$SID" "$NOW" "seq=1" "ctx_pct=78" "elapsed=0h 0m" "status=active" \
  "next=$EVIL" "files=1" "commits=0" "north_star_first_120=sanitize goal"
NF2=$(awk -F'\t' 'NR==1{print NF}' "$HOME/.claude/chains/${SID}.log")
LINES=$(wc -l < "$HOME/.claude/chains/${SID}.log" | tr -d ' ')
if [ "$NF2" = "9" ] && [ "$LINES" = "1" ]; then pass "embedded tab/newline sanitized"
else fail "sanitization" "NF=$NF2 lines=$LINES (expected NF=9 lines=1)"; fi
cleanup_sid "$SID"

# ---------------- 7: recovery from corrupt manifest, preserving north_star ----------------
SID="${UNIQ}-recover"
cleanup_sid "$SID"
GOAL="recovered goal — must survive corruption"
# Init manifest + ledger
jq -nc --arg sid "$SID" --arg st "$NOW" --arg ns "$GOAL" \
  '{chain_id:$sid, started_at:$st, north_star:$ns,
    north_star_source:"arguments", current_seq:1, last_handoff_path:"",
    last_heartbeat_at:$st, status:"active", host:"test"}' \
  | chain_manifest_write "$SID" >/dev/null
chain_ledger_append "$SID" "$NOW" "seq=1" "ctx_pct=80" "elapsed=0h 0m" "status=active" \
  "next=do thing" "files=2" "commits=1" "north_star_first_120=$GOAL"
# Corrupt manifest
echo "{ broken json" > "$HOME/.claude/chains/${SID}.json"
RECOVERED=$(chain_manifest_read "$SID" 2>/dev/null | jq -r '.recovered_from_ledger')
RECOVERED_NS=$(chain_manifest_read "$SID" 2>/dev/null | jq -r '.north_star')
if [ "$RECOVERED" = "true" ] && [ "$RECOVERED_NS" = "$GOAL" ]; then
  pass "recovery from corrupt manifest preserves north_star"
else
  fail "recovery preservation" "recovered=$RECOVERED north_star='$RECOVERED_NS'"
fi
cleanup_sid "$SID"

# ---------------- 8: empty/hostile sid rejected by path helpers ----------------
if chain_manifest_path "" 2>/dev/null; then fail "empty sid path" "rc=0 for empty"
else pass "chain_manifest_path rejects empty sid"; fi
# Hostile sid with path separator — should sanitize to safe form, not allow traversal.
SAFE=$(chain_manifest_path "../etc/passwd" 2>/dev/null)
case "$SAFE" in
  *"../"*) fail "sid sanitization" "path traversal allowed: $SAFE" ;;
  "$HOME/.claude/chains/etcpasswd.json") pass "sid sanitization strips path chars" ;;
  *) pass "sid sanitization (resulted in $SAFE)" ;;
esac

# ---------------- 9: ledger position 9 is north_star_first_120 ----------------
SID="${UNIQ}-pos9"
cleanup_sid "$SID"
chain_ledger_append "$SID" "$NOW" "seq=1" "ctx_pct=78" "elapsed=0h 0m" "status=active" \
  "next=position test" "files=1" "commits=0" "north_star_first_120=position 9 verifies"
F9=$(awk -F'\t' 'NR==1{print $9}' "$HOME/.claude/chains/${SID}.log")
case "$F9" in
  north_star_first_120=*) pass "ledger position 9 is north_star_first_120" ;;
  *) fail "ledger position 9" "got '$F9'" ;;
esac
cleanup_sid "$SID"

# --- guard-integrity (2026-08-03, mission part 3): chain_manifest_read must NOT report
# success while producing nothing. The ledger-recovery path ended in a bare `jq -nc ...`
# followed by an unconditional `return 0`, so a missing or failing jq gave rc=0 with ZERO
# bytes on stdout - and callers branch on that rc (`if MANIFEST=$(chain_manifest_read ...)`),
# so they entered the success path and rendered a chain banner of empty fields.
# jq is stubbed to fail rather than removed from PATH, because "absent" and "present but
# broken" are different failures and the broken one is the quieter of the two.
SID="${UNIQ}-jqfail"
cleanup_sid "$SID"
chain_ledger_append "$SID" "$NOW" "seq=1" "ctx_pct=10" "elapsed=0h 0m" "status=active" \
  "next=jq failure test" "files=0" "commits=0" "north_star_first_120=jq failure verifies"
rm -f "$HOME/.claude/chains/${SID}.json"          # force the ledger-recovery path
_JQBIN=$(mktemp -d); printf '#!/bin/sh\nexit 3\n' > "$_JQBIN/jq"; chmod +x "$_JQBIN/jq"
_out=$(PATH="$_JQBIN:$PATH" chain_manifest_read "$SID" 2>/dev/null); _rc=$?
rm -rf "$_JQBIN"
if [ "$_rc" -ne 0 ] && [ -z "$_out" ]; then
  pass "chain_manifest_read fails closed when jq cannot build the manifest"
else
  fail "chain_manifest_read jq-failure" "rc=$_rc bytes=${#_out} (rc=0 with 0 bytes = success reported for nothing)"
fi
# ...and the same path must still SUCCEED when jq works, or the guard above is worthless.
_out2=$(chain_manifest_read "$SID" 2>/dev/null); _rc2=$?
if [ "$_rc2" -eq 0 ] && [ -n "$_out2" ]; then
  pass "chain_manifest_read still recovers from the ledger when jq works"
else
  fail "chain_manifest_read recovery" "rc=$_rc2 bytes=${#_out2}"
fi
cleanup_sid "$SID"

# --- round-5 review fixes (2026-08-04). Two halves of chain_manifest_read disagreed with
# each other: the recovery branch validated what it produced, while the FAST path trusted any
# parseable JSON, and "recovery failed" was reported with the same rc as "first run".

# 1. The fast path must check SHAPE, not just parseability. `jq -e .` returns 0 for {}, [],
#    0 and "a string"; the primer then rendered a chain banner from .north_star // "" etc -
#    a hollow banner of defaults, the exact outcome the recovery branch was hardened against.
SID="chaintest-shape-$$"
cleanup_sid "$SID"
for _bad in '{}' '[]' '"just a string"' '0'; do
    printf '%s' "$_bad" > "$HOME/.claude/chains/${SID}.json"
    _o=$(chain_manifest_read "$SID" 2>/dev/null); _r=$?
    if [ "$_r" -ne 0 ]; then
        pass "non-manifest JSON is rejected by the fast path: $_bad"
    else
        fail "fast-path shape check ($_bad)" "rc=0 with bytes=${#_o} - parseable is not the same as valid"
    fi
done
cleanup_sid "$SID"

# 2. rc=2 (ledger exists, recovery failed) must NOT be reported as rc=1 (genuinely first run).
#    pre-compact.md sets IS_FIRST_RUN=1 / NEW_SEQ=1 and re-derives NORTH_STAR on the first-run
#    branch, so collapsing these two silently RESTARTS a live chain at seq 1 and discards its
#    history. This case asserts the DISTINCTION, not merely "non-zero".
SID="chaintest-rc2-$$"
cleanup_sid "$SID"
printf 'not json' > "$HOME/.claude/chains/${SID}.json"
printf '2026-01-01T00:00:00Z\tseq=7\tctx_pct=1\telapsed=1\tstatus=active\tnext=x\tfiles=1\tcommits=1\tnorth_star_first_120=goal\n' \
    > "$HOME/.claude/chains/${SID}.log"
_JQ2=$(mktemp -d); printf '#!/bin/sh\nexit 1\n' > "$_JQ2/jq"; chmod +x "$_JQ2/jq"
_o2=$(PATH="$_JQ2:$PATH" chain_manifest_read "$SID" 2>/dev/null); _r2=$?
if [ "$_r2" -eq 2 ]; then
    pass "a chain WITH a ledger reports rc=2, never rc=1 (must not be reseeded as first run)"
else
    fail "rc=2 distinction" "rc=$_r2 (1 would make pre-compact restart this chain at seq 1)"
fi
rm -rf "$_JQ2"
# ...and a genuinely first run must still be rc=1, or the distinction is meaningless.
cleanup_sid "$SID"
chain_manifest_read "$SID" >/dev/null 2>&1; _r3=$?
if [ "$_r3" -eq 1 ]; then
    pass "a genuinely first run is still rc=1"
else
    fail "first-run rc" "rc=$_r3 (want 1)"
fi
cleanup_sid "$SID"

# 3. An unusable manifest with NO ledger is ALSO rc=2, not rc=1. This branch shipped in round 7
#    with no coverage at all - deleting it left this harness green at 18/0, which the round-7
#    reviewer demonstrated. The distinction matters because rc=1 makes pre-compact treat the
#    sid as a first run; the file's mere existence is proof a chain was here, and its contents
#    are the only surviving evidence of it.
SID="chaintest-noledger-$$"
cleanup_sid "$SID"
printf 'not valid json' > "$HOME/.claude/chains/${SID}.json"
[ -e "$HOME/.claude/chains/${SID}.log" ] && rm -f "$HOME/.claude/chains/${SID}.log"
chain_manifest_read "$SID" >/dev/null 2>&1; _r4=$?
if [ "$_r4" -eq 2 ]; then
    pass "an unusable manifest with NO ledger is rc=2 (a chain existed here)"
else
    fail "no-ledger rc=2" "rc=$_r4 (want 2; rc=1 would let pre-compact overwrite the evidence)"
fi
cleanup_sid "$SID"

echo
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
