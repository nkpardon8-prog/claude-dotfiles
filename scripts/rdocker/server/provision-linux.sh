#!/bin/bash
# provision-linux.sh - turn a fresh Ubuntu / Debian / Linux Mint box (or WSL2 with systemd) into an rdocker
# worker / home server. Run as root ONCE (`sudo bash provision-linux.sh ...`); safe to re-run: every step
# checks before it changes, and nothing is ever deleted. `rdocker add-server` copies this directory to
# the box and runs it; see commands/dockersetup.md.
#
#   provision-linux.sh --ts-ip <tailscale ip> [--user rd] [--port 22] [--keys FILE] [--img-gb 30]
#                      [--max-slots 2] [--heavy-slots 1] [--headless auto|yes|no] [--home] [--admin-user U]
#                      [--rr-gb auto|N|0] [--dry-run]
#
# Recipe (2026-11-01, WSL): user rd; sshd on the Tailscale ip + loopback only; docker-ce with daemon.json
# {ip 127.0.0.1, containerd snapshotter off, json-file 10m x3, builder gc 1GB}; a 30G ext4 loop image at
# /var/lib/docker (so the janitor's 50/60% caps mean ~15/18 GB); journald 50M; chrony makestep; sudoers
# for the janitor verbs; mise node 25 + pnpm 9. Plus: rd-tune (slot cap + reclaim timer), the reporter
# units when shipped alongside, client keys from --keys. Windows-side keep-alive (S4U task) is NOT here.
# ~/rr on a reflink XFS image (rd-rrfs.sh: package clones share blocks; --rr-gb auto = the largest image that
# cannot overfill the disk, at most 300 GB, 120 on WSL whose real limit is the Windows drive; 0 = skip). A box
# whose ~/rr already has data is not moved here: run rd-rrfs presync + cutover when it is idle.
set -euo pipefail

RD_USER=rd TS_IP="" PORT=22 KEYS="" IMG_GB=30 MAX_SLOTS=2 HEAVY_SLOTS=1 HEADLESS=auto DRY=0 IS_HOME=0 ADMIN_USER="" RR_GB=auto
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG=/var/lib/rdocker-docker.img

die() { echo "provision: $*" >&2; exit 1; }
say() { echo "RDPROV step $*"; }
run() { if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi; }
# put_file DEST MODE < content: write only when different; echoes "changed" status to fd 3
put_file() {
  local dest=$1 mode=$2 tmp; tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
  if [ "$DRY" = 1 ]; then echo "+ write $dest"; rm -f "$tmp"; return 0; fi
  mkdir -p "$(dirname "$dest")"; install -m "$mode" "$tmp" "$dest"; rm -f "$tmp"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) RD_USER=${2:?}; shift 2 ;;
    --ts-ip) TS_IP=${2:?}; shift 2 ;;
    --port) PORT=${2:?}; shift 2 ;;
    --keys) KEYS=${2:?}; shift 2 ;;
    --img-gb) IMG_GB=${2:?}; shift 2 ;;
    --max-slots) MAX_SLOTS=${2:?}; shift 2 ;;
    --heavy-slots) HEAVY_SLOTS=${2:?}; shift 2 ;;
    --headless) HEADLESS=${2:?}; shift 2 ;;
    --admin-user) ADMIN_USER=${2:?}; shift 2 ;;
    --rr-gb) RR_GB=${2:?}; shift 2 ;;
    --home) IS_HOME=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$TS_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--ts-ip <tailscale ipv4> is required"
[[ "$RD_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "bad --user"
[[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "bad --port"
[[ "$IMG_GB$MAX_SLOTS$HEAVY_SLOTS" =~ ^[0-9]+$ ]] || die "--img-gb/--max-slots/--heavy-slots must be numbers"
[[ "$RR_GB" =~ ^(auto|[0-9]+)$ ]] || die "--rr-gb must be auto or a number"
[ -z "$KEYS" ] || [ -r "$KEYS" ] || die "cannot read --keys $KEYS"
[ "$(id -u)" = 0 ] || [ "$DRY" = 1 ] || die "run as root: sudo bash $0 ..."
[ -d /run/systemd/system ] || [ "$DRY" = 1 ] || die "systemd is required (on WSL: [boot] systemd=true in /etc/wsl.conf)"

. /etc/os-release
case "${ID:-}" in ubuntu|debian|linuxmint) ;; *) die "unsupported distro '${ID:-?}' (Ubuntu, Debian, Mint)" ;; esac
CODENAME=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
[ -n "$CODENAME" ] || die "cannot tell the distro codename"
DOCKER_DISTRO=$ID; [ "$ID" = linuxmint ] && DOCKER_DISTRO=ubuntu
IS_WSL=0; grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1
say "distro=$ID/$CODENAME wsl=$IS_WSL user=$RD_USER ts-ip=$TS_IP port=$PORT"
export DEBIAN_FRONTEND=noninteractive
PKGS_BASE="ca-certificates curl gnupg openssh-server chrony git perl python3 rsync tar e2fsprogs util-linux sudo libatomic1 build-essential"
PKGS_DOCKER="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

# 0a. prior state (FIRST provision only, before anything changes): what unprovision-linux.sh needs to put the
#     box back - which packages / user / settings were already there, plus copies of the shared files provision
#     edits in place. Never rewritten by a re-run (a re-run would record our own changes as "before").
PRIOR=/etc/rdocker/prior-state
record_prior_state() {
  local p v u ena="" masked="" files="" missing="" present=""
  install -d -m 755 /etc/rdocker; install -d -m 700 /etc/rdocker/prior /etc/rdocker/prior/files
  # every package provision or its helpers (rd-rrfs xfsprogs, rd-harden ufw, rd-resilience
  # unattended-upgrades/pciutils) may install, and the time daemons installing chrony may replace
  for p in $PKGS_BASE $PKGS_DOCKER xfsprogs ufw unattended-upgrades pciutils; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing="$missing $p"
  done
  for p in systemd-timesyncd ntp ntpsec openntpd; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' && present="$present $p"
  done
  for u in ssh.service ssh.socket avahi-daemon.socket avahi-daemon.service cups.socket cups.path cups.service \
           cups-browsed.service rpcbind.socket rpcbind.service; do
    [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] && ena="$ena $u"
  done
  for u in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    [ "$(systemctl is-enabled "$u" 2>/dev/null)" = masked ] && masked="$masked $u"
  done
  # every installed package: --purge-packages removes only what apt pulled in since (never one of these)
  dpkg-query -W -f='${Status} ${Package}\n' 2>/dev/null | awk '$3 == "installed" {print $4}' | sort > /etc/rdocker/prior/packages
  # shared files provision overwrites in place: a copy under /etc/rdocker/prior/files keeps the original
  for p in /etc/docker/daemon.json /etc/apt/apt.conf.d/20auto-upgrades /etc/wsl.conf \
           /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc; do
    [ -e "$p" ] || continue
    files="$files $p"; cp -a --parents "$p" /etc/rdocker/prior/files
  done
  {
    echo "# rdocker: this box before its first provision ($(date -u +%FT%TZ)); read by unprovision-linux.sh"
    printf 'PRIOR_VERSION=1\n'
    printf 'PRIOR_USER_NAME=%q\n' "$RD_USER"      # the record speaks for this user only
    printf 'PRIOR_USER_EXISTED=%s\n' "$(id "$RD_USER" >/dev/null 2>&1 && echo 1 || echo 0)"
    printf 'PRIOR_LINGER=%s\n' "$([ -e "/var/lib/systemd/linger/$RD_USER" ] && echo 1 || echo 0)"
    printf 'PRIOR_PKGS_MISSING=%q\n' "${missing# }"
    printf 'PRIOR_PKGS_PRESENT=%q\n' "${present# }"
    printf 'PRIOR_ENABLED=%q\n' "${ena# }"
    printf 'PRIOR_MASKED=%q\n' "${masked# }"
    printf 'PRIOR_FILES=%q\n' "${files# }"
    printf 'PRIOR_DEFAULT_TARGET=%q\n' "$(systemctl get-default 2>/dev/null || true)"
    printf 'PRIOR_UFW_ACTIVE=%s\n' "$(ufw status 2>/dev/null | grep -q '^Status: active' && echo 1 || echo 0)"
    # rules / default policies ufw already had: rd-harden's identical rules then are not ours to delete
    # only a snapshot that was really taken: without PRIOR_UFW_RULES, unprovision deletes no ufw rule at all
    if ! command -v ufw >/dev/null 2>&1; then printf 'PRIOR_UFW_RULES=%q\n' ""
    elif v=$(ufw show added 2>/dev/null); then printf 'PRIOR_UFW_RULES=%q\n' "$(grep '^ufw ' <<< "$v" || true)"; fi
    # default policies from ufw's own file (valid while ufw is off too), in `ufw default` words
    printf 'PRIOR_UFW_DEFAULTS=%q\n' "$(. /etc/default/ufw 2>/dev/null && for v in "${DEFAULT_INPUT_POLICY:-}" "${DEFAULT_OUTPUT_POLICY:-}"; do
      case "$v" in DROP) echo deny ;; ACCEPT) echo allow ;; REJECT) echo reject ;; esac; done | xargs)"
    # the box's own DOCKER-USER rules (rd-docker-user rebuilds that chain from scratch): put back by unprovision
    printf 'PRIOR_DOCKER_USER=%q\n' "$(iptables-save -t filter 2>/dev/null | grep '^-A DOCKER-USER ' | grep -vx -- '-A DOCKER-USER -j RETURN' || true)"
    printf 'PRIOR_DOCKER_GROUP=%q\n' "$(getent group docker >/dev/null && echo "yes:$(getent group docker | cut -d: -f4)" || echo no)"
    printf 'PRIOR_CHRONY_MAKESTEP=%s\n' "$(grep -qs '^makestep 0.05 -1' /etc/chrony/chrony.conf && echo 1 || echo 0)"
    printf 'PRIOR_DOCKER_DATA=%s\n' "$([ -n "$(ls -A /var/lib/docker 2>/dev/null)" ] && echo 1 || echo 0)"
    for v in net.ipv4.ip_nonlocal_bind vm.swappiness kernel.panic kernel.panic_on_oops; do
      printf 'PRIOR_SYSCTL_%s=%q\n' "$(echo "$v" | tr '.' '_')" "$(sysctl -n "$v" 2>/dev/null || true)"
    done
  } > "$PRIOR.tmp"
  chmod 600 "$PRIOR.tmp"; mv -f "$PRIOR.tmp" "$PRIOR"
  say "prior state recorded in $PRIOR"
}
if [ "$DRY" = 1 ]; then echo "+ record prior state in $PRIOR (first provision only)"
elif [ ! -f "$PRIOR" ]; then
  # a box that already has rdocker's files was provisioned before this record existed: "before" is unknown
  if [ -e /etc/sudoers.d/rd-docker ] || [ -e /etc/rdocker/tune.conf ]; then
    say "note provisioned before prior-state records existed: unprovision will keep shared settings it cannot attribute"
  else record_prior_state; fi
fi

# 0. WSL isolation (B8): pool jobs must never reach the Windows drive or launch Windows programs.
#    The OpenDental laptop keeps patient data on C:. Interop also lets any WSL user run
#    `wsl.exe -u root`, i.e. passwordless root. Applied live and in /etc/wsl.conf.
if [ "$IS_WSL" = 1 ]; then
  say "wsl isolation (no C: automount, no interop)"
  if [ "$DRY" != 1 ]; then
    python3 - <<'PY'
import configparser
p = "/etc/wsl.conf"; c = configparser.ConfigParser(); c.optionxform = str; c.read(p)
for s, k, v in [("automount", "enabled", "false"), ("automount", "mountFsTab", "true"),
                ("interop", "enabled", "false"), ("interop", "appendWindowsPath", "false")]:
    c.has_section(s) or c.add_section(s); c.set(s, k, v)
with open(p, "w") as f: c.write(f)
PY
    for m in /mnt/[a-z]; do mountpoint -q "$m" && { umount "$m" 2>/dev/null || umount -l "$m"; }; done
    [ -w /proc/sys/fs/binfmt_misc/WSLInterop ] && echo 0 > /proc/sys/fs/binfmt_misc/WSLInterop || true
  fi
fi

# 1. packages ---------------------------------------------------------------------------------------
say packages
run apt-get update -qq
# shellcheck disable=SC2086  # word-split on purpose: a package list
run apt-get install -y -qq $PKGS_BASE   # node >= 25 links libatomic; native npm addons need a compiler

# 2. user + client keys -----------------------------------------------------------------------------
say user
id "$RD_USER" >/dev/null 2>&1 || run useradd -m -s /bin/bash "$RD_USER"
RD_HOME=$(getent passwd "$RD_USER" | cut -d: -f6 || true); RD_HOME=${RD_HOME:-/home/$RD_USER}
ADMIN_USER=${ADMIN_USER:-${SUDO_USER:-$RD_USER}}
authorize_keys() {   # authorize_keys USER: add every key of --keys to USER's authorized_keys (dedupe by key blob)
  local u=$1 home ak n=0 key blob
  home=$(getent passwd "$u" | cut -d: -f6) || return 0
  install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
  ak="$home/.ssh/authorized_keys"; touch "$ak"; chmod 600 "$ak"; chown "$u": "$ak"
  while IFS= read -r key; do
    [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[A-Za-z0-9-]+)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] || continue
    blob=$(echo "$key" | awk '{print $2}')
    grep -qF " $blob" "$ak" && continue
    echo "$key" >> "$ak"; n=$((n+1))
    # unprovision-linux.sh takes back exactly the keys provision added (never one that was there before)
    install -d -m 755 /etc/rdocker; echo "$u $blob" >> /etc/rdocker/added-keys; chmod 600 /etc/rdocker/added-keys
  done < "$KEYS"
  say "client keys user=$u added=$n"
}
if [ -n "$KEYS" ] && [ "$DRY" != 1 ]; then
  authorize_keys "$RD_USER"
  # key-only sshd (step 10) needs the admin login to have a key too, or we would lock ourselves out
  [ "$ADMIN_USER" = "$RD_USER" ] || authorize_keys "$ADMIN_USER"
fi

# 3. sshd: Tailscale ip + loopback only, key-only for the rd user ---------------------------------------
say sshd
if put_file /etc/ssh/sshd_config.d/10-rdocker.conf 644 <<CONF
# rdocker: listen on the Tailscale address and loopback only
Port $PORT
ListenAddress $TS_IP
ListenAddress 127.0.0.1
PermitRootLogin no
Match User $RD_USER
  PasswordAuthentication no
  KbdInteractiveAuthentication no
CONF
then
  [ "$DRY" = 1 ] || sshd -t || die "sshd config rejected; /etc/ssh/sshd_config.d/10-rdocker.conf left in place - fix or remove it"
  SSH_CHANGED=1
fi
# a listen address that is not up yet at boot must not stop sshd (Tailscale comes up later)
put_file /etc/sysctl.d/90-rdocker.conf 644 <<CONF || true
net.ipv4.ip_nonlocal_bind = 1
vm.swappiness = 10
CONF
[ "$DRY" = 1 ] || sysctl -q --system >/dev/null 2>&1 || true
put_file /etc/systemd/system/ssh.service.d/10-rdocker.conf 644 <<'CONF' || true
[Unit]
After=tailscaled.service
CONF
if [ "$DRY" != 1 ]; then
  systemctl list-unit-files ssh.socket >/dev/null 2>&1 && systemctl disable --now ssh.socket 2>/dev/null || true   # socket activation ignores Port/ListenAddress
  systemctl daemon-reload
  systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
  [ "${SSH_CHANGED:-0}" = 1 ] && { systemctl restart ssh 2>/dev/null || systemctl restart sshd; } || systemctl start ssh 2>/dev/null || true
fi

# 4. capped Docker data disk (ext4 loop image) - BEFORE docker so the dir starts empty -----------------------
say docker-disk
if ! mountpoint -q /var/lib/docker; then
  [ -f "$IMG" ] || run truncate -s "${IMG_GB}G" "$IMG"
  blkid "$IMG" >/dev/null 2>&1 || run mkfs.ext4 -q -F "$IMG"
  grep -qF "$IMG /var/lib/docker" /etc/fstab || { [ "$DRY" = 1 ] && echo "+ fstab entry" || echo "$IMG /var/lib/docker ext4 loop,defaults,nofail 0 0" >> /etc/fstab; }
  if [ -d /var/lib/docker ] && [ -n "$(ls -A /var/lib/docker 2>/dev/null)" ]; then   # docker already ran here: carry its data over, keep the old copy
    run systemctl stop docker docker.socket
    run mv /var/lib/docker /var/lib/docker.pre-rdocker
    run mkdir -p /var/lib/docker
    run mount /var/lib/docker
    run cp -a /var/lib/docker.pre-rdocker/. /var/lib/docker/
    echo "RDPROV note old docker data kept at /var/lib/docker.pre-rdocker (delete it by hand once verified)"
  else
    run mkdir -p /var/lib/docker
    run mount /var/lib/docker
  fi
fi

# 5. docker-ce ------------------------------------------------------------------------------------------
say docker
if ! command -v docker >/dev/null 2>&1 || ! docker --version 2>/dev/null | grep -q "Docker version"; then
  run install -m 0755 -d /etc/apt/keyrings
  [ -f /etc/apt/keyrings/docker.asc ] || run curl -fsSL "https://download.docker.com/linux/$DOCKER_DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
  put_file /etc/apt/sources.list.d/docker.list 644 <<CONF || true
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DOCKER_DISTRO $CODENAME stable
CONF
  run apt-get update -qq
  # shellcheck disable=SC2086  # word-split on purpose: a package list
  run apt-get install -y -qq $PKGS_DOCKER
fi
LIVE_RESTORE=""; [ "$IS_HOME" = 1 ] && LIVE_RESTORE='  "live-restore": true,
'   # home keeps DBs: dockerd restarts/upgrades must not stop containers
if put_file /etc/docker/daemon.json 644 <<CONF
{
  "ip": "127.0.0.1",
${LIVE_RESTORE}  "features": {"containerd-snapshotter": false},
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "builder": {"gc": {"enabled": true, "defaultKeepStorage": "1GB"}}
}
CONF
then DOCKER_CHANGED=1; fi
put_file /etc/systemd/system/docker.service.d/10-rdocker.conf 644 <<'CONF' || true
[Unit]
RequiresMountsFor=/var/lib/docker
CONF
if [ "$DRY" != 1 ]; then
  systemctl daemon-reload
  systemctl enable docker >/dev/null 2>&1 || true
  if [ "${DOCKER_CHANGED:-0}" = 1 ] && systemctl is-active --quiet docker; then systemctl restart docker; else systemctl start docker || true; fi
fi

# 6. journald, chrony, headless tuning ------------------------------------------------------------------
say system
if put_file /etc/systemd/journald.conf.d/50-rdocker.conf 644 <<'CONF'
[Journal]
SystemMaxUse=50M
CONF
then run systemctl restart systemd-journald; fi
if [ -d /etc/chrony/conf.d ] || grep -q '^confdir' /etc/chrony/chrony.conf 2>/dev/null; then
  put_file /etc/chrony/conf.d/rdocker.conf 644 <<'CONF' && run systemctl restart chrony || true
makestep 0.05 -1
CONF
elif ! grep -q '^makestep 0.05 -1' /etc/chrony/chrony.conf 2>/dev/null; then
  [ "$DRY" = 1 ] && echo "+ append makestep to chrony.conf" || echo "makestep 0.05 -1" >> /etc/chrony/chrony.conf
  run systemctl restart chrony
fi
run systemctl enable chrony >/dev/null 2>&1 || true
[ "$HEADLESS" = auto ] && { [ "$ID" = linuxmint ] && HEADLESS=yes || HEADLESS=no; }
[ "$IS_WSL" = 1 ] && HEADLESS=no
[ "$HEADLESS" = yes ] && run systemctl set-default multi-user.target

# 7. sudoers: only the verbs the janitor / kick path needs ------------------------------------------------------
say sudoers
SYSTEMCTL=$(command -v systemctl || echo /usr/bin/systemctl); JOURNALCTL=$(command -v journalctl || echo /usr/bin/journalctl)
FSTRIM=$(command -v fstrim || echo /usr/sbin/fstrim)
SSHD=$(command -v sshd || echo /usr/sbin/sshd); UFW=$(command -v ufw || echo /usr/sbin/ufw)   # read-only checks for rd-verify
SUDOERS_TMP=$(mktemp)
cat > "$SUDOERS_TMP" <<CONF
$RD_USER ALL=(root) NOPASSWD: $SYSTEMCTL start docker, $SYSTEMCTL restart docker, $JOURNALCTL --vacuum-size=*, $FSTRIM -a, $SSHD -T, $UFW status verbose
CONF
if [ "$DRY" != 1 ]; then
  visudo -cf "$SUDOERS_TMP" >/dev/null || die "generated sudoers failed visudo"
  cmp -s "$SUDOERS_TMP" /etc/sudoers.d/rd-docker 2>/dev/null || install -m 440 "$SUDOERS_TMP" /etc/sudoers.d/rd-docker
fi
rm -f "$SUDOERS_TMP"

# 8. node (mise) for the rd user ----------------------------------------------------------------------------------
say node
if [ "$DRY" != 1 ]; then
  as_rd() { runuser -u "$RD_USER" -- env HOME="$RD_HOME" PATH="$RD_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
  [ -x "$RD_HOME/.local/bin/mise" ] || as_rd sh -c 'curl -fsSL https://mise.run | sh'
  as_rd "$RD_HOME/.local/bin/mise" use -g node@25 pnpm@9
  grep -qs 'rdocker: mise' "$RD_HOME/.bashrc" || printf '%s\n' '# rdocker: mise (node for non-interactive ssh too)' 'export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"' >> "$RD_HOME/.bashrc"
  as_rd mkdir -p "$RD_HOME/rr"
fi

# 8b. ~/rr on a reflink XFS image (rd-rrfs.sh) - before anything starts writing ~/rr --------------------------
say rr-volume
if [ -f "$SRC/rd-rrfs.sh" ]; then
  put_file /usr/local/bin/rd-rrfs 755 < "$SRC/rd-rrfs.sh" || true
  if [ "$RR_GB" != 0 ] && [ "$DRY" != 1 ]; then
    if [ -n "$(ls -A "$RD_HOME/rr" 2>/dev/null)" ] && ! mountpoint -q "$RD_HOME/rr"; then
      echo "RDPROV note ~/rr already has data: move it when idle with rd-rrfs create --gb N; rd-rrfs presync; rd-rrfs cutover"
    else
      gb=$RR_GB
      if [ "$gb" = auto ]; then
        gb=$(RD_RRFS_USER=$RD_USER /usr/local/bin/rd-rrfs max-gb); cap=300; [ "$IS_WSL" = 1 ] && cap=120
        [ "$gb" -gt "$cap" ] && gb=$cap
      fi
      if [ "$gb" -ge 40 ] 2>/dev/null; then
        RD_RRFS_USER=$RD_USER /usr/local/bin/rd-rrfs create --gb "$gb" && systemctl start rd-rrfs.service
      else
        echo "RDPROV note no room for a ~/rr volume (max ${gb} GB < 40): ~/rr stays on the root disk"
      fi
    fi
  fi
fi

# 9. rd-tune (optimizer) + reporter units ----------------------------------------------------------------------------
say rd-tune
if [ -f "$SRC/rd-tune.sh" ]; then
  put_file /etc/rdocker/tune.conf 644 <<CONF || true
RD_USER=$RD_USER
MAX_SLOTS=$MAX_SLOTS
HEAVY_SLOTS=$HEAVY_SLOTS
IS_HOME=$IS_HOME
CONF
  put_file /usr/local/bin/rd-tune 755 < "$SRC/rd-tune.sh" || true
  put_file /etc/systemd/system/rd-tune.service 644 < "$SRC/rd-tune.service" || true
  put_file /etc/systemd/system/rd-tune.timer 644 < "$SRC/rd-tune.timer" || true
  [ "$DRY" = 1 ] || { systemctl daemon-reload; systemctl enable --now rd-tune.timer; }
fi
if [ -d "$SRC/reporter" ] && [ "$DRY" != 1 ]; then
  say reporter
  install -d -o "$RD_USER" -g "$RD_USER" "$RD_HOME/.local/share/rdocker-reporter"
  cp -r "$SRC/reporter/." "$RD_HOME/.local/share/rdocker-reporter/" && chown -R "$RD_USER": "$RD_HOME/.local/share/rdocker-reporter"
  echo "RDPROV note reporter files copied; enable it once ~/.config/rdocker/reporter.json exists (see reporter/README)"
fi

say resilience
if [ "$DRY" = 1 ]; then echo "+ rd-resilience.sh"; else
  put_file /usr/local/bin/rd-verify 755 < "$SRC/rd-verify.sh" || true
  # the owner of the box can take everything off again without us: `sudo bash /usr/local/bin/rd-unprovision`
  put_file /usr/local/bin/rd-unprovision 755 < "$SRC/unprovision-linux.sh" || true
  HOME_FLAG=(); [ "$IS_HOME" = 1 ] && HOME_FLAG=(--home)
  bash "$SRC/rd-resilience.sh" --user "$RD_USER" --wsl "$IS_WSL" --distro "$ID" --codename "$CODENAME" --src "$SRC" "${HOME_FLAG[@]}"
fi

say harden
if [ "$DRY" = 1 ]; then echo "+ rd-harden.sh"; else
  bash "$SRC/rd-harden.sh" --user "$RD_USER" --admin-user "$ADMIN_USER" --keys "${KEYS:-/nonexistent}" --port "$PORT" --wsl "$IS_WSL" --src "$SRC"
fi

[ "$DRY" = 1 ] || { systemctl is-active --quiet docker || die "docker is not running"; }
echo "RDPROV ok user=$RD_USER ts-ip=$TS_IP port=$PORT wsl=$IS_WSL"
