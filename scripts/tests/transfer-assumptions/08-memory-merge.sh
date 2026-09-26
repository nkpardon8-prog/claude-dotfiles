#!/usr/bin/env bash
# 08 - a memory-dir conflict never overwrites B's own file: B's version wins in place, and the
# incoming version is saved beside it as <name>.from-<host>.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 08)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

SID=$(tx_new_sid)
CWD="$HOME_T/work/proj"
mkdir -p "$CWD"
tx_write_transcript "$HOME_T" "$SID" "$CWD"
tx_write_handoff "$CWD" "$SID"
SLUG=$(tx_slug "$CWD")
MEMDIR="$HOME_T/.claude/projects/$SLUG/memory"
mkdir -p "$MEMDIR"
printf 'A version of MEMORY.md\n' > "$MEMDIR/MEMORY.md"

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$CWD"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send failed: $(tx_combined)" >&2; exit 3; }
CODE="$TX_LAST_CODE"

# B already has its OWN, DIFFERENT memory file at the same path - a genuine conflict, not a fresh
# arrival (which would just be "NEW", already covered by test 01).
printf 'B version of MEMORY.md (must survive)\n' > "$MEMDIR/MEMORY.md"
B_SHA=$(tx_sha "$MEMDIR/MEMORY.md")

tx_run_resume "$HOME_T" "$DROP" "$CODE" --no-exec
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "resumework exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"
else
  [ "$(tx_sha "$MEMDIR/MEMORY.md")" = "$B_SHA" ] || fail "B's own memory file was overwritten by the incoming one"
  FROM=$(find "$MEMDIR" -maxdepth 1 -name "MEMORY.md.from-*" 2>/dev/null | head -1)
  [ -n "$FROM" ] || fail "no MEMORY.md.from-<host> file was created for the incoming version"
  if [ -n "$FROM" ]; then
    grep -q "A version of MEMORY.md" "$FROM" || fail "the .from-<host> file does not hold A's incoming content"
  fi
  case "$(tx_combined)" in
    *"$(basename "$FROM" 2>/dev/null)"* | *"memory conflict"* | *"kept beside"*) ;;
    *) fail "the memory conflict was not mentioned in resumework's output/checklist" ;;
  esac
  TF="$CWD/TRANSFER.$SID.md"
  if [ -f "$TF" ]; then
    grep -qi "memory conflict" "$TF" || fail "TRANSFER.$SID.md does not record the memory conflict"
  else
    fail "no TRANSFER.$SID.md was written on B"
  fi
fi

ok_report "08-memory-merge" "B's own memory file survives untouched; the incoming version lands beside it as MEMORY.md.from-<host> and is listed in the checklist and TRANSFER notes"
