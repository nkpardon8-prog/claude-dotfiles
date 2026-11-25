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
ours_installed() { local p; for p in $PRIOR_PKGS_MISSING; do pkg_installed "$p" && return 0; done; return 1; }

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
PRIOR_USER_NAME="" PRIOR_UFW_RULES="" PRIOR_UFW_DEFAULTS="" PRIOR_DOCKER_USER="" PRIOR_FILES="" PRIOR_DEFAULT_TARGET="" PRIOR_UFW_ACTIVE="" PRIOR_DOCKER_GROUP="" PRIOR_CHRONY_MAKESTEP="" PRIOR_DOCKER_DATA=1
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
# is the service user ours to delete? Only when the record says provision created THIS user. Without a record
# (a box provisioned before it existed) the user stays: provision marks a user it found the same way.
USER_OURS=0
[ -n "$RD_UID" ] && [ "$HAVE_PRIOR" = 1 ] && [ "$PRIOR_USER_NAME" = "$RD_USER" ] && [ "$PRIOR_USER_EXISTED" = 0 ] && USER_OURS=1

# a box with no trace of rdocker (never provisioned, or already given back): nothing to do, and no "no record" hints
traces=0
for f in "$STATE_DIR" /etc/sudoers.d/rd-docker "$DOCKER_IMG" "$RR_IMG" /etc/ssh/sshd_config.d/10-rdocker.conf \
         /etc/ssh/sshd_config.d/05-rdocker-hardening.conf /var/lib/docker.pre-rdocker; do [ -e "$f" ] && traces=1; done
for u in $UNITS; do [ -e "$SD/$u" ] && traces=1; done
for t in $TOOLS; do [ -e "/usr/local/bin/$t" ] && traces=1; done
grep -qsF "$DOCKER_IMG" /etc/fstab && traces=1
if [ "$traces" = 0 ]; then echo "RDUNPROV nothing of rdocker's found on $(hostname): nothing to do"; echo "RDUNPROV ok"; exit 0; fi

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
# Ours = positive proof only: one of the pool's labels or an rrun run's compose project. Everything else (an
# unlabelled volume too, whoever made it) is the box's: counted, never removed, and it keeps the docker disk.
# A failed listing = nothing is known = nothing removed. Only the local daemon is asked (never DOCKER_HOST/context).
export DOCKER_HOST=unix:///var/run/docker.sock; unset DOCKER_CONTEXT
say "step containers"
DOCKER_OK=0 INVENTORY_OK=0 FOREIGN=0 N_IMAGES=0
if command -v docker >/dev/null 2>&1; then
  quiet docker info || { [ "$DRY" = 1 ] || quiet systemctl start docker; }
  quiet docker info && DOCKER_OK=1
fi
inv() {   # inv VAR docker-args...: VAR = the output; a failure marks the inventory unknown
  local _o
  if _o=$(docker "${@:2}" 2>/dev/null); then printf -v "$1" '%s' "$_o"; else INVENTORY_OK=0; printf -v "$1" ''; fi
}
classify() {   # stdin "<id>|<labels>|<compose project>" -> "OURS <id>" / "OTHER <id>"
  awk -F'|' -v labs="$OUR_LABELS" 'BEGIN { n = split(labs, L, " ") }
    NF { o = 0; m = split($2, kv, ",")
         for (i = 1; i <= m; i++) { split(kv[i], p, "="); for (j = 1; j <= n; j++) if (p[1] == L[j]) o = 1 }
         if ($3 ~ /^rr[0-9a-f]{12}-default$/) o = 1
         print (o ? "OURS " : "OTHER ") $1 }'
}
inventory() {   # -> globals C_ROWS V_ROWS N_ROWS (classified), N_IMAGES, DOCKER_ROOT
  local c v n i
  INVENTORY_OK=1
  inv DOCKER_ROOT info -f '{{.DockerRootDir}}'
  inv c ps -a --no-trunc --format '{{.ID}}|{{.Labels}}|{{.Label "com.docker.compose.project"}}'
  inv v volume ls --format '{{.Name}}|{{.Labels}}|{{.Label "com.docker.compose.project"}}'
  inv n network ls --no-trunc --filter type=custom --format '{{.ID}}|{{.Labels}}|{{.Label "com.docker.compose.project"}}'
  inv i images -q
  C_ROWS=$(classify <<< "$c"); V_ROWS=$(classify <<< "$v"); N_ROWS=$(classify <<< "$n")
  N_IMAGES=$(sort -u <<< "$i" | grep -c . || true)
}
if [ "$DOCKER_OK" = 1 ]; then
  inventory
  CTS=$(awk '$1 == "OURS" {print $2}' <<< "$C_ROWS")
  n=$(grep -c . <<< "$CTS" || true)
  if [ "$INVENTORY_OK" != 1 ]; then
    RERUN=1; kept "docker objects: listing them failed, so nothing in docker was removed (re-run once docker answers)"
  else
    if [ "$n" -gt 0 ]; then
      say "removing $n pool container(s): $(echo "$CTS" | xargs -r docker inspect -f '{{.Name}}' 2>/dev/null | tr -d / | tr '\n' ' ')"
      # shellcheck disable=SC2086
      act docker rm -f -v $CTS >/dev/null && gone "$n pool container(s) (labelled rdocker.*)"
    fi
    VOLS=$(awk '$1 == "OURS" {print $2}' <<< "$V_ROWS")
    NETS=$(awk '$1 == "OURS" {print $2}' <<< "$N_ROWS")
    for kind in volume network; do
      [ "$kind" = volume ] && OBJS=$VOLS || OBJS=$NETS
      k=$(grep -c . <<< "$OBJS" || true)
      # shellcheck disable=SC2086
      [ "$k" -gt 0 ] && act docker "$kind" rm $OBJS >/dev/null && gone "$k pool ${kind}(s)"
    done
    # what stays: every container / volume / custom network that is not ours (after the removals above)
    oc=$(grep -c '^OTHER' <<< "$C_ROWS" || true); on=$(grep -c '^OTHER' <<< "$N_ROWS" || true)
    ov=$(grep -c '^OTHER' <<< "$V_ROWS" || true)
    FOREIGN=$((oc + ov + on))
    [ "$oc" -gt 0 ] && kept "$oc container(s) that are not ours - never touched"
    [ "$ov" -gt 0 ] && kept "$ov docker volume(s) without a pool label - never touched: $(awk '$1 == "OTHER" {print $2}' <<< "$V_ROWS" | head -5 | xargs)"
    [ "$on" -gt 0 ] && kept "$on docker network(s) that are not ours - never touched"
  fi
fi

# --- 3. the capped docker data disk (ext4 loop image at /var/lib/docker) ---------------------------------------
say "step docker-disk"
DISK_REMOVED=0
unmount_all() {   # every mount stacked on $1 (a lazy umount when one is busy)
  local i
  if [ "$DRY" = 1 ]; then echo "+ umount $1 (every layer)" >&3; return 0; fi
  for i in 1 2 3 4 5 6 7 8; do mountpoint -q "$1" || return 0; umount "$1" 2>/dev/null || umount -l "$1" || return 1; done
}
detach_loops() {   # the loop devices of image $1; one a process still maps (a service's private mount view)
  local dev           # is only marked to detach: its space comes back when that process ends (at the latest, a reboot)
  for dev in $(losetup -j "$1" -nO NAME 2>/dev/null); do act losetup -d "$dev"; done
  [ "$DRY" = 1 ] && return 0
  sleep 1
  losetup -j "$1" 2>/dev/null | grep -q . && kept "$1: deleted, but a running service still maps it - its disk space returns at the next reboot"
  return 0
}
img_still_mounted() {   # is any loop device of image $1 mounted anywhere (this mount namespace)?
  local d
  for d in $(losetup -j "$1" -nO NAME 2>/dev/null); do findmnt -rn -S "$d" >/dev/null && return 0; done
  return 1
}
# is MOUNTPOINT mounted from IMAGE's loop device?
mounted_from() { local dev; dev=$(losetup -j "$2" -nO NAME 2>/dev/null | head -1)
  [ -n "$dev" ] && mountpoint -q "$1" 2>/dev/null && [ "$(findmnt -no SOURCE "$1" | head -1)" = "$dev" ]; }
if [ -f "$DOCKER_IMG" ]; then
  if ! mounted_from /var/lib/docker "$DOCKER_IMG"; then
    RERUN=1; kept "docker data image $DOCKER_IMG: not mounted, so its contents cannot be checked for data that is not ours (mount it and re-run, or delete it by hand)"
  elif [ "$DOCKER_OK" != 1 ] || [ "$INVENTORY_OK" != 1 ] || [ "$DOCKER_ROOT" != /var/lib/docker ]; then
    RERUN=1; kept "docker data image $DOCKER_IMG: docker did not answer, so it cannot be checked for data that is not ours"
  elif [ "$FOREIGN" -gt 0 ]; then
    RERUN=1; kept "docker data image $DOCKER_IMG at /var/lib/docker (+ its /etc/fstab line): it holds containers/volumes/networks that are not ours; move them, then re-run"
  else
    # dockerd bind-mounts its root onto itself, on top of our image: take off every layer, or one umount
    # leaves the image mounted underneath (and docker would come back up on a deleted image). The image is
    # deleted only once docker stopped and no mount anywhere in this namespace comes from its loop device.
    if ! act systemctl stop docker.socket docker.service >/dev/null 2>&1 || ! unmount_all /var/lib/docker \
       || { [ "$DRY" != 1 ] && img_still_mounted "$DOCKER_IMG"; }; then
      FAILED+=("could not stop docker / unmount the docker data image everywhere: image kept")
    else
      detach_loops "$DOCKER_IMG"
      rm_file "$DOCKER_IMG" "docker data image ($N_IMAGES image(s), build cache; the box's pre-provision docker data is restored below)" && DISK_REMOVED=1
    fi
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
  for mp in "$RR_STAGE" ${RR:+"$RR"}; do mounted_from "$mp" "$RR_IMG" && unmount_all "$mp"; done
  if [ "$DRY" != 1 ] && { mounted_from "$RR_STAGE" "$RR_IMG" || { [ -n "$RR" ] && mounted_from "$RR" "$RR_IMG"; }; }; then
    FAILED+=("could not unmount the ~$RD_USER/rr volume: image kept")
  else
    detach_loops "$RR_IMG"
    rm_file "$RR_IMG" "~$RD_USER/rr XFS volume image"
  fi
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
# The way back in (sshd listener/port, ufw, our client keys) goes only in a run that finishes everything else:
# an incomplete run (RERUN) must leave the re-run able to log in exactly as this one did.
SSHD_CHANGED=0
if [ "$RERUN" = 1 ]; then
  kept "sshd config, ufw rules and our client keys: kept until a re-run finishes the rest (it must still get in)"
else
  for f in /etc/ssh/sshd_config.d/10-rdocker.conf /etc/ssh/sshd_config.d/05-rdocker-hardening.conf \
           /etc/ssh/sshd_config.d/05-rdocker-hardening.conf.rdbak; do
    [ -e "$f" ] && SSHD_CHANGED=1; rm_file "$f" "sshd config"
  done
fi
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
    [ -e "$bak" ] || { FAILED+=("$p: recorded as the box's own but its saved copy $bak is missing - not restored"); return 1; }
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
  # reload, never restart: sshd re-execs on SIGHUP (new listeners, new config) and every open session lives on
  if sshd -t 2>/dev/null || /usr/sbin/sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
      || kept "sshd not reloaded (not running?): the restored config applies at its next start"
  else FAILED+=("sshd -t rejects the box's own sshd config: ssh NOT reloaded (fix it, then: sudo systemctl reload ssh)"); fi
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
  grep -q '^PRIOR_UFW_RULES=' "$PRIOR" 2>/dev/null || { kept "ufw rules (the record has no snapshot of the box's own rules)"; return 0; }
  for r in "${rules[@]}"; do
    grep -qxF "ufw $r" <<< "$PRIOR_UFW_RULES" && continue      # the box had this rule itself
    # shellcheck disable=SC2086  # word-split on purpose: a ufw rule
    ufw show added 2>/dev/null | grep -qxF "ufw $r" && act ufw delete $r >/dev/null && gone "ufw rule: $r"
  done
}
ufw_defaults() { (. /etc/default/ufw 2>/dev/null && for v in "${DEFAULT_INPUT_POLICY:-}" "${DEFAULT_OUTPUT_POLICY:-}"; do
  case "$v" in DROP) echo deny ;; ACCEPT) echo allow ;; REJECT) echo reject ;; esac; done | xargs); }
if [ "$RERUN" = 1 ] || ! command -v ufw >/dev/null 2>&1; then :
elif [ "$HAVE_PRIOR" = 1 ]; then
  if [ "$PRIOR_UFW_ACTIVE" = 0 ] && ufw status 2>/dev/null | grep -q '^Status: active'; then
    act ufw --force disable >/dev/null && gone "ufw firewall (was off before provision)"
  fi
  drop_ufw_rules    # either way (when ufw was already on, the box had its own way in)
  if [ -n "$PRIOR_UFW_DEFAULTS" ] && [ "$(ufw_defaults)" != "$PRIOR_UFW_DEFAULTS" ]; then   # rd-harden: deny in / allow out
    read -r din dout <<< "$PRIOR_UFW_DEFAULTS"
    act ufw default "$din" incoming >/dev/null && act ufw default "$dout" outgoing >/dev/null \
      && gone "ufw default policies (back to $din incoming, $dout outgoing)"
  fi
elif ufw status 2>/dev/null | grep -q '^Status: active'; then
  kept "ufw on with rdocker's rules (no record whether ufw was on before; undo: sudo ufw --force disable)"
fi
# rd-docker-user's exact rule set (rd-docker-user.sh), removed only when all of it is there - never a flush
DU_RULES=("-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" "-i lo -j RETURN" "-i tailscale0 -j RETURN"
          "-i docker+ -j RETURN" "-i br-+ -j RETURN" "-j DROP")
if command -v iptables >/dev/null 2>&1 && quiet iptables -S DOCKER-USER; then
  all=1; for r in "${DU_RULES[@]}"; do
    # shellcheck disable=SC2086  # word-split on purpose: an iptables rule
    quiet iptables -C DOCKER-USER $r || all=0; done
  if [ "$all" = 1 ]; then
    # shellcheck disable=SC2086
    for r in "${DU_RULES[@]}"; do act iptables -D DOCKER-USER $r; done
    gone "DOCKER-USER firewall rules of rd-docker-user"
  fi
  # the box's own rules, which rd-docker-user's rebuild had dropped (live until the box's own tooling rewrites them)
  if [ "$HAVE_PRIOR" = 1 ] && [ -n "$PRIOR_DOCKER_USER" ]; then
    while read -r _a _chain rule; do
      [ "$_a" = -A ] && [ "$_chain" = DOCKER-USER ] && [ -n "$rule" ] || continue
      # shellcheck disable=SC2086  # word-split on purpose: an iptables rule
      quiet iptables -C DOCKER-USER $rule || { act iptables -A DOCKER-USER $rule && gone "DOCKER-USER rule of the box put back: $rule"; }
    done <<< "$PRIOR_DOCKER_USER"
  fi
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
    # the user was there before (or no record says otherwise): only the files we put there leave its home.
    # The reporter first: stop it, so it cannot keep reporting after the box left the fleet.
    if [ -e "$RD_HOME/.config/systemd/user/rd-reporter.service" ]; then
      if [ "$DRY" = 1 ]; then echo "+ stop and disable $RD_USER's rd-reporter user unit"
      else
        quiet runuser -u "$RD_USER" -- env XDG_RUNTIME_DIR="/run/user/$RD_UID" systemctl --user disable --now rd-reporter.service
        quiet pkill -u "$RD_UID" -f '/rdocker/reporter/rd-reporter\.mjs'
        ! pgrep -u "$RD_UID" -f '/rdocker/reporter/rd-reporter\.mjs' >/dev/null || FAILED+=("$RD_USER's rd-reporter is still running")
      fi
    fi
    for p in .config/systemd/user/rd-reporter.service .config/systemd/user/rd-reporter.service.d \
             .config/systemd/user/default.target.wants/rd-reporter.service .local/share/rdocker \
             .local/share/rdocker-reporter .config/rdocker; do
      [ -e "$RD_HOME/$p" ] || [ -L "$RD_HOME/$p" ] || continue
      act rm -rf "${RD_HOME:?}/$p" && gone "~$RD_USER/$p"
    done
    # ~/rr: only the empty mountpoint of our XFS volume goes; a ~/rr with data stays (provision never moved one)
    if [ -n "$RR" ] && [ -d "$RR" ] && ! mountpoint -q "$RR" 2>/dev/null; then
      if [ -z "$(ls -A "$RR" 2>/dev/null)" ]; then act rmdir "$RR" && gone "~$RD_USER/rr (the empty volume mountpoint)"
      else kept "$RR (holds data: remove it by hand once unneeded)"; fi
    fi
    if grep -qs 'rdocker: mise' "$RD_HOME/.bashrc"; then
      if [ "$DRY" = 1 ]; then echo "+ remove rdocker's mise PATH lines from ~$RD_USER/.bashrc"
      else sed -i '/^# rdocker: mise (node for non-interactive ssh too)$/{N;d;}' "$RD_HOME/.bashrc"; fi
      gone "rdocker's PATH lines in ~$RD_USER/.bashrc"
    fi
    [ "$HAVE_PRIOR" = 1 ] && [ "$PRIOR_LINGER" = 0 ] && [ -e "/var/lib/systemd/linger/$RD_USER" ] && act loginctl disable-linger "$RD_USER"
    if [ "$HAVE_PRIOR" = 1 ]; then kept "user $RD_USER (it existed before provision) and its mise install (~/.local/bin/mise, ~/.local/share/mise)"
    else kept "user $RD_USER (no record that provision created it; if it did: sudo userdel -r $RD_USER)"; fi
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
    # rewritten AS that user (never root through a path the user controls); cat >: keeps the file's inode and mode
    runuser -u "$u" -- sh -c 'f=$1; t=$(mktemp "$f.XXXXXX") || exit 1
      awk -v bl="$2" "{ for (i = 1; i <= NF; i++) if (\$i ~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)/ && index(bl, \" \" \$(i+1) \" \")) next; print }" "$f" > "$t" \
        && cat "$t" > "$f"; rc=$?; rm -f "$t"; exit $rc' _ "$ak" " $* " \
      || { FAILED+=("removing our client keys from $ak"); return 1; }
  fi
  gone "$n rdocker client key(s) from $u's authorized_keys"
}
if [ "$RERUN" = 1 ]; then :      # kept for the re-run (see step 6)
elif [ -f "$STATE_DIR/added-keys" ]; then
  for u in $(awk '{print $1}' "$STATE_DIR/added-keys" | sort -u); do
    [ "$u" = "$RD_USER" ] && [ "$USER_OURS" = 1 ] && continue
    # shellcheck disable=SC2046
    drop_keys "$u" $(awk -v u="$u" '$1 == u {print $2}' "$STATE_DIR/added-keys")
  done
# --keys only on a box with no record at all: the ledger names exactly the keys provision added
elif [ "$HAVE_PRIOR" != 1 ] && [ -n "$KEYS" ] && [ "$ADMIN_USER" != "$RD_USER" ]; then
  # shellcheck disable=SC2046
  drop_keys "$ADMIN_USER" $(awk '/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)/ {print $2}' "$KEYS")
fi

# --- 12. packages (--purge-packages only) ------------------------------------------------------------------------
say "step packages"
DOCKER_PURGED=0
if [ "$PURGE" = 1 ]; then
  if [ "$HAVE_PRIOR" = 1 ] && [ ! -s "$STATE_DIR/prior/packages" ]; then
    kept "packages: the record has no package list, none purged"
  elif [ "$HAVE_PRIOR" != 1 ]; then
    kept "packages: no record of which ones the box had before provision, none purged (by hand: sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)"
  else
    P=""
    for p in $PURGEABLE; do has "$p" "$PRIOR_PKGS_MISSING" && pkg_installed "$p" && P="$P $p"; done
    if has docker-ce "$P" && { [ "$INVENTORY_OK" != 1 ] || [ "$FOREIGN" -gt 0 ] || [ -f "$DOCKER_IMG" ]; }; then
      # docker stays unless the inventory proved it holds nothing of the box's (and our disk is gone)
      # shellcheck disable=SC2086
      P=$(printf '%s\n' $P | grep -vE '^(docker-.*|containerd\.io)$' | xargs)
      kept "docker packages: docker still holds (or could not be checked for) data that is not ours"
    fi
    # docker-ce's recommends that apt installed with it (not ones the box had before) leave with it
    has docker-ce "$P" && pkg_installed docker-ce-rootless-extras && [ -s "$STATE_DIR/prior/packages" ] \
      && ! grep -qx docker-ce-rootless-extras "$STATE_DIR/prior/packages" && P="$P docker-ce-rootless-extras"
    autoremovable() { apt-get -s autoremove 2>/dev/null | awk '/^Remv / {print $2}' | sed 's/:.*//' | sort -u; }
    safe_purge() {   # safe_purge WHAT PKG...: purge only when apt's own plan removes nothing the box had before
      local what=$1 plan bad; shift
      [ "$DRY" = 1 ] && { echo "+ apt-get purge $* (after checking apt's plan removes nothing the box had)" >&3; gone "$what: $*"; return 0; }
      plan=$(apt-get -s purge "$@" 2>/dev/null) || { FAILED+=("apt-get -s purge $* failed: nothing purged"); return 1; }
      bad=$(awk '/^(Purg|Remv) / {print $2}' <<< "$plan" | sed 's/:.*//' | sort -u | comm -12 - "$STATE_DIR/prior/packages" | xargs)
      [ -z "$bad" ] || { FAILED+=("apt would also remove packages the box had before ($bad): nothing purged"); return 1; }
      env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$@" >/dev/null || { FAILED+=("apt-get purge $*"); return 1; }
      gone "$what: $*"
    }
    ORPHANS_BEFORE=$(autoremovable)   # orphans the box already had: never ours to take
    if [ -n "${P# }" ]; then
      # shellcheck disable=SC2086
      safe_purge packages $P
      has docker-ce "$P" && { [ "$DRY" = 1 ] || ! pkg_installed docker-ce; } && DOCKER_PURGED=1
      # the dependencies our purge left orphaned, minus orphans from before and anything the box had before
      if [ -s "$STATE_DIR/prior/packages" ] && [ "$DRY" != 1 ]; then
        DEPS=$(autoremovable | comm -23 - <(printf '%s\n' "$ORPHANS_BEFORE" | sort -u) \
               | comm -23 - "$STATE_DIR/prior/packages" | xargs)
        # shellcheck disable=SC2086
        [ -n "$DEPS" ] && safe_purge "dependency packages apt installed for them" $DEPS
      elif [ "$DRY" = 1 ]; then echo "+ apt-get purge the dependencies apt installed for them (not ones the box had before)"; fi
      # a purge also deletes config the box had (unattended-upgrades' postrm removes 20auto-upgrades): put it back
      restore_shared /etc/apt/apt.conf.d/20auto-upgrades "automatic apt updates"
      # installing chrony replaced the box's own time daemon: put that back
      for p in $PRIOR_PKGS_PRESENT; do
        pkg_installed "$p" || { act env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p" >/dev/null && gone "chrony's replacement of $p (reinstalled)"; }
      done
    fi
    # docker that provision installed and that is gone now (this run's purge, or an earlier one): its leftovers go
    [ "$DOCKER_PURGED" = 1 ] && [ "$DRY" != 1 ] && : > "$STATE_DIR/docker-purged"   # a re-run may finish the cleanup
    if { [ "$DOCKER_PURGED" = 1 ] || [ -f "$STATE_DIR/docker-purged" ]; } && [ ! -f "$DOCKER_IMG" ] \
       && ! mounted_from /var/lib/docker "$DOCKER_IMG"; then
      for f in /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc; do prior_file "$f" || rm_file "$f" "docker apt repo"; done
      # runtime data: docker's only when the box had none before; containerd's only when we installed containerd
      if [ "$PRIOR_DOCKER_DATA" = 0 ] && [ ! -d /var/lib/docker.pre-rdocker ] && [ -d /var/lib/docker ]; then
        # dockerd bind-mounts its root onto itself; that bind outlives the purged daemon (never our image here:
        # step 3 removed that, and kept docker installed while it stayed)
        if mountpoint -q /var/lib/docker && ! mounted_from /var/lib/docker "$DOCKER_IMG" \
           && [ "$(findmnt -no SOURCE /var/lib/docker | head -1 | sed 's/.*\[\(.*\)\]$/\1/')" = /var/lib/docker ]; then
          unmount_all /var/lib/docker || FAILED+=("umount /var/lib/docker (docker's own bind of its root)")
        fi
        act rm -rf /var/lib/docker && gone "/var/lib/docker (docker installed by provision, purged)"
      fi
      if has containerd.io "$P" && ! pkg_installed containerd.io && [ -d /var/lib/containerd ]; then
        act rm -rf /var/lib/containerd && gone "/var/lib/containerd (containerd installed by provision, purged)"
      fi
      rmdir_empty /etc/docker
      for d in /opt/containerd/bin /opt/containerd/lib /opt/containerd; do rmdir_empty "$d"; done
      kept "docker's runtime firewall chains and the docker0 bridge: gone at the next reboot"
      if [ "$PRIOR_DOCKER_GROUP" = no ] && getent group docker >/dev/null && [ -z "$(getent group docker | cut -d: -f4)" ]; then act groupdel docker && gone "group docker"; fi
    fi
    kept "base tools provision may have installed (curl, git, rsync, perl, gnupg, libatomic1, ...): never purged; system users packages made (e.g. _chrony) stay, as Debian does"
  fi
else
  kept "packages (docker-ce & co, chrony, build-essential, ufw, ...): kept - re-run with --purge-packages to remove the ones provision installed"
fi
# a kept docker comes back up on its own config (and, when the image went, a fresh /var/lib/docker)
if [ "$DOCKER_PURGED" != 1 ] && command -v docker >/dev/null 2>&1 \
   && [ $((DOCKER_CH + DISK_REMOVED + DOCKER_UNITS_CH)) -gt 0 ]; then
  if [ "$FOREIGN" -gt 0 ] || [ "$INVENTORY_OK" != 1 ]; then   # a restart stops every container without a restart policy: theirs to do
    kept "docker NOT restarted (it may run containers that are not ours): the restored config applies after: sudo systemctl restart docker"
  else
    act systemctl restart docker.socket docker.service >/dev/null 2>&1
  fi
fi

# --- 13. our state ----------------------------------------------------------------------------------------------
say "step state"
for p in /run/rdocker /run/rdocker-tune /run/rdocker-doctor /run/rdocker-netcheck.count /run/rd-rrfs.lock; do
  [ -e "$p" ] && act rm -rf "$p"
done
if [ -d "$STATE_DIR" ]; then
  if [ "$DRY" != 1 ] && { [ "${#FAILED[@]}" -gt 0 ] || [ "$RERUN" = 1 ]; }; then
    kept "$STATE_DIR (the prior-state record): kept so a re-run can still put things back"
  elif [ "$HAVE_PRIOR" = 1 ] && [ "$PURGE" != 1 ] && ours_installed; then
    # packages provision installed are still here: keep only the record a later --purge-packages needs
    for f in "$STATE_DIR"/*; do case "$f" in "$PRIOR"|"$STATE_DIR/prior") ;; *) act rm -rf "$f" ;; esac; done
    kept "$PRIOR and $STATE_DIR/prior (root-only): the record a later run with --purge-packages needs; delete $STATE_DIR if you will not"
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
if [ "$RERUN" = 1 ] && [ "$DRY" != 1 ]; then echo "RDUNPROV incomplete: re-run once the kept items above are dealt with"; exit 3; fi
echo "RDUNPROV ok"
