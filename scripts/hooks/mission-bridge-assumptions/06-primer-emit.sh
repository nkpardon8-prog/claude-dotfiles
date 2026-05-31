#!/usr/bin/env bash
# 06 — primer surfacing: jq -n emit is injection-safe; branch truth-table is
#      correct; banner read is bounded (regression guard on the 5s budget).
#
# Proves the SessionStart surfacing (post-compact-primer.sh, plan Key Pseudocode):
#   jq -n --arg c "$content" \
#     '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
#   branch: banner present -> surface ; pointer-set + file missing -> CRITICAL
#
# Load-bearing assumption: the banner text (PLAN slice, may contain quotes,
# newlines, $(...), <!-- --> markers) round-trips through jq with NO injection /
# corruption, the branch logic surfaces the right thing on every exit path, and
# reading the precomputed banner stays far under the primer's hard 5s timeout.
#
# Reviewer notes folded: the <1s timing is near-tautological for a size-capped
# banner, so A4 is framed as a REGRESSION GUARD — it fails loudly if a future
# change makes the primer path do unbounded work. The host-imposed
# additionalContext size CEILING is NOT shell-testable and is flagged separately.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "06-primer-emit"

command -v jq >/dev/null 2>&1 || atest_infra "jq not found (required for primer emit)"

# --- A1: jq -n round-trips adversarial content with NO injection -------------
payload='Line with "double quotes" and a newline below
$(rm -rf /)  <-- must NOT execute, must survive verbatim
<!-- MISSION schema=v1 sid=x nonce=y plan_hash=z -->
backtick `whoami` and a trailing backslash \'
emitted="$(jq -n --arg c "$payload" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}')"
# valid JSON?
printf '%s' "$emitted" | jq -e . >/dev/null 2>&1
atest_assert "A1" "$?" "jq -n emitted invalid JSON for adversarial banner content — primer would crash / emit nothing (silent loss)."
# content round-trips byte-for-byte?
got="$(printf '%s' "$emitted" | jq -r '.hookSpecificOutput.additionalContext')"
[ "$got" = "$payload" ]
atest_assert "A2" "$?" "banner content did not round-trip through jq -n (quotes/newlines/\$()/markers mangled) — context would be corrupted on resume."

# --- A3: branch truth-table (banner present / pointer-set+file-missing) ------
# Reproduce the primer's MISSION_PREFIX decision with fixtures.
prefix_for() { # $1 mission_path (may be "")  -> echoes the prefix the primer would set
  _mp="$1"
  if [ -n "$_mp" ] && [ -f "${_mp%.md}.banner" ]; then
    cat "${_mp%.md}.banner"
  elif [ -n "$_mp" ] && [ -f "$_mp" ]; then
    echo "CRITICAL: mission $_mp exists but its banner is missing — run /pre-compact"
  elif [ -n "$_mp" ]; then
    echo "CRITICAL: mission expected (recorded in chain manifest) but FILE MISSING"
  else
    echo ""
  fi
}
MD="$ATEST_DIR/MISSION.test.md"; BN="$ATEST_DIR/MISSION.test.banner"
# case 1: banner present -> surfaces banner text
printf 'mission body\n<!-- MISSION schema=v1 sid=test nonce=n plan_hash=h -->\n' > "$MD"
printf '=== MISSION (immutable plan) ===\nStep 1\n' > "$BN"
p1="$(prefix_for "$MD")"
printf '%s' "$p1" | grep -q '=== MISSION'
atest_assert "A3a" "$?" "banner-present branch did not surface the banner text — a live mission would be invisible post-compact."
# case 2: pointer set, main file exists, banner MISSING -> loud CRITICAL
rm -f "$BN"
p2="$(prefix_for "$MD")"
printf '%s' "$p2" | grep -q 'CRITICAL'
atest_assert "A3b" "$?" "missing-banner branch was not LOUD (no CRITICAL) — primer would proceed as if no mission (fail-silent, the worst case)."
# case 3: pointer set, main file GONE -> loud CRITICAL
rm -f "$MD"
p3="$(prefix_for "$MD")"
printf '%s' "$p3" | grep -q 'CRITICAL'
atest_assert "A3c" "$?" "missing-file branch was not LOUD (no CRITICAL) — a vanished spine would be silently ignored."
# case 4: no pointer at all -> empty (no false CRITICAL on no-mission sessions)
p4="$(prefix_for "")"
[ -z "$p4" ]
atest_assert "A3d" "$?" "no-mission session produced a non-empty prefix ('$p4') — would spam CRITICAL on ordinary sessions."

# --- A4: bounded banner read stays FAR under 5s (regression guard) -----------
# Build a worst-case 64KB banner; time cat | jq emit. This is fast by construction;
# the test's value is catching a FUTURE regression that reintroduces unbounded
# work on the primer path (e.g. reading the 5MB main file).
BIG="$ATEST_DIR/big.banner"
head -c 65536 < /dev/zero | tr '\0' 'B' > "$BIG"
t0="$(date +%s)"
content="$(cat "$BIG")"
jq -n --arg c "$content" '{hookSpecificOutput:{additionalContext:$c}}' >/dev/null 2>&1
_emit_rc=$?
t1="$(date +%s)"
elapsed=$(( t1 - t0 ))
[ "$_emit_rc" = "0" ] && [ "$elapsed" -lt 5 ]
atest_assert "A4" "$?" "64KB banner cat+emit took ${elapsed}s (budget <5s) or failed (rc=$_emit_rc) — primer would risk the SessionStart timeout (fail-silent)."

# NOTE (not shell-testable): the HOST-imposed additionalContext size ceiling
# (Claude Code may truncate very large context) is NOT verifiable here — the
# banner is size-capped at MISSION_PLAN_BANNER_MAX (4000B) precisely to stay well
# under any such ceiling. Verify the cap holds in test-mission-bridge.sh.

atest_report
