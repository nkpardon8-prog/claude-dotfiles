#!/usr/bin/env bash
# 03 - git state travels correctly:
#   A. unpushed commit + staged + unstaged + untracked -> HEAD, diff hash and untracked file match
#      (this is also the cwd==ROOT case: every test in this suite uses a plain repo, no separate
#      worktree, so ROOT == WT == CWD throughout).
#   B. a B clone that has not fetched A's last push needs `git fetch origin` before the bundle's
#      prerequisite commit is satisfiable - proven by a direct `git bundle verify` control that
#      fails on the still-stale clone, then a real resumework run that succeeds because it fetches.
#   C. nothing unpushed -> no bundle; resumework resolves HEAD from what B already has (or fetches).
#   D. detached HEAD survives the round trip.
#   F. transfer-send.sh refuses while a merge is in progress (MERGE_HEAD present).
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 03)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

send_ok() {  # send_ok <cwd> <sid> -> sets CODE/LOC or fails/exits 3
  tx_write_transcript "$HOME_T" "$2" "$1"
  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$2" --cwd "$1"
  [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA($3): send failed: $(tx_combined)" >&2; exit 3; }
  [ -n "$TX_LAST_CODE" ] || { echo "INFRA($3): send printed no CODE: $(tx_combined)" >&2; exit 3; }
}

# ---------------------------------------------------------------------------------------------
# A. unpushed commit + staged + unstaged + untracked; cwd == ROOT
# ---------------------------------------------------------------------------------------------
scenario_a() {
  local origin="$HOME_T/origin-a.git" wt="$HOME_T/work/proj-a" sid untracked_before diff_before head_before
  sid=$(tx_new_sid)
  tx_init_origin "$origin" "$wt" >/dev/null
  printf 'tracked v1\n' > "$wt/tracked.txt"
  git -C "$wt" add tracked.txt
  git -C "$wt" commit -q -m "add tracked"
  git -C "$wt" push -q origin HEAD
  printf 'tracked v2 (unpushed commit)\n' > "$wt/tracked.txt"
  git -C "$wt" commit -q -am "unpushed change"
  printf 'staged edit\n' >> "$wt/tracked.txt"
  git -C "$wt" add tracked.txt
  printf 'more staged\n' >> "$wt/tracked.txt"          # now also unstaged on top of the staged add
  printf 'an untracked file\n' > "$wt/scratch.txt"
  tx_write_handoff "$wt" "$sid"

  head_before=$(git -C "$wt" rev-parse HEAD)
  diff_before=$(tx_git_diff_head "$wt" | tx_sha_stdin)
  untracked_before=$(cat "$wt/scratch.txt")

  send_ok "$wt" "$sid" "A"
  local code="$TX_LAST_CODE"

  mv "$wt" "$wt.A-final"
  git clone -q "$origin" "$wt"   # B's plain, freshly-cloned ROOT before restore

  tx_run_resume "$HOME_T" "$DROP" "$code" --no-exec
  if [ "$TX_LAST_RC" -ne 0 ]; then
    fail "A: resumework exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"
    return
  fi
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "A: restored HEAD does not match sender's"
  [ "$(tx_git_diff_head "$wt" | tx_sha_stdin)" = "$diff_before" ] || fail "A: restored uncommitted diff hash does not match"
  [ -f "$wt/scratch.txt" ] || fail "A: untracked file was not restored"
  [ "$(cat "$wt/scratch.txt" 2>/dev/null)" = "$untracked_before" ] || fail "A: untracked file content differs"
  local top_phys wt_phys
  top_phys=$(cd -P "$(git -C "$wt" rev-parse --show-toplevel)" && pwd -P)
  wt_phys=$(cd -P "$wt" && pwd -P)
  [ "$top_phys" = "$wt_phys" ] || fail "A: restored repo's toplevel ($top_phys) is not the cwd ($wt_phys) - cwd==ROOT broke"
}

# ---------------------------------------------------------------------------------------------
# B. B's clone predates A's later push - the bundle's prerequisite is missing until B fetches.
# ---------------------------------------------------------------------------------------------
scenario_b() {
  local origin="$HOME_T/origin-b.git" wt="$HOME_T/work/proj-b" sid stale head_before diff_before
  sid=$(tx_new_sid)
  tx_init_origin "$origin" "$wt" >/dev/null
  stale="$HOME_T/proj-b.stale-snapshot"
  cp -R "$wt" "$stale"                                  # B's clone, frozen before A's next push

  printf 'v2\n' >> "$wt/README.md"
  git -C "$wt" commit -q -am "pushed commit A had, B has not fetched"
  git -C "$wt" push -q origin HEAD
  printf 'v3 (unpushed)\n' >> "$wt/README.md"
  git -C "$wt" commit -q -am "unpushed on top"
  tx_write_handoff "$wt" "$sid"
  head_before=$(git -C "$wt" rev-parse HEAD)
  diff_before=$(tx_git_diff_head "$wt" | tx_sha_stdin)

  send_ok "$wt" "$sid" "B"
  local code="$TX_LAST_CODE" loc="$TX_LAST_LOC"

  rm -rf "$wt"; cp -R "$stale" "$wt"                    # restore B's stale (un-fetched) clone

  # Negative control: prove the staleness is real - bundle verify fails BEFORE any fetch.
  local dec="$HOME_T/decoy-$sid"
  mkdir -p "$dec"
  if tx_decrypt "$DROP/$loc.tx" "$dec/inner.tgz" "$code" 2>/dev/null; then
    ( cd "$dec" && tar -xzf inner.tgz )
    if [ -f "$dec/git/branch.bundle" ]; then
      if git -C "$wt" bundle verify -q "$dec/git/branch.bundle" >/dev/null 2>&1; then
        fail "B: negative control broken - bundle verified against the STALE clone before any fetch (staleness was not real)"
      fi
    else
      fail "B: INFRA - no bundle in the decrypted archive to run the negative control against"
    fi
  else
    fail "B: INFRA - could not decrypt for the negative control"
  fi
  rm -rf "$dec"

  tx_run_resume "$HOME_T" "$DROP" "$code" --no-exec
  if [ "$TX_LAST_RC" -ne 0 ]; then
    fail "B: resumework exited $TX_LAST_RC after a real fetch should have fixed staleness: $(tx_combined | tr '\n' '|')"
    return
  fi
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "B: restored HEAD does not match sender's after fetch+unbundle"
  [ "$(tx_git_diff_head "$wt" | tx_sha_stdin)" = "$diff_before" ] || fail "B: restored diff hash does not match"
}

# ---------------------------------------------------------------------------------------------
# C. nothing unpushed (empty bundle case) - HEAD is resolved from what origin already has.
# ---------------------------------------------------------------------------------------------
scenario_c() {
  local origin="$HOME_T/origin-c.git" wt="$HOME_T/work/proj-c" sid head_before diff_before
  sid=$(tx_new_sid)
  tx_init_origin "$origin" "$wt" >/dev/null
  printf 'uncommitted only, HEAD fully pushed\n' >> "$wt/README.md"   # unstaged, on top of pushed HEAD
  printf 'untracked-c\n' > "$wt/scratch-c.txt"
  tx_write_handoff "$wt" "$sid"
  head_before=$(git -C "$wt" rev-parse HEAD)
  diff_before=$(tx_git_diff_head "$wt" | tx_sha_stdin)

  send_ok "$wt" "$sid" "C"
  local code="$TX_LAST_CODE" loc="$TX_LAST_LOC"

  local dec="$HOME_T/decoy-c-$sid"
  mkdir -p "$dec"
  if tx_decrypt "$DROP/$loc.tx" "$dec/inner.tgz" "$code" 2>/dev/null; then
    ( cd "$dec" && tar -xzf inner.tgz )
    if [ -f "$dec/git/branch.bundle" ]; then
      fail "C: expected NO bundle (HEAD fully pushed) but one was written"
    fi
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['git']['bundle'] is None else 1)" "$dec/manifest.json" \
      || fail "C: manifest git.bundle is not null for a fully-pushed HEAD"
  else
    fail "C: INFRA - could not decrypt to inspect the manifest"
  fi
  rm -rf "$dec"

  mv "$wt" "$wt.C-final"
  git clone -q "$origin" "$wt"

  tx_run_resume "$HOME_T" "$DROP" "$code" --no-exec
  if [ "$TX_LAST_RC" -ne 0 ]; then
    fail "C: resumework exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"
    return
  fi
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "C: restored HEAD does not match (empty-bundle path)"
  [ "$(tx_git_diff_head "$wt" | tx_sha_stdin)" = "$diff_before" ] || fail "C: restored diff hash does not match (empty-bundle path)"
  [ -f "$wt/scratch-c.txt" ] || fail "C: untracked file missing after empty-bundle restore"
}

# ---------------------------------------------------------------------------------------------
# D. detached HEAD
# ---------------------------------------------------------------------------------------------
scenario_d() {
  local origin="$HOME_T/origin-d.git" wt="$HOME_T/work/proj-d" sid head_before diff_before
  sid=$(tx_new_sid)
  tx_init_origin "$origin" "$wt" >/dev/null
  printf 'second\n' >> "$wt/README.md"
  git -C "$wt" commit -q -am "second"
  git -C "$wt" push -q origin HEAD
  git -C "$wt" checkout -q --detach HEAD
  printf 'third (unpushed, detached)\n' >> "$wt/README.md"
  git -C "$wt" commit -q -am "detached commit"
  printf 'detached uncommitted\n' >> "$wt/README.md"
  tx_write_handoff "$wt" "$sid"
  head_before=$(git -C "$wt" rev-parse HEAD)
  diff_before=$(tx_git_diff_head "$wt" | tx_sha_stdin)
  git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1 && { echo "INFRA(D): fixture is not actually detached" >&2; exit 3; }

  send_ok "$wt" "$sid" "D"
  local code="$TX_LAST_CODE"

  mv "$wt" "$wt.D-final"
  git clone -q "$origin" "$wt"

  tx_run_resume "$HOME_T" "$DROP" "$code" --no-exec
  if [ "$TX_LAST_RC" -ne 0 ]; then
    fail "D: resumework exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"
    return
  fi
  if git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail "D: restored repo is on a branch, expected detached HEAD"
  fi
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "D: restored detached HEAD does not match sender's"
  [ "$(tx_git_diff_head "$wt" | tx_sha_stdin)" = "$diff_before" ] || fail "D: restored diff hash does not match"
}

# ---------------------------------------------------------------------------------------------
# F. merge-in-progress refusal
# ---------------------------------------------------------------------------------------------
scenario_f() {
  local origin="$HOME_T/origin-f.git" wt="$HOME_T/work/proj-f" sid
  sid=$(tx_new_sid)
  tx_init_origin "$origin" "$wt" >/dev/null
  tx_write_handoff "$wt" "$sid"
  tx_write_transcript "$HOME_T" "$sid" "$wt"
  printf 'fake merge in progress\n' > "$wt/.git/MERGE_HEAD"

  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$sid" --cwd "$wt"
  [ "$TX_LAST_RC" -eq 2 ] || { fail "F: expected refuse (rc=2) with MERGE_HEAD present, got rc=$TX_LAST_RC"; return; }
  case "$TX_LAST_ERR" in
    *MERGE_HEAD*) ;;
    *) fail "F: refusal did not mention MERGE_HEAD: $TX_LAST_ERR" ;;
  esac
  [ -z "$(find "$DROP" -maxdepth 1 -type f 2>/dev/null)" ] || fail "F: a bundle was written despite the merge-in-progress refusal"
}

tx_sha_stdin() { shasum -a 256 | cut -d' ' -f1; }

scenario_a
scenario_b
scenario_c
scenario_d
scenario_f

ok_report "03-git-state-roundtrip" "A(unpushed+staged+unstaged+untracked+cwd==ROOT) B(stale-clone-needs-fetch) C(empty-bundle) D(detached-HEAD) F(merge-in-progress refusal)"
