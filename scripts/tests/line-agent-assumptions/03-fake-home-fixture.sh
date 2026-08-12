#!/usr/bin/env bash
# 03 — Can a hermetic fixture satisfy the REAL liveness check?
#
# Every other test in this suite builds a synthetic registry under a throwaway $HOME. That is only
# worth anything if the script judges the synthetic window ALIVE. The script's liveness test shells
# `ps -p <pid> -o comm=` and requires the string "claude" in the output, so a fixture must present a
# real running process whose comm looks like claude. If macOS truncates comm, strips the path
# differently than expected, or the script reads it differently, every fixture reads as "not
# running" and every later assertion silently exercises only the failure branch — vacuously green,
# which this repo has a written rule against (scripts/hooks/verify-test-integrity.sh).
#
# A1 — `ps -p <pid> -o comm=` on a copy of /bin/sleep named `claude` contains "claude"
# A2 — the REAL script (invoked as a subprocess, not reimplemented here) lists that window
#
# NEGATIVE CONTROL (controllable precondition): name the fixture binary `notclaude` instead and
# confirm A1/A2 fail. Verified at authoring time — see the NEG_CONTROL block below, run with
# LINE_AGENT_NEG_CONTROL=true.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$SCRIPT" ] || { echo "INFRA: script not found: $SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="lac-atest"                       # stable namespace marker, for the orphan reaper
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
BINNAME="claude"; [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ] && BINNAME="notclaude"

# --- startup orphan reaper: `finally` does not survive SIGKILL, so reap prior crashed runs -------
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
FAKE_PID=""

cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  rm -rf "$FAKE_HOME" 2>/dev/null || echo "CLEANUP WARNING: could not remove $FAKE_HOME" >&2
}
trap cleanup EXIT

mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status"

# a real process whose comm looks like claude
cp /bin/sleep "$FAKE_HOME/$BINNAME" 2>/dev/null || { echo "INFRA: cannot copy /bin/sleep" >&2; exit 3; }
"$FAKE_HOME/$BINNAME" 120 &
FAKE_PID=$!
sleep 0.3
kill -0 "$FAKE_PID" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }

FAILURES=()

# --- A1 — does ps report a comm containing "claude"? --------------------------------------------
COMM="$(ps -p "$FAKE_PID" -o comm= 2>/dev/null | tr -d ' ')"
case "$COMM" in
  *claude*) ;;
  *) FAILURES+=("A1 expected ps comm to contain 'claude', got '${COMM}'") ;;
esac

# --- A2 — does the REAL script list a synthetic window backed by that pid? -----------------------
# procStart/startedAt are filled from the fixture process's own truth so the entry is self-consistent.
PROC_START="$(ps -o lstart= -p "$FAKE_PID" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
SID="00000000-0000-4000-8000-${RUN_ID}"
python3 - "$FAKE_HOME" "$FAKE_PID" "$SID" "$PROC_START" <<'PY'
import json, os, sys, time
home, pid, sid, procstart = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
entry = {
    "pid": pid, "sessionId": sid, "cwd": home,
    "startedAt": int(time.time() * 1000), "procStart": procstart,
    "version": "2.1.228", "peerProtocol": 1, "kind": "interactive",
    "entrypoint": "cli", "name": "atest-window", "nameSource": "explicit",
    "status": "idle", "updatedAt": int(time.time() * 1000), "bridgeSessionId": None,
}
with open(os.path.join(home, ".claude", "sessions", f"{pid}.json"), "w") as fh:
    json.dump(entry, fh, separators=(",", ":"))
with open(os.path.join(home, ".claude", "session-status", f"{sid}.txt"), "w") as fh:
    fh.write("atest window\n")
PY

OUT="$(HOME="$FAKE_HOME" python3 "$SCRIPT" list 2>&1)"
case "$OUT" in
  *atest-window*) ;;
  *) FAILURES+=("A2 real script did not list the fixture window; output was: $(printf '%s' "$OUT" | head -3 | tr '\n' '|')") ;;
esac

# --- verdict ------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "NEG-CONTROL OK: test correctly went RED with a non-claude binary (${#FAILURES[@]} assertion(s) failed)"
    exit 0
  fi
  echo "NEG-CONTROL BROKEN: test stayed GREEN with a binary named '$BINNAME' - it proves nothing" >&2
  exit 1
fi

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo "FAIL: 03-fake-home-fixture" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi

cat > "${HERE}/03-fake-home-fixture.fingerprint.json" <<EOF
{"assumption":"hermetic_fixture_satisfies_liveness_check","uname":"$(uname -s)","os_version":"$(sw_vers -productVersion 2>/dev/null || echo unknown)","ps_comm_observed":"${COMM}","comm_is_basename":$([ "$COMM" = "claude" ] && echo true || echo false)}
EOF

echo "PASS: 03-fake-home-fixture — 2 assertions (A1 ps-comm, A2 real-script-lists-fixture)"
exit 0
