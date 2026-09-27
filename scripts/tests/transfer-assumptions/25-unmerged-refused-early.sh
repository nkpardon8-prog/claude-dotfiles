#!/usr/bin/env bash
# 25 - files left half-merged are refused AT SEND TIME, in seconds, before anything is packed.
#   U  a `git stash pop` that conflicts leaves unmerged index entries but NO MERGE_HEAD (so the
#      in-progress-operation guard does not fire). A patch cannot carry git's conflict stages; found
#      live 2026-09-27 when the receiving Mac rebuilt a different index and backed out only after
#      a full ~700 MB upload. The send must exit 2 naming the conflicted file, with no bundle.
#   R  negative control: once the conflict is resolved (git add), the same chat sends normally.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 25)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

ROOT="$HOME_T/work/proj"
tx_init_origin "$HOME_T/origin.git" "$ROOT" >/dev/null
ROOT=$(cd -P "$ROOT" && pwd -P)
# Build a stash-pop conflict: stash an edit, commit a clashing edit, pop.
printf 'stashed line\n' > "$ROOT/README.md"
git -C "$ROOT" stash -q
printf 'committed line\n' > "$ROOT/README.md"
git -C "$ROOT" commit -q -am "clashing edit"
git -C "$ROOT" stash pop -q >/dev/null 2>&1
[ -n "$(git -C "$ROOT" diff --name-only --diff-filter=U)" ] || { echo "INFRA: fixture did not produce an unmerged path" >&2; exit 3; }
[ ! -e "$ROOT/.git/MERGE_HEAD" ] || { echo "INFRA: fixture left a MERGE_HEAD; it must model the no-operation case" >&2; exit 3; }

SID=$(tx_new_sid)
tx_write_transcript "$HOME_T" "$SID" "$ROOT"
tx_write_handoff "$ROOT" "$SID"

# U
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 2 ] || fail "U: send with a conflicted file exited $TX_LAST_RC, expected 2 (refused)"
case "$(tx_combined)" in *"unresolved merge conflicts"*README.md*) ;; *) fail "U: the refusal does not say 'unresolved merge conflicts' and name README.md: $(tx_combined | tr '\n' '|')" ;; esac
[ -z "$(find "$DROP" -name '*.tx' 2>/dev/null | head -1)" ] || fail "U: a bundle was published despite the refusal"

# R
printf 'resolved line\n' > "$ROOT/README.md"; git -C "$ROOT" add README.md; git -C "$ROOT" stash drop -q 2>/dev/null
tx_write_handoff "$ROOT" "$SID"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || fail "R: send after resolving the conflict exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"

ok_report "25-unmerged-refused-early" "half-merged files (a conflicted stash pop, no MERGE_HEAD) are refused at send time naming the file, with no bundle; once resolved the same chat sends"
