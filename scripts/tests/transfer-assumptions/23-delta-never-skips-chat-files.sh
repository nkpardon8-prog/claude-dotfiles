#!/usr/bin/env bash
# 23 - DELTA SENDS never leave out the chat's own files or git state, whatever the state file says.
#
#   A state that claims the other Mac already holds EXACT copies (correct sha256 + size) of the
#   handoff, its .prev, MISSION.<sid>.md, TRANSFER.<sid>.md, the transcript, a sid-named ignored file
#   (tmp/notes-<sid>.md, kind context - e.g. a Codex chat's own MISSION/TRANSFER files are this kind)
#   and an ordinary ignored file - plus the project memory file (kind memory: its path carries NO
#   sid, so only the kind rule protects it). The next send must still ship every chat file (by kind: root /
#   session; by name: the sid) plus the git patches, and may leave out only the ordinary file.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 23)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

ROOT="$HOME_T/work/proj"
tx_init_origin "$HOME_T/origin.git" "$ROOT" >/dev/null
ROOT=$(cd -P "$ROOT" && pwd -P)
printf 'tmp/\n' > "$ROOT/.gitignore"; git -C "$ROOT" add .gitignore; git -C "$ROOT" commit -q -m ignore; git -C "$ROOT" push -q
printf 'seed\nunstaged edit\n' > "$ROOT/README.md"                 # git state: an unstaged change
SID=$(tx_new_sid)
tx_write_transcript "$HOME_T" "$SID" "$ROOT"
tx_write_handoff "$ROOT" "$SID"
cp "$ROOT/CLAUDE.local.$SID.md" "$ROOT/CLAUDE.local.$SID.md.prev"
printf '# mission\n' > "$ROOT/MISSION.$SID.md"
printf '# TRANSFER %s\n' "$SID" > "$ROOT/TRANSFER.$SID.md"
mkdir -p "$ROOT/tmp"
printf 'this chat notes\n' > "$ROOT/tmp/notes-$SID.md"
printf 'ordinary ride-along\n' > "$ROOT/tmp/plain.md"
TRANSCRIPT="$HOME_T/.claude/projects/$(tx_slug "$ROOT")/$SID.jsonl"
TRANSCRIPT=$(cd -P "$(dirname "$TRANSCRIPT")" && pwd -P)/$SID.jsonl
MEMF="$(dirname "$TRANSCRIPT")/memory/MEMORY.md"
mkdir -p "$(dirname "$MEMF")"; printf '# memory index\n' > "$MEMF"

CHAT_FILES="$ROOT/CLAUDE.local.$SID.md $ROOT/CLAUDE.local.$SID.md.prev $ROOT/MISSION.$SID.md $ROOT/TRANSFER.$SID.md $ROOT/tmp/notes-$SID.md"
SF=$(tx_state_path "$HOME_T" "$ROOT")
mkdir -p "$(dirname "$SF")"
python3 - "$SF" "$ROOT" "$TRANSCRIPT" "$MEMF" $CHAT_FILES "$ROOT/tmp/plain.md" <<'PY'
import hashlib, json, os, sys
sf, root, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
files = {}
for p in paths:
    b = open(p, "rb").read()
    files[p] = {"sha256": hashlib.sha256(b).hexdigest(), "size": len(b), "mtime_ns": None}
json.dump({"format": 1, "root": root, "role": "receive", "host": "other", "written_at": "x", "files": files}, open(sf, "w"))
PY
chmod 600 "$SF"

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send failed: $(tx_combined)" >&2; exit 3; }
tx_open_bundle "$TX_LAST_CODE" "$TX_LAST_LOC" "$DROP" "$HOME_T/dec" || { echo "INFRA: cannot open the bundle" >&2; exit 3; }
M="$HOME_T/dec/manifest.json"
[ "$(tx_mget "$M" 'm["delta"]["mode"]')" = delta ] || { echo "INFRA: not a delta send: $(tx_mget "$M" 'm["delta"]')" >&2; exit 3; }
for p in $CHAT_FILES; do
  [ "$(tx_mget "$M" '"'"$p"'" in [f.get("abs") for f in m["files"]]')" = True ] || fail "the chat's own ${p#"$ROOT"/} was left out"
  [ "$(tx_mget "$M" '"'"$p"'" in [a["path"] for a in m["assumed_present"]]')" = True ] && fail "the chat's own ${p#"$ROOT"/} is listed as assumed present"
done
[ "$(tx_mget "$M" 'any(f.get("rel","").endswith("/'"$SID"'.jsonl") for f in m["files"])')" = True ] || fail "the transcript was left out"
[ "$(tx_mget "$M" 'any(f.get("kind") == "memory" and f.get("rel","").endswith("/memory/MEMORY.md") for f in m["files"])')" = True ] \
  || fail "the project memory file (no sid in its path) was left out"
[ "$(tx_mget "$M" 'm["git"]["worktree_patch_bytes"] > 0')" = True ] || fail "the git worktree patch did not ship"
[ -s "$HOME_T/dec/git/worktree.patch" ] || fail "git/worktree.patch is empty or missing"
[ "$(tx_mget "$M" '[a["path"] for a in m["assumed_present"]]')" = "['$ROOT/tmp/plain.md']" ] \
  || fail "assumed_present should be exactly the ordinary ride-along file: $(tx_mget "$M" '[a["path"] for a in m["assumed_present"]]')"

ok_report "23-delta-never-skips-chat-files" "handoff(.prev), MISSION, TRANSFER, transcript, the sid-less memory file, a sid-named ignored file and the git patch all ship despite a state claiming exact copies; only the ordinary ride-along file is assumed present"
