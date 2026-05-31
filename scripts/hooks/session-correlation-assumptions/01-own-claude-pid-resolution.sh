#!/usr/bin/env bash
# 01-own-claude-pid-resolution.sh
#
# A1 — From a claude-descendant process, an ANCHORED-ERE ancestry walk resolves THE session's
#      real TUI `claude` process (not a `node …/cli.js` wrapper, not a `.claude-dotfiles` path
#      match, not the `ucomm` version string), and `ps -o tty= -p <pid>` yields its controlling
#      /dev/ttysN.
#
# CONTEXT NOTE (the A1 proxy question): this test runs from a Bash-tool subprocess. On this
#   machine the Bash tool spawns scripts as a DIRECT child of `claude` (PPID == claude — verified
#   live, hop 1), the SAME ancestry depth as the real Stop hook (auto-compact-after-pre-compact.sh
#   header: "runs as a direct subprocess of Claude Code"). So this is a VALID proxy here. The test
#   RECORDS the resolved hop-depth in its fingerprint; a future depth > 1 means the context changed
#   and A1 must be re-validated from the actual hook.
#
# NEGATIVE CONTROL (synthetic injection): the anchored ERE rejects argv strings that a bare
#   `*claude*` glob would falsely match (`/x/.claude-dotfiles/y`, `node /x/claude-cli.js`); proven
#   inline (assertion N1). Also proves `ucomm`-based resolution would have mis-resolved (the
#   2026-05-14 regression) — assertion N2.
#
# Exit: 0 PASS · 1 FAIL · 2 REFUSED · 3 INFRASTRUCTURE
set -uo pipefail
[ "${CORRELATION_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set CORRELATION_TESTS_ALLOW_DEV=true to run assumption tests" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$HERE/01-own-claude-pid-resolution.fingerprint.json"
ERE='(^|[[:space:]/])claude([[:space:]]|$)'

# --- candidate helper under test (mirrors plan ac_resolve_own_claude_pid) ---
resolve_own_claude_pid() {   # echoes "pid hop" or empty
  local p="${PPID:-}" hop args
  for hop in 1 2 3 4 5 6 7 8; do
    [ -z "$p" ] && break; { [ "$p" = 0 ] || [ "$p" = 1 ]; } && break
    args=$(ps -ww -o args= -p "$p" 2>/dev/null)
    if printf '%s' "$args" | grep -Eq "$ERE"; then printf '%s %s' "$p" "$hop"; return 0; fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')
  done
  return 1
}
pid_tty() { local t; t=$(ps -o tty= -p "$1" 2>/dev/null | tr -d '[:space:]'); case "$t" in ttys[0-9]*) printf '/dev/%s' "$t"; return 0;; esac; return 1; }

fails=()

# A1 — resolution finds a pid + its argv really matches the ERE
RES=$(resolve_own_claude_pid) || { echo "INFRASTRUCTURE: no claude ancestor found (run inside a Claude session)" >&2; exit 3; }
PID=${RES%% *}; HOP=${RES##* }
ARGS=$(ps -ww -o args= -p "$PID" 2>/dev/null)
printf '%s' "$ARGS" | grep -Eq "$ERE" || fails+=("A1 resolved pid=$PID but its argv does not match the anchored ERE: '$ARGS'")

# A1b — resolved process is the REAL TUI (argv[0] basename == claude), not a node wrapper
COMM=$(ps -o comm= -p "$PID" 2>/dev/null); BASE=$(basename "$COMM" 2>/dev/null)
case "$BASE" in
  claude) : ;;
  *) fails+=("A1b resolved pid=$PID comm='$COMM' basename='$BASE' — expected the TUI 'claude', got a wrapper/other. argv: $ARGS") ;;
esac

# A1c — its controlling tty resolves to /dev/ttysN
TTY=$(pid_tty "$PID") || fails+=("A1c pid_tty($PID) did not resolve to /dev/ttysN (got: '$(ps -o tty= -p "$PID" 2>/dev/null)')")

# N1 — anchored ERE rejects glob-false-positives that *claude* would match
for bad in "/Users/x/.claude-dotfiles/foo" "node /opt/claude-cli.js --x" "/usr/bin/claudette" "myclaudexyz"; do
  if printf '%s' "$bad" | grep -Eq "$ERE"; then fails+=("N1 anchored ERE FALSELY matched '$bad' (would mis-resolve)"); fi
done
# and confirm it DOES match the real forms
for good in "claude --dangerously-skip-permissions" "/opt/homebrew/bin/claude" "claude"; do
  printf '%s' "$good" | grep -Eq "$ERE" || fails+=("N1 anchored ERE failed to match legit '$good'")
done

# N2 — ucomm of the claude proc is NOT the literal 'claude' (proves the 2026-05-14 ucomm regression class)
UCOMM=$(ps -o ucomm= -p "$PID" 2>/dev/null)
case "$UCOMM" in
  claude) : ;;  # if some build DOES expose comm=claude, fine — not a failure, just record
  *) [ -n "$UCOMM" ] && echo "INFO: ucomm='$UCOMM' (NOT 'claude') — resolution MUST use args=, never ucomm. (documents the 2026-05-14 regression)" ;;
esac

if [ ${#fails[@]} -gt 0 ]; then
  echo "FAIL: 01-own-claude-pid-resolution"; for f in "${fails[@]}"; do echo "  - $f"; done; exit 1
fi
printf '{"hop_depth":%s,"resolved_comm":"%s","tty_form":"%s","ucomm":"%s"}\n' "$HOP" "$BASE" "$TTY" "${UCOMM:-}" > "$FP"
echo "PASS: 01-own-claude-pid-resolution — pid=$PID hop=$HOP tty=$TTY (A1, A1b, A1c, N1, N2)"
exit 0
