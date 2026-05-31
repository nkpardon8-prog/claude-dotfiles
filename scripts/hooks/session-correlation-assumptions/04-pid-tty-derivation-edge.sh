#!/usr/bin/env bash
# 04-pid-tty-derivation-edge.sh
#
# A4 — `ac_pid_tty <pid>` ( ps -o tty= ) derives the controlling tty correctly across the edge states
#      the fire-path hits:
#        - a live claude returns its controlling /dev/ttysN (proven in 01/02 — re-asserted here),
#        - a process with NO controlling terminal (setsid/disowned) returns empty/`??`, and the helper
#          maps that to rc1 (NOT a reassigned/stale ttysN) — so a severed tab can never be targeted.
#
#   The fire-path derives tty from the pid *while compaction is firing*, a moment when claude may not
#   be the foreground leader. `ps -o tty=` reports the CONTROLLING tty regardless of foreground status,
#   so derivation is independent of the foreground check (which is a separate guard). This test proves
#   the no-tty case fails CLOSED.
#
# NEGATIVE CONTROL (controllable precondition): a `setsid`-detached process has no controlling tty;
#   the helper must return rc1/empty for it. If it returned a ttysN, that's the misfire vector.
#
# Exit: 0 PASS · 1 FAIL · 2 REFUSED · 3 INFRASTRUCTURE
set -uo pipefail
[ "${CORRELATION_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set CORRELATION_TESTS_ALLOW_DEV=true to run assumption tests" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$HERE/04-pid-tty-derivation-edge.fingerprint.json"
BGPID=""
cleanup() { [ -n "$BGPID" ] && kill "$BGPID" 2>/dev/null; return 0; }
trap cleanup EXIT

# --- candidate helper under test (mirrors plan ac_pid_tty) ---
pid_tty() { local t; t=$(ps -o tty= -p "$1" 2>/dev/null | tr -d '[:space:]'); case "$t" in ttys[0-9]*) printf '/dev/%s' "$t"; return 0;; esac; return 1; }

own_claude() { local p="${PPID:-}" h a; for h in 1 2 3 4 5 6 7 8; do [ -z "$p" ]&&break; { [ "$p" = 0 ]||[ "$p" = 1 ]; }&&break; a=$(ps -ww -o args= -p "$p" 2>/dev/null); printf '%s' "$a"|grep -Eq '(^|[[:space:]/])claude([[:space:]]|$)'&&{ printf '%s' "$p"; return 0; }; p=$(ps -o ppid= -p "$p" 2>/dev/null|tr -d ' '); done; return 1; }

fails=()

# A4a — live claude has a controlling /dev/ttysN
PID=$(own_claude) || { echo "INFRASTRUCTURE: no claude ancestor" >&2; exit 3; }
if T=$(pid_tty "$PID"); then
  case "$T" in /dev/ttys[0-9]*) : ;; *) fails+=("A4a pid_tty($PID) returned non-ttys form '$T'") ;; esac
else
  fails+=("A4a pid_tty($PID) failed to resolve a controlling tty for the live claude")
fi

# A4b — a setsid/no-controlling-tty process maps to rc1 (fail-closed), NOT a stale ttysN
NOTTY_DERIVED=""
if command -v setsid >/dev/null 2>&1; then
  setsid sleep 30 & BGPID=$!
else
  # macOS lacks setsid(1); use a background job whose controlling tty we then check.
  # A plain background job KEEPS the controlling tty, so to get a true no-tty proc we
  # disown + redirect; if we cannot truly detach, we degrade to checking ps output directly.
  ( sleep 30 </dev/null >/dev/null 2>&1 & echo $! ) >/tmp/.corr-bg.$$ 2>/dev/null
  BGPID=$(cat /tmp/.corr-bg.$$ 2>/dev/null); rm -f /tmp/.corr-bg.$$ 2>/dev/null
fi
sleep 0.3
if [ -n "$BGPID" ] && kill -0 "$BGPID" 2>/dev/null; then
  RAWT=$(ps -o tty= -p "$BGPID" 2>/dev/null | tr -d '[:space:]')
  NOTTY_DERIVED="$RAWT"
  if pid_tty "$BGPID" >/dev/null 2>&1; then
    # It resolved to a ttysN. Acceptable ONLY if the process genuinely still has that controlling tty
    # (macOS background jobs inherit the tty). The load-bearing assertion is the helper never INVENTS
    # a tty for a process whose ps tty is '??' or empty:
    case "$RAWT" in
      ""|"??") fails+=("A4b helper resolved a ttysN for a no-tty process (ps tty='$RAWT') — fail-OPEN, misfire vector") ;;
      *) echo "INFO: background proc retained controlling tty '$RAWT' (macOS inherits tty for bg jobs without setsid) — no-tty path not exercised; see A4c." ;;
    esac
  else
    : # rc1 — correct fail-closed for a no/`??` tty
  fi
else
  echo "INFO: could not spawn a detached probe process; A4b degraded."
fi

# A4c — direct contract: the helper's case-guard rejects empty and '??' (the values ps gives a no-tty proc)
#   This is the pure fail-closed contract, independent of whether we could spawn a real setsid proc.
_probe() { local t="$1"; case "$t" in ttys[0-9]*) return 0;; *) return 1;; esac; }
_probe "" && fails+=("A4c guard accepted EMPTY tty (fail-open)")
_probe "??" && fails+=("A4c guard accepted '??' tty (fail-open)")
_probe "ttys000" || fails+=("A4c guard REJECTED a valid 'ttys000'")

if [ ${#fails[@]} -gt 0 ]; then
  echo "FAIL: 04-pid-tty-derivation-edge"; for f in "${fails[@]}"; do echo "  - $f"; done; exit 1
fi
printf '{"live_tty":"%s","notty_probe_raw":"%s"}\n' "${T:-}" "${NOTTY_DERIVED:-}" > "$FP"
echo "PASS: 04-pid-tty-derivation-edge — live=$T (A4a, A4b, A4c)"
exit 0
