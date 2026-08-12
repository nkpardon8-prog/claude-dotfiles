#!/usr/bin/env bash
# 04 — Is "CAN RECEIVE: YES" reachability, or just file existence?
#
# `list` is a directory an agent acts on: it says YES and the agent sends. That promise is only worth
# something if YES means a listener is actually bound. The current implementation ends its reachable()
# check at `Path(sock).exists()`, and a unix socket file OUTLIVES the process that bound it - nothing
# unlinks it when a window is SIGKILLed or the machine loses power. So an orphaned inode keeps
# advertising a dead window as messageable, and the send fails at the far end where nobody is looking.
# This is the silent-wrong-answer direction, which is the one worth a gate.
#
# A1 — while a real listener is bound to the socket, the REAL script reports the window reachable.
# A2 — kill the listener but LEAVE the socket file on disk; the script must report NOT reachable.
#
# A2 IS EXPECTED TO FAIL TODAY. That is the point: this file is the pre-implementation gate for the
# reachability fix and the regression catcher after it. It exits 1 either way so it cannot be
# mistaken for green, and prints the observed behavior explicitly in both directions.
#
# NEGATIVE CONTROL: A1 and A2 are each other's control - the ONLY difference between them is whether
# a process holds the socket, so a comparator stuck at "always YES" fails A2 and one stuck at
# "always no" fails A1. To exercise the A1 side deliberately, run with LINE_AGENT_NEG_CONTROL=true:
# it never binds a listener and unlinks the socket path, so A1 must go RED. If A1 stays green with no
# socket at all, A1 is observing nothing.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$SCRIPT" ] || { echo "INFRA: script not found: $SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="lac-atest"                       # stable namespace marker, for the orphan reaper
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"

# --- startup orphan reaper: `finally` does not survive SIGKILL, so reap prior crashed runs -------
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
FAKE_PID=""
LISTEN_PID=""

cleanup() {
  [ -n "$LISTEN_PID" ] && kill "$LISTEN_PID" 2>/dev/null
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  rm -rf "$FAKE_HOME" 2>/dev/null || echo "CLEANUP WARNING: could not remove $FAKE_HOME" >&2
}
trap cleanup EXIT

mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status"
SOCK="$FAKE_HOME/msg.sock"
# sun_path is 104 bytes on macOS; a long TMPDIR silently truncates the bind target, which would make
# A1 fail for a reason that has nothing to do with the assumption under test.
[ "${#SOCK}" -lt 100 ] || { echo "INFRA: socket path too long for AF_UNIX (${#SOCK} bytes): $SOCK" >&2; exit 3; }

# A real process whose comm looks like claude. SYMLINK, not copy: macOS SIGKILLs a copied system
# binary on exec (code-signature check) - `cp /bin/sleep .../claude` dies instantly with "Killed: 9".
# A symlink keeps the original signed inode while presenting our name on the exec path.
ln -s /bin/sleep "$FAKE_HOME/claude" 2>/dev/null || { echo "INFRA: cannot symlink /bin/sleep" >&2; exit 3; }
"$FAKE_HOME/claude" 120 &
FAKE_PID=$!
sleep 0.3
kill -0 "$FAKE_PID" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }

PROC_START="$(ps -o lstart= -p "$FAKE_PID" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
SID="00000000-0000-4000-8000-${RUN_ID}"
python3 - "$FAKE_HOME" "$FAKE_PID" "$SID" "$PROC_START" "$SOCK" <<'PY'
import json, os, sys, time
home, pid, sid, procstart, sock = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
entry = {
    "pid": pid, "sessionId": sid, "cwd": home,
    "startedAt": int(time.time() * 1000), "procStart": procstart,
    # >= 2.1.224 or reachable() short-circuits on the version gate and never looks at the socket.
    "version": "2.1.228", "peerProtocol": 1, "kind": "interactive",
    "entrypoint": "cli", "name": "atest-sockwin", "nameSource": "explicit",
    "status": "idle", "updatedAt": int(time.time() * 1000), "bridgeSessionId": None,
    "messagingSocketPath": sock,
}
with open(os.path.join(home, ".claude", "sessions", f"{pid}.json"), "w") as fh:
    json.dump(entry, fh, separators=(",", ":"))
with open(os.path.join(home, ".claude", "session-status", f"{sid}.txt"), "w") as fh:
    fh.write("atest socket window\n")
PY

# Counter + string, NOT a bash array: this repo runs on macOS bash 3.2, where `${#arr[@]}` on an
# EMPTY array under `set -u` aborts with "unbound variable" — i.e. the all-assertions-passed path is
# exactly the one that would crash. Same class of bash-3.2 trap the sibling run-all.sh documents.
FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

# Ask the REAL script, never a bash reimplementation of its rules - a reimplementation stays green
# after the real defense is deleted. --json is the same reachable() code path that fills the
# CAN RECEIVE column; we parse it instead of the table so the assertion cannot drift with formatting.
probe_reachable() {  # -> prints "true" / "false" / "missing"
  HOME="$FAKE_HOME" python3 "$SCRIPT" list --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("missing"); sys.exit(0)
for r in d.get("live", []):
    if r.get("sessionId") == sys.argv[1]:
        print("true" if r.get("reachable") else "false"); sys.exit(0)
print("missing")
' "$SID"
}

# --- A1 — a real bound listener means reachable ----------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" != "true" ]; then
  python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1]); s.listen(1)
time.sleep(120)
' "$SOCK" &
  LISTEN_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.2; done
  [ -S "$SOCK" ] || { echo "INFRA: listener never bound $SOCK" >&2; exit 3; }
else
  rm -f "$SOCK"   # neg control: no listener, no socket file at all
fi

A1="$(probe_reachable)"
echo "A1 (listener bound): script reports reachable=${A1}"
[ "$A1" = "true" ] || fail "A1 expected reachable=true with a live bound listener, got '${A1}'"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  if [ "$FAIL_N" -gt 0 ]; then
    echo "NEG-CONTROL OK: A1 correctly went RED with no socket bound (${FAIL_N} assertion(s) failed)"
    exit 0
  fi
  echo "NEG-CONTROL BROKEN: A1 stayed GREEN with no socket at all - it observes nothing" >&2
  exit 1
fi

# --- A2 — an ORPHANED socket file must NOT count as reachable --------------------------------------
kill "$LISTEN_PID" 2>/dev/null
wait "$LISTEN_PID" 2>/dev/null
LISTEN_PID=""
[ -S "$SOCK" ] || { echo "INFRA: socket file vanished with the listener - cannot test the orphan case" >&2; exit 3; }

A2="$(probe_reachable)"
echo "A2 (listener dead, socket file left on disk): script reports reachable=${A2}"
if [ "$A2" != "false" ]; then
  fail "A2 expected reachable=false for an orphaned socket, got '${A2}'"
  echo "KNOWN DEFECT (pre-fix): reachable() is file-existence, not reachability - orphaned socket advertises a dead window as messageable"
fi

# The human-readable table, so the CAN RECEIVE column is on the record next to the parsed verdict.
echo "--- real script output at the orphaned-socket moment ---"
HOME="$FAKE_HOME" python3 "$SCRIPT" list 2>&1 | sed 's/^/    /'
echo "-------------------------------------------------------"

# --- verdict --------------------------------------------------------------------------------------
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 04-stale-socket-reachability" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

cat > "${HERE}/04-stale-socket-reachability.fingerprint.json" <<EOF
{"assumption":"reachable_means_a_listener_is_bound","uname":"$(uname -s)","os_version":"$(sw_vers -productVersion 2>/dev/null || echo unknown)","reachable_with_listener":"${A1}","reachable_with_orphaned_socket":"${A2}","socket_file_outlives_listener":true}
EOF

echo "PASS: 04-stale-socket-reachability - 2 assertions (A1 bound listener reachable, A2 orphaned socket NOT reachable)"
exit 0
