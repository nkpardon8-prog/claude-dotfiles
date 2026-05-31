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
OSA_STDERR_TMP=""

# ---------------------------------------------------------------------------
# SESSION-CORRELATION DELIVERY (bulletproof, 2026-05-31). Bind the destination tab to THIS
# session's OWN `claude` process — NOT the arm-time sentinel tty (unstable across tab churn,
# shared across concurrent sessions → the 04:42Z misfire where 49d80a3a's resume hit sibling
# 24a704c2). This Stop hook is a direct subprocess of its own session's claude, so the
# own-ancestry walk resolves THIS session and can never reach a sibling. Contracts proven by
# scripts/hooks/session-correlation-assumptions/ (6/6 PASS). VERIFY-THEN-CLAIM: do all checks
# BEFORE the atomic claim so an abort leaves the sentinel intact (next-Stop retry +
# pending-handoff primer still recover). Every failure aborts WITHOUT typing — never misfire.
# ---------------------------------------------------------------------------
TARGET_PID=$(ac_resolve_own_claude_pid)
if [ -z "$TARGET_PID" ]; then
  ac_log "abort sid=$REAL_SID reason=own-claude-unresolved"
  exit 0
fi
# Identity tuple {pid, start-time, argv-is-claude} — captured once, re-checked just before firing
# (defeats macOS pid-reuse and a mid-window process swap). The start-time MUST be non-empty: an
# empty lstart means the pid vanished between resolve and stat (a race), so fail closed rather than
# carry an empty identity that any reused pid with an also-empty lstart could later "match".
PID_START=$(ac_pid_starttime "$TARGET_PID")
if [ -z "$PID_START" ]; then
  ac_log "abort sid=$REAL_SID reason=starttime-empty pid=$TARGET_PID"
  exit 0
fi
if ! ac_pid_argv_is_claude "$TARGET_PID"; then
  ac_log "abort sid=$REAL_SID reason=argv-mismatch pid=$TARGET_PID"
  exit 0
fi
TARGET_TTY=$(ac_pid_tty "$TARGET_PID")
if [ -z "$TARGET_TTY" ] || ! ac_validate_tty "$TARGET_TTY"; then
  ac_log "abort sid=$REAL_SID reason=tty-unresolved pid=$TARGET_PID tty=${TARGET_TTY:-none}"
  exit 0
fi
TTY_SHORT="${TARGET_TTY#/dev/}"
# Pid-PINNED foreground-leader check (subsumes the old "any foreground claude" check, which was
# exactly the bug — it accepted a SIBLING session's claude on this tty). Rejects dead / non-claude
# / pivoted-to-vim / sibling-pid. `ps -o args=` (never ucomm — the 2026-05-14 version-string trap).
if ! ac_pid_is_foreground_leader_on_tty "$TARGET_PID" "$TTY_SHORT"; then
  ac_log "abort sid=$REAL_SID reason=not-foreground-leader pid=$TARGET_PID tty=$TARGET_TTY"
  exit 0
fi

# All verification passed → NOW claim (atomic anti-loop guarantee, as late as possible so a
# pre-claim abort never destroys the sentinel). Only one concurrent Stop wins the mv.
CLAIM="${SENTINEL}.claim.$$"
if ! mv "$SENTINEL" "$CLAIM" 2>/dev/null; then
  exit 0
fi
trap 'rm -f "$CLAIM" "${OSA_STDERR_TMP:-}"' EXIT

# TOCTOU narrowing: re-resolve identity + tty immediately before firing. If the tty churned or the
# process changed (sleep/wake, tab close/reopen, pid swap) in the gap, abort AND restore the
# sentinel so the pending-handoff primer + next-Stop retry still recover this session.
TTY2=$(ac_pid_tty "$TARGET_PID")
START2=$(ac_pid_starttime "$TARGET_PID")
if [ "$TTY2" != "$TARGET_TTY" ] || [ "$START2" != "$PID_START" ] \
   || ! ac_pid_is_foreground_leader_on_tty "$TARGET_PID" "$TTY_SHORT"; then
  ac_log "abort sid=$REAL_SID reason=identity-churned-pre-fire pid=$TARGET_PID tty=$TARGET_TTY tty2=${TTY2:-none}"
  mv -f "$CLAIM" "$SENTINEL" 2>/dev/null && trap 'rm -f "${OSA_STDERR_TMP:-}"' EXIT
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
    -- REVERTED 2026-05-31 to bare /compact. A field incident (dentall session fca8c4ab,
    -- 02:07Z) showed that firing /compact WITH a trailing instruction argument shifts the
    -- timing such that the queued /post-compact-resume (typed during compaction, line ~181)
    -- intermittently fails to submit after compaction completes — leaving the session FROZEN
    -- on unsubmitted draft text (27-min idle until the user re-ran it by hand). The
    -- auto-resume queue is the load-bearing overnight-autonomy mechanism and must never be
    -- put at risk for the (nice-to-have) "complementary channels" focus instruction. Bare
    -- /compact has resumed cleanly across every logged run. DO NOT re-add a /compact argument
    -- without first proving — in the live build, repeatedly — that the queued resume still
    -- auto-submits after it. See CHANGELOG 2026-05-31.
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

# RESTORE-ON-FIRE-FAILURE (2026-05-31, codex-review C2): the sentinel was already CLAIMED above.
# If /compact did NOT actually fire — osascript said not-running / no-windows / no-matching-tab, or
# errored / returned empty (e.g. a bad CTX_GATE_PTY_DELAY_SEC, or the target tab closed in the final
# window) — then letting the EXIT trap delete the claim would CONSUME the sentinel without compacting,
# silently breaking the next-Stop retry AND the pending-handoff primer recovery. So restore it.
# A result that STARTS WITH "fired" means the first `do script "/compact"` succeeded (even
# "fired+queue-failed" — /compact ran; the typed resume is just a backstop and the self-driven primer
# covers it), so we do NOT restore in that case.
case "${OSA_RESULT:-}" in
  fired*) : ;;   # /compact fired — sentinel correctly consumed
  *)
    if mv -f "$CLAIM" "$SENTINEL" 2>/dev/null; then
      trap 'rm -f "${OSA_STDERR_TMP:-}"' EXIT
      ac_log "restore sid=$REAL_SID tty=$TARGET_TTY reason=compact-not-fired result=${OSA_RESULT:-empty} (sentinel restored → next-Stop retry)"
    else
      ac_log "restore-FAILED sid=$REAL_SID tty=$TARGET_TTY result=${OSA_RESULT:-empty} (claim could not be moved back; pending-handoff primer is the remaining recovery)"
    fi
    ;;
esac

# R8 V2-4: breadcrumb-write block DELETED. Identity now comes from the command arg
# (/post-compact-resume <session_id>), so the breadcrumb (which existed solely for
# SID recovery in the reader) is no longer needed. No breadcrumbs written.

exit 0
