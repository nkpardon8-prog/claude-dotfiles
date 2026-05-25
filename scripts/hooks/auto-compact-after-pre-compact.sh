#!/usr/bin/env bash
# Stop hook — fires /compact into the originating Terminal.app tab when /pre-compact armed it.
#
# Execution context: this is a Claude Code Stop hook script.
# It runs as a direct subprocess of Claude Code, NOT through the orchestrator Bash tool.
#
# Mechanism:
#   1. /pre-compact (via arm-auto-compact.sh) writes a per-session JSON sentinel containing
#      the originating tab's TTY and metadata.
#   2. On every model Stop, this hook claims its session's sentinel atomically (mv-to-lock),
#      looks up the matching Terminal.app tab via AppleScript, verifies `claude` is the
#      foreground process in that tab, then delivers `/compact` via `do script ... in <tab>`
#      (writes to the tab's PTY input — no keystroke synthesis, no focus race, no Accessibility
#      requirement, only Terminal Automation permission).
#
# Anti-loop:
#   The sentinel is moved (atomic claim) to a `.claim.<pid>` file before any external command,
#   then removed entirely via EXIT trap. The Stop event that /compact triggers therefore finds
#   no sentinel and exits silently. The atomic mv also prevents two concurrent Stop events
#   from double-firing on the same sentinel (only one mv succeeds).
#
# Security:
#   - TARGET_TTY passed to osascript via argv (NOT heredoc string interpolation).
#   - TTY validated against anchored regex `^/dev/ttys[0-9]+$`.
#   - Sentinel: symlink-rejected, size-bounded (4KB), schema-validated.
#   - Foreground-process check: `do script` only fires if the matched tab is running `claude`.
#
# Platform: macOS Terminal.app only. The arming step refuses to write a sentinel for
# non-Darwin / non-Terminal.app / tmux / screen, so this hook is naturally inert there.
#
# Uninstall: run `~/.claude-dotfiles/scripts/hooks/uninstall-auto-compact.sh`.
# Diagnostics: `~/.claude/logs/auto-compact.log` (bounded ring, last ~64KB).

[ "$(uname -s)" = "Darwin" ] || exit 0
[ -z "${HOME:-}" ] && exit 0
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(printf '%s' "$INPUT" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null \
    | tr -cd 'A-Za-z0-9_-' | head -c 128)
fi
if [ -z "$SESSION_ID" ]; then
  # Forward-compat diagnostic: if Claude Code ever changes the Stop-hook JSON shape,
  # log a one-time hint so the user/maintainer can see why the hook went silent.
  # Strip ALL control bytes (not just \n) so terminal escapes in a hostile payload
  # can't corrupt the log when viewed with `cat`.
  ac_log "stop no-session-id input-head=$(printf '%s' "$INPUT" | head -c 200 | tr -d '[:cntrl:]')"
  exit 0
fi

# R8: Identity-via-arg. The hook-JSON SESSION_ID (payload) is the platform's authoritative
# session_id. Thread it verbatim as the /post-compact-resume command arg.
# REAL_SID = the payload value captured here, never mutated downstream.
# The dual-SID strategy and stop-hook-refused breadcrumb block (pre-R8) are deleted:
# - dual-SID (both REAL and RESOLVED sentinels) is gone — we use REAL_SID sentinel only.
# - stop-hook-refused is gone — no dual-sentinel conflict possible anymore.
# Sentinel is the /compact TRIGGER only; handoff identity comes from the command arg.
REAL_SID="$SESSION_ID"

SENTINEL=$(ac_sentinel_path "$REAL_SID")

# Garbage-collect orphan claim files (>1h old) on EVERY Stop event — this is the
# only routine cleanup path because most Stop events skip the sentinel-consume
# path (`[ -f "$SENTINEL" ] || exit 0` below is the typical fast-path). Putting
# GC here ensures it actually runs.
find "$HOME/.claude/progress" -maxdepth 1 -type f \
  -name 'auto-compact-*.json.claim.*' \
  -mmin +60 -delete 2>/dev/null || true

# V2-11 (R8): GC stale orphan breadcrumbs (>24h old) — sweeps migration residue from
# pre-R8 sessions that wrote breadcrumbs. Also sweep stale .session-key-* files from
# pre-R8 sessions. Both are safe to delete after 24h; no live session uses them under R8.
# The count-and-log pattern keeps the log quiet under normal operation.
GC_BREAD_COUNT=$(find "$HOME/.claude/progress" -maxdepth 1 -type f \
  -name 'breadcrumb-*.json' \
  -mmin +1440 -print -delete 2>/dev/null | wc -l | tr -d '[:space:]')
[ -n "$GC_BREAD_COUNT" ] && [ "$GC_BREAD_COUNT" -gt 0 ] && handoff_log "gc_stale_orphan_breadcrumbs count=$GC_BREAD_COUNT"

find "$HOME/.claude/progress" -maxdepth 1 -type f \
  -name '.session-key-*' \
  -mmin +1440 -delete 2>/dev/null || true

[ -f "$SENTINEL" ] || exit 0

# Atomic claim: rename to a per-pid lock file. Only one concurrent invocation succeeds.
# This is the primary anti-loop guarantee — `mv` is atomic on POSIX, so any later
# Stop event (including the one /compact itself emits) finds no sentinel and exits.
CLAIM="${SENTINEL}.claim.$$"
OSA_STDERR_TMP=""
if ! mv "$SENTINEL" "$CLAIM" 2>/dev/null; then
  exit 0
fi
trap 'rm -f "$CLAIM" "${OSA_STDERR_TMP:-}"' EXIT

TARGET_TTY=$(ac_read_sentinel_tty "$CLAIM") || exit 0

# Foreground-process verification: confirm `claude` is in the foreground process group
# on the target TTY (the `+` flag in `ps -o stat=`). If the user pivoted to vim/psql/ssh
# in that tab post-arm, that process owns the foreground PG and `claude` doesn't have `+`,
# so we refuse to type — `do script` would deliver `/compact` to the wrong process.
#
# NOTE: -E (ERE) is required. BSD grep treats `\|` in BRE as literal — every check
# would fail and the hook would always abort. Round 3 caught this.
TTY_SHORT="${TARGET_TTY#/dev/}"
# Use `args=` not `ucomm=` (per empirical /script finding 2026-05-23): Claude Code's
# ucomm is the version string (e.g., `2.1.149`), not `claude` — every arm since
# 2026-05-14 aborted because of this. ucomm changes with every release; argv[0] is
# stable as `claude`. Match on args= for the foreground process group leader. The
# pattern `(^|[[:space:]/])claude([[:space:]]|$)` matches `claude`, `-claude`,
# `/path/to/claude`, and `claude --any-flags`; rejects unrelated `node` / `caffeinate`
# processes that happen to share the foreground pgid with the claude TUI.
FG_HIT=$(ps -ww -t "$TTY_SHORT" -o stat=,args= 2>/dev/null \
         | awk '$1 ~ /\+/' \
         | grep -E '(^|[[:space:]/])claude([[:space:]]|$)' | head -1)
# `-ww` forces ps to NOT truncate `args=` at terminal width — BSD ps default truncates at
# ~80 cols, which loses the `claude` token in long argv (e.g., when the user launches via
# a wrapper that injects env paths). Per codex-review Depth.
if [ -z "$FG_HIT" ]; then
  ac_log "abort sid=$SESSION_ID tty=$TARGET_TTY reason=no-claude-in-foreground-pg"
  exit 0
fi

# Deliver /compact via `do script ... in foundTab` (AppleScript writes to tab PTY input).
# TARGET_TTY passes through argv — never string-interpolated into the AppleScript body.
# Capture stdout (the on-run handler's return value: "fired"/"no-matching-tab"/etc.)
# separately from stderr so log lines stay single-line and structured.
# Per-system PTY delay override: default 0.3s; set CTX_GATE_PTY_DELAY_SEC to tune.
# Slow machines may need 0.5-1.0; fast machines may be fine with 0.1.
PTY_DELAY="${CTX_GATE_PTY_DELAY_SEC:-0.3}"

OSA_STDERR_TMP=$(mktemp 2>/dev/null)
# If mktemp fails (rare — full /tmp), keep $OSA_STDERR_TMP empty. We deliberately
# do NOT use "/dev/null" as a sentinel because the EXIT trap would then attempt
# `rm -f /dev/null` (harmless as non-root, destructive if ever run as root).
# Empty $OSA_STDERR_TMP means: redirect stderr to /dev/null at the osascript call
# (inline), and skip the stderr-capture branch.
OSA_STDERR_TGT="${OSA_STDERR_TMP:-/dev/null}"
# R8 V2-2+V2-3: pass REAL_SID as argv[3] (NOT SESSION_ID which may have been
# reassigned). Raw concat in AppleScript ("& (item 3 of argv)") — NOT quoted form of,
# which injects literal single-quotes that corrupt the typed command (smoke A2 proved).
# UUIDs contain only [A-Za-z0-9-] — no shell-special chars; raw concat is safe.
OSA_RESULT=$(/usr/bin/osascript - "$TARGET_TTY" "$PTY_DELAY" "$REAL_SID" <<'EOF' 2>"$OSA_STDERR_TGT"
on run argv
  set targetTTY to item 1 of argv
  set ptyDelay to (item 2 of argv) as real
  set sessionId to item 3 of argv
  tell application "Terminal"
    if not running then return "not-running"
    if not (exists window 1) then return "no-windows"
    set foundTab to missing value
    set foundWin to missing value
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of t) is targetTTY then
            set foundTab to t
            set foundWin to w
            exit repeat
          end if
        end try
      end repeat
      if foundTab is not missing value then exit repeat
    end repeat
    if foundTab is missing value then return "no-matching-tab"
    do script "/compact" in foundTab
    -- R8: Chain /post-compact-resume <session_id> so identity is threaded verbatim.
    -- Raw concat (& sessionId) — NOT quoted form of, which injects literal quotes.
    -- UUID chars are [A-Za-z0-9-] — no shell-special chars; safe for raw concat.
    -- NOTE: no apostrophes in this comment block — bash 3.2 heredoc-inside-$()
    -- has a known apostrophe-pairing quirk that breaks parsing even with <<EOF.
    delay ptyDelay
    try
      do script "/post-compact-resume " & sessionId in foundTab
      return "fired+queued-resume"
    on error errMsg
      return "fired+queue-failed:" & errMsg
    end try
  end tell
end run
EOF
)
OSA_EXIT=$?
# Collapse multi-line stderr to single token, strip control bytes, cap at 200 chars.
# Only read the tmpfile if we actually created one (empty $OSA_STDERR_TMP means
# stderr went to /dev/null and there is nothing to read; do NOT try to read /dev/null
# as that would block forever waiting for EOF on a character device).
if [ -n "$OSA_STDERR_TMP" ]; then
  OSA_STDERR=$(tr -d '[:cntrl:]' < "$OSA_STDERR_TMP" 2>/dev/null | head -c 200)
else
  OSA_STDERR=""
fi
ac_log "stop sid=$REAL_SID tty=$TARGET_TTY osa_exit=$OSA_EXIT result=${OSA_RESULT:-empty} stderr=${OSA_STDERR:-none}"
# B20: unified handoff audit trail — log compact chain event. V2-15: log full session_id.
handoff_log "compact_chained sid=$REAL_SID tty=$TARGET_TTY result=${OSA_RESULT:-unknown}"

# R4 PR-12: Write per-session breadcrumb so /post-compact-resume can recover the SID + nonce
# AFTER our EXIT trap removes the .claim file. Path is SID-scoped (PR-1) to avoid
# parallel-session races. Hostname-tagged (PR-3) for iCloud cross-machine defense.
# No mtime field in JSON (PR-12) — filesystem mtime is canonical.
# R4 PR-12: breadcrumb-write decoupled from OSA delivery success. The breadcrumb's purpose
# is SID recovery for /post-compact-resume, NOT delivery confirmation. Block runs AFTER
# AppleScript invocation but BEFORE exit 0, regardless of OSA_RESULT.
BREADCRUMB_DIR="$HOME/.claude/progress"
# R3-fix-sweep C2: use TTY-aware ac_compute_sid8 (defined in lib/auto-compact-sentinel.sh,
# sourced at top of script) so parallel sessions with __ttysN suffix get DISTINCT SID8 values.
SID8=$(ac_compute_sid8 "$SESSION_ID")
BREADCRUMB="$BREADCRUMB_DIR/breadcrumb-${SESSION_ID}.json"
# Read sentinel fields from the claim before EXIT trap removes it.
SENTINEL_NONCE=$(ac_read_sentinel_nonce "$CLAIM" 2>/dev/null || printf '')
SENTINEL_CWD=$(ac_read_sentinel_cwd "$CLAIM" 2>/dev/null || printf '')

# R4 H8 / PR-M2: if SENTINEL_NONCE is empty, breadcrumb would be unvalidatable.
# Log + skip — do NOT write a nonce-less breadcrumb (caller cannot validate nonce_ok).
if [ -z "$SENTINEL_NONCE" ]; then
  handoff_log "breadcrumb_write_failed sid=${SID8} reason=empty-sentinel-nonce"
  exit 0
fi

# R4 H2: hostname fallback chain (explicit if-elif — no || cascade per bash 3.2 BSD portability).
HOSTNAME_SHORT=""
if HOSTNAME_SHORT=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64); then
  :
elif HOSTNAME_SHORT=$(uname -n 2>/dev/null | tr -d '[:space:]' | head -c 64); then
  :
elif HOSTNAME_SHORT=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]' | head -c 64); then
  :
else
  HOSTNAME_SHORT=""
fi
if [ -z "$HOSTNAME_SHORT" ]; then
  handoff_log "breadcrumb_write_failed sid=${SID8} reason=hostname-fail"
  exit 0
fi

# R4 H4: ensure BREADCRUMB_DIR has restrictive permissions.
mkdir -p "$BREADCRUMB_DIR" 2>/dev/null
chmod 700 "$BREADCRUMB_DIR" 2>/dev/null

# R2-PR-8 / PR-7: delete this session's prior breadcrumb (from a prior /pre-compact arm
# within the same Claude Code session) BEFORE writing the new one. Without this, a session
# that ran /pre-compact twice would leave the stale prior-arm breadcrumb visible until
# /post-compact-resume consumes it. This is OWN-SESSION cleanup (NOT cross-session).
rm -f "$BREADCRUMB" 2>/dev/null || true

BREADCRUMB_TMP="${BREADCRUMB}.tmp.$$"
# R4 H4: wrap breadcrumb write in umask 077 subshell for mode 600.
# H1: breadcrumb JSON gains schema_version:1 and originating_command fields.
# R5 Phase 3: generate per-session HMAC key + sign canonical fields before writing breadcrumb.
# This allows step2.sh to verify the breadcrumb was written by THIS session's Stop hook
# (not an attacker who knows the SID and writes a forged breadcrumb + handoff).
# If session_key_generate or session_key_sign fails (openssl absent, /tmp full, etc.),
# we write an unsigned breadcrumb and log a warning. step2.sh rejects unsigned breadcrumbs
# unless HANDOFF_ACCEPT_UNSIGNED=1 is set (migration window escape hatch).
_BC_SIG=""
if command -v session_key_generate >/dev/null 2>&1; then
  if session_key_generate "$SID8" 2>/dev/null; then
    # Sign: sid, nonce (=marker_nonce for this pre-compact breadcrumb), cwd, host, origcmd.
    # marker_nonce and nonce are the same field at breadcrumb-write time (sentinel marker_nonce).
    _BC_SIG=$(session_key_sign "$SID8" "$SESSION_ID" "$SENTINEL_NONCE" "$SENTINEL_NONCE" \
      "$SENTINEL_CWD" "$HOSTNAME_SHORT" "pre-compact" 2>/dev/null) || _BC_SIG=""
  fi
fi
[ -z "$_BC_SIG" ] && handoff_log "breadcrumb_unsigned sid=${SID8} reason=session-key-sign-failed"
if ( umask 077 && jq -c -n \
     --argjson sv 1 \
     --arg sid "$SESSION_ID" \
     --arg sid8 "$SID8" \
     --arg cwd "$SENTINEL_CWD" \
     --arg nonce "$SENTINEL_NONCE" \
     --arg host "$HOSTNAME_SHORT" \
     --arg sig "${_BC_SIG:-}" \
     '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host,signature:$sig}' \
     > "$BREADCRUMB_TMP" 2>/dev/null ); then
  if mv "$BREADCRUMB_TMP" "$BREADCRUMB" 2>/dev/null; then
    handoff_log "breadcrumb_written sid=${SID8} cwd=$SENTINEL_CWD host=$HOSTNAME_SHORT signed=$([ -n "$_BC_SIG" ] && echo yes || echo no)"
  else
    rm -f "$BREADCRUMB_TMP" 2>/dev/null
    handoff_log "breadcrumb_write_failed sid=${SID8} reason=mv"
  fi
else
  rm -f "$BREADCRUMB_TMP" 2>/dev/null
  handoff_log "breadcrumb_write_failed sid=${SID8} reason=jq"
fi

# R4 D5: delete .tmp.<pid> orphans from crashed writes of THIS same session
# (NOT cross-session). Identifies by glob breadcrumb-${SESSION_ID}.json.tmp.*.
# The write above is already complete; only prior .tmp.* orphans are deleted.
find "$BREADCRUMB_DIR" -maxdepth 1 -type f \
  -name "breadcrumb-${SESSION_ID}.json.tmp.*" \
  -delete 2>/dev/null || true

# R7-INC.1 B3: PRECOMPACT_PID scratch cleanup removed (dead code).
# The env var PRECOMPACT_PID cannot reliably cross process-tree boundaries (the Stop hook
# runs in a different process context than the /pre-compact orchestrator). The scratch file
# is now SID-keyed (pre-compact-parent-<SID>.json), not PID-keyed, and is cleaned up by:
#   (a) Step 9.1 orchestrator rm -f (primary path — runs before sentinel arm)
#   (b) 720-min GC glob pre-compact-parent-*.json in on-session-start-cleanup.sh (fallback)

exit 0
