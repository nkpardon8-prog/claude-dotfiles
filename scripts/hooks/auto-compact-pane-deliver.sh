#!/usr/bin/env bash
# Pane delivery helper for auto-compact (2026-10-16). Spawned DETACHED by
# auto-compact-after-pre-compact.sh when the sentinel says delivery:"pane", so the Stop hook can
# return and Claude can go idle. Never invoked by the Terminal.app path.
#
# Usage: auto-compact-pane-deliver.sh <sid> <panel_id> <runpane_bin> <pane_dir> <sentinel_path> \
#                                     <lock_path> <transcript_path-or-empty>
#
# Sequence (every step logged to ~/.claude/logs/auto-compact.log):
#   1. wait until the panel is READY (STABLE consecutive polls; bounded by READY_TIMEOUT):
#        - Pane's agent state for the panel (`runpane workspace state` → agentState) is "idle".
#          NOT `panels screen` state.activityStatus: that is raw PTY recency, and Claude's
#          ticking status line keeps it "active" forever (live 2026-10-16: 180s of "busy").
#        - the composer is present and empty, read by OUR parser (pane_composer below), which
#          accepts a named top rule (`──── my-session ─`). Pane's own detector requires a rule of
#          bare `─`, so for any named Claude session it reports isPresent:false.
#   2. deliver /compact: `runpane panels submit`; when Pane answers blocked.kind
#      composer-unknown (same named-rule blind spot — it sent nothing), fall back to
#      `panels input --text` then a separate `panels input --keys enter` (Claude treats an Enter
#      that arrives with the text as a newline), then confirm the composer emptied.
#   3. wait until compaction has FINISHED:
#        finished = a new `compact_boundary` entry in the session transcript after dispatch
#                   (Claude Code writes it when a compaction completes), OR — when no usable
#                   transcript was given — the sentinel was retired by post-compact-primer.sh
#                   (it does that only on a confirmed source=compact start).
#      Bounded by COMPACT_TIMEOUT.
#   (between 2 and 3) queue /post-compact-resume <sid> right behind /compact, as the Terminal path
#      does; Claude runs it the moment compaction ends. Confirmed by a resume line AFTER the
#      compact_boundary in the transcript.
#
# The Stop hook has already done the retain/attempts bookkeeping before spawning this, so any
# failure here just leaves the sentinel for the next Stop to retry (bounded at 3 attempts).
#
# Tunables (seconds): AUTO_COMPACT_PANE_POLL_SEC (2), AUTO_COMPACT_PANE_READY_TIMEOUT_SEC (180),
# AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC (900), AUTO_COMPACT_PANE_STABLE_POLLS (2),
# AUTO_COMPACT_PANE_CALL_TIMEOUT_SEC (60, per runpane call), AUTO_COMPACT_PANE_KEY_GAP_SEC (0.8,
# text→Enter gap on the input fallback), AUTO_COMPACT_PANE_CONFIRM_SEC (30, resume confirmation).

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
KEY_GAP="${AUTO_COMPACT_PANE_KEY_GAP_SEC:-0.8}"
CONFIRM="${AUTO_COMPACT_PANE_CONFIRM_SEC:-30}"
for _v in "$READY_TIMEOUT" "$COMPACT_TIMEOUT" "$STABLE" "$CALL_TIMEOUT" "$CONFIRM"; do
  case "$_v" in ''|*[!0-9]*) ac_log "pane-helper abort sid=$SID reason=bad-tunable value=$_v"; exit 0 ;; esac
done
case "$POLL" in ''|*[!0-9.]*) POLL=2 ;; esac
case "$KEY_GAP" in ''|*[!0-9.]*) KEY_GAP=0.8 ;; esac

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

# Pane's agent state for this panel: idle | working | blocked | unknown | none (not listed).
agent_state() {
  rp workspace state | jq -r --arg p "$PANEL" '
    [.. | objects | select(.panelId? == $p and has("agentState")) | .agentState][0] // "none"' 2>/dev/null \
    || printf 'none'
}

# Composer from a `panels screen` JSON on stdin: empty | text | absent | error.
# Trusts Pane's composer when Pane found one; otherwise finds Claude's prompt box itself: the last
# `❯` row whose row above STARTS with a horizontal rule (a named session draws `──── name ─`).
# Held text = the rest of the `❯` row plus rows down to the closing rule. Python's strip() also
# drops the no-break space Claude prints after `❯`.
pane_composer() {
  python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("error"); sys.exit()
if d.get("ok") is not True:
    print("error"); sys.exit()
c = d.get("composer") or {}
if c.get("isPresent") is True:
    print("text" if c.get("hasUndeliveredText") is True else "empty"); sys.exit()
rows = [r.strip() for r in str(d.get("text") or "").split("\n")]
rule = "───"
for i in range(len(rows) - 1, 0, -1):
    if rows[i].startswith("❯") and rows[i - 1].startswith(rule):
        held = [rows[i][1:].strip()]
        for r in rows[i + 1:]:
            if r.startswith(rule):
                break
            held.append(r)
        print("text" if any(held) else "empty"); sys.exit()
print("absent")
' 2>/dev/null || printf 'error'
}

# Echoes "<agent>/<composer>" plus a final ready|busy verdict on its own line.
# ready = agentState idle AND composer empty. When Pane lists no agent state for the panel
# (older Pane), fall back to the screen's activityStatus.
panel_status() {
  local agent scr comp act
  agent=$(agent_state)
  scr=$(rp panels screen --panel "$PANEL" --limit 60)
  comp=$(printf '%s' "$scr" | pane_composer)
  if [ "$agent" = "none" ] || [ "$agent" = "unknown" ]; then
    act=$(printf '%s' "$scr" | jq -r '.state.activityStatus // "none"' 2>/dev/null)
    [ "$act" = "idle" ] && agent="idle(activity)"
  fi
  printf '%s/%s\n' "$agent" "$comp"
  case "$agent" in idle|"idle(activity)") [ "$comp" = "empty" ] && { printf 'ready'; return; } ;; esac
  printf 'busy'
}

# wait_ready <timeout_sec> <label> → rc 0 once STABLE consecutive polls read ready.
wait_ready() {
  local timeout="$1" label="$2" start now streak=0 out detail verdict last=""
  start=$(date +%s)
  while :; do
    out=$(panel_status)
    detail=$(printf '%s' "$out" | sed -n 1p)
    verdict=$(printf '%s' "$out" | sed -n 2p)
    if [ "$verdict" = "ready" ]; then streak=$((streak + 1)); else streak=0; fi
    [ "$detail" != "$last" ] && ac_log "pane-helper sid=$SID panel=$PANEL wait=$label screen=$verdict agent/composer=$detail"
    last="$detail"
    [ "$streak" -ge "$STABLE" ] && return 0
    now=$(date +%s)
    [ $((now - start)) -ge "$timeout" ] && return 1
    sleep "$POLL"
  done
}

# Composer right now (empty | text | absent | error).
composer_now() {
  rp panels screen --panel "$PANEL" --limit 60 | pane_composer
}

# submit <text> <label> → rc 0 iff the text was handed to Claude.
#   path 1: `panels submit` reports ok + verifiedSubmitted (taken or queued), or ok without
#           verification: never retyped; if our text still sits in the composer, Enter is pressed.
#   path 2: Pane answered composer-unknown (nothing typed) → type it with `panels input`, press
#           Enter as a separate write, and confirm the composer no longer holds text.
submit() {
  local text="$1" label="$2" out ok verified state blocked i comp
  out=$(rp panels submit --panel "$PANEL" --text "$text" --yes)
  ok=$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)
  verified=$(printf '%s' "$out" | jq -r '.verifiedSubmitted // false' 2>/dev/null)
  state=$(printf '%s' "$out" | jq -r '.delivery.state // "none"' 2>/dev/null)
  blocked=$(printf '%s' "$out" | jq -r '.blocked.kind // "none"' 2>/dev/null)
  if [ "$ok" = "true" ] && [ "$verified" = "true" ]; then
    ac_log "pane-submitted sid=$SID panel=$PANEL step=$label via=submit delivery=$state"
    return 0
  fi
  # ok without verification: Pane typed and submitted but could not prove it from the screen (seen
  # live on a named session). Do NOT retype (that would double-submit); the caller's transcript
  # check (compact_boundary / resume line) is the real proof either way.
  # Live (2nd run): the text landed but the Enter did not, leaving `/compact` in the composer. So
  # look: still holding text → press Enter ourselves; empty → it was taken.
  if [ "$ok" = "true" ] && [ "$blocked" = "none" ]; then
    sleep "$KEY_GAP"
    comp=$(composer_now)
    if [ "$comp" = "text" ]; then
      ac_log "pane-submit-unverified sid=$SID panel=$PANEL step=$label composer_after=text → pressing Enter"
      enter_until_taken "$label" submit-enter
      return
    fi
    ac_log "pane-submitted sid=$SID panel=$PANEL step=$label via=submit-unverified composer_after=$comp delivery=$state (transcript check decides)"
    return 0
  fi
  if [ "$blocked" != "composer-unknown" ]; then
    ac_log "pane-submit-failed sid=$SID panel=$PANEL step=$label ok=${ok:-none} verified=${verified:-none} delivery=${state:-none} blocked=${blocked:-none}"
    return 1
  fi

  # composer-unknown: Pane typed nothing. Our own parser already saw an empty composer (we only
  # get here after wait_ready), so typing into it is safe.
  ac_log "pane-submit-fallback sid=$SID panel=$PANEL step=$label reason=composer-unknown (named prompt rule) → panels input"
  out=$(rp panels input --panel "$PANEL" --text "$text" --yes)
  if [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
    ac_log "pane-submit-failed sid=$SID panel=$PANEL step=$label via=input-text"
    return 1
  fi
  sleep "$KEY_GAP"
  enter_until_taken "$label" input
}

# enter_until_taken <label> <via> → press Enter (its own write) until the composer no longer holds
# text, at most twice. Only called right after WE typed into a composer we saw empty.
enter_until_taken() {
  local label="$1" via="$2" out comp i
  for i in 1 2; do
    out=$(rp panels input --panel "$PANEL" --keys enter --yes)
    if [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
      ac_log "pane-submit-failed sid=$SID panel=$PANEL step=$label via=$via-enter"
      return 1
    fi
    sleep "$KEY_GAP"
    comp=$(composer_now)
    if [ "$comp" != "text" ]; then
      ac_log "pane-submitted sid=$SID panel=$PANEL step=$label via=$via composer_after=$comp enter_presses=$i"
      return 0
    fi
  done
  ac_log "pane-submit-failed sid=$SID panel=$PANEL step=$label via=$via reason=text-still-in-composer (left for the user; not retried)"
  return 1
}

# Transcript usable only if it is a regular .jsonl under ~/.claude/projects (path came from the
# Stop-hook payload; re-checked here because this is a separate process).
case "$TRANSCRIPT" in
  "$HOME"/.claude/projects/*.jsonl) [ -f "$TRANSCRIPT" ] && [ ! -L "$TRANSCRIPT" ] || TRANSCRIPT="" ;;
  *) TRANSCRIPT="" ;;
esac

transcript_size() {
  local s=0
  [ -n "$TRANSCRIPT" ] && s=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d '[:space:]')
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  printf '%s' "$s"
}

ac_log "pane-helper start sid=$SID panel=$PANEL transcript=${TRANSCRIPT:+yes}${TRANSCRIPT:-no}"

if ! wait_ready "$READY_TIMEOUT" pre-compact; then
  ac_log "pane-helper abort sid=$SID panel=$PANEL reason=composer-not-ready-pre-compact timeout=${READY_TIMEOUT}s (sentinel retained → next-Stop retry)"
  exit 0
fi

# Baselines taken BEFORE /compact goes in, so only a boundary written after dispatch counts.
T_OFFSET=$(transcript_size)
SENTINEL_AT_DISPATCH=0
[ -f "$SENTINEL" ] && SENTINEL_AT_DISPATCH=1

if ! submit "/compact" compact; then
  exit 0
fi

# Queue the resume right behind /compact, the way the Terminal path does (it types both lines
# 0.3s apart): Claude holds a line submitted mid-compaction and runs it the moment compaction
# ends. Live 2026-10-18: waiting for the panel to go idle AFTER compaction instead left the resume
# unsent for minutes — the post-compact panel kept reading busy. The composer was just seen empty
# by submit(), so this never appends to a draft of the user's.
sleep 1
RESUMED=0
if submit "/post-compact-resume $SID" resume; then
  RESUMED=1
  handoff_log "compact_chained sid=$SID delivery=pane panel=$PANEL result=fired+resume-queued"
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

# Resume ran = a post-compact-resume line AFTER the compact_boundary (a queued line can be
# recorded before compaction finishes; only one after the boundary proves it ran).
resume_ran() {
  tail -c +$((T_OFFSET + 1)) "$TRANSCRIPT" 2>/dev/null |
    awk '/"subtype":"compact_boundary"/{b=1; next} b && /post-compact-resume/{f=1} END{exit !f}'
}

START=$(date +%s)
SIGNAL="none"
while :; do
  if compaction_confirmed; then
    if [ -n "$TRANSCRIPT" ]; then SIGNAL="transcript-compact-boundary"; else SIGNAL="sentinel-retired"; fi
    break
  fi
  if [ $(( $(date +%s) - START )) -ge "$COMPACT_TIMEOUT" ]; then
    ac_log "pane-compact-unconfirmed sid=$SID panel=$PANEL timeout=${COMPACT_TIMEOUT}s resume_queued=$RESUMED (sentinel left for primer/next Stop)"
    exit 0
  fi
  sleep "$POLL"
done
ac_log "pane-compact-confirmed sid=$SID panel=$PANEL signal=$SIGNAL after=$(( $(date +%s) - START ))s"

[ "$RESUMED" = "1" ] || exit 0
# Effect, not delivery: the resume command must show up in the session transcript.
if [ -n "$TRANSCRIPT" ]; then
  _t=0
  while [ "$_t" -lt "$CONFIRM" ]; do
    if resume_ran; then
      ac_log "pane-resume-confirmed sid=$SID panel=$PANEL signal=transcript after=${_t}s"
      exit 0
    fi
    sleep 1; _t=$((_t + 1))
  done
  ac_log "pane-resume-unconfirmed sid=$SID panel=$PANEL (resume queued but not seen after compaction within ${CONFIRM}s; check the panel)"
fi
exit 0
