#!/usr/bin/env bash
# Arm auto-compact: write a per-session sentinel that the Stop hook will consume to
# fire `/compact` into the originating Terminal.app tab — or, when running inside a Pane
# panel, into that panel via `runpane` (delivery:"pane"). Invoked from /pre-compact's
# Step 9.0; can also be invoked directly for testing.
#
# Execution context: this is a Claude Code hook script (invoked from /pre-compact via
# the orchestrator Bash tool, or directly from terminal). When called from /pre-compact,
# it runs as a subprocess of the Bash tool — NOT directly as a Claude Code hook process.
# This means deny-class restrictions do NOT apply; all subprocess shell features are available.
#
# Usage:   arm-auto-compact.sh [ARGUMENTS_STRING]
# Prints:  one line to stdout — the arming state to embed in the /pre-compact report.
# Args:    if the ARGUMENTS_STRING contains `no-auto-compact`, `--no-auto-compact`,
#          or the phrase `no auto compact`, disarm any prior sentinel and skip arming.
#
# KNOWN LIMITATION (R4 D8 + Fix-sweep Commit 1):
# When CLAUDE_SESSION_ID is unset (true in Bash subprocesses spawned from the Bash tool),
# SID is derived from slug-of-cwd + most-recent .jsonl transcript via `ls -t | head -1`.
# At N>=2 parallel sessions in the same cwd without distinct CLAUDE_SESSION_ID, the
# fallback path now folds TTY basename into the SID via _ac_resolve_tty_basename_via_ppid
# (slug-fallback SID format: ${transcript_sid}__${tty_basename}).
# In normal Claude Code operation, CLAUDE_SESSION_ID IS exported and this fallback is
# bypassed entirely. The fallback exists for development-time / manual-invocation cases.
# Live observation 2026-05-24 confirmed pre-fix collision: Track A SID a90ac8f5 clobbered
# Track B's c6f7c23c sentinel under shared cwd. Fix-sweep Commit 1 added TTY-keying.

[ "$(uname -s)" = "Darwin" ] || { echo "NOT armed — auto-compact requires macOS Terminal.app"; exit 0; }
[ -z "${HOME:-}" ] && { echo "NOT armed — HOME unset"; exit 0; }
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

ARGS=" ${1:-} "

# --dry-run: resolve everything but don't write the sentinel. For verifying the
# pipeline without firing /compact for real. Prints what WOULD be armed.
case "$ARGS" in
  *" --dry-run "*) DRY_RUN=1 ;;
  *) DRY_RUN=0 ;;
esac

# Opt-out detection: accept hyphenated token, dash-prefixed flag, or space-separated phrase.
case "$ARGS" in
  *" no-auto-compact "*|*" --no-auto-compact "*|*" no auto compact "*)
    SID=$(ac_resolve_session_id)
    if [ -n "$SID" ]; then
      rm -f "$(ac_sentinel_path "$SID")" 2>/dev/null
      ac_log "disarmed sid=$SID"
    fi
    echo "skipped per request"
    exit 0
    ;;
esac

# Host / multiplexer guards FIRST (cheapest checks, most discriminating).
if [ -n "${TMUX:-}" ] || [ -n "${STY:-}" ]; then
  echo "NOT armed — running inside tmux/screen; auto-compact requires direct Terminal.app"
  exit 0
fi
# PANE MODE (2026-10-16): the Pane app runs Claude in its own pty and leaves TERM_PROGRAM
# unset, so the Terminal.app guard below used to pass and arm a sentinel the Stop hook could
# never deliver (no Terminal tab owns that tty). Pane mode = PANE_PANEL_ID set AND TERM_PROGRAM
# unset; any host that names itself in TERM_PROGRAM takes the unchanged Terminal.app path.
PANE_MODE=0
PANE_RUNPANE=""
PANE_DIR=""
if [ -n "${PANE_PANEL_ID:-}" ] && [ -z "${TERM_PROGRAM:-}" ]; then
  PANE_MODE=1
  if ! ac_validate_pane_panel_id "$PANE_PANEL_ID"; then
    ac_log "arm-failed reason=pane-panel-id-invalid"
    echo "NOT armed — Pane detected but PANE_PANEL_ID is not a valid panel id; run /compact manually"
    exit 0
  fi
  PANE_RUNPANE=$(ac_resolve_runpane_bin) || PANE_RUNPANE=""
  if [ -z "$PANE_RUNPANE" ]; then
    ac_log "arm-failed reason=pane-runpane-unavailable panel=$PANE_PANEL_ID"
    echo "NOT armed — Pane detected but runpane unavailable; run /compact manually"
    exit 0
  fi
  # Pane data dir = the parent of runpane's bin/ dir (~/.pane/bin/runpane → ~/.pane) when it
  # looks like one; otherwise the default ~/.pane.
  PANE_DIR=$(dirname "$(dirname "$PANE_RUNPANE")")
  if [ ! -f "$PANE_DIR/config.json" ] && [ ! -d "$PANE_DIR/sockets" ]; then
    PANE_DIR="$HOME/.pane"
  fi
  if [ ! -d "$PANE_DIR" ]; then
    ac_log "arm-failed reason=pane-dir-missing panel=$PANE_PANEL_ID"
    echo "NOT armed — Pane detected but its data dir could not be found; run /compact manually"
    exit 0
  fi
fi
if [ -n "${TERM_PROGRAM:-}" ] && [ "${TERM_PROGRAM:-}" != "Apple_Terminal" ]; then
  echo "NOT armed — host is '${TERM_PROGRAM}'; auto-compact requires Terminal.app"
  exit 0
fi

# Stop-hook registration check. Uses jq for proper JSON parsing (grep would
# false-positive on stale strings inside other fields, e.g. a `description`).
# Catches: (a) fresh installs not wired yet, (b) post-uninstall state where the
# Stop entry was removed but the user runs /pre-compact again.
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  if ! jq -e '(.hooks.Stop // []) | map(.hooks[]?.command // "") | any(test("auto-compact-after-pre-compact\\.sh"))' "$SETTINGS" >/dev/null 2>&1; then
    echo "NOT armed — Stop hook not registered in $SETTINGS (re-add the entry to enable auto-compact)"
    exit 0
  fi
fi

# First-run Automation permission probe. macOS TCC prompts on first use; if the
# user has walked away, the prompt blocks indefinitely. Wrap in a perl-based
# 2-second alarm (macOS doesn't ship coreutils `timeout(1)`). Non-fatal: if the
# probe fails or times out we still arm — the user may pass on the actual fire.
# Pane mode never uses AppleScript, so it skips the probe.
if [ "$PANE_MODE" = "0" ]; then
if ! perl -e 'alarm 2; exec @ARGV' /usr/bin/osascript -e 'tell application "Terminal" to get name' >/dev/null 2>&1; then
  ac_log "warn automation-probe-failed-or-timed-out"
fi
fi

# Walk up the process tree until we find an ancestor with a controlling TTY.
# tty(1) returns "not a tty" inside Claude Code's Bash tool subprocess; the parent
# `claude` CLI process inherits the TTY from Terminal. First-hop usually hits.
ORIG_TTY=""
CHECK_PID="$PPID"
for _hop in 1 2 3 4 5; do
  [ -z "$CHECK_PID" ] && break
  if [ "$CHECK_PID" = "0" ] || [ "$CHECK_PID" = "1" ]; then break; fi
  RAW_TTY=$(ps -o tty= -p "$CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  case "$RAW_TTY" in
    ttys[0-9]*) ORIG_TTY="/dev/$RAW_TTY"; break ;;
  esac
  CHECK_PID=$(ps -o ppid= -p "$CHECK_PID" 2>/dev/null | tr -d '[:space:]')
done

# Anchored validation of the resolved TTY (defense-in-depth — sed-injected metacharacters
# from a malicious PPID-process command line would be rejected here).
if [ -n "$ORIG_TTY" ] && ! ac_validate_tty "$ORIG_TTY"; then
  ORIG_TTY=""
fi

# Pane mode addresses the panel by id, so a missing tty is not fatal there (target_tty is
# recorded as "" in that case).
if [ -z "$ORIG_TTY" ] && [ "$PANE_MODE" = "0" ]; then
  echo "NOT armed — could not resolve controlling tty in ancestry; run /compact manually"
  exit 0
fi

SID=$(ac_resolve_session_id)
if [ -z "$SID" ]; then
  echo "NOT armed — could not resolve session id; run /compact manually"
  exit 0
fi

CWD_CANON=$(ac_canonicalize_path "$PWD") || CWD_CANON="$PWD"

# 4th argument: marker_nonce — generated by /pre-compact Step 6D and passed here.
# If unset (legacy invocation), arm-auto-compact generates a fallback nonce.
MARKER_NONCE="${2:-}"
if [ -z "$MARKER_NONCE" ]; then
  MARKER_NONCE=$(uuidgen 2>/dev/null | tr -d '\n' | tr 'A-F' 'a-f')
  if [ -z "$MARKER_NONCE" ]; then
    MARKER_NONCE=$(od -vAn -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  fi
  if [ -z "$MARKER_NONCE" ]; then
    MARKER_NONCE=$(openssl rand -hex 16 2>/dev/null)
  fi
  if [ -z "$MARKER_NONCE" ]; then
    ac_log "FATAL nonce-generation-failed at arm-auto-compact"
    echo "NOT armed — nonce generation failed (uuidgen/od/openssl all unavailable)"
    exit 1
  fi
fi
# Also normalize externally-passed nonces to lowercase for canonical comparison
MARKER_NONCE=$(printf '%s' "$MARKER_NONCE" | tr 'A-F' 'a-f')

if [ "$PANE_MODE" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    ac_log "dry-run sid=$SID delivery=pane panel=$PANE_PANEL_ID tty=${ORIG_TTY:-none} cwd=$CWD_CANON nonce=${MARKER_NONCE:0:8}"
    echo "DRY-RUN — would arm (pane panel $PANE_PANEL_ID via $PANE_RUNPANE, sid=$SID tty=${ORIG_TTY:-none} cwd=$CWD_CANON nonce_prefix=${MARKER_NONCE:0:8}); no sentinel written"
    exit 0
  fi
  if ac_write_sentinel_pane "$SID" "$ORIG_TTY" "$CWD_CANON" "$MARKER_NONCE" "$PANE_PANEL_ID" "$PANE_RUNPANE" "$PANE_DIR"; then
    ac_log "armed sid=$SID delivery=pane panel=$PANE_PANEL_ID tty=${ORIG_TTY:-none} cwd=$CWD_CANON nonce=${MARKER_NONCE:0:8}..."
    handoff_log "sentinel_armed sid=$(ac_compute_sid8 "$SID") delivery=pane panel=$PANE_PANEL_ID cwd=$CWD_CANON"
    echo "armed (pane panel ${PANE_PANEL_ID}, sentinel auto-compact-${SID}.json, nonce_prefix=${MARKER_NONCE:0:8})"
  else
    ac_log "arm-failed sid=$SID delivery=pane panel=$PANE_PANEL_ID"
    echo "NOT armed — sentinel write failed (disk full or permission?); run /compact manually"
  fi
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  ac_log "dry-run sid=$SID tty=$ORIG_TTY cwd=$CWD_CANON nonce=${MARKER_NONCE:0:8}"
  echo "DRY-RUN — would arm (sid=$SID target=$ORIG_TTY cwd=$CWD_CANON nonce_prefix=${MARKER_NONCE:0:8}); no sentinel written"
  exit 0
fi

if ac_write_sentinel "$SID" "$ORIG_TTY" "$CWD_CANON" "$MARKER_NONCE"; then
  ac_log "armed sid=$SID tty=$ORIG_TTY cwd=$CWD_CANON nonce=${MARKER_NONCE:0:8}..."
  handoff_log "sentinel_armed sid=$(ac_compute_sid8 "$SID") tty=$ORIG_TTY cwd=$CWD_CANON"
  echo "armed (sentinel auto-compact-${SID}.json, target ${ORIG_TTY}, nonce_prefix=${MARKER_NONCE:0:8})"
else
  ac_log "arm-failed sid=$SID tty=$ORIG_TTY"
  # Intentional design: this script falls through to implicit exit 0 even on sentinel
  # write failure. The user-visible "NOT armed —" message + ac_log entry are the
  # diagnostic signal; non-zero exit would break /pre-compact's stdout capture at Step 9.0.
  echo "NOT armed — sentinel write failed (disk full or permission?); run /compact manually"
fi
