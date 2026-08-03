#!/bin/bash
# codex-invoke.sh — Bounded wrapper around `codex exec` for god-review.
#
# Usage: bash lib/codex-invoke.sh <outfile> <prompt> <workdir>
#
#   outfile  — Path to write Codex output (written atomically via temp->mv at the end).
#   prompt   — The review prompt string (quoted by the caller).
#   workdir  — Working directory passed to `--cd`.
#
# Optional env vars (set before calling for two-account threading):
#   CODEX_HOME_1  — CODEX_HOME for primary account profile.
#   CODEX_HOME_2  — CODEX_HOME for fallback account profile (used if primary fails).
#   CODEX_BIN     — Path or name of the codex binary. Defaults to "codex".
#   GODREVIEW_INVOKE_TIMEOUT_SECS — start-to-finish deadline for the WHOLE invocation
#                   (profile fallback + lock-wait + codex). Default 3300 s.
#
# Account isolation strategy:
#   - If CODEX_HOME_1 is set: use it. On failure, try CODEX_HOME_2 if set.
#   - If neither is set: fall back to shared ~/.codex with flock serialization
#     (or mkdir-spinlock if flock unavailable) to prevent concurrent calls from
#     stomping each other's session state.
#   - If codex binary is not on PATH: write "(unavailable)" note and exit 0.
#
# Termination guarantee (why the whole wrapper is bounded, not just codex exec):
#   The real hang surface is NOT only a runaway `codex exec` — it is ALSO an unbounded
#   `flock` / mkdir-spinlock wait on the shared ~/.codex lock (a late waiter can block
#   forever behind a wedged holder). So EVERY blocking leg draws from ONE shared
#   remaining-budget deadline. `pt_run` bounds codex and kills its whole PROCESS GROUP
#   (TERM then KILL) on timeout; the lock legs are bounded by `flock -w`/a budget-checked
#   spin. On any deadline hit we write `<outfile>.status=timeout` and exit 124, so a
#   timed-out PARTIAL output is never miscounted as a completed reviewer.
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

# --- Whole-invocation deadline (shared remaining-budget) ---
START=$(date +%s)
INVOKE_TIMEOUT="${GODREVIEW_INVOKE_TIMEOUT_SECS:-3300}"

# Partial output accumulates here; promoted to OUTFILE atomically at the end.
WORK_OUT="${OUTFILE}.partial"
: > "$WORK_OUT" 2>/dev/null || true

# Source the shared portable-timeout helper (pt_run <secs> <cmd...>). If absent,
# degrade to an UNBOUNDED runner rather than crash (belt-and-braces; the lib ships here).
PT_LIB="$HOME/.claude-dotfiles/scripts/lib/portable-timeout.sh"
if [ -f "$PT_LIB" ]; then
  # shellcheck disable=SC1090
  . "$PT_LIB"
else
  pt_run() { shift; "$@"; }
fi

# remaining budget in seconds (never negative; 0 means the deadline is spent).
remaining() {
  local now elapsed rem
  now=$(date +%s)
  elapsed=$(( now - START ))
  rem=$(( INVOKE_TIMEOUT - elapsed ))
  if [ "$rem" -lt 1 ]; then rem=0; fi
  printf '%s' "$rem"
}

# Map a run rc to a status word for the sidecar.
map_status() {
  local rc="$1"
  if [ "$rc" -eq 0 ]; then
    printf 'ok'
  elif [ "$rc" -eq 124 ]; then
    printf 'timeout'
  else
    printf 'nonzero-%s' "$rc"
  fi
}

# Single terminal: atomically promote the partial output, write the .status sidecar,
# and exit with the run rc. finish <rc> [explicit-status]
finish() {
  local rc="$1" st="${2:-}"
  if [ -z "$st" ]; then st=$(map_status "$rc"); fi
  mv -f "$WORK_OUT" "$OUTFILE" 2>/dev/null || true
  printf '%s\n' "$st" > "$OUTFILE.status.tmp" && mv -f "$OUTFILE.status.tmp" "$OUTFILE.status"
  exit "$rc"
}

# Guard: codex binary must exist.
if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  echo "[unavailable] codex binary not found on PATH (CODEX_BIN=${CODEX_BIN})" > "$WORK_OUT"
  finish 0 unavailable
fi

# --- Helper: run codex with an optional CODEX_HOME override, bounded by the remaining budget ---
# Returns 124 if the deadline is already spent or if pt_run times out (pt_run kills the
# child's whole process group). NEVER call this bare under `set -e` — capture rc via
# `|| rc=$?` so a 124 does not abort before lock cleanup + the .status write.
run_codex() {
  local home_arg="$1" rem
  rem=$(remaining)
  if [ "$rem" -le 0 ]; then return 124; fi
  if [ -n "$home_arg" ]; then
    CODEX_HOME="$home_arg" pt_run "$rem" "$CODEX_BIN" \
      -c model_reasoning_effort="xhigh" \
      exec -s read-only --ephemeral --cd "$WORKDIR" \
      "$PROMPT" >> "$WORK_OUT" 2>&1
  else
    pt_run "$rem" "$CODEX_BIN" \
      -c model_reasoning_effort="xhigh" \
      exec -s read-only --ephemeral --cd "$WORKDIR" \
      "$PROMPT" >> "$WORK_OUT" 2>&1
  fi
}

# --- Case 1: primary profile configured ---
if [ -n "$PRIMARY_HOME" ]; then
  rc=0; run_codex "$PRIMARY_HOME" || rc=$?
  if [ "$rc" -eq 0 ]; then finish 0; fi
  # A 124 means the shared deadline is spent — going to the fallback would only 124 again.
  if [ "$rc" -eq 124 ]; then finish 124; fi
  # Primary failed fast (non-timeout); try fallback if available and budget remains.
  if [ -n "$FALLBACK_HOME" ]; then
    echo "[primary-failed] falling back to CODEX_HOME_2=${FALLBACK_HOME}" >> "$WORK_OUT"
    rc=0; run_codex "$FALLBACK_HOME" || rc=$?
    finish "$rc"
  fi
  finish "$rc"
fi

# --- Case 2: fallback only (primary empty, fallback non-empty) ---
if [ -n "$FALLBACK_HOME" ]; then
  rc=0; run_codex "$FALLBACK_HOME" || rc=$?
  finish "$rc"
fi

# --- Case 3: no isolated profile — use shared ~/.codex with lock serialization ---
echo "[no-profile] running with default CODEX_HOME (~/.codex). Multi-account isolation unavailable — serializing on /tmp/codex-default-home.lock." >> "$WORK_OUT"

LOCK_FILE=/tmp/codex-default-home.lock

if command -v flock >/dev/null 2>&1; then
  # Use file descriptor 200 for the lock; function runs in same shell, inherits all vars.
  # The lock WAIT is bounded by the remaining budget (`flock -w`) — an unbounded flock is
  # the real hang, not just codex. A wait that exhausts the budget is a deadline timeout.
  exec 200>"$LOCK_FILE"
  lock_wait=$(remaining)
  if [ "$lock_wait" -le 0 ] || ! flock -w "$lock_wait" 200; then
    exec 200>&- 2>/dev/null || true
    finish 124
  fi
  rc=0; run_codex "" || rc=$?
  flock -u 200 2>/dev/null || true
  exec 200>&- 2>/dev/null || true
  finish "$rc"
fi

# flock unavailable — mkdir-spinlock fallback with stale-lock detection.
# A SIGKILLed prior run leaves the lockdir behind indefinitely; detect and remove it
# if its mtime is older than 600 seconds (10 minutes).
LOCKDIR=/tmp/codex-default-home.lock.d
LOCK_TIMEOUT="${SPINLOCK_TIMEOUT_SEC:-600}"

if [ -d "$LOCKDIR" ]; then
  lock_mtime=$(stat -f "%m" "$LOCKDIR" 2>/dev/null || stat -c "%Y" "$LOCKDIR" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$((now - lock_mtime))
  if [ "$age" -gt "$LOCK_TIMEOUT" ]; then
    echo "[spinlock] stale lockdir detected (age=${age}s > ${LOCK_TIMEOUT}s); force-removing." >> "$WORK_OUT"
    rmdir "$LOCKDIR" 2>/dev/null || true
  fi
fi

# The spin is bounded by the remaining budget — a wedged holder must not hang us forever.
while ! mkdir "$LOCKDIR" 2>/dev/null; do
  if [ "$(remaining)" -le 0 ]; then finish 124; fi
  sleep 0.5
done
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

rc=0; run_codex "" || rc=$?

rmdir "$LOCKDIR" 2>/dev/null || true
trap - EXIT INT TERM
finish "$rc"
