#!/usr/bin/env bash
# 18 - a file that merely rides along with the chat (ignored repo context) is never rolled back:
#   N  B's copy is NEWER than the incoming one (another window edited it here since A last saw it)
#      -> B's copy stays in place, the incoming version lands beside it as <name>.from-<host>, and
#      the dry-run and checklist say so.
#   O  negative control: B's copy is OLDER than the incoming one -> replaced by A's version, the old
#      copy kept as <name>.bak-<ts> (the rule must not freeze every differing file).
# Found live 2026-09-26: a reverse transfer would have rolled another agent's newer plan back to the
# sender's older copy, and a count ("8 backed up first") could not show it.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 18)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"
setmtime() { python3 -c "import os,sys; os.utime(sys.argv[1], (float(sys.argv[2]), float(sys.argv[2])))" "$1" "$2"; }
NOW=$(date +%s)

ROOT="$HOME_T/work/proj"
tx_init_origin "$HOME_T/origin.git" "$ROOT" >/dev/null
ROOT=$(cd -P "$ROOT" && pwd -P)
printf 'tmp/\n' > "$ROOT/.gitignore"; git -C "$ROOT" add .gitignore; git -C "$ROOT" commit -q -m ignore; git -C "$ROOT" push -q
mkdir -p "$ROOT/tmp"
printf 'A plan (older than B edit)\n' > "$ROOT/tmp/newer-here.md"; setmtime "$ROOT/tmp/newer-here.md" $((NOW - 7200))
printf 'A plan (newer than B copy)\n' > "$ROOT/tmp/older-here.md"; setmtime "$ROOT/tmp/older-here.md" $((NOW - 3600))

SID=$(tx_new_sid)
tx_write_transcript "$HOME_T" "$SID" "$ROOT"
tx_write_handoff "$ROOT" "$SID"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$ROOT"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send failed: $(tx_combined)" >&2; exit 3; }
CODE="$TX_LAST_CODE"

# On "B": another window edited newer-here.md after A's copy; older-here.md is a stale local copy.
printf 'B edit - must survive\n' > "$ROOT/tmp/newer-here.md"; setmtime "$ROOT/tmp/newer-here.md" $((NOW - 60))
printf 'B stale copy\n' > "$ROOT/tmp/older-here.md"; setmtime "$ROOT/tmp/older-here.md" $((NOW - 86400))
B_NEWER=$(tx_sha "$ROOT/tmp/newer-here.md")

tx_run_resume "$HOME_T" "$DROP" "$CODE" --dry-run
DRY=$(tx_combined)
case "$DRY" in *"would replace"*"tmp/older-here.md"*) ;; *) fail "dry-run did not list tmp/older-here.md under 'would replace'" ;; esac
case "$DRY" in *"would replace"*"tmp/newer-here.md"*) fail "dry-run lists the newer local file as one it would replace" ;; esac
[ "$(tx_sha "$ROOT/tmp/newer-here.md")" = "$B_NEWER" ] || fail "dry-run changed a file"

tx_run_resume "$HOME_T" "$DROP" "$CODE" --no-exec
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "resumework exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"
else
  # N
  [ "$(tx_sha "$ROOT/tmp/newer-here.md")" = "$B_NEWER" ] || fail "N: the newer local file was rolled back to the sender's older copy"
  FROM=$(find "$ROOT/tmp" -maxdepth 1 -name 'newer-here.md.from-*' | head -1)
  if [ -z "$FROM" ]; then fail "N: no newer-here.md.from-<host> beside the kept file"
  else grep -q 'A plan (older than B edit)' "$FROM" || fail "N: the .from-<host> file does not hold the incoming content"; fi
  case "$(tx_combined)" in *"newer-here.md.from-"*) ;; *) fail "N: the kept-local file is not named in resumework's output" ;; esac
  # O
  grep -q 'A plan (newer than B copy)' "$ROOT/tmp/older-here.md" || fail "O: the older local copy was not replaced by the incoming one"
  [ -n "$(find "$ROOT/tmp" -maxdepth 1 -name 'older-here.md.bak-*' | head -1)" ] || fail "O: no .bak-<ts> kept for the replaced older copy"
fi

ok_report "18-newer-local-kept" "a newer local copy of a ride-along file is kept (incoming beside it as .from-<host>, named in the dry-run and checklist); an older one is still replaced with a .bak"
