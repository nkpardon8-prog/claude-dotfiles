#!/bin/bash
# rd-verify [--home]: check this box's self-recovery setup. One line per check: `PASS|FAIL|SKIP <name> <detail>`.
# Needs no root. Exit 1 when any check FAILs. `rdocker add-server` runs it over ssh and prints the table.
# Test hook: RD_VERIFY_ROOT (prefix for /etc files).
set -u
R="${RD_VERIFY_ROOT:-}" IS_HOME=0
[ "${1:-}" = --home ] && IS_HOME=1
WSL=0; grep -qi microsoft /proc/version 2>/dev/null && WSL=1
bad=0
res() { [ "$1" = FAIL ] && bad=1; echo "$1 $2 ${3:-}"; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then res PASS "$name"; else res FAIL "$name"; fi; }
has() { grep -qs "$2" "$R$1"; }

for t in sleep suspend hibernate hybrid-sleep; do
  [ "$(systemctl is-enabled "$t.target" 2>/dev/null)" = masked ] && res PASS "mask-$t" || res FAIL "mask-$t"
done
check logind-ignore-lid-idle bash -c "grep -qs '^HandleLidSwitch=ignore' '$R/etc/systemd/logind.conf.d/50-rdocker.conf' && grep -qs '^IdleAction=ignore' '$R/etc/systemd/logind.conf.d/50-rdocker.conf'"
for u in ssh tailscaled docker chrony; do
  [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] && res PASS "boot-$u" || res FAIL "boot-$u"
  has "/etc/systemd/system/$u.service.d/10-rdocker-restart.conf" "Restart=always" \
    && has "/etc/systemd/system/$u.service.d/10-rdocker-restart.conf" "StartLimitIntervalSec=0" \
    && res PASS "restart-$u" || res FAIL "restart-$u"
done
for t in rd-tune rd-netcheck; do
  [ "$(systemctl is-enabled "$t.timer" 2>/dev/null)" = enabled ] && systemctl is-active --quiet "$t.timer" \
    && res PASS "timer-$t" || res FAIL "timer-$t"
done
if [ "$WSL" = 1 ]; then
  for c in watchdog panic-sysctl ac-power unattended-upgrades; do res SKIP "$c" "WSL: the Windows host owns this"; done
else
  has /etc/systemd/system.conf.d/50-rdocker-watchdog.conf "RuntimeWatchdogSec=30s" \
    && has /etc/systemd/system.conf.d/50-rdocker-watchdog.conf "RebootWatchdogSec=2min" && res PASS watchdog || res FAIL watchdog
  [ "$(sysctl -n kernel.panic 2>/dev/null)" = 10 ] && [ "$(sysctl -n kernel.panic_on_oops 2>/dev/null)" = 1 ] \
    && res PASS panic-sysctl || res FAIL panic-sysctl
  case "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" in
    Macmini5,*|Macmini6,*) [ "$(systemctl is-enabled rd-ac-poweron.service 2>/dev/null)" = enabled ] \
                  && res PASS ac-power "setpci unit" || res FAIL ac-power "rd-ac-poweron.service missing" ;;
    *) res SKIP ac-power "set BIOS 'After Power Loss = On' by hand (HP ProDesk: F10 > Advanced > Power-On Options)" ;;
  esac
  has /etc/apt/apt.conf.d/52rdocker-unattended 'Automatic-Reboot "true"' \
    && has /etc/apt/apt.conf.d/52rdocker-unattended 'Automatic-Reboot-Time "04:30"' \
    && has /etc/apt/apt.conf.d/20auto-upgrades 'Unattended-Upgrade "1"' && res PASS unattended-upgrades || res FAIL unattended-upgrades
fi
if command -v tailscale >/dev/null 2>&1; then
  p=$(tailscale debug prefs 2>/dev/null)
  if [ -z "$p" ]; then res SKIP tailscale-auto-update "cannot read prefs as this user"
  elif echo "$p" | tr -d ' \n' | grep -q '"Apply":true'; then res PASS tailscale-auto-update; else res FAIL tailscale-auto-update; fi
else res FAIL tailscale-auto-update "tailscale not installed"; fi
if [ "$IS_HOME" = 1 ]; then
  has /etc/docker/daemon.json '"live-restore": true' && res PASS docker-live-restore || res FAIL docker-live-restore
else res SKIP docker-live-restore "not the home machine"; fi

# ---- lock-down (rd-harden.sh) ------------------------------------------------------------------------------------
RD_USER=rd; [ -r "$R/etc/rdocker/tune.conf" ] && RD_USER=$(sed -n 's/^RD_USER=//p' "$R/etc/rdocker/tune.conf" | head -1)
SSHD_T=""
if [ -n "${RD_SSHD_T_FILE:-}" ]; then SSHD_T=$(cat "$RD_SSHD_T_FILE"); else SSHD_T=$(sudo -n /usr/sbin/sshd -T 2>/dev/null); fi
if [ -z "$SSHD_T" ]; then
  res FAIL ssh-key-only "cannot run sshd -T (sudoers missing? re-run provisioning)"; res FAIL ssh-allowusers "cannot run sshd -T"
else
  want="passwordauthentication no|kbdinteractiveauthentication no|permitrootlogin no|authenticationmethods publickey|maxauthtries 3|logingracetime 20|x11forwarding no|allowagentforwarding no"
  miss=""
  IFS='|' read -ra wants <<< "$want"
  for kv in "${wants[@]}"; do echo "$SSHD_T" | grep -qix "$kv" || miss="$miss [$kv]"; done
  [ -z "$miss" ] && res PASS ssh-key-only || res FAIL ssh-key-only "missing:$miss"
  echo "$SSHD_T" | grep -qE "^allowusers( .*)? $RD_USER( |$)|^allowusers $RD_USER( |$)" && res PASS ssh-allowusers || res FAIL ssh-allowusers "AllowUsers does not list $RD_USER"
fi
if [ "$WSL" = 1 ]; then res SKIP ufw-active "WSL: Windows Hyper-V firewall"
else
  if [ -n "${RD_UFW_FILE:-}" ]; then U=$(cat "$RD_UFW_FILE"); else U=$(sudo -n /usr/sbin/ufw status verbose 2>/dev/null); fi
  echo "$U" | grep -q "^Status: active" && res PASS ufw-active || res FAIL ufw-active "ufw is not active"
  echo "$U" | grep -q "^Default: deny (incoming), allow (outgoing)" && res PASS ufw-default-deny || res FAIL ufw-default-deny
  echo "$U" | grep -qE "41641/udp +ALLOW IN" && res PASS ufw-tailscale-udp || res FAIL ufw-tailscale-udp
  # no rule may admit anything except via tailscale0 (the udp 41641 rule is the one exception)
  bad_rules=$(echo "$U" | grep -E "ALLOW IN" | grep -v "tailscale0" | grep -v "41641/udp")
  [ -z "$bad_rules" ] && res PASS ufw-only-tailscale || res FAIL ufw-only-tailscale "$(echo "$bad_rules" | head -1)"
fi
[ "$(systemctl is-active rd-docker-user.service 2>/dev/null)" = active ] && res PASS docker-user-chain || res FAIL docker-user-chain
# docker: no tcp listener, socket 0660, group docker = only the service user
if grep -rqs -e '-H *tcp' -e 'tcp://' "$R/etc/docker/daemon.json" "$R/lib/systemd/system/docker.service" "$R/etc/systemd/system/docker.service.d" 2>/dev/null; then
  res FAIL docker-no-tcp "a tcp listener is configured"; else res PASS docker-no-tcp; fi
sock="${RD_DOCKER_SOCK:-/var/run/docker.sock}"
[ "$(stat -c %a "$sock" 2>/dev/null)" = 660 ] && res PASS docker-socket-660 || res FAIL docker-socket-660 "$(stat -c %a "$sock" 2>/dev/null)"
members=$(getent group docker | cut -d: -f4)
[ "$members" = "$RD_USER" ] && res PASS docker-group-only-rd || res FAIL docker-group-only-rd "members: ${members:-none}"
# services nobody asked for
on=""
for u in avahi-daemon cups cups-browsed rpcbind; do
  [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] && on="$on $u"
  systemctl is-active --quiet "$u" 2>/dev/null && on="$on $u"
done
[ -z "$on" ] && res PASS services-off || res FAIL services-off "still on:$on"
# every listener must be loopback or the Tailscale address (tailscaled/chronyd/dhcp sockets are covered by ufw)
TSIP=$(tailscale ip -4 2>/dev/null | head -1)
if [ -n "${RD_SS_FILE:-}" ]; then SS=$(cat "$RD_SS_FILE"); else SS=$(ss -H -tlnup 2>/dev/null); fi
exposed=$(echo "$SS" | awk -v ts="$TSIP" '
  { addr = $5; proc = $0; sub(/:[0-9]+$/, "", addr); gsub(/[\[\]]/, "", addr)
    if (addr ~ /^127\./ || addr == "::1" || addr == "lo" || (ts != "" && addr == ts) || addr ~ /%lo$/ || addr ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ || addr ~ /^fd7a:115c:a1e0:/ || addr ~ /%tailscale0$/) next   # 100.64/10 + fd7a:115c:a1e0::/48 = Tailscale
    if (proc ~ /"(tailscaled|chronyd|dhclient|NetworkManager|systemd-network)"/) next
    if ($1 == "udp" && $5 ~ /:(68|546|41641)$/) next   # DHCPv4/v6 client + WireGuard: process names are hidden without root
    print $1 " " $5 }')
[ -z "$exposed" ] && res PASS no-exposed-listeners || res FAIL no-exposed-listeners "$(echo "$exposed" | head -3 | tr '\n' ';')"
# reporter: 0600, owned by the service user, never listens (outbound only; covered by the listener check)
RS="$(getent passwd "$RD_USER" | cut -d: -f6)/.config/rdocker/reporter.json"; [ -n "${RD_REPORTER_FILE:-}" ] && RS=$RD_REPORTER_FILE
st=$(stat -c '%a %U' "$RS" 2>/dev/null)
[ "$st" = "600 $RD_USER" ] && res PASS reporter-secret-0600 || res FAIL reporter-secret-0600 "${st:-missing}"
# home: the dashboard archive timer (data kept on this disk)
if [ "${IS_HOME:-0}" = 1 ]; then
  [ "$(systemctl is-enabled rd-archive.timer 2>/dev/null)" = enabled ] && res PASS archive-timer || res FAIL archive-timer "rd-archive.timer not enabled"
else res SKIP archive-timer "not the home machine"; fi
# power bar: the sampler runs where RAPL exists (never on WSL)
if [ "$WSL" = 1 ] || [ ! -e /sys/class/powercap/intel-rapl:0/energy_uj ]; then res SKIP power-sampler "no RAPL here"
elif [ "$(systemctl is-active rd-power.service 2>/dev/null)" = active ]; then res PASS power-sampler
else res FAIL power-sampler "rd-power.service not running: dashboard power shows n/a"; fi
# reporter must come back after a reboot: the user unit's wants symlink (what `systemctl --user enable` writes)
RU="$(getent passwd "$RD_USER" | cut -d: -f6)/.config/systemd/user"; [ -n "${RD_REPORTER_UNITS:-}" ] && RU=$RD_REPORTER_UNITS
if [ ! -f "$RU/rd-reporter.service" ]; then res SKIP reporter-boot "reporter not installed"
elif [ -e "$RU/default.target.wants/rd-reporter.service" ]; then res PASS reporter-boot
else res FAIL reporter-boot "rd-reporter not enabled: it will not start after a reboot"; fi
if [ "$WSL" = 1 ]; then res SKIP unattended-timer "WSL"
elif [ "$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null)" = enabled ]; then res PASS unattended-timer; else res FAIL unattended-timer; fi
[ "$bad" = 0 ]
