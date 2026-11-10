#!/bin/sh
# One-time, as root (sudo): installs the power sampler LaunchDaemon. Safe to re-run.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
install -d -m 755 /usr/local/libexec /Users/Shared/rdocker
install -m 755 "$SRC/rd-power-mac.sh" /usr/local/libexec/rd-power-mac
install -m 644 "$SRC/com.rdocker.power.plist" /Library/LaunchDaemons/com.rdocker.power.plist
launchctl bootout system/com.rdocker.power 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.rdocker.power.plist
sleep 7; echo "POWER-SET $(cat /Users/Shared/rdocker/power 2>/dev/null || echo 'no sample yet')"
