#!/usr/bin/env bash
# session-key.sh — Per-session HMAC key management for breadcrumb authenticity.
#
# R5 Phase 3: Criticals #5, #6, #7 (SID-knowledge poisoning / same-SID hijack).
# Provides per-session signing keys so that breadcrumbs written by the Stop hook
# can be verified by step2.sh as originating from the legitimate session process.
#
# Key file: $HOME/.claude/progress/.session-key-<SID8> (mode 0600)
# Key format: 64 hex chars (32 bytes of raw entropy) from /dev/urandom
# Key derivation: generated at first session setup, idempotent (existing file NOT overwritten).
#
# Signing: openssl SHA-256 HMAC of canonical fields using newline separator.
# Canonical field order (hardcoded, invariant): sid\nnonce\nmarker_nonce\ncwd\nhost\noriginating_command
# Using newline separator because fields may contain | or other punctuation.
# Note: macOS has openssl 3.x (LibreSSL via brew or system); BSD sed used throughout.
#
# Escape hatch: HANDOFF_ACCEPT_UNSIGNED=1 env var makes verify return 0 for unsigned
# breadcrumbs (migration window; one-major-version deprecation). Default: deny unsigned.
#
# Source-guard: second sourcing is a no-op.
[ -n "${_SESSION_KEY_LOADED:-}" ] && return 0
readonly _SESSION_KEY_LOADED=1

# ---------------------------------------------------------------------------
# session_key_path <SID8>
# Returns (via stdout) the path to the session key file for this SID8.
# ---------------------------------------------------------------------------
session_key_path() {
  local sid8="$1"
  printf '%s' "$HOME/.claude/progress/.session-key-${sid8}"
}

# ---------------------------------------------------------------------------
# session_key_generate <SID8>
# Generates a 32-byte HMAC key for this session (idempotent: no-op if key exists).
# Creates key file at mode 0600. Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
session_key_generate() {
  local sid8="$1"
  [ -n "$sid8" ] || return 1
  local keyfile
  keyfile=$(session_key_path "$sid8")
  # Idempotent: if key already exists and is non-empty, do not overwrite.
  if [ -f "$keyfile" ] && [ -s "$keyfile" ]; then
    return 0
  fi
  local keydir
  keydir=$(dirname "$keyfile")
  mkdir -p "$keydir" 2>/dev/null && chmod 700 "$keydir" 2>/dev/null || return 1
  local key
  # Generate 32 bytes = 64 hex chars from /dev/urandom.
  # BSD head -c 32 + xxd or od for hex; use od as portable fallback.
  if command -v xxd >/dev/null 2>&1; then
    key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | xxd -p | tr -d '[:space:]')
  else
    key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  fi
  [ -n "$key" ] || return 1
  # Write atomically via temp + rename; mode 0600 via umask.
  local tmp="${keyfile}.tmp.$$"
  ( umask 077 && printf '%s\n' "$key" > "$tmp" ) && mv "$tmp" "$keyfile" && return 0
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------------------
# session_key_load <SID8>
# Prints the key hex string on stdout. Returns 1 if key file is absent or empty.
# ---------------------------------------------------------------------------
session_key_load() {
  local sid8="$1"
  [ -n "$sid8" ] || return 1
  local keyfile
  keyfile=$(session_key_path "$sid8")
  [ -f "$keyfile" ] && [ -s "$keyfile" ] || return 1
  # Safety: ensure file is owned by us and mode 0600.
  [ -O "$keyfile" ] || return 1
  local mode
  mode=$(stat -f '%Lp' "$keyfile" 2>/dev/null || stat -c '%a' "$keyfile" 2>/dev/null)
  [ "$mode" = "600" ] || return 1
  tr -d '[:space:]' < "$keyfile"
}

# ---------------------------------------------------------------------------
# session_key_sign <SID8> <sid> <nonce> <marker_nonce> <cwd> <host> <originating_command>
# Prints a hex HMAC-SHA256 signature on stdout.
# Returns 1 if openssl is not available or key is missing.
# Canonical field separator: newline (\n). Field order is hardcoded.
# ---------------------------------------------------------------------------
session_key_sign() {
  local sid8="$1" sid="$2" nonce="$3" marker_nonce="$4" cwd="$5" host="$6" origcmd="$7"
  [ -n "$sid8" ] || return 1
  local key
  key=$(session_key_load "$sid8") || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  # Build canonical message (newline-separated fields, hardcoded order).
  # printf is used so that \n is a literal newline, not a backslash-n.
  local msg
  msg=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    "$sid" "$nonce" "$marker_nonce" "$cwd" "$host" "$origcmd")
  # Compute HMAC-SHA256. openssl dgst -hmac uses the key as a raw string.
  # Convert hex key to binary first (openssl on macOS 3.x requires binary key via -mac HMAC -macopt).
  # Use the simpler -hmac <passphrase> form; key is the hex string treated as passphrase (portable).
  printf '%s' "$msg" | openssl dgst -sha256 -hmac "$key" 2>/dev/null | sed 's/.*= //'
}

# ---------------------------------------------------------------------------
# session_key_verify <SID8> <sig> <sid> <nonce> <marker_nonce> <cwd> <host> <origcmd>
# Returns:
#   0  — signature valid (or key-absent with empty sig → fail-open backward compat)
#   1  — signature mismatch (attacker-forged or HANDOFF_ACCEPT_UNSIGNED=0 with empty sig + key exists)
#   2  — verification inconclusive (key/openssl unavailable; caller may proceed with warning)
#
# Security model:
# - Key file exists + sig empty: REJECT (the signer should have signed; something is wrong).
# - Key file exists + sig present: VERIFY (reject if mismatch).
# - Key file absent + sig empty: ACCEPT (no key → no signing was possible → backward compat).
# - Key file absent + sig present: INCONCLUSIVE (can't verify foreign sig; caller warns + accepts).
# - HANDOFF_ACCEPT_UNSIGNED=1: always accept empty sig regardless of key state (migration window).
# ---------------------------------------------------------------------------
session_key_verify() {
  local sid8="$1" sig="$2" sid="$3" nonce="$4" marker_nonce="$5" cwd="$6" host="$7" origcmd="$8"
  [ -n "$sid8" ] || return 2
  # Migration escape hatch: accept unsigned breadcrumbs when explicitly enabled.
  if [ -z "$sig" ] && [ "${HANDOFF_ACCEPT_UNSIGNED:-0}" = "1" ]; then
    return 0
  fi
  local keyfile
  keyfile=$(session_key_path "$sid8")
  # Key-absent + empty sig → backward compat fail-open (signing wasn't possible).
  if [ -z "$sig" ] && [ ! -f "$keyfile" ]; then
    return 0
  fi
  # Key-absent + sig present → inconclusive (can't verify).
  if [ ! -f "$keyfile" ]; then
    return 2
  fi
  # Key exists + empty sig → reject (signer should have signed).
  [ -n "$sig" ] || return 1
  local expected
  expected=$(session_key_sign "$sid8" "$sid" "$nonce" "$marker_nonce" "$cwd" "$host" "$origcmd") || return 2
  [ -n "$expected" ] || return 2
  # Constant-time comparison.
  [ "$sig" = "$expected" ] && return 0 || return 1
}
