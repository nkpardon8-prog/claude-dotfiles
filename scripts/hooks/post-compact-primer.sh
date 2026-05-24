#!/usr/bin/env bash
# post-compact-primer.sh — SessionStart hook (matcher: "compact|resume|startup|clear"):
# Source-routing primer for all session-start sources.
#
# Decision E: fires for compact (post-compact nav), resume/startup/clear (pending-handoff
# detection or session-start nav). Removes the hard-gate to compact-only.
#
# Fail-open on any error (exits 0, no output) so a buggy hook never breaks session start.

set -uo pipefail

[ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0  # kill-switch per Round 3 A #12 / B #7

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ctx-gate-config.sh
. "$ROOT/lib/ctx-gate-config.sh"
# shellcheck source=lib/handoff-config.sh
. "$ROOT/lib/handoff-config.sh"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

INPUT=$(head -c 1048576)  # bound stdin to 1MB (per codex-review R2 F16: DoS guard)

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$PWD"

# Walk up to the git repo root (SessionStart cwd may be a subdirectory of the repo).
# Look at cwd first, fall back to repo root.
HANDOFF_PATH=""
if [ -f "$CWD/CLAUDE.local.md" ]; then
  HANDOFF_PATH="$CWD/CLAUDE.local.md"
else
  REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || printf '')
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/CLAUDE.local.md" ]; then
    HANDOFF_PATH="$REPO_ROOT/CLAUDE.local.md"
  fi
fi

if [ -z "$HANDOFF_PATH" ]; then
  ctx_gate_log "primer sid=${SID:-unknown} source=${SOURCE:-unknown} action=skip reason=no-handoff-file"
  exit 0
fi

# Read mtime ONCE (used by both freshness checks). R2 #4 fix: strip whitespace from
# stat output (bash 3.2 arithmetic fails on whitespace from `stat` on some systems).
HANDOFF_MTIME=$(stat -f %m "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]' || stat -c %Y "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]' || printf 0)
[ -z "$HANDOFF_MTIME" ] && HANDOFF_MTIME=0
NOW=$(date +%s)
HANDOFF_AGE=$((NOW - HANDOFF_MTIME))

# R2 #4 fix: if stat failed (HANDOFF_MTIME=0), HANDOFF_AGE is a ~57-year false positive
# (current epoch minus zero). Guard: treat stat-failure as "freshness unknown" rather
# than "ancient." Skip stale check, log the failure, proceed with marker check only.
STAT_OK="true"
if [ "$HANDOFF_MTIME" -eq 0 ]; then
  STAT_OK="false"
  HANDOFF_AGE=0  # neutralize for downstream comparisons
  ctx_gate_log "primer sid=${SID:-unknown} action=stat-failed-mtime-zero stale-check-skipped"
fi

# Legacy-file detection — backwards-compat for existing CLAUDE.local.md files
# written before the END-OF-HANDOFF marker convention.
# Cutoff epoch from lib/handoff-config.sh: 3+ days before first deploy, so
# same-day-old files are NOT treated as legacy.
LEGACY="false"
if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_MTIME" -lt "$HANDOFF_LEGACY_CUTOFF_EPOCH" ]; then
  LEGACY="true"
fi

# END-OF-HANDOFF marker check (Decision D).
# R4 #B1 clarification: `tail | grep` pipe is CORRECT here. This is post-compact-primer.sh
# running as a standalone shell script under the SessionStart hook (subprocess invocation),
# NOT a Bash tool call by the orchestrator. The ctx-gate compound-command deny-class only
# applies to orchestrator Bash-tool calls (gated via PreToolUse hook). Hook scripts running
# their own bash are not gated. Do NOT "fix" this pipe — it works as-is.
MARKER='<!-- END-OF-HANDOFF -->'
MARKER_PRESENT="true"
if ! tail -c 512 "$HANDOFF_PATH" 2>/dev/null | grep -qF "$MARKER"; then
  MARKER_PRESENT="false"
fi

# Compose marker-related warning based on (marker, legacy) combination.
if [ "$MARKER_PRESENT" = "false" ] && [ "$LEGACY" = "true" ]; then
  MARKER_WARNING=$'INFO LEGACY HANDOFF FILE — predates the END-OF-HANDOFF marker convention (file mtime older than deployment cutoff). Proceeding but please verify content makes sense.\n\n'
elif [ "$MARKER_PRESENT" = "false" ]; then
  MARKER_WARNING=$'WARNING HANDOFF FILE APPEARS TRUNCATED — missing END-OF-HANDOFF marker; file is recent enough that the marker should be present. The prior /pre-compact may have crashed mid-write. Verify with the user what was being worked on before assuming.\n\n'
else
  MARKER_WARNING=""
fi

# Stale-handoff detection (Decision F + R1 #6 — uses lib constant, default 24h).
# R2 #4 / #11 fix: always assign STALE_WARNING in both branches (prevents `set -u` abort).
# R2 #4: skip stale check if STAT_OK=false (HANDOFF_MTIME unreliable).
# R3 #B12: compute HANDOFF_AGE_HUMAN INSIDE the stale-branch (not at top scope).
STALE_WARNING=""
if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_AGE" -gt "${CTX_STALE_HANDOFF_SECS}" ]; then
  HANDOFF_AGE_HUMAN=$((HANDOFF_AGE / 3600))
  STALE_WARNING="WARNING STALE HANDOFF — predates this session by ~${HANDOFF_AGE_HUMAN}h; it may be from a prior conversation. Verify with the user before resuming."$'\n\n'
fi

# Sentinel-presence check (Decision E — resume-path coverage).
# R2 CRITICAL fix: new session SID differs from sentinel SID for resume/startup/clear.
# Use GLOB scan + cwd-disambiguation via ac_read_sentinel_cwd (added in Task 1.1a).
#
# SENTINEL LIFECYCLE:
# - /pre-compact Step 9.0 writes: $HOME/.claude/progress/auto-compact-${SID}.json
# - Stop hook atomically RENAMES it to ${SENTINEL_PATH}.claim.<pid> on consumption.
# - For source=compact: sentinel typically ABSENT at primer time (Stop hook claimed it).
# - For source=resume/startup/clear: unconsumed sentinel means /pre-compact ran but
#   /compact never fired (laptop close, crash, etc.). Hard channel was lost.

SENTINEL_PRESENT="false"
SENTINEL_PATH=""
for sentinel_candidate in "$HOME/.claude/progress/auto-compact-"*.json; do
  # Glob with no match expands to literal pattern; the -f test catches this.
  [ -f "$sentinel_candidate" ] || continue
  # Use schema-validating lib reader: symlink rejection, size cap, schema_version check.
  # R3 #5 fix: legacy sentinels (schema_version=1, no cwd field) → skip via continue.
  SENT_CWD=$(ac_read_sentinel_cwd "$sentinel_candidate" 2>/dev/null)
  if [ -z "$SENT_CWD" ]; then
    ctx_gate_log "primer action=skip-legacy-sentinel path=$sentinel_candidate reason=no-cwd-field-or-invalid-schema"
    continue
  fi
  if [ "$SENT_CWD" = "$CWD" ]; then
    SENTINEL_PRESENT="true"
    SENTINEL_PATH="$sentinel_candidate"
    break
  fi
  # Different cwd — this sentinel is for another workspace; skip
done

# Compose nav directive based on (source, sentinel, marker, freshness, legacy) matrix.
# See plan Architecture Overview "Source-routing decision matrix" for the full table.
case "$SOURCE" in
  compact)
    # Stop hook claimed sentinel; sentinel typically absent.
    # R2 #10 ANOMALY: if sentinel IS present, the Stop hook mv-claim failed silently.
    if [ "$SENTINEL_PRESENT" = "true" ]; then
      ctx_gate_log "primer sid=${SID:-unknown} source=compact ANOMALY sentinel-still-present-after-compact path=$SENTINEL_PATH"
      ANOMALY_WARNING=$'WARNING ANOMALY: sentinel still present after /compact. Stop hook may have failed to claim it. Check ~/.claude/logs/auto-compact.log if this repeats.\n\n'
    else
      ANOMALY_WARNING=""
    fi
    # R3 #B6 fix: use $'\n\n' between concatenated warnings for separate paragraphs.
    MSG="${ANOMALY_WARNING}${MARKER_WARNING}${STALE_WARNING}POST-COMPACT SESSION. A /pre-compact handoff is at ${HANDOFF_PATH}. /post-compact-resume should auto-fire from the Stop-hook queue. If it did not fire, run /post-compact-resume now."
    ;;
  resume|startup|clear)
    if [ "$SENTINEL_PRESENT" = "true" ]; then
      # Sentinel exists = /pre-compact ran but /compact did not fire (hard channel lost).
      MSG="${MARKER_WARNING}${STALE_WARNING}RESUMED SESSION with PENDING HANDOFF. A /pre-compact ran but /compact did not fire (laptop close, crash, or terminal exit). Handoff at ${HANDOFF_PATH}. Your FIRST action: run /post-compact-resume to navigate the handoff."
    else
      # No sentinel; handoff file may be from any prior session.
      MSG="${MARKER_WARNING}${STALE_WARNING}SESSION START with existing handoff at ${HANDOFF_PATH}. If this is the continuation of prior work, run /post-compact-resume. If it is unrelated, ignore."
    fi
    ;;
  *)
    # Unknown source — emit minimal nav. With E2 regex matcher, only compact|resume|startup|clear
    # should ever reach here. Defensive fallback for any future Claude Code source types.
    MSG="${MARKER_WARNING}${STALE_WARNING}Handoff at ${HANDOFF_PATH}. If resuming prior work, run /post-compact-resume."
    ;;
esac

STALE_FLAG="no"
if [ -n "$STALE_WARNING" ]; then STALE_FLAG="yes"; fi
ctx_gate_log "primer sid=${SID:-unknown} source=${SOURCE:-unknown} sentinel=$SENTINEL_PRESENT marker=$MARKER_PRESENT legacy=$LEGACY age=${HANDOFF_AGE}s stale=$STALE_FLAG"

jq -n --arg ctx "$MSG" '{ "hookSpecificOutput": { "hookEventName": "SessionStart", "additionalContext": $ctx } }'
exit 0
