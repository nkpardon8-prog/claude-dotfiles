#!/usr/bin/env bash
# post-compact-primer-helpers.sh — helper functions for post-compact-primer.sh.
# Extracted to keep the primer body lean (orchestration + source-routing only).
#
# Execution context: sourced by post-compact-primer.sh, which runs as a direct
# subprocess of Claude Code (SessionStart hook). Not subject to orchestrator
# Bash tool restrictions.
#
# Source-guard: second sourcing is a no-op.
[ -n "${_POST_COMPACT_PRIMER_HELPERS_LOADED:-}" ] && return 0
readonly _POST_COMPACT_PRIMER_HELPERS_LOADED=1

# R4 H10 (Phase 3 task 3.5): source canonical handoff resolver.
# _primer_check_linkcount is defined there (R2-PR-6 BLOCKER fix — removes cross-lib scope hazard).
# primer_resolve_handoff_path below is now a thin wrapper around handoff_resolve_path.
. "$(dirname "${BASH_SOURCE[0]}")/handoff-resolve.sh" 2>/dev/null || true

# Dependencies sourced by the caller (post-compact-primer.sh) before sourcing this lib:
#   lib/ctx-gate-config.sh  — ctx_gate_log
#   lib/auto-compact-sentinel.sh — ac_log, ac_canonicalize_path, ac_read_sentinel_cwd
#   lib/handoff-config.sh   — HANDOFF_STALE_SECS, HANDOFF_LEGACY_CUTOFF_EPOCH, HANDOFF_MAX_SIZE_BYTES
#   lib/handoff-marker.sh   — handoff_marker_check
#   lib/handoff-resolve.sh  — handoff_resolve_path, _primer_check_linkcount (sourced above)

# ---------------------------------------------------------------------------
# primer_resolve_handoff_path <cwd>
#
# Thin wrapper around handoff_resolve_path (lib/handoff-resolve.sh).
# PR-9: the canonical resolver lives in handoff-resolve.sh so step2.sh can call it
# directly without depending on primer-helpers.
# SENTINEL_SID8 is set by primer_find_sentinel_for_cwd — that function MUST run first.
# Sets HANDOFF_PATH (global) on success (rc=0); leaves empty on failure.
# Returns:
#   0 — handoff path resolved
#   1 — no handoff file found (SID unknown, no alias either)
#   2 — SID known but no SID-tagged file (R4 D3 fail-closed signal)
# ---------------------------------------------------------------------------
primer_resolve_handoff_path() {
  local cwd="$1"
  handoff_resolve_path "$cwd" "${SENTINEL_SID8:-}"
  return $?
}

# ---------------------------------------------------------------------------
# primer_check_marker <file>
#
# Checks for END-OF-HANDOFF marker (new or legacy form) in the last 512 bytes.
# Sets MARKER_PRESENT ("true" or "false") globally.
# ---------------------------------------------------------------------------
primer_check_marker() {
  local file="$1"
  # H1: delegate to handoff_marker_check lib function (from lib/handoff-marker.sh, sourced by
  # post-compact-primer.sh before this file). Eliminates duplicate grep logic.
  if handoff_marker_check "$file"; then
    MARKER_PRESENT="true"
  else
    MARKER_PRESENT="false"
  fi
}

# ---------------------------------------------------------------------------
# primer_check_freshness <file>
#
# Checks handoff file mtime for staleness.
# Sets HANDOFF_MTIME, HANDOFF_AGE, STAT_OK, LEGACY, STALE_WARNING globally.
# Requires HANDOFF_STALE_SECS and HANDOFF_LEGACY_CUTOFF_EPOCH to be set.
# ---------------------------------------------------------------------------
primer_check_freshness() {
  local file="$1" sid="${2:-unknown}"
  # B2 fix: explicit if-elif for stat (no || chaining — macOS BSD stat short-circuits).
  if HANDOFF_MTIME=$(stat -f %m "$file" 2>/dev/null); then
    :
  elif HANDOFF_MTIME=$(stat -c %Y "$file" 2>/dev/null); then
    :
  else
    HANDOFF_MTIME=0
  fi
  HANDOFF_MTIME=$(printf '%s' "$HANDOFF_MTIME" | tr -d '[:space:]')
  [ -z "$HANDOFF_MTIME" ] && HANDOFF_MTIME=0
  local now
  now=$(date +%s)
  HANDOFF_AGE=$((now - HANDOFF_MTIME))

  # Guard: stat failure (HANDOFF_MTIME=0) produces a ~57-year false-positive age.
  STAT_OK="true"
  if [ "$HANDOFF_MTIME" -eq 0 ]; then
    STAT_OK="false"
    HANDOFF_AGE=0
    ctx_gate_log "primer sid=${sid} action=stat-failed-mtime-zero stale-check-skipped"
  fi

  LEGACY="false"
  if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_MTIME" -lt "${HANDOFF_LEGACY_CUTOFF_EPOCH:-1779321600}" ]; then
    LEGACY="true"
  fi

  STALE_WARNING=""
  if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_AGE" -gt "${HANDOFF_STALE_SECS:-86400}" ]; then
    local age_human
    age_human=$((HANDOFF_AGE / 3600))
    STALE_WARNING="WARNING STALE HANDOFF — predates this session by ~${age_human}h; it may be from a prior conversation. Verify with the user before resuming."$'\n\n'
  fi
}

# ---------------------------------------------------------------------------
# primer_find_sentinel_for_cwd <cwd_canon> [session_id]
#
# Scans $HOME/.claude/progress/ for a sentinel matching the given canonical cwd.
# Sets SENTINEL_PRESENT, SENTINEL_PATH, SENTINEL_SID8, SENTINEL_NONCE globally.
#
# Phase 2 (Round 4): optional 2nd argument session_id.
# When session_id is provided (non-empty), require sentinel basename to match
# auto-compact-${session_id}.json EXACTLY (not glob). This binds the primer to
# the current session's sentinel and prevents Track A from adopting Track B's
# sentinel when both have sentinels for the same cwd (live-reproduced, Round 3
# Concurrency C1+C2). Falls back to cwd-match-only when session_id is empty.
# ---------------------------------------------------------------------------
primer_find_sentinel_for_cwd() {
  local cwd_canon="$1"
  local session_id="${2:-}"
  SENTINEL_PRESENT="false"
  SENTINEL_PATH=""
  SENTINEL_SID8=""
  SENTINEL_NONCE=""

  # Phase 2 (Round 4): session-id-strict binding.
  # When session_id is known, try the exact sentinel path first.
  if [ -n "$session_id" ]; then
    local exact_candidate="$HOME/.claude/progress/auto-compact-${session_id}.json"
    if [ -f "$exact_candidate" ]; then
      local sent_cwd
      sent_cwd=$(ac_read_sentinel_cwd "$exact_candidate" 2>/dev/null) || sent_cwd=""
      if [ -n "$sent_cwd" ]; then
        local sent_cwd_canon
        sent_cwd_canon=$(ac_canonicalize_path "$sent_cwd") || sent_cwd_canon="$sent_cwd"
        if [ -n "$cwd_canon" ] && [ -n "$sent_cwd_canon" ] \
           && { [ "$sent_cwd_canon" = "$cwd_canon" ] || [ "$sent_cwd" = "${CWD:-}" ]; }; then
          local sentinel_sid_full
          sentinel_sid_full=$(basename "$exact_candidate" .json | sed 's/^auto-compact-//')
          if printf '%s' "$sentinel_sid_full" | grep -qE '^[A-Za-z0-9_-]+$'; then
            SENTINEL_PRESENT="true"
            SENTINEL_PATH="$exact_candidate"
            SENTINEL_SID8=$(ac_compute_sid8 "$sentinel_sid_full")
            SENTINEL_NONCE=$(jq -r '.marker_nonce // empty' "$exact_candidate" 2>/dev/null) || SENTINEL_NONCE=""
            ctx_gate_log "primer_sentinel_bind session_id=${session_id} mode=strict path=$exact_candidate"
            return 0
          fi
        fi
      fi
    fi
    # Session-id known but exact sentinel not found or cwd mismatch — do NOT fall back to glob scan.
    # This is the correct fail-closed behavior: avoid adopting another track's sentinel.
    ctx_gate_log "primer_sentinel_bind session_id=${session_id} mode=strict-miss no-sentinel-found"
    return 0
  fi

  # session_id empty — legacy cwd-match glob scan (fallback for old contexts / manual invocations).
  ctx_gate_log "primer_sentinel_bind session_id=unknown mode=legacy-fallback"
  local sentinel_candidate
  for sentinel_candidate in "$HOME/.claude/progress/auto-compact-"*.json; do
    [ -f "$sentinel_candidate" ] || continue
    local sent_cwd
    # Schema-validating reader: symlink rejection, size cap, schema_version check.
    # Legacy sentinels (no cwd field) → skip via continue.
    sent_cwd=$(ac_read_sentinel_cwd "$sentinel_candidate" 2>/dev/null) || {
      ac_log "primer action=skip-legacy-sentinel path=$sentinel_candidate reason=no-cwd-field-or-invalid-schema"
      continue
    }
    if [ -z "$sent_cwd" ]; then
      ac_log "primer action=skip-legacy-sentinel path=$sentinel_candidate reason=empty-cwd"
      continue
    fi
    # Canonicalize sentinel cwd; match if EITHER canonical OR raw equality (R1-H1 fallback).
    local sent_cwd_canon
    sent_cwd_canon=$(ac_canonicalize_path "$sent_cwd") || sent_cwd_canon="$sent_cwd"
    # CWD (raw, pre-canonicalization) is available via the caller's global CWD variable.
    # H4: guard against empty-string false-positive when both canonicalizations fail.
    if [ -n "$cwd_canon" ] && [ -n "$sent_cwd_canon" ] \
       && { [ "$sent_cwd_canon" = "$cwd_canon" ] || [ "$sent_cwd" = "${CWD:-}" ]; }; then
      SENTINEL_PRESENT="true"
      SENTINEL_PATH="$sentinel_candidate"
      local sentinel_sid_full
      sentinel_sid_full=$(basename "$sentinel_candidate" .json | sed 's/^auto-compact-//')
      # H11 (R4): validate sentinel SID against safe charset before using it.
      # Rejects any SID containing characters outside [A-Za-z0-9_-] (path-traversal defense).
      if ! printf '%s' "$sentinel_sid_full" | grep -qE '^[A-Za-z0-9_-]+$'; then
        ctx_gate_log "primer skip reason=invalid-sentinel-basename path=$sentinel_candidate"
        SENTINEL_PRESENT="false"
        SENTINEL_PATH=""
        continue
      fi
      # R3-fix-sweep C2: use TTY-aware ac_compute_sid8 so parallel sessions with
      # __ttysN suffix produce DISTINCT SID8 values (auto-compact-sentinel.sh sourced above).
      SENTINEL_SID8=$(ac_compute_sid8 "$sentinel_sid_full")
      SENTINEL_NONCE=$(jq -r '.marker_nonce // empty' "$sentinel_candidate" 2>/dev/null) || SENTINEL_NONCE=""
      # R4 D6: handoff_detected log line MOVED to post-compact-primer.sh AFTER
      # primer_resolve_handoff_path completes (so HANDOFF_PATH is set at log time).
      break
    fi
    # Different cwd — sentinel for another workspace; skip.
  done
}
