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
# S2 — INVOKE_TIMEOUT flows into bash arithmetic `$(( ))` in remaining(). An UNVALIDATED env var
# like `GODREVIEW_INVOKE_TIMEOUT_SECS='x[$(rm -rf ~)]'` would EXECUTE the command during arithmetic
# evaluation (arithmetic injection -> RCE). Require a plain positive integer; anything else (or an
# absurd value) falls back to the safe default BEFORE it ever reaches `$(( ))`.
case "$INVOKE_TIMEOUT" in
  ''|*[!0-9]*) echo "[warn] GODREVIEW_INVOKE_TIMEOUT_SECS is not a plain integer; using default 3300" >&2; INVOKE_TIMEOUT=3300 ;;
esac
# F2 (round-2): digits-only is NOT enough. `08`/`09` are invalid OCTAL and would ERROR under `$(( ))`
# (aborting before finish() writes a status), and an overlong digit string can overflow. Reject an
# overlong value by STRING length BEFORE any arithmetic, then force base-10 so leading zeros never
# read as octal. Only then is the numeric range test safe.
if [ "${#INVOKE_TIMEOUT}" -gt 6 ]; then echo "[warn] GODREVIEW_INVOKE_TIMEOUT_SECS too long; using default 3300" >&2; INVOKE_TIMEOUT=3300; fi
INVOKE_TIMEOUT=$((10#$INVOKE_TIMEOUT))
# now a plain base-10 int <= 999999; a 0 or an absurd ceiling collapses to the default.
if [ "$INVOKE_TIMEOUT" -lt 1 ] || [ "$INVOKE_TIMEOUT" -gt 21600 ]; then INVOKE_TIMEOUT=3300; fi

# Partial output accumulates here; promoted to OUTFILE atomically at the end. Per-PID (I4) so two
# invocations sharing an OUTFILE never clobber each other's partial / status temp.
WORK_OUT="${OUTFILE}.partial.$$"
: > "$WORK_OUT" 2>/dev/null || true

# Source the shared portable-timeout helper (pt_run <secs> <cmd...>). C11 — if it is absent, DO NOT
# degrade to an unbounded runner (that restores the exact hang this wrapper exists to kill). Try the
# system gtimeout/timeout; if none is available, fail CLOSED (guarded below, once finish() exists).
PT_LIB="$HOME/.claude-dotfiles/scripts/lib/portable-timeout.sh"
PT_OK=1
# F3 (round-2): a PRESENT-but-broken/unreadable helper must NOT abort the wrapper under `set -e` before
# finish() exists (that leaves the FIFO with no output/status, looking never-launched). Source it
# defensively (`|| true`), then VERIFY pt_run was actually defined; if not, fall back to system
# gtimeout/timeout, else fail CLOSED. C11 — never degrade to an unbounded runner.
if [ -f "$PT_LIB" ] && [ -r "$PT_LIB" ]; then
  # shellcheck disable=SC1090
  . "$PT_LIB" 2>/dev/null || true
fi
if ! command -v pt_run >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    pt_run() { gtimeout --kill-after=2 "$@"; }
  elif command -v timeout >/dev/null 2>&1; then
    pt_run() { timeout --kill-after=2 "$@"; }
  else
    PT_OK=0
    pt_run() { return 125; }   # never reached (guarded once finish() exists); defined for set -u
  fi
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
  # I4 — a FAILED promote must NOT be reported as `ok`: a caller counting `ok` sidecars would count a
  # reviewer whose output never landed. Reflect the promote failure in both status and rc.
  if ! mv -f "$WORK_OUT" "$OUTFILE" 2>/dev/null; then
    st=promote-failed
    [ "$rc" -eq 0 ] && rc=1
  fi
  printf '%s\n' "$st" > "$OUTFILE.status.$$.tmp" && mv -f "$OUTFILE.status.$$.tmp" "$OUTFILE.status"
  exit "$rc"
}

# Guard: codex binary must exist.
if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
  echo "[unavailable] codex binary not found on PATH (CODEX_BIN=${CODEX_BIN})" > "$WORK_OUT"
  finish 0 unavailable
fi

# C11 — fail CLOSED if no bounded runner is available. Running codex unbounded here would restore the
# exact runaway/lock-wait hang the whole wrapper was built to prevent, so refuse rather than risk it.
if [ "$PT_OK" -ne 1 ]; then
  echo "[refused] no portable-timeout helper (portable-timeout.sh / gtimeout / timeout) available — refusing to run codex UNBOUNDED (a hang would freeze god-review). Install coreutils (gtimeout) or restore portable-timeout.sh." > "$WORK_OUT"
  finish 1 no-timeout-helper
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
# A SIGKILLed prior run leaves the lockdir behind indefinitely; detect and remove it once its mtime
# is older than the stale threshold. I5 — that threshold MUST exceed the longest LEGIT hold.
# R7-5 — the longest legit hold is the HOLDER's OWN budget, NOT the waiter's. A short-budget waiter
# (e.g. 3300 s) must NEVER evict a still-live holder that was launched with a larger budget (e.g.
# 21600 s). So the HOLDER publishes its INVOKE_TIMEOUT into `$LOCKDIR/budget` on acquire, and a WAITER
# sizes its stale threshold to (holder_budget + 60). When that file is absent/unreadable/invalid, the
# waiter falls back to the CAP (21600) + 60 — conservative: never evict a possibly-live holder.
LOCKDIR=/tmp/codex-default-home.lock.d
_LOCK_CAP_FLOOR=$((21600 + 60))

# _holder_stale_threshold -> the age (s) past which the CURRENT lockdir holder is deemed dead. Reads the
# holder's own budget file; validates with the SAME anti-injection idiom used for INVOKE_TIMEOUT (reject
# non-numeric / over-long / out-of-range BEFORE any `$(( ))`), else the conservative CAP+60 fallback.
_holder_stale_threshold() {
  _hb_file="$LOCKDIR/budget"; _hb=""
  [ -r "$_hb_file" ] && _hb=$(head -1 "$_hb_file" 2>/dev/null)
  case "$_hb" in
    ''|*[!0-9]*) printf '%s' "$_LOCK_CAP_FLOOR"; return 0 ;;
  esac
  if [ "${#_hb}" -gt 6 ]; then printf '%s' "$_LOCK_CAP_FLOOR"; return 0; fi
  _hb=$((10#$_hb))
  if [ "$_hb" -lt 1 ] || [ "$_hb" -gt 21600 ]; then printf '%s' "$_LOCK_CAP_FLOOR"; return 0; fi
  printf '%s' "$((_hb + 60))"
}

# S2 (round-4) - SPINLOCK_TIMEOUT_SEC arrives from the environment. It may only RAISE the stale threshold
# above the holder-sized value, NEVER lower it (round-5: a too-small value like 1 must not make a live
# lockdir look stale after 1 s). Validate with the same anti-injection idiom BEFORE any `$(( ))`.
_SPIN_RAISE=0
case "${SPINLOCK_TIMEOUT_SEC:-}" in
  ''|*[!0-9]*) _SPIN_RAISE=0 ;;
  *) if [ "${#SPINLOCK_TIMEOUT_SEC}" -le 6 ]; then _SPIN_RAISE=$((10#$SPINLOCK_TIMEOUT_SEC)); fi ;;
esac

if [ -d "$LOCKDIR" ]; then
  lock_mtime=$(stat -f "%m" "$LOCKDIR" 2>/dev/null || stat -c "%Y" "$LOCKDIR" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$((now - lock_mtime))
  LOCK_TIMEOUT=$(_holder_stale_threshold)
  if [ "$_SPIN_RAISE" -gt "$LOCK_TIMEOUT" ]; then LOCK_TIMEOUT=$_SPIN_RAISE; fi
  if [ "$age" -gt "$LOCK_TIMEOUT" ]; then
    echo "[spinlock] stale lockdir detected (age=${age}s > ${LOCK_TIMEOUT}s); force-removing." >> "$WORK_OUT"
    rm -f "$LOCKDIR/budget" 2>/dev/null || true
    rmdir "$LOCKDIR" 2>/dev/null || true
  fi
fi

# The spin is bounded by the remaining budget — a wedged holder must not hang us forever.
while ! mkdir "$LOCKDIR" 2>/dev/null; do
  if [ "$(remaining)" -le 0 ]; then finish 124; fi
  sleep 0.5
done
# We hold the lock: publish OUR budget so a future waiter sizes ITS stale threshold to OUR hold (R7-5).
printf '%s\n' "$INVOKE_TIMEOUT" > "$LOCKDIR/budget" 2>/dev/null || true
trap 'rm -f "$LOCKDIR/budget" 2>/dev/null; rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

rc=0; run_codex "" || rc=$?

rm -f "$LOCKDIR/budget" 2>/dev/null || true
rmdir "$LOCKDIR" 2>/dev/null || true
trap - EXIT INT TERM
finish "$rc"
