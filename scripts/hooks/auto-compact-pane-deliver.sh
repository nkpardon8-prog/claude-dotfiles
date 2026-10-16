#!/usr/bin/env bash
# Pane delivery helper for auto-compact (2026-10-16). Spawned DETACHED by
# auto-compact-after-pre-compact.sh when the sentinel says delivery:"pane", so the Stop hook can
# return and Claude can go idle. Never invoked by the Terminal.app path.
#
# Usage: auto-compact-pane-deliver.sh <sid> <panel_id> <runpane_bin> <pane_dir> <sentinel_path> \
#                                     <lock_path> <transcript_path-or-empty>
#
# Sequence (every step logged to ~/.claude/logs/auto-compact.log):
#   1. wait until the panel's composer is present, empty and the panel is not active
#      (STABLE consecutive polls; bounded by READY_TIMEOUT)
#   2. `runpane panels submit` /compact — must come back verifiedSubmitted (taken or queued)
#   3. wait until compaction has FINISHED, then until the composer is idle again:
#        finished = a new `compact_boundary` entry in the session transcript after dispatch
#                   (Claude Code writes it when a compaction completes), OR — when no usable
#                   transcript was given — the sentinel was retired by post-compact-primer.sh
#                   (it does that only on a confirmed source=compact start).
#      Bounded by COMPACT_TIMEOUT. On timeout the resume is NOT sent (a resume typed into a
#      session that never compacted would be a plain prompt).
#   4. `runpane panels submit` /post-compact-resume <sid>
#
# The Stop hook has already done the retain/attempts bookkeeping before spawning this, so any
# failure here just leaves the sentinel for the next Stop to retry (bounded at 3 attempts).
#
# Tunables (seconds): AUTO_COMPACT_PANE_POLL_SEC (2), AUTO_COMPACT_PANE_READY_TIMEOUT_SEC (180),
# AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC (900), AUTO_COMPACT_PANE_STABLE_POLLS (2),
# AUTO_COMPACT_PANE_CALL_TIMEOUT_SEC (60, per runpane call).

[ -z "${HOME:-}" ] && exit 0
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

SID="${1:-}"; PANEL="${2:-}"; RUNPANE="${3:-}"; PANE_DIR="${4:-}"
SENTINEL="${5:-}"; LOCK="${6:-}"; TRANSCRIPT="${7:-}"

POLL="${AUTO_COMPACT_PANE_POLL_SEC:-2}"
READY_TIMEOUT="${AUTO_COMPACT_PANE_READY_TIMEOUT_SEC:-180}"
COMPACT_TIMEOUT="${AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC:-900}"
STABLE="${AUTO_COMPACT_PANE_STABLE_POLLS:-2}"
CALL_TIMEOUT="${AUTO_COMPACT_PANE_CALL_TIMEOUT_SEC:-60}"
for _v in "$READY_TIMEOUT" "$COMPACT_TIMEOUT" "$STABLE" "$CALL_TIMEOUT"; do
  case "$_v" in ''|*[!0-9]*) ac_log "pane-helper abort sid=$SID reason=bad-tunable value=$_v"; exit 0 ;; esac
done
case "$POLL" in ''|*[!0-9.]*) POLL=2 ;; esac

# Release the in-flight lock on any exit, but only if it is still ours.
cleanup() {
  if [ -n "$LOCK" ] && [ "$(cat "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK" 2>/dev/null; fi
}
trap cleanup EXIT

if [ -z "$SID" ] || ! ac_validate_pane_panel_id "$PANEL" || [ ! -x "$RUNPANE" ] || [ ! -d "$PANE_DIR" ]; then
  ac_log "pane-helper abort sid=$SID reason=bad-args panel=$PANEL"
  exit 0
fi

rp() {
  perl -e 'alarm shift; exec @ARGV' "$CALL_TIMEOUT" "$RUNPANE" "$@" --pane-dir "$PANE_DIR" --json 2>/dev/null
}

# Echoes ready | busy | error for the panel right now.
# ready = composer present AND no undelivered text AND activityStatus is not "active".
screen_state() {
  local out
  out=$(rp panels screen --panel "$PANEL" --limit 1) || { printf 'error'; return; }
  printf '%s' "$out" | jq -r '
    if .ok != true then "error"
    elif (.composer.isPresent == true)
         and (.composer.hasUndeliveredText != true)
         and ((.state.activityStatus // "idle") != "active")
    then "ready" else "busy" end' 2>/dev/null || printf 'error'
}

# wait_ready <timeout_sec> <label> → rc 0 once STABLE consecutive polls read "ready".
wait_ready() {
  local timeout="$1" label="$2" start now streak=0 st last=""
  start=$(date +%s)
  while :; do
    st=$(screen_state)
    if [ "$st" = "ready" ]; then streak=$((streak + 1)); else streak=0; fi
    [ "$st" != "$last" ] && ac_log "pane-helper sid=$SID panel=$PANEL wait=$label screen=$st"
    last="$st"
    [ "$streak" -ge "$STABLE" ] && return 0
    now=$(date +%s)
    [ $((now - start)) -ge "$timeout" ] && return 1
    sleep "$POLL"
  done
}

# submit <text> <label> → rc 0 iff runpane reports ok + verifiedSubmitted (taken or queued).
submit() {
  local text="$1" label="$2" out ok verified state blocked
  out=$(rp panels submit --panel "$PANEL" --text "$text" --yes)
  ok=$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)
  verified=$(printf '%s' "$out" | jq -r '.verifiedSubmitted // false' 2>/dev/null)
  state=$(printf '%s' "$out" | jq -r '.delivery.state // "none"' 2>/dev/null)
  blocked=$(printf '%s' "$out" | jq -r '.blocked.kind // "none"' 2>/dev/null)
  if [ "$ok" = "true" ] && [ "$verified" = "true" ]; then
    ac_log "pane-submitted sid=$SID panel=$PANEL step=$label delivery=$state"
    return 0
  fi
  ac_log "pane-submit-failed sid=$SID panel=$PANEL step=$label ok=${ok:-none} verified=${verified:-none} delivery=${state:-none} blocked=${blocked:-none}"
  return 1
}

# Transcript usable only if it is a regular .jsonl under ~/.claude/projects (path came from the
# Stop-hook payload; re-checked here because this is a separate process).
case "$TRANSCRIPT" in
  "$HOME"/.claude/projects/*.jsonl) [ -f "$TRANSCRIPT" ] && [ ! -L "$TRANSCRIPT" ] || TRANSCRIPT="" ;;
  *) TRANSCRIPT="" ;;
esac

ac_log "pane-helper start sid=$SID panel=$PANEL transcript=${TRANSCRIPT:+yes}${TRANSCRIPT:-no}"

if ! wait_ready "$READY_TIMEOUT" pre-compact; then
  ac_log "pane-helper abort sid=$SID panel=$PANEL reason=composer-not-ready-pre-compact timeout=${READY_TIMEOUT}s (sentinel retained → next-Stop retry)"
  exit 0
fi

# Baselines taken BEFORE /compact goes in, so only a boundary written after dispatch counts.
T_OFFSET=0
if [ -n "$TRANSCRIPT" ]; then
  T_OFFSET=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d '[:space:]')
  case "$T_OFFSET" in ''|*[!0-9]*) T_OFFSET=0 ;; esac
fi
SENTINEL_AT_DISPATCH=0
[ -f "$SENTINEL" ] && SENTINEL_AT_DISPATCH=1

if ! submit "/compact" compact; then
  exit 0
fi

compaction_confirmed() {
  if [ -n "$TRANSCRIPT" ]; then
    tail -c +$((T_OFFSET + 1)) "$TRANSCRIPT" 2>/dev/null | grep -q '"subtype":"compact_boundary"' && return 0
    return 1
  fi
  # Fallback: primer retired the sentinel. A claim file means a Stop hook holds it right now,
  # which is not a retirement.
  if [ "$SENTINEL_AT_DISPATCH" = "1" ] && [ ! -f "$SENTINEL" ]; then
    ls "${SENTINEL}.claim."* >/dev/null 2>&1 && return 1
    return 0
  fi
  return 1
}

START=$(date +%s)
SIGNAL="none"
while :; do
  if compaction_confirmed; then
    if [ -n "$TRANSCRIPT" ]; then SIGNAL="transcript-compact-boundary"; else SIGNAL="sentinel-retired"; fi
    break
  fi
  if [ $(( $(date +%s) - START )) -ge "$COMPACT_TIMEOUT" ]; then
    ac_log "pane-compact-unconfirmed sid=$SID panel=$PANEL timeout=${COMPACT_TIMEOUT}s (resume NOT sent; sentinel left for primer/next Stop)"
    exit 0
  fi
  sleep "$POLL"
done
ac_log "pane-compact-confirmed sid=$SID panel=$PANEL signal=$SIGNAL after=$(( $(date +%s) - START ))s"

REMAIN=$(( COMPACT_TIMEOUT - ( $(date +%s) - START ) ))
[ "$REMAIN" -lt "$READY_TIMEOUT" ] && REMAIN="$READY_TIMEOUT"
if ! wait_ready "$REMAIN" post-compact; then
  ac_log "pane-helper abort sid=$SID panel=$PANEL reason=composer-not-ready-post-compact (compacted; run /post-compact-resume $SID manually)"
  exit 0
fi

if submit "/post-compact-resume $SID" resume; then
  handoff_log "compact_chained sid=$SID delivery=pane panel=$PANEL result=fired+resume-after-confirmed-compaction"
fi
exit 0
