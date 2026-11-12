#!/bin/sh
# One-time, as root (sudo): installs rd-doctor (the worker's self-healing watchdog) as a LaunchDaemon that
# runs as the rd user every 30 s. Safe to re-run.  install-doctor-mac.sh [--user rd] [--uninstall]
# --uninstall also lifts a drain the doctor left (rd-doctor --lift), so the worker never stays closed.
# Kill switch without uninstalling: DOCTOR_DISABLE=1 in /etc/rdocker/doctor.conf.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
RD_USER=rd UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) RD_USER=${2:?}; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "install-doctor-mac: unknown argument: $1" >&2; exit 1 ;;
  esac
done
SRC=$(cd "$(dirname "$0")" && pwd)
PL=/Library/LaunchDaemons/com.rdocker.doctor.plist BIN=/usr/local/libexec/rd-doctor
RD_HOME=$(dscl . -read "/Users/$RD_USER" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }')
[ -n "$RD_HOME" ] || { echo "no user $RD_USER"; exit 1; }
launchctl bootout system/com.rdocker.doctor 2>/dev/null || true
if [ "$UNINSTALL" = 1 ]; then
  [ -x "$BIN" ] && sudo -u "$RD_USER" HOME="$RD_HOME" /bin/bash "$BIN" --lift >/dev/null 2>&1 || true
  rm -f "$PL" "$BIN"
  echo "DOCTOR-REMOVED"; exit 0
fi
DOC="$SRC/rd-doctor.sh"; [ -f "$DOC" ] || DOC="$SRC/../server/rd-doctor.sh"
[ -f "$DOC" ] || { echo "rd-doctor.sh not found next to this script or in ../server"; exit 1; }
install -d -m 755 /usr/local/libexec
install -m 755 "$DOC" "$BIN"
sed -e "s#__USER__#$RD_USER#g" -e "s#__HOME__#$RD_HOME#g" "$SRC/com.rdocker.doctor.plist" > "$PL.tmp"
chmod 644 "$PL.tmp" && mv -f "$PL.tmp" "$PL"
launchctl bootstrap system "$PL"
sleep 3; echo "DOCTOR-SET $(cat "$RD_HOME/rr/state/doctor.json" 2>/dev/null || echo 'no status yet')"
