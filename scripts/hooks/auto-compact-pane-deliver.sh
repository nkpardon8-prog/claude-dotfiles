#!/usr/bin/env bash
# Pane delivery helper for auto-compact (2026-10-16; delivery rework 2026-11-16). Spawned DETACHED
# by auto-compact-after-pre-compact.sh when the sentinel says delivery:"pane", so the Stop hook can
# return and Claude can go idle. Never invoked by the Terminal.app path.
#
# Usage: auto-compact-pane-deliver.sh <sid> <panel_id> <runpane_bin> <pane_dir> <sentinel_path> \
#                                     <lock_path> <transcript_path-or-empty>
#
# Sequence (every step logged to ~/.claude/logs/auto-compact.log; verbs in LOG_VERBS.md):
#   1. wait for TRUE idle, STABLE consecutive polls in a row (bounded by READY_TIMEOUT):
#        - the session transcript says no turn is running or queued (transcript_state below) -
#          the screen alone misread a thinking turn as idle (live 2026-11-16), and a new turn can
#          start right after a Stop (queued notifications);
#        - Pane's agent state, else Claude's own screen (spinner row / "esc to interrupt"), is idle;
#        - the prompt box is empty, read by OUR parser first (Pane's composer flag misread it),
#          or shows the same unchanging text, which may be Claude's grey "suggested next prompt"
#          (the screen has no colour, so it looks like typing; the same goes for a fresh session's
#          `Try "…"` placeholder).
#   2. type `/compact` with `panels input`. If the box had text: a suggestion vanishes as soon as
#      we type (box reads exactly `/compact`); a real draft does not, so our 8 characters are
#      deleted again and we wait for the box to empty. Then ONE Enter as its own write.
#      `panels submit` is not used: it can leave the text in the box when it refuses.
#   3. prove Claude ACCEPTED it within ACCEPT_SEC: "Compacting conversation" on screen, or a
#      /compact / compact_boundary entry in the transcript. Enter is never pressed a second time
#      (on an empty or ghost-text box that can submit something else). Not accepted → delete
#      exactly the characters we typed, and retry from step 1, at most TRIES times in total.
#   4. accepted → queue `/post-compact-resume <sid>` right behind it (Claude runs a line queued
#      mid-compaction the moment compaction ends; the Terminal path does the same).
#   5. wait for a confirmed compaction (a new compact_boundary in the transcript, or - with no
#      usable transcript - the primer retiring the sentinel), then confirm the resume ran.
#      A compaction that stops without a boundary (cancelled or errored) is NOT retried.
#
# Any final failure retires the sentinel (no more typing on later Stops), writes a log line and
# shows a macOS notification. The only exit that leaves the sentinel for a later Stop is "never
# became idle" (nothing was typed), plus a compaction still running at COMPACT_TIMEOUT.
#
# Tunables (seconds unless noted): AUTO_COMPACT_PANE_POLL_SEC (2), AUTO_COMPACT_PANE_READY_TIMEOUT_SEC
# (1800), AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC (900), AUTO_COMPACT_PANE_STABLE_POLLS (2, count),
# AUTO_COMPACT_PANE_CALL_TIMEOUT_SEC (60, per runpane call), AUTO_COMPACT_PANE_KEY_GAP_SEC (0.8,
# text→Enter gap), AUTO_COMPACT_PANE_ACCEPT_SEC (10), AUTO_COMPACT_PANE_TRIES (2, count),
# AUTO_COMPACT_PANE_CONFIRM_SEC (30, resume confirmation), AUTO_COMPACT_PANE_RESUME_DELAY_SEC (5,
# /compact accepted → resume's Enter lands).

[ -z "${HOME:-}" ] && exit 0
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

SID="${1:-}"; PANEL="${2:-}"; RUNPANE="${3:-}"; PANE_DIR="${4:-}"
SENTINEL="${5:-}"; LOCK="${6:-}"; TRANSCRIPT="${7:-}"

POLL="${AUTO_COMPACT_PANE_POLL_SEC:-2}"
READY_TIMEOUT="${AUTO_COMPACT_PANE_READY_TIMEOUT_SEC:-1800}"
COMPACT_TIMEOUT="${AUTO_COMPACT_PANE_COMPACT_TIMEOUT_SEC:-900}"
STABLE="${AUTO_COMPACT_PANE_STABLE_POLLS:-2}"
CALL_TIMEOUT="${AUTO_COMPACT_PANE_CALL_TIMEOUT_SEC:-60}"
KEY_GAP="${AUTO_COMPACT_PANE_KEY_GAP_SEC:-0.8}"
ACCEPT="${AUTO_COMPACT_PANE_ACCEPT_SEC:-10}"
TRIES="${AUTO_COMPACT_PANE_TRIES:-2}"
RESUME_DELAY="${AUTO_COMPACT_PANE_RESUME_DELAY_SEC:-5}"
CONFIRM="${AUTO_COMPACT_PANE_CONFIRM_SEC:-30}"
for _v in "$READY_TIMEOUT" "$COMPACT_TIMEOUT" "$STABLE" "$CALL_TIMEOUT" "$CONFIRM" "$ACCEPT" "$TRIES"; do
  case "$_v" in ''|*[!0-9]*) ac_log "pane-helper abort sid=$SID reason=bad-tunable value=$_v"; exit 0 ;; esac
done
case "$POLL" in ''|*[!0-9.]*) POLL=2 ;; esac
case "$KEY_GAP" in ''|*[!0-9.]*) KEY_GAP=0.8 ;; esac
case "$RESUME_DELAY" in ''|*[!0-9.]*) RESUME_DELAY=5 ;; esac

# Release the in-flight lock on any exit, but only if it is still ours.
cleanup() {
  if [ -n "$LOCK" ] && [ "$(cat "$LOCK" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK" 2>/dev/null; fi
}
trap cleanup EXIT

if [ -z "$SID" ] || ! ac_validate_pane_panel_id "$PANEL" || [ ! -x "$RUNPANE" ] || [ ! -d "$PANE_DIR" ]; then
  ac_log "pane-helper abort sid=$SID reason=bad-args panel=$PANEL"
  exit 0
fi

# Transcript usable only if it is a regular .jsonl under ~/.claude/projects (path came from the
# Stop-hook payload; re-checked here because this is a separate process).
case "$TRANSCRIPT" in
  "$HOME"/.claude/projects/*.jsonl) [ -f "$TRANSCRIPT" ] && [ ! -L "$TRANSCRIPT" ] || TRANSCRIPT="" ;;
  *) TRANSCRIPT="" ;;
esac

rp() {
  perl -e 'alarm shift; exec @ARGV' "$CALL_TIMEOUT" "$RUNPANE" "$@" --pane-dir "$PANE_DIR" --json 2>/dev/null
}

# Pane's agent state for this panel: idle | working | blocked | unknown | none (not listed).
agent_state() {
  rp workspace state | jq -r --arg p "$PANEL" '
    [.. | objects | select(.panelId? == $p and has("agentState")) | .agentState][0] // "none"' 2>/dev/null \
    || printf 'none'
}

# Reads a `panels screen` JSON on stdin and prints three lines:
#   1. prompt box: empty | text | absent | error
#   2. Claude's own busy signal: idle | busy | compacting | unknown
#   3. the text held in the prompt box (one line, rows joined by a space)
# OUR parser first: Claude's prompt box = the last `❯` row whose row above STARTS with a rule (a
# named session draws `──── name ─`). Pane's composer flag is used only when no box is found -
# trusted first, it reported text in an empty box (live 2026-11-16). Grey placeholder and
# suggestion text read as text here; deliver_compact tells them from a draft. Busy = a spinner row (ellipsis + live timer) above the box or
# "esc to interrupt" anywhere (Claude 2.1.32x prints it in the footer); compacting = the
# "Compacting conversation" spinner.
screen_read() {
  python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("error\nunknown\n"); sys.exit()
if d.get("ok") is not True:
    print("error\nunknown\n"); sys.exit()
rows = [r.strip() for r in str(d.get("text") or "").split("\n")]
rule = "───"
box = None
for i in range(len(rows) - 1, 0, -1):
    if rows[i].startswith("❯") and rows[i - 1].startswith(rule):
        box = i; break
if any("Compacting conversation" in r for r in rows):
    state = "compacting"
elif box is None:
    state = "unknown"
else:
    above = rows[max(0, box - 10):box - 1]
    # A status row about BACKGROUND work ("Waiting for 3 background agents to finish") is not
    # the main turn: background agents, shells and wakeups keep running through a compaction.
    busy = any(re.search("…\\s*\\(\\d", r) and "background" not in r.lower() for r in above) \
        or any("esc to interrupt" in r for r in rows)
    state = "busy" if busy else "idle"
held = ""
if box is not None:
    parts = [rows[box][1:].strip()]
    for r in rows[box + 1:]:
        if r.startswith(rule):
            break
        parts.append(r)
    held = " ".join(p for p in parts if p)
    comp = "text" if held else "empty"
else:
    c = d.get("composer") or {}
    if c.get("isPresent") is True:
        comp = "text" if c.get("hasUndeliveredText") is True else "empty"
    else:
        comp = "absent"
print(comp); print(state); print(held.replace("\n", " "))
' 2>/dev/null || printf 'error\nunknown\n'
}

# Session transcript, read from the end (last 512KB): idle | busy | unknown.
#   busy = the latest turn-relevant entry is an assistant message, a user prompt / tool result,
#          or a queued line nobody has taken yet;
#   idle = it is a turn end (stop_hook_summary, turn_duration), a compact_boundary, or an
#          interrupt, with no line queued during that last turn still waiting to be taken. Local commands (2.1.319: user caveat/command lines; 2.1.32x: system
#          local_command) and bookkeeping entries are skipped. unknown = no transcript or no
#          decisive entry (then the screen decides alone).
transcript_state() {
  [ -n "$TRANSCRIPT" ] || { printf 'unknown'; return; }
  tail -c 524288 "$TRANSCRIPT" 2>/dev/null | python3 -I -c '
import json, sys
lines = sys.stdin.read().split("\n")
consumed = 0
def text_of(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(str(x.get("text") or x.get("type") or "") for x in c if isinstance(x, dict))
    return ""
ended = False   # passed the latest turn end: only look for a line queued during that turn
for l in reversed(lines):
    try:
        d = json.loads(l)
    except Exception:
        continue
    t = d.get("type")
    if ended and not (t == "queue-operation" or (t == "system" and d.get("subtype") in ("stop_hook_summary", "turn_duration", "compact_boundary"))):
        continue
    if t == "system":
        if d.get("subtype") in ("stop_hook_summary", "turn_duration", "compact_boundary"):
            if ended:
                break       # the turn before: nothing queued in the latest one is still pending
            ended = True
        continue
    if t == "queue-operation":
        if d.get("operation") == "enqueue":
            if consumed > 0:
                consumed -= 1; continue
            print("busy"); sys.exit()
        consumed += 1
        continue
    if ended:
        continue
    if t == "assistant":
        print("busy"); sys.exit()
    if t == "user":
        if d.get("isMeta"):
            continue
        s = text_of((d.get("message") or {}).get("content")).lstrip()
        if s.startswith("[Request interrupted"):
            print("idle"); sys.exit()
        if s.startswith(("<local-command", "<command-name>", "<command-message>")):
            continue
        print("busy"); sys.exit()
print("idle" if ended else "unknown")
' 2>/dev/null || printf 'unknown'
}

transcript_size() {
  local s=0
  [ -n "$TRANSCRIPT" ] && s=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d '[:space:]')
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  printf '%s' "$s"
}

# What the transcript shows about our /compact since byte offset T_OFFSET:
#   boundary = a compact_boundary (compaction finished)
#   started  = Claude 2.1.319 records the "/compact" prompt when it starts
#   ended    = after it: a local-command caveat or an assistant turn with no boundary
#              (compaction was cancelled or failed; 2.1.319 wrote a lone caveat, live 2026-11-16);
#              started-ended = both (accepted, then stopped - never retried)
#   none
compact_evidence() {
  [ -n "$TRANSCRIPT" ] || { printf 'none'; return; }
  tail -c +$((T_OFFSET + 1)) "$TRANSCRIPT" 2>/dev/null | python3 -I -c '
import json, sys
started = ended = False
for l in sys.stdin:
    try:
        d = json.loads(l)
    except Exception:
        continue
    t = d.get("type")
    if t == "system" and d.get("subtype") == "compact_boundary":
        print("boundary"); sys.exit()
    c = (d.get("message") or {}).get("content")
    s = c.strip() if isinstance(c, str) else ""
    if t == "user" and (s == "/compact" or s.startswith("<command-name>/compact<")):
        started = True; continue
    if t == "assistant" or (t == "user" and "<local-command-caveat>" in s):
        ended = True
print("started-ended" if started and ended else "ended" if ended else "started" if started else "none")
' 2>/dev/null || printf 'none'
}

SCR=""   # last screen_read output
read_screen() { SCR=$(rp panels screen --panel "$PANEL" --limit 60 | screen_read); }
scr_line() { printf '%s\n' "$SCR" | sed -n "${1}p"; }

# Prints "<agent>/<composer>/<transcript>", then ready | maybe-ghost | busy, then the held text.
# maybe-ghost = everything idle but the box shows text that is not a known draft. After a turn
# Claude Code draws a grey "suggested next prompt" in the EMPTY box; the screen text carries no
# colour, so it reads exactly like typing (live 2026-11-16, Claude 2.1.326). deliver_compact
# tells the two apart by typing (a suggestion vanishes on the first keystroke; a draft does not).
KNOWN_DRAFT=""
panel_status() {
  local agent comp sstate tstate held
  agent=$(agent_state)
  read_screen
  comp=$(scr_line 1); sstate=$(scr_line 2); held=$(scr_line 3)
  tstate=$(transcript_state)
  if [ "$agent" = "none" ] || [ "$agent" = "unknown" ]; then
    [ "$sstate" = "idle" ] && agent="idle(screen)"
  elif [ "$sstate" = "busy" ] || [ "$sstate" = "compacting" ]; then
    agent="$agent+screen-$sstate"
  fi
  printf '%s/%s/%s\n' "$agent" "$comp" "$tstate"
  case "$agent" in
    idle|"idle(screen)")
      if [ "$tstate" != "busy" ]; then
        [ "$comp" = "empty" ] && { printf 'ready\n\n'; return; }
        [ "$comp" = "text" ] && [ "$held" != "$KNOWN_DRAFT" ] && { printf 'maybe-ghost\n%s\n' "$held"; return; }
      fi ;;
  esac
  printf 'busy\n\n'
}

# wait_ready <timeout_sec> <label> → rc 0 once STABLE consecutive polls read ready (or the same
# maybe-ghost text: a draft being typed changes between polls, a suggestion does not). Sets
# READY_HELD to the text seen in the box ("" when empty).
READY_HELD=""
wait_ready() {
  local timeout="$1" label="$2" start now streak=0 out detail verdict held prev="" last=""
  start=$(date +%s)
  while :; do
    out=$(panel_status)
    detail=$(printf '%s\n' "$out" | sed -n 1p)
    verdict=$(printf '%s\n' "$out" | sed -n 2p)
    held=$(printf '%s\n' "$out" | sed -n 3p)
    case "$verdict" in
      ready|maybe-ghost) if [ "$streak" -gt 0 ] && [ "$held" != "$prev" ]; then streak=1; else streak=$((streak + 1)); fi ;;
      *) streak=0 ;;
    esac
    prev="$held"
    [ "$detail" != "$last" ] && ac_log "pane-helper sid=$SID panel=$PANEL wait=$label screen=$verdict agent/composer/transcript=$detail"
    last="$detail"
    if [ "$streak" -ge "$STABLE" ]; then READY_HELD="$held"; return 0; fi
    now=$(date +%s)
    [ $((now - start)) -ge "$timeout" ] && return 1
    sleep "$POLL"
  done
}

# Low-level writes; each returns rc 1 (and logs) when runpane refuses.
type_text() {
  [ "$(rp panels input --panel "$PANEL" --text "$1" --yes | jq -r '.ok // false' 2>/dev/null)" = "true" ] && return 0
  ac_log "pane-type-failed sid=$SID panel=$PANEL step=$2 via=input-text"; return 1
}
press_enter() {
  [ "$(rp panels input --panel "$PANEL" --keys enter --yes | jq -r '.ok // false' 2>/dev/null)" = "true" ] && return 0
  ac_log "pane-type-failed sid=$SID panel=$PANEL step=$1 via=input-enter"; return 1
}
backspaces() {  # backspaces <count>
  local n="$1" keys="backspace"
  while [ "$n" -gt 1 ]; do keys="$keys,backspace"; n=$((n - 1)); done
  rp panels input --panel "$PANEL" --keys "$keys" --yes >/dev/null
}

# type_line <text> <label> → the text, then ONE Enter as its own write.
type_line() {
  type_text "$1" "$2" || return 1
  sleep "$KEY_GAP"
  press_enter "$2"
}

# clear_ours <text> <label> → if the prompt box holds exactly our text, delete it with one
# backspace per character (+1 for a newline an Enter may have left). Never touches other text.
clear_ours() {
  local text="$1" label="$2"
  read_screen
  if [ "$(scr_line 1)" != "text" ]; then
    ac_log "pane-clear sid=$SID panel=$PANEL step=$label result=nothing-to-clear composer=$(scr_line 1)"
    return 0
  fi
  if [ "$(scr_line 3)" != "$text" ]; then
    KNOWN_DRAFT="$(scr_line 3)"
    ac_log "pane-clear sid=$SID panel=$PANEL step=$label result=left-alone (prompt box holds other text)"
    return 1
  fi
  backspaces $(( ${#text} + 1 ))
  sleep "$KEY_GAP"
  read_screen
  if [ "$(scr_line 1)" = "text" ]; then
    ac_log "pane-clear sid=$SID panel=$PANEL step=$label result=still-text"
    return 1
  fi
  ac_log "pane-clear sid=$SID panel=$PANEL step=$label result=cleared"
  return 0
}

# type_over <text> <label> <held-before> → 0 the box now holds exactly our text | 1 write failed
# | 2 the box held a real draft: our characters were removed and the draft is back as it was |
# 3 the draft could not be restored. With <held-before> empty there is nothing to check.
# A grey suggestion or placeholder vanishes on the first keystroke; a draft does not.
type_over() {
  local text="$1" label="$2" before="$3"
  type_text "$text" "$label" || return 1
  sleep "$KEY_GAP"
  [ -n "$before" ] || return 0
  read_screen
  if [ "$(scr_line 3)" = "$text" ]; then
    ac_log "pane-suggestion-replaced sid=$SID panel=$PANEL step=$label (the text in the box was Claude's grey suggestion)"
    return 0
  fi
  backspaces "${#text}"
  sleep "$KEY_GAP"
  read_screen
  [ "$(scr_line 3)" = "$before" ] || return 3
  ac_log "pane-draft-detected sid=$SID panel=$PANEL step=$label (the box held real text; our ${#text} characters removed)"
  return 2
}

# deliver_compact → 0 typed + Enter pressed | 1 write failed | 2 the box held a real draft
# (left as it was; nothing submitted).
deliver_compact() {
  local rc
  type_over "/compact" compact "$READY_HELD"; rc=$?
  case "$rc" in
    0) press_enter compact ;;
    2) KNOWN_DRAFT="$READY_HELD"; PROBES=$((PROBES + 1)); return 2 ;;
    3) give_up "draft-not-restored" ;;
    *) return 1 ;;
  esac
}

# Give up for good: no more typing on later Stops, a log line and a visible notification.
give_up() {
  local why="$1"
  rm -f "$SENTINEL" "${SENTINEL}.attempts" 2>/dev/null
  ac_log "pane-gave-up sid=$SID panel=$PANEL reason=$why (sentinel retired; no further /compact will be typed)"
  ac_notify "Auto-compact did not run for session ${SID:0:8} ($why). Run /compact then /post-compact-resume $SID yourself."
  exit 0
}

ac_log "pane-helper start sid=$SID panel=$PANEL transcript=${TRANSCRIPT:+yes}${TRANSCRIPT:-no}"

SENTINEL_AT_DISPATCH=0
[ -f "$SENTINEL" ] && SENTINEL_AT_DISPATCH=1
T_OFFSET=0
ACCEPTED=0
PROBES=0
try=0
while [ "$try" -lt "$TRIES" ]; do
  if ! wait_ready "$READY_TIMEOUT" pre-compact; then
    if [ "$try" = "0" ]; then
      ac_log "pane-helper abort sid=$SID panel=$PANEL reason=never-idle timeout=${READY_TIMEOUT}s (nothing typed; sentinel retained → next-Stop retry)"
      exit 0
    fi
    give_up "never-idle-after-failed-try"
  fi
  # Baseline taken BEFORE /compact goes in, so only evidence written after dispatch counts.
  T_OFFSET=$(transcript_size)
  deliver_compact; _rc=$?
  # A real draft: not a try, wait for the box to empty. Bounded: a draft edited and left again
  # may be probed at most 3 times.
  if [ "$_rc" = "2" ]; then
    [ "$PROBES" -ge 3 ] && give_up "draft-in-the-box"
    continue
  fi
  try=$((try + 1))
  if [ "$_rc" = "0" ]; then
    _start=$(date +%s); _how=""
    while [ $(( $(date +%s) - _start )) -le "$ACCEPT" ]; do
      _ev=$(compact_evidence)
      case "$_ev" in boundary|started|started-ended) _how="transcript-$_ev"; break ;; esac
      read_screen
      [ "$(scr_line 2)" = "compacting" ] && { _how="screen-compacting"; break; }
      # No transcript: the box emptying is the best evidence there is.
      if [ -z "$TRANSCRIPT" ] && [ "$(scr_line 1)" = "empty" ]; then _how="composer-empty"; break; fi
      sleep 0.5
    done
    if [ -n "$_how" ]; then
      ac_log "pane-compact-accepted sid=$SID panel=$PANEL try=$try signal=$_how"
      ACCEPTED=1
      break
    fi
    ac_log "pane-compact-not-accepted sid=$SID panel=$PANEL try=$try within=${ACCEPT}s composer=$(scr_line 1) screen=$(scr_line 2)"
  fi
  clear_ours "/compact" compact
done
[ "$ACCEPTED" = "1" ] || give_up "compact-not-accepted-after-$TRIES-tries"

# Queue the resume right behind the accepted /compact (the Terminal path types both lines 0.3s
# apart): Claude holds a line submitted mid-compaction and runs it the moment compaction ends.
# Waiting for idle AFTER compaction instead left it unsent for minutes (live 2026-10-18). A line
# queued mid-compaction stays visible in the box until it runs, so it is never Enter'd twice.
_wait=$(awk -v d="$RESUME_DELAY" -v g="$KEY_GAP" 'BEGIN{w=d-g; if (w<0) w=0; print w}')
sleep "$_wait"
RESUMED=0
RESUME="/post-compact-resume $SID"
read_screen
_before=""; [ "$(scr_line 1)" = "text" ] && _before=$(scr_line 3)
type_over "$RESUME" resume "$_before"; _rc=$?
if [ "$_rc" = "0" ] && press_enter resume; then
  RESUMED=1
  ac_log "pane-resume-queued sid=$SID panel=$PANEL"
  handoff_log "compact_chained sid=$SID delivery=pane panel=$PANEL result=fired+resume-queued"
elif [ "$_rc" = "2" ] || [ "$_rc" = "3" ]; then
  # Someone is typing: never append to their text. The primer still tells the resumed session
  # to run the resume itself.
  ac_log "pane-resume-skipped sid=$SID panel=$PANEL reason=box-not-empty"
  ac_notify "Session ${SID:0:8} is compacting, but the prompt box had text so /post-compact-resume was not typed. Run $RESUME in that window."
else
  clear_ours "$RESUME" resume
  ac_notify "Session ${SID:0:8} is compacting, but /post-compact-resume could not be typed. Run $RESUME in that window."
fi

compaction_confirmed() {
  if [ -n "$TRANSCRIPT" ]; then
    [ "$(compact_evidence)" = "boundary" ]
    return
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
  if [ -n "$TRANSCRIPT" ] && case "$(compact_evidence)" in ended|started-ended) true ;; *) false ;; esac; then
    give_up "compaction-stopped-before-finishing"
  fi
  if [ $(( $(date +%s) - START )) -ge "$COMPACT_TIMEOUT" ]; then
    ac_log "pane-compact-unconfirmed sid=$SID panel=$PANEL timeout=${COMPACT_TIMEOUT}s resume_queued=$RESUMED (sentinel left for primer/next Stop)"
    ac_notify "Auto-compact for session ${SID:0:8} has not finished after ${COMPACT_TIMEOUT}s. Check the window."
    exit 0
  fi
  sleep "$POLL"
done
ac_log "pane-compact-confirmed sid=$SID panel=$PANEL signal=$SIGNAL after=$(( $(date +%s) - START ))s"

# Effect, not delivery: the resume command must show up in the session transcript.
if [ "$RESUMED" = "1" ] && [ -n "$TRANSCRIPT" ]; then
  _t=0; _ok=0
  while [ "$_t" -lt "$CONFIRM" ]; do
    if resume_ran; then _ok=1; break; fi
    sleep 1; _t=$((_t + 1))
  done
  if [ "$_ok" = "1" ]; then
    ac_log "pane-resume-confirmed sid=$SID panel=$PANEL signal=transcript after=${_t}s"
  else
    ac_log "pane-resume-unconfirmed sid=$SID panel=$PANEL (resume queued but not seen after compaction within ${CONFIRM}s; check the panel)"
    ac_notify "Session ${SID:0:8} compacted, but /post-compact-resume was not seen running. Run /post-compact-resume $SID in that window."
  fi
fi
# The compaction is proven, so this arming is done. The primer retires the sentinel too, but only
# when a handoff file exists; without this, every later Stop would compact again (live
# 2026-11-17). Done after the resume check, so the primer (SessionStart) has long since read it.
if [ -f "$SENTINEL" ]; then
  rm -f "$SENTINEL" "${SENTINEL}.attempts" 2>/dev/null
  ac_log "pane-sentinel-retired sid=$SID panel=$PANEL (compaction confirmed)"
fi
exit 0
