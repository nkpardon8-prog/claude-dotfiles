#!/bin/sh
# One command, as root (sudo), on a Mac worker: everything that keeps it in the pool after sleep, wifi
# changes, Tailscale reconnects and reboots. Safe to re-run. Run it from the unpacked bundle
# (share/ next to server/rd-doctor.sh and reporter/rd-reporter.mjs):
#   - /usr/local/bin/rdocker-share (the owner's switch; the menu-bar plugin finds it there)
#   - com.rdocker.worker LaunchDaemon (rd-worker-mac: AC-only keep-awake while sharing, sshd re-kick)
#   - com.rdocker.doctor (install-doctor-mac.sh) and com.rdocker.power (install-power-mac.sh)
#   - the owner's reporter (his LaunchAgent com.rdocker.reporter), when it is installed: new rd-reporter.mjs + restart
# Never touches the share level, the rd user, the sshd config or Tailscale. Ends with a status summary.
#   install-worker-mac.sh [--user rd]        (--user: the worker account, passed to install-doctor-mac.sh)
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
RD_USER=rd
while [ $# -gt 0 ]; do
  case "$1" in
    --user) RD_USER=${2:?}; shift 2 ;;
    *) echo "install-worker-mac: unknown argument: $1" >&2; exit 1 ;;
  esac
done
SRC=$(cd "$(dirname "$0")" && pwd)
for f in rdocker-share.sh rd-worker-mac.sh com.rdocker.worker.plist install-doctor-mac.sh install-power-mac.sh; do
  [ -f "$SRC/$f" ] || { echo "install-worker-mac: $f missing next to this script"; exit 1; }
done

# The owner's switch writes the share file in /Users/Shared/rdocker as the owner: the folder is his, 0755, never
# group/world-writable (the root daemon reads the level from it). Made before install-power-mac.sh, which
# would otherwise create it as root.
OWNER=${SUDO_USER:-}
SD=/Users/Shared/rdocker
if [ -L "$SD" ] || { [ -e "$SD" ] && [ ! -d "$SD" ]; }; then echo "install-worker-mac: $SD is not a plain directory; fix it first"; exit 1; fi
if [ ! -d "$SD" ]; then
  if [ -n "$OWNER" ] && [ "$OWNER" != root ]; then install -d -o "$OWNER" -g staff -m 755 "$SD"
  else install -d -m 755 "$SD"; echo "note: $SD made root-owned (no sudo caller): the owner cannot set the share level until it is his"; fi
fi
chmod go-w "$SD"

install -d -m 755 /usr/local/bin /usr/local/libexec
install -m 755 "$SRC/rdocker-share.sh" /usr/local/bin/rdocker-share
install -m 755 "$SRC/rd-worker-mac.sh" /usr/local/libexec/rd-worker-mac
install -m 644 "$SRC/com.rdocker.worker.plist" /Library/LaunchDaemons/com.rdocker.worker.plist
launchctl bootout system/com.rdocker.worker 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.rdocker.worker.plist
echo "WORKER-SET"

sh "$SRC/install-doctor-mac.sh" --user "$RD_USER"
sh "$SRC/install-power-mac.sh"

# The reporter runs in the owner's own login session (gui domain), so it is refreshed for the sudo caller.
MJS="$SRC/../reporter/rd-reporter.mjs"
if [ -n "$OWNER" ] && [ "$OWNER" != root ] && [ -f "$MJS" ]; then
  OH=$(dscl . -read "/Users/$OWNER" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }')
  OUID=$(id -u "$OWNER")
  if [ -n "$OH" ] && [ -d "$OH/.local/share/rdocker/reporter" ]; then
    install -o "$OWNER" -m 644 "$MJS" "$OH/.local/share/rdocker/reporter/rd-reporter.mjs"
    if launchctl kickstart -k "gui/$OUID/com.rdocker.reporter" 2>/dev/null; then echo "REPORTER-SET"
    else echo "REPORTER-COPIED (com.rdocker.reporter is not loaded in $OWNER's session; log in, or load its plist)"; fi
  else echo "REPORTER-SKIPPED (no $OH/.local/share/rdocker/reporter)"; fi
fi

state() { s=$(launchctl print "$1" 2>/dev/null | awk '$1 == "state" { print $3; exit }'); echo "${s:-NOT LOADED}"; }
echo "---- status"
for l in sshd worker doctor power; do echo "com.rdocker.$l: $(state "system/com.rdocker.$l")"; done
[ -n "${OUID:-}" ] && echo "com.rdocker.reporter: $(state "gui/$OUID/com.rdocker.reporter")"
echo "share level: $(/usr/local/bin/rdocker-share level) (sticky; only the owner's switch changes it)"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -x "$TS" ] || TS=$(command -v tailscale 2>/dev/null || true)
if [ -n "$TS" ]; then echo "tailscale: $("$TS" ip -4 2>/dev/null | head -1) $("$TS" status --self --peers=false 2>/dev/null | head -1)"
else echo "tailscale: CLI not found"; fi
