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
# R5 Phase 3: source session-key.sh for HMAC breadcrumb signing.
. "$ROOT/lib/session-key.sh" 2>/dev/null || true

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

# C2 fix: Stop hook must use the SAME SID derivation as the writer (arm-auto-compact.sh)
# to find the sentinel the writer left.  The hook-JSON SESSION_ID is Claude Code's real
# session_id; the writer derives via ac_resolve_session_id (which may produce a
# TTY-keyed slug-fallback SID that differs from the real session_id when CLAUDE_SESSION_ID
# was unset at arm time and the transcript had not yet flushed).
#
# Strategy: try BOTH the hook-JSON SID AND the ac_resolve_session_id result.
# - If only one resolves to a sentinel file, use that one.
# - If both resolve to DISTINCT sentinels, REFUSE to fire /compact (H4 Adversary fail-closed).
#   An attacker who plants a transcript file + crafts a TTY redirect could redirect compact
#   delivery by triggering RESOLVED_SID to diverge from REAL_SID. Refusing when ownership
#   is ambiguous is the only safe option. A stop-hook-refused signal is written so the user
#   can be informed at the next session start (see breadcrumb with originating_command=stop-hook-fail-closed).
# - If neither resolves, fall through to the `[ -f "$SENTINEL" ] || exit 0` fast-path.
# NOTE: "Case (b) both sentinels with disagreement → REFUSE to fire /compact" was changed
# in R3-fix-sweep H4 from "prefer ac_resolve path" to "refuse". LOG_VERBS.md stop_hook_sid_mismatch
# has been updated to reflect the actual behavior (action=refuse).
REAL_SID="$SESSION_ID"
RESOLVED_SID=$(ac_resolve_session_id 2>/dev/null)
REAL_SENTINEL=$(ac_sentinel_path "$REAL_SID")
RESOLVED_SENTINEL=""
if [ -n "$RESOLVED_SID" ]; then
  RESOLVED_SENTINEL=$(ac_sentinel_path "$RESOLVED_SID")
fi

# Determine which sentinel to use.
REAL_EXISTS=false
RESOLVED_EXISTS=false
[ -f "$REAL_SENTINEL" ] && REAL_EXISTS=true
[ -n "$RESOLVED_SENTINEL" ] && [ -f "$RESOLVED_SENTINEL" ] && RESOLVED_EXISTS=true

if [ "$REAL_EXISTS" = "true" ] && [ "$RESOLVED_EXISTS" = "true" ] \
   && [ "$REAL_SENTINEL" != "$RESOLVED_SENTINEL" ]; then
  # R3-fix-sweep H4 (Adversary) + R4 Round 4 Phase 3: both sentinels exist but disagree — fail-closed.
  # Refuse to fire compact when sentinel ownership is ambiguous.
  _REAL_BASENAME=$(basename "$REAL_SENTINEL")
  _RESOLVED_BASENAME=$(basename "$RESOLVED_SENTINEL")
  handoff_log "stop_hook_sid_mismatch real_sid=$REAL_SID resolved_sid=$RESOLVED_SID real_basename=$_REAL_BASENAME resolved_basename=$_RESOLVED_BASENAME action=refuse"
  # Phase 3 (Round 4): write a stop-hook-refused breadcrumb so step2.sh can surface this
  # to the user at the next session start (STATE=stop-hook-refused).
  # Use the REAL_SID (hook-JSON SID) as the key — it's Claude Code's authoritative session ID.
  _REFUSE_BREADCRUMB_DIR="$HOME/.claude/progress"
  mkdir -p "$_REFUSE_BREADCRUMB_DIR" 2>/dev/null
  chmod 700 "$_REFUSE_BREADCRUMB_DIR" 2>/dev/null
  _REFUSE_BC="$_REFUSE_BREADCRUMB_DIR/breadcrumb-${REAL_SID}.json"
  _REFUSE_BC_TMP="${_REFUSE_BC}.tmp.$$"
  _REFUSE_HOST=""
  if _REFUSE_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64); then :
  elif _REFUSE_HOST=$(uname -n 2>/dev/null | tr -d '[:space:]' | head -c 64); then :
  fi
  # R5 Critical #6: drop next_steps from breadcrumb-writer to eliminate prompt-injection vector.
  # Attacker-controlled content (e.g., git commit messages, file names, env vars) could flow into
  # the next_steps field and then be emitted to the orchestrator LLM via STATE=stop-hook-refused.
  # step2.sh now hard-codes the recovery prose instead of relying on this field.
  if ( umask 077 && jq -c -n \
       --argjson sv 1 \
       --arg sid "$REAL_SID" \
       --arg sid8 "$(ac_compute_sid8 "$REAL_SID")" \
       --arg cmd "stop-hook-fail-closed" \
       --arg real_sid "$REAL_SID" --arg resolved_sid "$RESOLVED_SID" \
       --arg real_basename "$_REAL_BASENAME" --arg resolved_basename "$_RESOLVED_BASENAME" \
       --arg host "${_REFUSE_HOST:-unknown}" \
       '{schema_version:$sv,originating_command:$cmd,sid:$sid,sid8:$sid8,hostname:$host,real_sid:$real_sid,resolved_sid:$resolved_sid,real_basename:$real_basename,resolved_basename:$resolved_basename}' \
       > "$_REFUSE_BC_TMP" 2>/dev/null ) && mv "$_REFUSE_BC_TMP" "$_REFUSE_BC" 2>/dev/null; then
    handoff_log "stop_hook_refused_breadcrumb_written sid=$(ac_compute_sid8 "$REAL_SID") path=$_REFUSE_BC"
  else
    rm -f "$_REFUSE_BC_TMP" 2>/dev/null || true
  fi
  exit 0
elif [ "$REAL_EXISTS" = "false" ] && [ "$RESOLVED_EXISTS" = "true" ]; then
  # Only the resolved (arm-time) sentinel exists — use it.
  SESSION_ID="$RESOLVED_SID"
fi
# else: real-SID sentinel exists (or neither exists) — keep SESSION_ID as-is.

SENTINEL=$(ac_sentinel_path "$SESSION_ID")

# Garbage-collect orphan claim files (>1h old) on EVERY Stop event — this is the
# only routine cleanup path because most Stop events skip the sentinel-consume
# path (`[ -f "$SENTINEL" ] || exit 0` below is the typical fast-path). Putting
# GC here ensures it actually runs.
# R4 D5: GC only cross-session .claim files (they're orphaned by definition once their
# Stop hook process exits). Breadcrumbs are now per-session lifecycle: owner deletes on
# read OR own-session Stop deletes on next /pre-compact arm.
find "$HOME/.claude/progress" -maxdepth 1 -type f \
  -name 'auto-compact-*.json.claim.*' \
  -mmin +60 -delete 2>/dev/null || true

# H12 fix: GC stale orphan breadcrumbs (>24h old). These cannot belong to any live
# session — the 1h age guard in step2.sh rejects anything >3600s, and the EXIT trap
# (C4 fix) deletes breadcrumbs on consume. A >24h breadcrumb can only come from a
# crashed session (kernel panic, OOM, hard-kill). Safe to delete unconditionally.
# The count-and-log pattern keeps the log quiet under normal operation.
GC_BREAD_COUNT=$(find "$HOME/.claude/progress" -maxdepth 1 -type f \
  -name 'breadcrumb-*.json' \
  -mmin +1440 -print -delete 2>/dev/null | wc -l | tr -d '[:space:]')
[ -n "$GC_BREAD_COUNT" ] && [ "$GC_BREAD_COUNT" -gt 0 ] && handoff_log "gc_stale_orphan_breadcrumbs count=$GC_BREAD_COUNT"

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
OSA_RESULT=$(/usr/bin/osascript - "$TARGET_TTY" "$PTY_DELAY" <<'EOF' 2>"$OSA_STDERR_TGT"
on run argv
  set targetTTY to item 1 of argv
  set ptyDelay to (item 2 of argv) as real
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
    -- Chain /post-compact-resume into the same tab input queue. Claude Code TUI
    -- accepts typed input while a command is running and processes it as the next
    -- turn when the current turn ends. ptyDelay lets /compact register as the
    -- active command before the second do_script types in, avoiding the race where
    -- both lines could merge into one buffered blob. Wrapped in try so a failed
    -- second fire (e.g., slash command missing) still reports /compact as fired.
    -- NOTE: no apostrophes in this comment block — bash 3.2 heredoc-inside-$()
    -- has a known apostrophe-pairing quirk that breaks parsing even with <<EOF.
    delay ptyDelay
    try
      do script "/post-compact-resume" in foundTab
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
ac_log "stop sid=$SESSION_ID tty=$TARGET_TTY osa_exit=$OSA_EXIT result=${OSA_RESULT:-empty} stderr=${OSA_STDERR:-none}"
# B20: unified handoff audit trail — log compact chain event.
handoff_log "compact_chained sid=$(ac_compute_sid8 "$SESSION_ID") tty=$TARGET_TTY result=${OSA_RESULT:-unknown}"

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
if ( umask 077 && jq -c -n \
     --argjson sv 1 \
     --arg sid "$SESSION_ID" \
     --arg sid8 "$SID8" \
     --arg cwd "$SENTINEL_CWD" \
     --arg nonce "$SENTINEL_NONCE" \
     --arg host "$HOSTNAME_SHORT" \
     '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
     > "$BREADCRUMB_TMP" 2>/dev/null ); then
  if mv "$BREADCRUMB_TMP" "$BREADCRUMB" 2>/dev/null; then
    handoff_log "breadcrumb_written sid=${SID8} cwd=$SENTINEL_CWD host=$HOSTNAME_SHORT"
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

exit 0
