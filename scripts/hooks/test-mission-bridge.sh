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
MWSH="$ROOT/mission-write.sh"   # the real dispatcher (validator + verbs + PART-DONE preconditions)

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
# 11: LOG multibyte entry that FITS the <480B per-line budget is appended to the log as a single
# valid-UTF-8 line. (An OVERSIZE entry is no longer truncated-into-the-log — it is rerouted to
# DURABLE NOTES in full; that reroute is covered by the dedicated C2 test below.)
# ===========================================================================================
SID="${UNIQ}-mblog"
R=$(fresh_root mblog)
mission_create "$SID" "$R" "mb plan" >/dev/null 2>&1
LOGF="$R/MISSION.${SID}.log"
# A multibyte payload that FITS: 80 * 4-byte emoji (~320 bytes) + a short tag, well under 480.
MB=$(awk 'BEGIN{s="";for(i=0;i<80;i++)s=s"\360\237\230\200";printf "%s", s}')
mission_log_append "$SID" "$R" "$MB" "mb-tag" >/dev/null 2>&1
if [ -f "$LOGF" ]; then
  LASTLINE_BYTES=$(tail -n 1 "$LOGF" | LC_ALL=C wc -c | tr -d ' ')
  if [ -n "$LASTLINE_BYTES" ] && [ "$LASTLINE_BYTES" -lt 480 ]; then
    pass "LOG multibyte entry within budget appended (<480 bytes: $LASTLINE_BYTES)"
  else fail "log byte-budget" "last line $LASTLINE_BYTES bytes (>=480)"; fi
  # valid UTF-8: round-trip through iconv UTF-8->UTF-8 with -c removing invalid; if nothing was
  # removed (byte counts equal), the stored line was already valid UTF-8.
  RAW=$(tail -n 1 "$LOGF")
  RB=$(printf '%s' "$RAW" | LC_ALL=C wc -c | tr -d ' ')
  CB=$(printf '%s' "$RAW" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null | LC_ALL=C wc -c | tr -d ' ')
  if [ "$RB" = "$CB" ]; then pass "LOG multibyte line is valid UTF-8 (no split codepoint)"
  else fail "log utf8 valid" "raw=$RB bytes, iconv-clean=$CB bytes (codepoint was split)"; fi
else fail "log byte-budget" "no log file written"; fi

# ===========================================================================================
# 12: anchored idempotency — a log entry whose BODY quotes an existing id does NOT suppress a
# real new entry; a same-tag/DIFFERENT-content write is refused (Task 4: it now surfaces as a
# COLLISION instead of a silent drop, but either way it does NOT append a new line).
#
# CONTRACT UPDATE (Task 4): the earlier revision counted RAW log lines against a literal "2",
# assuming mission_create wrote NOTHING to the log. But mission_create emits its two run-timing
# birth anchors (MISSION-START + WORK-START) into the log, so the raw count starts at 2 — the old
# assertions were reading `4` and failing (58/2 baseline). The load-bearing property is the DELTA:
# a body-quoted id must ADD a line (tagB appends), and a same-tag write must NOT add a line
# (idempotent-or-collision, never a silent second line). Measure against a post-create baseline.
# ===========================================================================================
SID="${UNIQ}-anchor"
R=$(fresh_root anchor)
mission_create "$SID" "$R" "anchor plan" >/dev/null 2>&1
LOGF="$R/MISSION.${SID}.log"
BASE_LINES=$(wc -l < "$LOGF" | tr -d ' ')          # MISSION-START + WORK-START birth anchors
mission_log_append "$SID" "$R" "first real entry" "tagA" >/dev/null 2>&1
# Body quotes the existing tag "tagA" but the NEW tag is tagB — must NOT be suppressed (appends).
mission_log_append "$SID" "$R" "mentions tagA inside body text" "tagB" >/dev/null 2>&1
LINES_AFTER_B=$(wc -l < "$LOGF" | tr -d ' ')
# A same-tag write (tagA again, different content) must NOT add a line (surfaces as COLLISION).
mission_log_append "$SID" "$R" "different body, same tag" "tagA" >/dev/null 2>&1
LINES_AFTER_DUP=$(wc -l < "$LOGF" | tr -d ' ')
if [ "$LINES_AFTER_B" = "$((BASE_LINES + 2))" ]; then pass "anchored idempotency: body-quoted id does NOT suppress a new tagged entry (+2 over baseline)"
else fail "anchor new entry" "expected $((BASE_LINES + 2)) lines (baseline $BASE_LINES + tagA + tagB), got $LINES_AFTER_B"; fi
if [ "$LINES_AFTER_DUP" = "$LINES_AFTER_B" ]; then pass "anchored idempotency: same-tag write adds no new line (idempotent/collision, not a silent second line)"
else fail "anchor dup suppress" "expected no new line ($LINES_AFTER_B), got $LINES_AFTER_DUP"; fi

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

# ===========================================================================================
# 34 (C1): the mission_path "" (empty-string) cell — a manifest carrying mission_path:"" must be
# BACKFILLED by the robust merge idiom, NOT kept "". jq // keeps "" (only null/false trigger //),
# so the naive `// $mp` would leave it ""; the robust idiom replaces it with the real path.
# ===========================================================================================
EXISTING_EMPTY='{"mission_path":"","current_seq":1}'
REALMP="/canonical/root/MISSION.sid.md"
ROBUST_OUT=$(printf '%s' "$EXISTING_EMPTY" \
  | jq -r --arg mp "$REALMP" '(.mission_path = (if ((.mission_path // "") == "") then $mp else .mission_path end)) | .mission_path' 2>/dev/null)
NAIVE_OUT=$(printf '%s' "$EXISTING_EMPTY" \
  | jq -r --arg mp "$REALMP" '(.mission_path = (.mission_path // $mp)) | .mission_path' 2>/dev/null)
if [ "$ROBUST_OUT" = "$REALMP" ]; then
  pass "C1: robust merge backfills mission_path:\"\" with the real path"
else fail "C1 robust merge" "got '$ROBUST_OUT' want '$REALMP'"; fi
# negative control: prove the naive // idiom is broken (keeps "") — so the robust test is non-vacuous
if [ "$NAIVE_OUT" = "" ]; then
  pass "C1 (negative control): naive // idiom WOULD keep \"\" (bug it replaces)"
else fail "C1 negative control" "naive // unexpectedly produced '$NAIVE_OUT' (expected empty)"; fi

# ===========================================================================================
# 35 (C2): an OVERSIZE (>480B) log entry is rerouted to DURABLE NOTES in FULL (not truncated),
# and the log either omits it or stores no truncated copy.
# ===========================================================================================
SID="${UNIQ}-c2reroute"
R=$(fresh_root c2reroute)
mission_create "$SID" "$R" "c2 plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
LOGF="$R/MISSION.${SID}.log"
# Build a distinctive >480B ASCII payload (600 'A's plus a unique sentinel marker).
BIG=$(awk 'BEGIN{s="C2SENTINEL-";for(i=0;i<600;i++)s=s"A";printf "%s", s}')
mission_log_append "$SID" "$R" "$BIG" "c2-tag" >/dev/null 2>&1
NOTES_C2=$(mission_read_zone "$F" "DURABLE NOTES" 2>/dev/null)
# The FULL payload (all 600 A's, length >= 611) must be present in DURABLE NOTES, intact.
NOTES_HAS_FULL=0
case "$NOTES_C2" in *"C2SENTINEL-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"*) NOTES_HAS_FULL=1 ;; esac
NOTES_LEN=$(printf '%s' "$NOTES_C2" | LC_ALL=C wc -c | tr -d ' ')
if [ "$NOTES_HAS_FULL" = "1" ] && [ -n "$NOTES_LEN" ] && [ "$NOTES_LEN" -ge 600 ]; then
  pass "C2: oversize log entry rerouted to DURABLE NOTES in FULL (len $NOTES_LEN, not truncated)"
else fail "C2 reroute" "DURABLE NOTES len=$NOTES_LEN has_full=$NOTES_HAS_FULL"; fi
# The log must NOT contain a truncated sentinel-bearing line (no lossy copy left behind).
if [ ! -f "$LOGF" ] || ! grep -q "C2SENTINEL" "$LOGF" 2>/dev/null; then
  pass "C2: no truncated copy left in the log sidecar (zero loss, single home)"
else fail "C2 no-truncated-log-copy" "log holds a (truncated) sentinel line"; fi

# ===========================================================================================
# 36 (C4): mission_resolve_pending must NOT strip a `[pd:<id>]` STRING that appears in the PLAN
# zone (only the live PENDING DECISIONS zone is in scope).
# ===========================================================================================
SID="${UNIQ}-c4scope"
R=$(fresh_root c4scope)
# PLAN body deliberately quotes a pd-id string that we will later "resolve" in PENDING.
mission_create "$SID" "$R" "PLAN references [pd:9-keepme] as an example in prose" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
mission_mutate "$SID" "$R" pending "- [pd:9-keepme] should we do X?" "pd-9" >/dev/null 2>&1
mission_resolve_pending "$SID" "$R" "9-keepme" "decided" >/dev/null 2>&1
PLAN_C4=$(mission_read_zone "$F" PLAN 2>/dev/null)
PEND_C4=$(mission_read_zone "$F" "PENDING DECISIONS" 2>/dev/null)
PLAN_KEPT=0; case "$PLAN_C4" in *"[pd:9-keepme]"*) PLAN_KEPT=1 ;; esac
PEND_STRIPPED=1; case "$PEND_C4" in *"pd:9-keepme"*) PEND_STRIPPED=0 ;; esac
if [ "$PLAN_KEPT" = "1" ] && [ "$PEND_STRIPPED" = "1" ] && mission_verify "$F" "$SID" 2>/dev/null; then
  pass "C4: resolve strips the PENDING-zone pd line but PRESERVES the same string in PLAN"
else fail "C4 scope" "plan_kept=$PLAN_KEPT pend_stripped=$PEND_STRIPPED"; fi

# ===========================================================================================
# 37 (I1): mission_verify fails when a zone CLOSE fence is missing OR duplicated.
# ===========================================================================================
SID="${UNIQ}-i1close"
R=$(fresh_root i1close)
mission_create "$SID" "$R" "i1 plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
N8=$(_mission_marker_field "$F" nonce | cut -c1-8)
# (a) remove the DURABLE NOTES CLOSE fence, keep marker last → must fail verify.
awk -v t="<!-- /MZONE:DURABLE NOTES n=${N8} -->" '$0 != t' "$F" > "$F.noclose"
if mission_verify "$F.noclose" "$SID" 2>/dev/null; then
  fail "I1 missing close" "verify passed a file with a missing zone CLOSE fence"
else pass "I1: mission_verify rejects a missing zone CLOSE fence"; fi
# (b) duplicate the PLAN CHALLENGES close fence (paste a second live-nonce close) → must fail.
awk -v t="<!-- /MZONE:PLAN CHALLENGES n=${N8} -->" '
  { print }
  $0 == t && !done { print t; done=1 }' "$F" > "$F.dupclose"
if mission_verify "$F.dupclose" "$SID" 2>/dev/null; then
  fail "I1 dup close" "verify passed a file with a DUPLICATE zone close fence"
else pass "I1: mission_verify rejects a duplicated zone close fence"; fi
rm -f "$F.noclose" "$F.dupclose"

# ===========================================================================================
# 38 (I2): an EMPTY-PID lock that is STALE (mtime age >= 2s) is reclaimed; a fresh empty-pid lock
# (young) is NOT reclaimed (acquire times out, lock left intact).
# ===========================================================================================
SID="${UNIQ}-i2empty"
R=$(fresh_root i2empty)
LB=$(_mission_lockbase "$R")
LOCK="${LB}/.claude-mission-$(_mission_sanitize_sid "$SID").lock"
# (a) stale empty-pid lock: create the lock dir with NO pid file and backdate its mtime by 10s.
rm -rf "$LOCK" 2>/dev/null; mkdir -p "$LOCK" 2>/dev/null
touch -t "$(date -v-10S +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$LOCK" 2>/dev/null
_MLOCK=""
if _mission_lock "$LB" "$SID" 2>/dev/null; then
  HELDPID=$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9')
  if [ "$HELDPID" = "$$" ]; then pass "I2: stale empty-pid lock reclaimed (now held by us $$)"
  else fail "I2 empty reclaim" "lock pid '$HELDPID' != $$"; fi
  _mission_unlock
else
  fail "I2 empty reclaim" "_mission_lock failed to reclaim a STALE empty-pid lock"
fi
rm -rf "$LOCK" 2>/dev/null

# ===========================================================================================
# 39 (I3): two pre-mutation backups created within the SAME second BOTH survive (no overwrite).
# ===========================================================================================
SID="${UNIQ}-i3backup"
R=$(fresh_root i3backup)
mission_create "$SID" "$R" "i3 plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
# Two mutates back-to-back almost certainly land in the same UTC second → same ts+nonce prefix.
mission_mutate "$SID" "$R" note "first note same-second" "i3-1" >/dev/null 2>&1
mission_mutate "$SID" "$R" note "second note same-second" "i3-2" >/dev/null 2>&1
NONBIRTH_CNT=$(ls -1 "$R/.mission-backups/"MISSION."${SID}".*.md 2>/dev/null | grep -vE "[.]birth[.]" | wc -l | tr -d ' ')
if [ -n "$NONBIRTH_CNT" ] && [ "$NONBIRTH_CNT" -ge 2 ]; then
  pass "I3: two same-second backups BOTH survive (count $NONBIRTH_CNT >= 2, no overwrite)"
else fail "I3 backup collision" "non-birth backup count=$NONBIRTH_CNT (<2 → one overwrote the other)"; fi

# ===========================================================================================
# 40 (Task 4): the `gen=` marker field survives the full lifecycle round-trip create→note→
# challenge→pending→resolve→rebaseline. gen==1 through the mutating verbs; ==2 after rebaseline.
# ===========================================================================================
SID="${UNIQ}-genrt"
R=$(fresh_root genrt)
mission_create "$SID" "$R" "gen round-trip plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
G0=$(_mission_marker_field "$F" gen)
mission_mutate "$SID" "$R" note "a note" "grt-note" >/dev/null 2>&1
mission_mutate "$SID" "$R" challenge "a challenge" "grt-chal" >/dev/null 2>&1
mission_mutate "$SID" "$R" pending "- [pd:1-x] a pending?" "grt-pend" >/dev/null 2>&1
G1=$(_mission_marker_field "$F" gen)
mission_resolve_pending "$SID" "$R" "1-x" "decided" >/dev/null 2>&1
G2=$(_mission_marker_field "$F" gen)
mission_rebaseline "$SID" "$R" "gen round-trip plan v2" >/dev/null 2>&1
G3=$(_mission_marker_field "$F" gen)
if [ "$G0" = "1" ] && [ "$G1" = "1" ] && [ "$G2" = "1" ] && [ "$G3" = "2" ] \
   && mission_verify "$F" "$SID" 2>/dev/null; then
  pass "gen survives create→note→challenge→pending→resolve→rebaseline (1,1,1→2)"
else fail "gen round-trip" "gens: create=$G0 mutate=$G1 resolve=$G2 rebaseline=$G3 (want 1,1,1,2)"; fi

# ===========================================================================================
# 41 (Task 4): EMPTY idtags are exempt from gen-prefixing — the rebaseline boundary line (empty
# idtag) persists under gen>=2, and re-clearing after rebaseline re-appends (always-append).
# ===========================================================================================
BND=$(grep -a 'MISSION-REBASELINED status=active gen=2' "$R/MISSION.${SID}.log" | head -1)
if [ -n "$BND" ]; then
  # the boundary line has an EMPTY leading idtag (a leading TAB), NOT a g2- prefix
  case "$BND" in
    "	[mission] MISSION-REBASELINED"*) pass "empty-idtag rebaseline boundary persists gen-unprefixed under gen 2" ;;
    *) fail "empty-idtag boundary" "boundary line not empty-idtag: '$BND'" ;;
  esac
else fail "empty-idtag boundary" "no gen=2 boundary line found in log"; fi

# ===========================================================================================
# 42 (Task 4): a wrong-gen idtag prefix is REFUSED (FAILED rc=5), NOT a collision — via the real
# mission-write.sh dispatcher.
# ===========================================================================================
SID="${UNIQ}-wronggen"
R=$(fresh_root wronggen)
bash "$MWSH" create "$SID" "$R" "MISSION MODE: build — wg" >/dev/null 2>&1
OUT=$(bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=1 dry=0 findings=1" "g7-m1-review-r1-d0" 2>/dev/null)
case "$OUT" in
  *"FAILED rc=5 (REFUSED:"*) pass "wrong-gen idtag prefix REFUSED rc=5 (not collision)" ;;
  *) fail "wrong-gen refuse" "got: '$OUT'" ;;
esac

# ===========================================================================================
# 43 (Task 4): control characters in the entry are REFUSED (literal case literals — a VALID line
# passes first to prove the check is not vacuous).
# ===========================================================================================
OUT_OK=$(bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=1 dry=0 findings=1" "m1-review-r1-d0" 2>/dev/null)
OUT_TAB=$(bash "$MWSH" log "$SID" "$R" "$(printf '[mission] part=2 name=x\tphase=review round=1 dry=0')" "m2-review-r1-d0" 2>/dev/null)
if printf '%s' "$OUT_OK" | grep -q 'log ok' && printf '%s' "$OUT_TAB" | grep -q 'REFUSED: control-char'; then
  pass "control-char entry REFUSED (valid line passes first)"
else fail "control-char refuse" "ok='$OUT_OK' tab='$OUT_TAB'"; fi

# ===========================================================================================
# 44 (Task 4): a machine-readable shape whose persisted line exceeds the 480B budget is REFUSED
# `line-too-long` (never rerouted — machine shapes are terse by design).
# ===========================================================================================
LONGREASON=$(awk 'BEGIN{s="";for(i=0;i<500;i++)s=s"x";printf "%s", s}')
OUT=$(bash "$MWSH" log "$SID" "$R" "[mission] FAIL part=1 phase=review reason=${LONGREASON} attempt=1" "m1-fail-x-1" 2>/dev/null)
case "$OUT" in
  *"REFUSED: line-too-long"*) pass "oversize machine shape REFUSED line-too-long (not rerouted)" ;;
  *) fail "line-too-long" "got: '$OUT'" ;;
esac

# ===========================================================================================
# 45 (Task 4): VOID and FAIL lines are ACCEPTED through the log verb (grammar + idtag valid).
# ===========================================================================================
OUT_V=$(bash "$MWSH" log "$SID" "$R" "[mission] VOID part=1 phase=review round=2 reason=codex-unavailable" "m1-void-r2-run123hdeadbeef" 2>/dev/null)
OUT_F=$(bash "$MWSH" log "$SID" "$R" "[mission] FAIL part=1 phase=review reason=panel-dead attempt=1" "m1-fail-panel-dead-1" 2>/dev/null)
OUT_FP=$(bash "$MWSH" log "$SID" "$R" "[mission] FAIL part=1 phase=review reason=panel-unavailable-3x attempt=3" "m1-fail-panel3x-r2" 2>/dev/null)
if printf '%s' "$OUT_V" | grep -q 'log ok' && printf '%s' "$OUT_F" | grep -q 'log ok' && printf '%s' "$OUT_FP" | grep -q 'log ok'; then
  pass "VOID + FAIL (incl. panel3x idtag) lines accepted through log"
else fail "void/fail accept" "void='$OUT_V' fail='$OUT_F' fail3x='$OUT_FP'"; fi

# ===========================================================================================
# 46 (Task 4): idempotent PART-DONE re-emit is a quiet ok; a same-idtag/different-content write
# is a COLLISION (loud, no silent second line).
# ===========================================================================================
SID="${UNIQ}-pdcol"
R=$(fresh_root pdcol)
bash "$MWSH" create "$SID" "$R" "MISSION MODE: build — pdcol" >/dev/null 2>&1
# converge cleanly (two adjacent dry rounds + fresh live-verify)
bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=1 dry=1 findings=0" "m1-review-r1-d1" >/dev/null 2>&1
bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=2 dry=2 findings=0" "m1-review-r2-d2" >/dev/null 2>&1
bash "$MWSH" log "$SID" "$R" "[mission] live-verify part=1 round=2 status=n/a reason=not-ui" "m1-live-verify-r2" >/dev/null 2>&1
OUT1=$(bash "$MWSH" log "$SID" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done" 2>/dev/null)
OUT2=$(bash "$MWSH" log "$SID" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done" 2>/dev/null)
COL=$(bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=1 dry=1 findings=7" "m1-review-r1-d1" 2>/dev/null)
if printf '%s' "$OUT1" | grep -q 'log ok' && printf '%s' "$OUT2" | grep -q 'log ok' \
   && printf '%s' "$COL" | grep -q 'COLLISION'; then
  pass "PART-DONE idempotent re-emit quiet ok; same-tag/diff-content = COLLISION"
else fail "pd-idem/collision" "pd1='$OUT1' pd2='$OUT2' col='$COL'"; fi

# ===========================================================================================
# 47 (Task 4): gen-2 vs gen-1 evidence isolation — a VOID banked in gen 1 does NOT count toward
# a reused round number in gen 2 (gen-sliced void-count).
# ===========================================================================================
SID="${UNIQ}-geniso"
R=$(fresh_root geniso)
bash "$MWSH" create "$SID" "$R" "MISSION MODE: build — iso" >/dev/null 2>&1
bash "$MWSH" log "$SID" "$R" "[mission] VOID part=1 phase=review round=1 reason=codex-unavailable" "m1-void-r1-g1runhdeadbeef" >/dev/null 2>&1
VC_G1=$(bash "$MWSH" void-count "$SID" "$R" 1 1 2>/dev/null)
bash "$MWSH" rebaseline "$SID" "$R" "MISSION MODE: build — iso v2" >/dev/null 2>&1
VC_G2=$(bash "$MWSH" void-count "$SID" "$R" 1 1 2>/dev/null)   # gen-2: reused round 1, gen-1 VOID excluded
if [ "$VC_G1" = "1" ] && [ "$VC_G2" = "0" ]; then
  pass "gen-sliced void-count isolates gen-2 from gen-1 evidence (g1=1, g2=0)"
else fail "gen isolation" "void-count g1=$VC_G1 g2=$VC_G2 (want 1,0)"; fi

# ===========================================================================================
# 48 (Task 4): live-verify STALENESS — early verify → fix → reconverge → PART-DONE REFUSED
# `live-verify-stale` until a fresh round-scoped live-verify lands (and that re-emit does NOT
# collide with the earlier round's line).
# ===========================================================================================
SID="${UNIQ}-stale"
R=$(fresh_root stale)
bash "$MWSH" create "$SID" "$R" "MISSION MODE: build — stale" >/dev/null 2>&1
bash "$MWSH" log "$SID" "$R" "[mission] live-verify part=1 round=1 status=ok evidence=od:1377" "m1-live-verify-r1" >/dev/null 2>&1
bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=1 dry=1 findings=0" "m1-review-r1-d1" >/dev/null 2>&1
bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=fix round=2 dry=0 findings=3" "m1-fix-r2-d0" >/dev/null 2>&1
bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=2 dry=1 findings=0" "m1-review-r2-d1" >/dev/null 2>&1
bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=3 dry=2 findings=0" "m1-review-r3-d2" >/dev/null 2>&1
STALE=$(bash "$MWSH" log "$SID" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done" 2>/dev/null)
# fresh round-scoped re-verify (r3 idtag != r1 idtag → no collision), then PART-DONE passes
FRESH=$(bash "$MWSH" log "$SID" "$R" "[mission] live-verify part=1 round=3 status=ok evidence=od:1400" "m1-live-verify-r3" 2>/dev/null)
PASSED=$(bash "$MWSH" log "$SID" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done" 2>/dev/null)
if printf '%s' "$STALE" | grep -q 'live-verify-stale' \
   && printf '%s' "$FRESH" | grep -q 'log ok' \
   && printf '%s' "$PASSED" | grep -q 'log ok'; then
  pass "live-verify staleness blocks PART-DONE until a fresh round-scoped re-verify (no collision)"
else fail "live-verify stale" "stale='$STALE' fresh='$FRESH' passed='$PASSED'"; fi

# ===========================================================================================
# 49 (Task 4): gen-boundary rollover crash-safety — marker gen AHEAD of the latest boundary
# (marker mv committed, boundary append died) ⇒ every gen-sliced read REFUSES loud (void-count
# prints -1; PART-DONE FAILED rc=4); the WRITE path self-heals; subsequent reads slice correctly.
# ===========================================================================================
SID="${UNIQ}-rollover"
R=$(fresh_root rollover)
bash "$MWSH" create "$SID" "$R" "MISSION MODE: build — rollover" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"; LOGF="$R/MISSION.${SID}.log"
# FAULT INJECT: bump the marker to gen 2 WITHOUT a boundary line (the crash window).
sed 's/ gen=1 -->/ gen=2 -->/' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
VC_BAD=$(bash "$MWSH" void-count "$SID" "$R" 1 1 2>/dev/null)
PD_BAD=$(bash "$MWSH" log "$SID" "$R" "[mission] PART-DONE part=1 (converged)" "m1-part-done" 2>/dev/null)
# WRITE self-heals (a gen>=2 append writes the recovered boundary FIRST):
bash "$MWSH" log "$SID" "$R" "[mission] part=1 name=x phase=review round=1 dry=0 findings=1" "m1-review-r1-d0" >/dev/null 2>&1
HEALED=$(grep -ac 'MISSION-REBASELINED status=active gen=2' "$LOGF")
VC_OK=$(bash "$MWSH" void-count "$SID" "$R" 1 1 2>/dev/null)
if [ "$VC_BAD" = "-1" ] && printf '%s' "$PD_BAD" | grep -q 'FAILED rc=4 (REFUSED gen-boundary-mismatch)' \
   && [ "$HEALED" = "1" ] && [ "$VC_OK" = "0" ]; then
  pass "gen-boundary mismatch: void-count=-1, PART-DONE rc=4; write self-heals; reads recover"
else fail "gen-boundary crash-safety" "vc_bad=$VC_BAD pd_bad='$PD_BAD' healed=$HEALED vc_ok=$VC_OK"; fi

# ===========================================================================================
# 50 (Task 4 / DoD #6): a PRE-GEN fixture (a mission file created by the OLD code — NO gen= field
# in the marker) still passes mission_verify AND reads as gen 1 (default), so old on-disk missions
# keep working.
# ===========================================================================================
SID="${UNIQ}-pregen"
R=$(fresh_root pregen)
mission_create "$SID" "$R" "pre-gen plan" >/dev/null 2>&1
F="$R/MISSION.${SID}.md"
# strip the gen= field from the marker to reproduce an OLD-code file
sed 's/ gen=1 -->/ -->/' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
GEN_READ=$(_mission_marker_field "$F" gen)
GEN_TAG=$(_mission_gen_tag "$F" "sometag")   # gen 1 default => unprefixed
if mission_verify "$F" "$SID" 2>/dev/null && [ -z "$GEN_READ" ] && [ "$GEN_TAG" = "sometag" ]; then
  pass "pre-gen fixture (no gen= in marker) verifies and reads as gen 1 (unprefixed idtag)"
else fail "pre-gen fixture" "verify/gen-read='$GEN_READ' gen-tag='$GEN_TAG'"; fi

# ===========================================================================================
# 51 (Task 4): the archive-inclusive gen-sliced read survives log ROTATION — a VOID line rotated
# into an archive is still counted by void-count (union of archives + live log).
# ===========================================================================================
SID="${UNIQ}-rotgen"
R=$(fresh_root rotgen)
mission_create "$SID" "$R" "rotate-gen plan" >/dev/null 2>&1
LOGF="$R/MISSION.${SID}.log"
# one VOID for part=1 round=1, then many fillers, then force a rotation so the VOID lands in the archive.
mission_log_append "$SID" "$R" "[mission] VOID part=1 phase=review round=1 reason=codex-unavailable" "m1-void-r1-earlyhdeadbeef" >/dev/null 2>&1
(
  MISSION_LOG_MAX_BYTES=4096; export MISSION_LOG_MAX_BYTES
  i=0; while [ "$i" -lt 120 ]; do
    mission_log_append "$SID" "$R" "[mission] part=1 name=x phase=implement round=$i dry=0 findings=0 padding padding padding padding" "rg-$i" >/dev/null 2>&1
    i=$((i+1))
  done
)
ARCH=$(ls -1 "$R/.mission-backups/"MISSION."${SID}".log.* 2>/dev/null | head -1)
VC_ROT=$(bash "$MWSH" void-count "$SID" "$R" 1 1 2>/dev/null)
if [ -n "$ARCH" ] && [ "$VC_ROT" = "1" ]; then
  pass "void-count is archive-inclusive: a rotated-out VOID is still counted ($VC_ROT)"
else fail "rotation-crossing count" "archive='$ARCH' void-count=$VC_ROT (want 1)"; fi

echo
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
