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
#   G5b a destination path reached through a symlink refuses final; nothing lands behind the link.
#   G8b final stays re-runnable after a landing: the fleet's own re-sync of a landed root does not
#      trip rule 7 on the next run.
#   G11 the REAL marker block from commands/transfer.md (Pack step) satisfies the gate, also after the
#      growth a pack really leaves behind; it removes mission liveness.
#   G10 dest-setup: without --apply nothing changes and the diff shows the moved-aside dirs and the
#      dropped hook; a source missing a required setting refuses --apply; --apply makes commands,
#      agents, rules, patterns, statusline.sh symlinks (real dirs kept as .bak-<ts>), rewrites this
#      Mac's home to the destination's, never touches CLAUDE.md or ~/.claude-dotfiles.
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

# --- G5b --------------------------------------------------------------------------------------------
mkdir -p "$DPRE$ALIAS" "$SANDBOX/elsewhere"
ln -s "$SANDBOX/elsewhere" "$DPRE$ALIAS/Developer"
fleet final --only aaaaaaaa-1
[ "$FRC" -eq 2 ] && has "is a symlink" || fail "G5b: a destination symlink on the path was not refused (rc=$FRC): $(printf '%s' "$FO" | tail -3 | tr '\n' '|')"
[ -z "$(ls -A "$SANDBOX/elsewhere")" ] || fail "G5b: files were written through the destination symlink"
rm -f "$DPRE$ALIAS/Developer"

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
printf 'new on the source\n' > "$ROOT/added-after-landing.txt"
fleet final --only aaaaaaaa-1
[ "$FRC" -eq 0 ] || fail "G8b: re-syncing a landed root failed: $(printf '%s' "$FO" | grep REFUSE | head -2)"
[ -f "$DPRE$ROOT/added-after-landing.txt" ] || fail "G8b: the new source file did not reach the landed root"
fleet final --only aaaaaaaa-1
[ "$FRC" -eq 0 ] || fail "G8b: the fleet's own re-sync tripped rule 7 on the next final: $(printf '%s' "$FO" | grep REFUSE | head -2)"
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

# --- G11 --------------------------------------------------------------------------------------------
TM="$TX_REPO/commands/transfer.md"
[ -f "$TM" ] || { echo "INFRA: $TM missing" >&2; exit 3; }
D="dddddddd-4444-4444-8444-444444444444"
transcript "$D"
printf '{}\n' > "$SRC/.claude/progress/mission-liveness-$D.json"
awk '/^## Pack step/{p=1} p&&/^```bash$/{b=1;next} b&&/^```$/{exit} b{print}' "$TM" \
  | sed -e "s/<SID>/$D/g" -e "s|<CWD>|$ROOT|g" > "$SANDBOX/pack.sh"
[ -s "$SANDBOX/pack.sh" ] || fail "G11: could not find the marker block in transfer.md"
PO=$(HOME="$SRC" bash "$SANDBOX/pack.sh" 2>&1)
case "$PO" in *"pack_rc=0"*) ;; *) fail "G11: the marker block failed: $PO" ;; esac
[ -e "$SRC/.claude/progress/mission-liveness-$D.json" ] && fail "G11: the marker block left mission liveness behind"
[ "$(stat -f %Lp "$SRC/.claude/progress/fleet-ready-$D")" = 600 ] || fail "G11: the marker is not mode 600"
append_tool "$P/$D.jsonl" Bash "$(cat "$SANDBOX/pack.sh")"
fleet final --dry-run --only dddddddd
[ "$FRC" -eq 0 ] || fail "G11: the gate refused a chat packed by the real block: $(printf '%s' "$FO" | grep REFUSE | head -3)"
rm -f "$SRC/.claude/progress/fleet-ready-$D"

# --- G10 --------------------------------------------------------------------------------------------
DF="$DHOME/dotfiles/claude"; DC="$DHOME/.claude"
mkdir -p "$DF/commands" "$DF/agents" "$DF/rules" "$DF/patterns" "$DF/scripts" "$DC/commands" "$DC/agents"
printf 'dest claude md\n' > "$DF/CLAUDE.md"; printf 'sl\n' > "$DF/scripts/statusline.sh"
ln -s "$DF" "$DHOME/.claude-dotfiles"; ln -s "$DF/CLAUDE.md" "$DC/CLAUDE.md"
printf 'old\n' > "$DC/commands/old.md"
python3 - "$DC/settings.json" <<'PY2'
import json, sys
json.dump({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "cp -r $HOME/dotfiles/claude/commands/* $HOME/.claude/commands/"}]}]}}, open(sys.argv[1], "w"))
PY2
SC="$SRC/.claude"
for n in commands agents rules patterns; do ln -s "$SRC/.claude-dotfiles/$n" "$SC/$n"; done
ln -s "$SRC/.claude-dotfiles/scripts/statusline.sh" "$SC/statusline.sh"
printf '[user]\n\tname = tx owner\n\temail = owner@example.invalid\n' > "$SRC/.gitconfig"
settings() {  # settings <crossSessionInbound value>
  python3 - "$SC/settings.json" "$1" "$SRC" <<'PY2'
import json, sys
f, inbound, src = sys.argv[1:4]
def h(c): return [{"hooks": [{"type": "command", "command": c}]}]
d = {"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}, "remoteControlAtStartup": True,
     "crossSessionInbound": inbound, "extra": src + "/tools/x",
     "hooks": {"SessionStart": h("python3 $HOME/.claude-dotfiles/scripts/line-agent-communicator.py session-title") + h("bash $HOME/.claude-dotfiles/scripts/hooks/line-reassert-identity.sh"),
               "UserPromptSubmit": h("python3 $HOME/.claude-dotfiles/scripts/line-agent-communicator.py session-title"),
               "PreToolUse": h("python3 $HOME/.claude-dotfiles/scripts/line-agent-communicator.py route-send"),
               "SessionEnd": h("python3 $HOME/.claude-dotfiles/scripts/line-agent-communicator.py publish --background --delay 3"),
               "PostToolUse": h("$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh")}}
json.dump(d, open(f, "w"))
PY2
}
export FLEET_TEST_SKIP_INSTALLS=1
SET_BEFORE=$(tx_sha "$DC/settings.json")
settings "off"
fleet dest-setup --apply
[ "$FRC" -eq 2 ] && has "would lack: crossSessionInbound=accept" || fail "G10: a missing required setting did not refuse --apply (rc=$FRC): $FO"
[ "$(tx_sha "$DC/settings.json")" = "$SET_BEFORE" ] && [ ! -L "$DC/commands" ] || fail "G10: a refused --apply changed something"
settings "accept"
fleet dest-setup
[ "$FRC" -eq 0 ] || fail "G10: dest-setup diff failed: $FO"
has "real dir moved aside" && has "hook dropped by the full match" && has "all present" || fail "G10: the diff does not show the layout change and dropped hook: $FO"
[ "$(tx_sha "$DC/settings.json")" = "$SET_BEFORE" ] && [ ! -L "$DC/commands" ] || fail "G10: a diff-only run changed something"
fleet dest-setup --apply
[ "$FRC" -eq 0 ] || fail "G10: dest-setup --apply failed: $FO"
for n in commands agents rules patterns; do
  [ "$(readlink "$DC/$n")" = "$DHOME/.claude-dotfiles/$n" ] || fail "G10: $n is not a symlink into the destination's dotfiles"
done
[ "$(readlink "$DC/statusline.sh")" = "$DHOME/.claude-dotfiles/scripts/statusline.sh" ] || fail "G10: statusline.sh link wrong"
[ "$(cat "$DC"/commands.bak-*/old.md 2>/dev/null)" = "old" ] || fail "G10: the real commands dir was not kept as commands.bak-<ts>"
[ "$(readlink "$DC/CLAUDE.md")" = "$DF/CLAUDE.md" ] && [ "$(cat "$DF/CLAUDE.md")" = "dest claude md" ] || fail "G10: CLAUDE.md was touched"
[ "$(readlink "$DHOME/.claude-dotfiles")" = "$DF" ] || fail "G10: ~/.claude-dotfiles was touched"
grep -q "$DHOME/tools/x" "$DC/settings.json" || fail "G10: this Mac's home was not rewritten to the destination's"
grep -q "$SRC" "$DC/settings.json" && fail "G10: this Mac's home is still in the destination settings"
ls "$DC"/settings.json.bak-* >/dev/null 2>&1 || fail "G10: settings.json was not backed up"
[ "$(HOME="$DHOME" git config --global user.email)" = "owner@example.invalid" ] || fail "G10: git identity was not copied"

ok_report "29-fleet-gates" "FLEET_DEST required; Docker flag, unpacked, open, duplicate, still-working and in-use gates refuse; --only prefixes resolve or refuse; pilot lands with fork-guard markers; landed roots/chats edited on the destination block final (reads do not); rollback only while unchanged"
