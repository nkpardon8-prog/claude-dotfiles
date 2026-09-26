#!/usr/bin/env bash
# 15 - the REVERSE direction of test 07: send FROM the Mac mini, whose real home is
# /Users/omidsmacmini but whose chat works in /Users/omidzahrai/... (a verified home alias), back
# to the MacBook, where /Users/omidzahrai is simply the owner's real home. Uses the normal dentall
# layout: a separate worktree beside the main checkout (WT != ROOT).
#
#   S1 negative controls on the sender: the same cwd is refused when no verified alias covers it -
#      with no alias base at all, and with a marker that names another account.
#   S2 send: accepted; the manifest records home = the mini's real home and repo_home = the alias.
#   R1 receive on the "MacBook" (HOME = the former alias path, now a plain real home, no marker):
#      transcript + caption + memory land under ITS real $HOME/.claude; the ROOT handoff and TRANSFER
#      notes land at ROOT; the worktree is re-created at the same path on the same branch with
#      HEAD, the `git diff HEAD` hash, the untracked set and tmp/ context matching the mini.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

SANDBOX=$(tx_sandbox 15)
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

USERS="$SANDBOX/users"                 # stands in for /Users
ALIAS="$USERS/omid-a"                  # /Users/omidzahrai: alias on the mini, real home on the MacBook
MINI="$USERS/omid-b"                   # /Users/omidsmacmini: the mini's real home
EMPTY_USERS="$SANDBOX/no-users"        # an alias base with no aliases in it
DROP="$SANDBOX/drop"
ORIGIN="$SANDBOX/origin.git"
mkdir -p "$ALIAS/Developer" "$MINI/.claude" "$EMPTY_USERS"
ME=$(id -un)
printf 'alias_of=%s\n' "$ME" > "$ALIAS/.home-alias-of"

ROOT="$ALIAS/Developer/proj"
tx_init_origin "$ORIGIN" "$ROOT" >/dev/null
ROOT=$(cd -P "$ROOT" && pwd -P)
WT="$ROOT-feat"
git -C "$ROOT" worktree add -q -b feat "$WT"
WT=$(cd -P "$WT" && pwd -P)
printf 'feature v1\n' > "$WT/f.txt"; git -C "$WT" add f.txt; git -C "$WT" commit -q -m "unpushed feature"
printf 'dirty\n' >> "$WT/f.txt"
printf 'untracked on the mini\n' > "$WT/untracked.txt"
mkdir -p "$WT/tmp"; printf 'mini context\n' > "$WT/tmp/ctx.md"

SID=$(tx_new_sid)
tx_write_transcript "$MINI" "$SID" "$WT"
tx_write_caption "$MINI" "$SID" "atest 15 reverse"
SLUG=$(tx_slug "$WT")
mkdir -p "$MINI/.claude/projects/$SLUG/memory"
printf 'mini memory\n' > "$MINI/.claude/projects/$SLUG/memory/MEMORY.md"
tx_write_handoff "$ROOT" "$SID"
printf '# Transfer notes - %s\n\n## Restart checklist on the new Mac\n- [ ] atest-15 item\n' "$SID" > "$ROOT/TRANSFER.$SID.md"

# --- S1: negative controls ----------------------------------------------------------------------
export TX_TEST_ALIAS_HOMES_BASE="$EMPTY_USERS"
tx_run_send "$MINI" "$DROP" --tool claude --sid "$SID" --cwd "$WT"
[ "$TX_LAST_RC" -eq 2 ] || fail "S1: a cwd outside \$HOME with no verified alias was not refused (rc=$TX_LAST_RC)"
case "$TX_LAST_ERR" in *"verified home alias"*) ;; *) fail "S1: refusal did not mention the home alias rule: $TX_LAST_ERR" ;; esac
export TX_TEST_ALIAS_HOMES_BASE="$USERS"
printf 'alias_of=someone-else\n' > "$ALIAS/.home-alias-of"
tx_run_send "$MINI" "$DROP" --tool claude --sid "$SID" --cwd "$WT"
[ "$TX_LAST_RC" -eq 2 ] || fail "S1: an alias whose marker names another account was accepted by the sender (rc=$TX_LAST_RC)"
[ -z "$(find "$DROP" -maxdepth 1 -name '*.tx' 2>/dev/null)" ] || fail "S1: a bundle was written despite the refusals"

# --- S2: send through the verified alias ----------------------------------------------------------
printf 'alias_of=%s\n' "$ME" > "$ALIAS/.home-alias-of"
tx_run_send "$MINI" "$DROP" --tool claude --sid "$SID" --cwd "$WT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send through the alias failed: $(tx_combined)" >&2; exit 3; }
CODE="$TX_LAST_CODE"; LOC="$TX_LAST_LOC"
DEC="$SANDBOX/dec"; mkdir -p "$DEC"
tx_decrypt "$DROP/$LOC.tx" "$DEC/inner.tgz" "$CODE" || { echo "INFRA: decrypt failed" >&2; exit 3; }
( cd "$DEC" && tar -xzf inner.tgz manifest.json )
python3 - "$DEC/manifest.json" "$(cd -P "$MINI" && pwd -P)" "$(cd -P "$ALIAS" && pwd -P)" <<'PY' || fail "S2: manifest home/repo_home/placement classes are wrong"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["home"] == sys.argv[2], m["home"]
assert m["repo_home"] == sys.argv[3], m["repo_home"]
cls = {(f["kind"], f["class"]) for f in m["files"]}
assert ("session", "home") in cls and ("root", "abs") in cls and ("untracked", "abs") in cls, cls
assert all(f["path"].startswith("home/claude/") for f in m["files"] if f["class"] == "home")
PY
rm -rf "$DEC"

untracked_set() { git -C "$1" ls-files -o --exclude-standard | sort | while IFS= read -r f; do printf '%s %s\n' "$(tx_sha "$1/$f")" "$f"; done; }
M_HEAD=$(git -C "$WT" rev-parse HEAD)
M_DIFF=$(tx_git_diff_head "$WT" | shasum -a 256 | cut -d' ' -f1)
M_UNTRACKED=$(untracked_set "$WT")
M_TRANSCRIPT=$(tx_sha "$MINI/.claude/projects/$SLUG/$SID.jsonl")
M_HANDOFF=$(tx_sha "$ROOT/CLAUDE.local.$SID.md")

# The MacBook: the alias path is its REAL home (no marker), holding its own clone without the
# worktree; no Claude state for this chat yet.
git -C "$ROOT" worktree remove --force "$WT"
rm -rf "$ROOT" "$ALIAS/.home-alias-of"
git clone -q "$ORIGIN" "$ROOT"
export TX_TEST_ALIAS_HOMES_BASE="$EMPTY_USERS"

# --- R1 ---------------------------------------------------------------------------------------------
tx_run_resume "$ALIAS" "$DROP" "$CODE" --no-exec
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "R1: resumework on the MacBook failed: $(tx_combined | tr '\n' '|')"
else
  [ "$(tx_sha "$ALIAS/.claude/projects/$SLUG/$SID.jsonl")" = "$M_TRANSCRIPT" ] || fail "R1: transcript not byte-identical under the MacBook's real \$HOME"
  [ -f "$ALIAS/.claude/session-status/$SID.txt" ] || fail "R1: caption missing under the MacBook's real \$HOME"
  [ "$(cat "$ALIAS/.claude/projects/$SLUG/memory/MEMORY.md" 2>/dev/null)" = "mini memory" ] || fail "R1: memory file missing"
  [ "$(tx_sha "$ROOT/CLAUDE.local.$SID.md")" = "$M_HANDOFF" ] || fail "R1: ROOT handoff missing or different"
  grep -q "atest-15 item" "$ROOT/TRANSFER.$SID.md" 2>/dev/null || fail "R1: TRANSFER notes missing at ROOT"
  [ "$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null)" = "feat" ] || fail "R1: worktree not re-created on branch feat"
  [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" = "$M_HEAD" ] || fail "R1: HEAD differs from the mini's"
  [ "$(tx_git_diff_head "$WT" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)" = "$M_DIFF" ] || fail "R1: git diff HEAD hash differs"
  [ "$(untracked_set "$WT")" = "$M_UNTRACKED" ] || fail "R1: untracked set differs: mini=[$M_UNTRACKED] macbook=[$(untracked_set "$WT")]"
  [ "$(cat "$WT/tmp/ctx.md" 2>/dev/null)" = "mini context" ] || fail "R1: tmp/ context missing in the worktree"
fi

ok_report "15-alias-reverse" "sender refuses a cwd under an unverified alias; through a verified alias it records home + repo_home; the MacBook restores state under its real \$HOME and the separate worktree (HEAD, diff, untracked, tmp/) plus handoff/TRANSFER at the same absolute paths"
