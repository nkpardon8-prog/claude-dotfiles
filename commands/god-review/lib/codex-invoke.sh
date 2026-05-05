#!/bin/bash
# codex-invoke.sh — Thin wrapper around `codex exec` for god-review.
#
# Usage: bash lib/codex-invoke.sh <outfile> <prompt> <workdir>
#
#   outfile  — Path to write Codex output (appended on retries).
#   prompt   — The review prompt string (quoted by the caller).
#   workdir  — Working directory passed to `--cd`.
#
# Optional env vars (set before calling for two-account threading):
#   CODEX_HOME_1  — CODEX_HOME for primary account profile.
#   CODEX_HOME_2  — CODEX_HOME for fallback account profile (used if primary fails).
#   CODEX_BIN     — Path or name of the codex binary. Defaults to "codex".
#
# Account isolation strategy:
#   - If CODEX_HOME_1 is set: use it. On failure, try CODEX_HOME_2 if set.
#   - If neither is set: fall back to shared ~/.codex with flock serialization
#     (or mkdir-spinlock if flock unavailable) to prevent concurrent calls from
#     stomping each other's session state.
#   - If codex binary is not on PATH: write "(unavailable)" note and exit 0.
#
# This script intentionally drops multi-account router.json threading from master-review.md.
# Two-profile alternation (CODEX_HOME_1 / CODEX_HOME_2) is the maximum supported.

set -euo pipefail

OUTFILE="${1:?outfile argument required}"
PROMPT="${2:?prompt argument required}"
WORKDIR="${3:?workdir argument required}"

CODEX_BIN="${CODEX_BIN:-codex}"
PRIMARY_HOME="${CODEX_HOME_1:-}"
FALLBACK_HOME="${CODEX_HOME_2:-}"

# Guard: codex binary must exist.
if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  echo "[unavailable] codex binary not found on PATH (CODEX_BIN=${CODEX_BIN})" > "$OUTFILE"
  exit 0
fi

# --- Helper: run with a given CODEX_HOME ---
run_with_home() {
  local home="$1"
  CODEX_HOME="$home" "$CODEX_BIN" \
    -c model_reasoning_effort="high" \
    exec -s read-only --ephemeral --cd "$WORKDIR" \
    "$PROMPT" >> "$OUTFILE" 2>&1
}

# --- Case 1: primary profile configured ---
if [ -n "$PRIMARY_HOME" ]; then
  if run_with_home "$PRIMARY_HOME"; then
    exit 0
  fi
  # Primary failed; try fallback if available.
  if [ -n "$FALLBACK_HOME" ]; then
    echo "[primary-failed] falling back to CODEX_HOME_2=${FALLBACK_HOME}" >> "$OUTFILE"
    run_with_home "$FALLBACK_HOME"
    exit $?
  fi
  exit 1
fi

# --- Case 2: fallback only (primary empty, fallback non-empty) ---
if [ -n "$FALLBACK_HOME" ]; then
  run_with_home "$FALLBACK_HOME"
  exit $?
fi

# --- Case 3: no isolated profile — use shared ~/.codex with lock serialization ---
echo "[no-profile] running with default CODEX_HOME (~/.codex). Multi-account isolation unavailable — serializing on /tmp/codex-default-home.lock." >> "$OUTFILE"

LOCK_FILE=/tmp/codex-default-home.lock

run_codex_default() {
  "$CODEX_BIN" \
    -c model_reasoning_effort="high" \
    exec -s read-only --ephemeral --cd "$WORKDIR" \
    "$PROMPT" >> "$OUTFILE" 2>&1
}

if command -v flock >/dev/null 2>&1; then
  # Use file descriptor 200 for the lock; function runs in same shell, inherits all vars.
  exec 200>"$LOCK_FILE"
  flock 200
  run_codex_default
  rc=$?
  flock -u 200
  exec 200>&-
  exit $rc
fi

# flock unavailable — mkdir-spinlock fallback.
LOCKDIR=/tmp/codex-default-home.lock.d
while ! mkdir "$LOCKDIR" 2>/dev/null; do
  sleep 0.5
done
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

run_codex_default
rc=$?

rmdir "$LOCKDIR" 2>/dev/null
trap - EXIT INT TERM
exit $rc
