#!/bin/sh
# rd-disk-cap-mac.sh - put a Mac rdocker worker's disk use (/Users/rd/rr: job checkouts, package caches, logs,
# the Colima Docker VM, npm cache) on its own APFS volume with a hard quota, so the pool can never use more
# than CAP of this Mac's SSD (the Linux workers' equivalent: rd-rrfs's fixed-size ~/rr image).
#   sudo sh share/rd-disk-cap-mac.sh <CAP e.g. 40g> [--docker] [--reporter <fleet name>]
#   --docker    re-run setup-mac-worker.sh --docker afterwards (Colima for db jobs; its VM lives under the cap)
#   --reporter  run the dashboard reporter as rd under that name (key minted here, never printed)
# Pauses the share while it moves ~/rr (running jobs finish first, at most 15 min), then restores the level.
# Safe to re-run: an existing rdocker-rr volume mounted at /Users/rd/rr is kept. Run from the unpacked bundle.
set -eu
CAP=${1:?usage: sudo sh rd-disk-cap-mac.sh <CAP e.g. 40g> [--docker] [--reporter NAME]}; shift
DOCKER=""; RNAME=""
while [ $# -gt 0 ]; do case $1 in --docker) DOCKER=1; shift ;; --reporter) RNAME=${2:?}; shift 2 ;; *) echo "unknown: $1"; exit 2 ;; esac; done
OWNER=${SUDO_USER:-}
[ "$(id -u)" = 0 ] && [ -n "$OWNER" ] || { echo "run with sudo from your own account"; exit 1; }
RD=/Users/rd; RR=$RD/rr; HERE=$(cd "$(dirname "$0")/.." && pwd)   # the bundle root (share/ is in it)
say() { echo "rd-disk-cap: $*"; }
was=$(cat /Users/Shared/rdocker/share 2>/dev/null || echo off)

if mount | grep -q " on $RR (apfs"; then
  say "$RR is already its own volume: $(df -h "$RR" | tail -1)"
else
  say "pausing the pool here (share off) and waiting for running jobs to finish (at most 15 min)"
  sudo -u "$OWNER" /usr/local/bin/rdocker-share off >/dev/null
  i=0; while pgrep -u rd -f rrun-runner >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 180 ] && { say "jobs still running after 15 min; stopping them"; sudo -u "$OWNER" /usr/local/bin/rdocker-share stop >/dev/null; sleep 20; break; }; sleep 5; done
  launchctl bootout system/com.rdocker.worker 2>/dev/null || true
  CONT=$(diskutil info -plist / | plutil -extract APFSContainerReference raw -)
  diskutil info rdocker-rr >/dev/null 2>&1 || diskutil apfs addVolume "$CONT" APFS rdocker-rr -quota "$CAP" -nomount
  DEV=$(diskutil info -plist rdocker-rr | plutil -extract DeviceIdentifier raw -)
  UUID=$(diskutil info -plist rdocker-rr | plutil -extract VolumeUUID raw -)
  mkdir -p "$RD/rr.new"
  diskutil mount -mountPoint "$RD/rr.new" "$DEV"
  diskutil enableOwnership "$RD/rr.new"
  say "copying the worker's files onto the capped volume"
  rsync -aH "$RR/" "$RD/rr.new/"
  diskutil unmount "$RD/rr.new"; rmdir "$RD/rr.new"
  mv "$RR" "$RD/rr.old"; mkdir "$RR"
  diskutil mount -mountPoint "$RR" "$DEV"
  diskutil enableOwnership "$RR"
  chown rd:staff "$RR"; chmod 755 "$RR"
fi

# mounted at /Users/rd/rr at every boot: a LaunchDaemon (macOS refuses writes to /etc/fstab here)
MP=/Library/LaunchDaemons/com.rdocker.rrmount.plist
cat > "$MP" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.rdocker.rrmount</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string>
    <string>mount | grep -q " on $RR (apfs" || /usr/sbin/diskutil mount -mountPoint $RR rdocker-rr</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
chown root:wheel "$MP"; chmod 644 "$MP"
launchctl bootout system/com.rdocker.rrmount 2>/dev/null || true
launchctl bootstrap system "$MP" 2>/dev/null || true
mount | grep -q " on $RR (apfs" || { say "the capped volume is not mounted at $RR; refusing"; exit 1; }
  mdutil -i off "$RR" >/dev/null 2>&1 || true
  # the Docker VM and the package caches live under the cap too
  for d in colima npm cache; do sudo -u rd mkdir -p "$RR/home/$d"; done
  [ -d "$RD/.npm" ] && [ ! -L "$RD/.npm" ] && { sudo -u rd rsync -a "$RD/.npm/" "$RR/home/npm/"; rm -rf "$RD/.npm"; }
  [ -d "$RD/.cache" ] && [ ! -L "$RD/.cache" ] && { sudo -u rd rsync -a "$RD/.cache/" "$RR/home/cache/"; rm -rf "$RD/.cache"; }
  [ -e "$RD/.colima" ] || sudo -u rd ln -s "$RR/home/colima" "$RD/.colima"
  [ -e "$RD/.npm" ] || sudo -u rd ln -s "$RR/home/npm" "$RD/.npm"
  [ -e "$RD/.cache" ] || sudo -u rd ln -s "$RR/home/cache" "$RD/.cache"
  rm -rf "$RD/rr.old"
  say "done: $(df -h "$RR" | tail -1)"

# the dashboard reporter, as rd (only rd can read its ~/rr): a LaunchDaemon with UserName rd; its key is minted
# here and never printed (the owner pipes it into the dashboard's secret store over ssh)
if [ -n "$RNAME" ] && [ -f "$HERE/reporter/rd-reporter.mjs" ]; then
  sudo -u rd mkdir -p "$RD/.local/share/rdocker/reporter" "$RD/.config/rdocker"
  install -o rd -g staff -m 644 "$HERE/reporter/rd-reporter.mjs" "$RD/.local/share/rdocker/reporter/rd-reporter.mjs"
  sudo -u rd /usr/bin/python3 -c "import json,os,secrets
p=os.path.expanduser('~rd/.config/rdocker/reporter.json'); old={}
try: old=json.load(open(p))
except Exception: pass
c={'name':'$RNAME','url':'wss://spine-fleet.zomid777.workers.dev/ingest','key':old.get('key') or secrets.token_hex(32),'role':'worker','rrRoot':'/Users/rd/rr'}
t=p+'.tmp'; fd=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); os.write(fd,json.dumps(c,indent=1).encode()); os.close(fd); os.replace(t,p)"
  PL=/Library/LaunchDaemons/com.rdocker.reporter-rd.plist
  cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.rdocker.reporter-rd</string>
  <key>UserName</key><string>rd</string>
  <key>ProgramArguments</key><array><string>/opt/homebrew/bin/node</string><string>$RD/.local/share/rdocker/reporter/rd-reporter.mjs</string></array>
  <key>EnvironmentVariables</key><dict><key>HOME</key><string>$RD</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string><key>LowPriorityIO</key><true/><key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$RR/log/rd-reporter.log</string><key>StandardErrorPath</key><string>$RR/log/rd-reporter.log</string>
</dict></plist>
PLIST
  chown root:wheel "$PL"; chmod 644 "$PL"
  launchctl bootout system/com.rdocker.reporter-rd 2>/dev/null || true
  pkill -u rd -f rd-reporter.mjs 2>/dev/null || true   # a hand-started one: never two for one name
  launchctl bootstrap system "$PL" && say "dashboard reporter running (as rd)"
fi

if [ -n "$DOCKER" ]; then say "turning on Docker for pool jobs"; sh "$HERE/share/setup-mac-worker.sh" --docker
else launchctl bootstrap system /Library/LaunchDaemons/com.rdocker.worker.plist 2>/dev/null || launchctl kickstart -k system/com.rdocker.worker; fi
case $was in off|'') sudo -u "$OWNER" /usr/local/bin/rdocker-share high ;; *) printf '%s\n' "$was" > /Users/Shared/rdocker/share.tmp && chown "$OWNER" /Users/Shared/rdocker/share.tmp && chmod 644 /Users/Shared/rdocker/share.tmp && mv -f /Users/Shared/rdocker/share.tmp /Users/Shared/rdocker/share ;; esac
say "sharing restored: $(cat /Users/Shared/rdocker/share). RD-DISK-CAP-OK cap=$CAP"

