#!/usr/bin/env bash
# 01 - a fake Claude session round-trips byte-identical, with mtimes preserved, and resumework
# leaves a transfer-arrived-<sid> marker (mode 600) behind for the primer to notice.
#
# One sandbox $HOME plays both Mac A (transfer-send.sh) and Mac B (resumework): CWD/ROOT are
# absolute paths that must already match on both ends anyway, so this is the same same-machine
# proxy the plan uses for assumption A1. The transcript/caption/memory file are deleted after
# sending and BEFORE restoring, so recreating them proves the round trip, not mere presence.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 01)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT

DROP="$HOME_T/drop"
SID=$(tx_new_sid)
CWD="$HOME_T/work/proj"
mkdir -p "$CWD"

tx_write_transcript "$HOME_T" "$SID" "$CWD"
tx_write_caption "$HOME_T" "$SID" "atest-01-caption"
SLUG=$(tx_slug "$CWD")
MEMDIR="$HOME_T/.claude/projects/$SLUG/memory"
mkdir -p "$MEMDIR"
printf 'A remembers: PINEAPPLE-42\n' > "$MEMDIR/MEMORY.md"
tx_write_handoff "$CWD" "$SID"

TRANSCRIPT="$HOME_T/.claude/projects/$SLUG/$SID.jsonl"
CAPTION="$HOME_T/.claude/session-status/$SID.txt"
MEMFILE="$MEMDIR/MEMORY.md"
[ -f "$TRANSCRIPT" ] || { echo "INFRA: fixture transcript missing" >&2; exit 3; }

SAVE=$(tx_sandbox 01-save)
cp "$TRANSCRIPT" "$SAVE/transcript.jsonl"
cp "$CAPTION" "$SAVE/caption.txt"
cp "$MEMFILE" "$SAVE/memory.md"
T_SHA=$(tx_sha "$TRANSCRIPT"); T_MT=$(tx_mtime "$TRANSCRIPT")
C_SHA=$(tx_sha "$CAPTION");    C_MT=$(tx_mtime "$CAPTION")
M_SHA=$(tx_sha "$MEMFILE");    M_MT=$(tx_mtime "$MEMFILE")

tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$CWD"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: send failed: $(tx_combined)" >&2; exit 3; }
[ -n "$TX_LAST_CODE" ] || { echo "INFRA: send printed no CODE: $(tx_combined)" >&2; exit 3; }
CODE="$TX_LAST_CODE"
LOC="$TX_LAST_LOC"
[ -f "$DROP/$LOC.tx" ] && [ -f "$DROP/$LOC.tx.sha256" ] || { echo "INFRA: bundle/sidecar missing after send" >&2; exit 3; }

# Delete the originals - B does not have them yet. The project directory itself stays (it is the
# non-git ROOT, which resumework requires to already exist).
rm -f "$TRANSCRIPT" "$CAPTION" "$MEMFILE"

tx_run_resume "$HOME_T" "$DROP" "$CODE" --no-exec
if [ "$TX_LAST_RC" -ne 0 ]; then
  fail "resumework exited $TX_LAST_RC: $(tx_combined | tr '\n' '|')"
else
  [ -f "$TRANSCRIPT" ] || fail "transcript was not restored at $TRANSCRIPT"
  [ -f "$CAPTION" ]    || fail "caption was not restored at $CAPTION"
  [ -f "$MEMFILE" ]    || fail "memory file was not restored at $MEMFILE"
  if [ -f "$TRANSCRIPT" ]; then
    [ "$(tx_sha "$TRANSCRIPT")" = "$T_SHA" ] || fail "transcript content differs after restore"
    [ "$(tx_mtime "$TRANSCRIPT")" = "$T_MT" ] || fail "transcript mtime not preserved (want $T_MT got $(tx_mtime "$TRANSCRIPT"))"
    grep -q "PINEAPPLE-42" "$TRANSCRIPT" || fail "restored transcript lost its content marker"
  fi
  if [ -f "$CAPTION" ]; then
    [ "$(tx_sha "$CAPTION")" = "$C_SHA" ] || fail "caption content differs after restore"
    [ "$(tx_mtime "$CAPTION")" = "$C_MT" ] || fail "caption mtime not preserved"
  fi
  if [ -f "$MEMFILE" ]; then
    [ "$(tx_sha "$MEMFILE")" = "$M_SHA" ] || fail "memory file content differs after restore"
    [ "$(tx_mtime "$MEMFILE")" = "$M_MT" ] || fail "memory file mtime not preserved"
  fi
  ARRIVED="$HOME_T/.claude/progress/transfer-arrived-$SID"
  if [ -f "$ARRIVED" ]; then
    PERM=$(stat -f %Lp "$ARRIVED" 2>/dev/null)
    [ "$PERM" = "600" ] || fail "transfer-arrived marker mode is $PERM, want 600"
  else
    fail "no transfer-arrived-$SID marker was written"
  fi
  [ -f "$DROP/$LOC.tx" ] && fail "bundle was not deleted after a successful single-use restore"
  [ -f "$DROP/$LOC.tx.sha256" ] && fail "sidecar was not deleted after a successful single-use restore"
fi

# ---------------------------------------------------------------------------------------------
# Exec argv: resumework always launches unattended by default (--dangerously-skip-permissions),
# deduped against a recorded argv that already had it, and omits it under --safe.
# ---------------------------------------------------------------------------------------------
STUB="$HOME_T/bin/fake-claude"
mkdir -p "$HOME_T/bin"
cat > "$STUB" <<'STUBSCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TX_TEST_ARGV_CAPTURE"
exit 0
STUBSCRIPT
chmod +x "$STUB"
CAPTURE="$HOME_T/argv-capture.txt"

send_for_argv() {  # send_for_argv <sid> -> fresh transcript+handoff+send, sets $ARGV_CODE
  tx_write_transcript "$HOME_T" "$1" "$CWD"
  tx_write_handoff "$CWD" "$1"
  tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$1" --cwd "$CWD"
  [ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: argv-test send failed: $(tx_combined)" >&2; exit 3; }
  ARGV_CODE="$TX_LAST_CODE"
}

SID_ARGV1=$(tx_new_sid)
send_for_argv "$SID_ARGV1"
rm -f "$CAPTURE"
( HOME="$HOME_T" TX_DROP_DIR="$DROP" TX_CLAUDE_BIN="$STUB" TX_TEST_ARGV_CAPTURE="$CAPTURE" "$TX_RESUME" "$ARGV_CODE" ) \
  >"$HOME_T/.argv1.out" 2>"$HOME_T/.argv1.err"
if [ ! -f "$CAPTURE" ]; then
  fail "argv default: the stub claude binary was never exec'd: $(cat "$HOME_T/.argv1.out" "$HOME_T/.argv1.err")"
else
  grep -qx -- "--dangerously-skip-permissions" "$CAPTURE" \
    || fail "argv default: --dangerously-skip-permissions is missing from the exec argv: $(tr '\n' '|' < "$CAPTURE")"
  N=$(grep -cx -- "--dangerously-skip-permissions" "$CAPTURE")
  [ "$N" = 1 ] || fail "argv default: --dangerously-skip-permissions appeared $N times, want exactly 1"
  grep -qx -- "--resume" "$CAPTURE" || fail "argv default: --resume is missing from the exec argv"
fi

SID_ARGV2=$(tx_new_sid)
send_for_argv "$SID_ARGV2"
rm -f "$CAPTURE"
( HOME="$HOME_T" TX_DROP_DIR="$DROP" TX_CLAUDE_BIN="$STUB" TX_TEST_ARGV_CAPTURE="$CAPTURE" "$TX_RESUME" "$ARGV_CODE" --safe ) \
  >"$HOME_T/.argv2.out" 2>"$HOME_T/.argv2.err"
if [ ! -f "$CAPTURE" ]; then
  fail "argv --safe: the stub claude binary was never exec'd: $(cat "$HOME_T/.argv2.out" "$HOME_T/.argv2.err")"
else
  grep -qx -- "--dangerously-skip-permissions" "$CAPTURE" \
    && fail "argv --safe: --dangerously-skip-permissions was added despite --safe: $(tr '\n' '|' < "$CAPTURE")"
fi

# --dangerously-skip-permissions is deduped, never doubled, when A's own recorded argv already
# had it (argv[0] carries the fake flags - a symlinked/copied real binary would be SIGKILLed by
# macOS code signing, so a plain background process with a doctored argv[0] stands in for "A was
# already running with this flag").
SID_ARGV3=$(tx_new_sid)
send_for_argv "$SID_ARGV3"
bash -c 'exec -a "claude --dangerously-skip-permissions" sleep 30' &
FAKE_REG_PID=$!
disown "$FAKE_REG_PID" 2>/dev/null
sleep 0.2
kill -0 "$FAKE_REG_PID" 2>/dev/null || { echo "INFRA: dedupe fixture process died immediately" >&2; exit 3; }
tx_write_session "$HOME_T" "$SID_ARGV3" "$CWD" "$FAKE_REG_PID"
# Re-send so transfer-send.sh reads THIS pid's argv into the manifest (py_registry matches on sid).
tx_write_transcript "$HOME_T" "$SID_ARGV3" "$CWD"
tx_write_handoff "$CWD" "$SID_ARGV3"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID_ARGV3" --cwd "$CWD"
kill "$FAKE_REG_PID" 2>/dev/null; wait "$FAKE_REG_PID" 2>/dev/null
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: dedupe-fixture send failed: $(tx_combined)" >&2; exit 3; }
rm -f "$CAPTURE"
( HOME="$HOME_T" TX_DROP_DIR="$DROP" TX_CLAUDE_BIN="$STUB" TX_TEST_ARGV_CAPTURE="$CAPTURE" "$TX_RESUME" "$TX_LAST_CODE" ) \
  >"$HOME_T/.argv3.out" 2>"$HOME_T/.argv3.err"
if [ ! -f "$CAPTURE" ]; then
  fail "argv dedupe: the stub claude binary was never exec'd: $(cat "$HOME_T/.argv3.out" "$HOME_T/.argv3.err")"
else
  N=$(grep -cx -- "--dangerously-skip-permissions" "$CAPTURE")
  [ "$N" = 1 ] || fail "argv dedupe: --dangerously-skip-permissions appeared $N times (A's own argv already had it), want exactly 1"
fi

# -n <handle>: the Remote Control display name (ListAgents). By the /line rule the display name IS
# the peer handle (LAC slugify: lowercase, non-alnum -> hyphen, collapsed, trimmed), never the
# caption SENTENCE - so a sentence caption must arrive as its handle, and the sentence must not.
SID_ARGV4=$(tx_new_sid)
send_for_argv "$SID_ARGV4"
tx_write_caption "$HOME_T" "$SID_ARGV4" "Argv > Caption  Check!"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID_ARGV4" --cwd "$CWD"
[ "$TX_LAST_RC" -eq 0 ] || { echo "INFRA: caption-argv send failed: $(tx_combined)" >&2; exit 3; }
rm -f "$CAPTURE"
# A private TMPDIR, so "resumework removed its decrypted staging copy before exec" is checkable.
RTMP="$HOME_T/rtmp"; mkdir -p "$RTMP"
( HOME="$HOME_T" TMPDIR="$RTMP" TX_DROP_DIR="$DROP" TX_CLAUDE_BIN="$STUB" TX_TEST_ARGV_CAPTURE="$CAPTURE" "$TX_RESUME" "$TX_LAST_CODE" ) \
  >"$HOME_T/.argv4.out" 2>"$HOME_T/.argv4.err"
if [ ! -f "$CAPTURE" ]; then
  fail "argv -n: the stub claude binary was never exec'd: $(cat "$HOME_T/.argv4.out" "$HOME_T/.argv4.err")"
else
  N_VAL=$(awk 'p { print; exit } $0 == "-n" { p = 1 }' "$CAPTURE")
  [ "$N_VAL" = "argv-caption-check" ] || fail "argv -n: want the handle 'argv-caption-check' after -n, got '$N_VAL': $(tr '\n' '|' < "$CAPTURE")"
  grep -qxF -- "Argv > Caption  Check!" "$CAPTURE" && fail "argv -n: the raw caption SENTENCE reached the exec argv"
fi
[ -z "$(find "$RTMP" -mindepth 1 -maxdepth 1 -name 'tx-recv.*' 2>/dev/null)" ] \
  || fail "exec: resumework left its decrypted staging dir in \$TMPDIR after launching"

ok_report "01-claude-roundtrip" "byte-identical transcript/caption/memory, mtimes preserved, transfer-arrived marker, single-use delete, exec argv defaults to --dangerously-skip-permissions (deduped) and --safe omits it, -n carries the /line handle (not the caption sentence), no decrypted staging left after exec"
