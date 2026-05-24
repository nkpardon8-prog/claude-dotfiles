#!/usr/bin/env bash
# handoff-marker.sh — canonical marker constants + detection helper.
# Used by post-compact-primer.sh + /post-compact-resume Bash snippet.
#
# Execution context: sourced by SessionStart hook scripts and orchestrator Bash
# snippets. Hook paths run as subprocess; orchestrator paths run in Bash tool.
#
# Source-guard: second sourcing is a no-op.
[ -n "${_HANDOFF_MARKER_LOADED:-}" ] && return 0
readonly _HANDOFF_MARKER_LOADED=1

# Canonical marker strings — locked format (attributes in fixed order).
# New form: schema + sid + nonce attributes.
# Legacy form: bare closing, predates the schema= convention.
readonly HANDOFF_MARKER_NEW='<!-- END-OF-HANDOFF schema=v1'
readonly HANDOFF_MARKER_LEGACY='<!-- END-OF-HANDOFF -->'

# ---------------------------------------------------------------------------
# handoff_marker_check <file>
#
# Returns 0 if marker (new or legacy) found in the last 512 bytes of file; 1 otherwise.
#
# 512-byte tail: marker is ~55 bytes. 512 provides ample headroom for long last lines
# + trailing whitespace, avoiding truncated-tail false negatives.
#
# Uses subprocess pipe — safe for hook scripts and orchestrator Bash tool calls
# below the hard-gate threshold. For orchestrator Bash AT the hard gate, callers
# should use the Read tool + in-memory grep instead of calling this function.
# ---------------------------------------------------------------------------
handoff_marker_check() {
  local file="$1"
  [ -f "$file" ] || return 1
  local tail_buf
  tail_buf=$(tail -c 512 "$file" 2>/dev/null) || return 1
  if printf '%s' "$tail_buf" | grep -qF "$HANDOFF_MARKER_NEW" \
     || printf '%s' "$tail_buf" | grep -qF "$HANDOFF_MARKER_LEGACY"; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# handoff_marker_nonce <file>
#
# Extracts the nonce from the marker line if present; prints nothing on failure.
# Nonce extraction is order-insensitive within the marker line.
# ---------------------------------------------------------------------------
handoff_marker_nonce() {
  local file="$1"
  [ -f "$file" ] || return 1
  tail -c 512 "$file" 2>/dev/null | sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p' | head -1
}
