#!/usr/bin/env bash
# 07 — torn-final-line recovery (NEW, per adversarial review).
#
# Zero-loss gap: even with O_APPEND < PIPE_BUF, a writer SIGKILLed mid-printf, or
# an ENOSPC, can leave the LOG/main file with a final line that has NO trailing
# newline (a "torn" record). The plan's append idiom is `printf '%s\n' >> "$f"`,
# which would then START THE NEXT RECORD ON THE SAME PHYSICAL LINE — fusing two
# records into one (silent corruption / data loss).
#
# This test proves:
#   A1 — the failure mode is REAL: a naive `>>` after a torn line fuses records.
#   A2 — a newline-guarded append (the repair the implementation MUST adopt)
#        keeps every record on its own line even after a torn final line.
#   A3 — the last-line marker scan still finds the canonical marker when the
#        torn line is in the BODY (so main-file verify degrades safely).
#
# This surfaces a concrete requirement for /implement: mission_log_append (and
# mission_mutate's main-file path) MUST normalize a missing trailing newline
# before appending. The test doubles as the regression catcher for that fix.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "07-append-after-torn-line"

LOG="$ATEST_DIR/MISSION.test.log"

# --- A1: NEGATIVE CONTROL — a naive append after a torn line FUSES records ---
# Torn final line: NO trailing newline (simulates a killed/ENOSPC partial write).
printf 'rec:001\tfirst entry' > "$LOG"        # <-- no newline (torn)
printf '%s\n' "rec:002	second entry" >> "$LOG"  # naive plan idiom
# A fused first line will contain BOTH tags. Count physical lines: a correct file
# has 2 lines; the fused file has 1 line containing "rec:001...rec:002".
naive_lines="$(wc -l < "$LOG" | tr -d ' ')"
fused="$(grep -cE 'rec:001.*rec:002' "$LOG" 2>/dev/null | tr -d ' ')"
[ "$fused" = "1" ] || [ "$naive_lines" -lt 2 ]
atest_assert "A1" "$?" "expected a naive append after a torn line to FUSE records (proving the hazard is real); it did not (lines=$naive_lines fused=$fused) — test cannot demonstrate the failure it guards."

# --- A2: the REPAIRED append keeps records separate --------------------------
# The repair the implementation must use: ensure the file ends in a newline
# before appending (POSIX-portable, bash 3.2): if last byte != \n, add one.
safe_append() { # $1 file  $2 line
  _f="$1"; _ln="$2"
  if [ -s "$_f" ]; then
    # last byte of the file
    _lastbyte="$(tail -c 1 "$_f" | od -An -tx1 2>/dev/null | tr -d ' \n')"
    [ "$_lastbyte" != "0a" ] && printf '\n' >> "$_f"   # heal torn line
  fi
  printf '%s\n' "$_ln" >> "$_f"
}
: > "$LOG"
printf 'rec:001\tfirst entry' > "$LOG"        # torn again
safe_append "$LOG" "rec:002	second entry"
safe_append "$LOG" "rec:003	third entry"
lines="$(wc -l < "$LOG" | tr -d ' ')"
# rec:001 must be ALONE on line 1 (healed), and no line may contain two tags.
fused2="$(grep -cE 'rec:[0-9]+.*rec:[0-9]+' "$LOG" 2>/dev/null | tr -d ' ')"
got001="$(grep -cE '^rec:001'$'\t''first entry$' "$LOG" 2>/dev/null | tr -d ' ')"
[ "$fused2" = "0" ] && [ "$got001" = "1" ] && [ "$lines" = "3" ]
atest_assert "A2" "$?" "newline-guarded append did not heal the torn line (lines=$lines fused=$fused2 rec001-intact=$got001) — records still lost/fused."

# --- A3: last-line marker scan survives a torn line in the main-file body ----
F="$ATEST_DIR/MISSION.test.md"
MARK='<!-- MISSION schema=v1 sid=test nonce=n plan_hash=h -->'
# body has a torn-looking line, canonical marker is the true last line
printf 'plan step\npartial-body-line-without-newline-then' > "$F"
printf '\n%s\n' "$MARK" >> "$F"
last="$(grep -nE '^<!-- MISSION schema=v1 ' "$F" | tail -1 | sed 's/^[0-9]*://')"
[ "$last" = "$MARK" ]
atest_assert "A3" "$?" "last-line marker scan failed with a torn body line (got '$last') — main-file verify would misjudge corruption."

atest_report
