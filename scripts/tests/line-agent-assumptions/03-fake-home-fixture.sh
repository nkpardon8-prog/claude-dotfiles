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
# Decoy name must not CONTAIN "claude" — the check is a substring match, so `notclaude` passes it.
# (Discovered by this very negative control: the first decoy was `notclaude` and the test stayed
# green, which is itself the over-match defect this suite exists to surface. See 05.)
BINNAME="claude"; [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ] && BINNAME="zzsleep"

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

# A real process whose comm looks like claude. SYMLINK, not copy: macOS SIGKILLs a copied system
# binary on exec (code-signature check) - `cp /bin/sleep .../claude` dies instantly with "Killed: 9".
# A symlink keeps the original signed inode while presenting our name on the exec path.
ln -s /bin/sleep "$FAKE_HOME/$BINNAME" 2>/dev/null || { echo "INFRA: cannot symlink /bin/sleep" >&2; exit 3; }
"$FAKE_HOME/$BINNAME" 120 &
FAKE_PID=$!
sleep 0.3
kill -0 "$FAKE_PID" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }

# Counter + string, NOT a bash array: this repo runs on macOS bash 3.2, where `${#arr[@]}` on an
# EMPTY array under `set -u` aborts with "unbound variable" — i.e. the all-assertions-passed path is
# exactly the one that would crash. Same class of bash-3.2 trap the sibling run-all.sh documents.
FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

# --- A1 — does ps report a comm containing "claude"? --------------------------------------------
COMM="$(ps -p "$FAKE_PID" -o comm= 2>/dev/null | tr -d ' ')"
case "$COMM" in
  *claude*) ;;
  *) fail "A1 expected ps comm to contain 'claude', got '${COMM}'" ;;
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
  *) fail "A2 real script did not list the fixture window; output was: $(printf '%s' "$OUT" | head -3 | tr '\n' '|')" ;;
esac

# --- verdict ------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  if [ "$FAIL_N" -gt 0 ]; then
    echo "NEG-CONTROL OK: test correctly went RED with a non-claude binary (${FAIL_N} assertion(s) failed)"
    exit 0
  fi
  echo "NEG-CONTROL BROKEN: test stayed GREEN with a binary named '$BINNAME' - it proves nothing" >&2
  exit 1
fi

if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 03-fake-home-fixture" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

# Every value here must be STABLE across runs. A fingerprint is checked in, and this suite is
# triggered by a pre-commit hook on changes under this directory: a value that differs per run makes
# the suite dirty the very files that gate it, so the auto-sync stages them, the hook re-triggers,
# the run re-dirties them, and it never converges. This file used to record `ps_comm_observed`
# verbatim - which embeds that run's mktemp path - and did exactly that. Record the DERIVED FACT the
# assumption is about, never a per-run path, pid, timestamp, hostname, or run id.
COMM_IS_BASENAME=false;      case "$COMM" in claude) COMM_IS_BASENAME=true ;; esac
COMM_IS_ABSOLUTE_PATH=false; case "$COMM" in /*)     COMM_IS_ABSOLUTE_PATH=true ;; esac
COMM_ENDS_IN_BINNAME=false;  case "$COMM" in *"/${BINNAME}"|"${BINNAME}") COMM_ENDS_IN_BINNAME=true ;; esac
UNAME_S="$(uname -s)"
OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"

cat > "${HERE}/03-fake-home-fixture.fingerprint.json" <<EOF
{"assumption":"hermetic_fixture_satisfies_liveness_check","uname":"${UNAME_S}","os_version":"${OS_VERSION}","comm_is_basename":${COMM_IS_BASENAME},"comm_is_absolute_path":${COMM_IS_ABSOLUTE_PATH},"comm_ends_in_fixture_binary_name":${COMM_ENDS_IN_BINNAME},"real_script_listed_the_fixture_window":true}
EOF
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "${HERE}/03-fake-home-fixture.fingerprint.json" \
  || { echo "FAIL: 03-fake-home-fixture wrote an unparseable fingerprint file" >&2; exit 1; }

echo "PASS: 03-fake-home-fixture — 2 assertions (A1 ps-comm, A2 real-script-lists-fixture)"
exit 0
