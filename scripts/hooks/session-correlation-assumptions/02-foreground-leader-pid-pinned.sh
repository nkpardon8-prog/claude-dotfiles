#!/usr/bin/env bash
# 02-foreground-leader-pid-pinned.sh
#
# A3 — `ac_pid_is_foreground_leader_on_tty <pid> <ttysN>` returns true ONLY for the SPECIFIC live
#      claude pid that is the foreground-PG leader (`+`) on that exact tty, and false for:
#        (a) a dead pid,
#        (b) a live NON-claude pid,
#        (c) the right claude pid on the WRONG tty,
#        (d) a SIBLING session's claude pid on THIS tty  <-- THE 2026-05-31 04:42Z incident shape.
#
#   (d) is the load-bearing assertion: today's code matches ANY foreground claude on the tty, which
#   is exactly the bug. Pinning to the specific pid must REJECT a sibling session's legitimate claude.
#
# NEGATIVE CONTROL (controllable preconditions): each false-case (a)-(d) is a real flip of the input;
#   the single true-case is the live self. If any false-case returned true, the guard is worthless.
#
# Exit: 0 PASS · 1 FAIL · 2 REFUSED · 3 INFRASTRUCTURE
set -uo pipefail
[ "${CORRELATION_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set CORRELATION_TESTS_ALLOW_DEV=true to run assumption tests" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$HERE/02-foreground-leader-pid-pinned.fingerprint.json"
ERE='(^| |\/)claude( |$)'

# --- candidate helper under test (mirrors plan ac_pid_is_foreground_leader_on_tty) ---
fg_leader_on_tty() {   # $1=pid $2=ttysN ; rc0 iff pid is '+' leader on tty AND its argv is claude
  ps -ww -t "$2" -o stat=,pid=,args= 2>/dev/null \
    | awk -v want="$1" '$1 ~ /\+/ && $2==want && $0 ~ /(^| |\/)claude( |$)/ {f=1} END{exit f?0:1}'
}
own_claude() { local p="${PPID:-}" h a; for h in 1 2 3 4 5 6 7 8; do [ -z "$p" ]&&break; { [ "$p" = 0 ]||[ "$p" = 1 ]; }&&break; a=$(ps -ww -o args= -p "$p" 2>/dev/null); printf '%s' "$a"|grep -Eq '(^|[[:space:]/])claude([[:space:]]|$)'&&{ printf '%s' "$p"; return 0; }; p=$(ps -o ppid= -p "$p" 2>/dev/null|tr -d ' '); done; return 1; }

MYPID=$(own_claude) || { echo "INFRASTRUCTURE: no claude ancestor (run inside a Claude session)" >&2; exit 3; }
MYTTY=$(ps -o tty= -p "$MYPID" 2>/dev/null | tr -d '[:space:]')
case "$MYTTY" in ttys[0-9]*) : ;; *) echo "INFRASTRUCTURE: own claude tty unresolved ('$MYTTY')" >&2; exit 3 ;; esac

fails=()
sib_tested=0

# TRUE case — own claude pid on own tty must verify
fg_leader_on_tty "$MYPID" "$MYTTY" || fails+=("TRUE-case: own claude pid=$MYPID on $MYTTY should verify (rc0) but did not")

# (a) dead pid — find an unused pid number
DEAD=99999; while kill -0 "$DEAD" 2>/dev/null; do DEAD=$((DEAD+1)); done
fg_leader_on_tty "$DEAD" "$MYTTY" && fails+=("(a) dead pid=$DEAD on $MYTTY FALSELY verified")

# (b) live non-claude pid — our own shell ($$) is not claude
fg_leader_on_tty "$$" "$MYTTY" && fails+=("(b) non-claude pid=$$ ($) on $MYTTY FALSELY verified")

# (c)+(d) — enumerate OTHER claude foreground leaders on OTHER ttys (sibling sessions)
#   each line: ttysN<TAB>pid
SIBS=$(ps -A -o tty=,stat=,pid=,args= 2>/dev/null | awk -v ere="$ERE" -v mt="$MYTTY" -v mp="$MYPID" '
  $2 ~ /\+/ && $0 ~ ere {
    tty=$1; pid=$3;
    if (tty != mt && pid != mp && tty ~ /^ttys[0-9]+$/) print tty"\t"pid
  }' | sort -u)

if [ -n "$SIBS" ]; then
  while IFS=$'\t' read -r stty spid; do
    [ -z "$spid" ] && continue
    sib_tested=1
    # (d) sibling claude pid on MY tty must be REJECTED (the incident)
    fg_leader_on_tty "$spid" "$MYTTY" && fails+=("(d) INCIDENT: sibling claude pid=$spid (from $stty) FALSELY verified on MY tty $MYTTY")
    # (c) MY claude pid on the SIBLING tty must be REJECTED
    fg_leader_on_tty "$MYPID" "$stty" && fails+=("(c) own claude pid=$MYPID FALSELY verified on wrong tty $stty")
  done <<< "$SIBS"
else
  echo "INFO: no sibling claude sessions detected — (c)/(d) sibling negatives not exercised this run (only 1 live session)."
fi

if [ ${#fails[@]} -gt 0 ]; then
  echo "FAIL: 02-foreground-leader-pid-pinned"; for f in "${fails[@]}"; do echo "  - $f"; done; exit 1
fi
printf '{"sibling_negatives_exercised":%s,"own_tty":"%s"}\n' "$sib_tested" "$MYTTY" > "$FP"
echo "PASS: 02-foreground-leader-pid-pinned — pid=$MYPID tty=$MYTTY sibling_negatives=$sib_tested (TRUE,a,b$([ "$sib_tested" = 1 ] && echo ',c,d'))"
exit 0
