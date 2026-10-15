#!/usr/bin/env bash
# 17 - The statusline trigger publishes at most once a minute per Mac and never adds latency.
#
# Publishing runs from Claude Code: scripts/statusline.sh calls scripts/line-publish-trigger.sh on
# every render in every window. So (a) a burst of triggers must still produce ONE publish, and (b)
# the statusline must return at once even while the detached publish is stuck on iCloud.
#
# T1  five publishes started at the same instant (what a burst of windows does) -> exactly one runs
#     (LAC_PUBLISH_TRACE counts real runs) - the Python claim, independent of the trigger's own check
# T2  five triggers return immediately while the publish's prefetch is blocked on a placeholder
# T3  the REAL statusline.sh returns immediately in the same state and prints nothing from publish
# T4  once the stamp is older than the interval, the next trigger publishes again
# T5  the published file appears (the detached publish really ran and wrote it)
# T6  a publish that cannot write is LOUD: `list` says this Mac's entry could not be updated (with
#     the permission explanation), and the warning clears after the next good publish
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): the Python claim is removed AND the trigger runs
# publish in the foreground. T1 (more than one publish) and T2 (the trigger waits) must go red.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_addrbook-fixture.sh"

REPO="$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)"
TRIGGER_SRC="$REPO/scripts/line-publish-trigger.sh"
STATUSLINE="$REPO/scripts/statusline.sh"
[ -f "$TRIGGER_SRC" ] && [ -f "$STATUSLINE" ] || { echo "INFRA: trigger or statusline missing" >&2; exit 3; }
# The statusline finds the trigger under $HOME/.claude-dotfiles; give the fake HOME its own copy.
mkdir -p "$FAKE_HOME/.claude-dotfiles/scripts"
TRIGGER="$FAKE_HOME/.claude-dotfiles/scripts/line-publish-trigger.sh"
cp "$TRIGGER_SRC" "$TRIGGER"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  python3 - "$REAL_SCRIPT" "$SCRIPT" "$TRIGGER" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = "    if throttle > 0 and not _claim_publish_slot(throttle):\n"
assert s.count(a) == 1
open(sys.argv[2], "w").write(s.replace(a, "    if False:\n"))
t = open(sys.argv[3]).read()
a = 'nohup python3 "$LAC" publish --throttle "$INTERVAL" </dev/null >/dev/null 2>&1 &\n'
assert t.count(a) == 1
open(sys.argv[3], "w").write(t.replace(a, 'python3 "$LAC" publish --throttle "$INTERVAL" </dev/null >/dev/null 2>&1\n'))
PY
fi

TRACE="$ROOT/publish-trace"; : > "$TRACE"
STAMP="$ROOT/icloud/.claude-windows-cache/.publish-stamp"
export HOME_FOR_RUN="$FAKE_HOME"
trap 'chflags nouchg "$WIN_DIR" 2>/dev/null; cleanup' EXIT
trig_env() {  # trig_env <command...> - run with the sandbox environment the trigger and publish see
  env HOME="$FAKE_HOME" PATH="$ROOT/bin:$PATH" LAC_SCRIPT="$SCRIPT" LAC_WINDOWS_DIR="$WIN_DIR" \
      LAC_HOST_ID="test-mac-a" LAC_HOST_LABEL="Test Mac A" LAC_PUBLISH_TRACE="$TRACE" \
      LAC_PREFETCH_TIMEOUT=6 LAC_NO_AUTOPUBLISH=1 "$@"
}
elapsed() { python3 -c "import time;print(time.time())"; }
traces() { wc -l < "$TRACE" | tr -d ' '; }

# A placeholder that never answers, so the detached publish's prefetch blocks for its full 6 s.
mkfifo "$WIN_DIR/test-mac-z.json"

# --- T1 -------------------------------------------------------------------------------------------
PIDS=""
for _ in 1 2 3 4 5; do trig_env python3 "$SCRIPT" publish --throttle 60 --no-prefetch >/dev/null 2>&1 & PIDS="$PIDS $!"; done
for p in $PIDS; do wait "$p" 2>/dev/null; done
[ "$(traces)" = 1 ] || fail "T1: five simultaneous publishes produced $(traces) real runs, want exactly 1"

# --- T2 -------------------------------------------------------------------------------------------
touch -t 202001010000 "$STAMP" 2>/dev/null
BEFORE=$(traces)
t0=$(elapsed)
for _ in 1 2 3 4 5; do trig_env bash "$TRIGGER" </dev/null >/dev/null 2>&1; done
t1=$(elapsed)
[ "$(python3 -c "print(1 if $t1 - $t0 > 2.5 else 0)")" = 0 ] \
  || fail "T2: five triggers took $(python3 -c "print(round($t1 - $t0, 1))")s - the trigger waited on publish"
i=0; while [ "$i" -lt 40 ] && [ "$(traces)" = "$BEFORE" ]; do sleep 0.25; i=$((i + 1)); done

# --- T3 -------------------------------------------------------------------------------------------
touch -t 202001010000 "$STAMP" 2>/dev/null
t0=$(elapsed)
OUT_SL="$(printf '{"session_id":"%s","workspace":{"current_dir":"/tmp"},"model":{"display_name":"x"}}' "$SID" \
          | trig_env bash "$STATUSLINE" 2>/dev/null)"
t1=$(elapsed)
[ "$(python3 -c "print(1 if $t1 - $t0 > 3 else 0)")" = 0 ] \
  || fail "T3: the statusline took $(python3 -c "print(round($t1 - $t0, 1))")s while publish was blocked on iCloud"
case "$OUT_SL" in *"publish"*|*"prefetch"*) fail "T3: publish output leaked into the statusline" ;; esac

# --- T4 -------------------------------------------------------------------------------------------
i=0; while [ "$i" -lt 40 ] && [ "$(traces)" -lt 3 ]; do sleep 0.25; i=$((i + 1)); done
[ "$(traces)" -ge 3 ] || fail "T4: a trigger after the interval did not publish again ($(traces) publishes)"

# --- T5 -------------------------------------------------------------------------------------------
i=0; while [ "$i" -lt 40 ] && [ ! -f "$WIN_DIR/test-mac-a.json" ]; do sleep 0.25; i=$((i + 1)); done
[ -f "$WIN_DIR/test-mac-a.json" ] || fail "T5: the detached publish never wrote this Mac's file"

# --- T6 -------------------------------------------------------------------------------------------
sleep 7   # let the blocked prefetches finish so they cannot race the checks below
rm -f "$WIN_DIR/test-mac-z.json"
echo "renamed caption" > "$FAKE_HOME/.claude/session-status/${SID}.txt"   # force a real content change
chflags uchg "$WIN_DIR"   # immutable: a real "Operation not permitted", like iCloud refusing a write
run_lac publish --no-prefetch
run_lac list
chflags nouchg "$WIN_DIR"
case "$OUT" in *"this Mac's entry could not be updated"*"PermissionError"*) ;; *) fail "T6: a failed publish was not reported in list" ;; esac
case "$OUT" in *"Privacy & Security"*) ;; *) fail "T6: no plain explanation for a permission failure" ;; esac
run_lac publish --no-prefetch
run_lac list
case "$OUT" in *"could not be updated"*) fail "T6: the warning stayed after a good publish" ;; esac

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in T1 T2; do case "$FAIL_MSGS" in *"${tag}:"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: without the claim and with a foreground publish, T1 and T2 went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not go red:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 17-address-book-trigger" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
echo "PASS: 17-address-book-trigger - 6 assertions (burst -> one publish, trigger and statusline return at once while iCloud blocks, republish after the interval, file written, failure loud in list)"
exit 0
