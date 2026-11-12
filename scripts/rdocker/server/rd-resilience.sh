#!/bin/bash
# rd-resilience: make a worker/home box come back fully online with zero human work after a power loss,
# crash, reboot or network drop. Idempotent; called by provision-linux.sh (as root), also runnable alone.
#   rd-resilience.sh [--user rd] [--home] [--wsl 0|1] [--distro ubuntu|debian|linuxmint] [--codename X]
#                    [--src DIR] [--root DIR]
# --root DIR = test mode: every file lands under DIR, systemctl calls are only logged to DIR/systemctl.log,
# and nothing else touches the machine (no apt, tailscale, loginctl). Test hook: RD_DMI_PRODUCT.
set -euo pipefail
RD_USER=rd IS_WSL=0 IS_HOME=0 DISTRO=ubuntu CODENAME=noble R="" SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --user) RD_USER=${2:?}; shift 2 ;;
    --home) IS_HOME=1; shift ;;     # home also keeps the dashboard archive (rd-archive.timer)
    --wsl) IS_WSL=${2:?}; shift 2 ;;
    --distro) DISTRO=${2:?}; shift 2 ;;
    --codename) CODENAME=${2:?}; shift 2 ;;
    --src) SRC=${2:?}; shift 2 ;;
    --root) R=${2:?}; shift 2 ;;
    *) echo "rd-resilience: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -z "$R" ] || mkdir -p "$R"
say() { echo "RDPROV resilience $*"; }
sc() { if [ -n "$R" ]; then echo "systemctl $*" >> "$R/systemctl.log"; else systemctl "$@"; fi; }
put() {   # put DEST MODE < content (only when different)
  local dest="$R$1" tmp; tmp=$(mktemp); cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
  mkdir -p "$(dirname "$dest")"; install -m "$2" "$tmp" "$dest"; rm -f "$tmp"
}
restart_dropin() {   # $1 = system unit name: always restart, no start-limit give-up
  put "/etc/systemd/system/$1.service.d/10-rdocker-restart.conf" 644 <<'CONF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=5
CONF
}

# 1. never sleep -------------------------------------------------------------------------------------------
sc mask sleep.target suspend.target hibernate.target hybrid-sleep.target
put /etc/systemd/logind.conf.d/50-rdocker.conf 644 <<'CONF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
CONF

# 2. services: enabled at boot, restarted forever -------------------------------------------------------------
for u in ssh tailscaled docker chrony; do restart_dropin "$u"; done
put /usr/local/bin/rd-netcheck 755 < "$SRC/rd-netcheck.sh"
put /etc/systemd/system/rd-netcheck.service 644 < "$SRC/rd-netcheck.service"
put /etc/systemd/system/rd-netcheck.timer 644 < "$SRC/rd-netcheck.timer"
# rd-doctor: self-healing rules every 30 s (orphan slots/containers, hung jobs, reporter, drain; see the script).
# Kill switch: DOCTOR_DISABLE=1 in /etc/rdocker/doctor.conf (owner-written, never put here).
put /usr/local/bin/rd-doctor 755 < "$SRC/rd-doctor.sh"
put /etc/systemd/system/rd-doctor.service 644 < "$SRC/rd-doctor.service"
put /etc/systemd/system/rd-doctor.timer 644 < "$SRC/rd-doctor.timer"
if [ "$IS_WSL" != 1 ]; then   # power bar: root averages RAPL for the reporter (WSL has no RAPL)
  put /usr/local/bin/rd-power 755 < "$SRC/rd-power.sh"
  put /etc/systemd/system/rd-power.service 644 < "$SRC/rd-power.service"
fi
[ -n "$R" ] || systemctl daemon-reload
sc enable ssh tailscaled docker chrony rd-tune.timer rd-netcheck.timer
sc start rd-netcheck.timer
sc enable rd-doctor.timer
sc start rd-doctor.timer
if [ "$IS_WSL" != 1 ]; then sc enable rd-power.service; [ -n "$R" ] || systemctl restart rd-power.service || true; fi
if [ "$IS_HOME" = 1 ]; then   # the dashboard's data, archived daily onto the home disk and kept forever
  put /usr/local/bin/rd-archive 755 < "$SRC/rd-archive.sh"
  put /etc/systemd/system/rd-archive.service 644 < "$SRC/rd-archive.service"
  put /etc/systemd/system/rd-archive.timer 644 < "$SRC/rd-archive.timer"
  [ -n "$R" ] || systemctl daemon-reload
  sc enable rd-archive.timer
  sc start rd-archive.timer
fi
if [ -f "$SRC/reporter/units/rd-reporter.service" ]; then    # user unit (lane C): boot via linger, never gives up
  UDIR="${R}/home/$RD_USER/.config/systemd/user"
  [ -n "$R" ] || UDIR="$(getent passwd "$RD_USER" | cut -d: -f6)/.config/systemd/user"
  mkdir -p "$UDIR/rd-reporter.service.d"
  install -m 644 "$SRC/reporter/units/rd-reporter.service" "$UDIR/rd-reporter.service"
  RDIR="${UDIR%/.config/systemd/user}/.local/share/rdocker/reporter"   # the unit's ExecStart target
  mkdir -p "$RDIR" && install -m 644 "$SRC/reporter/rd-reporter.mjs" "$RDIR/rd-reporter.mjs"
  [ -n "$R" ] || chown -R "$RD_USER": "${UDIR%/.config/systemd/user}/.local/share/rdocker" 2>/dev/null || true
  printf '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestart=always\nRestartSec=5\n' > "$UDIR/rd-reporter.service.d/10-rdocker-restart.conf"
  if [ -z "$R" ]; then
    chown -R "$RD_USER": "$(dirname "$UDIR")/.." 2>/dev/null || true
    loginctl enable-linger "$RD_USER"
    runuser -u "$RD_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$RD_USER")" systemctl --user enable rd-reporter.service || true
  else echo "systemctl --user enable rd-reporter.service" >> "$R/systemctl.log"; fi
  # `systemctl --user enable` fails silently when the user manager linger just started is not up yet (seen on
  # mini-a 2026-11-10: reporter ran but never came back after a reboot). Enable offline too: the wants symlink is
  # all `enable` writes, and it needs no running manager.
  mkdir -p "$UDIR/default.target.wants"
  ln -sfn ../rd-reporter.service "$UDIR/default.target.wants/rd-reporter.service"
  [ -n "$R" ] || chown -h "$RD_USER": "$UDIR/default.target.wants" "$UDIR/default.target.wants/rd-reporter.service" 2>/dev/null || true
else
  say "note reporter units not shipped yet: reporter boot-enable skipped"
fi

# 3-5. hardware recovery (not on WSL: the Windows host owns the hardware) ------------------------------------------
if [ "$IS_WSL" != 1 ]; then
  put /etc/systemd/system.conf.d/50-rdocker-watchdog.conf 644 <<'CONF'
[Manager]
RuntimeWatchdogSec=30s
RebootWatchdogSec=2min
CONF
  put /etc/sysctl.d/91-rdocker-panic.conf 644 <<'CONF'
kernel.panic = 10
kernel.panic_on_oops = 1
CONF
  [ -n "$R" ] || sysctl -q --system >/dev/null 2>&1 || true
  PRODUCT="${RD_DMI_PRODUCT:-$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)}"
  case "$PRODUCT" in
    Macmini5,*|Macmini6,*)   # 2011/2012 Mac mini: clear the southbridge AFTERG3 "stay off after power loss" bit (GEN_PMCON_3 bit 0) at every boot
      [ -n "$R" ] || { command -v setpci >/dev/null 2>&1 || apt-get install -y -qq pciutils; }
      put /etc/systemd/system/rd-ac-poweron.service 644 <<'CONF'
[Unit]
Description=Power on automatically after AC loss (Mac mini 2011/2012)

[Service]
Type=oneshot
ExecStart=/usr/bin/setpci -s 00:1f.0 0xa4.b=0:1

[Install]
WantedBy=multi-user.target
CONF
      sc enable rd-ac-poweron.service
      [ -n "$R" ] || systemctl start rd-ac-poweron.service || true
      say "ac-poweron unit installed ($PRODUCT)" ;;
    *) say "note set the BIOS option 'After Power Loss = On' by hand ($PRODUCT; HP ProDesk: F10 -> Advanced -> Power-On Options -> After Power Loss)" ;;
  esac
fi

# 6. Tailscale updates itself ---------------------------------------------------------------------------------------------
if [ -z "$R" ]; then
  if command -v tailscale >/dev/null 2>&1; then tailscale set --auto-update || say "note tailscale set --auto-update failed"
  else say "note tailscale not installed yet: run 'sudo tailscale up' then 'sudo tailscale set --auto-update'"; fi
fi

# 7. unattended security updates, reboot 04:30 (not on WSL) ---------------------------------------------------------------
if [ "$IS_WSL" != 1 ]; then
  [ -n "$R" ] || apt-get install -y -qq unattended-upgrades
  case "$DISTRO" in
    debian) ORIGINS="\"origin=Debian,codename=${CODENAME}-security,label=Debian-Security\";" ;;
    *) ORIGINS="\"Ubuntu:${CODENAME}-security\"; \"UbuntuESMApps:${CODENAME}-apps-security\"; \"UbuntuESM:${CODENAME}-infra-security\";" ;;
  esac
  put /etc/apt/apt.conf.d/52rdocker-unattended 644 <<CONF
// rdocker: security updates only, automatic reboot at 04:30 local
#clear Unattended-Upgrade::Allowed-Origins;
Unattended-Upgrade::Allowed-Origins { $ORIGINS };
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
CONF
  put /etc/apt/apt.conf.d/20auto-upgrades 644 <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
fi
say finished
