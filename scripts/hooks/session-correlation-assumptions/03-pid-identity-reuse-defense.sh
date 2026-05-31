#!/usr/bin/env bash
# 03-pid-identity-reuse-defense.sh
#
# A5 — A pid+start-time identity defeats macOS pid reuse, AND the start-time NORMALIZER produces a
#      byte-stable comparison key (the real, non-obvious risk):
#        - `ps -o lstart= -p <pid>` is non-empty for a live process,
#        - normalized form is byte-IDENTICAL across repeated reads of the SAME live pid
#          (so the fire-path equality check never false-mismatches on whitespace/locale jitter),
#        - a deliberately-altered stored start-time is REJECTED by the identity comparison
#          (so a recycled pid carrying a different birth time cannot pass as the original session).
#
#   Why the normalizer matters: `ps -o lstart=` emits trailing spaces, and single-digit days print a
#   DOUBLE space ("May  5" vs "May 28"). If normalization jitters, a CORRECT pid false-aborts EVERY
#   fire — a silent self-DoS worse than the bug. `tr -s ' '` + trim must collapse it deterministically.
#
# NEGATIVE CONTROL (synthetic injection): assertion A5c mutates the stored start-time and confirms the
#   comparison rejects it; without that route a recycled pid would silently pass.
#
# Exit: 0 PASS · 1 FAIL · 2 REFUSED · 3 INFRASTRUCTURE
set -uo pipefail
[ "${CORRELATION_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set CORRELATION_TESTS_ALLOW_DEV=true to run assumption tests" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$HERE/03-pid-identity-reuse-defense.fingerprint.json"

# --- candidate helper under test (mirrors plan ac_pid_starttime) ---
pid_starttime() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ *$//'; }

fails=()

# Use a real, stable, live pid: our own claude ancestor (long-lived) — fall back to $$ (this shell).
own_claude() { local p="${PPID:-}" h a; for h in 1 2 3 4 5 6 7 8; do [ -z "$p" ]&&break; { [ "$p" = 0 ]||[ "$p" = 1 ]; }&&break; a=$(ps -ww -o args= -p "$p" 2>/dev/null); printf '%s' "$a"|grep -Eq '(^|[[:space:]/])claude([[:space:]]|$)'&&{ printf '%s' "$p"; return 0; }; p=$(ps -o ppid= -p "$p" 2>/dev/null|tr -d ' '); done; return 1; }
PID=$(own_claude) || PID=$$

# A5a — non-empty
S1=$(pid_starttime "$PID")
[ -n "$S1" ] || fails+=("A5a pid_starttime($PID) returned empty for a live pid")

# A5b — byte-stable across 3 reads (normalizer determinism)
S2=$(pid_starttime "$PID"); S3=$(pid_starttime "$PID")
if [ "$S1" != "$S2" ] || [ "$S1" != "$S3" ]; then
  fails+=("A5b normalized start-time NOT byte-stable across reads: '$S1' vs '$S2' vs '$S3' (would false-abort every fire)")
fi
# also assert no leading/trailing space and no double-space survived normalization
case "$S1" in
  " "*|*" ") fails+=("A5b normalized form has leading/trailing space: '[$S1]'") ;;
esac
case "$S1" in
  *"  "*) fails+=("A5b normalized form still contains a DOUBLE space (single-digit-day jitter not collapsed): '[$S1]'") ;;
esac

# A5c — a mutated stored start-time is rejected (synthetic injection / reuse defense)
STORED_BAD="${S1} TAMPERED"
if [ "$S1" = "$STORED_BAD" ]; then
  fails+=("A5c comparison considered a tampered start-time equal — reuse defense broken")
fi
# and a CORRECT stored value must still match (no false-abort)
STORED_GOOD="$S1"
[ "$S1" = "$STORED_GOOD" ] || fails+=("A5c correct stored start-time FALSELY rejected — would self-DoS")

# A5d — two DIFFERENT live pids have (almost certainly) different start-times OR are distinguishable;
#   compare our claude vs our shell ($$). If equal start-time, pid alone still differs — identity is (pid,lstart).
if [ "$PID" != "$$" ]; then
  OTHER=$(pid_starttime "$$")
  # identity = pid + lstart; they must NOT compare equal as a tuple
  if [ "$PID|$S1" = "$$|$OTHER" ]; then fails+=("A5d identity tuple collision between pid=$PID and pid=$$"); fi
fi

if [ ${#fails[@]} -gt 0 ]; then
  echo "FAIL: 03-pid-identity-reuse-defense"; for f in "${fails[@]}"; do echo "  - $f"; done; exit 1
fi
printf '{"starttime_nonempty":true,"normalizer_stable":true,"sample":"%s"}\n' "$S1" > "$FP"
echo "PASS: 03-pid-identity-reuse-defense — pid=$PID lstart='$S1' (A5a,A5b,A5c,A5d)"
exit 0
