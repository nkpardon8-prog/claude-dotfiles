#!/bin/sh
# setup-mac-worker.sh - THE way to make a Mac an rdocker pool worker, or to re-provision one (Nick's MacBook,
# the Air). One command, as root (sudo), from the unpacked bundle (share/ next to server/rd-doctor.sh,
# reporter/rd-reporter.mjs and fleet.json). Idempotent: safe to re-run; it changes only what differs.
#
#   1. /Users/Shared/rdocker (the owner's or root's, no group/world write; any other owner = refuse) and the
#      share switch seeded `off` when there is none, FIRST: no file means everything on a Mac, so an install
#      cut short after the sshd came up never leaves a worker nobody opted into. An existing setting is kept
#      (re-provisioning Nick's Mac with no share file therefore turns him OFF until he picks a level).
#   2. the `rd` user: hidden, standard (never admin), random password nobody knows, home 0700
#   3. its ~/.ssh/authorized_keys = fleet.json client_keys (the agent Macs that send jobs)
#   4. a separate sshd for rd alone: key-only, no forwarding of any kind, on <port> (2222) bound to THIS
#      Mac's Tailscale address only
#      (100.64.0.0/10, and it must be up on an interface: never 0.0.0.0, never a LAN address), LaunchDaemon
#      com.rdocker.sshd. The sshd is reloaded only when its config or plist changed (a reload drops the
#      jobs' ssh links). macOS Remote Login is not turned on or off, but its sshd gets a drop-in
#      `DenyUsers rd` (/etc/ssh/sshd_config.d; refused when the main config does not read that folder)
#   5. node for rd's jobs (the runner uses brew's node): fleet.json pool_node_major; missing -> brew install
#      node (as the owner), another major -> says how (never upgrades the owner's node by itself); git (CLT)
#   6. --docker only (a Mac that takes db jobs): colima + docker CLI via brew, as the owner. Without it the
#      Mac has no Docker for jobs, so its fleet entry leaves out the db class.
#   7. the menu bar: SwiftBar (brew cask, as the owner, when missing and brew exists; else says how), its
#      plugin folder, rdocker-share.1m.sh in it, SwiftBar started in the owner's session
#   8. install-worker-mac.sh: rdocker-share, com.rdocker.worker, rd-doctor, the power sampler, the reporter
#   9. checks: the sshd listens on <ip>:<port> only; status summary
#
#   setup-mac-worker.sh [--user rd] [--owner <login>] [--port 2222] [--ip <tailscale ip>] [--docker]
#                       [--no-swiftbar]
# Never touches system settings (sleep, firewall, Remote Login) and never pushes or edits fleet.json.
# Env (tests): RD_SETUP_PARSE_ONLY=1 (parse the arguments and the bundle, print them, stop).
set -eu
RD_USER=rd OWNER=${SUDO_USER:-} PORT=2222 IP="" DOCKER=0 SWIFTBAR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --user) RD_USER=${2:?}; shift 2 ;;
    --owner) OWNER=${2:?}; shift 2 ;;
    --port) PORT=${2:?}; shift 2 ;;
    --ip) IP=${2:?}; shift 2 ;;
    --docker) DOCKER=1; shift ;;
    --no-swiftbar) SWIFTBAR=0; shift ;;
    *) echo "setup-mac-worker: unknown argument: $1" >&2; exit 1 ;;
  esac
done
SRC=$(cd "$(dirname "$0")" && pwd)
FLEET="$SRC/../fleet.json"
for f in install-worker-mac.sh rdocker-share.sh rdocker-share.1m.sh; do
  [ -f "$SRC/$f" ] || { echo "setup-mac-worker: $f missing next to this script"; exit 1; }
done
[ -f "$FLEET" ] || { echo "setup-mac-worker: fleet.json missing (expected at $FLEET)"; exit 1; }
case $RD_USER in ''|*[!a-z0-9_-]*) echo "setup-mac-worker: bad --user"; exit 1 ;; esac
case $PORT in ''|*[!0-9]*) echo "setup-mac-worker: bad --port"; exit 1 ;; esac
# fleet.json: the client keys (one per line, each checked) and the pool's node major
# shellcheck disable=SC2016  # Perl, expanded by perl
KEYS=$(/usr/bin/perl -MJSON::PP -e 'local $/; open my $f, "<", shift or exit 1; my $d = decode_json(<$f>);
  for (@{ $d->{client_keys} || [] }) { print "$_\n" if m{^ssh-(?:ed25519|rsa) [A-Za-z0-9+/]+={0,2}(?: [^\x00-\x1f]+)?$} }' "$FLEET")
NODE_MAJOR=$(/usr/bin/perl -MJSON::PP -e 'local $/; open my $f, "<", shift or exit 1; my $v = decode_json(<$f>)->{pool_node_major}; print $v // ""' "$FLEET")
[ -n "$KEYS" ] || { echo "setup-mac-worker: fleet.json has no client_keys"; exit 1; }
if [ "${RD_SETUP_PARSE_ONLY:-}" = 1 ]; then
  printf 'user=%s owner=%s port=%s ip=%s docker=%s swiftbar=%s node_major=%s keys=%s\n' "$RD_USER" "$OWNER" "$PORT" \
    "$IP" "$DOCKER" "$SWIFTBAR" "$NODE_MAJOR" "$(printf '%s\n' "$KEYS" | wc -l | tr -d ' ')"
  exit 0
fi
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "setup-mac-worker: macOS only (Linux workers: rdocker add-server)"; exit 1; }
# shellcheck disable=SC2015  # any failing test means: no usable owner
[ -n "$OWNER" ] && [ "$OWNER" != root ] && id "$OWNER" >/dev/null 2>&1 || {
  echo "setup-mac-worker: run it with sudo from the owner's account (or pass --owner <login>)"; exit 1; }
[ "$OWNER" != "$RD_USER" ] || { echo "setup-mac-worker: the owner cannot be the worker account"; exit 1; }
OH=$(dscl . -read "/Users/$OWNER" NFSHomeDirectory | awk '{ print $2 }')
OUID=$(id -u "$OWNER")
as_owner() { sudo -u "$OWNER" -H env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$@"; }
BREW=""; for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW=$b && break; done
say() { echo "setup-mac-worker: $*"; }

# ---------------------------------------------------------------------------------- 0. the Tailscale address
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -x "$TS" ] || TS=$(command -v tailscale 2>/dev/null || true)
if [ -z "$IP" ]; then
  [ -n "$TS" ] || { say "Tailscale CLI not found; pass --ip <this Mac's Tailscale IPv4>"; exit 1; }
  IP=$("$TS" ip -4 2>/dev/null | head -1)
fi
# only a Tailscale (CGNAT 100.64.0.0/10) address that is up on an interface right now
case $IP in 100.*.*.*) ;; *) say "refusing $IP: not a Tailscale address (100.64.0.0/10)"; exit 1 ;; esac
o2=$(echo "$IP" | cut -d. -f2)
[ "$o2" -ge 64 ] && [ "$o2" -le 127 ] || { say "refusing $IP: not in 100.64.0.0/10"; exit 1; }
/sbin/ifconfig | grep -q "inet $IP " || { say "$IP is not up on any interface: start Tailscale first"; exit 1; }
say "Tailscale address $IP (the worker sshd binds to it alone)"

# ---------------------------------------------------------------------------------- 1. the share switch: OFF first
# Before any account, key or sshd exists: on a Mac no share file means everything, so an install cut short
# after the sshd came up must never leave a worker that takes jobs nobody opted into. The folder must be the
# owner's (or root's), with no group/world write: the root daemon reads the level from it.
SD=/Users/Shared/rdocker
if [ -L "$SD" ] || { [ -e "$SD" ] && [ ! -d "$SD" ]; }; then say "$SD is not a plain directory; fix it first"; exit 1; fi
[ -d "$SD" ] || /usr/bin/install -d -o "$OWNER" -g staff -m 755 "$SD"
so=$(/usr/bin/stat -f %Su "$SD")
if [ "$so" != "$OWNER" ] && [ "$so" != root ]; then
  say "$SD belongs to $so, not to $OWNER or root: refusing (it holds the share switch). Fix: sudo chown $OWNER $SD"; exit 1
fi
/bin/chmod go-w "$SD"
if [ ! -e "$SD/share" ] && [ ! -L "$SD/share" ]; then
  as_owner /bin/sh "$SRC/rdocker-share.sh" off >/dev/null || true   # as the owner (its default file is $SD/share)
  say "share switch seeded OFF (pick a level in the menu bar, or: rdocker-share medium)"
fi
lvl=$(RR_SHARE_FILE="$SD/share" /bin/sh "$SRC/rdocker-share.sh" level 2>/dev/null || true)
[ -n "$lvl" ] && [ -e "$SD/share" ] || { say "could not set the share switch in $SD/share: stopping before any sshd"; exit 1; }
say "share switch: $lvl"

# ---------------------------------------------------------------------------------- 2. the rd user
if ! id "$RD_USER" >/dev/null 2>&1; then
  PW=$(/usr/bin/openssl rand -base64 30)
  /usr/sbin/sysadminctl -addUser "$RD_USER" -fullName "rdocker worker" -password "$PW" -home "/Users/$RD_USER" \
    -shell /bin/zsh >/dev/null 2>&1 || true
  unset PW
  id "$RD_USER" >/dev/null 2>&1 || { say "could not create user $RD_USER (sysadminctl)"; exit 1; }
  /usr/sbin/createhomedir -c -u "$RD_USER" >/dev/null 2>&1 || true
  say "created user $RD_USER"
fi
if /usr/sbin/dseditgroup -o checkmember -m "$RD_USER" admin >/dev/null 2>&1; then
  say "$RD_USER is an ADMIN account; a worker account must be standard. Fix it first (System Settings > Users)"; exit 1
fi
/usr/bin/dscl . create "/Users/$RD_USER" IsHidden 1
H=$(/usr/bin/dscl . read "/Users/$RD_USER" NFSHomeDirectory | awk '{ print $2 }')
[ -n "$H" ] && [ -d "$H" ] && [ ! -L "$H" ] || { say "no home directory for $RD_USER"; exit 1; }
/bin/chmod 700 "$H"

# ---------------------------------------------------------------------------------- 3. its keys
# Written AS rd (tested code runs as rd and owns everything under its home: root never writes or chowns a
# path there, so a planted symlink cannot point a root write anywhere).
# shellcheck disable=SC2016  # expanded by rd's shell
printf '%s\n' "$KEYS" | sudo -u "$RD_USER" -H /bin/sh -c 'umask 077; set -e; [ ! -L "$HOME/.ssh" ]
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; t=$(mktemp "$HOME/.ssh/.ak.XXXXXX"); cat > "$t"
  mv -f "$t" "$HOME/.ssh/authorized_keys"' || { say "could not write $RD_USER's authorized_keys"; exit 1; }
say "authorized_keys: $(printf '%s\n' "$KEYS" | wc -l | tr -d ' ') key(s) from fleet.json client_keys"

# ---------------------------------------------------------------------------------- 4. the worker sshd
# The MAIN sshd (macOS Remote Login, if the owner turns it on) must never let rd in: a drop-in DenyUsers,
# which needs the main config to read /etc/ssh/sshd_config.d (macOS ships that Include); without it: refuse.
MAIN=/etc/ssh/sshd_config DROP=/etc/ssh/sshd_config.d/100-rdocker-deny-$RD_USER.conf
grep -q '^Include /etc/ssh/sshd_config.d/\*' "$MAIN" || {
  say "$MAIN does not read /etc/ssh/sshd_config.d: cannot keep $RD_USER out of Remote Login; refusing"; exit 1; }
/usr/bin/install -d -m 755 /etc/ssh/sshd_config.d
printf '# rdocker: the worker account logs in only through its own sshd (com.rdocker.sshd), never Remote Login\nDenyUsers %s\n' \
  "$RD_USER" > "$DROP.tmp"
/bin/chmod 644 "$DROP.tmp"; /bin/mv -f "$DROP.tmp" "$DROP"
/usr/sbin/sshd -t || { rm -f "$DROP"; say "the main sshd rejected $DROP; refusing"; exit 1; }
D=/etc/ssh/rdocker
/usr/bin/install -d -m 755 "$D"
[ -f "$D/ssh_host_ed25519_key" ] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$D/ssh_host_ed25519_key"
CONF="$D/sshd_config" PL=/Library/LaunchDaemons/com.rdocker.sshd.plist
sum() { [ -f "$1" ] && /sbin/md5 -q "$1" 2>/dev/null || echo none; }
before="$(sum "$CONF") $(sum "$PL")"
cat > "$CONF.tmp" <<CONF
# rdocker worker sshd: Tailscale address only, user $RD_USER only, keys only. Remote Login stays OFF.
# Written by share/setup-mac-worker.sh (re-run it to change; hand edits are replaced).
Port $PORT
ListenAddress $IP
HostKey $D/ssh_host_ed25519_key
PidFile /var/run/rdocker-sshd.pid
AllowUsers $RD_USER
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 30
UsePAM no
CONF
/usr/sbin/sshd -t -f "$CONF.tmp" || { rm -f "$CONF.tmp"; say "sshd rejected the config"; exit 1; }
/bin/chmod 644 "$CONF.tmp"; /bin/mv -f "$CONF.tmp" "$CONF"
cat > "$PL.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.rdocker.sshd</string>
<key>ProgramArguments</key><array><string>/usr/sbin/sshd</string><string>-D</string><string>-f</string><string>$CONF</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>
</dict></plist>
PLIST
/bin/chmod 644 "$PL.tmp"; /usr/sbin/chown root:wheel "$PL.tmp"; /bin/mv -f "$PL.tmp" "$PL"
if [ "$before" != "$(sum "$CONF") $(sum "$PL")" ] || ! /bin/launchctl print system/com.rdocker.sshd >/dev/null 2>&1; then
  /bin/launchctl bootout system/com.rdocker.sshd 2>/dev/null || true
  /bin/launchctl bootstrap system "$PL"
  say "com.rdocker.sshd (re)loaded: $IP:$PORT"
else
  say "com.rdocker.sshd unchanged (not reloaded: running jobs keep their links)"
fi

# ---------------------------------------------------------------------------------- 5. node + git for rd
NODE=/opt/homebrew/opt/node/bin/node    # the runner's choice on a Mac (rr_runner.pl node_dir)
if [ ! -x "$NODE" ] && [ -n "$BREW" ]; then
  say "installing node with brew (as $OWNER)"; as_owner "$BREW" install node || say "brew install node failed"
fi
if [ -x "$NODE" ]; then
  have=$(sudo -u "$RD_USER" "$NODE" -v 2>/dev/null | sed -n 's/^v\([0-9]*\)\..*/\1/p')
  if [ -n "$NODE_MAJOR" ] && [ "$have" != "$NODE_MAJOR" ]; then
    say "WARNING: node for $RD_USER is v${have:-?}, the pool runs $NODE_MAJOR (fleet.json pool_node_major): its"
    say "  results are not shared until they match. Fix (as $OWNER): brew upgrade node  (or brew install node@$NODE_MAJOR)"
  else say "node v$have for $RD_USER (pool runs ${NODE_MAJOR:-?})"; fi
else
  say "WARNING: no node at $NODE: install Homebrew, then (as $OWNER) brew install node"
fi
/usr/bin/xcode-select -p >/dev/null 2>&1 || say "WARNING: no command line tools (git): run xcode-select --install"

# ---------------------------------------------------------------------------------- 6. Docker (--docker)
if [ "$DOCKER" = 1 ]; then
  if [ -x /opt/homebrew/bin/colima ] && [ -x /opt/homebrew/bin/docker ]; then say "colima + docker present"
  elif [ -n "$BREW" ]; then say "installing colima + docker with brew (as $OWNER)"; as_owner "$BREW" install colima docker
  else say "WARNING: --docker needs Homebrew: install it, then (as $OWNER) brew install colima docker"; fi
  /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || say "note: Rosetta is not installed (amd64 images): softwareupdate --install-rosetta"
fi

# ---------------------------------------------------------------------------------- 7. the menu bar
if [ "$SWIFTBAR" = 1 ]; then
  APP=/Applications/SwiftBar.app
  if [ ! -d "$APP" ] && [ -n "$BREW" ]; then
    say "installing SwiftBar with brew (as $OWNER)"; as_owner "$BREW" install --cask swiftbar || true
  fi
  if [ -d "$APP" ]; then
    PD=$(as_owner /usr/bin/defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
    if [ -z "$PD" ]; then
      PD="$OH/Library/Application Support/SwiftBar/Plugins"
      as_owner /usr/bin/defaults write com.ameba.SwiftBar PluginDirectory "$PD"
    fi
    as_owner /bin/mkdir -p "$PD"
    as_owner /usr/bin/install -m 755 "$SRC/rdocker-share.1m.sh" "$PD/rdocker-share.1m.sh"
    say "menu bar plugin -> $PD/rdocker-share.1m.sh"
    /usr/bin/pgrep -qx SwiftBar || /bin/launchctl asuser "$OUID" sudo -u "$OWNER" /usr/bin/open -g -a SwiftBar || true
  else
    say "SwiftBar is not installed: brew install --cask swiftbar (or https://swiftbar.app), then re-run this"
  fi
fi

# ---------------------------------------------------------------------------------- 8. the daemons
sh "$SRC/install-worker-mac.sh" --user "$RD_USER"

# ---------------------------------------------------------------------------------- 9. checks
sleep 2
L=$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u | tr '\n' ' ')
case " $L" in
  " $IP:$PORT ") say "LISTEN-OK $IP:$PORT only" ;;
  *) say "WARNING: port $PORT listeners: ${L:-none} (expected $IP:$PORT only)" ;;
esac
echo "RDOCKER-MAC-WORKER-OK user=$RD_USER ip=$IP port=$PORT share=$(/usr/local/libexec/rdocker-share level 2>/dev/null)"
