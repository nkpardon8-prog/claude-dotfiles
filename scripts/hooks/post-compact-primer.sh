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
# Chain primitives (overnight-autonomy): provides chain_manifest_read for the chain banner.
# shellcheck source=lib/handoff-chain.sh
. "$ROOT/lib/handoff-chain.sh"
# Mission-bridge primitives (PIVOT A): provides _file_size, handoff_canonical_root, mission helpers.
# Only used here to surface the PRECOMPUTED MISSION.<sid>.banner (near-zero work — never reads the
# 5MB main file). Sourced last so its source-guards/helpers override cleanly if order changes.
# shellcheck source=lib/mission-bridge.sh
. "$ROOT/lib/mission-bridge.sh"

INPUT=$(head -c 1048576)  # bound stdin to 1MB (DoS guard)

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)

# R8: expose the full session_id (SID) as PRIMER_SESSION_ID for primer_resolve_handoff_path.
# The resolver now uses the full UUID, not the truncated SENTINEL_SID8.
PRIMER_SESSION_ID="${SID:-}"
export PRIMER_SESSION_ID

# B20: unified handoff audit trail — log session start event.
handoff_log "session_started sid=${SID:-unknown} source=${SOURCE:-unknown}"

# Stale-broker guard (2026-05-28): the ctx broker sidecar ~/.claude/progress/ctx-<sid>.txt is
# written by the statusline from the harness context-used %, and the writer PRESERVES last-known-good
# when the harness value is briefly empty (so transient render glitches don't dark the gate). /compact
# preserves the session_id, so post-compaction the same-named sidecar still holds the PRE-compaction
# value until the statusline's next render. The first post-compact UserPromptSubmit reads that stale-high
# value DETERMINISTICALLY and fires a false IMPORTANT/FORCE nudge → premature /pre-compact with most of
# the budget free. Invalidate the sidecar here so the reader fails open (silent) until a fresh value is
# written. Only compact|clear — the two sources where context drops sharply while the sidecar persists;
# resume/startup keep their sidecar (it reflects real current context, or the SID is new so no stale file).
# Placed BEFORE the chain-banner and CWD-validation early-exits (lines 50+/115+) so invalidation is
# unconditional. Staleness here is SEMANTIC not temporal — a fast compact yields a young-but-stale
# sidecar an mtime check would miss — so deletion (age-independent) is the correct mechanism, not mtime.
if [ -n "${SID:-}" ]; then
  case "${SOURCE:-}" in
    compact|clear)
      rm -f "$HOME/.claude/progress/ctx-${SID}.txt" 2>/dev/null || true
      handoff_log "ctx_broker_invalidated sid=${SID} source=${SOURCE}"
      ;;
  esac
fi

# Chain banner (overnight-autonomy): prepend the chain's situation to every additionalContext
# emission so the agent reads "Chain X | Link N | Elapsed Hh Mm | Goal: … | Status: …" first.
# Manifest absence = empty banner, fall through silently (every fresh session starts here).
# Robustness rules: bash-side date fallback if jq lacks fromdateiso8601 (< 1.5); clamp negative
# elapsed at 0 (clock skew); sanitize HEARTBEAT_AGE to integer; heartbeat staleness threshold
# raised to 90 min (a productive overnight cycle is normally well under that).
CHAIN_BANNER=""
BANNER_PREFIX=""
MISSION_PREFIX=""  # PIVOT A: precomputed-mission banner; folded into BANNER_PREFIX + emitted on bare exits.
if [ -n "${SID:-}" ] && MANIFEST_JSON=$(chain_manifest_read "$SID" 2>/dev/null); then
  # Elapsed math is done via bash `date` (BSD-then-GNU fallback) below — universally portable —
  # so no jq date-function probe is needed. The earlier draft had a `HAVE_JQ_DATE` check; dropped.
  CID=$(printf '%s' "$MANIFEST_JSON"      | jq -r '.chain_id // empty')
  SEQ_=$(printf '%s' "$MANIFEST_JSON"     | jq -r '.current_seq // 1')
  STATUS_=$(printf '%s' "$MANIFEST_JSON"  | jq -r '.status // "active"')
  GOAL_=$(printf '%s' "$MANIFEST_JSON"    | jq -r '(.north_star // "") | .[0:80]')
  STARTED=$(printf '%s' "$MANIFEST_JSON"  | jq -r '.started_at // empty')
  HBT=$(printf '%s' "$MANIFEST_JSON"      | jq -r '.last_heartbeat_at // empty')
  RECOVERED=$(printf '%s' "$MANIFEST_JSON" | jq -r '.recovered_from_ledger // false')

  # Compute elapsed via bash date arithmetic (more portable than relying on jq's fromdateiso8601).
  EPOCH_START=0
  if [ -n "$STARTED" ]; then
    EPOCH_START=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$STARTED" +%s 2>/dev/null \
                || date -u -d "$STARTED" +%s 2>/dev/null || echo 0)
  fi
  S=$(( $(date +%s) - EPOCH_START ))
  [ "$S" -lt 0 ] && S=0
  if [ "$S" -ge 86400 ]; then
    ELAPSED="$((S/86400))d $(((S%86400)/3600))h $(((S%3600)/60))m"
  else
    ELAPSED="$((S/3600))h $(((S%3600)/60))m"
  fi
  CID8=$(printf '%s' "$CID" | cut -c1-8)
  CHAIN_BANNER="Chain ${CID8} | Link ${SEQ_} | Elapsed ${ELAPSED} | Goal: ${GOAL_} | Status: ${STATUS_}"
  if [ "$RECOVERED" = "true" ]; then
    CHAIN_BANNER="${CHAIN_BANNER} (manifest was recovered from ledger — re-state goal if it is wrong)"
  fi

  # Heartbeat staleness — 90 min threshold (down from the brief's original 30 to reduce
  # false advisories on productive overnight runs).
  HEARTBEAT_AGE=0
  if [ -n "$HBT" ]; then
    EPOCH_HBT=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$HBT" +%s 2>/dev/null \
              || date -u -d "$HBT" +%s 2>/dev/null || echo 0)
    HEARTBEAT_AGE=$(( $(date +%s) - EPOCH_HBT ))
  fi
  # Sanitize to plain integer.
  HEARTBEAT_AGE=$(printf '%d' "${HEARTBEAT_AGE:-0}" 2>/dev/null); HEARTBEAT_AGE=${HEARTBEAT_AGE:-0}
  [ "$HEARTBEAT_AGE" -lt 0 ] && HEARTBEAT_AGE=0
  if [ "$HEARTBEAT_AGE" -gt 5400 ]; then  # 90 min
    CHAIN_BANNER="${CHAIN_BANNER}
NOTE: $((HEARTBEAT_AGE/60))-minute gap since last /pre-compact — verify a resume wasn't missed."
  fi
  BANNER_PREFIX="${CHAIN_BANNER}

"
  unset CID SEQ_ STATUS_ GOAL_ STARTED HBT EPOCH_START EPOCH_HBT S RECOVERED CID8
fi

# PIVOT A — surface the PRECOMPUTED mission banner (#1/#11/#33). Near-zero work: we ONLY `cat` the
# small, pre-bounded MISSION.<sid>.banner (size-guarded ≤64KB) — NEVER the 5MB main file. Reuses the
# MANIFEST_JSON already read above (no 2nd manifest read — #33). Computed HERE, before all the bare
# `exit 0` paths below, so MISSION_PREFIX is in scope at every exit. The chain-manifest if-block may
# have been skipped entirely (no manifest) — MISSION_PREFIX was initialized to "" above, so the
# recovery probe still runs. CWD_CANON is not set yet (assigned later); the probe falls back to
# handoff_canonical_root with no arg (defaults to $PWD), which is the right canonical root anyway.
MP=$(printf '%s' "${MANIFEST_JSON:-}" | jq -r '.mission_path // empty' 2>/dev/null)
if [ -z "$MP" ] && [ -n "${SID:-}" ]; then
  MP="$(handoff_canonical_root "${CWD_CANON:-}" 2>/dev/null)/MISSION.${SID}.md"
fi
if [ -n "$MP" ] && [ -f "${MP%.md}.banner" ] && [ "$(_file_size "${MP%.md}.banner" 2>/dev/null)" -le 65536 ] 2>/dev/null; then
  # Banner content + a trailing newline. Injection-safety framing is ALREADY baked in by the writer.
  MISSION_PREFIX="$(cat "${MP%.md}.banner" 2>/dev/null)
"
elif [ -n "$MP" ] && [ -f "$MP" ]; then
  # Main mission file exists but the banner is gone → loud (#11). Never reads the main file.
  MISSION_PREFIX="CRITICAL: mission $MP exists but its banner is missing — run /pre-compact; do NOT proceed as if no mission.
"
elif printf '%s' "${MANIFEST_JSON:-}" | jq -e '.mission_path // empty' >/dev/null 2>&1; then
  # Manifest recorded a mission_path but the file is gone → loud (#11).
  MISSION_PREFIX="CRITICAL: mission expected (recorded in chain manifest) but FILE MISSING — inspect .mission-backups/; re-create via /mission.
"
fi
# Fold into BANNER_PREFIX so all existing ${BANNER_PREFIX} jq emitters (rc=2/rc=3/normal tail) pick it
# up automatically (#13). MISSION_PREFIX leads so the standing directive is read first.
BANNER_PREFIX="${MISSION_PREFIX}${BANNER_PREFIX}"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$PWD"

# CWD validation (A6): defends against path-traversal via hostile/corrupted SessionStart JSON.
# Reject non-absolute paths, ../ traversal, and non-directories. Owner-mismatch logs but
# proceeds (could fail on docker/NFS/shared mounts where the user UID differs from cwd owner).
if [ "${CWD#/}" = "$CWD" ]; then
  ctx_gate_log "primer skip reason=cwd-not-absolute cwd=$CWD"
  [ -n "${MISSION_PREFIX:-}" ] && jq -n --arg c "$MISSION_PREFIX" '{hookSpecificOutput:{hookEventName:"SessionStart",hookEventVersion:"SessionStart-v1",additionalContext:$c}}'
  exit 0
fi
if printf '%s' "$CWD" | grep -qE '(^|/)\.\.($|/)'; then
  ctx_gate_log "primer skip reason=cwd-traversal cwd=$CWD"
  [ -n "${MISSION_PREFIX:-}" ] && jq -n --arg c "$MISSION_PREFIX" '{hookSpecificOutput:{hookEventName:"SessionStart",hookEventVersion:"SessionStart-v1",additionalContext:$c}}'
  exit 0
fi
if [ ! -d "$CWD" ]; then
  ctx_gate_log "primer skip reason=cwd-not-dir cwd=$CWD"
  [ -n "${MISSION_PREFIX:-}" ] && jq -n --arg c "$MISSION_PREFIX" '{hookSpecificOutput:{hookEventName:"SessionStart",hookEventVersion:"SessionStart-v1",additionalContext:$c}}'
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
# Phase 2 (Round 4): pass $SID so primer_find_sentinel_for_cwd can bind to the
# exact sentinel for this session, preventing Track A from adopting Track B's sentinel.
primer_find_sentinel_for_cwd "$CWD_CANON" "$SID"

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
# V2-15 (R8): log full session_id instead of truncated SENTINEL_SID8.
handoff_log "handoff_detected sid=${SID:-unknown} file=${HANDOFF_PATH:-unknown} sentinel_present=${SENTINEL_PRESENT:-false}"

# R4 D3 + R2-PR-7: handle rc=2 before the generic no-handoff check.
if [ "$RESOLVE_RC" -eq 2 ]; then
  # R8: only emit the SID-tagged-file-missing warning if a sentinel was FOUND for this session
  # (i.e., we KNOW /pre-compact ran here). Without a sentinel, this is an ordinary session start
  # with no handoff — treat as rc=1 (silent exit). Emitting a warning when no sentinel exists
  # would be spurious noise on every session start that has no handoff.
  if [ "${SENTINEL_PRESENT:-false}" = "true" ]; then
    ctx_gate_log "primer sid=${SID:-unknown} action=refuse reason=sid-known-no-tagged-file sid=${SID:-unknown}"
    ctx_gate_log "primer warn reason=sentinel-without-sid-file sid=${SID:-unknown}"
    jq -n \
      --arg msg "${BANNER_PREFIX}WARNING: A /pre-compact ran for this session (sid=${SID:-unknown}) but the SID-tagged handoff file (CLAUDE.local.${SID:-unknown}.md) is missing. Possible causes: (1) file deleted, (2) cwd changed since /pre-compact, (3) another agent moved it. Ask the user before proceeding. If auto-resume did not fire, run: /post-compact-resume ${SID:-<session_id>}" \
      '{"hookSpecificOutput":{"hookEventName":"SessionStart","hookEventVersion":"SessionStart-v1","additionalContext":$msg}}'
  else
    ctx_gate_log "primer sid=${SID:-unknown} action=skip reason=no-handoff-file-for-sid"
  fi
  exit 0
fi

# R5 Critical #8: handle rc=3 (SID-tagged file exists but has hardlink count > 1).
# _primer_check_linkcount in handoff-resolve.sh returns rc=3 when hardlink guard triggers.
# Without this branch, rc=3 falls through to the generic no-handoff path (HANDOFF_PATH=""),
# silently swallowing the security signal. Now emit an explicit actionable warning.
if [ "$RESOLVE_RC" -eq 3 ]; then
  ctx_gate_log "primer sid=${SID:-unknown} action=refuse reason=sid-known-hardlinked sid=${SID:-unknown}"
  ctx_gate_log "primer warn reason=sid-known-hardlinked sid=${SID:-unknown}"
  jq -n \
    --arg msg "${BANNER_PREFIX}WARNING: The SID-tagged handoff file (CLAUDE.local.${SID:-unknown}.md) has a hardlink count > 1 (potential filesystem manipulation). Refusing to load. To fix: copy the file to a new path (cp CLAUDE.local.${SID:-unknown}.md CLAUDE.local.${SID:-unknown}.md.new && mv CLAUDE.local.${SID:-unknown}.md.new CLAUDE.local.${SID:-unknown}.md) then re-run: /post-compact-resume ${SID:-<session_id>}" \
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
# RQ-07 (R6 HZ-34/INV-3): handle MARKER_PRESENT="tampered" (multi-marker detected at primer layer).
if [ "$MARKER_PRESENT" = "tampered" ]; then
  MARKER_WARNING=$'WARNING HANDOFF FILE TAMPERED — multiple END-OF-HANDOFF markers detected. This indicates possible filesystem manipulation or a double-write bug. Do NOT run /post-compact-resume automatically; investigate the file first. step2.sh will emit STATE=multi-marker-detected and refuse ingestion.\n\n'
elif [ "$MARKER_PRESENT" = "false" ] && [ "$LEGACY" = "true" ]; then
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
    # R8: advisory prints the exact /post-compact-resume command including session_id.
    MSG="${ANOMALY_WARNING}${MARKER_WARNING}${STALE_WARNING}POST-COMPACT SESSION. A /pre-compact handoff is at ${HANDOFF_PATH}. /post-compact-resume should auto-fire from the Stop-hook queue. If it did not fire, run: /post-compact-resume ${SID:-<session_id>}"
    ;;
  resume|startup|clear)
    if [ "$SENTINEL_PRESENT" = "true" ]; then
      # Sentinel exists = /pre-compact ran but /compact did not fire (hard channel lost).
      MSG="${MARKER_WARNING}${STALE_WARNING}RESUMED SESSION with PENDING HANDOFF. A /pre-compact ran but /compact did not fire (laptop close, crash, or terminal exit). Handoff at ${HANDOFF_PATH}. Your FIRST action: run /post-compact-resume ${SID:-<session_id>}"
    else
      # No sentinel; handoff file may be from any prior session.
      MSG="${MARKER_WARNING}${STALE_WARNING}SESSION START with existing handoff at ${HANDOFF_PATH}. If this is the continuation of prior work, run /post-compact-resume ${SID:-<session_id>}. If it is unrelated, ignore."
    fi
    ;;
  *)
    # Unknown source — emit minimal nav. With E2 regex matcher, only compact|resume|startup|clear
    # should ever reach here. Defensive fallback for any future Claude Code source types.
    MSG="${MARKER_WARNING}${STALE_WARNING}Handoff at ${HANDOFF_PATH}. If resuming prior work, run /post-compact-resume ${SID:-<session_id>}."
    ;;
esac

STALE_FLAG="no"
if [ -n "$STALE_WARNING" ]; then STALE_FLAG="yes"; fi
# RQ-07 (R6): MARKER_PRESENT can be "true", "false", or "tampered" (new in R6 for multi-marker).
ctx_gate_log "primer sid=${SID:-unknown} source=${SOURCE:-unknown} sentinel=$SENTINEL_PRESENT marker=$MARKER_PRESENT legacy=$LEGACY age=${HANDOFF_AGE}s stale=$STALE_FLAG"

jq -n --arg ctx "${BANNER_PREFIX}${MSG}" '{ "hookSpecificOutput": { "hookEventName": "SessionStart", "hookEventVersion": "SessionStart-v1", "additionalContext": $ctx } }'
exit 0
