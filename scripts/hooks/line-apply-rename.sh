#!/usr/bin/env bash
# Stop hook - types `/rename <name>` into THIS session's own Terminal.app tab when a /line request
# is waiting, so the display name (what Remote Control shows on the owner's other Macs) changes LIVE.
# The name is always the window's peer HANDLE, never the caption sentence: /rename also sets the
# session registry name to its argument, so typing the handle leaves address == display name.
#
# Why a hook has to type it: `/line` already appends the same custom-title record /rename writes, but
# a running session only reads that record at startup/resume. The built-in /rename is the only thing
# that updates the live name, and it cannot be driven from a slash command's Bash call. So /line
# (line-agent-communicator.py cmd_set) leaves a one-shot request at
#   ~/.claude/progress/line-rename-<sid>.json    {"name": "<handle>", "at": <epoch>}
# and this hook, at the end of that reply, types the command into the session's own tab.
# line-reassert-identity.sh (SessionStart) leaves the same request after a reopen when the transcript's
# last title no longer matches the handle.
#
# Tab targeting is the auto-compact Stop hook's hardened machinery, reused through its library
# (lib/auto-compact-sentinel.sh) rather than copied: own-ancestry claude pid, identity tuple
# {pid, start-time, argv-is-claude}, controlling tty, pid-pinned foreground-leader check, then an
# AppleScript that finds the Terminal tab by tty and `do script`s into it. VERIFY-THEN-CLAIM: every
# check runs before the atomic claim, the identity is re-checked after it, and every failure aborts
# WITHOUT typing. Never misfire into a sibling session.
#
# Ordering with auto-compact: if an auto-compact sentinel for this session is armed (or mid-claim),
# this hook defers without touching the request - /compact + /post-compact-resume go first, and the
# rename goes out on a later Stop.
#
# Retry: a failed attempt keeps the request for exactly ONE more try (a `tries` counter in the
# request), then drops it. Requests older than 1 hour are deleted without typing.
#
# Security:
#   - The name is passed to osascript via argv, never interpolated into the AppleScript source, and
#     re-validated here against the handle shape [a-z0-9-]{1,60}, no leading hyphen (the writer
#     already refuses anything else).
#   - Request file: symlink-rejected, size-bounded (4KB), schema-validated.
#
# Platform: macOS Terminal.app only (TERM_PROGRAM=Apple_Terminal, not inside tmux/screen). Anywhere
# else the request is dropped and `unsupported-terminal` logged; cmd_set already printed the manual
# `/rename` tip in that case, so nothing was promised.
#
# Diagnostics: ~/.claude/logs/line-rename.log (mode 600, bounded ring). Verbs: LOG_VERBS.md.
# Hook stdout is not shown to the user, so this hook prints nothing.

[ "$(uname -s)" = "Darwin" ] || exit 0
[ -z "${HOME:-}" ] && exit 0
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

PROGRESS_DIR="$HOME/.claude/progress"
LR_LOG="$HOME/.claude/logs/line-rename.log"
LR_MAX_REQUEST_BYTES=4096
LR_STALE_SEC=3600

lr_log() {
  local dir size tmp
  dir=$(dirname "$LR_LOG")
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null
    chmod 700 "$dir" 2>/dev/null
  fi
  ( umask 077 && printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LR_LOG" ) 2>/dev/null || return 0
  size=$(wc -c < "$LR_LOG" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$size" ] && [ "$size" -gt 65536 ]; then
    tmp="${LR_LOG}.tmp.$$"
    ( umask 077 && tail -c 32768 "$LR_LOG" > "$tmp" ) 2>/dev/null && mv "$tmp" "$LR_LOG" 2>/dev/null
  fi
  return 0
}

# Session id: stdin JSON first (the channel the harness populates for hooks), env only as fallback.
INPUT=$(head -c 1048576)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [ -z "$SID" ]; then
  SID=$(printf '%s' "$INPUT" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
fi
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
SID=$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -n "$SID" ] || exit 0

# Orphan GC on every Stop (cheap): claims left by a crashed run, temp files left by a crashed writer.
find "$PROGRESS_DIR" -maxdepth 1 -type f -name 'line-rename-*.json.claimed.*' -mmin +60 -delete 2>/dev/null || true
find "$PROGRESS_DIR" -maxdepth 1 -type f -name '.line-rename-*.tmp' -mmin +60 -delete 2>/dev/null || true

REQ="$PROGRESS_DIR/line-rename-$SID.json"
[ -e "$REQ" ] || [ -L "$REQ" ] || exit 0   # fast path: nothing requested

# ---- validate the request ------------------------------------------------------------------------
if [ -L "$REQ" ]; then
  rm -f "$REQ" 2>/dev/null   # removes the link, never its target
  lr_log "drop sid=$SID reason=symlink"
  exit 0
fi
[ -f "$REQ" ] || exit 0
REQ_SIZE=$(wc -c < "$REQ" 2>/dev/null | tr -d '[:space:]')
case "$REQ_SIZE" in ''|*[!0-9]*) REQ_SIZE=0 ;; esac
if [ "$REQ_SIZE" -gt "$LR_MAX_REQUEST_BYTES" ]; then
  rm -f "$REQ" 2>/dev/null
  lr_log "drop sid=$SID reason=oversized size=$REQ_SIZE"
  exit 0
fi
NAME=$(jq -r 'if type=="object" and (.name|type)=="string" then .name else empty end' < "$REQ" 2>/dev/null)
AT=$(jq -r 'if type=="object" and (.at|type)=="number" then .at else empty end' < "$REQ" 2>/dev/null)
case "$AT" in ''|*[!0-9]*) AT="" ;; esac
NAME_OK=1
[ -n "$NAME" ] || NAME_OK=0
[ "${#NAME}" -le 60 ] || NAME_OK=0
# The name is a peer handle (TYPEABLE_NAME in line-agent-communicator.py): lowercase ASCII letters,
# digits, hyphen, not starting with a hyphen. Explicit class, no ranges: under a UTF-8 locale bash
# collation lets `a-z` match letters like e-acute.
LR_NAME_CHARS='abcdefghijklmnopqrstuvwxyz0123456789-'
case "$NAME" in *[!"$LR_NAME_CHARS"]*|-*) NAME_OK=0 ;; esac
if [ -z "$AT" ] || [ "$NAME_OK" = 0 ]; then
  rm -f "$REQ" 2>/dev/null
  lr_log "drop sid=$SID reason=malformed"
  exit 0
fi

NOW=$(date +%s)
AGE=$((NOW - AT))
if [ "$AGE" -gt "$LR_STALE_SEC" ] || [ "$AGE" -lt -300 ]; then
  rm -f "$REQ" 2>/dev/null
  lr_log "stale sid=$SID age=${AGE}s (deleted without typing)"
  exit 0
fi

# ---- terminal gate -------------------------------------------------------------------------------
# The environment the harness hands this hook is the session's own, so this describes THIS window.
if [ "${TERM_PROGRAM:-}" != "Apple_Terminal" ] || [ -n "${TMUX:-}" ] || [ -n "${STY:-}" ]; then
  rm -f "$REQ" 2>/dev/null
  lr_log "unsupported-terminal sid=$SID term=${TERM_PROGRAM:-none} tmux=${TMUX:+yes} screen=${STY:+yes}"
  exit 0
fi

# ---- let a pending auto-compact go first ---------------------------------------------------------
AC_SENTINEL=$(ac_sentinel_path "$SID")
AC_BUSY=0
[ -f "$AC_SENTINEL" ] && AC_BUSY=1
for _c in "$AC_SENTINEL".claim.*; do
  [ -e "$_c" ] && AC_BUSY=1
done
if [ "$AC_BUSY" = 1 ]; then
  lr_log "defer sid=$SID reason=auto-compact-armed (request kept for a later Stop)"
  exit 0
fi

# lr_retry_or_drop <reason> <held-file>
# <held-file> is a claim WE own (moved off $REQ atomically). Give the request one more try by moving
# it back with tries=1 - unless it already had its retry, or a NEWER /line request has appeared at
# $REQ in the meantime (the newer one wins; ours is discarded).
lr_retry_or_drop() {
  local reason="$1" held="$2" tries tmp
  tries=$(jq -r '.tries // 0' < "$held" 2>/dev/null)
  case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
  if [ "$tries" -ge 1 ]; then
    rm -f "$held" 2>/dev/null
    lr_log "give-up sid=$SID reason=$reason tries=$((tries + 1)) (request dropped; the name is still saved in the chat and applies on the next restart)"
    return 0
  fi
  if [ -e "$REQ" ]; then
    rm -f "$held" 2>/dev/null
    lr_log "abort sid=$SID reason=$reason (a newer request replaced this one)"
    return 0
  fi
  tmp="${held}.retry"
  if ( umask 077 && jq -c '.tries = 1' < "$held" > "$tmp" ) 2>/dev/null && mv "$tmp" "$REQ" 2>/dev/null; then
    rm -f "$held" 2>/dev/null
    lr_log "abort sid=$SID reason=$reason (request kept for one retry)"
  else
    rm -f "$tmp" "$held" 2>/dev/null
    lr_log "abort sid=$SID reason=$reason (could not keep the request; dropped)"
  fi
}

# lr_abort_preclaim <reason>: a verification failed before the claim. Take the request atomically
# (so the retry bookkeeping cannot clobber a newer /line request mid-write), then retry-or-drop.
lr_abort_preclaim() {
  local held="${REQ}.claimed.$$"
  mv "$REQ" "$held" 2>/dev/null || exit 0   # someone else took it
  lr_retry_or_drop "$1" "$held"
  exit 0
}

# ---- verify: this session's own claude, its identity, its tty ------------------------------------
TARGET_PID=$(ac_resolve_own_claude_pid)
[ -n "$TARGET_PID" ] || lr_abort_preclaim "own-claude-unresolved"
PID_START=$(ac_pid_starttime "$TARGET_PID")
[ -n "$PID_START" ] || lr_abort_preclaim "starttime-empty"
ac_pid_argv_is_claude "$TARGET_PID" || lr_abort_preclaim "argv-mismatch"
TARGET_TTY=$(ac_pid_tty "$TARGET_PID")
if [ -z "$TARGET_TTY" ] || ! ac_validate_tty "$TARGET_TTY"; then
  lr_abort_preclaim "tty-unresolved"
fi
TTY_SHORT="${TARGET_TTY#/dev/}"
ac_pid_is_foreground_leader_on_tty "$TARGET_PID" "$TTY_SHORT" || lr_abort_preclaim "not-foreground-leader"

# ---- claim (atomic; only one concurrent Stop wins) -----------------------------------------------
CLAIM="${REQ}.claimed.$$"
mv "$REQ" "$CLAIM" 2>/dev/null || exit 0
OSA_STDERR_TMP=""
trap 'rm -f "$CLAIM" "${OSA_STDERR_TMP:-}"' EXIT

# TOCTOU narrowing: re-check the full identity tuple right before typing.
TTY2=$(ac_pid_tty "$TARGET_PID")
START2=$(ac_pid_starttime "$TARGET_PID")
if [ "$TTY2" != "$TARGET_TTY" ] || [ "$START2" != "$PID_START" ] \
   || ! ac_pid_argv_is_claude "$TARGET_PID" \
   || ! ac_pid_is_foreground_leader_on_tty "$TARGET_PID" "$TTY_SHORT"; then
  lr_retry_or_drop "identity-churned-pre-fire" "$CLAIM"
  exit 0
fi

# ---- fire ----------------------------------------------------------------------------------------
# Test seam: LINE_RENAME_OSASCRIPT replaces /usr/bin/osascript, but ONLY when HOME is not this
# account's real home directory (i.e. inside a test harness's fake HOME). A real Stop hook runs with
# the real HOME, so the override can never apply there.
OSA_BIN=/usr/bin/osascript
if [ -n "${LINE_RENAME_OSASCRIPT:-}" ]; then
  REAL_HOME=$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null)
  if [ -n "$REAL_HOME" ] && [ "$HOME" != "$REAL_HOME" ] && [ -x "$LINE_RENAME_OSASCRIPT" ]; then
    OSA_BIN="$LINE_RENAME_OSASCRIPT"
  else
    lr_log "test-seam-ignored sid=$SID (LINE_RENAME_OSASCRIPT set outside a fake HOME)"
  fi
fi

OSA_STDERR_TMP=$(mktemp 2>/dev/null)
OSA_STDERR_TGT="${OSA_STDERR_TMP:-/dev/null}"
# The name travels as argv item 2 and is concatenated as a VALUE inside AppleScript - it is never
# part of the script source, so no quoting in it can change what the script does.
# NOTE: no apostrophes inside this heredoc (bash 3.2 heredoc-inside-$() pairing quirk).
OSA_RESULT=$("$OSA_BIN" - "$TARGET_TTY" "$NAME" <<'EOF' 2>"$OSA_STDERR_TGT"
on run argv
  set targetTTY to item 1 of argv
  set theName to item 2 of argv
  tell application "Terminal"
    if not running then return "not-running"
    if not (exists window 1) then return "no-windows"
    set foundTab to missing value
    set winSeen to 0
    set winSkipped to 0
    set tabsSeen to 0
    repeat with w in windows
      set winSeen to winSeen + 1
      try
        repeat with t in tabs of w
          set tabsSeen to tabsSeen + 1
          try
            if (tty of t) is targetTTY then
              set foundTab to t
              exit repeat
            end if
          end try
        end repeat
      on error
        set winSkipped to winSkipped + 1
      end try
      if foundTab is not missing value then exit repeat
    end repeat
    if foundTab is missing value then return "no-matching-tab/win=" & winSeen & "/skip=" & winSkipped & "/tabs=" & tabsSeen
    do script ("/rename " & theName) in foundTab
    return "fired"
  end tell
end run
EOF
)
OSA_EXIT=$?
if [ -n "$OSA_STDERR_TMP" ]; then
  OSA_STDERR=$(tr -d '[:cntrl:]' < "$OSA_STDERR_TMP" 2>/dev/null | head -c 200)
else
  OSA_STDERR=""
fi

if [ "$OSA_EXIT" = 0 ] && [ "${OSA_RESULT:-}" = "fired" ]; then
  rm -f "$CLAIM" 2>/dev/null
  lr_log "fired sid=$SID tty=$TARGET_TTY name=$NAME"
else
  lr_retry_or_drop "osascript-failed/exit=$OSA_EXIT/result=${OSA_RESULT:-empty}/stderr=${OSA_STDERR:-none}" "$CLAIM"
fi
exit 0
