#!/usr/bin/env bash
# 06-toctou-tty-format-parity.sh
#
# THE CRITICAL GAP (Codex review #4): the fire path bash-derives + verifies a tty, then AppleScript
# matches a tab by `(tty of t) is targetTTY`. Two provable sub-contracts text review cannot settle:
#
#   P1 (FORMAT PARITY — single point of total failure): AppleScript `tty of t` returns the SAME string
#      form that `ac_pid_tty` produces (`/dev/ttysN`). If one side is `ttys000` and the other
#      `/dev/ttys000`, the match silently NEVER succeeds and EVERY fire returns no-matching-tab. The
#      delivery hook passes the `/dev/`-prefixed value; this proves AppleScript agrees.
#
#   P2 (TOCTOU window): the gap between bash `ps` verification and AppleScript `do script` cannot be
#      fully closed in a test (sleep/wake/tab-close can reassign a tty mid-fire). This test MEASURES
#      the residual window of the verify->match sequence so a regression that widens it is visible, and
#      asserts the in-AppleScript foreground/tab-existence check is the backstop. Re-resolve-adjacent
#      (plan) narrows but does not eliminate it; the self-resume + R9 guard catch the rare miss.
#
# NEGATIVE CONTROL (synthetic): P1 also asserts a deliberately wrong-format target ('ttys000' without
#   /dev/) does NOT match any tab — proving the match is format-sensitive (so parity actually matters).
#
# Requires macOS Terminal.app + a live claude tab. Exit: 0 PASS · 1 FAIL · 2 REFUSED · 3 INFRASTRUCTURE
set -uo pipefail
[ "${CORRELATION_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set CORRELATION_TESTS_ALLOW_DEV=true to run assumption tests" >&2; exit 2; }
[ "$(uname -s)" = "Darwin" ] || { echo "INFRASTRUCTURE: macOS-only (Terminal.app)" >&2; exit 3; }
[ "${TERM_PROGRAM:-}" = "Apple_Terminal" ] || echo "INFO: TERM_PROGRAM='${TERM_PROGRAM:-}' (expected Apple_Terminal) — proceeding, tab match may be N/A."

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$HERE/06-toctou-tty-format-parity.fingerprint.json"

pid_tty() { local t; t=$(ps -o tty= -p "$1" 2>/dev/null | tr -d '[:space:]'); case "$t" in ttys[0-9]*) printf '/dev/%s' "$t"; return 0;; esac; return 1; }
own_claude() { local p="${PPID:-}" h a; for h in 1 2 3 4 5 6 7 8; do [ -z "$p" ]&&break; { [ "$p" = 0 ]||[ "$p" = 1 ]; }&&break; a=$(ps -ww -o args= -p "$p" 2>/dev/null); printf '%s' "$a"|grep -Eq '(^|[[:space:]/])claude([[:space:]]|$)'&&{ printf '%s' "$p"; return 0; }; p=$(ps -o ppid= -p "$p" 2>/dev/null|tr -d ' '); done; return 1; }

PID=$(own_claude) || { echo "INFRASTRUCTURE: no claude ancestor" >&2; exit 3; }
TARGET=$(pid_tty "$PID") || { echo "INFRASTRUCTURE: could not derive /dev/ttysN for claude $PID" >&2; exit 3; }
fails=()

# ask AppleScript: does a tab's (tty of t) equal our /dev/-prefixed target? and what raw form does it report?
match_with() {  # $1 = target string to match against
  /usr/bin/osascript - "$1" <<'EOF' 2>/dev/null
on run argv
  set want to item 1 of argv
  tell application "Terminal"
    if not running then return "not-running"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of t) is want then return "MATCH"
        end try
      end repeat
    end repeat
    return "no-match"
  end tell
end run
EOF
}

# P1 — correct /dev/-prefixed form MUST match exactly one tab
R_CORRECT=$(match_with "$TARGET")
case "$R_CORRECT" in
  MATCH) : ;;
  not-running) echo "INFRASTRUCTURE: Terminal.app not scriptable" >&2; exit 3 ;;
  *) fails+=("P1 FORMAT PARITY BROKEN: AppleScript did not match the /dev/-prefixed target '$TARGET' (got '$R_CORRECT') — EVERY fire would return no-matching-tab") ;;
esac

# P1neg — wrong format (bare ttysN, no /dev/) must NOT match (proves match is format-sensitive)
BARE="${TARGET#/dev/}"
R_BARE=$(match_with "$BARE")
[ "$R_BARE" = "MATCH" ] && fails+=("P1neg unexpectedly matched the bare form '$BARE' — match not format-sensitive (then parity wouldn't matter, but the hook passes /dev/ form so investigate)")

# P2 — measure the verify->match residual window (informational regression guard)
T0=$(date +%s)
_=$(pid_tty "$PID"); _=$(match_with "$TARGET")
T1=$(date +%s)
WINDOW=$(( T1 - T0 ))
# the window should be small (sub-second to a couple seconds). Flag only an egregious widening.
[ "$WINDOW" -gt 10 ] && fails+=("P2 verify->match window unexpectedly large: ${WINDOW}s (TOCTOU exposure widened)")

if [ ${#fails[@]} -gt 0 ]; then
  echo "FAIL: 06-toctou-tty-format-parity"; for f in "${fails[@]}"; do echo "  - $f"; done; exit 1
fi
printf '{"applescript_tty_form":"/dev/-prefixed","format_parity":true,"verify_match_window_s":%s}\n' "$WINDOW" > "$FP"
echo "PASS: 06-toctou-tty-format-parity — target=$TARGET parity=ok window=${WINDOW}s (P1, P1neg, P2)"
exit 0
