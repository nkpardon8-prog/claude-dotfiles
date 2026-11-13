#!/bin/sh
# rd-worker-mac: keeps a Mac worker in the pool through sleep, wifi changes, Tailscale reconnects and reboots.
# Runs as root from the LaunchDaemon com.rdocker.worker (RunAtLoad + KeepAlive; install-worker-mac.sh). Every
# RD_TICK_S (15 s):
#   awake  share some|max -> hold `caffeinate -s`: an AC-only assertion, so a plugged-in Mac does not idle-sleep
#          while it is lent out. On battery, or with the lid closed, the Mac sleeps as usual (asleep = unreachable;
#          the pool routes around it). Share off -> released. This never reads anything but the owner's switch
#          (`rdocker-share level`) and never writes it: only the owner turns sharing off.
#   sshd   com.rdocker.sshd listens on the Tailscale address only, and Tailscale comes up after launchd at boot,
#          and can drop and return on wake, a wifi change or a reconnect. When that address is on an interface
#          but nothing listens on it for 2 ticks in a row -> `launchctl kickstart -k system/com.rdocker.sshd` (a
#          plist that is not loaded is bootstrapped). While the address is not up, nothing is done.
# Logs only changes (stdout; the plist sends it to /var/log/rd-worker-mac.log).
# Env (tests): RD_SHARE_CMD, RD_SSHD_CONF, RD_SSHD_PLIST, RD_IFCONFIG, RD_LSOF, RD_LAUNCHCTL, RD_CAFFEINATE,
# RD_TICK_S, RD_TICKS (stop after that many ticks; 0 = run forever).
set -u
SHARE=${RD_SHARE_CMD:-/usr/local/bin/rdocker-share}
CONF=${RD_SSHD_CONF:-/etc/ssh/rdocker/sshd_config}
PLIST=${RD_SSHD_PLIST:-/Library/LaunchDaemons/com.rdocker.sshd.plist}
LABEL=com.rdocker.sshd
IFCONFIG=${RD_IFCONFIG:-/sbin/ifconfig}
LSOF=${RD_LSOF:-/usr/sbin/lsof}
LCTL=${RD_LAUNCHCTL:-/bin/launchctl}
CAFF=${RD_CAFFEINATE:-/usr/bin/caffeinate}
TICK=${RD_TICK_S:-15}
TICKS=${RD_TICKS:-0}

log() { echo "$(date +%Y-%m-%dT%H:%M:%S%z) $*"; }

# ------------------------------------------------------------------------------------------------ awake
cpid="" last_lvl=""
mine() {    # $cpid is still the caffeinate this loop started: our child, named like $CAFF (never a reused pid)
  [ -n "$cpid" ] || return 1
  # shellcheck disable=SC2046  # two words on purpose: ppid and command path
  set -- $(ps -o ppid= -o comm= -p "$cpid" 2>/dev/null)
  [ "${1:-}" = "$$" ] && [ "${2##*/}" = "${CAFF##*/}" ]
}
release() { mine && kill "$cpid" 2>/dev/null; cpid=""; }
trap 'release; exit 0' TERM INT HUP
awake() {
  lvl=$("$SHARE" level 2>/dev/null)
  case $lvl in off|some|max) ;; *) lvl=unknown ;; esac
  [ "$lvl" != "$last_lvl" ] && log "share level $lvl"
  last_lvl=$lvl
  [ -n "$cpid" ] && ! mine && cpid=""
  case $lvl in
    some|max)
      if [ -z "$cpid" ]; then
        "$CAFF" -s -w $$ & cpid=$!
        log "awake hold (caffeinate -s pid $cpid: no idle sleep while plugged in and sharing)"
      fi ;;
    *)
      if [ -n "$cpid" ]; then release; log "awake release (share $lvl)"; fi ;;
  esac
}

# ------------------------------------------------------------------------------------------------- sshd
miss=0
sshd_heal() {
  ip=$(awk '$1 == "ListenAddress" { print $2; exit }' "$CONF" 2>/dev/null)
  port=$(awk '$1 == "Port" { print $2; exit }' "$CONF" 2>/dev/null)
  [ -n "$ip" ] && [ -n "${port:-}" ] || return 0
  "$IFCONFIG" 2>/dev/null | grep -q "inet $ip " || { miss=0; return 0; }    # Tailscale not up: nothing can bind
  if "$LSOF" -nP -iTCP@"$ip":"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then miss=0; return 0; fi
  miss=$((miss + 1))
  [ "$miss" -ge 2 ] || return 0
  if "$LCTL" print "system/$LABEL" >/dev/null 2>&1; then
    if "$LCTL" kickstart -k "system/$LABEL" >/dev/null 2>&1; then log "sshd kickstart (nothing listening on $ip:$port)"
    else log "sshd kickstart failed (nothing listening on $ip:$port)"; fi
  elif [ -f "$PLIST" ]; then
    if "$LCTL" bootstrap system "$PLIST" >/dev/null 2>&1; then log "sshd bootstrap $PLIST (was not loaded)"
    else log "sshd bootstrap failed ($PLIST)"; fi
  else log "sshd missing: no $LABEL loaded and no $PLIST"; fi
  miss=-2    # give it a minute before the next try
}

n=0
log "start (tick ${TICK}s)"
while :; do
  awake
  sshd_heal
  n=$((n + 1))
  [ "$TICKS" -gt 0 ] && [ "$n" -ge "$TICKS" ] && break
  sleep "$TICK" & wait $!
done
release
