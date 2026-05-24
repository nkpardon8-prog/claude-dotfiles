#!/usr/bin/env bash
# handoff-marker.sh — canonical marker constants + detection helper.
# Used by post-compact-primer.sh + /post-compact-resume Bash snippet.
#
# Execution context: sourced by SessionStart hook scripts and orchestrator Bash
# snippets. Hook paths run as subprocess; orchestrator paths run in Bash tool.
#
# Write-protocol invariant: the pre-compact writer appends the END-OF-HANDOFF
# marker exactly ONCE at the very end of the file and nothing modifies the file
# after that. Therefore, within any well-formed handoff file there is exactly
# ONE marker line. head -1 is used instead of tail -1 throughout to defend
# against an attacker who appends a second marker line AFTER the canonical one:
# head -1 picks the FIRST (canonical) marker, ignoring any appended impostor.
# An attacker who PREPENDS a second marker before the canonical one would win
# head -1 — but the write protocol writes the canonical marker LAST and
# nothing external to the pre-compact pipeline modifies the file between arm
# time and ingestion. handoff_marker_count() logs a warning when count > 1 so
# operators can detect tampered files; ingestion still proceeds (defense-in-depth).
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
  # R3-fix-sweep C3+C4: anchor extraction to the actual marker line.
  # grep -F filters to ONLY lines containing the literal marker prefix;
  # tail -1 picks the last such line (canonical marker is at end-of-file);
  # sed then extracts the nonce= attribute value.
  # This defeats body-injection attacks (body content containing nonce=... in prose
  # can no longer shadow the canonical marker's nonce value).
  tail -c 512 "$file" 2>/dev/null \
    | grep -F 'END-OF-HANDOFF schema=' \
    | tail -1 \
    | sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p'
}

# ---------------------------------------------------------------------------
# handoff_marker_sid <file>
#
# C1+C3 fix: extracts the sid= attribute from the END-OF-HANDOFF marker line.
# Prints the sid8 value on success; prints nothing on failure (file absent,
# no marker, or no sid= attribute).
# Attribute extraction is order-insensitive within the marker line.
# The sid= attribute value uses the same safe charset as SID8: [A-Za-z0-9_-]+
# (double-underscore separator is preserved since _ is in that set).
#
# R3-fix-sweep C1: BSD sed doesn't recognize \b word-boundary — the old
# implementation silently returned empty on macOS. Fixed by anchoring extraction
# to the marker line (via grep -F) so \b is no longer needed.
# R3-fix-sweep C3+C4: same anchor-to-marker-line approach defeats body-injection.
# ---------------------------------------------------------------------------
handoff_marker_sid() {
  local file="$1"
  [ -f "$file" ] || return 1
  # grep -F filters to ONLY marker lines; tail -1 picks last (canonical is end-of-file);
  # sed extracts sid= attribute — no \b needed (already on a marker-only line).
  tail -c 512 "$file" 2>/dev/null \
    | grep -F 'END-OF-HANDOFF schema=' \
    | tail -1 \
    | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p'
}
