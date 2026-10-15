#!/usr/bin/env bash
# 14 - A sandbox shared folder can never feed the REAL local cache.
#
# The live defect (2026-10-15): a run with a sandbox shared folder (LAC_WINDOWS_DIR) but the real
# HOME wrote fixture windows ("mini-billing") into ~/.claude/claude-windows-cache/, and the real
# `list` then showed them as the other Mac. The cache path was derived from HOME alone. It is now
# tied to the shared folder: an overridden folder gets a cache BESIDE it.
#
# G1  PURE (writes nothing): with the REAL home and a sandbox folder, every write path the script
#     reports (cache, stamp, log) is outside the real home
# G2  a pretend home + sandbox folder: publish (with prefetch), list and find run end to end, the
#     fixture Mac lands in the sandbox cache, and NOTHING is created under the pretend home's
#     .claude/claude-windows-cache
# G3  LAC_CACHE_DIR, when given, is honoured exactly
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): a copy whose cache path ignores the override
# (the original bug). G1 and G2 must go red. G1 is pure and G2 only writes inside the pretend home,
# so the negative control cannot itself leak into the real cache.
set -uo pipefail
GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
REAL_SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$REAL_SCRIPT" ] || { echo "INFRA: script not found: $REAL_SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lac-atest-${RUN_ID}-XXXXXX")"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "INFRA: mktemp -d failed" >&2; exit 3; }
trap 'rm -rf "$ROOT"' EXIT
REAL_HOME_DIR="$(python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)')"
SANDBOX="$ROOT/icloud/claude-windows"
PRETEND="$ROOT/pretend-home"
mkdir -p "$SANDBOX" "$PRETEND/.claude/sessions" "$PRETEND/.claude/session-status"

SCRIPT="$REAL_SCRIPT"
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  python3 - "$REAL_SCRIPT" "$SCRIPT" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = '''    override = os.environ.get("LAC_WINDOWS_DIR")
    if override:
        p = Path(override)
        return p.parent / f".{p.name or 'claude-windows'}-cache"
    return HOME / ".claude" / "claude-windows-cache"'''
assert s.count(a) == 1
s = s.replace(a, '    return HOME / ".claude" / "claude-windows-cache"')
s = s.replace('''    if os.environ.get("LAC_CACHE_DIR") or os.environ.get("LAC_WINDOWS_DIR"):
        return cache_dir() / "windows-publish.log"''', '''    if os.environ.get("LAC_CACHE_DIR"):
        return cache_dir() / "windows-publish.log"''')
open(sys.argv[2], "w").write(s)
PY
fi

FAIL_N=0; FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

# --- G1: pure path query with the REAL home ------------------------------------------------------
OUT="$(LAC_WINDOWS_DIR="$SANDBOX" python3 "$SCRIPT" address-book-paths 2>&1)"
printf '%s' "$OUT" | python3 -c '
import json, os, sys
homes = [os.path.realpath(h) for h in sys.argv[1:]]
d = json.load(sys.stdin)
bad = [k for k in ("cache_dir", "publish_stamp", "publish_log") for h in homes
       if (os.path.realpath(d[k]) + os.sep).startswith(h + os.sep)]
sys.exit(1 if bad else 0)
' "$REAL_HOME_DIR" "$HOME" || fail "G1: with a sandbox folder, a write path still resolves under the real home: $OUT"

# --- G2: end to end under a pretend home ---------------------------------------------------------
NOW=$(python3 -c 'import time;print(int(time.time()))')
python3 - "$SANDBOX/lac-guard-mac.json" "$NOW" <<'PY'
import json, sys, time
iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(sys.argv[2])))
json.dump({"format": 1, "host": "lac-guard-mac", "host_label": "Guard Mac", "updated_at": iso,
           "heartbeat_at": iso, "account_hash": "",
           "windows": [{"address": "guard-fixture-window", "caption": "guard fixture", "cwd_label": "x",
                        "can_receive": True, "named": True}]}, open(sys.argv[1], "w"))
PY
for verb in "publish" "list" "find guard fixture"; do
  # shellcheck disable=SC2086  # word-split on purpose: the verb and its query
  HOME="$PRETEND" LAC_WINDOWS_DIR="$SANDBOX" LAC_HOST_ID=lac-guard-self LAC_NO_AUTOPUBLISH=1 \
    LAC_PREFETCH_TIMEOUT=5 perl -e 'alarm shift; exec @ARGV' 30 python3 "$SCRIPT" $verb >"$ROOT/out.txt" 2>&1
done
grep -q "guard-fixture-window" "$ROOT/out.txt" || fail "G2: find did not see the fixture Mac at all (fixture broken): $(head -3 "$ROOT/out.txt")"
if [ -e "$PRETEND/.claude/claude-windows-cache" ]; then
  fail "G2: the pretend home's cache was written: $(ls -A "$PRETEND/.claude/claude-windows-cache" | tr '\n' ' ')"
fi
[ -f "$ROOT/icloud/.claude-windows-cache/lac-guard-mac.json" ] || fail "G2: the fixture Mac was not cached beside the sandbox folder"

# --- G3 -------------------------------------------------------------------------------------------
OUT="$(LAC_CACHE_DIR="$ROOT/explicit-cache" LAC_WINDOWS_DIR="$SANDBOX" python3 "$SCRIPT" address-book-paths 2>&1)"
printf '%s' "$OUT" | python3 -c 'import json,os,sys; sys.exit(0 if os.path.realpath(json.load(sys.stdin)["cache_dir"]) == os.path.realpath(sys.argv[1]) else 1)' "$ROOT/explicit-cache" \
  || fail "G3: LAC_CACHE_DIR was not honoured: $OUT"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in G1 G2; do case "$FAIL_MSGS" in *"${tag}:"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: with the cache path ignoring the override, G1 and G2 went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not go red:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 14-address-book-cache-isolation" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
echo "PASS: 14-address-book-cache-isolation - 3 assertions (sandbox folder never resolves to the real cache, end-to-end run leaves the home cache untouched, LAC_CACHE_DIR honoured)"
exit 0
