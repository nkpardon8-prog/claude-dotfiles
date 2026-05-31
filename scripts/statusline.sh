#!/usr/bin/env bash
# ~/.claude/statusline.sh
# Claude Code statusLine command — receives JSON blob on stdin.
# Rate-limit fields (time-left, sess%, wk%) come from ~/.claude/ratelimit.json,
# populated by ~/.claude/refresh-ratelimit.sh (OAuth token from macOS keychain).
# Fields still used from stdin: model.display_name, workspace.current_dir,
#   transcript_path, context_window.*, effort.level.

# Do NOT use -e: partial failures must not abort the whole status line
set -uo pipefail

# ── ANSI colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Read stdin once ───────────────────────────────────────────────────────────
INPUT=$(cat)

jq_get() { echo "$INPUT" | jq -r "${1} // empty" 2>/dev/null || true; }

# ── 1. Context window usage ───────────────────────────────────────────────────
TRANSCRIPT=$(jq_get '.transcript_path')
CTX_USED_PCT=$(jq_get '.context_window.used_percentage')
CTX_SIZE=$(jq_get '.context_window.context_window_size')
MODEL_ID=$(jq_get '.model.id')

# Derive context window size from model if not provided
if [ -z "$CTX_SIZE" ] || [ "$CTX_SIZE" = "0" ]; then
  case "$MODEL_ID" in
    *opus-4-7*|*opus-4.7*|*opus4-7*) CTX_SIZE=1000000 ;;
    *) CTX_SIZE=200000 ;;
  esac
fi

# Try pre-calculated percentage first, then fall back to transcript counting
if [ -n "$CTX_USED_PCT" ] && [ "$CTX_USED_PCT" != "null" ]; then
  CTX_PCT=$(printf '%.0f' "$CTX_USED_PCT" 2>/dev/null || echo "")
else
  CTX_PCT=""
  # Count tokens from transcript JSONL
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Sum input+cache tokens from the most recent assistant message
    TOKENS=$(tail -200 "$TRANSCRIPT" 2>/dev/null \
      | jq -s '
          [ .[]
            | select(.type == "assistant" or (.message.role == "assistant"))
          ] | last
          | (
              (.message.usage.input_tokens // 0)
            + (.message.usage.cache_read_input_tokens // 0)
            + (.message.usage.cache_creation_input_tokens // 0)
            + (.usage.input_tokens // 0)
            + (.usage.cache_read_input_tokens // 0)
            + (.usage.cache_creation_input_tokens // 0)
            )
        ' 2>/dev/null || echo "0")
    if [ -n "$TOKENS" ] && [ "$TOKENS" != "0" ] && [ "$TOKENS" != "null" ]; then
      CTX_PCT=$(awk "BEGIN { printf \"%.0f\", ($TOKENS / $CTX_SIZE) * 100 }" 2>/dev/null || echo "")
    fi
  fi
fi

# Format context field with color
if [ -n "$CTX_PCT" ]; then
  if [ "$CTX_PCT" -gt 80 ] 2>/dev/null; then
    CTX_FIELD="${RED}${BOLD}ctx ${CTX_PCT}%${RESET}"
  elif [ "$CTX_PCT" -gt 60 ] 2>/dev/null; then
    CTX_FIELD="${YELLOW}ctx ${CTX_PCT}%${RESET}"
  else
    CTX_FIELD="${GREEN}ctx ${CTX_PCT}%${RESET}"
  fi
else
  CTX_FIELD="${DIM}ctx —${RESET}"
fi

# ── 2–4. Rate-limit data from ~/.claude/ratelimit.json ───────────────────────
# The cache is populated by ~/.claude/refresh-ratelimit.sh (runs in background).
# If cache is missing or older than 5 minutes, kick off a background refresh
# (nohup + disown so it survives shell exit and doesn't block rendering).
# Stale-but-not-ancient data (up to 1 h) is still displayed; beyond 1 h shows —.

NOW_EPOCH=$(date "+%s")
RL_CACHE="$HOME/.claude/ratelimit.json"
RL_REFRESH="$HOME/.claude/refresh-ratelimit.sh"
REFRESH_INTERVAL=300   # 5 minutes
STALE_CUTOFF=3600      # 1 hour — beyond this show — instead of old data

RL_FETCHED_AT=0
RL_FIVE_H_RESET=""
RL_FIVE_H_UTIL=""
RL_FIVE_H_STATUS=""
RL_SEVEN_D_RESET=""
RL_SEVEN_D_UTIL=""
RL_SEVEN_D_STATUS=""

if [ -f "$RL_CACHE" ]; then
  RL_FETCHED_AT=$(python3 -c "import json,sys; d=json.load(open('$RL_CACHE')); print(d.get('fetched_at',0))" 2>/dev/null || echo "0")
  CACHE_AGE=$(( NOW_EPOCH - RL_FETCHED_AT ))

  # Background refresh if stale
  if [ "$CACHE_AGE" -gt "$REFRESH_INTERVAL" ] && [ -x "$RL_REFRESH" ]; then
    nohup "$RL_REFRESH" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi

  # Use cache data unless it's too old
  if [ "$CACHE_AGE" -le "$STALE_CUTOFF" ]; then
    _rl_parse() {
      python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    q = lambda v: '' if v is None else str(v)
    print('RL_FIVE_H_RESET=' + q(d.get('five_h_reset')))
    print('RL_FIVE_H_UTIL=' + q(d.get('five_h_util')))
    print('RL_FIVE_H_STATUS=' + q(d.get('five_h_status')))
    print('RL_SEVEN_D_RESET=' + q(d.get('seven_d_reset')))
    print('RL_SEVEN_D_UTIL=' + q(d.get('seven_d_util')))
    print('RL_SEVEN_D_STATUS=' + q(d.get('seven_d_status')))
except Exception:
    pass
" "$RL_CACHE" 2>/dev/null
    }
    eval "$(_rl_parse)" 2>/dev/null || true
  fi
else
  # No cache at all — kick off refresh and carry on with empty fields
  if [ -x "$RL_REFRESH" ]; then
    nohup "$RL_REFRESH" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

# ── 2. Time left in 5-hour window ────────────────────────────────────────────
SESSION_TIME_LEFT="—"

if [ -n "$RL_FIVE_H_RESET" ] && [ "$RL_FIVE_H_RESET" != "0" ]; then
  SECS_LEFT=$(( RL_FIVE_H_RESET - NOW_EPOCH ))
  if [ "$SECS_LEFT" -gt 0 ]; then
    HRS=$(( SECS_LEFT / 3600 ))
    MINS=$(( (SECS_LEFT % 3600) / 60 ))
    SESSION_TIME_LEFT="${HRS}h ${MINS}m left"
  else
    SESSION_TIME_LEFT="—"
  fi
fi

# Color: red if < 30 min, green if rate_limited (still show countdown), cyan otherwise
if [ "$RL_FIVE_H_STATUS" = "rate_limited" ]; then
  SESSION_FIELD="${GREEN}${SESSION_TIME_LEFT}${RESET}"
elif [ -n "$RL_FIVE_H_RESET" ] && [ "$RL_FIVE_H_RESET" != "0" ]; then
  SECS_REMAIN=$(( RL_FIVE_H_RESET - NOW_EPOCH ))
  if [ "$SECS_REMAIN" -lt 1800 ] && [ "$SECS_REMAIN" -gt 0 ]; then
    SESSION_FIELD="${RED}${SESSION_TIME_LEFT}${RESET}"
  else
    SESSION_FIELD="${CYAN}${SESSION_TIME_LEFT}${RESET}"
  fi
else
  SESSION_FIELD="${DIM}${SESSION_TIME_LEFT}${RESET}"
fi

# Debug output when CLAUDE_STATUSLINE_DEBUG=1
if [ "${CLAUDE_STATUSLINE_DEBUG:-0}" = "1" ]; then
  echo "[DEBUG] rl_cache_age : $(( NOW_EPOCH - RL_FETCHED_AT ))s" >&2
  echo "[DEBUG] five_h_reset : $RL_FIVE_H_RESET ($(date -r "${RL_FIVE_H_RESET:-0}" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo 'n/a'))" >&2
  echo "[DEBUG] five_h_util  : $RL_FIVE_H_UTIL  status=$RL_FIVE_H_STATUS" >&2
  echo "[DEBUG] seven_d_util : $RL_SEVEN_D_UTIL  status=$RL_SEVEN_D_STATUS" >&2
  echo "[DEBUG] time_left    : $SESSION_TIME_LEFT" >&2
fi

# ── 3. Session usage (5-hour rate limit) ─────────────────────────────────────
if [ -n "$RL_FIVE_H_UTIL" ]; then
  SESSION_USAGE_LEFT=$(python3 -c "print(round((1 - float('$RL_FIVE_H_UTIL')) * 100))" 2>/dev/null || echo "")
  if [ -n "$SESSION_USAGE_LEFT" ]; then
    UTIL_INT=$(python3 -c "print(round(float('$RL_FIVE_H_UTIL') * 100))" 2>/dev/null || echo "0")
    if [ "$UTIL_INT" -gt 90 ] 2>/dev/null; then
      SESSION_USAGE_FIELD="${RED}${SESSION_USAGE_LEFT}% sess${RESET}"
    elif [ "$UTIL_INT" -gt 75 ] 2>/dev/null; then
      SESSION_USAGE_FIELD="${YELLOW}${SESSION_USAGE_LEFT}% sess${RESET}"
    else
      SESSION_USAGE_FIELD="${GREEN}${SESSION_USAGE_LEFT}% sess${RESET}"
    fi
  else
    SESSION_USAGE_FIELD="${DIM}— sess${RESET}"
  fi
else
  SESSION_USAGE_FIELD="${DIM}— sess${RESET}"
fi

# ── 4. Weekly usage ───────────────────────────────────────────────────────────
if [ -n "$RL_SEVEN_D_UTIL" ]; then
  WEEK_LEFT=$(python3 -c "print(round((1 - float('$RL_SEVEN_D_UTIL')) * 100))" 2>/dev/null || echo "")
  if [ -n "$WEEK_LEFT" ]; then
    UTIL_WK=$(python3 -c "print(round(float('$RL_SEVEN_D_UTIL') * 100))" 2>/dev/null || echo "0")
    if [ "$UTIL_WK" -gt 90 ] 2>/dev/null; then
      WEEK_FIELD="${RED}${WEEK_LEFT}% wk${RESET}"
    elif [ "$UTIL_WK" -gt 75 ] 2>/dev/null; then
      WEEK_FIELD="${YELLOW}${WEEK_LEFT}% wk${RESET}"
    else
      WEEK_FIELD="${GREEN}${WEEK_LEFT}% wk${RESET}"
    fi
  else
    WEEK_FIELD="${DIM}— wk${RESET}"
  fi
else
  WEEK_FIELD="${DIM}— wk${RESET}"
fi

# ── 4b. Weekly reset time (fills the slot the model's "(1M context)" used to hold) ──
# Format: "wk→6th 4pm" from RL_SEVEN_D_RESET (epoch). Uses `date -r` like the debug
# line above; pure-bash ordinal suffix — no extra python fork on the render path.
WEEKRESET_FIELD="${DIM}wk→—${RESET}"
if [ -n "$RL_SEVEN_D_RESET" ] && [ "$RL_SEVEN_D_RESET" != "0" ]; then
  _wd=$(date -r "$RL_SEVEN_D_RESET" "+%-d" 2>/dev/null)
  _wh=$(date -r "$RL_SEVEN_D_RESET" "+%-I" 2>/dev/null)
  _wm=$(date -r "$RL_SEVEN_D_RESET" "+%M" 2>/dev/null)
  _wp=$(date -r "$RL_SEVEN_D_RESET" "+%p" 2>/dev/null | tr 'A-Z' 'a-z')
  if [ -n "$_wd" ] && [ -n "$_wh" ]; then
    case "$_wd" in
      11|12|13) _sfx="th" ;;
      *1)       _sfx="st" ;;
      *2)       _sfx="nd" ;;
      *3)       _sfx="rd" ;;
      *)        _sfx="th" ;;
    esac
    if [ "$_wm" = "00" ]; then _wt="${_wh}${_wp}"; else _wt="${_wh}:${_wm}${_wp}"; fi
    WEEKRESET_FIELD="${CYAN}wk→${_wd}${_sfx} ${_wt}${RESET}"
  fi
fi

# ── 5. Effort / model display ─────────────────────────────────────────────────
MODEL_DISPLAY=$(jq_get '.model.display_name')
# Drop any "(… context)" parenthetical — the 1M window is assumed (per 2026-05-30 plan).
MODEL_DISPLAY=$(printf '%s' "$MODEL_DISPLAY" | sed -E 's/[[:space:]]*\([^)]*[Cc]ontext[^)]*\)//')
EFFORT_LEVEL=$(jq_get '.effort.level')

if [ -n "$MODEL_DISPLAY" ] && [ "$MODEL_DISPLAY" != "null" ]; then
  EFFORT_FIELD="$MODEL_DISPLAY"
else
  EFFORT_FIELD="${MODEL_ID:-—}"
fi

# Append effort level if present and not already encoded in model name
if [ -n "$EFFORT_LEVEL" ] && [ "$EFFORT_LEVEL" != "null" ] && [ "$EFFORT_LEVEL" != "" ]; then
  # Map effort levels to short labels
  case "$EFFORT_LEVEL" in
    low)    EFFORT_LABEL="[lo]" ;;
    medium) EFFORT_LABEL="[med]" ;;
    high)   EFFORT_LABEL="[hi]" ;;
    xhigh)  EFFORT_LABEL="[xhi]" ;;
    max)    EFFORT_LABEL="[max]" ;;
    *)      EFFORT_LABEL="[${EFFORT_LEVEL}]" ;;
  esac
  EFFORT_FIELD="${EFFORT_FIELD} ${EFFORT_LABEL}"
fi

# ── 6. Repo name ──────────────────────────────────────────────────────────────
CWD=$(jq_get '.workspace.current_dir')
if [ -z "$CWD" ]; then
  CWD=$(jq_get '.cwd')
fi
if [ -z "$CWD" ]; then
  CWD="$PWD"
fi

REPO_NAME=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  REPO_NAME=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null \
    | xargs basename 2>/dev/null || echo "")
fi

if [ -z "$REPO_NAME" ]; then
  REPO_NAME=$(basename "$CWD" 2>/dev/null || echo "—")
fi

REPO_FIELD="${BOLD}${REPO_NAME}${RESET}"

# ── Assemble status line ──────────────────────────────────────────────────────
# Format: ctx 42%  3h12m left  72% sess  85% wk  Opus 4.8 [hi]  wk→6th 4pm  my-repo
printf "%b  %b  %b  %b  %b  %b  %b\n" \
  "$CTX_FIELD" \
  "$SESSION_FIELD" \
  "$SESSION_USAGE_FIELD" \
  "$WEEK_FIELD" \
  "$EFFORT_FIELD" \
  "$WEEKRESET_FIELD" \
  "$REPO_FIELD"

# ── 7. Line 2: progress bars (active) or session label (idle) ──────────────
# Reads ~/.claude/progress/<sid>.json first; if absent or stale, falls back to
# the existing ~/.claude/session-status/<sid>.txt label. Empty if neither.
SESSION_ID=$(jq_get '.session_id')
SAFE_SID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9_-' | head -c 128 || true)
LINE2=""

if [ -n "$SAFE_SID" ]; then
  PROGRESS_FILE="$HOME/.claude/progress/$SAFE_SID.json"
  if [ -f "$PROGRESS_FILE" ]; then
    LINE2=$(python3 - "$PROGRESS_FILE" <<'PY' 2>/dev/null
import json, sys, time
try:
    with open(sys.argv[1]) as fh: s = json.load(fh)
except Exception: sys.exit(0)
now_f = time.time()
now = int(now_f)
# 5-min failsafe: hide bars if no tool call in 5 min (Stop hook may have misfired)
if now - s.get("last_tick", now) > 300: sys.exit(0)

elapsed = now - s.get("prompt_started_at", now)
mins, secs = divmod(elapsed, 60)
stalled = (now - s.get("last_tick", now)) > 30
color = "\033[0;33m" if stalled else "\033[0;32m"  # yellow if stalled, green otherwise
reset = "\033[0m"
WIDTH = 8

def bar(spec):
    if spec.get("indeterminate") or not spec.get("total"):
        # Sub-second pos so the sliding window glides on every render
        pos = int(now_f * 4) % WIDTH
        cells = ["▱"] * WIDTH
        for i in range(3): cells[(pos + i) % WIDTH] = "▰"
        return "".join(cells), spec.get("label") or "working", None
    # Accept either `done` (overall) or `step` (current)
    done = int(spec.get("done", spec.get("step", 0)))
    total = int(spec["total"])
    if total <= 0: total = 1
    filled = max(0, min(WIDTH, (done * WIDTH) // total))
    return "▰"*filled + "▱"*(WIDTH-filled), spec.get("label") or "", f"{(100*done)//total}% {done}/{total}"

ov = s.get("overall", {"indeterminate": True})
cu = s.get("current", {"indeterminate": True})
ovb, ovl, ovp = bar(ov)
cub, cul, cup = bar(cu)
ov_str = f"task {ovb} {ovp}" if ovp else f"task {ovb} {ovl}"
cu_label = s.get("outer_command") or cul or "cmd"
cu_str = f"{cu_label} {cub} {cup}" if cup else f"{cu_label} {cub} {cul}"
print(f"{color}{mins}:{secs:02d}  {ov_str}   {cu_str}{reset}")
PY
    )
  fi

  # Fallback to existing session label
  if [ -z "$LINE2" ]; then
    LABEL_FILE="$HOME/.claude/session-status/$SAFE_SID.txt"
    if [ -f "$LABEL_FILE" ]; then
      LABEL=$(head -n 1 "$LABEL_FILE" 2>/dev/null \
        | python3 -c "import sys; s=sys.stdin.readline().rstrip(); print(s[:99]+'…' if len(s) > 100 else s)" \
        2>/dev/null || true)
      [ -n "$LABEL" ] && LINE2="${DIM}${LABEL}${RESET}"
    fi
  fi
fi

[ -n "$LINE2" ] && printf "%b\n" "$LINE2"

# ── 8. ctx-gate broker write (per plan 2026-05-23) ─────────────────────────────
# Writes the harness-supplied context % to ~/.claude/progress/ctx-<sid>.txt so
# the ctx-gate hooks can read it without walking the transcript themselves.
# Side-effect only; never emits to stdout (would corrupt statusline). All errors
# silenced — broker failure must not abort statusline rendering.
if [ -n "$SAFE_SID" ]; then
  CTX_BROKER_DIR="$HOME/.claude/progress"
  CTX_BROKER_FILE="$CTX_BROKER_DIR/ctx-${SAFE_SID}.txt"
  if [ ! -d "$CTX_BROKER_DIR" ]; then
    mkdir -p "$CTX_BROKER_DIR" 2>/dev/null || true
    chmod 700 "$CTX_BROKER_DIR" 2>/dev/null || true
  fi
  # Validate CTX_PCT is purely numeric 0-100 before writing (per codex-review Depth):
  # `printf '%.0f'` can crash on non-numeric input, leaving CTX_PCT empty; previous behavior
  # was to delete the sidecar on empty, which silently disabled all gate hooks until next render.
  # New behavior: only write when CTX_PCT is a valid integer 0-100; otherwise PRESERVE
  # the existing sidecar (last-known-good) so transient render glitches don't disable the gate.
  case "$CTX_PCT" in
    ''|*[!0-9]*) : ;;  # empty or non-numeric — keep last-known-good
    *)
      if [ "$CTX_PCT" -ge 0 ] 2>/dev/null && [ "$CTX_PCT" -le 100 ] 2>/dev/null; then
        CTX_BROKER_TMP="${CTX_BROKER_FILE}.tmp.$$"
        ( umask 077 && printf '%s\n' "$CTX_PCT" > "$CTX_BROKER_TMP" ) 2>/dev/null || true
        { [ -f "$CTX_BROKER_TMP" ] && mv "$CTX_BROKER_TMP" "$CTX_BROKER_FILE" 2>/dev/null; } || true
      fi
      ;;
  esac
fi

exit 0
