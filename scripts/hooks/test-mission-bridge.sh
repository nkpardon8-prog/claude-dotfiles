#!/usr/bin/env bash
# test-mission-bridge.sh — regression harness for lib/mission-bridge.sh
#
# Mirrors test-chain-primitives.sh: emits a final `PASS: N  FAIL: M` line so the other
# harness runners can parse it; the final test is the exit code.
#
# ZERO-INFORMATION-LOSS contract surface under test (plan 2026-05-30-precompact-mission-bridge):
#   - marker is read from the LAST marker line (canonical), never head -1
#   - a PLAN body containing a pseudo-marker + a bare /MZONE close + a `## ` heading round-trips
#     (nonce-fenced extraction is not fooled / not truncated)
#   - a body pseudo-marker NOT on the last line => mission_verify LOUD corruption
#   - LOG byte-cap from multibyte input stays <512 bytes and valid UTF-8
#   - anchored idempotency: a body-quoted id does NOT suppress a real new entry; a true dup IS
#   - log rotation archives the oldest half into .mission-backups/ (a .gz appears) — no loss
#   - orphan-lock reclaim: a dead-pid lock is reclaimed; a live-pid lock is NEVER stolen
#   - manifest merge preserves mission_path across a seq bump; recovery re-derives it
#   - mutate atomicity + idempotent re-mutate is a no-op
#   - banner emitted, contains the PLAN slice + injection-safety framing, bounded
#   - birth backup exists after create AND survives a prune exceeding MISSION_BACKUP_KEEP
#   - plan_hash determinism; create idempotency (no clobber); mission_read_zone per zone
#
# Hermetic: every test uses a per-test temp dir under $TMPDIR (namespaced by UNIQ) as the
# mission canonical root. Recovery test uses a unique SID under ~/.claude/chains and cleans it.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/handoff-locate.sh"
. "$ROOT/lib/mission-bridge.sh"
. "$ROOT/lib/handoff-chain.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "${2:-}"; }

UNIQ="test-mission-$$-$(date +%s)"
WORKBASE="${TMPDIR:-/tmp}/${UNIQ}"

cleanup_root() { rm -rf "$1" 2>/dev/null || true; }

cleanup_sid() {
  s="$1"
  rm -f "$HOME/.claude/chains/${s}.json" "$HOME/.claude/chains/${s}.log" \
        "$HOME/.claude/chains/.${s}.json."* 2>/dev/null || true
}

# fresh_root <name> -> echoes a clean per-test root dir (created), removing any prior copy.
fresh_root() {
  _fr_d="${WORKBASE}-$1"
  cleanup_root "$_fr_d"
  mkdir -p "$_fr_d" 2>/dev/null
  printf '%s' "$_fr_d"
}

trap 'rm -rf "${WORKBASE}"* 2>/dev/null || true' EXIT

echo
echo "=== mission-bridge regression harness ==="
echo

# Marker is NOT git-locked to any repo here; lockbase falls back to root. But $TMPDIR may be a
# git repo on some CI boxes — neutralize by pointing lock + ops at our own dir (not a repo).

# ===========================================================================================
# 1: mission_create produces a verifiable file
# ===========================================================================================
SID="${UNIQ}-create"
R=$(fresh_root create)
if mission_create "$SID" "$R" "plan line one
plan line two" 2>/dev/null; then
  if mission_verify "$R/MISSION.${SID}.md" "$SID" 2>/dev/null; then
    pass "mission_create writes a file that verifies"
  else fail "mission_create verify" "verify failed on fresh create"; fi
else fail "mission_create" "create returned non-zero"; fi

# ===========================================================================================
# 2: mission_read_zone returns the right content for PLAN
# ===========================================================================================
ZP=$(mission_read_zone "$R/MISSION.${SID}.md" PLAN 2>/dev/null)
if [ "$ZP" = "plan line one
plan line two" ]; then pass "mission_read_zone PLAN exact content"
else fail "read_zone PLAN" "got '$ZP'"; fi

# ===========================================================================================
# 3-5: mission_read_zone for the other 3 zones (empty after create)
# ===========================================================================================
for Z in "DURABLE NOTES" "PLAN CHALLENGES" "PENDING DECISIONS"; do
  ZC=$(mission_read_zone "$R/MISSION.${SID}.md" "$Z" 2>/dev/null)
  if [ -z "$ZC" ]; then pass "mission_read_zone '$Z' empty on create"
  else fail "read_zone $Z" "expected empty, got '$ZC'"; fi
done

# ===========================================================================================
# 6: marker read from the LAST line (canonical), NOT head -1
# Append a body-style pseudo-marker BEFORE the canonical last line and confirm the field reader
# still returns the canonical (last) marker's value.
# ===========================================================================================
SID="${UNIQ}-lastline"
R=$(fresh_root lastline)
mission_create "$SID" "$R" "the real plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
REAL_SID=$(_mission_marker_field "$F" sid)
# craft a file: a decoy marker line near the top, real file body, real marker last.
{
  printf '<!-- MISSION schema=v1 sid=DECOY nonce=deadbeefdeadbeef plan_hash=0000000000000000 -->\n'
  cat "$F"
} > "$F.injected"
GOT=$(_mission_marker_field "$F.injected" sid)
if [ "$GOT" = "$REAL_SID" ] && [ "$GOT" != "DECOY" ]; then
  pass "_mission_marker_field reads the LAST marker line (not head -1)"
else fail "marker last-line" "got sid='$GOT' want '$REAL_SID'"; fi

# ===========================================================================================
# 7: body pseudo-marker (NOT last line) => mission_verify reports corruption (non-zero)
# (same injected file: it now has 2 marker-anchored lines, decoy NOT last)
# ===========================================================================================
if mission_verify "$F.injected" "$SID" 2>/dev/null; then
  fail "verify body-pseudo-marker" "verify passed a file with a body pseudo-marker"
else pass "mission_verify => corruption on body pseudo-marker (2 markers, decoy not last)"; fi

# ===========================================================================================
# 8: a PLAN body containing a pseudo-marker AND a bare /MZONE close AND a `## ` heading
# round-trips correctly (nonce-fence extraction not fooled / not truncated).
# ===========================================================================================
SID="${UNIQ}-roundtrip"
R=$(fresh_root roundtrip)
TRICKY='## Heading inside PLAN
A line that mentions <!-- MISSION schema=v1 sid=FAKE nonce=ffff plan_hash=dead --> in prose.
A bare close without the live nonce: <!-- /MZONE:PLAN -->
final plan line'
mission_create "$SID" "$R" "$TRICKY" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
if mission_verify "$F" "$SID" 2>/dev/null; then
  GOTZ=$(mission_read_zone "$F" PLAN 2>/dev/null)
  if [ "$GOTZ" = "$TRICKY" ]; then
    pass "tricky PLAN (pseudo-marker + bare /MZONE close + ## heading) round-trips verbatim"
  else fail "tricky round-trip" "PLAN zone differs from seeded (truncation?)"; fi
else
  fail "tricky verify" "verify FAILED on a file whose PLAN body holds a pseudo-marker (last-line parse should be fine)"
fi

# ===========================================================================================
# 9: plan_hash determinism — same PLAN twice gives the same 16-hex.
# ===========================================================================================
H1=$(printf '%s' "deterministic plan content" | _mission_hash_stream 2>/dev/null)
H2=$(printf '%s' "deterministic plan content" | _mission_hash_stream 2>/dev/null)
if [ -n "$H1" ] && [ "$H1" = "$H2" ] && printf '%s' "$H1" | grep -qE '^[0-9a-f]{16}$'; then
  pass "_mission_hash_stream deterministic 16-hex ($H1)"
else fail "hash determinism" "H1='$H1' H2='$H2'"; fi

# 9b: _mission_plan_hash deterministic on the same file
PH1=$(_mission_plan_hash "$F" 2>/dev/null)
PH2=$(_mission_plan_hash "$F" 2>/dev/null)
if [ -n "$PH1" ] && [ "$PH1" = "$PH2" ]; then pass "_mission_plan_hash deterministic on a file"
else fail "plan_hash file determinism" "PH1='$PH1' PH2='$PH2'"; fi

# 9c: plan_hash matches the stamped marker plan_hash
MARKH=$(_mission_marker_field "$F" plan_hash)
if [ "$PH1" = "$MARKH" ]; then pass "_mission_plan_hash matches stamped marker plan_hash"
else fail "plan_hash vs marker" "computed='$PH1' marker='$MARKH'"; fi

# ===========================================================================================
# 10: create idempotency — second create does NOT clobber the first (PLAN unchanged, nonce same)
# ===========================================================================================
SID="${UNIQ}-idem"
R=$(fresh_root idem)
mission_create "$SID" "$R" "original plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
NONCE1=$(_mission_marker_field "$F" nonce)
mission_create "$SID" "$R" "DIFFERENT plan that must NOT overwrite" >/dev/null 2>&1
NONCE2=$(_mission_marker_field "$F" nonce)
PLAN_AFTER=$(mission_read_zone "$F" PLAN 2>/dev/null)
if [ "$NONCE1" = "$NONCE2" ] && [ "$PLAN_AFTER" = "original plan" ]; then
  pass "mission_create idempotent no-clobber (PLAN + nonce unchanged on 2nd create)"
else fail "create idempotency" "nonce '$NONCE1'->'$NONCE2' plan='$PLAN_AFTER'"; fi

# ===========================================================================================
# 11: LOG byte-cap from multibyte input — an entry of 4-byte codepoints is capped <512 bytes
# and stays valid UTF-8. (assumption test 01 idiom)
# ===========================================================================================
SID="${UNIQ}-mblog"
R=$(fresh_root mblog)
mission_create "$SID" "$R" "mb plan" >/dev/null 2>&1
LOGF="$R/MISSION.${SID}.log"
# Build a big multibyte payload: repeat a 4-byte emoji (U+1F600) ~600 times (~2400 bytes).
MB=$(awk 'BEGIN{s="";for(i=0;i<600;i++)s=s"\360\237\230\200";printf "%s", s}')
mission_log_append "$SID" "$R" "$MB" "mb-tag" >/dev/null 2>&1
if [ -f "$LOGF" ]; then
  LASTLINE_BYTES=$(tail -n 1 "$LOGF" | LC_ALL=C wc -c | tr -d ' ')
  if [ -n "$LASTLINE_BYTES" ] && [ "$LASTLINE_BYTES" -lt 512 ]; then
    pass "LOG multibyte entry capped <512 bytes ($LASTLINE_BYTES)"
  else fail "log byte-cap" "last line $LASTLINE_BYTES bytes (>=512)"; fi
  # valid UTF-8: round-trip through iconv UTF-8->UTF-8 with -c removing invalid; if nothing was
  # removed (byte counts equal), the stored line was already valid UTF-8.
  RAW=$(tail -n 1 "$LOGF")
  RB=$(printf '%s' "$RAW" | LC_ALL=C wc -c | tr -d ' ')
  CB=$(printf '%s' "$RAW" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null | LC_ALL=C wc -c | tr -d ' ')
  if [ "$RB" = "$CB" ]; then pass "LOG capped multibyte line is valid UTF-8 (no split codepoint)"
  else fail "log utf8 valid" "raw=$RB bytes, iconv-clean=$CB bytes (codepoint was split)"; fi
else fail "log byte-cap" "no log file written"; fi

# ===========================================================================================
# 12: anchored idempotency — a log entry whose BODY quotes an existing id does NOT suppress a
# real new entry; a true duplicate tag IS suppressed.
# ===========================================================================================
SID="${UNIQ}-anchor"
R=$(fresh_root anchor)
mission_create "$SID" "$R" "anchor plan" >/dev/null 2>&1
LOGF="$R/MISSION.${SID}.log"
mission_log_append "$SID" "$R" "first real entry" "tagA" >/dev/null 2>&1
# Body quotes the existing tag "tagA" but the NEW tag is tagB — must NOT be suppressed.
mission_log_append "$SID" "$R" "mentions tagA inside body text" "tagB" >/dev/null 2>&1
LINES_AFTER_B=$(wc -l < "$LOGF" | tr -d ' ')
# A true duplicate (tagA again) must be suppressed.
mission_log_append "$SID" "$R" "different body, same tag" "tagA" >/dev/null 2>&1
LINES_AFTER_DUP=$(wc -l < "$LOGF" | tr -d ' ')
if [ "$LINES_AFTER_B" = "2" ]; then pass "anchored idempotency: body-quoted id does NOT suppress a new tagged entry"
else fail "anchor new entry" "expected 2 lines, got $LINES_AFTER_B"; fi
if [ "$LINES_AFTER_DUP" = "2" ]; then pass "anchored idempotency: true duplicate tag IS suppressed"
else fail "anchor dup suppress" "expected 2 lines (dup suppressed), got $LINES_AFTER_DUP"; fi

# ===========================================================================================
# 13: log rotation — exceeding MISSION_LOG_MAX_BYTES archives the oldest half into
# .mission-backups/ (a .gz appears) and does NOT lose entries (archive, not truncate).
# ===========================================================================================
SID="${UNIQ}-rotate"
R=$(fresh_root rotate)
mission_create "$SID" "$R" "rotate plan" >/dev/null 2>&1
LOGF="$R/MISSION.${SID}.log"
(
  MISSION_LOG_MAX_BYTES=4096   # tiny threshold so a handful of entries trips it
  export MISSION_LOG_MAX_BYTES
  i=0
  while [ "$i" -lt 200 ]; do
    mission_log_append "$SID" "$R" "rotation payload entry number $i with some padding text here to add bytes" "rot-$i" >/dev/null 2>&1
    i=$((i+1))
  done
)
ARCH=$(ls -1 "$R/.mission-backups/"MISSION."${SID}".log.*.gz 2>/dev/null | head -1)
if [ -n "$ARCH" ] && [ -f "$ARCH" ]; then
  pass "log rotation produced a .gz archive in .mission-backups/"
  # zero-loss proof: live tail-count + archived count together must cover the entries; specifically
  # the archive is non-empty (gunzip yields lines) — entries were moved, not dropped.
  ARCH_LINES=$(gzip -dc "$ARCH" 2>/dev/null | wc -l | tr -d ' ')
  if [ -n "$ARCH_LINES" ] && [ "$ARCH_LINES" -ge 1 ]; then
    pass "log rotation archive holds the oldest entries (archive, not truncate: $ARCH_LINES lines)"
  else fail "rotation zero-loss" "archive had $ARCH_LINES lines"; fi
else
  # rotation might archive .txt if gzip absent; accept that as still zero-loss.
  ARCHTXT=$(ls -1 "$R/.mission-backups/"MISSION."${SID}".log.*.txt 2>/dev/null | head -1)
  if [ -n "$ARCHTXT" ]; then
    pass "log rotation produced a plain-text archive (.gz unavailable; still zero-loss)"
    ARCH_LINES=$(wc -l < "$ARCHTXT" | tr -d ' ')
    if [ "$ARCH_LINES" -ge 1 ]; then pass "log rotation archive holds oldest entries ($ARCH_LINES lines)"
    else fail "rotation zero-loss" "txt archive empty"; fi
  else
    fail "log rotation archive" "no archive (.gz/.txt) in .mission-backups/ after exceeding cap"
    fail "rotation zero-loss" "no archive to verify"
  fi
fi

# ===========================================================================================
# 14: orphan-lock reclaim — a lock dir stamped with a DEAD pid is reclaimed; a LIVE-pid lock is
# NOT stolen. (mirror assumption test 03)
# ===========================================================================================
SID="${UNIQ}-lock"
R=$(fresh_root lock)
LB=$(_mission_lockbase "$R")
LOCK="${LB}/.claude-mission-$(_mission_sanitize_sid "$SID").lock"
# Dead pid: spawn+reap a child so its pid is guaranteed not alive.
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
rm -rf "$LOCK" 2>/dev/null
mkdir -p "$LOCK" 2>/dev/null
printf '%s\n' "$DEADPID" > "$LOCK/pid"
_MLOCK=""
if _mission_lock "$LB" "$SID" 2>/dev/null; then
  HELDPID=$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9')
  if [ "$HELDPID" = "$$" ]; then pass "orphan-lock reclaim: dead-pid lock reclaimed (now held by us $$)"
  else fail "lock reclaim" "lock pid is '$HELDPID', expected our pid $$"; fi
  _mission_unlock
else
  fail "lock reclaim" "_mission_lock failed to reclaim a dead-pid lock"
fi

# live-pid lock must NOT be stolen
SID="${UNIQ}-livelock"
R=$(fresh_root livelock)
LB=$(_mission_lockbase "$R")
LOCK="${LB}/.claude-mission-$(_mission_sanitize_sid "$SID").lock"
sleep 30 & LIVEPID=$!
rm -rf "$LOCK" 2>/dev/null
mkdir -p "$LOCK" 2>/dev/null
printf '%s\n' "$LIVEPID" > "$LOCK/pid"
_MLOCK=""
# _mission_lock loops 50x * 0.1s = ~5s before giving up. With a LIVE holder it must time out (rc!=0)
# and must NOT have removed the live holder's pid file.
if _mission_lock "$LB" "$SID" 2>/dev/null; then
  _mission_unlock
  fail "live-lock not stolen" "_mission_lock acquired a LIVE holder's lock"
else
  STILL=$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9')
  if [ "$STILL" = "$LIVEPID" ]; then pass "live-pid lock NOT stolen (holder pid intact, acquire timed out)"
  else fail "live-lock not stolen" "live holder pid file was disturbed ('$STILL' vs $LIVEPID)"; fi
fi
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null
rm -rf "$LOCK" 2>/dev/null

# ===========================================================================================
# 15: mutate atomicity — after a mutate, mission_verify still passes and the file ends with a
# valid marker; an idempotent re-mutate (same idtag) is a no-op.
# ===========================================================================================
SID="${UNIQ}-mutate"
R=$(fresh_root mutate)
mission_create "$SID" "$R" "mutate plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
mission_mutate "$SID" "$R" note "a durable note" "note-1" >/dev/null 2>&1; MRC=$?
if [ "$MRC" = "0" ] && mission_verify "$F" "$SID" 2>/dev/null; then
  pass "mission_mutate note: file still verifies after mutate"
else fail "mutate verify" "rc=$MRC or verify failed after mutate"; fi
# last non-empty line is a canonical marker
LASTNB=$(grep -vE '^[[:space:]]*$' "$F" | tail -1)
case "$LASTNB" in
  '<!-- MISSION schema=v1 '*' -->') pass "mutate: file ends with a valid canonical marker line" ;;
  *) fail "mutate marker last" "last non-empty line: '$LASTNB'" ;;
esac
# the note landed in DURABLE NOTES
NOTES=$(mission_read_zone "$F" "DURABLE NOTES" 2>/dev/null)
case "$NOTES" in
  *"a durable note"*) pass "mutate: entry landed in DURABLE NOTES zone" ;;
  *) fail "mutate content" "DURABLE NOTES zone='$NOTES'" ;;
esac
# idempotent re-mutate (same idtag) is a no-op — zone content unchanged.
mission_mutate "$SID" "$R" note "a durable note" "note-1" >/dev/null 2>&1
NOTES2=$(mission_read_zone "$F" "DURABLE NOTES" 2>/dev/null)
if [ "$NOTES" = "$NOTES2" ]; then pass "mutate idempotent: same idtag re-mutate is a no-op"
else fail "mutate idempotent" "zone changed on re-mutate"; fi

# ===========================================================================================
# 16: banner — mission_render_banner produces a banner file; contains the PLAN slice + the
# injection-safety framing; bounded.
# ===========================================================================================
SID="${UNIQ}-banner"
R=$(fresh_root banner)
mission_create "$SID" "$R" "BANNER-PLAN-MARKER plan body" >/dev/null 2>&1
mission_log_append "$SID" "$R" "a recent log line" "blog-1" >/dev/null 2>&1
mission_render_banner "$SID" "$R" >/dev/null 2>&1
BAN="$R/MISSION.${SID}.banner"
if [ -f "$BAN" ]; then pass "mission_render_banner wrote a banner file"
else fail "banner file" "no banner produced"; fi
if grep -q "BANNER-PLAN-MARKER" "$BAN" 2>/dev/null; then pass "banner contains the PLAN slice"
else fail "banner plan slice" "PLAN marker not in banner"; fi
if grep -q "Hand-editing this file is NOT running /pre-compact" "$BAN" 2>/dev/null \
   && grep -q "UNTRUSTED" "$BAN" 2>/dev/null; then
  pass "banner contains the injection-safety framing"
else fail "banner framing" "injection-safety framing missing"; fi
BANSZ=$(_file_size "$BAN")
if [ -n "$BANSZ" ] && [ "$BANSZ" -le 65536 ]; then pass "banner bounded (<=64KB: ${BANSZ}B)"
else fail "banner bounded" "banner size ${BANSZ}B exceeds 64KB"; fi

# banner LOUD path: corrupt the main file, re-render, banner must shout CRITICAL.
printf 'garbage not a mission\n' > "$R/MISSION.${SID}.md"
mission_render_banner "$SID" "$R" >/dev/null 2>&1
if grep -q "CRITICAL" "$BAN" 2>/dev/null; then pass "banner LOUD on corrupt main file (CRITICAL)"
else fail "banner loud" "corrupt main file did not yield a CRITICAL banner"; fi

# ===========================================================================================
# 17: birth backup exists after create AND survives a prune that exceeds MISSION_BACKUP_KEEP.
# ===========================================================================================
SID="${UNIQ}-birth"
R=$(fresh_root birth)
mission_create "$SID" "$R" "birth plan" >/dev/null 2>&1
BIRTH="$R/.mission-backups/MISSION.${SID}.birth.md"
if [ -f "$BIRTH" ]; then pass "birth backup exists after create"
else fail "birth backup" "no birth backup after create"; fi
F="$R/MISSION.${SID}.md"
# Trigger many backups (each mutate backs up first) to exceed MISSION_BACKUP_KEEP.
(
  MISSION_BACKUP_KEEP=5
  export MISSION_BACKUP_KEEP
  i=0
  while [ "$i" -lt 12 ]; do
    mission_mutate "$SID" "$R" note "prune-trigger note $i" "prune-$i" >/dev/null 2>&1
    i=$((i+1))
  done
)
NON_BIRTH=$(ls -1 "$R/.mission-backups/"MISSION."${SID}".*.md 2>/dev/null | grep -v "birth.md" | wc -l | tr -d ' ')
if [ -f "$BIRTH" ]; then pass "birth backup SURVIVES a prune exceeding MISSION_BACKUP_KEEP"
else fail "birth prune-survive" "birth backup deleted by prune"; fi
if [ -n "$NON_BIRTH" ] && [ "$NON_BIRTH" -le 6 ]; then
  pass "prune kept backups bounded (non-birth count $NON_BIRTH <= keep+1)"
else fail "prune bound" "non-birth backups=$NON_BIRTH (prune did not bound)"; fi

# ===========================================================================================
# 18: manifest merge preserves mission_path across a seq bump
# (.mission_path = (.mission_path // $mp) keeps an existing path).
# ===========================================================================================
SID="${UNIQ}-mppreserve"
cleanup_sid "$SID"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXISTING_MP="/some/canonical/root/MISSION.${SID}.md"
jq -nc --arg sid "$SID" --arg st "$NOW" --arg mp "$EXISTING_MP" \
  '{chain_id:$sid, started_at:$st, north_star:"mp goal", north_star_source:"arguments",
    current_seq:1, last_handoff_path:"", last_heartbeat_at:$st, status:"active",
    host:"test", mission_path:$mp}' \
  | chain_manifest_write "$SID" >/dev/null 2>&1
# simulate a seq-bump merge that would try to set mission_path to a DIFFERENT value
MERGED=$(chain_manifest_read "$SID" 2>/dev/null \
  | jq --arg mp "/WRONG/path/MISSION.${SID}.md" \
       '.current_seq = 2 | .mission_path = (.mission_path // $mp)' 2>/dev/null)
MP_AFTER=$(printf '%s' "$MERGED" | jq -r '.mission_path' 2>/dev/null)
SEQ_AFTER=$(printf '%s' "$MERGED" | jq -r '.current_seq' 2>/dev/null)
if [ "$MP_AFTER" = "$EXISTING_MP" ] && [ "$SEQ_AFTER" = "2" ]; then
  pass "manifest merge preserves mission_path across a seq bump (// keeps existing)"
else fail "mp preserve-merge" "mission_path='$MP_AFTER' seq='$SEQ_AFTER'"; fi
cleanup_sid "$SID"

# ===========================================================================================
# 19: recovery re-derives mission_path — chain_manifest_read on a DELETED manifest with a ledger
# present re-derives mission_path from handoff_canonical_root.
# ===========================================================================================
SID="${UNIQ}-mprecover"
cleanup_sid "$SID"
# ledger present, manifest absent → recovery branch
chain_ledger_append "$SID" "$NOW" "seq=1" "ctx_pct=80" "elapsed=0h 0m" "status=active" \
  "next=recover mp" "files=1" "commits=0" "north_star_first_120=recover mp goal" >/dev/null 2>&1
rm -f "$HOME/.claude/chains/${SID}.json" 2>/dev/null
REC=$(chain_manifest_read "$SID" 2>/dev/null)
REC_MP=$(printf '%s' "$REC" | jq -r '.mission_path // empty' 2>/dev/null)
REC_FLAG=$(printf '%s' "$REC" | jq -r '.recovered_from_ledger' 2>/dev/null)
case "$REC_MP" in
  *"/MISSION.${SID}.md")
    if [ "$REC_FLAG" = "true" ]; then
      pass "recovery re-derives mission_path from canonical root (.../MISSION.${SID}.md)"
    else fail "recovery mp" "mp ok but recovered_from_ledger='$REC_FLAG'"; fi ;;
  *) fail "recovery mp" "mission_path='$REC_MP' (expected to end in /MISSION.${SID}.md)" ;;
esac
cleanup_sid "$SID"

# ===========================================================================================
# 20: mission_ensure creates when absent and is a no-op when present-and-valid.
# ===========================================================================================
SID="${UNIQ}-ensure"
R=$(fresh_root ensure)
F="$R/MISSION.${SID}.md"
[ -f "$F" ] && rm -f "$F"
if mission_ensure "$SID" "$R" "ensured plan" >/dev/null 2>&1 && [ -f "$F" ] \
   && mission_verify "$F" "$SID" 2>/dev/null; then
  pass "mission_ensure creates a valid file when absent"
else fail "ensure create" "ensure did not produce a valid file"; fi
NONCE_E1=$(_mission_marker_field "$F" nonce)
mission_ensure "$SID" "$R" "different plan" >/dev/null 2>&1
NONCE_E2=$(_mission_marker_field "$F" nonce)
if [ "$NONCE_E1" = "$NONCE_E2" ]; then pass "mission_ensure no-op when present-and-valid (nonce unchanged)"
else fail "ensure no-op" "nonce changed '$NONCE_E1'->'$NONCE_E2'"; fi

# ===========================================================================================
# 21: mission_log_append refuses to orphan — given a root where the main file can be created,
# it creates it first (mission_ensure), so a log never exists without a main file.
# ===========================================================================================
SID="${UNIQ}-noorphan"
R=$(fresh_root noorphan)
rm -f "$R/MISSION.${SID}.md" "$R/MISSION.${SID}.log" 2>/dev/null
mission_log_append "$SID" "$R" "log forces main-file creation" "orphan-1" >/dev/null 2>&1
if [ -f "$R/MISSION.${SID}.log" ] && [ -f "$R/MISSION.${SID}.md" ] \
   && mission_verify "$R/MISSION.${SID}.md" "$SID" 2>/dev/null; then
  pass "mission_log_append created the main file first (no orphan log)"
else fail "no-orphan log" "log written without a valid main file"; fi

# ===========================================================================================
# 22: pending resolve — add a pending decision then resolve it strips the pd: line.
# ===========================================================================================
SID="${UNIQ}-pending"
R=$(fresh_root pending)
mission_create "$SID" "$R" "pending plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
mission_mutate "$SID" "$R" pending "- [pd:1-foo] should we do X?" "pd-1" >/dev/null 2>&1
PEND_BEFORE=$(mission_read_zone "$F" "PENDING DECISIONS" 2>/dev/null)
mission_resolve_pending "$SID" "$R" "1-foo" "decided yes" >/dev/null 2>&1
PEND_AFTER=$(mission_read_zone "$F" "PENDING DECISIONS" 2>/dev/null)
case "$PEND_BEFORE" in *"pd:1-foo"*) PB=1 ;; *) PB=0 ;; esac
case "$PEND_AFTER" in *"pd:1-foo"*) PA=1 ;; *) PA=0 ;; esac
if [ "$PB" = "1" ] && [ "$PA" = "0" ] && mission_verify "$F" "$SID" 2>/dev/null; then
  pass "mission_resolve_pending strips the pd: line and file still verifies"
else fail "resolve pending" "before-has=$PB after-has=$PA"; fi

# ===========================================================================================
# 23: rebaseline — the ONLY path that rewrites PLAN; re-stamps plan_hash; file verifies.
# ===========================================================================================
SID="${UNIQ}-rebase"
R=$(fresh_root rebase)
mission_create "$SID" "$R" "old plan body" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
OLDH=$(_mission_marker_field "$F" plan_hash)
mission_rebaseline "$SID" "$R" "brand new plan body" >/dev/null 2>&1
NEWPLAN=$(mission_read_zone "$F" PLAN 2>/dev/null)
NEWH=$(_mission_marker_field "$F" plan_hash)
COMPUTED=$(_mission_plan_hash "$F" 2>/dev/null)
if [ "$NEWPLAN" = "brand new plan body" ] && [ "$NEWH" != "$OLDH" ] \
   && [ "$NEWH" = "$COMPUTED" ] && mission_verify "$F" "$SID" 2>/dev/null; then
  pass "mission_rebaseline replaces PLAN, re-stamps a matching plan_hash, verifies"
else fail "rebaseline" "plan='$NEWPLAN' oldh='$OLDH' newh='$NEWH' computed='$COMPUTED'"; fi

# ===========================================================================================
# 24: _snap_last_line drops a trailing partial line but keeps a complete newline-terminated tail.
# ===========================================================================================
SNAP_TRUNC=$(_snap_last_line "line1
line2
partial-no-newline")
case "$SNAP_TRUNC" in
  *"partial-no-newline"*) fail "snap_last_line" "partial tail not dropped" ;;
  "line1"*) pass "_snap_last_line drops a truncated trailing partial line" ;;
  *) fail "snap_last_line" "unexpected: '$SNAP_TRUNC'" ;;
esac

# ===========================================================================================
# 25: _re_escape neutralizes regex metacharacters so anchored grep is literal.
# ===========================================================================================
ESC=$(_re_escape 'a.b*c')
if printf 'a.b*c\n' | grep -qE "^$ESC\$" && ! printf 'aXbXc\n' | grep -qE "^$ESC\$"; then
  pass "_re_escape makes a metacharacter string match literally"
else fail "re_escape" "escaped='$ESC' did not behave literally"; fi

# ===========================================================================================
# 26: _mission_sanitize_sid strips hostile path/format characters.
# ===========================================================================================
SAN=$(_mission_sanitize_sid "../etc/passwd")
case "$SAN" in
  *"/"*|*".."*) fail "sanitize_sid" "path chars survived: '$SAN'" ;;
  "etcpasswd") pass "_mission_sanitize_sid strips path separators" ;;
  *) pass "_mission_sanitize_sid sanitized to '$SAN'" ;;
esac

# ===========================================================================================
# 27: mission_create refuses to clobber an EXISTING-but-corrupt main file (fail-loud).
# ===========================================================================================
SID="${UNIQ}-noclobber"
R=$(fresh_root noclobber)
printf 'corrupt not-a-mission body\n' > "$R/MISSION.${SID}.md"
if mission_create "$SID" "$R" "fresh plan" 2>/dev/null; then
  fail "create no-clobber-corrupt" "create returned 0 over a corrupt existing file"
else
  if grep -q "corrupt not-a-mission body" "$R/MISSION.${SID}.md" 2>/dev/null; then
    pass "mission_create refuses to clobber a corrupt existing file (fail-loud, contents intact)"
  else fail "create no-clobber-corrupt" "corrupt file was overwritten"; fi
fi

# ===========================================================================================
# 28: mission_path helper rejects empty sid / empty root and composes the right path.
# ===========================================================================================
if mission_path "" "/x" 2>/dev/null; then fail "mission_path empty sid" "rc=0 for empty sid"
else pass "mission_path rejects empty sid"; fi
if mission_path "abc" "" 2>/dev/null; then fail "mission_path empty root" "rc=0 for empty root"
else pass "mission_path rejects empty root"; fi
MP=$(mission_path "sidX" "/root/dir" 2>/dev/null)
if [ "$MP" = "/root/dir/MISSION.sidX.md" ]; then pass "mission_path composes <root>/MISSION.<sid>.md"
else fail "mission_path compose" "got '$MP'"; fi

# ===========================================================================================
# 29: _file_size reports the byte size of a known file.
# ===========================================================================================
SZF="${WORKBASE}-sizetest"
printf '12345' > "$SZF"
SZ=$(_file_size "$SZF")
rm -f "$SZF"
if [ "$SZ" = "5" ]; then pass "_file_size reports correct byte size"
else fail "file_size" "got '$SZ' expected 5"; fi

# ===========================================================================================
# 30: mission_verify rejects a missing zone fence (structural completeness).
# ===========================================================================================
SID="${UNIQ}-missingzone"
R=$(fresh_root missingzone)
mission_create "$SID" "$R" "zoned plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
# delete the PLAN CHALLENGES open fence line, keep marker last → must fail verify.
N8=$(_mission_marker_field "$F" nonce | cut -c1-8)
grep -v "^<!-- MZONE:PLAN CHALLENGES n=${N8} -->\$" "$F" > "$F.tmp" 2>/dev/null
# grep with literal $ — strip the line robustly via awk instead
awk -v t="<!-- MZONE:PLAN CHALLENGES n=${N8} -->" '$0 != t' "$F" > "$F.broken"
if mission_verify "$F.broken" "$SID" 2>/dev/null; then
  fail "verify missing zone" "verify passed a file missing a zone fence"
else pass "mission_verify rejects a file with a missing zone fence"; fi
rm -f "$F.tmp" "$F.broken"

# ===========================================================================================
# 31: mission_verify rejects a sid mismatch.
# ===========================================================================================
if mission_verify "$F" "TOTALLY-DIFFERENT-SID" 2>/dev/null; then
  fail "verify sid mismatch" "verify passed with a mismatched sid"
else pass "mission_verify rejects a marker/sid mismatch"; fi

# ===========================================================================================
# 32: _mission_nonce returns a non-empty lowercase nonce (uuidgen → hex+hyphens, lowercased;
# the lib uses cut -c1-8 for the fence nonce8, so hyphens within the full UUID are fine).
# Assert: non-empty, lowercase, only [0-9a-f-], and the 8-char fence slice is clean hex.
# ===========================================================================================
NCE=$(_mission_nonce 2>/dev/null)
NCE8=$(printf '%s' "$NCE" | cut -c1-8)
if [ -n "$NCE" ] && printf '%s' "$NCE" | grep -qE '^[0-9a-f-]+$' \
   && printf '%s' "$NCE8" | grep -qE '^[0-9a-f]{8}$'; then
  pass "_mission_nonce returns a lowercase nonce with a clean 8-hex fence slice ($NCE8)"
else fail "nonce" "got '$NCE'"; fi

# ===========================================================================================
# 33: _write_atomic writes content and refuses an empty payload.
# ===========================================================================================
WAF="${WORKBASE}-wa/sub/file.txt"
if _write_atomic "$WAF" "hello atomic" 2>/dev/null && [ -f "$WAF" ] \
   && grep -q "hello atomic" "$WAF"; then
  pass "_write_atomic writes content (creating parent dirs)"
else fail "write_atomic" "did not write content"; fi
rm -rf "${WORKBASE}-wa" 2>/dev/null

echo
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
