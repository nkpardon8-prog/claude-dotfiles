#!/usr/bin/env bash
# 11 - reverse transfer: the departure-state stash.
#
# In the real two-Mac flow, A's own transferred-<sid> marker (written by A's original send) sits
# untouched on A's disk while the chat lives on B - it is only cleared when resumework runs ON A
# again. So when B eventually sends the chat back, A's worktree may still be sitting exactly as A
# left it (dirty), and resumework on A must recognize "this dirty state is MY OWN prior departure"
# and stash it safely rather than refuse or clobber it.
#
#   A1 (positive): the destination's actual dirty state (E1) exactly matches its own recorded
#      transferred-<sid> departure - resumework stashes it as transfer-backup-<ts>, applies the
#      incoming content (E2) on top, and deletes transferred-<sid>.
#   A2 (negative control): the recorded departure does NOT match the destination's actual dirty
#      state (drift) - resumework refuses, and the destination's dirty content is left untouched
#      (nothing stashed, nothing overwritten).
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 11)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"
tx_sha_stdin() { shasum -a 256 | cut -d' ' -f1; }

write_departure_marker() {  # write_departure_marker <sid> <head> <diff_sha256>
  local f="$HOME_T/.claude/progress/transferred-$1"
  mkdir -p "$(dirname "$f")"
  printf 'sid=%s\ntool=claude\nlocator=x\nsent_at=x\nworktree=x\nhead=%s\ndiff_sha256=%s\n' "$1" "$2" "$3" > "$f"
}

# ---------------------------------------------------------------------------------------------
# A1: matching departure -> stash + apply incoming
# ---------------------------------------------------------------------------------------------
scenario_a1() {
  local origin="$HOME_T/origin-a1.git" p="$HOME_T/work/proj-a1" sid1 sid2
  sid1=$(tx_new_sid)
  tx_init_origin "$origin" "$p" >/dev/null

  # "B's" incoming send: an edit E2 on top of the same pushed HEAD.
  sid2=$(tx_new_sid)
  printf 'B edit E2\n' >> "$p/README.md"
  tx_write_handoff "$p" "$sid2"
  tx_write_transcript "$HOME_T" "$sid2" "$p"
  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$sid2" --cwd "$p"
  [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA(A1): incoming send failed: $(tx_combined)" >&2; exit 3; }
  local incoming_code="$TX_LAST_CODE" incoming_head incoming_diff
  incoming_head=$(git -C "$p" rev-parse HEAD)
  incoming_diff=$(tx_git_diff_head "$p" | tx_sha_stdin)
  rm -f "$HOME_T/.claude/progress/transferred-$sid2"     # this send's own marker is irrelevant here

  # Now set P's CURRENT on-disk state to A's own separate departure edit E1 (different from E2).
  git -C "$p" checkout -q -- README.md
  printf 'A departure edit E1\n' >> "$p/README.md"
  local a_head a_diff
  a_head=$(git -C "$p" rev-parse HEAD)
  a_diff=$(tx_git_diff_head "$p" | tx_sha_stdin)
  write_departure_marker "$sid2" "$a_head" "$a_diff"

  tx_run_resume "$HOME_T" "$DROP" "$incoming_code" --no-exec
  if [ "$TX_LAST_RC" -ne 0 ]; then
    fail "A1: resumework refused a dirty state matching its own recorded departure: $(tx_combined | tr '\n' '|')"
    return
  fi
  [ "$(git -C "$p" rev-parse HEAD)" = "$incoming_head" ] || fail "A1: HEAD after restore does not match the incoming bundle's HEAD"
  [ "$(tx_git_diff_head "$p" | tx_sha_stdin)" = "$incoming_diff" ] || fail "A1: uncommitted diff after restore does not match the incoming (E2) content"
  git -C "$p" stash list 2>/dev/null | grep -q "transfer-backup-" || fail "A1: no transfer-backup-<ts> stash was created for the departed (E1) edits"
  [ -f "$HOME_T/.claude/progress/transferred-$sid2" ] && fail "A1: transferred-$sid2 marker was not deleted on arrival"
  local stash_ref
  stash_ref=$(git -C "$p" stash list 2>/dev/null | grep "transfer-backup-" | head -1 | cut -d: -f1)
  if [ -n "$stash_ref" ]; then
    git -C "$p" stash show -p "$stash_ref" 2>/dev/null | grep -q "A departure edit E1" \
      || fail "A1: the stash does not contain A's departed (E1) content - it would have been lost"
  fi
}

# ---------------------------------------------------------------------------------------------
# A2: recorded departure does NOT match actual dirty state -> refuse, nothing touched
# ---------------------------------------------------------------------------------------------
scenario_a2() {
  local origin="$HOME_T/origin-a2.git" p="$HOME_T/work/proj-a2" sid2
  tx_init_origin "$origin" "$p" >/dev/null

  sid2=$(tx_new_sid)
  printf 'B edit E2\n' >> "$p/README.md"
  tx_write_handoff "$p" "$sid2"
  tx_write_transcript "$HOME_T" "$sid2" "$p"
  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$sid2" --cwd "$p"
  [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA(A2): incoming send failed: $(tx_combined)" >&2; exit 3; }
  local incoming_code="$TX_LAST_CODE"
  rm -f "$HOME_T/.claude/progress/transferred-$sid2"

  git -C "$p" checkout -q -- README.md
  printf 'A departure edit E1 (drifted)\n' >> "$p/README.md"
  local dirty_before dirty_diff_before
  dirty_before=$(cat "$p/README.md")
  dirty_diff_before=$(tx_git_diff_head "$p" | tx_sha_stdin)
  # A marker recording a DIFFERENT diff than what's actually sitting dirty right now (drift).
  write_departure_marker "$sid2" "$(git -C "$p" rev-parse HEAD)" "$(printf 'mismatch' | tx_sha_stdin)"

  tx_run_resume "$HOME_T" "$DROP" "$incoming_code" --no-exec
  [ "$TX_LAST_RC" -ne 0 ] || fail "A2: resumework proceeded despite a departure-state mismatch (should refuse)"
  [ "$(cat "$p/README.md")" = "$dirty_before" ] || fail "A2: the destination's dirty content was changed despite the refusal"
  [ "$(tx_git_diff_head "$p" | tx_sha_stdin)" = "$dirty_diff_before" ] || fail "A2: the destination's diff hash changed despite the refusal"
  git -C "$p" stash list 2>/dev/null | grep -q "transfer-backup-" && fail "A2: a stash was created despite the refusal"
}

scenario_a1
scenario_a2

ok_report "11-reverse-transfer" "matching own departure state is stashed as transfer-backup-<ts> then the incoming content applied and the marker cleared; a drifted departure is refused with nothing touched"
