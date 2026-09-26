#!/usr/bin/env bash
# 07 - placement across two DIFFERENT usernames (MacBook `omidzahrai` -> Mac mini `omidsmacmini`),
# the real setup: the repo lives at the same absolute path on both Macs, on the mini through a
# home alias (make-home-alias.sh). The placement rule (transfer-lib.sh) says:
#   "home" files (Claude/Codex state) -> under the RECEIVER's own real $HOME/.claude
#   "abs"  files (handoff, TRANSFER notes, untracked, tmp/ context, git) -> the SAME absolute path,
#          accepted only when that path's tree resolves under the receiver's $HOME or a VERIFIED
#          home alias of the receiver's account (marker .home-alias-of naming it).
#
#   A1 no alias: A's home does not exist on B at all - refused (exit 2) with the make-home-alias.sh
#      fix naming A's home, bundle kept, nothing created at A's path.
#   A1b wrong alias: the path exists and holds B's clone, but its marker names ANOTHER account - still
#      refused (a same-named directory is not proof), and B's clone is untouched.
#   A2 verified alias: accepted. Transcript/caption land under B's REAL $HOME (never under the alias
#      path); the ROOT handoff, TRANSFER notes, an untracked file and tmp/ context land at the SAME
#      absolute path; HEAD, the `git diff HEAD` hash and the untracked set match A's departure.
#
# Alias homes are simulated inside the sandbox: TX_TEST_ALIAS_HOMES_BASE (honored only under
# TRANSFER_TESTS_ALLOW_DEV=true) stands in for /Users, which tests cannot write. The sandbox alias
# deliberately has NO .claude symlink, so "state landed under B's real home" is a sharp assertion.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

SANDBOX=$(tx_sandbox 07)
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

USERS="$SANDBOX/users"                 # stands in for /Users
HOME_A="$USERS/omid-a"                 # A's real home (the MacBook's /Users/omidzahrai)
HOME_B="$USERS/omid-b"                 # B's real home (the mini's /Users/omidsmacmini)
DROP="$SANDBOX/drop"
ORIGIN="$SANDBOX/origin.git"
mkdir -p "$HOME_A" "$HOME_B/.claude"
export TX_TEST_ALIAS_HOMES_BASE="$USERS"
ME=$(id -un)

SID=$(tx_new_sid)
ROOT="$HOME_A/Developer/proj"
mkdir -p "$HOME_A/Developer"
BR=$(tx_init_origin "$ORIGIN" "$ROOT")
ROOT=$(cd -P "$ROOT" && pwd -P)
printf 'v2 (unpushed)\n' >> "$ROOT/README.md"
git -C "$ROOT" commit -q -am "unpushed on A"
printf 'staged\n' >> "$ROOT/README.md"; git -C "$ROOT" add README.md
printf 'unstaged\n' >> "$ROOT/README.md"
printf 'untracked on A\n' > "$ROOT/scratch.txt"
mkdir -p "$ROOT/tmp"; printf 'context notes\n' > "$ROOT/tmp/notes.md"
tx_write_transcript "$HOME_A" "$SID" "$ROOT"
tx_write_caption "$HOME_A" "$SID" "atest 07 caption"
tx_write_handoff "$ROOT" "$SID"
printf '# Transfer notes - %s\n\n## Restart checklist on the new Mac\n- [ ] atest-07 item\n' "$SID" > "$ROOT/TRANSFER.$SID.md"

tx_run_send "$HOME_A" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send from HOME_A failed: $(tx_combined)" >&2; exit 3; }
CODE="$TX_LAST_CODE"; LOC="$TX_LAST_LOC"

# A's departure state (post-send, so A's .git/info/exclude already hides the sid files).
untracked_set() { git -C "$1" ls-files -o --exclude-standard | sort | while IFS= read -r f; do printf '%s %s\n' "$(tx_sha "$1/$f")" "$f"; done; }
A_HEAD=$(git -C "$ROOT" rev-parse HEAD)
A_DIFF=$(tx_git_diff_head "$ROOT" | shasum -a 256 | cut -d' ' -f1)
A_UNTRACKED=$(untracked_set "$ROOT")
A_HANDOFF=$(tx_sha "$ROOT/CLAUDE.local.$SID.md")
SLUG=$(tx_slug "$ROOT")
A_TRANSCRIPT=$(tx_sha "$HOME_A/.claude/projects/$SLUG/$SID.jsonl")
case "$A_UNTRACKED" in *scratch.txt*) ;; *) echo "INFRA: fixture untracked file not seen on A" >&2; exit 3 ;; esac

# B never had A's home: take it away entirely.
mv "$HOME_A" "$SANDBOX/macbook-final"

# --- A1: no alias -----------------------------------------------------------------------------
tx_run_resume "$HOME_B" "$DROP" "$CODE" --no-exec
[ "$TX_LAST_RC" -eq 2 ] || fail "A1: expected refuse (rc=2) with A's home absent on B, got rc=$TX_LAST_RC: $(tx_combined | tr '\n' '|')"
case "$TX_LAST_ERR" in
  *"make-home-alias.sh omid-a"*) ;;
  *) fail "A1: refusal did not print the make-home-alias.sh fix naming A's home: $TX_LAST_ERR" ;;
esac
[ -f "$DROP/$LOC.tx" ] || fail "A1: the bundle was deleted by a refused placement check"
[ -e "$HOME_A" ] && fail "A1: something was created at A's home path despite the refusal"

# --- A1b: the path exists (B's own clone) but the alias marker names another account -----------
mkdir -p "$HOME_A/Developer"
git clone -q "$ORIGIN" "$ROOT"
printf 'alias_of=someone-else\n' > "$HOME_A/.home-alias-of"
B_SEED=$(git -C "$ROOT" rev-parse HEAD)
tx_run_resume "$HOME_B" "$DROP" "$CODE" --no-exec
[ "$TX_LAST_RC" -eq 2 ] || fail "A1b: expected refuse (rc=2) for an alias whose marker names another account, got rc=$TX_LAST_RC"
case "$TX_LAST_ERR" in
  *"verified home alias"*"make-home-alias.sh"*) ;;
  *) fail "A1b: refusal did not explain the unverified alias + fix: $TX_LAST_ERR" ;;
esac
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$B_SEED" ] || fail "A1b: B's clone was changed despite the refusal"
[ -e "$ROOT/CLAUDE.local.$SID.md" ] && fail "A1b: the handoff was placed despite the refusal"

# --- A2: verified alias -------------------------------------------------------------------------
printf 'alias_of=%s\ncreated_or_verified_at=test\n' "$ME" > "$HOME_A/.home-alias-of"
tx_run_resume "$HOME_B" "$DROP" "$CODE" --no-exec
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "A2: resumework refused a verified home alias: $(tx_combined | tr '\n' '|')"
else
  # home class -> B's REAL home, never the alias path
  [ "$(tx_sha "$HOME_B/.claude/projects/$SLUG/$SID.jsonl")" = "$A_TRANSCRIPT" ] || fail "A2: transcript is not byte-identical under B's real \$HOME"
  [ -f "$HOME_B/.claude/session-status/$SID.txt" ] || fail "A2: caption did not land under B's real \$HOME"
  [ -e "$HOME_A/.claude" ] && fail "A2: Claude state was written under the ALIAS path ($HOME_A/.claude)"
  # abs class -> the same absolute path
  [ "$(tx_sha "$ROOT/CLAUDE.local.$SID.md")" = "$A_HANDOFF" ] || fail "A2: ROOT handoff missing or different at $ROOT"
  if [ -f "$ROOT/TRANSFER.$SID.md" ]; then
    grep -q "atest-07 item" "$ROOT/TRANSFER.$SID.md" || fail "A2: TRANSFER notes lost the sender's checklist"
    grep -q "Restored on this Mac" "$ROOT/TRANSFER.$SID.md" || fail "A2: TRANSFER notes lack the 'Restored on this Mac' record"
  else
    fail "A2: TRANSFER.$SID.md did not land at $ROOT"
  fi
  [ "$(cat "$ROOT/tmp/notes.md" 2>/dev/null)" = "context notes" ] || fail "A2: tmp/ context did not land at $ROOT/tmp/notes.md"
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$A_HEAD" ] || fail "A2: HEAD differs from A's"
  [ "$(tx_git_diff_head "$ROOT" | shasum -a 256 | cut -d' ' -f1)" = "$A_DIFF" ] || fail "A2: git diff HEAD hash differs from A's"
  [ "$(untracked_set "$ROOT")" = "$A_UNTRACKED" ] || fail "A2: untracked set differs: A=[$A_UNTRACKED] B=[$(untracked_set "$ROOT")]"
  [ -f "$DROP/$LOC.tx" ] && fail "A2: bundle not deleted after a successful restore"
fi

ok_report "07-identity-and-path-refusal" "A's home absent -> refused with the make-home-alias fix; alias marker naming another account -> refused, clone untouched; verified alias -> state under B's real \$HOME, handoff/TRANSFER/untracked/tmp at the same absolute path, HEAD + diff + untracked match"
