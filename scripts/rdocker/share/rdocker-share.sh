#!/bin/sh
# rdocker share [off|some|max|status] - the OWNER's switch for a Mac rdocker worker.
#
# Lends this Mac's compute to the rdocker pool (jobs run as the separate, non-admin `rd` user;
# nothing here touches your account or files). The pool reads the level live before every job:
#   off   no new jobs (running ones finish); the Docker VM stops once the worker is idle
#   some  half the job slots; the Docker VM gets 6 CPU / 12 GB when it next starts
#   max   all job slots; the Docker VM gets 12 CPU / 24 GB when it next starts
# No root needed. Install: see share/README.md (copy to /usr/local/bin/rdocker-share).
# Env (tests): RR_SHARE_FILE (default /Users/Shared/rdocker/share), RR_SLOTS_DIR (default /Users/rd/rr/slots).
set -u
FILE=${RR_SHARE_FILE:-/Users/Shared/rdocker/share}
SLOTS=${RR_SLOTS_DIR:-/Users/rd/rr/slots}

level() {   # same rule as the worker: no file = max; off/some/max; anything else = off
  [ -e "$FILE" ] || { echo max; return; }
  v=$(tr -d ' \t\r\n' < "$FILE" 2>/dev/null)
  case $v in off|some|max) echo "$v" ;; *) echo off ;; esac
}

meaning() {
  case $1 in
    off)  echo "Sharing is OFF: no new jobs start here (running ones finish); the Docker VM stops once idle." ;;
    some) echo "Sharing is SOME: the pool may use half of the job slots; Docker VM 6 CPU / 12 GB on its next start." ;;
    max)  echo "Sharing is MAX: the pool may use all job slots; Docker VM 12 CPU / 24 GB on its next start." ;;
  esac
}

jobs_running() {   # held slots: a .who file whose process is alive; prints the count, or "?" when unreadable
  [ -d "$SLOTS" ] && [ -r "$SLOTS" ] && [ -x "$SLOTS" ] || { echo "?"; return; }
  n=0
  for w in "$SLOTS"/*.who; do
    [ -f "$w" ] && [ -r "$w" ] || continue
    pid=$(awk '{ print $3 }' "$w" 2>/dev/null)
    case $pid in ''|*[!0-9]*) continue ;; esac
    ps -p "$pid" >/dev/null 2>&1 && n=$((n + 1))
  done
  echo "$n"
}

set_level() {
  dir=$(dirname "$FILE")
  if [ ! -d "$dir" ]; then mkdir -p "$dir" && chmod 755 "$dir"; fi
  tmp="$dir/.share.$$"
  printf '%s\n' "$1" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$FILE" || {
    rm -f "$tmp"; echo "rdocker share: could not write $FILE" >&2; exit 1; }
}

case "${1:-status}" in
  off|some|max)
    set_level "$1"
    meaning "$1"
    [ "$1" = off ] && { j=$(jobs_running); [ "$j" != "?" ] && [ "$j" -gt 0 ] && echo "$j job(s) still running will finish."; }
    exit 0 ;;
  status)
    l=$(level)
    meaning "$l"
    j=$(jobs_running)
    [ "$j" = "?" ] || echo "Jobs running now: $j"
    exit 0 ;;
  -h|--help|help)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *)
    echo "usage: rdocker share [off|some|max|status]" >&2
    exit 2 ;;
esac
