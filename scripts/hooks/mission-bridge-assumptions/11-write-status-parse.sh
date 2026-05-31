#!/usr/bin/env bash
# 11 — mission-write.sh always exit 0; a lib failure surfaces ONLY on the stdout status line.
# Fix-plan #3. Invokes the REAL mission-write.sh CLI and proves the conductor's parse contract.
#
# Load-bearing contract: mission-write.sh ALWAYS `exit 0` (never aborts the autonomous /pre-compact
# caller). A corrupt mission file → lib rc=2, a busy lock → lib rc=3, and these surface ONLY as
# `mission-write: <verb> FAILED rc=N (...)` on stdout (mission-write.sh _mw_status). The fix wires
# mission.md to PARSE that line (rc=2 → STOP-LOUD, rc=3 → retry); this test proves the signal the
# parse depends on is actually emitted and machine-extractable — and that exit code is useless.
#
# NEGATIVE CONTROL (controllable precondition): A4 runs a SUCCESSFUL write and requires the status
# line say `ok` with NO `FAILED rc=` token (so the parse idiom yields empty, not a phantom code).
# That green proves the rc-extraction in A1/A2 is not matching noise.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "11-write-status-parse"

MW="$HOME/.claude-dotfiles/scripts/hooks/mission-write.sh"
[ -f "$MW" ] || atest_infra "mission-write.sh not found at $MW"
. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh" 2>/dev/null \
  || atest_infra "cannot source mission-bridge.sh"

# the parse idiom the conductor (mission.md) will use on every mission-write.sh status line:
parse_rc() { printf '%s' "$1" | sed -n 's/.*FAILED rc=\([0-9][0-9]*\).*/\1/p'; }

SID="atest11"
ROOT="$ATEST_DIR/anchor"; mkdir -p "$ROOT"
MF="$ROOT/MISSION.${SID}.md"
mission_create "$SID" "$ROOT" "MISSION MODE: build — t11" >/dev/null 2>&1 \
  || atest_infra "mission_create failed"

# --- A4 (NEGATIVE CONTROL, run first on the still-valid file): success → `ok`, no rc -----
out_ok=$(bash "$MW" note "$SID" "$ROOT" "a healthy note" "n-ok" 2>/dev/null); ec_ok=$?
rc_ok=$(parse_rc "$out_ok")
case "$out_ok" in *"mission-write: note ok"*) _okline=0 ;; *) _okline=1 ;; esac
[ "$_okline" = "0" ] && [ -z "$rc_ok" ] && [ "$ec_ok" = "0" ]
atest_assert "A4" "$?" "a successful write did not report a clean 'ok' status (line='$out_ok', parsed-rc='$rc_ok', exit=$ec_ok) — the parse would either miss success or hallucinate a failure code."

# --- A1: CORRUPT mission file → status line carries rc=2, parse extracts 2 ----------------
# Corrupt by rewriting the marker's plan_hash so mission_verify mismatches.
tmpf=$(mktemp "${MF}.corrupt.XXXXXX") || atest_infra "mktemp failed"
LC_ALL=C sed 's/plan_hash=[0-9a-fA-F]*/plan_hash=deadbeefdeadbeef/' "$MF" > "$tmpf" && mv -f "$tmpf" "$MF" \
  || atest_infra "could not corrupt the mission file"
mission_verify "$MF" "$SID" 2>/dev/null && atest_infra "setup: corruption did not break mission_verify"

out_corrupt=$(bash "$MW" note "$SID" "$ROOT" "into a corrupt file" "n-corrupt" 2>/dev/null); ec_corrupt=$?
rc_corrupt=$(parse_rc "$out_corrupt")
[ "$rc_corrupt" = "2" ]
atest_assert "A1" "$?" "corrupt-file write did not surface rc=2 on the status line (line='$out_corrupt', parsed='$rc_corrupt') — the STOP-LOUD guard can never see a corrupt bridge."

# --- A2: exit code is ALWAYS 0 even on failure (so stdout parse is the ONLY signal) ------
[ "$ec_corrupt" = "0" ]
atest_assert "A2" "$?" "mission-write.sh exited $ec_corrupt on a corrupt-file failure (expected 0) — if it ever exits nonzero the autonomous /pre-compact caller could be aborted; if it exits 0 (correct) then ONLY the stdout line carries the failure."

# --- A3: BUSY lock → status line carries rc=3, parse extracts 3 --------------------------
# Restore a valid file first so the ONLY failure cause is the held lock (not corruption).
rm -f "$ROOT/MISSION.${SID}.md" 2>/dev/null
mission_create "$SID" "$ROOT" "MISSION MODE: build — t11-relock" >/dev/null 2>&1 \
  || atest_infra "mission_create (relock) failed"
LB=$(_mission_lockbase "$ROOT")
LOCKDIR="${LB}/.claude-mission-${SID}.lock"
sleep 30 & live=$!
mkdir -p "$LOCKDIR" 2>/dev/null && printf '%s\n' "$live" > "$LOCKDIR/pid" \
  || { kill "$live" 2>/dev/null; atest_infra "could not pre-hold the lock"; }
out_busy=$(bash "$MW" note "$SID" "$ROOT" "while lock held" "n-busy" 2>/dev/null); ec_busy=$?
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
rm -rf "$LOCKDIR" 2>/dev/null
rc_busy=$(parse_rc "$out_busy")
[ "$rc_busy" = "3" ] && [ "$ec_busy" = "0" ]
atest_assert "A3" "$?" "lock-busy write did not surface rc=3 (line='$out_busy', parsed='$rc_busy', exit=$ec_busy) — the conductor cannot distinguish a transient lock (retry) from a corrupt file (STOP)."

atest_report
