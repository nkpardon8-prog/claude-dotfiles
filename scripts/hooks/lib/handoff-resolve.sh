#!/usr/bin/env bash
# handoff-resolve.sh — canonical HANDOFF_PATH resolver.
# Used by post-compact-primer.sh (via primer_resolve_handoff_path in primer-helpers) AND
# post-compact-resume-step2.sh (directly).
#
# Sets HANDOFF_PATH on success; returns:
#   0 — resolved
#   1 — no handoff (SID unknown, no alias either)
#   2 — SID known but no SID-tagged file found (fail-closed signal)
#   3 — SID-tagged file exists but is hardlinked (distinct from rc=2)
#
# R8: Second parameter renamed from sid8 to session_id (full UUID now, no truncation).
# F4 alias probe deleted (V2-6) — alias-with-marker-binding was for the old alias path;
# with full-UUID filenames + identity-via-arg, the alias probe is dead code (writer never
# writes CLAUDE.local.md alias; legacy 8-char alias markers cannot match a full UUID).
#
# macOS bash 3.2.57 compatible.

[ -n "${_HANDOFF_RESOLVE_LOADED:-}" ] && return 0
readonly _HANDOFF_RESOLVE_LOADED=1

# Defensive stub: if ctx_gate_log wasn't sourced from lib/ctx-gate-config.sh, no-op it.
command -v ctx_gate_log >/dev/null 2>&1 || ctx_gate_log() { :; }

# ---------------------------------------------------------------------------
# _primer_check_linkcount <path>
#
# R2-PR-6 (Round 3 BLOCKER fix): DEFINED HERE (not in primer-helpers).
# H9: Returns 0 if file linkcount == 1 (normal file); 1 if linkcount > 1 (hardlink).
# BSD stat: -f %l; GNU stat: -c %h. Falls back to fail-closed on stat failure.
# ---------------------------------------------------------------------------
_primer_check_linkcount() {
  local p="$1"
  local linkcount stat_ok
  stat_ok=false
  if linkcount=$(stat -f %l "$p" 2>/dev/null); then
    stat_ok=true
  elif linkcount=$(stat -c %h "$p" 2>/dev/null); then
    stat_ok=true
  fi
  # H10 fix: fail-CLOSED on stat failure.
  if [ "$stat_ok" = "false" ]; then
    ctx_gate_log "primer skip reason=stat-failed path=$p"
    return 1
  fi
  linkcount=$(printf '%s' "$linkcount" | tr -d '[:space:]')
  [ -z "$linkcount" ] && linkcount=1
  if [ "$linkcount" -gt 1 ]; then
    ctx_gate_log "primer skip reason=multi-hardlink path=$p linkcount=$linkcount"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# handoff_resolve_path <cwd> [session_id]
#
# V2-5 (R8): second parameter renamed from sid8 to session_id (full UUID).
# PR-9: canonical resolver. session_id may be empty (SID-unknown path).
#
# When session_id is provided (non-empty):
#   - Tries SID-tagged files: <cwd>/CLAUDE.local.<session_id>.md + repo-root variant.
#     F2 (R7-INC-02): each candidate is content-verified — the file's END-OF-HANDOFF
#     marker `sid=` attribute MUST match the requested session_id.
#     Allow-empty marker only for legacy files (mtime < HANDOFF_LEGACY_CUTOFF_EPOCH).
#   - If no SID-tagged file passes content-check: returns 2 (fail-closed signal).
#     V2-6: F4 alias probe (CLAUDE.local.md alias-with-marker-binding) deleted.
#     Writer never writes the alias under R8; legacy 8-char alias markers cannot
#     match a full UUID arg. No alias probe needed.
#   - If found but hardlinked: logs + returns 3.
#
# When session_id is empty (SID unknown):
#   - Tries legacy alias files only: <cwd>/CLAUDE.local.md + repo-root variant.
#   - No content-check (legacy; alias accepted as-is).
#   - If found: sets HANDOFF_PATH, returns 0.
#   - If not found: returns 1.
# ---------------------------------------------------------------------------
handoff_resolve_path() {
  local cwd="$1" session_id="${2:-}"
  HANDOFF_PATH=""

  if [ -n "$session_id" ]; then
    local _legacy_cutoff="${HANDOFF_LEGACY_CUTOFF_EPOCH:-1779321600}"

    # ---------- cwd SID-tagged probe ----------
    local p="$cwd/CLAUDE.local.${session_id}.md"
    if [ -f "$p" ] && [ ! -L "$p" ]; then
      if _primer_check_linkcount "$p"; then
        # F2: marker-sid content-check. Canonical pattern mirrors handoff-marker.sh:130.
        local _resolver_marker_sid
        _resolver_marker_sid=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$p" 2>/dev/null | head -1 \
          | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
        if [ -n "$_resolver_marker_sid" ]; then
          if [ "$_resolver_marker_sid" = "$session_id" ]; then
            HANDOFF_PATH="$p"
            return 0
          else
            ctx_gate_log "primer skip reason=resolver-marker-sid-mismatch session_id=$session_id marker_sid=$_resolver_marker_sid file=$p"
            # Fall through to repo-root probe.
          fi
        else
          # R9-R2 HIGH-1 (fail-closed): on the SID-tagged path a file with NO marker cannot be
          # identity-verified, so it is NEVER accepted via mtime. The old legacy-mtime allow here
          # was a wrong-load hole — a markerless CLAUDE.local.<arg>.md in a shared repo-root would
          # load when the consumer-layer self-check is unavailable. Legacy-mtime tolerance applies
          # ONLY to the SID-unknown alias path below, never to a SID-tagged probe. Fall through → rc=2.
          ctx_gate_log "primer skip reason=resolver-sid-tagged-no-marker session_id=$session_id file=$p"
          # Fall through (do not accept).
        fi
      else
        local LCNT
        if LCNT=$(stat -f %l "$p" 2>/dev/null); then :
        elif LCNT=$(stat -c %h "$p" 2>/dev/null); then :
        else LCNT=">1"
        fi
        LCNT=$(printf '%s' "$LCNT" | tr -d '[:space:]')
        ctx_gate_log "primer skip reason=multi-hardlink linkcount=${LCNT} file=$p"
        return 3
      fi
    fi

    # ---------- repo-root SID-tagged probe ----------
    local repo_root
    repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || repo_root=""
    if [ -n "$repo_root" ]; then
      p="$repo_root/CLAUDE.local.${session_id}.md"
      if [ -f "$p" ] && [ ! -L "$p" ]; then
        if _primer_check_linkcount "$p"; then
          local _resolver_marker_sid2
          _resolver_marker_sid2=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$p" 2>/dev/null | head -1 \
            | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
          if [ -n "$_resolver_marker_sid2" ]; then
            if [ "$_resolver_marker_sid2" = "$session_id" ]; then
              HANDOFF_PATH="$p"
              return 0
            else
              ctx_gate_log "primer skip reason=resolver-marker-sid-mismatch session_id=$session_id marker_sid=$_resolver_marker_sid2 file=$p"
            fi
          else
            # R9-R2 HIGH-1 (fail-closed): SID-tagged repo-root probe — markerless file is never
            # accepted via mtime (same wrong-load hole as the cwd probe above). Fall through → rc=2.
            ctx_gate_log "primer skip reason=resolver-sid-tagged-no-marker session_id=$session_id file=$p"
          fi
        else
          local LCNT2
          if LCNT2=$(stat -f %l "$p" 2>/dev/null); then :
          elif LCNT2=$(stat -c %h "$p" 2>/dev/null); then :
          else LCNT2=">1"
          fi
          LCNT2=$(printf '%s' "$LCNT2" | tr -d '[:space:]')
          ctx_gate_log "primer skip reason=multi-hardlink linkcount=${LCNT2} file=$p"
          return 3
        fi
      fi
    fi

    # V2-6 (R8): F4 alias probe removed. With full-UUID filenames + identity-via-arg,
    # the alias (CLAUDE.local.md) probe is dead code — writer never writes it under R8,
    # and legacy 8-char alias markers cannot match a full UUID. Returning 2 (fail-closed).
    ctx_gate_log "primer skip reason=sid-known-no-tagged-file session_id=${session_id}"
    return 2
  fi

  # SID UNKNOWN: legacy alias-only path.
  local p2="$cwd/CLAUDE.local.md"
  if [ -f "$p2" ] && [ ! -L "$p2" ] && _primer_check_linkcount "$p2"; then
    HANDOFF_PATH="$p2"
    return 0
  fi
  local repo_root2
  repo_root2=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || repo_root2=""
  if [ -n "$repo_root2" ]; then
    p2="$repo_root2/CLAUDE.local.md"
    if [ -f "$p2" ] && [ ! -L "$p2" ] && _primer_check_linkcount "$p2"; then
      HANDOFF_PATH="$p2"
      return 0
    fi
  fi
  return 1
}
