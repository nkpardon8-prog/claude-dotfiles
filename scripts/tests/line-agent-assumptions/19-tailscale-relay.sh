#!/usr/bin/env bash
# 19 - Does a window on the OTHER Mac resolve to an address that actually delivers?
#
# 2026-10-16: iCloud stopped delivering the MacBook's address book to the Mac mini (a dataless
# placeholder `brctl download` called nonexistent), and Remote Control titles of reopened MacBook
# windows never updated, so from the mini neither `find patients-tab` nor SendMessage("patients-tab")
# reached the window. Two fixes are proven here, on two sandboxed "Macs" (A = MacBook, B = mini)
# whose iCloud folders share NOTHING - the failure state:
#
# R1  A's publish relays its book to B over "ssh" (a stub that runs B's real `relay-exchange`)
# R2  ...and brings B's book back to A in the same round trip
# R3  on B, `find` for A's window prints `SendMessage to: bridge:<A's session id>` - the bridge
#     address, which reaches the window whatever its Remote Control title says
# R4  while the relay is fresh, an (older) copy of A's book arriving via iCloud never replaces it
# R5  `relay-exchange` refuses a book claiming to be B itself (cache untouched, ok:false)
# R6  in a sandbox with no LAC_RELAY_HOST, publish never runs ssh at all
# R7  ssh failing: publish still exits 0, and the failure is logged, not silent
# R8  the MacBook starts the relay even when its rdocker config has no "host" key; the mini never does
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): make send_address() ignore the bridge. R3 must go red.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

REAL_SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$REAL_SCRIPT" ] || { echo "INFRA: script not found: $REAL_SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

MARKER="lac-atest"
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "INFRA: mktemp -d failed; refusing to run unsandboxed" >&2; exit 3; }
PIDS_FILE="$ROOT/pids"
cleanup() {
  # Braces + 2>/dev/null: otherwise the shell prints a "Terminated: 15" job notice under the verdict.
  for p in $(cat "$PIDS_FILE" 2>/dev/null); do { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; } 2>/dev/null; done
  rm -rf "$ROOT" 2>/dev/null || echo "CLEANUP WARNING: could not remove $ROOT" >&2
}
trap cleanup EXIT
mkdir -p "$ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/brctl"; chmod +x "$ROOT/bin/brctl"

SCRIPT="$REAL_SCRIPT"
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  cp "$REAL_SCRIPT" "$SCRIPT"
  python3 - "$SCRIPT" <<'PY' || { echo "INFRA: neg-control anchor moved" >&2; exit 3; }
import sys
p = sys.argv[1]
s = open(p).read()
a = '    return f"bridge:{b}" if b else w.get("address", "")\n'
if a not in s:
    sys.exit(3)
open(p, "w").write(s.replace(a, '    return w.get("address", "")\n', 1))
PY
fi

ACCOUNT="0f0f0f0f-1111-4222-8333-${RUN_ID}"
# mac <name> <host-id> <window-name> <caption> <bridge-id>: a fake Mac with one live window.
mac() {
  local home="$ROOT/$1/home"
  mkdir -p "$home/.claude/sessions" "$home/.claude/session-status" "$ROOT/$1/icloud" "$ROOT/$1/cache"
  python3 -c 'import json,sys; json.dump({"oauthAccount":{"accountUuid":sys.argv[2],"emailAddress":"x@example.invalid"}},open(sys.argv[1],"w"))' \
    "$home/.claude.json" "$ACCOUNT"
  ln -s /bin/sleep "$home/claude" 2>/dev/null || { echo "INFRA: cannot symlink /bin/sleep" >&2; exit 3; }
  "$home/claude" 300 >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" >> "$PIDS_FILE"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }
  local start; start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  local sid="00000000-0000-4000-8000-${1:0:1}${RUN_ID:1}"
  python3 - "$home/.claude/sessions/${pid}.json" "$pid" "$sid" "$start" "$3" "$5" <<'PY'
import json, sys, time
path, pid, sid, procstart, name, bridge = sys.argv[1], int(sys.argv[2]), *sys.argv[3:]
json.dump({"pid": pid, "sessionId": sid, "cwd": "/Users/nobody/dentall",
           "startedAt": int(time.time() * 1000), "procStart": procstart, "version": "2.1.302",
           "peerProtocol": 1, "kind": "interactive", "entrypoint": "cli", "name": name,
           "nameSource": "explicit", "status": "idle", "updatedAt": int(time.time() * 1000),
           "bridgeSessionId": bridge}, open(path, "w"), separators=(",", ":"))
PY
  printf '%s\n' "$4" > "$home/.claude/session-status/${sid}.txt"
}
BRIDGE_A="session_01AAAA${RUN_ID}"
BRIDGE_B="session_01BBBB${RUN_ID}"
mac laptop "fake-laptop" "front-desk" "front desk" "$BRIDGE_A" || exit 3
mac mini "fake-mini" "billing-desk" "billing desk" "$BRIDGE_B" || exit 3

# Run the script as one of the two Macs.
as() {  # as <laptop|mini> <args...>
  local m="$1"; shift
  HOME="$ROOT/$m/home" LAC_HOST_ID="fake-$m" LAC_HOST_LABEL="fake $m" \
    LAC_WINDOWS_DIR="$ROOT/$m/icloud" LAC_CACHE_DIR="$ROOT/$m/cache" LAC_NO_AUTOPUBLISH=1 \
    PATH="$ROOT/bin:$PATH" python3 "$SCRIPT" "$@"
}
# The ssh stub: records that it ran, then plays the mini's side with the real script.
cat > "$ROOT/bin/ssh" <<EOF
#!/bin/bash
echo "ran" >> "$ROOT/ssh-trace"
[ -n "\${SSH_STUB_FAIL:-}" ] && { echo "ssh: connect to host stub port 22: Connection refused" >&2; exit 255; }
case "\${@: -1}" in *relay-exchange*) ;; *) echo "stub: unexpected remote command" >&2; exit 99 ;; esac
HOME="$ROOT/mini/home" LAC_HOST_ID=fake-mini LAC_HOST_LABEL="fake mini" LAC_WINDOWS_DIR="$ROOT/mini/icloud" \\
  LAC_CACHE_DIR="$ROOT/mini/cache" LAC_NO_AUTOPUBLISH=1 PATH="$ROOT/bin:\$PATH" python3 "$SCRIPT" relay-exchange
EOF
chmod +x "$ROOT/bin/ssh"

FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }
host_of() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("host",""))
except Exception: print("")' "$1"; }

# The mini has published its own book (as its statusline would); the laptop has not met it.
as mini publish >/dev/null 2>&1
[ "$(host_of "$ROOT/mini/cache/fake-mini.json")" = "fake-mini" ] || { echo "INFRA: mini publish wrote no book" >&2; exit 3; }

# R6 first: no LAC_RELAY_HOST in a sandbox -> no ssh at all
as laptop publish >/dev/null 2>&1
[ ! -e "$ROOT/ssh-trace" ] || fail "R6: publish ran ssh in a sandbox with no LAC_RELAY_HOST"

# R1 + R2
LAC_RELAY_HOST=stub-mini as laptop publish >/dev/null 2>&1
[ -e "$ROOT/ssh-trace" ] || fail "R1: publish never ran ssh with LAC_RELAY_HOST set"
[ "$(host_of "$ROOT/mini/cache/fake-laptop.json")" = "fake-laptop" ] || fail "R1: the mini did not receive the laptop's book"
[ "$(host_of "$ROOT/laptop/cache/fake-mini.json")" = "fake-mini" ] || fail "R2: the laptop did not get the mini's book back"
[ ! -e "$ROOT/mini/icloud/fake-laptop.json" ] || fail "R1: fixture check - the laptop book leaked into the mini's iCloud folder"

# R3: from the mini, the laptop window resolves to its bridge address
OUT="$(as mini find "front desk" 2>&1)"
case "$OUT" in
  *"SendMessage to: bridge:${BRIDGE_A}"*) ;;
  *) fail "R3: mini's find did not hand out the bridge address; got: $(printf '%s' "$OUT" | grep -m1 'SendMessage to' || echo none)" ;;
esac

# R4: an older laptop book shows up in the mini's iCloud folder; the relayed one must survive
python3 - "$ROOT/mini/cache/fake-laptop.json" "$ROOT/mini/icloud/fake-laptop.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["heartbeat_at"] = "2026-01-01T00:00:00Z"
d["windows"] = []
json.dump(d, open(sys.argv[2], "w"))
PY
as mini publish >/dev/null 2>&1
N="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["windows"]))' "$ROOT/mini/cache/fake-laptop.json")"
[ "$N" = "1" ] || fail "R4: an iCloud copy replaced the freshly relayed book (windows now $N)"

# R5: a book claiming to be the mini itself is refused
BEFORE="$(shasum "$ROOT/mini/cache/fake-mini.json" | awk '{print $1}')"
R5="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));d["windows"]=[];print(json.dumps(d))' "$ROOT/mini/cache/fake-mini.json" \
      | as mini relay-exchange 2>/dev/null)"
case "$R5" in *'"ok": false'*) ;; *) fail "R5: relay-exchange accepted a book claiming to be itself" ;; esac
[ "$(shasum "$ROOT/mini/cache/fake-mini.json" | awk '{print $1}')" = "$BEFORE" ] || fail "R5: the mini's own book was overwritten"

# R7: ssh fails -> exit 0 + logged
SSH_STUB_FAIL=1 LAC_RELAY_HOST=stub-mini as laptop publish >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] || fail "R7: publish exited $RC when ssh failed"
grep -q "relay via stub-mini failed" "$ROOT/laptop/cache/windows-publish.log" 2>/dev/null \
  || fail "R7: the ssh failure was not logged"

# R8: which Mac starts the relay. rdocker's config.json holds only OVERRIDES, so a MacBook whose
# config has no "host" key still uses rdocker's default alias - reading that as "no relay" made the
# real MacBook skip silently (2026-10-16). A Mac with no rdocker login at all (the mini) stays off.
target_for() {  # target_for <home> -> relay_target() under that HOME, sandbox variables unset
  env -u LAC_WINDOWS_DIR -u LAC_CACHE_DIR -u LAC_RELAY_HOST HOME="$1" python3 - "$SCRIPT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lac", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.relay_target())
PY
}
mkdir -p "$ROOT/r8-laptop/.config/rdocker" "$ROOT/r8-mini"
printf '{"mode": "auto"}\n' > "$ROOT/r8-laptop/.config/rdocker/config.json"
[ "$(target_for "$ROOT/r8-laptop")" = "macmini-docker" ] \
  || fail "R8: an rdocker config without a host key did not fall back to macmini-docker (got '$(target_for "$ROOT/r8-laptop")')"
[ -z "$(target_for "$ROOT/r8-mini")" ] || fail "R8: a Mac with no rdocker login would start the relay"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  case "$FAIL_MSGS" in
    *"R3: mini's find did not hand out the bridge address"*)
      echo "NEG-CONTROL OK: with the bridge address dropped, R3 went RED"; exit 0 ;;
  esac
  echo "NEG-CONTROL BROKEN: R3 stayed green against a script that never hands out the bridge" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 19-tailscale-relay" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi
echo "PASS: 19-tailscale-relay - 8 assertions (R1-R2 round trip, R3 bridge address, R4 relay copy kept, R5 self-claim refused, R6 sandbox no-ssh, R7 failure logged, R8 who starts it)"
exit 0
