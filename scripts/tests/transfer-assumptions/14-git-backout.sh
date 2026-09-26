#!/usr/bin/env bash
# 14 - a git restore that fails part-way BACKS OUT instead of leaving this Mac half-changed.
#
#   I1 new worktree: B has a plain clone; a post-checkout hook in it (the failure injector) dirties
#      the freshly created worktree, so the final `git diff HEAD` proof fails AFTER `git worktree
#      add` and `git branch`. resumework exits 1 naming what it undid: the worktree it created is
#      gone, the branch it created is gone, refs/transfer/<sid> is gone, the bundle is kept - and,
#      with the injector removed, a re-run succeeds (the back-out left a clean retry path).
#   I2 existing checkout (cwd == ROOT) with this Mac's own departure edits: they match the
#      transferred-<sid> record, so they are stashed and the branch fast-forwarded - then the patch
#      cannot apply (B has its own untracked file where the patch creates one). resumework exits 1;
#      the branch and HEAD are back where they were, the departure edits are back in the working
#      tree (no stash left), B's untracked file is untouched, and the bundle is kept.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 14)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"
sha_stdin() { shasum -a 256 | cut -d' ' -f1; }

# --- I1: failure after creating a worktree + branch ----------------------------------------------
scenario_i1() {
  local origin="$HOME_T/i1-origin.git" root="$HOME_T/work/i1" wt sid code loc a_head
  tx_init_origin "$origin" "$root" >/dev/null
  root=$(cd -P "$root" && pwd -P); wt="$root-feat"
  git -C "$root" worktree add -q -b feat "$wt"
  wt=$(cd -P "$wt" && pwd -P)
  printf 'v1\n' > "$wt/f.txt"; git -C "$wt" add f.txt; git -C "$wt" commit -q -m "unpushed"
  printf 'dirty\n' >> "$wt/f.txt"
  sid=$(tx_new_sid)
  tx_write_transcript "$HOME_T" "$sid" "$wt"
  tx_write_handoff "$root" "$sid"
  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$sid" --cwd "$wt"
  [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA(I1): send failed: $(tx_combined)" >&2; exit 3; }
  code="$TX_LAST_CODE"; loc="$TX_LAST_LOC"
  a_head=$(git -C "$wt" rev-parse HEAD)
  git -C "$root" worktree remove --force "$wt"; rm -rf "$root"
  git clone -q "$origin" "$root"
  printf '#!/bin/sh\necho injected >> README.md\n' > "$root/.git/hooks/post-checkout"
  chmod +x "$root/.git/hooks/post-checkout"

  tx_run_resume "$HOME_T" "$DROP" "$code" --no-exec
  [ "$TX_LAST_RC" -eq 1 ] || { fail "I1: expected a git failure (rc=1), got rc=$TX_LAST_RC: $(tx_combined | tr '\n' '|')"; return; }
  case "$TX_LAST_ERR" in
    *"backed out"*"removed the worktree"*"deleted the branch feat"*) ;;
    *) fail "I1: the failure did not report what it backed out: $TX_LAST_ERR" ;;
  esac
  [ -e "$wt" ] && fail "I1: the worktree it created is still at $wt"
  git -C "$root" show-ref -q --verify refs/heads/feat && fail "I1: the branch feat it created is still there"
  git -C "$root" show-ref -q --verify "refs/transfer/$sid" && fail "I1: refs/transfer/$sid was left behind"
  [ "$(git -C "$root" worktree list --porcelain | grep -c '^worktree ')" = 1 ] || fail "I1: a stale worktree registration remains"
  [ -f "$DROP/$loc.tx" ] || fail "I1: the bundle was deleted after a failed restore"

  rm -f "$root/.git/hooks/post-checkout"
  tx_run_resume "$HOME_T" "$DROP" "$code" --no-exec
  [ "$TX_LAST_RC" -eq 0 ] || { fail "I1: a re-run after the back-out failed: $(tx_combined | tr '\n' '|')"; return; }
  [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$a_head" ] || fail "I1: the re-run did not restore A's HEAD"
}

# --- I2: failure after stashing departure edits + fast-forwarding an existing checkout -------------
scenario_i2() {
  local origin="$HOME_T/i2-origin.git" root="$HOME_T/work/i2" sid code loc seed dep_diff marker
  tx_init_origin "$origin" "$root" >/dev/null
  root=$(cd -P "$root" && pwd -P)
  printf 'added by an unpushed commit\n' > "$root/tracked.txt"
  git -C "$root" add tracked.txt; git -C "$root" commit -q -m "unpushed on A"
  printf 'new in the patch\n' > "$root/newfile.txt"; git -C "$root" add newfile.txt
  sid=$(tx_new_sid)
  tx_write_transcript "$HOME_T" "$sid" "$root"
  tx_write_handoff "$root" "$sid"
  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$sid" --cwd "$root"
  [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA(I2): send failed: $(tx_combined)" >&2; exit 3; }
  code="$TX_LAST_CODE"; loc="$TX_LAST_LOC"
  mv "$root" "$root.A-final"
  git clone -q "$origin" "$root"
  seed=$(git -C "$root" rev-parse HEAD)
  printf 'B departure edit\n' >> "$root/README.md"
  dep_diff=$(tx_git_diff_head "$root" | sha_stdin)
  marker="$HOME_T/.claude/progress/transferred-$sid"
  mkdir -p "$(dirname "$marker")"
  printf 'sid=%s\ntool=claude\nhead=%s\ndiff_sha256=%s\n' "$sid" "$seed" "$dep_diff" > "$marker"
  printf "B's own file\n" > "$root/newfile.txt"

  tx_run_resume "$HOME_T" "$DROP" "$code" --no-exec
  [ "$TX_LAST_RC" -eq 1 ] || { fail "I2: expected a git failure (rc=1), got rc=$TX_LAST_RC: $(tx_combined | tr '\n' '|')"; return; }
  case "$TX_LAST_ERR" in
    *"did not apply cleanly"*"backed out"*"departure edits back"*) ;;
    *) fail "I2: the failure did not report the back-out: $TX_LAST_ERR" ;;
  esac
  [ "$(git -C "$root" rev-parse HEAD)" = "$seed" ] || fail "I2: HEAD was not returned to its previous commit"
  [ "$(git -C "$root" symbolic-ref -q --short HEAD)" = "$(git -C "$origin" symbolic-ref --short HEAD)" ] || fail "I2: the checkout is no longer on its previous branch"
  [ "$(tx_git_diff_head "$root" | sha_stdin)" = "$dep_diff" ] || fail "I2: this Mac's departure edits are not back in the working tree"
  git -C "$root" stash list | grep -q transfer-backup- && fail "I2: the transfer-backup stash was left behind (edits not put back)"
  [ "$(cat "$root/newfile.txt")" = "B's own file" ] || fail "I2: B's own untracked file was changed"
  [ -e "$root/tracked.txt" ] && fail "I2: a file from the fast-forwarded commit is still in the working tree"
  [ -f "$marker" ] || fail "I2: the departure record was deleted by a failed restore"
  [ -f "$DROP/$loc.tx" ] || fail "I2: the bundle was deleted after a failed restore"
}

scenario_i1
scenario_i2

ok_report "14-git-backout" "failure after worktree add + branch create -> both removed, ref cleaned, bundle kept, re-run succeeds; failure after stash + fast-forward -> HEAD/branch restored, departure edits popped back, untracked file untouched"
