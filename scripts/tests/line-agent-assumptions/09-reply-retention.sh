#!/usr/bin/env bash
# 09 — Does retention ever delete an answer nobody has read?
#
# The reply dropbox exists to be the GUARANTEED delivery path for a window that cannot receive a
# SendMessage. Adding a reaper to a guaranteed-delivery mailbox is the single most dangerous change
# this feature can take: reaping too late costs disk, reaping too early destroys the one artifact
# the whole feature exists to produce, silently, with no error at either end. So the reap rule is
# AND, never OR - already-read AND older than REPLY_RETENTION_DAYS - and this file gates that AND.
#
# Both fixture replies are ANCIENT. The ONLY difference between them is whether the recipient's
# last-read mark covers them, so a reaper that has quietly become age-only cannot pass:
#
#   A1 — a read + old reply IS reaped              (retention actually does its job)
#   A2 — an UNREAD + old reply is NOT reaped       (the rule that matters; age alone is never enough)
#   A3 — a recently-seen contact SURVIVES the contact reap
#        (`find` answering "closed, last seen <date>" is the feature that turns "no such agent" into
#         a next step; a contact reap that ate live-ish entries would delete that answer)
#   A4 — with MORE replies than `replies` can display, the ones it did NOT display survive the reap
#        that `replies` itself triggers. A1-A3 all used a 2-file mailbox, so they could not see this:
#        `replies` shows at most MAX_ENTRY_FILES (20) but marked read with the NEWEST file's mtime,
#        which marks ALL N read, and main() then calls maybe_reap(). Observed with 25 replies: it
#        printed "Showing the newest 20; 5 older not shown", promised "25 file(s) left", and the
#        directory went 25 -> 15 in that one invocation. The 5 it had just said it was not showing
#        were destroyed, and a later explicit `reap` said "0 removed", so nothing reported the loss.
#   A5 — and the dry run agrees with the real pass about them (it counted them reapable while the
#        real pass had already eaten them - a dry run that does not share the predicates is a lie)
#
# Every assertion drives the REAL script as a subprocess (`reap` under a fake HOME) rather than
# reimplementing its predicates in bash - a reimplementation stays green after the real defense is
# deleted, which is the failure mode a regression gate exists to catch.
#
# NEGATIVE CONTROL: A2's fixture is unread only because the last-read mark predates its mtime. Run
# with LINE_AGENT_NEG_CONTROL=true and the mark is moved to NOW, making that same file read-and-old
# and therefore legitimately reap-eligible - so A2 MUST go RED. If A2 stays green when the file is
# genuinely reapable, A2 is not observing the reaper at all (e.g. the reaper never deletes anything,
# or the fixture never landed) and its green means nothing.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$SCRIPT" ] || { echo "INFRA: script not found: $SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="lac-atest"                       # same namespace marker the sibling tests reap on startup
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"

# --- startup orphan reaper: `finally` does not survive SIGKILL, so reap prior crashed runs -------
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
cleanup() { rm -rf "$FAKE_HOME" 2>/dev/null || echo "CLEANUP WARNING: could not remove $FAKE_HOME" >&2; }
trap cleanup EXIT

# The script derives every path it owns from Path.home(), so a fake HOME fully contains this test.
# The ONE path it does not derive from HOME is SOCK_DIR (/tmp/cc-socks), which is exactly why
# `reap` only DETECTS orphaned sockets and never unlinks them without an explicit --sockets: this
# test runs the real reaper on a shared machine and must not be able to disconnect a live window.
mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status" "$FAKE_HOME/claude-agent-replies"
DROPBOX="$FAKE_HOME/claude-agent-replies"
SID="00000000-0000-4000-8000-${RUN_ID}"

READ_FILE="${DROPBOX}/${SID}--from-peer-read--old.md"
UNREAD_FILE="${DROPBOX}/${SID}--from-peer-unread--old.md"
printf '# reply\nread and ancient\n'   > "$READ_FILE"
printf '# reply\nUNREAD and ancient\n' > "$UNREAD_FILE"

# Ages, in days back from now. Both are far past the 30d retention window; the read mark sits
# BETWEEN them, which is what makes one read and the other unread.
#   read file   -120d   <= mark  -> read   -> reapable
#   mark        -100d
#   unread file  -90d   >  mark  -> UNREAD -> immortal
NEG="${LINE_AGENT_NEG_CONTROL:-}"
python3 - "$FAKE_HOME" "$SID" "$READ_FILE" "$UNREAD_FILE" "$NEG" <<'PY'
import json, os, sys, time
home, sid, readf, unreadf, neg = sys.argv[1:6]
now = time.time()
d = 86400.0
os.utime(readf,   (now - 120 * d, now - 120 * d))
os.utime(unreadf, (now -  90 * d, now -  90 * d))
mark = now if neg == "true" else now - 100 * d
with open(os.path.join(home, ".claude", "agent-replies-read.json"), "w") as fh:
    json.dump({sid: mark}, fh)
# Contacts: one fresh entry (must survive) and one long-dead one (may be dropped). isoformat is the
# on-disk form the script writes with now_stamp().
import datetime
def stamp(days):
    return datetime.datetime.fromtimestamp(now - days * d).replace(microsecond=0).isoformat()
with open(os.path.join(home, ".claude", "agent-contacts.json"), "w") as fh:
    json.dump({
        "11111111-1111-4111-8111-111111111111": {
            "label": "fresh window", "handle": "atest-fresh", "cwd": home, "owns": "",
            "firstSeen": stamp(2), "lastSeen": stamp(1),
        },
        "22222222-2222-4222-8222-222222222222": {
            "label": "long gone window", "handle": "atest-ancient", "cwd": home, "owns": "",
            "firstSeen": stamp(900), "lastSeen": stamp(800),
        },
    }, fh)
PY

# Counter + string, NOT a bash array: on macOS bash 3.2 `${#arr[@]}` on an EMPTY array under `set -u`
# aborts with "unbound variable" — i.e. the all-assertions-passed path is exactly the one that would
# crash. Same bash-3.2 trap the sibling run-all.sh and 04 document.
FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

echo "--- dry run (nothing should be deleted) ---"
HOME="$FAKE_HOME" python3 "$SCRIPT" reap --dry-run 2>&1 | sed 's/^/    /'
[ -f "$READ_FILE" ]   || fail "DRY RUN deleted the read reply - --dry-run must not delete anything"
[ -f "$UNREAD_FILE" ] || fail "DRY RUN deleted the unread reply - --dry-run must not delete anything"

echo "--- real reap ---"
REAP_OUT="$(HOME="$FAKE_HOME" python3 "$SCRIPT" reap 2>&1)"
printf '%s\n' "$REAP_OUT" | sed 's/^/    /'

# --- A1 — a read + old reply IS reaped -------------------------------------------------------------
if [ -f "$READ_FILE" ]; then
  A1=kept; fail "A1 expected the read+120d-old reply to be reaped, it is still on disk"
else
  A1=reaped
fi
echo "A1 (read, 120d old):   ${A1}"

# --- A2 — an UNREAD + old reply is NEVER reaped ----------------------------------------------------
if [ -f "$UNREAD_FILE" ]; then
  A2=kept
else
  A2=reaped; fail "A2 the UNREAD 90d-old reply was DELETED - retention is reaping on age alone, which destroys undelivered answers"
fi
echo "A2 (UNREAD, 90d old):  ${A2}"

# --- A3 — a recently-seen contact survives the contact reap ----------------------------------------
A3="$(HOME="$FAKE_HOME" python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("missing"); sys.exit(0)
print("kept" if "11111111-1111-4111-8111-111111111111" in d else "dropped")
' "$FAKE_HOME/.claude/agent-contacts.json")"
echo "A3 (contact seen 1d ago): ${A3}"
[ "$A3" = "kept" ] || fail "A3 a contact seen 1 day ago was dropped ('${A3}') - that breaks find's 'closed, last seen <date>' answer"

# --- A4/A5 — more replies than `replies` can display -----------------------------------------------
# Skipped under NEG_CONTROL: that mode exists to prove A2's fixture is observable, and a second red
# assertion there would let "A2 went red" and "A4 went red" be confused for one another.
# A4's own control that it is not vacuous is INSIDE it: the same run must show the newest 20 actually
# being reaped. Its control that it can go RED is the pre-fix run recorded in the commit that added
# it - against the unfixed script all 25 files are destroyed and A4 fails.
if [ "$NEG" != "true" ]; then
  SID2="00000000-0000-4000-8000-${RUN_ID:0:8}bbbb"
  N_TOTAL=25
  N_SHOWN=20                                # MAX_ENTRY_FILES in line-agent-communicator.py
  i=1
  while [ "$i" -le "$N_TOTAL" ]; do
    printf '# reply\nanswer number %02d\n' "$i" > "${DROPBOX}/${SID2}--from-peer-$(printf '%02d' "$i").md"
    i=$((i + 1))
  done
  # Ages 41..65 days: EVERY file is past the 30d retention window, so age can never be the reason one
  # survives and another does not - only "was it displayed" can be. File 01 is the newest.
  python3 - "$DROPBOX" "$SID2" "$N_TOTAL" <<'PY'
import os, sys, time
box, sid, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
now, d = time.time(), 86400.0
for i in range(1, n + 1):
    t = now - (40 + i) * d
    os.utime(os.path.join(box, "%s--from-peer-%02d.md" % (sid, i)), (t, t))
PY
  # The earlier `reap` in this test stamped the once-a-day marker; without clearing it maybe_reap()
  # would no-op and A4 would pass vacuously.
  rm -f "$FAKE_HOME/.claude/.lac-reap-stamp"

  echo "--- replies (25 files, only 20 displayable; this invocation also triggers maybe_reap) ---"
  REPLIES_OUT="$(HOME="$FAKE_HOME" CLAUDE_SESSION_ID="$SID2" python3 "$SCRIPT" replies 2>&1)"
  printf '%s\n' "$REPLIES_OUT" | grep -E 'reply file|Showing the newest|non-destructive|NOT marked read' | sed 's/^/    /'

  LEFT="$(ls -1 "${DROPBOX}"/${SID2}--from-peer-*.md 2>/dev/null | wc -l | tr -d ' ')"
  NOT_SHOWN_LEFT=0
  i=$((N_SHOWN + 1))
  while [ "$i" -le "$N_TOTAL" ]; do
    [ -f "${DROPBOX}/${SID2}--from-peer-$(printf '%02d' "$i").md" ] && NOT_SHOWN_LEFT=$((NOT_SHOWN_LEFT + 1))
    i=$((i + 1))
  done
  echo "A4: files left=${LEFT} of ${N_TOTAL}; never-displayed files surviving=${NOT_SHOWN_LEFT} of $((N_TOTAL - N_SHOWN))"

  [ "$NOT_SHOWN_LEFT" = "$((N_TOTAL - N_SHOWN))" ] || \
    fail "A4 ${NOT_SHOWN_LEFT}/$((N_TOTAL - N_SHOWN)) of the replies \`replies\` said it was NOT showing survived - it deleted answers it never displayed"
  [ "$LEFT" -lt "$N_TOTAL" ] || \
    fail "A4 nothing at all was reaped, so A4 proves nothing - the maybe_reap() in that invocation did not run"

  # --- A5 — the dry run must agree with what the real pass would do -------------------------------
  DRY_OUT="$(HOME="$FAKE_HOME" CLAUDE_SESSION_ID="$SID2" python3 "$SCRIPT" reap --dry-run 2>&1)"
  DRY_LINE="$(printf '%s\n' "$DRY_OUT" | grep 'replies:' | sed 's/^ *//')"
  echo "A5: ${DRY_LINE}"
  case "$DRY_LINE" in
    *"0 read and older than"*) ;;
    *) fail "A5 the dry run claims it would remove replies that the real pass leaves alone: ${DRY_LINE}" ;;
  esac
  # Expected kept = the 5 never-displayed ones, PLUS the one A2 fixture (unread + 90d) still on disk
  # from earlier in this test. Spelled out rather than hardcoded so a change to either fixture is a
  # visible edit here and not a silently-passing off-by-one.
  N_KEPT_EXPECTED=$((N_TOTAL - N_SHOWN + 1))
  case "$DRY_LINE" in
    *"${N_KEPT_EXPECTED} old but UNREAD would be kept"*) ;;
    *) fail "A5 the dry run does not report the $((N_TOTAL - N_SHOWN)) never-displayed replies (+1 A2 fixture) as kept: ${DRY_LINE}" ;;
  esac
fi

# --- negative control ------------------------------------------------------------------------------
if [ "$NEG" = "true" ]; then
  if [ "$FAIL_N" -gt 0 ]; then
    echo "NEG-CONTROL OK: with the read mark moved to now, the A2 fixture became read+old and was correctly reaped, so A2 went RED (${FAIL_N} assertion(s) failed)"
    exit 0
  fi
  echo "NEG-CONTROL BROKEN: A2 stayed GREEN even though its fixture was read and 90 days old - A2 is not observing the reaper" >&2
  exit 1
fi

# --- verdict ---------------------------------------------------------------------------------------
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 09-reply-retention" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

cat > "${HERE}/09-reply-retention.fingerprint.json" <<EOF
{"assumption":"an_unread_reply_is_never_reaped_at_any_age","uname":"$(uname -s)","os_version":"$(sw_vers -productVersion 2>/dev/null || echo unknown)","read_old_reply":"${A1}","unread_old_reply":"${A2}","recent_contact":"${A3}","never_displayed_replies":"kept","dry_run_agrees_with_real_pass":true,"reply_retention_days":30,"contact_retention_days":180}
EOF

echo "PASS: 09-reply-retention - 9 assertions (dry-run deletes nothing x2, A1 read+old reaped, A2 UNREAD+old kept, A3 recent contact kept, A4 never-displayed replies survive + the reap was real, A5 dry run agrees x2)"
exit 0
