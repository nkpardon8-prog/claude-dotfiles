#!/bin/bash
# unprovision-linux.sh - the reverse of provision-linux.sh: take everything rdocker put on a Linux box back off
# it, so a friend who lent us the machine gets it back as it was. Run as root:
#
#   sudo bash unprovision-linux.sh [--user rd] [--yes] [--dry-run] [--purge-packages]
#                                  [--keys FILE --admin-user U]
#
#   --user U          the service user provision made (default: RD_USER in /etc/rdocker/tune.conf, else rd)
#   --yes             do not ask before changing anything
#   --dry-run         print what would be done; change nothing
#   --purge-packages  also purge the packages provision installed (docker-ce & co, chrony, build-essential,
#                     xfsprogs, ufw, unattended-upgrades, pciutils) - only the ones the box did not have before.
#                     Default: packages stay, docker's config is put back.
#   --keys FILE       our client public keys: removed from --admin-user's authorized_keys (only needed on a box
#                     provisioned before /etc/rdocker/added-keys existed; `rdocker remove-server` passes both)
#
# What is ours: only the paths provision and its helpers (rd-resilience, rd-harden, rd-rrfs) write - rd-* tools
# and units, *rdocker* drop-ins, the two loop images, the sudoers file, the user it created - and only the
# containers / volumes / networks the pool labels (rdocker.rrun / rdocker.keep / rdocker.ttl / rdocker.placed,
# and an rrun run's own compose project rr<12 hex>-default). Shared settings (ufw, enabled services, masked sleep
# targets, docker group, sysctl values, daemon.json, 20auto-upgrades, wsl.conf, packages) are put back from the
# record the FIRST provision wrote (/etc/rdocker/prior-state + /etc/rdocker/prior/files). A box provisioned
# before that record existed keeps those settings, and the summary prints the command to undo each by hand.
# Never touched: other users' files and containers, Tailscale (the last line prints `sudo tailscale logout`).
# Idempotent: a second run finds nothing left of ours and changes nothing.
set -uo pipefail

RD_USER="" DRY=0 YES=0 PURGE=0 KEYS="" ADMIN_USER=""
DOCKER_IMG=/var/lib/rdocker-docker.img
RR_IMG=/var/lib/rdocker-rr.xfs
RR_STAGE=/var/lib/rdocker-rr.stage
STATE_DIR=/etc/rdocker
PRIOR=$STATE_DIR/prior-state
SD=/etc/systemd/system
# rdocker's system units (rd-ac-poweron: the 2011/2012 Mac mini AC-loss unit) and its tools in /usr/local/bin
UNITS="rd-tune.timer rd-tune.service rd-doctor.timer rd-doctor.service rd-netcheck.timer rd-netcheck.service
       rd-archive.timer rd-archive.service rd-power.service rd-docker-user.service rd-rrfs.service rd-ac-poweron.service"
TOOLS="rd-tune rd-doctor rd-netcheck rd-power rd-archive rd-verify rd-rrfs rd-docker-user"
# packages --purge-packages may remove (when the box lacked them before). Base tools provision installed
# (sudo, python3, openssh-server, git, ...) are never purged: other software depends on them.
PURGEABLE="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin chrony build-essential
           xfsprogs ufw unattended-upgrades pciutils"
OUR_LABELS="rdocker.rrun rdocker.keep rdocker.ttl rdocker.placed"

die() { echo "unprovision: $*" >&2; exit 1; }
say() { echo "RDUNPROV $*"; }
REMOVED=() KEPT=() FAILED=() RERUN=0   # RERUN=1: something of ours stays until a later re-run (keep the record)
gone() { REMOVED+=("$*"); }
kept() { KEPT+=("$*"); }
# act CMD...: run it (or print it under --dry-run); a failure is recorded, never fatal - finish the rest
exec 3>&1      # act's dry-run lines go here: a caller's >/dev/null must not hide them
act() {
  if [ "$DRY" = 1 ]; then echo "+ $*" >&3; return 0; fi
  "$@" || { FAILED+=("$*"); echo "unprovision: failed: $*" >&2; return 1; }
}
quiet() { "$@" >/dev/null 2>&1; }      # a probe or best-effort step whose output nobody needs
rm_file() {   # rm_file PATH WHAT: remove one file of ours
  [ -e "$1" ] || [ -L "$1" ] || return 0
  act rm -f "$1" && gone "$2 ($1)"
}
rmdir_empty() { [ -d "$1" ] && [ -z "$(ls -A "$1" 2>/dev/null)" ] && act rmdir "$1"; return 0; }
has() { [[ " ${2//$'\n'/ } " == *" $1 "* ]]; }   # has WORD LIST (space/newline separated)
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) RD_USER=${2:?}; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --purge-packages) PURGE=1; shift ;;
    --keys) KEYS=${2:?}; shift 2 ;;
    --admin-user) ADMIN_USER=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -z "$RD_USER" ]; then
  RD_USER=$(sed -n 's/^RD_USER=//p' "$STATE_DIR/tune.conf" 2>/dev/null | head -1)
  RD_USER=${RD_USER:-rd}
fi
[[ "$RD_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "bad --user"
[ -z "$ADMIN_USER" ] || [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "bad --admin-user"
[ -z "$KEYS" ] || [ -r "$KEYS" ] || die "cannot read --keys $KEYS"
[ -z "$KEYS" ] || [ -n "$ADMIN_USER" ] || die "--keys needs --admin-user (whose authorized_keys to clean)"
[ "$(id -u)" = 0 ] || [ "$DRY" = 1 ] || die "run as root: sudo bash $0 ..."
[ "${SUDO_USER:-}" != "$RD_USER" ] || die "you are logged in as $RD_USER, the user this removes: run it from another sudo login"

# --- the record of the box before provision ----------------------------------------------------------------
HAVE_PRIOR=0
PRIOR_USER_EXISTED="" PRIOR_LINGER=0 PRIOR_PKGS_MISSING="" PRIOR_PKGS_PRESENT="" PRIOR_ENABLED="" PRIOR_MASKED=""
PRIOR_FILES="" PRIOR_DEFAULT_TARGET="" PRIOR_UFW_ACTIVE="" PRIOR_DOCKER_GROUP="" PRIOR_CHRONY_MAKESTEP="" PRIOR_DOCKER_DATA=1
if [ -f "$PRIOR" ]; then
  # root-written, 0600: refuse one anybody else could have edited (it is sourced as root)
  [ "$(stat -c '%u %a' "$PRIOR")" = "0 600" ] || die "$PRIOR is not root-owned 0600: refusing to read it"
  grep -vqE '^(#.*|PRIOR_[A-Za-z0-9_]+=.*)$' "$PRIOR" && die "$PRIOR has unexpected lines: refusing to read it"
  # shellcheck disable=SC1090
  . "$PRIOR"; HAVE_PRIOR=1
fi
prior_file() { has "$1" "$PRIOR_FILES"; }   # did the box have this shared file before provision?

RD_HOME=$(getent passwd "$RD_USER" | cut -d: -f6)
RD_UID=$(id -u "$RD_USER" 2>/dev/null || true)
PORT=$(sed -n 's/^Port \([0-9]\{1,5\}\)$/\1/p' /etc/ssh/sshd_config.d/10-rdocker.conf 2>/dev/null | head -1)
PORT=${PORT:-22}
# is the service user ours to delete? With the record: provision created it. Without: it carries every mark of
# provision (named in the sudoers file / tune.conf, and the mise line provision appends to its .bashrc).
USER_OURS=0
if [ -n "$RD_UID" ]; then
  if [ "$HAVE_PRIOR" = 1 ]; then [ "$PRIOR_USER_EXISTED" = 0 ] && USER_OURS=1
  elif { grep -qs "^$RD_USER ALL=(root) NOPASSWD:" /etc/sudoers.d/rd-docker || grep -qsx "RD_USER=$RD_USER" "$STATE_DIR/tune.conf"; } \
       && grep -qs 'rdocker: mise' "$RD_HOME/.bashrc"; then USER_OURS=1; fi
fi

say "user=$RD_USER (delete: $([ "$USER_OURS" = 1 ] && echo yes || echo no)) prior-record=$([ "$HAVE_PRIOR" = 1 ] && echo yes || echo no) purge-packages=$PURGE dry-run=$DRY"
if [ "$DRY" != 1 ] && [ "$YES" != 1 ]; then
  [ -r /dev/tty ] || die "no terminal to confirm on: re-run with --yes (or --dry-run first)"
  echo "This removes rdocker from $(hostname): its services, tools, data images, pool containers$([ "$USER_OURS" = 1 ] && echo ", and user $RD_USER with its home $RD_HOME")."
  printf 'Type yes to continue: '
  read -r ans < /dev/tty
  [ "$ans" = yes ] || die "not confirmed; nothing changed"
fi

# --- 1. stop our services first: nothing of ours may run (or write ~/rr) while it is taken apart -----------
say "step services"
unit_is_ours() {   # an rd-* unit file provision wrote (every one says rdocker; rd-ac-poweron is the setpci one)
  local f="$SD/$1"
  [ -f "$f" ] && { grep -q rdocker "$f" || grep -qx 'ExecStart=/usr/bin/setpci -s 00:1f.0 0xa4.b=0:1' "$f"; }
}
OUR_UNITS=""
for u in $UNITS; do unit_is_ours "$u" && OUR_UNITS="$OUR_UNITS $u"; done
for u in $OUR_UNITS; do
  case "$u" in rd-rrfs.service) continue ;; esac    # its mount is taken down with the ~/rr volume (step 5)
  act systemctl disable --now "$u" >/dev/null 2>&1 || true
done
if [ -n "$RD_UID" ] && [ "$USER_OURS" = 1 ]; then
  # the reporter (user unit) and any rrun job: linger off, the user's manager and processes stopped
  if [ -e "/var/lib/systemd/linger/$RD_USER" ]; then act loginctl disable-linger "$RD_USER" && gone "linger for $RD_USER"; fi
  if [ "$DRY" = 1 ]; then echo "+ stop every process of $RD_USER (loginctl terminate-user, pkill)"
  else
    quiet loginctl terminate-user "$RD_USER"; quiet systemctl stop "user@$RD_UID.service"
    quiet pkill -TERM -u "$RD_UID"; sleep 2; quiet pkill -KILL -u "$RD_UID"
  fi
fi

# --- 2. pool containers (labelled ours) --------------------------------------------------------------------
say "step containers"
DOCKER_OK=0 FOREIGN_CT=0 FOREIGN_VOL=0 VOLS_OURS=0
if command -v docker >/dev/null 2>&1; then
  quiet docker info || { [ "$DRY" = 1 ] || quiet systemctl start docker; }
  quiet docker info && DOCKER_OK=1
fi
if [ "$DOCKER_OK" = 1 ]; then
  ids_by_labels() {   # ids_by_labels container|volume|network -> ids/names of objects carrying one of our labels
    local kind=$1 l fmt='{{.ID}}'
    [ "$kind" = volume ] && fmt='{{.Name}}'
    for l in $OUR_LABELS; do
      if [ "$kind" = container ]; then docker ps -aq --no-trunc --filter "label=$l"
      else docker "$kind" ls -q --filter "label=$l"; fi
    done 2>/dev/null
    # an rrun run's own compose project (rr_runner.pl compose_project): rr + 12 hex + -default
    if [ "$kind" = container ]; then docker ps -a --no-trunc --format '{{.ID}} {{.Label "com.docker.compose.project"}}'
    else docker "$kind" ls --format "$fmt {{.Label \"com.docker.compose.project\"}}"; fi 2>/dev/null \
      | awk '$2 ~ /^rr[0-9a-f]{12}-default$/ { print $1 }'
  }
  CTS=$(ids_by_labels container | sort -u)
  n=$(echo "$CTS" | grep -c . || true)
  # named volumes our containers mount (`-v name:/path` creates one without a label): ours once no other
  # container uses them - checked after ours are gone (docker volume rm refuses a volume still in use)
  # shellcheck disable=SC2086
  CT_VOLS=$( [ "$n" -gt 0 ] && docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' $CTS 2>/dev/null | grep . | sort -u)
  if [ "$n" -gt 0 ]; then
    say "removing $n pool container(s): $(echo "$CTS" | xargs -r docker inspect -f '{{.Name}}' 2>/dev/null | tr -d / | tr '\n' ' ')"
    # shellcheck disable=SC2086
    act docker rm -f -v $CTS >/dev/null && gone "$n pool container(s) (labelled rdocker.*)"
  fi
  for kind in volume network; do
    OBJS=$(ids_by_labels "$kind" | sort -u)
    if [ "$kind" = volume ] && [ -n "$CT_VOLS" ]; then
      for v in $CT_VOLS; do   # still mounted by a container that is not ours: not ours to remove
        if [ "$DRY" = 1 ]; then used=$(docker ps -aq --filter "volume=$v" | grep -vxF -f <(echo "$CTS" | cut -c1-12) | grep -c . || true)
        else used=$(docker ps -aq --filter "volume=$v" | grep -c . || true); fi
        [ "$used" = 0 ] && OBJS=$(printf '%s\n%s\n' "$OBJS" "$v")
      done
      OBJS=$(echo "$OBJS" | grep . | sort -u)
    fi
    n=$(echo "$OBJS" | grep -c . || true)
    [ "$kind" = volume ] && VOLS_OURS=$n
    # shellcheck disable=SC2086
    [ "$n" -gt 0 ] && act docker "$kind" rm $OBJS >/dev/null && gone "$n pool ${kind}(s)"
  done
  if [ "$DRY" = 1 ]; then   # what is left once ours are gone
    FOREIGN_CT=$(( $(docker ps -aq | grep -c . || true) - $(echo "$CTS" | grep -c . || true) ))
    FOREIGN_VOL=$(( $(docker volume ls -q | grep -c . || true) - VOLS_OURS ))
  else
    FOREIGN_CT=$(docker ps -aq | grep -c . || true); FOREIGN_VOL=$(docker volume ls -q | grep -c . || true)
  fi
  [ "$FOREIGN_CT" -gt 0 ] && kept "$FOREIGN_CT container(s) not labelled ours - never touched"
  [ "$FOREIGN_VOL" -gt 0 ] && kept "$FOREIGN_VOL docker volume(s) not labelled ours - never touched"
fi

# --- 3. the capped docker data disk (ext4 loop image at /var/lib/docker) ---------------------------------------
say "step docker-disk"
DISK_REMOVED=0
# is MOUNTPOINT mounted from IMAGE's loop device?
mounted_from() { local dev; dev=$(losetup -j "$2" -nO NAME 2>/dev/null | head -1)
  [ -n "$dev" ] && mountpoint -q "$1" 2>/dev/null && [ "$(findmnt -no SOURCE "$1" | head -1)" = "$dev" ]; }
if [ -f "$DOCKER_IMG" ]; then
  if ! mounted_from /var/lib/docker "$DOCKER_IMG"; then
    RERUN=1; kept "docker data image $DOCKER_IMG: not mounted, so its contents cannot be checked for data that is not ours (mount it and re-run, or delete it by hand)"
  elif [ "$DOCKER_OK" != 1 ]; then
    RERUN=1; kept "docker data image $DOCKER_IMG: docker is not running, so its containers cannot be checked for ones that are not ours"
  elif [ $((FOREIGN_CT + FOREIGN_VOL)) -gt 0 ]; then
    RERUN=1; kept "docker data image $DOCKER_IMG at /var/lib/docker (+ its /etc/fstab line): it holds containers/volumes that are not ours; move them, then re-run"
  else
    act systemctl stop docker.socket docker.service >/dev/null 2>&1
    act umount /var/lib/docker || act umount -l /var/lib/docker
    for dev in $(losetup -j "$DOCKER_IMG" -nO NAME 2>/dev/null); do act losetup -d "$dev"; done
    rm_file "$DOCKER_IMG" "docker data image (pool images, build cache)" && DISK_REMOVED=1
  fi
fi
if [ "$DISK_REMOVED" = 1 ] || [ ! -f "$DOCKER_IMG" ]; then
  if grep -qF "$DOCKER_IMG /var/lib/docker" /etc/fstab 2>/dev/null; then
    if [ "$DRY" = 1 ]; then echo "+ remove the $DOCKER_IMG line from /etc/fstab"
    else cp -p /etc/fstab /etc/fstab.rdocker-bak && grep -vF "$DOCKER_IMG /var/lib/docker" /etc/fstab.rdocker-bak > /etc/fstab.tmp \
         && cat /etc/fstab.tmp > /etc/fstab && rm -f /etc/fstab.tmp /etc/fstab.rdocker-bak; fi
    gone "/etc/fstab line for the docker data image"
  fi
  if [ -d /var/lib/docker.pre-rdocker ]; then   # provision moved the box's own docker data aside: put it back
    if [ -n "$(ls -A /var/lib/docker 2>/dev/null)" ] && [ "$DRY" != 1 ]; then
      kept "/var/lib/docker.pre-rdocker (the box's docker data from before provision): /var/lib/docker is not empty, restore by hand"
    else
      rmdir_empty /var/lib/docker; act mv /var/lib/docker.pre-rdocker /var/lib/docker && gone "restored /var/lib/docker from /var/lib/docker.pre-rdocker"
    fi
  fi
fi

# --- 4. ~/rr on its reflink XFS image (rd-rrfs) ------------------------------------------------------------------
say "step rr-volume"
RR=${RD_HOME:+$RD_HOME/rr}
if unit_is_ours rd-rrfs.service; then act systemctl disable --now rd-rrfs.service >/dev/null 2>&1; fi
if [ -f "$RR_IMG" ]; then
  for mp in "$RR_STAGE" ${RR:+"$RR"}; do
    mounted_from "$mp" "$RR_IMG" && { act umount "$mp" || act umount -l "$mp"; }
  done
  for dev in $(losetup -j "$RR_IMG" -nO NAME 2>/dev/null); do act losetup -d "$dev"; done
  rm_file "$RR_IMG" "~$RD_USER/rr XFS volume image"
fi
rmdir_empty "$RR_STAGE"
# the empty mountpoint rd-rrfs left is immutable (chattr +i): clear the flag so it can go with the home
if [ -n "$RR" ] && [ -d "$RR" ] && ! mountpoint -q "$RR"; then act chattr -i "$RR" 2>/dev/null; fi

# --- 5. unit files and drop-ins ------------------------------------------------------------------------------------
say "step units"
for u in $OUR_UNITS; do rm_file "$SD/$u" "unit $u"; done
DOCKER_UNITS_CH=0
for d in ssh.service.d/10-rdocker.conf docker.service.d/10-rdocker.conf docker.socket.d/10-rdocker.conf \
         ssh.service.d/10-rdocker-restart.conf tailscaled.service.d/10-rdocker-restart.conf \
         docker.service.d/10-rdocker-restart.conf chrony.service.d/10-rdocker-restart.conf; do
  if [ "$d" = docker.service.d/10-rdocker.conf ] && [ -f "$DOCKER_IMG" ]; then
    [ -f "$SD/$d" ] && kept "$SD/$d (docker waits for the data image that is kept)"; continue
  fi
  [ -e "$SD/$d" ] && case "$d" in docker.*) DOCKER_UNITS_CH=1 ;; esac
  rm_file "$SD/$d" "drop-in $d"
  rmdir_empty "$SD/$(dirname "$d")"
done
act systemctl daemon-reload
# sleep targets provision masked; with no record, the box may have had them masked itself
for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  [ "$(systemctl is-enabled "$t" 2>/dev/null)" = masked ] || continue
  if [ "$HAVE_PRIOR" = 1 ]; then has "$t" "$PRIOR_MASKED" || { act systemctl unmask "$t" >/dev/null 2>&1 && gone "mask on $t"; }
  else kept "$t masked (no record of the box before provision; undo: sudo systemctl unmask $t)"; fi
done
CUR_TARGET=$(systemctl get-default 2>/dev/null || true)
if [ "$HAVE_PRIOR" = 1 ] && [ -n "$PRIOR_DEFAULT_TARGET" ] && [ "$CUR_TARGET" != "$PRIOR_DEFAULT_TARGET" ]; then
  act systemctl set-default "$PRIOR_DEFAULT_TARGET" >/dev/null 2>&1 && gone "default target $CUR_TARGET (back to $PRIOR_DEFAULT_TARGET)"
elif [ "$HAVE_PRIOR" != 1 ] && [ "$CUR_TARGET" = multi-user.target ]; then
  kept "default target multi-user.target (no record; a desktop box: sudo systemctl set-default graphical.target)"
fi

# --- 6. config files -----------------------------------------------------------------------------------------------
say "step config"
SSHD_CHANGED=0
for f in /etc/ssh/sshd_config.d/10-rdocker.conf /etc/ssh/sshd_config.d/05-rdocker-hardening.conf \
         /etc/ssh/sshd_config.d/05-rdocker-hardening.conf.rdbak; do
  [ -e "$f" ] && SSHD_CHANGED=1; rm_file "$f" "sshd config"
done
rm_file /etc/sysctl.d/90-rdocker.conf "sysctl (nonlocal bind, swappiness)"
rm_file /etc/sysctl.d/91-rdocker-panic.conf "sysctl (reboot on panic)"
J=/etc/systemd/journald.conf.d/50-rdocker.conf; JCH=0; [ -e "$J" ] && JCH=1; rm_file "$J" "journald 50M cap"
rmdir_empty /etc/systemd/journald.conf.d
rm_file /etc/systemd/logind.conf.d/50-rdocker.conf "logind lid/idle settings (apply at next boot)"
rmdir_empty /etc/systemd/logind.conf.d
W=/etc/systemd/system.conf.d/50-rdocker-watchdog.conf; WCH=0; [ -e "$W" ] && WCH=1; rm_file "$W" "hardware watchdog"
rmdir_empty /etc/systemd/system.conf.d
rm_file /etc/apt/apt.conf.d/52rdocker-unattended "unattended-upgrades auto-reboot policy"
rm_file /etc/sudoers.d/rd-docker "sudoers rules for $RD_USER"
CHRONY_CH=0
if [ -e /etc/chrony/conf.d/rdocker.conf ]; then rm_file /etc/chrony/conf.d/rdocker.conf "chrony makestep"; CHRONY_CH=1
elif grep -qs '^makestep 0.05 -1$' /etc/chrony/chrony.conf; then
  if [ "$HAVE_PRIOR" = 1 ] && [ "$PRIOR_CHRONY_MAKESTEP" = 0 ]; then
    if [ "$DRY" = 1 ]; then echo "+ remove 'makestep 0.05 -1' from /etc/chrony/chrony.conf"
    else sed -i '/^makestep 0\.05 -1$/d' /etc/chrony/chrony.conf; fi
    gone "chrony makestep line"; CHRONY_CH=1
  elif [ "$HAVE_PRIOR" != 1 ]; then kept "'makestep 0.05 -1' in /etc/chrony/chrony.conf (no record whether it was there before)"; fi
fi
# shared files edited in place: the copy from before provision goes back; one provision created goes away
restore_shared() {   # restore_shared PATH WHAT
  local p=$1 bak="$STATE_DIR/prior/files$1"
  if [ "$HAVE_PRIOR" = 1 ] && prior_file "$p"; then
    [ -e "$bak" ] || { kept "$p (recorded as pre-existing but its copy is missing)"; return 1; }
    cmp -s "$bak" "$p" && return 1
    act cp -a "$bak" "$p" && gone "$2: put back the box's own $p"
  elif [ "$HAVE_PRIOR" = 1 ]; then
    [ -e "$p" ] || return 1
    rm_file "$p" "$2"
  else
    [ -e "$p" ] && kept "$p (no record of the box before provision: maybe edited by provision; check it by hand)"
    return 1
  fi
}
restore_shared /etc/apt/apt.conf.d/20auto-upgrades "automatic apt updates"
grep -qi microsoft /proc/version 2>/dev/null && { restore_shared /etc/wsl.conf "WSL settings" && kept "WSL settings apply after: wsl --shutdown (from Windows)"; }

# apply what changed: sshd only once its config checks out (an ssh session must never be cut by a bad file)
if [ "$SSHD_CHANGED" = 1 ] && [ "$DRY" != 1 ]; then
  if sshd -t 2>/dev/null || /usr/sbin/sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || FAILED+=("restart ssh")
  else FAILED+=("sshd -t rejects the box's own sshd config: ssh NOT restarted (fix it, then: sudo systemctl restart ssh)"); fi
fi
if [ "$HAVE_PRIOR" = 1 ] && [ "$DRY" != 1 ]; then
  for v in net.ipv4.ip_nonlocal_bind vm.swappiness kernel.panic kernel.panic_on_oops; do
    var="PRIOR_SYSCTL_$(echo "$v" | tr '.' '_')"; val=${!var:-}
    [ -n "$val" ] && [ "$(sysctl -n "$v" 2>/dev/null)" != "$val" ] && quiet sysctl -w "$v=$val"
  done
fi
[ "$DRY" = 1 ] || quiet sysctl --system
[ "$JCH" = 1 ] && act systemctl restart systemd-journald
[ "$CHRONY_CH" = 1 ] && pkg_installed chrony && act systemctl restart chrony
[ "$WCH" = 1 ] && act systemctl daemon-reexec

# --- 7. firewall + the services rd-harden turned off ---------------------------------------------------------------
say "step firewall"
drop_ufw_rules() {   # the three rules rd-harden adds; ufw deletes the v4 and v6 copy of each
  local r
  local rules=("allow in on tailscale0 to any port $PORT proto tcp" "allow 41641/udp")
  [ "$PORT" = 22 ] || rules+=("allow in on tailscale0 to any port 22 proto tcp")
  for r in "${rules[@]}"; do
    # shellcheck disable=SC2086  # word-split on purpose: a ufw rule
    ufw show added 2>/dev/null | grep -qxF "ufw $r" && act ufw delete $r >/dev/null && gone "ufw rule: $r"
  done
}
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if [ "$HAVE_PRIOR" = 1 ]; then
    [ "$PRIOR_UFW_ACTIVE" = 0 ] && act ufw --force disable >/dev/null && gone "ufw firewall (was off before provision)"
    drop_ufw_rules    # either way (when ufw was already on, the box had its own way in)
  else
    kept "ufw on with rdocker's rules (no record whether ufw was on before; undo: sudo ufw --force disable)"
  fi
elif command -v ufw >/dev/null 2>&1 && [ "$HAVE_PRIOR" = 1 ]; then
  drop_ufw_rules
fi
if command -v iptables >/dev/null 2>&1 && quiet iptables -S DOCKER-USER && iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j DROP'; then
  act iptables -F DOCKER-USER && gone "DOCKER-USER firewall chain rules"
fi
if [ "$HAVE_PRIOR" = 1 ]; then
  for u in $PRIOR_ENABLED; do
    case "$u" in ssh.*) continue ;; esac
    [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] || { act systemctl enable --now "$u" >/dev/null 2>&1 && gone "disable on $u (re-enabled)"; }
  done
  # Ubuntu's socket-activated sshd: provision switched it to ssh.service. Switched back for the NEXT boot only,
  # so the ssh session this runs in is never cut.
  if has ssh.socket "$PRIOR_ENABLED" && [ "$(systemctl is-enabled ssh.socket 2>/dev/null)" != enabled ]; then
    act systemctl enable ssh.socket >/dev/null 2>&1
    has ssh.service "$PRIOR_ENABLED" || act systemctl disable ssh.service >/dev/null 2>&1
    gone "ssh on ssh.service (socket activation back from the next boot)"
  fi
else
  kept "avahi/cups/rpcbind stay as rd-harden left them (no record; to re-enable one: sudo systemctl enable --now <unit>)"
fi

# --- 8. docker config ---------------------------------------------------------------------------------------------
say "step docker-config"
DOCKER_CH=0
restore_shared /etc/docker/daemon.json "docker daemon.json" && DOCKER_CH=1
if getent group docker >/dev/null; then
  if [ "$HAVE_PRIOR" = 1 ]; then
    case "$PRIOR_DOCKER_GROUP" in
      yes:*) want=""; for m in $(echo "${PRIOR_DOCKER_GROUP#yes:}" | tr ',' ' '); do
               id "$m" >/dev/null 2>&1 && { [ "$m" != "$RD_USER" ] || [ "$USER_OURS" != 1 ]; } && want="$want,$m"; done
             want=${want#,}
             [ "$(getent group docker | cut -d: -f4)" = "$want" ] || { act gpasswd -M "$want" docker >/dev/null && gone "docker group members (back to: ${want:-none})"; } ;;
    esac
  else
    kept "docker group: rd-harden set its members to $RD_USER only; any member from before is not known (no record)"
  fi
fi

# --- 9. tools ---------------------------------------------------------------------------------------------------
say "step tools"
for t in $TOOLS; do
  f=/usr/local/bin/$t
  [ -f "$f" ] || continue
  if sed -n 2p "$f" | grep -q "^# $t\b"; then rm_file "$f" "tool $t"; else kept "$f (not rdocker's: no '# $t' header)"; fi
done
if [ -f /usr/local/libexec/rd-tune ] && sed -n 2p /usr/local/libexec/rd-tune | grep -q '^# rd-tune\b'; then
  rm_file /usr/local/libexec/rd-tune "tool rd-tune (libexec)"; rmdir_empty /usr/local/libexec
fi

# --- 10. the service user ---------------------------------------------------------------------------------------
say "step user"
if [ -n "$RD_UID" ]; then
  if [ "$USER_OURS" = 1 ]; then
    case "$RD_HOME" in /|/root|/home|/usr*|/etc*|/var|/bin*|/sbin*|"") die "refusing: $RD_USER's home is $RD_HOME" ;; esac
    if [ "$DRY" != 1 ] && [ -n "$RR" ] && mountpoint -q "$RR" 2>/dev/null; then
      RERUN=1; kept "user $RD_USER: $RR is still a mount point (unmount it, then re-run)"
    else
      act userdel -r "$RD_USER" && gone "user $RD_USER and its home $RD_HOME (~/rr, mise node/pnpm, reporter, configs)"
      getent group "$RD_USER" >/dev/null 2>&1 && [ -z "$(getent group "$RD_USER" | cut -d: -f4)" ] && act groupdel "$RD_USER"
      rm_file "/var/lib/systemd/linger/$RD_USER" "linger for $RD_USER"
    fi
  else
    # the user was there before: only our files leave its home
    for p in .config/systemd/user/rd-reporter.service .config/systemd/user/rd-reporter.service.d \
             .config/systemd/user/default.target.wants/rd-reporter.service .local/share/rdocker \
             .local/share/rdocker-reporter .config/rdocker rr; do
      [ -e "$RD_HOME/$p" ] || [ -L "$RD_HOME/$p" ] || continue
      act rm -rf "${RD_HOME:?}/$p" && gone "~$RD_USER/$p"
    done
    if grep -qs 'rdocker: mise' "$RD_HOME/.bashrc"; then
      if [ "$DRY" = 1 ]; then echo "+ remove rdocker's mise PATH lines from ~$RD_USER/.bashrc"
      else sed -i '/^# rdocker: mise (node for non-interactive ssh too)$/{N;d;}' "$RD_HOME/.bashrc"; fi
      gone "rdocker's PATH lines in ~$RD_USER/.bashrc"
    fi
    [ "$HAVE_PRIOR" = 1 ] && [ "$PRIOR_LINGER" = 0 ] && [ -e "/var/lib/systemd/linger/$RD_USER" ] && act loginctl disable-linger "$RD_USER"
    kept "user $RD_USER (existed before provision$([ "$HAVE_PRIOR" = 1 ] || echo ' or not clearly ours')), its mise install (~/.local/bin/mise, ~/.local/share/mise)"
  fi
fi

# --- 11. our client keys in other logins ------------------------------------------------------------------------------
say "step keys"
drop_keys() {   # drop_keys USER BLOB...: remove authorized_keys lines whose key blob is one of ours
  local u=$1; shift
  local home ak n
  home=$(getent passwd "$u" | cut -d: -f6) || return 0
  ak="$home/.ssh/authorized_keys"; [ -f "$ak" ] || return 0
  n=$(awk -v bl=" $* " 'BEGIN{c=0} { for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)/ && index(bl, " " $(i+1) " ")) { c++; break } } END{print c}' "$ak")
  [ "$n" -gt 0 ] || return 0
  if [ "$DRY" = 1 ]; then echo "+ remove $n rdocker client key(s) from $ak"
  else
    awk -v bl=" $* " '{ for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)/ && index(bl, " " $(i+1) " ")) next; print }' "$ak" > "$ak.rdtmp" \
      && cat "$ak.rdtmp" > "$ak" && rm -f "$ak.rdtmp"    # cat >: keeps the file's owner and mode
  fi
  gone "$n rdocker client key(s) from $u's authorized_keys"
}
if [ -f "$STATE_DIR/added-keys" ]; then
  for u in $(awk '{print $1}' "$STATE_DIR/added-keys" | sort -u); do
    [ "$u" = "$RD_USER" ] && [ "$USER_OURS" = 1 ] && continue
    # shellcheck disable=SC2046
    drop_keys "$u" $(awk -v u="$u" '$1 == u {print $2}' "$STATE_DIR/added-keys")
  done
fi
if [ -n "$KEYS" ] && [ "$ADMIN_USER" != "$RD_USER" ]; then
  # shellcheck disable=SC2046
  drop_keys "$ADMIN_USER" $(awk '/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)/ {print $2}' "$KEYS")
fi

# --- 12. packages (--purge-packages only) ------------------------------------------------------------------------
say "step packages"
DOCKER_PURGED=0
if [ "$PURGE" = 1 ]; then
  if [ "$HAVE_PRIOR" != 1 ]; then
    kept "packages: no record of which ones the box had before provision, none purged (by hand: sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)"
  else
    P=""
    for p in $PURGEABLE; do has "$p" "$PRIOR_PKGS_MISSING" && pkg_installed "$p" && P="$P $p"; done
    if has docker-ce "$P" && [ $((FOREIGN_CT + FOREIGN_VOL)) -gt 0 ]; then
      P=$(printf '%s\n' $P | grep -vE '^(docker-.*|containerd\.io)$' | xargs)
      kept "docker packages: containers/volumes that are not ours still use docker"
    fi
    if [ -n "${P# }" ]; then
      # shellcheck disable=SC2086
      act env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $P >/dev/null && gone "packages:$P"
      has docker-ce "$P" && DOCKER_PURGED=1
      # installing chrony replaced the box's own time daemon: put that back
      for p in $PRIOR_PKGS_PRESENT; do
        pkg_installed "$p" || { act env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null && gone "chrony's replacement of $p (reinstalled)"; }
      done
    fi
    if [ "$DOCKER_PURGED" = 1 ]; then
      for f in /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc; do prior_file "$f" || rm_file "$f" "docker apt repo"; done
      [ "$PRIOR_DOCKER_DATA" = 0 ] && [ ! -d /var/lib/docker.pre-rdocker ] && for d in /var/lib/docker /var/lib/containerd; do
        [ -d "$d" ] && act rm -rf "$d" && gone "$d (docker installed by provision, purged)"
      done
      rmdir_empty /etc/docker
      if [ "$PRIOR_DOCKER_GROUP" = no ] && getent group docker >/dev/null && [ -z "$(getent group docker | cut -d: -f4)" ]; then act groupdel docker && gone "group docker"; fi
    fi
    kept "base tools provision may have installed (curl, git, rsync, python3, sudo, openssh-server, libatomic1, ...): never purged; 'sudo apt-get autoremove' clears leftover dependencies"
  fi
else
  kept "packages (docker-ce & co, chrony, build-essential, ufw, ...): kept - re-run with --purge-packages to remove the ones provision installed"
fi
# a kept docker comes back up on its own config (and, when the image went, a fresh /var/lib/docker)
if [ "$DOCKER_PURGED" != 1 ] && command -v docker >/dev/null 2>&1 \
   && [ $((DOCKER_CH + DISK_REMOVED + DOCKER_UNITS_CH)) -gt 0 ]; then
  act systemctl restart docker.socket docker.service >/dev/null 2>&1
fi

# --- 13. our state ----------------------------------------------------------------------------------------------
say "step state"
for p in /run/rdocker /run/rdocker-tune /run/rdocker-doctor /run/rdocker-netcheck.count /run/rd-rrfs.lock; do
  [ -e "$p" ] && act rm -rf "$p"
done
if [ -d "$STATE_DIR" ]; then
  if [ "$DRY" != 1 ] && { [ "${#FAILED[@]}" -gt 0 ] || [ "$RERUN" = 1 ]; }; then
    kept "$STATE_DIR (the prior-state record): kept so a re-run can still put things back"
  else
    act rm -rf "$STATE_DIR" && gone "$STATE_DIR (tune.conf, doctor.conf, the prior-state record)"
  fi
fi

# --- summary --------------------------------------------------------------------------------------------------
echo
if [ "$DRY" = 1 ]; then echo "== DRY RUN: nothing was changed. Would remove / put back:"; else echo "== Removed / put back:"; fi
[ "${#REMOVED[@]}" -gt 0 ] && printf '  - %s\n' "${REMOVED[@]}" || echo "  (nothing of rdocker's left)"
echo "== Kept:"
[ "${#KEPT[@]}" -gt 0 ] && printf '  - %s\n' "${KEPT[@]}" || echo "  (nothing)"
if [ "${#FAILED[@]}" -gt 0 ]; then echo "== FAILED:"; printf '  - %s\n' "${FAILED[@]}"; fi
echo "== Not touched: Tailscale. Optional last step, only if this box should leave our tailnet:"
echo "     sudo tailscale set --auto-update=false   # if provision turned auto-update on"
echo "     sudo tailscale logout"
[ "${#FAILED[@]}" -eq 0 ] || exit 1
echo "RDUNPROV ok"
