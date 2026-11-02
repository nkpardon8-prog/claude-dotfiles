#!/usr/bin/env bash
# 28 - fleet-move.sh final places a packed chat's state on the destination without silently
# overwriting anything there (plan rules 8, 9, 10, 17), driving the REAL fleet-move.sh final + verify
# with the destination side run locally (dev gate only).
#
#   M1 memory merge (rule 8): absent -> copied; identical -> untouched; destination still equal to
#      what the fleet last wrote (fleet-written.json) -> overwritten with the source; a real conflict
#      -> destination kept, source beside it as .from-<host>; that taken and different ->
#      .from-<host>-<ts>.
#   M2 history.jsonl append-only (rule 9): the destination's own lines stay in place and order, the
#      missing source lines are appended once; prod-ledger/*.jsonl is created; a second final adds
#      nothing.
#   M3 per-chat state (rules 10, 17): transcript, its sid folder, file-history, session-status,
#      chains and the scratchpad land byte-identical; no staging folder is left behind.
#   M4 verify: 0 mismatches (merged files count as present when the source sits beside them).
#   M5 conflict (rule 10): a destination chat file that differs makes final refuse (exit 2) and
#      places NOTHING - not even a new, conflict-free file of the same chat.
#   M6 --dry-run final writes nothing on the destination and nothing on this Mac outside
#      ~/.claude/logs/fleet.
#   M8 a chat launched in a NON-git folder: the folder is created on the destination, only its tmp/
#      travels as a root, plus that chat's own CLAUDE.local/TRANSFER/MISSION files there - never
#      another chat's.
#   M7 the merge touches only project folders named by this Mac's inventory: the destination's own
#      project memory is untouched by final, and a state stream naming a project under the
#      destination's real home is refused by place-state with nothing placed.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
FLEET="$TX_REPO/scripts/transfer/fleet-move.sh"
[ -x "$FLEET" ] || { echo "INFRA: fleet-move.sh missing or not executable at $FLEET" >&2; exit 3; }

SANDBOX=$(tx_sandbox 28)
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(cd -P "$SANDBOX" && pwd -P)

USERS="$SANDBOX/users"; ALIAS="$USERS/omid-a"; SRC="$SANDBOX/src-home"
DHOME="$SANDBOX/dest-home"; DPRE="$SANDBOX/dest-root"; SCR="$SANDBOX/scratch"
mkdir -p "$ALIAS/Developer" "$SRC/.claude" "$DHOME/.claude" "$DPRE" "$SCR"
printf 'alias_of=%s\n' "$(id -un)" > "$ALIAS/.home-alias-of"
export TX_TEST_ALIAS_HOMES_BASE="$USERS" FLEET_TEST_DEST_HOME="$DHOME" FLEET_TEST_DEST_PREFIX="$DPRE"
export FLEET_TEST_SCRATCH_BASE="$SCR" FLEET_DEST="sandbox-dest" FLEET_DOCKER_OK=1 FLEET_EXTRA_ROOTS=""
HOSTN=$(hostname -s | tr -c 'A-Za-z0-9._-\n' '-')

ROOT="$ALIAS/Developer/proj"
tx_init_origin "$SANDBOX/origin.git" "$ROOT" >/dev/null
SID=$(tx_new_uuid)
SLUG=$(tx_slug "$ROOT")
P="$SRC/.claude/projects/$SLUG"; DP="$DHOME/.claude/projects/$SLUG"
mkdir -p "$P/$SID/subagents" "$P/memory" "$SRC/.claude/file-history/$SID" "$SRC/.claude/session-status" \
  "$SRC/.claude/chains" "$SRC/.claude/progress" "$SRC/.claude/prod-ledger" "$SCR/$SLUG/$SID"
python3 - "$P/$SID.jsonl" "$SID" "$ROOT" <<'PY'
import json, sys
path, sid, cwd = sys.argv[1:4]
recs = [{"type": "user", "uuid": "u-1", "sessionId": sid, "cwd": cwd, "message": {"role": "user", "content": "remember MANGO-7"}},
        {"type": "assistant", "uuid": "u-2", "sessionId": sid, "cwd": cwd, "message": {"role": "assistant", "content": [{"type": "text", "text": "noted"}]}}]
with open(path, "w") as fh:
    for r in recs:
        fh.write(json.dumps(r) + "\n")
PY
chmod 600 "$P/$SID.jsonl"
printf 'sub\n' > "$P/$SID/subagents/a.jsonl"
printf 'v1\n' > "$SRC/.claude/file-history/$SID/f@v1"
printf 'atest 28\n' > "$SRC/.claude/session-status/$SID.txt"
printf '{}\n' > "$SRC/.claude/chains/$SID.json"
printf 'scratch\n' > "$SCR/$SLUG/$SID/note.txt"
printf '{"line":"A"}\n{"line":"B"}\n{"line":"C"}\n' > "$SRC/.claude/history.jsonl"
printf '{"op":"push"}\n' > "$SRC/.claude/prod-ledger/proj.jsonl"
for n in new same fleetw conflict conflict2; do printf 'source %s\n' "$n" > "$P/memory/$n.md"; done
python3 - "$SRC/.claude/progress/fleet-ready-$SID" "$SID" "$P/$SID.jsonl" "$ROOT" <<'PY'
import json, os, sys
f, sid, tr, cwd = sys.argv[1:5]
json.dump({"sid": sid, "transcript_bytes": os.path.getsize(tr), "last_uuid": "u-2", "ts": "2026-11-02T00:00:00Z",
           "cwd": cwd, "transcript": tr}, open(f, "w"))
PY

# A second packed chat launched in a non-git folder (like ~/.pane/sessions/legacy-pane-chat).
NG="$ALIAS/.pane/sessions/legacy-pane-chat"; SID2=$(tx_new_uuid); NSLUG=$(tx_slug "$NG")
mkdir -p "$NG/tmp" "$SRC/.claude/projects/$NSLUG"
printf 'ng tmp\n' > "$NG/tmp/x.md"; printf 'big\n' > "$NG/not-copied.bin"
printf 'handoff\n' > "$NG/CLAUDE.local.$SID2.md"; printf 'notes\n' > "$NG/TRANSFER.$SID2.md"
printf 'mission\n' > "$NG/MISSION.$SID2.md"; printf 'other chat\n' > "$NG/CLAUDE.local.someone-else.md"
python3 - "$SRC/.claude/projects/$NSLUG/$SID2.jsonl" "$SID2" "$NG" "$SRC/.claude/progress/fleet-ready-$SID2" <<'PY2'
import json, os, sys
path, sid, cwd, mf = sys.argv[1:5]
with open(path, "w") as fh:
    fh.write(json.dumps({"type": "user", "uuid": "n-1", "sessionId": sid, "cwd": cwd, "message": {"role": "user", "content": "x"}}) + "\n")
json.dump({"sid": sid, "transcript_bytes": os.path.getsize(path), "last_uuid": "n-1", "ts": "t", "cwd": cwd, "transcript": path}, open(mf, "w"))
PY2

# Destination before the move: its own memory + history, and one file the fleet wrote earlier.
mkdir -p "$DP/memory" "$DHOME/.claude/logs/fleet"
printf 'source same\n' > "$DP/memory/same.md"
printf 'older fleet copy\n' > "$DP/memory/fleetw.md"
printf 'nick edited this\n' > "$DP/memory/conflict.md"
printf 'nick edited this too\n' > "$DP/memory/conflict2.md"
printf 'an earlier different copy\n' > "$DP/memory/conflict2.md.from-$HOSTN"
python3 - "$DHOME/.claude/logs/fleet/fleet-written.json" "$DP/memory/fleetw.md" <<'PY'
import hashlib, json, sys
json.dump({sys.argv[2]: hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()}, open(sys.argv[1], "w"))
PY
printf '{"line":"A"}\n{"line":"N"}\n' > "$DHOME/.claude/history.jsonl"
SAME_MT=$(tx_mtime "$DP/memory/same.md")
OWN="$DHOME/.claude/projects/$(tx_slug "$DHOME/.pane/sessions/legacy-pane-chat")/memory"
mkdir -p "$OWN"; printf 'destination memory\n' > "$OWN/MEMORY.md"
OWN_SUM=$(cd "$OWN" && ls -la; shasum -a 256 MEMORY.md)

fleet() { FO=$(HOME="$SRC" "$FLEET" "$@" 2>&1); FRC=$?; }
# Names of EVERYTHING (directories too: openrsync -n --no-implied-dirs creates parent folders) + file contents.
tree_sum() {
  ( cd "$1" && { find . ! -path './.claude/logs/fleet*' ! -path './.claude/logs' | LC_ALL=C sort
    find . -type f ! -path './.claude/logs/fleet/*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null; } | shasum -a 256 )
}

fleet inventory
[ "$FRC" -eq 0 ] || { echo "INFRA: inventory failed: $FO" >&2; exit 3; }

# --- M6 first: a dry run changes nothing anywhere --------------------------------------------------
D_BEFORE=$(tree_sum "$DHOME"); P_BEFORE=$(tree_sum "$DPRE"); S_BEFORE=$(tree_sum "$SRC"); R_BEFORE=$(tree_sum "$ROOT")
fleet final --dry-run
[ "$FRC" -eq 0 ] || fail "M6: final --dry-run exited $FRC: $(printf '%s' "$FO" | tail -4 | tr '\n' '|')"
case "$FO" in *"1 would be placed"*|*" would be placed"*) ;; *) fail "M6: the dry run did not report what it would place" ;; esac
[ "$(tree_sum "$DHOME")" = "$D_BEFORE" ] || fail "M6: the dry run changed the destination home"
[ "$(tree_sum "$DPRE")" = "$P_BEFORE" ] || fail "M6: the dry run changed destination roots"
[ "$(tree_sum "$SRC")" = "$S_BEFORE" ] || fail "M6: the dry run changed this Mac outside ~/.claude/logs/fleet"
[ "$(tree_sum "$ROOT")" = "$R_BEFORE" ] || fail "M6: the dry run changed the source root"
[ -d "$DHOME/.claude/fleet-staging" ] && fail "M6: the dry run created a staging folder"

# --- real final ---------------------------------------------------------------------------------------
fleet final
[ "$FRC" -eq 0 ] || { fail "final failed: $(printf '%s' "$FO" | tail -6 | tr '\n' '|')"; # --- M7 ---------------------------------------------------------------------------------------------
[ "$(cd "$OWN" && ls -la; shasum -a 256 MEMORY.md)" = "$OWN_SUM" ] || fail "M7: final wrote into a destination project folder that is not the moving chat's"
EVIL=$(tx_slug "$DHOME/.pane/sessions/legacy-pane-chat")
python3 - "$SANDBOX/evil.tar" "$EVIL" <<'PY2'
import hashlib, io, json, sys, tarfile
out, sl = sys.argv[1:3]
body = b"overwrite\n"
arc = "claude/projects/%s/memory/MEMORY.md" % sl
man = {"format": 1, "host": "x", "slugs": [sl], "members": [{"arc": arc, "kind": "merge", "sid": "", "mode": 420,
       "mtime": 0, "sha": hashlib.sha256(body).hexdigest(), "size": len(body)}]}
with tarfile.open(out, "w") as tf:
    for name, data in ((arc, body), ("__fleet__/manifest.json", json.dumps(man).encode())):
        ti = tarfile.TarInfo(name); ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
PY2
FO=$(HOME="$DHOME" python3 "$TX_REPO/scripts/transfer/fleet_lib.py" place-state --ts 20260101T000000Z --host x < "$SANDBOX/evil.tar" 2>&1); FRC=$?
[ "$FRC" -eq 2 ] || fail "M7: place-state accepted a project folder under the destination's own home (rc=$FRC)"
[ "$(cat "$OWN/MEMORY.md")" = "destination memory" ] || fail "M7: the destination's own memory was overwritten"

ok_report "28-fleet-merge" "-"; }

# --- M1 ---------------------------------------------------------------------------------------------
[ "$(cat "$DP/memory/new.md" 2>/dev/null)" = "source new" ] || fail "M1: absent memory file was not copied"
[ "$(tx_mtime "$DP/memory/same.md")" = "$SAME_MT" ] || fail "M1: an identical memory file was rewritten"
[ "$(cat "$DP/memory/fleetw.md")" = "source fleetw" ] || fail "M1: a file still equal to the fleet's last write was not updated"
[ "$(cat "$DP/memory/conflict.md")" = "nick edited this" ] || fail "M1: a conflicting destination memory file was overwritten"
[ "$(cat "$DP/memory/conflict.md.from-$HOSTN" 2>/dev/null)" = "source conflict" ] || fail "M1: the source copy is not beside the conflict as .from-$HOSTN"
[ "$(cat "$DP/memory/conflict2.md.from-$HOSTN")" = "an earlier different copy" ] || fail "M1: an existing .from- file was overwritten"
ls "$DP/memory/conflict2.md.from-$HOSTN-"* >/dev/null 2>&1 && [ "$(cat "$DP/memory/conflict2.md.from-$HOSTN-"*)" = "source conflict2" ] \
  || fail "M1: the second conflict copy did not go to .from-$HOSTN-<ts>"

# --- M2 ---------------------------------------------------------------------------------------------
H_WANT='{"line":"A"}
{"line":"N"}
{"line":"B"}
{"line":"C"}'
[ "$(cat "$DHOME/.claude/history.jsonl")" = "$H_WANT" ] || fail "M2: history.jsonl is not dest lines + appended source lines: $(tr '\n' '|' < "$DHOME/.claude/history.jsonl")"
[ "$(cat "$DHOME/.claude/prod-ledger/proj.jsonl" 2>/dev/null)" = '{"op":"push"}' ] || fail "M2: prod-ledger file was not created"

# --- M3 ---------------------------------------------------------------------------------------------
for f in "projects/$SLUG/$SID.jsonl" "projects/$SLUG/$SID/subagents/a.jsonl" "file-history/$SID/f@v1" \
         "session-status/$SID.txt" "chains/$SID.json"; do
  [ "$(tx_sha "$DHOME/.claude/$f")" = "$(tx_sha "$SRC/.claude/$f")" ] || fail "M3: $f did not land byte-identical"
done
[ "$(stat -f %Lp "$DHOME/.claude/projects/$SLUG/$SID.jsonl")" = 600 ] || fail "M3: the transcript lost its mode"
[ "$(stat -f %m "$DHOME/.claude/projects/$SLUG/$SID.jsonl")" = "$(stat -f %m "$P/$SID.jsonl")" ] || fail "M3: the transcript lost its mtime"
[ "$(cat "$DPRE$SCR/$SLUG/$SID/note.txt" 2>/dev/null)" = "scratch" ] || fail "M3: the scratchpad did not land"
[ -n "$(ls -A "$DHOME/.claude/fleet-staging" 2>/dev/null)" ] && fail "M3: a staging folder was left behind"
[ -f "$SRC/.claude/progress/fleet-ready-$SID" ] && [ -f "$P/$SID.jsonl" ] || fail "M3: a source file was removed"

# --- M8 ---------------------------------------------------------------------------------------------
DNG="$DPRE$NG"
[ -d "$DNG" ] || fail "M8: the non-git launch folder was not created on the destination"
[ "$(cat "$DNG/tmp/x.md" 2>/dev/null)" = "ng tmp" ] || fail "M8: its tmp/ did not travel"
for f in "CLAUDE.local.$SID2.md" "TRANSFER.$SID2.md" "MISSION.$SID2.md"; do
  [ "$(tx_sha "$DNG/$f")" = "$(tx_sha "$NG/$f")" ] || fail "M8: $f did not travel"
done
[ -e "$DNG/not-copied.bin" ] && fail "M8: a non-tmp file of the non-git folder travelled"
[ -e "$DNG/CLAUDE.local.someone-else.md" ] && fail "M8: another chat's handoff travelled"

# --- M4 ---------------------------------------------------------------------------------------------
fleet verify
[ "$FRC" -eq 0 ] || fail "M4: verify after final exited $FRC: $(printf '%s' "$FO" | tail -4 | tr '\n' '|')"

# --- M2 idempotence -------------------------------------------------------------------------------
fleet final
[ "$FRC" -eq 0 ] || fail "M2: a second final failed: $(printf '%s' "$FO" | tail -3 | tr '\n' '|')"
[ "$(cat "$DHOME/.claude/history.jsonl")" = "$H_WANT" ] || fail "M2: a second final changed history.jsonl"

# --- M5 ---------------------------------------------------------------------------------------------
printf 'nick touched the caption\n' > "$DHOME/.claude/session-status/$SID.txt"
printf 'v2\n' > "$SRC/.claude/file-history/$SID/f@v2"
fleet final
[ "$FRC" -eq 2 ] || fail "M5: a differing destination chat file did not refuse final (rc=$FRC)"
[ -e "$DHOME/.claude/file-history/$SID/f@v2" ] && fail "M5: a conflict-free file was placed despite the refusal"
[ "$(cat "$DHOME/.claude/session-status/$SID.txt")" = "nick touched the caption" ] || fail "M5: the conflicting destination file was changed"
case "$FO" in *session-status*) fail "M5: the refusal printed a file name (rule 13)" ;; esac

# --- M7 ---------------------------------------------------------------------------------------------
[ "$(cd "$OWN" && ls -la; shasum -a 256 MEMORY.md)" = "$OWN_SUM" ] || fail "M7: final wrote into a destination project folder that is not the moving chat's"
EVIL=$(tx_slug "$DHOME/.pane/sessions/legacy-pane-chat")
python3 - "$SANDBOX/evil.tar" "$EVIL" <<'PY2'
import hashlib, io, json, sys, tarfile
out, sl = sys.argv[1:3]
body = b"overwrite\n"
arc = "claude/projects/%s/memory/MEMORY.md" % sl
man = {"format": 1, "host": "x", "slugs": [sl], "members": [{"arc": arc, "kind": "merge", "sid": "", "mode": 420,
       "mtime": 0, "sha": hashlib.sha256(body).hexdigest(), "size": len(body)}]}
with tarfile.open(out, "w") as tf:
    for name, data in ((arc, body), ("__fleet__/manifest.json", json.dumps(man).encode())):
        ti = tarfile.TarInfo(name); ti.size = len(data); tf.addfile(ti, io.BytesIO(data))
PY2
FO=$(HOME="$DHOME" python3 "$TX_REPO/scripts/transfer/fleet_lib.py" place-state --ts 20260101T000000Z --host x < "$SANDBOX/evil.tar" 2>&1); FRC=$?
[ "$FRC" -eq 2 ] || fail "M7: place-state accepted a project folder under the destination's own home (rc=$FRC)"
[ "$(cat "$OWN/MEMORY.md")" = "destination memory" ] || fail "M7: the destination's own memory was overwritten"

ok_report "28-fleet-merge" "memory merges copy/skip/update/keep-beside (.from-<host>, then -<ts>); history is append-only and idempotent; per-chat state and scratchpad land byte-identical; verify 0; a conflicting chat file refuses and places nothing; a dry run writes nothing"
