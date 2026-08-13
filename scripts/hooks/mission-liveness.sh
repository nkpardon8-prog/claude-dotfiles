#!/usr/bin/env bash
# Stop hook - catches a /mission run that ended a turn WITHOUT booking its next wake.
#
# WHY THIS EXISTS
#   mission.md's CONTINUATION-OWNER INVARIANT ("a mission turn NEVER yields naked") was enforced by
#   nothing. ScheduleWakeup is called only because the model remembers to call it, and the sole Stop
#   hook registered before this one (auto-compact-after-pre-compact.sh) exits without ever reading
#   mission state. A dropped step 7 froze the mission INDEFINITELY - no timer, no expiring lock, no
#   watcher - until a human typed something. Observed repeatedly: four stops in one session, every one
#   immediately after a git commit returned success.
#
# WHAT IT DOES
#   On a normal turn end, for an ARMED mission session only: read the session transcript, check whether
#   the just-ended assistant turn actually called ScheduleWakeup, and if it did not - and the mission is
#   not at a sanctioned stop - exit 2 to block the stop and tell the model to re-enter the wake routine.
#
# MECHANISM NOTES (verified against the 2.1.229 hooks reference, 2026-08-13)
#   - Stop blocks on EXIT CODE 2. That is the documented mechanism; `{"decision":"block"}` is a
#     PreToolUse/PreCompact shape and does NOT apply here.
#   - Exit 2 is absolute: multiple Stop handlers run in PARALLEL and the most restrictive wins.
#   - There is NO `session_crons` field and no way to query pending ScheduleWakeup entries from a hook.
#     The transcript is therefore the evidence: we observe whether the CALL was made. That is still an
#     effect, not a self-report - the distinction that makes this a guard rather than a wish.
#   - `stop_hook_active` is NOT documented for this version, so the loop bound is keyed on `prompt_id`.
#   - Stop does NOT fire on API errors / rate limits (those emit StopFailure, whose exit 2 is ignored),
#     so this cannot catch an allowance-exhaustion death. Known and accepted; see the plan's scorecard.
#
# SAFETY POSTURE - fail SILENT everywhere it is not certain:
#   unarmed session, auto-compact in flight, repeat on the same prompt_id, unreadable/lagging
#   transcript, unreadable mission state, any sanctioned stop => exit 0 and say nothing. The ONLY
#   loud paths are the block itself and the stall alert. A false block interrupts a human; a missed
#   block costs one wake. We bias to the latter.

set -uo pipefail   # no -e: partial failures must fall through to a silent exit, never abort loudly

# KILL SWITCH. Every other guard in this directory has one (CLAUDE_CTX_GATE_DISABLED,
# SHARED_PATH_GUARD_DISABLED) and those only SPEAK. This one refuses to let a turn end, so it needs
# an escape hatch more than they do: if it misfires at 3am the alternative recovery is hand-editing
# settings.json or deleting a sentinel whose path the user would have to already know.
[ "${MISSION_LIVENESS_DISABLED:-0}" = "1" ] && exit 0

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$HOOKS_DIR/lib/auto-compact-sentinel.sh" 2>/dev/null || exit 0

# MISSION_LIVENESS_LOG lets the harness redirect this away from the user's real diagnostic channel;
# without it the test suite pollutes the one log the design leans on to tell "ran and stayed silent"
# apart from "never ran".
ML_LOG="${MISSION_LIVENESS_LOG:-$HOME/.claude/logs/mission-liveness.log}"
# Mirrors ac_log (lib/auto-compact-sentinel.sh): 0600, and a size ring. This log records absolute
# repo paths on every armed turn end, so world-readable is the wrong default, and unbounded growth on
# a hook that fires all night is a real leak.
ml_log() {
  local d; d=$(dirname "$ML_LOG")
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  ( umask 077
    if [ -f "$ML_LOG" ]; then
      local sz; sz=$(stat -f %z "$ML_LOG" 2>/dev/null || stat -c %s "$ML_LOG" 2>/dev/null || echo 0)
      if [ "${sz:-0}" -gt 65536 ]; then
        tail -c 32768 "$ML_LOG" > "$ML_LOG.tmp" 2>/dev/null && mv -f "$ML_LOG.tmp" "$ML_LOG" 2>/dev/null
      fi
    fi
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$ML_LOG" 2>/dev/null )
}

# ── stdin ────────────────────────────────────────────────────────────────────────────────────────
INPUT=$(head -c 1048576)   # bound stdin (DoS guard), matching ctx-gate-on-prompt-submit.sh:36
[ -n "$INPUT" ] || exit 0

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
PROMPT_ID=$(printf '%s' "$INPUT" | jq -r '.prompt_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$SID" ] || exit 0

# ── 1. ARMED? ────────────────────────────────────────────────────────────────────────────────────
# The arming sentinel is the ONLY thing that turns this hook on, and it carries the mission root.
# This is deliberate and load-bearing: without it the hook would fire on every turn end of every
# session on this machine, and - because several windows routinely sit in the same repo - it would
# inject a mission tick into a SIBLING window, or into the user's own live conversation during an
# interactive mission. Deriving the root from `cwd` instead would reintroduce exactly that bug.
ARM="$HOME/.claude/progress/mission-liveness-$SID.json"
[ -f "$ARM" ] || exit 0

ROOT=$(jq -r '.root // empty' "$ARM" 2>/dev/null)
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { ml_log "sid=$SID arm-unreadable-or-root-gone action=silent"; exit 0; }
case "$ROOT" in *..*) ml_log "sid=$SID root-traversal action=silent"; exit 0 ;; esac

# ── 2. NOT CONTENDING with the auto-compact chain? ───────────────────────────────────────────────
# auto-compact-after-pre-compact.sh:258-267 records a field incident where merely adding an argument
# to the typed /compact shifted timing enough to strand the queued /post-compact-resume for 27
# minutes. Blocking a stop while that chain is mid-flight is a strictly larger perturbation, and the
# compaction chain is load-bearing for overnight autonomy. Yield to it, always.
AC_SENT=$(ac_sentinel_path "$SID" 2>/dev/null)
if [ -n "$AC_SENT" ]; then
  [ -f "$AC_SENT" ] && { ml_log "sid=$SID autocompact-armed action=silent"; exit 0; }
  # shellcheck disable=SC2144  # glob-in-test is intended: any claim file for this sid counts
  for c in "$AC_SENT".claim.*; do
    [ -e "$c" ] && { ml_log "sid=$SID autocompact-claim action=silent"; exit 0; }
  done
fi

# ── 3. NOT REPEATING? (the loop bound) ───────────────────────────────────────────────────────────
# `stop_hook_active` is undocumented in 2.1.229, so `prompt_id` is the loop bound: block a given
# prompt AT MOST ONCE. If the model ends the turn again without scheduling, let it go rather than
# trapping the session.
#
# `prompt_id` REQUIRES 2.1.196+ and is therefore an assumption of exactly the same class as the
# undocumented `stop_hook_active` — load-bearing and outside our control. When it is ABSENT the
# per-prompt marker can never be written, the check can never trip, and the hook blocks EVERY time:
# an unbounded loop, reproduced three-for-three in review. So the absent case gets its own bound
# rather than silently losing one: a sid-keyed marker with a time window. Worst case is one block
# per window instead of one per prompt; it is never unbounded.
STATE_DIR="$HOME/.claude/progress/mission-liveness"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
ML_WINDOW_SEC="${MISSION_LIVENESS_WINDOW_SEC:-900}"
if [ -n "$PROMPT_ID" ]; then
  ATTEMPT="$STATE_DIR/$SID.$PROMPT_ID.blocked"
  if [ -f "$ATTEMPT" ]; then
    ml_log "sid=$SID prompt=$PROMPT_ID already-blocked action=silent"
    exit 0
  fi
else
  ATTEMPT="$STATE_DIR/$SID.noprompt.blocked"
  if [ -f "$ATTEMPT" ]; then
    _ml_mt=$(stat -f %m "$ATTEMPT" 2>/dev/null || stat -c %Y "$ATTEMPT" 2>/dev/null)
    _ml_now=$(date -u +%s)
    if [ -n "$_ml_mt" ] && [ $((_ml_now - _ml_mt)) -lt "$ML_WINDOW_SEC" ]; then
      ml_log "sid=$SID no-prompt-id within-window action=silent"
      exit 0
    fi
  fi
fi

# ── 4. RESOLVE the mission by SID (never by walking cwd) ─────────────────────────────────────────
# shellcheck source=lib/mission-bridge.sh
. "$HOOKS_DIR/lib/mission-bridge.sh" 2>/dev/null || exit 0
MPATH=$(mission_resolve_path "$SID" "$ROOT" 2>/dev/null)
[ -n "$MPATH" ] && [ -f "$MPATH" ] || { ml_log "sid=$SID no-mission action=silent"; exit 0; }

# ── 5. WAS A WAKE BOOKED? (observe the act in the transcript) ────────────────────────────────────
# The docs warn transcript_path MAY LAG. If we cannot positively establish that the just-ended turn
# is present and complete, we exit silent - never block on absent evidence. Measured lag on this
# machine is ~7s, but a slow flush must degrade to a missed catch, not to a spurious block.
[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || { ml_log "sid=$SID transcript-unreadable action=silent"; exit 0; }

# ── 5a. STALL SAMPLE — taken HERE, before any early return, and this placement is the whole point.
# A mission that dutifully books a wake every tick while the tree never moves is invisible to every
# other check in this file: it exits "yes" at step 5 below and never reaches the tail. That is the
# 11-hour shape that produced one part out of eight. Sampling only on a BLOCK (the original design)
# compared two cursors hours and many turns apart and would essentially never fire - coverage in
# appearance only. Sampling on every armed turn end is what makes it a real detector.
# Advisory: it only ever writes the log, never blocks.
ML_CUR=$(mission_cursor_hash "$SID" "$ROOT" 2>/dev/null | head -c 128)
if [ -n "$ML_CUR" ]; then
  ML_CURFILE="$STATE_DIR/$SID.cursor"
  ML_PREV=$(cat "$ML_CURFILE" 2>/dev/null)
  if [ "$ML_CUR" = "$ML_PREV" ]; then
    ML_N=$(cat "$STATE_DIR/$SID.stall" 2>/dev/null); ML_N=$((${ML_N:-0} + 1))
    printf '%s' "$ML_N" > "$STATE_DIR/$SID.stall" 2>/dev/null
    [ "$ML_N" -ge "${MISSION_LIVENESS_STALL_TICKS:-12}" ] && ml_log "sid=$SID STALL ticks=$ML_N cursor=$ML_CUR"
  else
    printf '0' > "$STATE_DIR/$SID.stall" 2>/dev/null
  fi
  printf '%s' "$ML_CUR" > "$ML_CURFILE" 2>/dev/null
fi

# The turn-boundary logic lives in lib/mission-liveness-parse.py so it can be unit-tested directly;
# getting it wrong is the difference between a guard and a saboteur. The first version scanned back
# only over a contiguous run of assistant records - but tool RESULTS are `user` records, so the real
# healthy sequence (ScheduleWakeup -> tool_result -> lock-release -> tool_result -> text) broke the
# scan before it reached the call. Replayed against a real transcript it printed "no" for a perfectly
# behaved turn, i.e. it would have blocked precisely the runs doing the right thing, and the injected
# "re-enter step 7" would have produced a SECOND ScheduleWakeup - the double-drive §12.4 exists to
# prevent. Three independent reviewers reproduced it.
SCHEDULED=$(tail -c 2000000 "$TRANSCRIPT" 2>/dev/null | python3 "$HOOKS_DIR/lib/mission-liveness-parse.py" "$SID" 2>/dev/null)

case "${SCHEDULED:-unknown}" in
  yes)     ml_log "sid=$SID wake-booked action=silent"; exit 0 ;;
  human)   ml_log "sid=$SID human-initiated-turn action=silent"; exit 0 ;;
  unknown) ml_log "sid=$SID transcript-inconclusive action=silent"; exit 0 ;;
esac

# ── 6. IS THIS A SANCTIONED STOP? ────────────────────────────────────────────────────────────────
# Exact machine predicates only, and ANY ambiguity exits silent. Never infer a stop, and never infer
# its absence: a mission legitimately at a human park or a corrupt bridge must not be nagged.
# mission_lifecycle_state returns exactly: unknown | unreadable | active | cleared (lib/mission-bridge.sh:504-536).
#   cleared    => MISSION-CLEARED banked (achieved / could-not / cleared) - a sanctioned stop.
#   unreadable => a genuine read error. Fail SILENT: never nag on evidence we could not read.
#   unknown    => NO lifecycle line yet. This is the NORMAL state of a healthy active mission and
#                 MUST NOT be treated as a stop. Treating it as one made the guard permanently inert
#                 on every real mission - caught by test 1 going red, which is why that test exists.
#   active     => explicitly rebaselined and running.
LIFE=$(mission_lifecycle_state "$SID" "$ROOT" 2>/dev/null)
case "$LIFE" in
  cleared|unreadable|"") ml_log "sid=$SID lifecycle=${LIFE:-empty} action=silent"; exit 0 ;;
esac

# Use the SOURCED function, not `bash mission-write.sh await-state`. Two access paths into one
# subsystem in one file is a Single-Way violation, and shelling out would re-source a 3104-line lib
# in a fresh process on every armed turn end - inside a 10s Stop timeout.
AWAIT=$(mission_await_state "$SID" "$ROOT" 2>/dev/null)
case "$AWAIT" in
  corrupt|"") ml_log "sid=$SID await=${AWAIT:-empty} action=silent"; exit 0 ;;
  await*kind=human*) ml_log "sid=$SID human-park action=silent"; exit 0 ;;
esac

# STOP-LOUD is the THIRD class of sanctioned stop, and missing it is actively harmful rather than
# merely incomplete. The 5-FAIL tally, panel-unavailable-3x and void-count=-1 bank NO lifecycle line
# and open NO human barrier, so both predicates above read healthy-active. mission.md:1477-1478 is
# explicit: "A STOP-LOUD must NEVER schedule the next self-wake (that would loop a wedged mission
# forever)" - so blocking here would force exactly the loop the playbook forbids. Cheap, live-log
# tail (deliberately not the archive-inclusive stream: a STOP-LOUD is recent by construction, and
# this runs inside a 10s Stop timeout).
ML_LIVE_LOG="${MPATH%.md}.log"
if [ -r "$ML_LIVE_LOG" ]; then
  ML_LAST=$(grep -a '\[mission\] ' "$ML_LIVE_LOG" 2>/dev/null | tail -1)
  case "$ML_LAST" in
    *"[mission] FAIL"*) ml_log "sid=$SID stop-loud-fail action=silent"; exit 0 ;;
  esac
fi

# ── 7. NAKED YIELD ───────────────────────────────────────────────────────────────────────────────
# ALWAYS write the attempt marker. Guarding this write on a non-empty prompt_id was the unbounded
# block loop: no prompt_id meant no marker, so the step-3 check could never trip. Step 3 chooses
# WHICH marker path applies; here we unconditionally record that we blocked.
#
# And the marker write MUST succeed before we block. If the state dir is unwritable (permissions,
# full disk, read-only home) the marker never lands, the step-3 check can never trip, and we would
# block forever - the same unbounded loop by a different route. No marker, no block.
: >"$ATTEMPT" 2>/dev/null
if [ ! -f "$ATTEMPT" ]; then
  ml_log "sid=$SID marker-unwritable action=silent (refusing to block without a loop bound)"
  exit 0
fi

# Opportunistic GC, best-effort and silent. One marker per blocked prompt plus a cursor and a stall
# counter per session would otherwise accumulate forever; nothing else prunes this directory.
find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true

ml_log "sid=$SID prompt=${PROMPT_ID:-none} NAKED-YIELD action=block life=$LIFE"

cat >&2 <<EOF
mission-liveness: NAKED YIELD BLOCKED. This turn ended with mission work owed and no ScheduleWakeup
call in it, which would have frozen the mission indefinitely (nothing retries a dropped step 7).
Do NOT reply with prose. Re-enter the /mission wake routine (playbook section 12.1) for
sid=$SID root=$ROOT and exit through step 7, which is the mandatory exit gate. Reminder: finishing a
unit of work, a git commit returning success, writing up what landed, and replying to a peer window
are NOT stop conditions - the closed list is in section 12.3.
EOF
exit 2
