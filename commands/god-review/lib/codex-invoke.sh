#!/bin/bash
# codex-invoke.sh — Thin wrapper around `codex exec` for god-review.
#
# Usage: bash lib/codex-invoke.sh <outfile> <primary_home> <fallback_home> <prompt>
#
#   outfile       — Path to write Codex output (appended, not overwritten, on retries).
#   primary_home  — Value of CODEX_HOME for the primary account profile. Pass "" to skip.
#   fallback_home — Value of CODEX_HOME for the fallback account profile. Pass "" to skip.
#   prompt        — The review prompt string (quoted by the caller).
#
# Optional env vars (set before calling):
#   CODEX_HOME_1  — If set, overrides primary_home arg when arg is empty.
#   CODEX_HOME_2  — If set, overrides fallback_home arg when arg is empty.
#   WORKDIR       — Working directory passed to `--cd`. Defaults to $PWD.
#   CODEX_BIN     — Path or name of the codex binary. Defaults to "codex".
#
# Account isolation strategy:
#   - If primary_home (or CODEX_HOME_1) is set: use it. On failure, try fallback.
#   - If neither primary nor fallback is set: fall back to shared ~/.codex with
#     flock serialization (or mkdir-spinlock if flock unavailable) to prevent
#     concurrent calls from stomping each other's session state.
#   - If codex binary is not on PATH: write "(unavailable)" note and exit 0.
#
# This script intentionally drops multi-account router.json threading from master-review.md.
# Two-profile alternation (CODEX_HOME_1 / CODEX_HOME_2) is the maximum supported here.

set -euo pipefail

OUTFILE="${1:?outfile argument required}"
PRIMARY_HOME="${2:-}"
FALLBACK_HOME="${3:-}"
PROMPT="${4:?prompt argument required}"

CODEX_BIN="${CODEX_BIN:-codex}"
WORKDIR="${WORKDIR:-$PWD}"

# Resolve profile homes: explicit args take precedence; env vars fill in when arg is empty.
if [ -z "$PRIMARY_HOME" ] && [ -n "${CODEX_HOME_1:-}" ]; then
  PRIMARY_HOME="$CODEX_HOME_1"
fi
if [ -z "$FALLBACK_HOME" ] && [ -n "${CODEX_HOME_2:-}" ]; then
  FALLBACK_HOME="$CODEX_HOME_2"
fi

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
    echo "[primary-failed] falling back to FALLBACK_HOME=${FALLBACK_HOME}" >> "$OUTFILE"
    run_with_home "$FALLBACK_HOME"
    exit $?
  fi
  # No fallback — surface the failure.
  exit 1
fi

# --- Case 2: fallback only (primary empty, fallback non-empty) ---
if [ -n "$FALLBACK_HOME" ]; then
  run_with_home "$FALLBACK_HOME"
  exit $?
fi

# --- Case 3: no isolated profile — use shared ~/.codex with lock-file serialization ---
# Multiple concurrent Codex calls sharing the default ~/.codex can stomp each other's
# session/account state. Serialize with flock (preferred) or mkdir-spinlock (fallback).
echo "[no-profile] running with default CODEX_HOME (~/.codex). Multi-account isolation unavailable — serializing on /tmp/codex-default-home.lock." >> "$OUTFILE"

LOCK_FILE=/tmp/codex-default-home.lock

run_codex_default() {
  "$CODEX_BIN" \
    -c model_reasoning_effort="high" \
    exec -s read-only --ephemeral --cd "$WORKDIR" \
    "$PROMPT" >> "$OUTFILE" 2>&1
}

if command -v flock >/dev/null 2>&1; then
  flock "$LOCK_FILE" bash -c "$(declare -f run_codex_default); run_codex_default"
  exit $?
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
