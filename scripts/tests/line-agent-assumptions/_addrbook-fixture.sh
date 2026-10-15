#!/usr/bin/env bash
# _addrbook-fixture.sh - shared sandbox for the address-book tests (11-13). Sourced, never run:
# run-all.sh only runs the files listed in its TESTS array.
#
# Builds: a fake HOME with ONE live "window" (a /bin/sleep symlinked as `claude`, like 10's fixture)
# and its registry entry; a fake .claude.json carrying a fake account id and a fake email (both
# must never appear in a published file); and a fake shared folder via LAC_WINDOWS_DIR, so nothing
# touches the real iCloud Drive. This Mac plays host "test-mac-a" (LAC_HOST_ID).
#
# Exposes: ROOT FAKE_HOME WIN_DIR SID ENTRY FAKE_PID FIX_CWD FAKE_EMAIL FAKE_ACCOUNT SCRIPT
#          run_lac <argv...>  (sets RC/OUT; bounded by a perl alarm, so a hang is a FAIL not a stall)
#          fail <msg>, FAIL_N, FAIL_MSGS
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

REAL_SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$REAL_SCRIPT" ] || { echo "INFRA: script not found: $REAL_SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }
command -v perl >/dev/null 2>&1 || { echo "INFRA: perl missing" >&2; exit 3; }

MARKER="lac-atest"
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "INFRA: mktemp -d failed; refusing to run unsandboxed" >&2; exit 3; }
FAKE_HOME="$ROOT/home"
WIN_DIR="$ROOT/icloud/claude-windows"
FAKE_PID=""
cleanup() {
  { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; } 2>/dev/null
  chmod -R u+rwx "$ROOT" 2>/dev/null
  rm -rf "$ROOT" 2>/dev/null || echo "CLEANUP WARNING: could not remove $ROOT" >&2
}
trap cleanup EXIT
mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status" "$WIN_DIR" "$ROOT/bin"

# brctl stub: a placeholder read asks iCloud to download; the real brctl must never be driven here.
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/brctl"
chmod +x "$ROOT/bin/brctl"

FAKE_EMAIL="fixture-owner@example.invalid"
FAKE_ACCOUNT="0f0f0f0f-1111-4222-8333-${RUN_ID}"
python3 - "$FAKE_HOME/.claude.json" "$FAKE_ACCOUNT" "$FAKE_EMAIL" <<'PY'
import json, sys
json.dump({"oauthAccount": {"accountUuid": sys.argv[2], "emailAddress": sys.argv[3]}}, open(sys.argv[1], "w"))
PY

ln -s /bin/sleep "$FAKE_HOME/claude" 2>/dev/null || { echo "INFRA: cannot symlink /bin/sleep" >&2; exit 3; }
"$FAKE_HOME/claude" 300 &
FAKE_PID=$!
sleep 0.3
kill -0 "$FAKE_PID" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }

PROC_START="$(ps -o lstart= -p "$FAKE_PID" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
SID="00000000-0000-4000-8000-${RUN_ID}"
ENTRY="$FAKE_HOME/.claude/sessions/${FAKE_PID}.json"
FIX_CWD="/Users/fixture-nobody/Developer/secret-client-folder/summit"
python3 - "$ENTRY" "$FAKE_PID" "$SID" "$PROC_START" "$FIX_CWD" <<'PY'
import json, sys, time
path, pid, sid, procstart, cwd = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
json.dump({
    "pid": pid, "sessionId": sid, "cwd": cwd,
    "startedAt": int(time.time() * 1000), "procStart": procstart,
    "version": "2.1.228", "name": "summit-zq", "nameSource": "derived",
    "status": "idle", "updatedAt": int(time.time() * 1000),
}, open(path, "w"), separators=(",", ":"))
PY

FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

SCRIPT="${SCRIPT:-$REAL_SCRIPT}"
LAC_ALARM="${LAC_ALARM:-30}"  # generous: a loaded machine must not read as a hang
# run_lac <argv...> -> RC, OUT, ELAPSED. Bounded: a hang returns RC=142 (SIGALRM) instead of stalling.
run_lac() {
  local t0 t1
  t0=$(python3 -c 'import time;print(time.time())')
  OUT="$(HOME="$FAKE_HOME" CLAUDE_SESSION_ID="$SID" PATH="$ROOT/bin:$PATH" \
         LAC_WINDOWS_DIR="$WIN_DIR" LAC_HOST_ID="test-mac-a" LAC_HOST_LABEL="Test Mac A" \
         LAC_NO_AUTOPUBLISH="${LAC_NO_AUTOPUBLISH:-1}" LAC_REMOTE_READ_TIMEOUT="${LAC_REMOTE_READ_TIMEOUT:-1}" \
         perl -e 'alarm shift; exec @ARGV' "$LAC_ALARM" python3 "$SCRIPT" "$@" 2>&1)"
  RC=$?
  t1=$(python3 -c 'import time;print(time.time())')
  ELAPSED=$(python3 -c "print(round($t1 - $t0, 2))")
}

# write_host <host-id> <label> <heartbeat-epoch> <account-hash> <json windows array>
write_host() {
  python3 - "$WIN_DIR/$1.json" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys, time
path, hid, label, hb, acct, wins = sys.argv[1:7]
iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(hb)))
json.dump({"format": 1, "host": hid, "host_label": label, "updated_at": iso, "heartbeat_at": iso,
           "account_hash": acct, "windows": json.loads(wins)}, open(path, "w"), indent=2)
PY
}

# our_hash -> the account_hash this fixture's Mac publishes (read from its own published file)
our_hash() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['account_hash'])" "$WIN_DIR/test-mac-a.json"; }
