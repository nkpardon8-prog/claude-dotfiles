#!/usr/bin/env bash
# 20 - Can an agent just SendMessage a NAME on the other Mac?
#
# Agents (and the owner) send by name. Across Macs that name resolves only through the window's
# Remote Control title, which a reopened window never updates (2026-10-16), so SendMessage
# ("patients-tab") from the mini failed. `route-send` is a PreToolUse hook on SendMessage that swaps
# such a name for the window's bridge address - and must touch NOTHING else.
#
# S1  another Mac's window by address          -> rewritten to bridge:<id>, message/summary kept
# S2  the same window by its caption ("front desk") -> rewritten
# S3  a name a window on THIS Mac holds        -> unchanged (local delivery works)
# S4  an explicit bridge:/uds: address         -> unchanged
# S5  a name two other-Mac windows share       -> unchanged (never guess between two)
# S6  a window on a Mac that looks asleep      -> unchanged
# S7  a matching window with no bridge id      -> unchanged
# S8  garbage stdin                            -> exit 0, no output (never blocks a send)
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): drop the this-Mac check. S3 must go red.
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
trap 'rm -rf "$ROOT" 2>/dev/null' EXIT
FAKE_HOME="$ROOT/home"
CACHE="$ROOT/cache"
mkdir -p "$FAKE_HOME/.claude/sessions" "$ROOT/icloud" "$CACHE"

SCRIPT="$REAL_SCRIPT"
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  cp "$REAL_SCRIPT" "$SCRIPT"
  python3 - "$SCRIPT" <<'PY' || { echo "INFRA: neg-control anchor moved" >&2; exit 3; }
import sys
p = sys.argv[1]
s = open(p).read()
a = '        if any((d.get("name") or "").lower() == to.lower() for d in load_sessions()):\n            return 0\n'
if a not in s:
    sys.exit(3)
open(p, "w").write(s.replace(a, "", 1))
PY
fi

# This Mac: one registry entry holding "billing-desk".
printf '{"pid":1,"sessionId":"00000000-0000-4000-8000-%s","name":"billing-desk","nameSource":"explicit"}\n' \
  "$RUN_ID" > "$FAKE_HOME/.claude/sessions/1.json"

# Other Macs, as the relay would have cached them.
python3 - "$CACHE" "$RUN_ID" <<'PY'
import json, sys, time
cache, run = sys.argv[1], sys.argv[2]
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def win(addr, caption, bridge):
    return {"address": addr, "caption": caption, "label": caption, "owns": "", "session_id": "s",
            "cwd_label": "dentall", "started_at": now, "can_receive": True, "named": True, "bridge": bridge}
def book(host, hb, windows):
    json.dump({"format": 1, "host": host, "host_label": host, "updated_at": hb, "heartbeat_at": hb,
               "account_hash": "", "windows": windows}, open(f"{cache}/{host}.json", "w"))
book("fake-laptop", now, [
    win("front-desk", "front desk", f"session_01FRONT{run}"),
    win("twin", "twin", f"session_01TWINA{run}"),
    win("billing-desk", "billing desk", f"session_01BILL{run}"),
    win("no-bridge", "no bridge", ""),
])
book("fake-other", now, [win("twin", "twin", f"session_01TWINB{run}")])
book("fake-asleep", "2026-01-01T00:00:00Z", [win("sleepy", "sleepy", f"session_01SLEEP{run}")])
PY

FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }
route() {  # route <to> -> ROUTED (new "to", or "" when unchanged), KEPT (message preserved?)
  local out
  out="$(printf '{"tool_name":"SendMessage","tool_input":{"to":%s,"message":"hello","summary":"s"}}' \
           "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
         | HOME="$FAKE_HOME" LAC_HOST_ID=fake-mini LAC_WINDOWS_DIR="$ROOT/icloud" LAC_CACHE_DIR="$CACHE" \
           python3 "$SCRIPT" route-send 2>/dev/null)"
  RC=$?
  ROUTED="$(python3 -c 'import json,sys
s=sys.stdin.read().strip()
print(json.loads(s)["hookSpecificOutput"]["updatedInput"]["to"] if s else "")' <<<"$out")"
  KEPT="$(python3 -c 'import json,sys
s=sys.stdin.read().strip()
print(json.loads(s)["hookSpecificOutput"]["updatedInput"].get("message","") if s else "")' <<<"$out")"
}

route "front-desk"
[ "$ROUTED" = "bridge:session_01FRONT${RUN_ID}" ] && [ "$KEPT" = "hello" ] \
  || fail "S1: front-desk -> '$ROUTED' (message '$KEPT'), expected the bridge address with the message kept"
route "front desk"
[ "$ROUTED" = "bridge:session_01FRONT${RUN_ID}" ] || fail "S2: caption form -> '$ROUTED'"
route "billing-desk"
[ -z "$ROUTED" ] || fail "S3: a name held on THIS Mac was rerouted to '$ROUTED'"
route "bridge:session_01XYZ"; [ -z "$ROUTED" ] || fail "S4: an explicit bridge address was rewritten"
route "uds:/tmp/cc-socks/1.sock"; [ -z "$ROUTED" ] || fail "S4: a uds address was rewritten"
route "twin"; [ -z "$ROUTED" ] || fail "S5: an ambiguous name was rerouted to '$ROUTED'"
route "sleepy"; [ -z "$ROUTED" ] || fail "S6: a window on an asleep Mac was rerouted"
route "no-bridge"; [ -z "$ROUTED" ] || fail "S7: a window with no bridge id was rerouted to '$ROUTED'"
OUT="$(printf 'garbage' | HOME="$FAKE_HOME" LAC_CACHE_DIR="$CACHE" LAC_WINDOWS_DIR="$ROOT/icloud" python3 "$SCRIPT" route-send 2>/dev/null)"
[ $? = 0 ] && [ -z "$OUT" ] || fail "S8: garbage stdin -> output '$OUT'"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  case "$FAIL_MSGS" in
    *"S3: a name held on THIS Mac was rerouted"*) echo "NEG-CONTROL OK: without the this-Mac check, S3 went RED"; exit 0 ;;
  esac
  echo "NEG-CONTROL BROKEN: S3 stayed green with the this-Mac check removed" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 20-route-send" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi
echo "PASS: 20-route-send - 9 assertions (S1-S2 rerouted, S3-S7 left alone, S8 fail-open)"
exit 0
