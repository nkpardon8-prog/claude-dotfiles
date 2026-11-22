#!/bin/sh
# rd-worker-mac: keeps a Mac worker in the pool through sleep, wifi changes, Tailscale reconnects and reboots.
# Runs as root from the LaunchDaemon com.rdocker.worker (RunAtLoad + KeepAlive; install-worker-mac.sh). Every
# RD_TICK_S (15 s):
#   awake  sharing on (any level but off) -> hold `caffeinate -s`: an AC-only assertion, so a plugged-in Mac does
#          not idle-sleep while it is lent out. On battery, or with the lid closed, the Mac sleeps as usual (asleep
#          = unreachable; the pool routes around it). Share off -> released. It reads the owner's switch
#          (`rdocker-share level`) and never writes it: only the owner changes sharing.
#   status jobs running here (rd's held slots, which the owner cannot read) -> RD_STATUS_FILE ("jobs=N", "ts=")
#          for the owner's menu bar and `rdocker-share status`; rewritten when it changes, else every 45 s.
#   stop   the owner's "Off now (stop jobs)" (`rdocker-share stop` writes off + RD_STOP_REQ) -> USR1 to rd's
#          runners (rr_runner.pl: before GO refused like share off, a started command stopped like a client
#          KILL - runs.log `interrupted`), now and once more on the next tick; the request file is removed.
#          Only the rd user's `rrun-runner` processes, never the owner's own (a local rrun is one too).
#   sshd   com.rdocker.sshd listens on the Tailscale address only, and Tailscale comes up after launchd at boot,
#          and can drop and return on wake, a wifi change or a reconnect. When that address is on an interface
#          but nothing listens on it for 2 ticks in a row -> `launchctl kickstart -k system/com.rdocker.sshd` (a
#          plist that is not loaded is bootstrapped). While the address is not up, nothing is done.
#   prune  every RD_PRUNE_EVERY_S (600 s, and at start): `rd-tune prune` as rd, in the background - the Linux
#          workers' ~/rr prune (rd-tune.sh: never a mirror a run uses; under disk pressure also the Colima
#          images/volumes no container uses), single instance and at low priority; it logs what it removed.
# Logs only changes (stdout; the plist sends it to /var/log/rd-worker-mac.log).
# Env (tests): RD_SHARE_CMD, RD_SSHD_CONF, RD_SSHD_PLIST, RD_IFCONFIG, RD_LSOF, RD_LAUNCHCTL, RD_CAFFEINATE,
# RD_TICK_S, RD_TICKS (stop after that many ticks; 0 = run forever), RD_USER, RD_SLOTS_DIR, RD_STATUS_FILE,
# RD_STOP_REQ, RD_PKILL, RD_TUNE (rd-tune.sh), RD_SUDO, RD_PRUNE_EVERY_S.
set -u
SHARE=${RD_SHARE_CMD:-/usr/local/libexec/rdocker-share}   # root-owned copy (install-worker-mac.sh), never PATH
RDU=${RD_USER:-rd}
SLOTS=${RD_SLOTS_DIR:-/Users/$RDU/rr/slots}
STATUS=${RD_STATUS_FILE:-/Users/Shared/rdocker/status}
REQ=${RD_STOP_REQ:-/Users/Shared/rdocker/stop-jobs}
PKILL=${RD_PKILL:-/usr/bin/pkill}
CONF=${RD_SSHD_CONF:-/etc/ssh/rdocker/sshd_config}
PLIST=${RD_SSHD_PLIST:-/Library/LaunchDaemons/com.rdocker.sshd.plist}
LABEL=com.rdocker.sshd
IFCONFIG=${RD_IFCONFIG:-/sbin/ifconfig}
LSOF=${RD_LSOF:-/usr/sbin/lsof}
LCTL=${RD_LAUNCHCTL:-/bin/launchctl}
CAFF=${RD_CAFFEINATE:-/usr/bin/caffeinate}
TICK=${RD_TICK_S:-15}
TICKS=${RD_TICKS:-0}
TUNE=${RD_TUNE:-/usr/local/libexec/rd-tune}   # root-owned copy (install-worker-mac.sh)
SUDO=${RD_SUDO:-/usr/bin/sudo}
PRUNE_EVERY=${RD_PRUNE_EVERY_S:-600}

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
  case $lvl in off|low|medium|high|custom|max) ;; *) lvl=unknown ;; esac
  [ "$lvl" != "$last_lvl" ] && log "share level $lvl"
  last_lvl=$lvl
  [ -n "$cpid" ] && ! mine && cpid=""
  case $lvl in
    low|medium|high|custom|max)
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

# ----------------------------------------------------------------------------------------------- status
last_status="" status_at=0
jobs_here() {   # held slots: a .who (never a symlink) whose pid is alive
  n=0
  for w in "$SLOTS"/*.who; do
    [ -f "$w" ] && [ ! -L "$w" ] || continue
    pid=$(awk '{ print $3; exit }' "$w" 2>/dev/null)
    case $pid in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}
status() {
  j=$(jobs_here) now=$(date +%s)
  [ "$j" = "$last_status" ] && [ $((now - status_at)) -lt 45 ] && return 0
  d=$(dirname "$STATUS")
  [ -d "$d" ] && [ ! -L "$d" ] || return 0
  t=$(mktemp "$d/.status.XXXXXX") || return 0   # a fresh name (O_EXCL): never through a planted file
  if printf 'jobs=%s\nts=%s\n' "$j" "$now" > "$t" && chmod 644 "$t" && mv -f "$t" "$STATUS"; then
    [ "$j" != "$last_status" ] && log "jobs running here: $j"
    last_status=$j status_at=$now
  else rm -f "$t"; fi
}

# ------------------------------------------------------------------------------------------------- stop
again=0
stop_jobs() {
  if [ -f "$REQ" ] && [ ! -L "$REQ" ]; then
    rm -f "$REQ"
    "$PKILL" -USR1 -U "$RDU" -f '^rrun-runner' 2>/dev/null
    log "stop: the owner stopped the jobs here (USR1 to $RDU's runners)"
    again=1
  elif [ -L "$REQ" ]; then rm -f "$REQ"
  elif [ "$again" = 1 ]; then
    "$PKILL" -USR1 -U "$RDU" -f '^rrun-runner' 2>/dev/null   # a keeper forked after the first one
    again=0
  fi
}

# ------------------------------------------------------------------------------------------------ prune
prune_at=0
prune() {
  now=$(date +%s)
  [ $((now - prune_at)) -ge "$PRUNE_EVERY" ] || return 0
  prune_at=$now
  [ -f "$TUNE" ] && [ ! -L "$TUNE" ] || return 0
  # as rd (never root: it only ever touches rd's own ~/rr and Colima); rd-tune holds the lock, so a slow
  # prune is never doubled; its lines are timestamped like ours
  ( "$SUDO" -n -u "$RDU" -H /bin/bash "$TUNE" prune </dev/null 2>&1 |
      while IFS= read -r line; do log "$line"; done ) &
}

n=0
log "start (tick ${TICK}s)"
while :; do
  stop_jobs
  awake
  status
  sshd_heal
  prune
  n=$((n + 1))
  [ "$TICKS" -gt 0 ] && [ "$n" -ge "$TICKS" ] && break
  sleep "$TICK" & wait $!
done
release
