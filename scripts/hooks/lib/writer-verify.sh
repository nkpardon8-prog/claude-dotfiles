#!/usr/bin/env bash
# writer-verify.sh — R7-INC-01: writer self-verification of marker SID vs filename SID8.
# Sourced by /pre-compact Step 6D.
#
# Function:
#   writer_verify_marker_sid <handoff_path> <expected_sid8>
#     Returns 0 if marker sid matches expected_sid8.
#     Returns 1 if marker absent, mismatched, or invocation error.
#
# HZ-38 defense (INV-24): ensures the file just written carries the same SID8
# in its marker as was used for its filename. Prevents writer-sid-divergence
# where Step 6A bash subprocess SID differs from Step 6D working-memory SID.
#
# macOS bash 3.2.57 compatible.

[ -n "${_WRITER_VERIFY_LOADED:-}" ] && return 0
readonly _WRITER_VERIFY_LOADED=1

# Shared first-occurrence-anchored marker-SID extractor (_resolver_extract_marker_sid).
# Sourced by path relative to THIS file; load-guarded inside handoff-locate.sh.
_WRITER_VERIFY_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=./handoff-locate.sh
. "$_WRITER_VERIFY_LIBDIR/handoff-locate.sh"

writer_verify_marker_sid() {
  local handoff_path="$1" expected_sid8="$2"
  if [ ! -f "$handoff_path" ]; then
    printf 'writer-verify-error: file absent: %s\n' "$handoff_path" >&2
    return 1
  fi
  if [ -z "$expected_sid8" ]; then
    printf 'writer-verify-error: empty expected_sid8\n' >&2
    return 1
  fi
  local observed_sid
  observed_sid=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$handoff_path" 2>/dev/null \
    | head -1 \
    | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
  if [ -z "$observed_sid" ]; then
    printf 'writer-sid-divergence: no marker found in %s (expected sid=%s)\n' \
      "$handoff_path" "$expected_sid8" >&2
    return 1
  fi
  if [ "$observed_sid" != "$expected_sid8" ]; then
    printf 'writer-sid-divergence: filename_sid8=%s marker_sid_observed=%s handoff=%s\n' \
      "$expected_sid8" "$observed_sid" "$handoff_path" >&2
    return 1
  fi
  return 0
}
