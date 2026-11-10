#!/bin/bash
# rd-harden: lock the box down so nothing but our Tailscale clients can get in. Idempotent; run as root by
# provision-linux.sh (after client keys are authorized), also runnable alone.
#   rd-harden.sh --user rd --admin-user A --keys FILE [--port 22] [--wsl 0|1] [--src DIR] [--root DIR]
# --root DIR = test mode: files land under DIR, systemctl/ufw/gpasswd/... are only logged to DIR/cmds.log.
# Test hook: RD_SSHD (the `sshd` used for `-t`; in --root mode without it the syntax check is skipped).
set -euo pipefail
RD_USER=rd ADMIN="" KEYS="" PORT=22 IS_WSL=0 R="" SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --user) RD_USER=${2:?}; shift 2 ;;
    --admin-user) ADMIN=${2:?}; shift 2 ;;
    --keys) KEYS=${2:?}; shift 2 ;;
    --port) PORT=${2:?}; shift 2 ;;
    --wsl) IS_WSL=${2:?}; shift 2 ;;
    --src) SRC=${2:?}; shift 2 ;;
    --root) R=${2:?}; shift 2 ;;
    *) echo "rd-harden: unknown argument: $1" >&2; exit 1 ;;
  esac
done
ADMIN=${ADMIN:-$RD_USER}
[ -z "$R" ] || mkdir -p "$R"
say() { echo "RDPROV harden $*"; }
x() { if [ -n "$R" ]; then echo "$*" >> "$R/cmds.log"; else "$@"; fi; }   # privileged/system command
put() { local dest="$R$1" tmp; tmp=$(mktemp); cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
  mkdir -p "$(dirname "$dest")"; install -m "$2" "$tmp" "$dest"; rm -f "$tmp"; }
home_of() { if [ -n "$R" ]; then echo "$R/home/$1"; else getent passwd "$1" | cut -d: -f6; fi; }
has_client_key() {   # does <user>'s authorized_keys hold at least one key from $KEYS?
  local ak blob; ak="$(home_of "$1")/.ssh/authorized_keys"
  [ -r "$ak" ] && [ -r "$KEYS" ] || return 1
  while read -r _ blob _; do [ -n "$blob" ] && grep -qF " $blob" "$ak" && return 0; done < "$KEYS"
  return 1
}

# 1. sshd: key-only for everyone, only after we know we can still get in --------------------------------------
say sshd
if has_client_key "$ADMIN" && has_client_key "$RD_USER"; then
  USERS="$RD_USER"; [ "$ADMIN" = "$RD_USER" ] || USERS="$RD_USER $ADMIN"
  CONF="$R/etc/ssh/sshd_config.d/05-rdocker-hardening.conf"     # 05: first match wins, so it beats cloud-init's 50
  NEW=$(mktemp)
  cat > "$NEW" <<CONF
# rdocker: key-only ssh for everyone (written by rd-harden)
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
AllowUsers $USERS
CONF
  if ! { [ -f "$CONF" ] && cmp -s "$NEW" "$CONF"; }; then
    mkdir -p "$(dirname "$CONF")"
    if [ -f "$CONF" ]; then cp -p "$CONF" "$CONF.rdbak"; else rm -f "$CONF.rdbak"; fi
    install -m 644 "$NEW" "$CONF"
    CHECK=(sshd -t); [ -z "$R" ] || CHECK=("${RD_SSHD:-true}" -t)
    if ! "${CHECK[@]}"; then
      if [ -f "$CONF.rdbak" ]; then mv -f "$CONF.rdbak" "$CONF"; else rm -f "$CONF"; fi
      rm -f "$NEW"; echo "rd-harden: sshd -t rejected the hardening config; rolled back, sshd untouched" >&2; exit 1
    fi
    rm -f "$CONF.rdbak"
    x systemctl reload ssh
  fi
  rm -f "$NEW"
else
  echo "rd-harden: NOT hardening sshd: $ADMIN / $RD_USER lack a client key in authorized_keys (would lock us out)" >&2
fi

# 2. firewall --------------------------------------------------------------------------------------------------------
say firewall
if [ "$IS_WSL" = 1 ]; then
  say "note ufw skipped on WSL (the Windows Hyper-V firewall rule covers it)"
else
  [ -n "$R" ] || { command -v ufw >/dev/null 2>&1 || apt-get install -y -qq ufw; }
  x ufw default deny incoming
  x ufw default allow outgoing
  x ufw allow in on tailscale0 to any port "$PORT" proto tcp
  [ "$PORT" = 22 ] || x ufw allow in on tailscale0 to any port 22 proto tcp
  x ufw allow 41641/udp
  x ufw --force enable
fi
put /usr/local/bin/rd-docker-user 755 < "$SRC/rd-docker-user.sh"
put /etc/systemd/system/rd-docker-user.service 644 < "$SRC/rd-docker-user.service"
[ -n "$R" ] || systemctl daemon-reload
x systemctl enable --now rd-docker-user.service

# 3. docker socket: no tcp, 0660, group docker = only the service user ----------------------------------------------
say docker-socket
put /etc/systemd/system/docker.socket.d/10-rdocker.conf 644 <<'CONF'
[Socket]
SocketMode=0660
SocketGroup=docker
CONF
x gpasswd -M "$RD_USER" docker
[ -n "$R" ] || { [ ! -S /var/run/docker.sock ] || chmod 660 /var/run/docker.sock; }
if [ -z "$R" ] && grep -rqs -e '-H *tcp' -e 'tcp://' /etc/docker/daemon.json /lib/systemd/system/docker.service /etc/systemd/system/docker.service.d 2>/dev/null; then
  echo "rd-harden: a docker tcp listener is configured (-H tcp / tcp://); remove it" >&2
fi

# 4. services nobody asked for --------------------------------------------------------------------------------------------
say services
for u in avahi-daemon.socket avahi-daemon.service cups.socket cups.path cups.service cups-browsed.service rpcbind.socket rpcbind.service; do
  if [ -n "$R" ] || systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then x systemctl disable --now "$u"; fi
done

# 5. reporter secret: 0600, owned by the service user ------------------------------------------------------------
say reporter-secret
RS="$(home_of "$RD_USER")/.config/rdocker/reporter.json"
if [ -f "$RS" ]; then chmod 600 "$RS"; [ -n "$R" ] || chown "$RD_USER": "$RS"; chmod 700 "$(dirname "$RS")"; fi
say finished
