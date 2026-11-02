#!/usr/bin/env bash
# 29 - the gates of fleet-move.sh final / land / rollback (plan rules 3-7, 15 and the required
# FLEET_DEST), driving the REAL fleet-move.sh with the destination side run locally (dev gate only).
# Live "windows" are /bin/sleep symlinked as `claude` (the line-agent suite's fixture) with real
# registry entries, so the ported liveness check judges them exactly as it judges real windows.
#
#   G0 FLEET_DEST unset -> every destination-touching subcommand refuses (no default host).
#   G1 a real final without FLEET_DOCKER_OK=1 refuses.
#   G2 a chat seen by inventory but never packed (no fleet-ready marker) refuses final.
#   G3 rule 4: growth after the marker with a tool call refuses; growth that is only text plus the
#      pack step's own marker-writing Bash call passes.
#   G4 rule 5: another open chat refuses a full final; one chat open in two windows refuses.
#   G5 rule 5: a non-shell process with its working folder inside a root refuses even a pilot.
#   G6 --only: shorter than 8 characters and ambiguous prefixes refuse; a unique prefix works.
#   G7 pilot: final --only + verify + land write transferred-<sid> here, transfer-arrived-<sid> and
#      landed.json there; resume-list prints the resume command, and NOT READY when the launch
#      folder is missing on the destination.
#   G8 rule 7: a file changed under a landed root on the destination refuses the next final; a
#      landed chat asked a question (Read only) does not; one that ran a Bash call does.
#   G9 rule 15: rollback refuses while the destination transcript differs from the landed one and
#      succeeds (removing transferred-<sid> here) once it matches.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
FLEET="$TX_REPO/scripts/transfer/fleet-move.sh"
[ -x "$FLEET" ] || { echo "INFRA: fleet-move.sh missing or not executable at $FLEET" >&2; exit 3; }
command -v lsof >/dev/null 2>&1 || { echo "INFRA: lsof missing" >&2; exit 3; }

SANDBOX=$(tx_sandbox 29)
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(cd -P "$SANDBOX" && pwd -P)

USERS="$SANDBOX/users"; ALIAS="$USERS/omid-a"; SRC="$SANDBOX/src-home"
DHOME="$SANDBOX/dest-home"; DPRE="$SANDBOX/dest-root"; SCR="$SANDBOX/scratch"
mkdir -p "$ALIAS/Developer" "$SRC/.claude/sessions" "$SRC/.claude/progress" "$DHOME/.claude" "$DPRE" "$SCR" "$SANDBOX/bin"
printf 'alias_of=%s\n' "$(id -un)" > "$ALIAS/.home-alias-of"
ln -s /bin/sleep "$SANDBOX/bin/claude" || { echo "INFRA: cannot symlink /bin/sleep" >&2; exit 3; }
export TX_TEST_ALIAS_HOMES_BASE="$USERS" FLEET_TEST_DEST_HOME="$DHOME" FLEET_TEST_DEST_PREFIX="$DPRE"
export FLEET_TEST_SCRATCH_BASE="$SCR" FLEET_DEST="sandbox-dest" FLEET_EXTRA_ROOTS=""
unset FLEET_DOCKER_OK

ROOT="$ALIAS/Developer/proj"
tx_init_origin "$SANDBOX/origin.git" "$ROOT" >/dev/null
SLUG=$(tx_slug "$ROOT"); P="$SRC/.claude/projects/$SLUG"; mkdir -p "$P"
A="aaaaaaaa-1111-4111-8111-111111111111"; B="aaaaaaaa-2222-4222-8222-222222222222"; C="cccccccc-3333-4333-8333-333333333333"

transcript() {  # transcript <sid> [extra-record-kind] -> writes P/<sid>.jsonl (2 records [+1])
  python3 - "$P/$1.jsonl" "$1" "$ROOT" "${2:-}" <<'PY'
import json, sys
path, sid, cwd, extra = sys.argv[1:5]
recs = [{"type": "user", "uuid": sid + "-u1", "sessionId": sid, "cwd": cwd, "message": {"role": "user", "content": "hi"}},
        {"type": "assistant", "uuid": sid + "-u2", "sessionId": sid, "cwd": cwd, "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}}]
with open(path, "w") as fh:
    for r in recs:
        fh.write(json.dumps(r) + "\n")
PY
}
append_tool() {  # append_tool <file> <ToolName> <command-or-path>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
f, name, arg = sys.argv[1:4]
inp = {"command": arg} if name == "Bash" else {"file_path": arg}
with open(f, "a") as fh:
    fh.write(json.dumps({"type": "assistant", "uuid": "late", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "goodbye"}, {"type": "tool_use", "id": "t1", "name": name, "input": inp}]}}) + "\n")
PY
}
mark() {  # mark <sid>: the fleet-ready marker /transfer pack writes
  python3 - "$SRC/.claude/progress/fleet-ready-$1" "$1" "$P/$1.jsonl" "$ROOT" <<'PY'
import json, os, sys
f, sid, tr, cwd = sys.argv[1:5]
json.dump({"sid": sid, "transcript_bytes": os.path.getsize(tr), "last_uuid": sid + "-u2", "ts": "2026-11-02T00:00:00Z",
           "cwd": cwd, "transcript": tr}, open(f, "w"))
PY
}
window() {  # window <sid>: a live "claude" process + its registry entry; prints the pid
  "$SANDBOX/bin/claude" 600 >/dev/null 2>&1 &
  local pid=$!
  PIDS="$PIDS $pid"
  python3 - "$SRC/.claude/sessions/$pid.json" "$pid" "$1" "$ROOT" <<'PY'
import json, sys, time
f, pid, sid, cwd = sys.argv[1:5]
json.dump({"pid": int(pid), "sessionId": sid, "cwd": cwd, "startedAt": int(time.time() * 1000), "name": "w-" + sid[:4]}, open(f, "w"))
PY
  echo "$pid"
}
close_window() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; rm -f "$SRC/.claude/sessions/$1.json"; }
fleet() { FO=$(HOME="$SRC" "$FLEET" "$@" 2>&1); FRC=$?; }
has() { case "$FO" in *"$1"*) return 0 ;; esac; return 1; }

transcript "$A"; transcript "$B"; transcript "$C"
PB=$(window "$B"); PC=$(window "$C")
sleep 1
fleet inventory
[ "$FRC" -eq 0 ] || { echo "INFRA: inventory failed: $FO" >&2; exit 3; }
has "aaaaaaaa  w-aaaa" && has "cccccccc  w-cccc" || { echo "INFRA: inventory did not see the fake windows: $FO" >&2; exit 3; }
close_window "$PB"
mark "$A"

# --- G0 ---------------------------------------------------------------------------------------------
for sub in "final --dry-run" "dest-check" "seed --dry-run" "verify" "land"; do
  # shellcheck disable=SC2086
  FO=$(env -u FLEET_DEST HOME="$SRC" "$FLEET" $sub 2>&1); FRC=$?
  [ "$FRC" -eq 2 ] && has "FLEET_DEST is not set" || fail "G0: '$sub' without FLEET_DEST did not refuse (rc=$FRC): $FO"
done

# --- G1 ---------------------------------------------------------------------------------------------
fleet final
[ "$FRC" -eq 2 ] && has "FLEET_DOCKER_OK=1" || fail "G1: final without FLEET_DOCKER_OK=1 was not refused (rc=$FRC)"
export FLEET_DOCKER_OK=1

# --- G2 + G4 -------------------------------------------------------------------------------------------
PC2=$(window "$C")
fleet final
[ "$FRC" -eq 2 ] || fail "G2/G4: full final with an unpacked chat and an open chat exited $FRC"
has "chat aaaaaaaa (w-aaaa): not packed" || fail "G2: the never-packed chat was not named: $FO"
has "chat cccccccc (w-cccc) is still open" || fail "G4: the open chat was not named"
has "open in 2 windows" || fail "G4: one chat open in two windows was not refused"
[ -d "$DPRE$ROOT" ] && fail "G2/G4: something was copied despite the refusal"
close_window "$PC"; close_window "$PC2"

# --- G6 ---------------------------------------------------------------------------------------------
fleet final --dry-run --only abc
[ "$FRC" -eq 2 ] && has "shorter than 8" || fail "G6: a 3-character --only was not refused (rc=$FRC)"
fleet final --dry-run --only aaaaaaaa
[ "$FRC" -eq 2 ] && has "matches 2 chats" || fail "G6: an ambiguous --only prefix was not refused (rc=$FRC)"

# --- G3 ---------------------------------------------------------------------------------------------
append_tool "$P/$A.jsonl" Bash "npm test"
fleet final --dry-run --only aaaaaaaa-1
[ "$FRC" -eq 2 ] && has "kept working after it was packed" || fail "G3: a tool call after packing was not refused (rc=$FRC)"
transcript "$A"; mark "$A"
append_tool "$P/$A.jsonl" Bash "printf x > ~/.claude/progress/fleet-ready-$A; rm -f mission-liveness"
fleet final --dry-run --only aaaaaaaa-1
[ "$FRC" -eq 0 ] || fail "G3: text + the pack's own marker call after packing was refused: $(printf '%s' "$FO" | grep REFUSE | head -3)"

# --- G5 ---------------------------------------------------------------------------------------------
( cd "$ROOT" && exec sleep 600 ) &
PS=$!; PIDS="$PIDS $PS"
sleep 1
fleet final --only aaaaaaaa-1
[ "$FRC" -eq 2 ] && has "(pid $PS) is using files inside $ROOT" || fail "G5: a process working inside the root was not refused (rc=$FRC)"
kill "$PS" 2>/dev/null; wait "$PS" 2>/dev/null

# --- G7 ---------------------------------------------------------------------------------------------
fleet final --only aaaaaaaa-1
[ "$FRC" -eq 0 ] || { fail "G7: pilot final failed: $(printf '%s' "$FO" | tail -5 | tr '\n' '|')"; ok_report 29-fleet-gates -; }
fleet verify
[ "$FRC" -eq 0 ] || fail "G7: verify after the pilot exited $FRC: $(printf '%s' "$FO" | tail -4 | tr '\n' '|')"
fleet land
[ "$FRC" -eq 0 ] || fail "G7: land failed: $FO"
grep -q "via=fleet" "$SRC/.claude/progress/transferred-$A" 2>/dev/null || fail "G7: transferred-<sid> missing on this Mac"
[ -f "$DHOME/.claude/progress/transfer-arrived-$A" ] || fail "G7: transfer-arrived-<sid> missing on the destination"
grep -q "$A" "$DHOME/.claude/logs/fleet/landed.json" 2>/dev/null || fail "G7: landed.json does not record the chat"
fleet resume-list
has "cd $ROOT && claude --resume $A" || fail "G7: resume-list did not print the resume command: $FO"
has "NOT READY" && fail "G7: resume-list flagged a chat whose folder exists"
mv "$DPRE$ROOT" "$DPRE$ROOT.away"
fleet resume-list
has "NOT READY (folder missing there): cd $ROOT" || fail "G7: resume-list did not flag a missing launch folder: $FO"
mv "$DPRE$ROOT.away" "$DPRE$ROOT"

# --- G8 ---------------------------------------------------------------------------------------------
cp -p "$DPRE$ROOT/README.md" "$SANDBOX/landed-readme"     # rsync set whole-second mtimes there
printf 'edited on the destination\n' >> "$DPRE$ROOT/README.md"
fleet final --only aaaaaaaa-1
[ "$FRC" -eq 2 ] && has "changed on THIS Mac since it landed" || fail "G8: a changed landed root was not refused (rc=$FRC)"
[ "$(tail -1 "$DPRE$ROOT/README.md")" = "edited on the destination" ] || fail "G8: the destination edit was overwritten"
cp -p "$SANDBOX/landed-readme" "$DPRE$ROOT/README.md"
DT="$DHOME/.claude/projects/$SLUG/$A.jsonl"
cp -p "$DT" "$SANDBOX/landed-transcript"
append_tool "$DT" Read "$ROOT/README.md"
fleet final --dry-run --only aaaaaaaa-1
[ "$FRC" -eq 0 ] || fail "G8: a landed chat that only read files blocked final: $(printf '%s' "$FO" | grep REFUSE | head -2)"
append_tool "$DT" Bash "rm -rf build"
fleet final --dry-run --only aaaaaaaa-1
[ "$FRC" -eq 2 ] && has "used for more than questions" || fail "G8: a landed chat that ran Bash was not refused (rc=$FRC)"

# --- G9 ---------------------------------------------------------------------------------------------
fleet rollback aaaaaaaa-1
[ "$FRC" -eq 2 ] && has "was used on this Mac after it landed" || fail "G9: rollback of a used chat was not refused (rc=$FRC): $FO"
[ -f "$SRC/.claude/progress/transferred-$A" ] || fail "G9: a refused rollback removed transferred-<sid>"
cp -p "$SANDBOX/landed-transcript" "$DT"
fleet rollback aaaaaaaa-1
[ "$FRC" -eq 0 ] || fail "G9: rollback of an unchanged chat failed: $FO"
[ -f "$SRC/.claude/progress/transferred-$A" ] && fail "G9: rollback left transferred-<sid> on this Mac"
grep -q "via=fleet-rollback" "$DHOME/.claude/progress/transferred-$A" 2>/dev/null || fail "G9: the destination copy is not marked as moved away"
grep -q "$A" "$DHOME/.claude/logs/fleet/landed.json" && fail "G9: landed.json still records the rolled-back chat"

ok_report "29-fleet-gates" "FLEET_DEST required; Docker flag, unpacked, open, duplicate, still-working and in-use gates refuse; --only prefixes resolve or refuse; pilot lands with fork-guard markers; landed roots/chats edited on the destination block final (reads do not); rollback only while unchanged"
