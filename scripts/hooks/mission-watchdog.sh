#!/usr/bin/env bash
# mission-watchdog.sh - detection-only watchdog for one long /mission helper (plan 5.3).
#
# USAGE
#   mission-watchdog.sh [--done=<path>] <sid> <label> <class> <path>...
# Launched with run_in_background beside each long helper. <path>... are that helper's OWN
# outputs and nothing else: the test runner's output file (not a result file written only at the
# end), the chunk's declared file set, or the codex-review run dir. Never a shared worktree or a
# transcript dir. A directory counts every file under it. A missing path counts as "not yet
# written"; its creation is progress.
#
# PROGRESS = any change in size or mtime of the declared paths. Writes anywhere else do not count.
#
# EXITS
#   0  done: the done-marker exists. Markers: --done=<path> if given, and always
#      <status-file>.done (the conductor may touch it when the helper finishes).
#   3  STALL: no progress for the idle window (MISSION_WATCHDOG_MIN minutes, default 20).
#   4  DEADLINE: the class deadline passed (non-test classes only).
#   2  usage error (nothing written).
# A test-run class (suite) never exits 4: past its deadline the status says state=overdue
# action=note and the watchdog keeps watching, so a run that is still progressing is never ended
# and a stall after the deadline is still caught. The part's wall clock is the real bound.
#
# CLASS DEADLINES (minutes; about 2x the slowest measured successful run, 2026-11-11)
#   chunk   60   implementer chunk
#   review  75   review barrier (codex-review panel + outer implementation-reviewer)
#   sweep   30   class sweep (one Codex Sol pass)
#   suite  160   full test suite (measured 66-80 min on a 2-CPU worker). Re-measure and lower
#                this when suite sharding lands (owned by the Online docker agent).
#
# STATUS FILE  ${MISSION_LIVENESS_DIR:-~/.claude/progress/mission-liveness}/<sid>.watchdog.<label>
#   One line, rewritten atomically on every state change and every poll:
#   watchdog sid=<sid> label=<label> class=<class> state=<running|overdue|stall|deadline|done|stopped>
#     action=<none|note|stop> idle_s=<n> elapsed_s=<n> deadline_min=<n> idle_min=<n> pid=<pid> at=<epoch>
#   action=stop means the conductor should TaskStop the helper (stall, or deadline for a non-test
#   helper); action=note means write a note and notify, nothing more.
#
# This script NEVER stops a helper and NEVER owns continuation. The conductor reads the status on
# its next wake (this exit or the heartbeat), TaskStops the helper when action=stop, writes a note,
# retries once, then parks.
#
# Test-only overrides: MISSION_WATCHDOG_IDLE_SECS, MISSION_WATCHDOG_DEADLINE_SECS,
# MISSION_WATCHDOG_POLL_SECS (default 30). macOS bash 3.2 compatible.

set -u

usage() { echo "usage: mission-watchdog.sh [--done=<path>] <sid> <label> <chunk|review|sweep|suite> <path>..." >&2; exit 2; }

DONE_EXTRA=""
case "${1:-}" in --done=*) DONE_EXTRA="${1#--done=}"; shift ;; esac
[ $# -ge 4 ] || usage
SID=$1; LABEL=$2; CLASS=$3; shift 3

case "$SID$LABEL" in *[!A-Za-z0-9._-]*|"") usage ;; esac
case "$CLASS" in
  chunk)  DEADLINE_MIN=60 ;;
  review) DEADLINE_MIN=75 ;;
  sweep)  DEADLINE_MIN=30 ;;
  suite)  DEADLINE_MIN=160 ;;
  *) usage ;;
esac
IS_TEST=0; [ "$CLASS" = suite ] && IS_TEST=1

IDLE_MIN=${MISSION_WATCHDOG_MIN:-20}
IDLE_SECS=${MISSION_WATCHDOG_IDLE_SECS:-$((IDLE_MIN * 60))}
DEADLINE_SECS=${MISSION_WATCHDOG_DEADLINE_SECS:-$((DEADLINE_MIN * 60))}
POLL=${MISSION_WATCHDOG_POLL_SECS:-30}

DIR=${MISSION_LIVENESS_DIR:-$HOME/.claude/progress/mission-liveness}
mkdir -p "$DIR" || { echo "mission-watchdog: cannot create $DIR" >&2; exit 2; }
STATUS="$DIR/$SID.watchdog.$LABEL"
rm -f "$STATUS.done"

# file_sig <file>: "<size> <mtime>" on BSD or GNU stat.
file_sig() { stat -f '%z %m' "$1" 2>/dev/null || stat -c '%s %Y' "$1" 2>/dev/null; }

# signature of every declared path; any difference between polls is progress.
signature() {
  for _p in "$@"; do
    if [ -d "$_p" ]; then
      find "$_p" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r _f; do
        printf '%s %s\n' "$_f" "$(file_sig "$_f")"
      done
    elif [ -e "$_p" ]; then
      printf '%s %s\n' "$_p" "$(file_sig "$_p")"
    else
      printf '%s missing\n' "$_p"
    fi
  done | cksum
}

START=$(date +%s)
LAST_CHANGE=$START
STATE=running; ACTION=none; IDLE=0; ELAPSED=0

write_status() {
  printf 'watchdog sid=%s label=%s class=%s state=%s action=%s idle_s=%s elapsed_s=%s deadline_min=%s idle_min=%s pid=%s at=%s\n' \
    "$SID" "$LABEL" "$CLASS" "$STATE" "$ACTION" "$IDLE" "$ELAPSED" "$DEADLINE_MIN" "$IDLE_MIN" "$$" "$(date +%s)" \
    > "$STATUS.tmp.$$" && mv -f "$STATUS.tmp.$$" "$STATUS"
}
finish() { STATE=$1; ACTION=$2; write_status; echo "mission-watchdog: $LABEL $STATE"; exit "$3"; }
trap 'finish stopped none 143' TERM INT

done_now() {
  [ -e "$STATUS.done" ] && return 0
  [ -n "$DONE_EXTRA" ] && [ -e "$DONE_EXTRA" ] && return 0
  return 1
}

SIG=$(signature "$@")
write_status
while :; do
  sleep "$POLL"
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  if done_now; then IDLE=$((NOW - LAST_CHANGE)); finish done none 0; fi
  NEW=$(signature "$@")
  if [ "$NEW" != "$SIG" ]; then SIG=$NEW; LAST_CHANGE=$NOW; fi
  IDLE=$((NOW - LAST_CHANGE))
  [ "$IDLE" -ge "$IDLE_SECS" ] && finish stall stop 3
  if [ "$ELAPSED" -ge "$DEADLINE_SECS" ]; then
    [ "$IS_TEST" = 1 ] || finish deadline stop 4
    STATE=overdue; ACTION=note
  fi
  write_status
done
