#!/usr/bin/env bash
# post-compact-primer.sh — SessionStart hook (matcher: "compact|resume|startup|clear"):
# Source-routing primer for all session-start sources.
#
# Decision E: fires for compact (post-compact nav), resume/startup/clear (pending-handoff
# detection or session-start nav). Removes the hard-gate to compact-only.
#
# Execution context: this is a Claude Code SessionStart hook script.
# It runs as a direct subprocess of Claude Code, NOT through the orchestrator Bash tool.
#
# Fail-open on any error (exits 0, no output) so a buggy hook never breaks session start.

set -uo pipefail

[ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0  # kill-switch

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ctx-gate-config.sh
. "$ROOT/lib/ctx-gate-config.sh"
# shellcheck source=lib/handoff-config.sh
. "$ROOT/lib/handoff-config.sh"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"
# shellcheck source=lib/handoff-marker.sh
. "$ROOT/lib/handoff-marker.sh"
# shellcheck source=lib/post-compact-primer-helpers.sh
. "$ROOT/lib/post-compact-primer-helpers.sh"
# R4 H10 (Phase 3 task 3.6): explicit source of handoff-resolve.sh after primer-helpers.
# primer-helpers already sources it (and primer_resolve_handoff_path is a thin wrapper),
# but explicit sourcing here defends against load-order surprises if the lib changes.
# shellcheck source=lib/handoff-resolve.sh
. "$ROOT/lib/handoff-resolve.sh"

INPUT=$(head -c 1048576)  # bound stdin to 1MB (DoS guard)

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)

# B20: unified handoff audit trail — log session start event.
handoff_log "session_started sid=${SID:-unknown} source=${SOURCE:-unknown}"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$PWD"

# CWD validation (A6): defends against path-traversal via hostile/corrupted SessionStart JSON.
# Reject non-absolute paths, ../ traversal, and non-directories. Owner-mismatch logs but
# proceeds (could fail on docker/NFS/shared mounts where the user UID differs from cwd owner).
if [ "${CWD#/}" = "$CWD" ]; then
  ctx_gate_log "primer skip reason=cwd-not-absolute cwd=$CWD"
  exit 0
fi
if printf '%s' "$CWD" | grep -qE '(^|/)\.\.($|/)'; then
  ctx_gate_log "primer skip reason=cwd-traversal cwd=$CWD"
  exit 0
fi
if [ ! -d "$CWD" ]; then
  ctx_gate_log "primer skip reason=cwd-not-dir cwd=$CWD"
  exit 0
fi
if [ ! -O "$CWD" ]; then
  ctx_gate_log "primer warn reason=cwd-not-owned cwd=$CWD"
  # log + proceed; do not hard-reject
fi

# Canonicalize CWD for symlink-safe comparison with sentinel cwd field.
CWD_CANON=$(ac_canonicalize_path "$CWD") || CWD_CANON="$CWD"

# R3 D6: Sentinel-presence check runs FIRST so SENTINEL_SID8 is set before
# primer_resolve_handoff_path uses it to prefer the SID-tagged handoff file.
# SENTINEL LIFECYCLE:
# - /pre-compact Step 9.0 writes: $HOME/.claude/progress/auto-compact-${SID}.json
# - Stop hook atomically RENAMES it to ${SENTINEL_PATH}.claim.<pid> on consumption.
# - For source=compact: sentinel typically ABSENT at primer time (Stop hook claimed it).
# - For source=resume/startup/clear: unconsumed sentinel means /pre-compact ran but
#   /compact never fired (laptop close, crash, etc.). Hard channel was lost.
primer_find_sentinel_for_cwd "$CWD_CANON"

# Walk up to the git repo root (SessionStart cwd may be a subdirectory of the repo).
# R4 D3: primer_resolve_handoff_path returns:
#   0 — path resolved (HANDOFF_PATH set)
#   1 — no handoff at all (SID unknown, no alias either)
#   2 — SID known but SID-tagged file missing (fail-closed; NEVER fall back to alias)
HANDOFF_PATH=""
primer_resolve_handoff_path "$CWD"
RESOLVE_RC=$?

# R4 D6: log the actually-selected handoff path AFTER primer_resolve_handoff_path completes
# (HANDOFF_PATH is now set; at primer_find_sentinel_for_cwd call time it was still empty).
handoff_log "handoff_detected sid=${SENTINEL_SID8:-unknown} file=${HANDOFF_PATH:-unknown} sentinel_present=${SENTINEL_PRESENT:-false}"

# R4 D3 + R2-PR-7: handle rc=2 before the generic no-handoff check.
if [ "$RESOLVE_RC" -eq 2 ]; then
  ctx_gate_log "primer sid=${SID:-unknown} action=refuse reason=sid-known-no-tagged-file sid8=${SENTINEL_SID8:-unknown}"
  jq -n \
    --arg msg "WARNING: A /pre-compact ran for this session (sid=${SENTINEL_SID8:-unknown}) but the SID-tagged handoff file (CLAUDE.local.${SENTINEL_SID8:-unknown}.md) is missing. Possible causes: (1) file deleted, (2) cwd changed since /pre-compact, (3) another agent moved it. Ask the user before proceeding. Do NOT load the generic alias CLAUDE.local.md -- it may belong to a different parallel-track session." \
    '{"hookSpecificOutput":{"hookEventName":"SessionStart","hookEventVersion":"SessionStart-v1","additionalContext":$msg}}'
  exit 0
fi

if [ -z "$HANDOFF_PATH" ]; then
  ctx_gate_log "primer sid=${SID:-unknown} source=${SOURCE:-unknown} action=skip reason=no-handoff-file"
  exit 0
fi

# Symlink guard — reject symlinks to prevent path-traversal attacks.
if [ -L "$HANDOFF_PATH" ]; then
  ac_log "primer action=skip reason=handoff-is-symlink path=$HANDOFF_PATH"
  ctx_gate_log "primer sid=${SID:-unknown} action=skip reason=handoff-is-symlink"
  exit 0
fi

# Size cap — reject handoffs larger than HANDOFF_MAX_SIZE_BYTES (default 5MB).
# Defense against pathological file growth that could cause memory pressure or OOM.
HANDOFF_SIZE=0
if HANDOFF_SIZE=$(stat -f %z "$HANDOFF_PATH" 2>/dev/null); then
  :
elif HANDOFF_SIZE=$(stat -c %s "$HANDOFF_PATH" 2>/dev/null); then
  :
else
  HANDOFF_SIZE=0
fi
HANDOFF_SIZE=$(printf '%s' "$HANDOFF_SIZE" | tr -d '[:space:]')
[ -z "$HANDOFF_SIZE" ] && HANDOFF_SIZE=0
if [ "$HANDOFF_SIZE" -gt "${HANDOFF_MAX_SIZE_BYTES:-5242880}" ]; then
  ac_log "primer action=skip reason=handoff-oversize size=$HANDOFF_SIZE limit=${HANDOFF_MAX_SIZE_BYTES:-5242880} path=$HANDOFF_PATH"
  ctx_gate_log "primer sid=${SID:-unknown} action=skip reason=handoff-oversize size=$HANDOFF_SIZE"
  exit 0
fi

# Check freshness, mtime, stale state, and legacy detection.
# Sets HANDOFF_MTIME, HANDOFF_AGE, STAT_OK, LEGACY, STALE_WARNING globally.
primer_check_freshness "$HANDOFF_PATH" "${SID:-unknown}"

# END-OF-HANDOFF marker check (Decision D).
# Match both new form (schema=v1 sid=... nonce=...) and legacy form (-- ).
# Uses handoff_marker_check from lib/handoff-marker.sh.
# Sets MARKER_PRESENT ("true"/"false") globally.
# Hook scripts run as subprocess — pipe is fine here (not subject to orchestrator restrictions).
primer_check_marker "$HANDOFF_PATH"

# Compose marker-related warning based on (marker, legacy) combination.
if [ "$MARKER_PRESENT" = "false" ] && [ "$LEGACY" = "true" ]; then
  MARKER_WARNING=$'INFO LEGACY HANDOFF FILE — predates the END-OF-HANDOFF marker convention (file mtime older than deployment cutoff). Proceeding but please verify content makes sense.\n\n'
elif [ "$MARKER_PRESENT" = "false" ]; then
  MARKER_WARNING=$'WARNING HANDOFF FILE APPEARS TRUNCATED — missing END-OF-HANDOFF marker; file is recent enough that the marker should be present. The prior /pre-compact may have crashed mid-write. Verify with the user what was being worked on before assuming.\n\n'
else
  MARKER_WARNING=""
fi

# SENTINEL_PRESENT + SENTINEL_SID8 were already set by primer_find_sentinel_for_cwd above.

# Compose nav directive based on (source, sentinel, marker, freshness, legacy) matrix.
# See plan Architecture Overview "Source-routing decision matrix" for the full table.
case "$SOURCE" in
  compact)
    # Stop hook claimed sentinel; sentinel typically absent for compact source.
    # ANOMALY: if sentinel IS still present here, the Stop hook mv-claim failed silently.
    # Only emitted for compact source — resume/startup/clear can legitimately have a
    # sentinel (indicates /pre-compact ran but /compact never fired).
    if [ "$SENTINEL_PRESENT" = "true" ]; then
      ctx_gate_log "primer sid=${SID:-unknown} source=compact ANOMALY sentinel-still-present-after-compact path=$SENTINEL_PATH"
      ANOMALY_WARNING=$'WARNING ANOMALY: sentinel still present after /compact. Stop hook may have failed to claim it. Check ~/.claude/logs/auto-compact.log if this repeats.\n\n'
    else
      ANOMALY_WARNING=""
    fi
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

jq -n --arg ctx "$MSG" '{ "hookSpecificOutput": { "hookEventName": "SessionStart", "hookEventVersion": "SessionStart-v1", "additionalContext": $ctx } }'
exit 0
