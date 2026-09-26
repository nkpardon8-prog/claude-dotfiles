#!/usr/bin/env bash
# 13 - the normal dentall layout: the chat works in a SEPARATE worktree (WT != ROOT) beside the main
# checkout, while its handoff and TRANSFER notes live at ROOT (the canonical anchor).
#
#   G  round trip: B has only a plain clone of ROOT. resumework re-creates the worktree at the same
#      path on the same branch; HEAD, the `git diff HEAD` hash, the untracked set and tmp/ context
#      match A; the handoff and TRANSFER notes land at ROOT, not in the worktree.
#   H  refusal: on B the chat's branch is already checked out in ANOTHER worktree - refused (exit 2)
#      with a message naming that worktree; nothing changes (no worktree created, branch unmoved,
#      the other worktree untouched, bundle kept).
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 13)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"
untracked_set() { git -C "$1" ls-files -o --exclude-standard | sort | while IFS= read -r f; do printf '%s %s\n' "$(tx_sha "$1/$f")" "$f"; done; }

# setup_a <name> -> ROOT, WT (branch feat: an unpushed commit, staged + unstaged edits, untracked,
# tmp/ context), a transcript for cwd=WT and a handoff + TRANSFER notes at ROOT; then sends.
setup_a() {
  ORIGIN="$HOME_T/$1-origin.git"; ROOT="$HOME_T/work/$1"
  tx_init_origin "$ORIGIN" "$ROOT" >/dev/null
  ROOT=$(cd -P "$ROOT" && pwd -P); WT="$ROOT-feat"
  git -C "$ROOT" worktree add -q -b feat "$WT"
  WT=$(cd -P "$WT" && pwd -P)
  printf 'v1\n' > "$WT/f.txt"; git -C "$WT" add f.txt; git -C "$WT" commit -q -m "unpushed on feat"
  printf 'staged\n' >> "$WT/f.txt"; git -C "$WT" add f.txt
  printf 'unstaged\n' >> "$WT/f.txt"
  printf 'untracked\n' > "$WT/u.txt"
  mkdir -p "$WT/tmp"; printf 'wt context\n' > "$WT/tmp/ctx.md"
  SID=$(tx_new_sid)
  tx_write_transcript "$HOME_T" "$SID" "$WT"
  tx_write_handoff "$ROOT" "$SID"
  printf '# Transfer notes - %s\n\n## Restart checklist on the new Mac\n- [ ] atest-13 item\n' "$SID" > "$ROOT/TRANSFER.$SID.md"
  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$WT"
  [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA($1): send failed: $(tx_combined)" >&2; exit 3; }
  CODE="$TX_LAST_CODE"; LOC="$TX_LAST_LOC"
  A_HEAD=$(git -C "$WT" rev-parse HEAD)
  A_DIFF=$(tx_git_diff_head "$WT" | shasum -a 256 | cut -d' ' -f1)
  A_UNTRACKED=$(untracked_set "$WT")
  A_HANDOFF=$(tx_sha "$ROOT/CLAUDE.local.$SID.md")
  # B: a plain fresh clone of ROOT, no worktree, no handoff.
  git -C "$ROOT" worktree remove --force "$WT"
  rm -rf "$ROOT"
  git clone -q "$ORIGIN" "$ROOT"
}

# --- G: round trip ---------------------------------------------------------------------------------
setup_a g
tx_run_resume "$HOME_T" "$DROP" "$CODE" --no-exec
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "G: resumework failed: $(tx_combined | tr '\n' '|')"
else
  [ "$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null)" = "feat" ] || fail "G: worktree not re-created on branch feat"
  [ "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)" ] \
    || fail "G: $WT is not a worktree of $ROOT"
  [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" = "$A_HEAD" ] || fail "G: HEAD differs"
  [ "$(tx_git_diff_head "$WT" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)" = "$A_DIFF" ] || fail "G: git diff HEAD hash differs"
  [ "$(untracked_set "$WT")" = "$A_UNTRACKED" ] || fail "G: untracked set differs: A=[$A_UNTRACKED] B=[$(untracked_set "$WT")]"
  [ "$(cat "$WT/tmp/ctx.md" 2>/dev/null)" = "wt context" ] || fail "G: worktree tmp/ context missing"
  [ "$(tx_sha "$ROOT/CLAUDE.local.$SID.md")" = "$A_HANDOFF" ] || fail "G: handoff did not land at ROOT"
  [ -e "$WT/CLAUDE.local.$SID.md" ] && fail "G: handoff landed in the worktree instead of ROOT"
  grep -q "atest-13 item" "$ROOT/TRANSFER.$SID.md" 2>/dev/null || fail "G: TRANSFER notes missing at ROOT"
fi

# --- H: branch already checked out in another worktree on B ------------------------------------------
setup_a h
OTHER="$HOME_T/work/h-other"
git -C "$ROOT" fetch -q origin
git -C "$ROOT" worktree add -q -b feat "$OTHER" 2>/dev/null || { echo "INFRA(H): could not create the other worktree" >&2; exit 3; }
OTHER=$(cd -P "$OTHER" && pwd -P)
OTHER_HEAD=$(git -C "$OTHER" rev-parse HEAD)
tx_run_resume "$HOME_T" "$DROP" "$CODE" --no-exec
[ "$TX_LAST_RC" -eq 2 ] || fail "H: expected refuse (rc=2) with feat checked out in another worktree, got rc=$TX_LAST_RC: $(tx_combined | tr '\n' '|')"
case "$TX_LAST_ERR" in
  *"checked out in another worktree"*"$OTHER"*) ;;
  *) fail "H: refusal did not name the other worktree: $TX_LAST_ERR" ;;
esac
[ -e "$WT" ] && fail "H: the chat's worktree was created despite the refusal"
[ "$(git -C "$ROOT" rev-parse refs/heads/feat)" = "$OTHER_HEAD" ] || fail "H: branch feat was moved despite the refusal"
[ "$(git -C "$OTHER" rev-parse HEAD)" = "$OTHER_HEAD" ] || fail "H: the other worktree was changed"
git -C "$ROOT" show-ref -q --verify "refs/transfer/$SID" && fail "H: refs/transfer/$SID was left behind"
[ -f "$DROP/$LOC.tx" ] || fail "H: the bundle was deleted by a refused restore"
[ -e "$ROOT/CLAUDE.local.$SID.md" ] && fail "H: files were placed despite the refusal"

ok_report "13-separate-worktree" "WT != ROOT: worktree re-created on its branch with HEAD/diff/untracked/tmp matching and handoff/TRANSFER at ROOT; branch checked out in another worktree on B -> refused with its path, nothing changed"
