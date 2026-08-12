#!/usr/bin/env bash
# 05 — Does the liveness check over-match on a path substring?
#
# pid_alive() runs `ps -p <pid> -o comm=` and accepts the pid if `"claude" in out.stdout.lower()`.
# On macOS `comm` is the FULL PATH the process was exec'd from, not the basename - so the test is
# really "is this process running from anywhere under a path containing the letters c-l-a-u-d-e".
# A pid recycled onto any binary living under ~/claude-something, /opt/claude-tools, a checkout named
# claude-dotfiles - anything - passes as a live Claude window. The registry then presents a stranger's
# process as a messageable peer, and the failure is silent: the directory looks healthy.
#
# A1 — a process running from a path that CONTAINS "claude" but is NOT a claude window must NOT be
#      reported as a live window by the REAL script. The fixture is /bin/sleep symlinked to
#      "$FAKE_HOME/zzsleep" with $FAKE_HOME placed under a directory literally named `claude-decoy`.
# A2 — POSITIVE CONTROL, added 2026-08-12: the same run must exit 0 and print the directory TABLE
#      with a REAL live window in it (`atest-real`, a verbatim copy of a live registry entry). A1 on
#      its own only asserts an ABSENCE, and it captured 2>&1 - so a python traceback, or any change
#      that made `list` show nothing at all, satisfied it. "The defect is gone" and "the feature is
#      gone" have to be distinguishable, and only a positive control does that.
#
# A1 was authored RED as the pre-implementation gate for tightening the liveness check (basename
# match, or corroboration against startedAt/procStart). The tightening shipped; this file is the
# regression catcher for it now.
#
# NEGATIVE CONTROL: put the SAME binary, with the SAME registry entry, under a parent directory whose
# name contains no "claude" (`decoy-only`) and confirm the script agrees it is not a window. That
# proves the assertion mechanism can distinguish listed from not-listed, so A1's verdict is the
# script's behavior and not a broken probe. Run it with LINE_AGENT_NEG_CONTROL=true.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$SCRIPT" ] || { echo "INFRA: script not found: $SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="lac-atest"                       # stable namespace marker, for the orphan reaper
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
# The ONLY difference between the test and its control. Neither name may contain "claude" by
# accident, and the marker `lac-atest` deliberately does not either.
DECOY_DIR="claude-decoy"; [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ] && DECOY_DIR="decoy-only"

# --- startup orphan reaper: `finally` does not survive SIGKILL, so reap prior crashed runs -------
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
FAKE_HOME="$ROOT/$DECOY_DIR/home"
FAKE_PID=""

cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  rm -rf "$ROOT" 2>/dev/null || echo "CLEANUP WARNING: could not remove $ROOT" >&2
}
trap cleanup EXIT

mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status"

# SYMLINK, not copy: macOS SIGKILLs a copied system binary on exec (code-signature check) -
# `cp /bin/sleep .../zzsleep` dies instantly with "Killed: 9". A symlink keeps the original signed
# inode while presenting our name, and our PATH, on the exec path that ps reports.
ln -s /bin/sleep "$FAKE_HOME/zzsleep" 2>/dev/null || { echo "INFRA: cannot symlink /bin/sleep" >&2; exit 3; }
"$FAKE_HOME/zzsleep" 120 &
FAKE_PID=$!
sleep 0.3
kill -0 "$FAKE_PID" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }

# On macOS `ps -o comm=` returns the FULL PATH, not the basename. Record what it actually says, since
# the whole assumption hinges on it.
COMM="$(ps -p "$FAKE_PID" -o comm= 2>/dev/null | sed 's/^ *//;s/ *$//')"
echo "ps -o comm= for the decoy process: ${COMM}"
case "$COMM" in
  */zzsleep) ;;
  *) echo "INFRA: unexpected comm for the decoy ('${COMM}') - fixture is not what this test assumes" >&2; exit 3 ;;
esac

PROC_START="$(ps -o lstart= -p "$FAKE_PID" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
SID="00000000-0000-4000-8000-${RUN_ID}"
python3 - "$FAKE_HOME" "$FAKE_PID" "$SID" "$PROC_START" <<'PY'
import json, os, sys, time
home, pid, sid, procstart = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
entry = {
    "pid": pid, "sessionId": sid, "cwd": home,
    "startedAt": int(time.time() * 1000), "procStart": procstart,
    "version": "2.1.228", "peerProtocol": 1, "kind": "interactive",
    "entrypoint": "cli", "name": "atest-decoy", "nameSource": "explicit",
    "status": "idle", "updatedAt": int(time.time() * 1000), "bridgeSessionId": None,
}
with open(os.path.join(home, ".claude", "sessions", f"{pid}.json"), "w") as fh:
    json.dump(entry, fh, separators=(",", ":"))
with open(os.path.join(home, ".claude", "session-status", f"{sid}.txt"), "w") as fh:
    fh.write("atest decoy window\n")
PY

# --- the positive control's fixture: one REAL live window, copied verbatim ------------------------
# Without this the fake $HOME contains nothing but the decoy, and "decoy correctly excluded" is
# indistinguishable from "list printed nothing at all".
REAL_SESSIONS="$HOME/.claude/sessions"
POS_SETUP="$(python3 - "$FAKE_HOME" "$REAL_SESSIONS" <<'PY'
import glob, json, os, subprocess, sys
fake, real = sys.argv[1], sys.argv[2]
for f in sorted(glob.glob(os.path.join(real, "*.json"))):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    pid = d.get("pid")
    if not isinstance(pid, int) or not pid:
        continue
    r = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
    if r.returncode != 0 or "claude" not in r.stdout.lower():
        continue
    d["sessionId"] = "00000000-0000-4000-8000-cccccccccccc"
    d["name"] = "atest-real"
    d["nameSource"] = "explicit"
    with open(os.path.join(fake, ".claude", "sessions", "%d.json" % pid), "w") as fh:
        json.dump(d, fh, separators=(",", ":"))
    print("OK pid=%d" % pid)
    break
else:
    print("NONE")
PY
)"
case "$POS_SETUP" in
  OK*) ;;
  *) echo "INFRA: no live claude window to build the positive control from (${POS_SETUP})" >&2; exit 3 ;;
esac
echo "positive-control fixture: ${POS_SETUP} (a verbatim live window named atest-real)"

# Counter + string, NOT a bash array: this repo runs on macOS bash 3.2, where `${#arr[@]}` on an
# EMPTY array under `set -u` aborts with "unbound variable" — i.e. the all-assertions-passed path is
# exactly the one that would crash. Same class of bash-3.2 trap the sibling run-all.sh documents.
FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

# --- A1 — the REAL script must not call a non-claude process a live window -------------------------
# Ask the script itself, never a bash reimplementation of its rule - a reimplementation stays green
# after the real defense is deleted.
# stdout and stderr are captured SEPARATELY: merging them is how a traceback used to masquerade as a
# clean "decoy absent" result. The exit code and the table header are asserted below (A2).
OUT="$(HOME="$FAKE_HOME" python3 "$SCRIPT" list 2>"$ROOT/list.err")"
RC=$?
ERR="$(cat "$ROOT/list.err" 2>/dev/null)"
LISTED="no"
case "$OUT" in
  *atest-decoy*) LISTED="yes" ;;
esac
REAL_LISTED="no"
case "$OUT" in
  *atest-real*) REAL_LISTED="yes" ;;
esac
HEADER="no"
case "$OUT" in
  *"ADDRESS"*"WHAT IT IS"*"CAN RECEIVE"*) HEADER="yes" ;;
esac
echo "decoy parent directory: ${DECOY_DIR}   ->   script lists it as a live window: ${LISTED}"
echo "positive control: exit=${RC}  table header printed=${HEADER}  real window listed=${REAL_LISTED}"

# --- A2 — the positive control, asserted in BOTH modes ---------------------------------------------
[ "$RC" = "0" ] || fail "A2 the script exited ${RC} instead of 0; stderr: $(printf '%s' "$ERR" | head -2 | tr '\n' ' ')"
[ -z "$ERR" ] || fail "A2 the script wrote to stderr: $(printf '%s' "$ERR" | head -2 | tr '\n' ' ')"
[ "$HEADER" = "yes" ] || fail "A2 the script printed no directory table - 'decoy absent' would be vacuous"
[ "$REAL_LISTED" = "yes" ] || fail "A2 the script did not list the REAL live window (atest-real) - it is excluding everything, not just the decoy"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  if [ "$FAIL_N" -gt 0 ]; then
    echo "NEG-CONTROL INCONCLUSIVE: the positive control itself failed" >&2
    printf '%s' "$FAIL_MSGS" >&2
    exit 1
  fi
  if [ "$LISTED" = "no" ]; then
    echo "NEG-CONTROL OK: with no 'claude' anywhere in the exec path the script agrees it is not a window"
    echo "  (so the not-listed observation is real, and A1's verdict is the script's behavior)"
    exit 0
  fi
  echo "NEG-CONTROL BROKEN: script listed a decoy under '${DECOY_DIR}' too - the probe cannot tell listed from not-listed" >&2
  exit 1
fi

if [ "$LISTED" = "yes" ]; then
  fail "A1 script reported a non-claude process under a 'claude'-containing path as a live window"
  echo "REGRESSION: substring match on the full ps path - any process under a claude-containing path is judged a live window"
  echo "--- real script output ---"
  printf '%s\n' "$OUT" | sed 's/^/    /'
  echo "-------------------------"
fi

# --- verdict --------------------------------------------------------------------------------------
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 05-comm-overmatch" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

# Computed BEFORE the heredoc, deliberately. A `$(case ... esac)` inside a heredoc does not parse,
# and under `set -uo pipefail` (no -e) that parse failure is NON-FATAL: the test printed PASS and
# exited 0 while leaving a syntactically corrupt fingerprint file on disk. Green-on-crash is worse
# than red. Keep every substitution in a heredoc trivial.
COMM_IS_FULL_PATH=false
case "$COMM" in /*) COMM_IS_FULL_PATH=true ;; esac
UNAME_S="$(uname -s)"
OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"

cat > "${HERE}/05-comm-overmatch.fingerprint.json" <<EOF
{"assumption":"liveness_check_does_not_overmatch_on_path_substring","uname":"${UNAME_S}","os_version":"${OS_VERSION}","ps_comm_observed":"${COMM}","comm_is_full_path":${COMM_IS_FULL_PATH},"decoy_parent_dir":"${DECOY_DIR}","listed_as_live_window":false,"positive_control_real_window_listed":true,"positive_control_exit_code":0}
EOF
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "${HERE}/05-comm-overmatch.fingerprint.json" \
  || { echo "FAIL: 05-comm-overmatch wrote an unparseable fingerprint file" >&2; exit 1; }

echo "PASS: 05-comm-overmatch - 2 assertions (A1 claude-containing path is not a live window, A2 positive control: exit 0 + table + real window listed)"
exit 0
