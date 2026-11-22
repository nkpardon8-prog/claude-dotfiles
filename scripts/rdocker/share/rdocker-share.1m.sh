#!/bin/sh
# <xbar.title>rdocker share</xbar.title>
# <xbar.desc>How much of this Mac the team pool may use: Off / Low / Medium / High, or your own CPU and RAM limits.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# SwiftBar / xbar menu-bar plugin, refreshed every minute and right after each click. It only wraps
# rdocker-share (found as $RDOCKER_SHARE_CMD, next to this plugin, in /usr/local/bin or /opt/homebrew/bin):
# `rdocker-share info` (one call) for what to show; `rdocker-share <level>` / `cpu N` / `ram N` / `stop` for
# the clicks. One flat menu: the four presets, then a "CPU" and a "RAM" submenu whose titles show the current
# value; picking a value there makes the setting custom and keeps the other value. The ticks always describe
# what is in force (a preset ticks its own CPU and RAM values too); nothing is ticked while sharing is off.
# Title: "⚙ 75% · 4G" (CPU share · RAM cap), "· 2▶" with jobs running here, "⏸" while the memory guard
# holds new jobs back, "⚙ off" when sharing is off.
here=$(cd "$(dirname "$0")" && pwd)
cmd=${RDOCKER_SHARE_CMD:-}
# RDOCKER_SHARE_PATHS (tests): the install places to look in instead of the two below
for c in "$here/rdocker-share.sh" ${RDOCKER_SHARE_PATHS-/usr/local/bin/rdocker-share /opt/homebrew/bin/rdocker-share}; do
  [ -z "$cmd" ] && [ -x "$c" ] && cmd=$c
done
if [ -z "$cmd" ]; then
  echo "⚙ ? | sfimage=exclamationmark.triangle"; echo "---"; echo "rdocker-share not installed"; exit 0
fi
info=$("$cmd" info 2>/dev/null)
v() { printf '%s\n' "$info" | sed -n "s/^$1=//p" | head -1; }
lvl=$(v level) cpu=$(v cpu) ram=$(v ram_gb) cores=$(v cores) ncpu=$(v ncpu) mem=$(v mem_gb) jobs=$(v jobs) guard=$(v guard)
[ -n "$lvl" ] || { echo "⚙ ? | sfimage=exclamationmark.triangle"; echo "---"; echo "rdocker-share info failed"; exit 0; }
on=""; [ "$lvl" != off ] && on=1

# cores for a CPU percent (the switch's own rule: floor, at least 1)
cores_of() { case $ncpu in ''|*[!0-9]*) echo "?" ;; *) n=$((ncpu * $1 / 100)); [ "$n" -lt 1 ] && n=1; echo "$n" ;; esac; }

# ---- title
if [ -z "$on" ]; then
  t="⚙ off"; col="#8a8a8a"
else
  t="⚙ ${cpu}%"; [ -n "$ram" ] && t="$t · ${ram}G"
  col="#36D399"
fi
case $jobs in ''|'?'|0) ;; *) t="$t · ${jobs}▶" ;; esac
[ -n "$guard" ] && { t="$t ⏸"; col="#F5A623"; }
echo "$t | color=$col"
echo "---"

# ---- what is in force now
name() { case $1 in off) echo Off ;; low) echo Low ;; medium) echo Medium ;; high) echo High ;; custom) echo Custom ;; *) echo "Max (no switch file)" ;; esac; }
if [ -z "$on" ]; then
  echo "Sharing is OFF: no new jobs start here | color=gray"
else
  rt="no RAM cap"; [ -n "$ram" ] && rt="up to $ram GB"
  echo "Sharing: $(name "$lvl") - $cores of $ncpu cores ($cpu %), $rt | color=#36D399"
fi
case $jobs in
  ''|'?') ;;
  *) echo "Team jobs running here now: $jobs | color=gray" ;;
esac
case $guard in
  pressure) echo "Paused for memory: macOS memory pressure is up; no new job starts until it is normal | color=#F5A623" ;;
  memory) echo "Paused for memory: free memory is low; no new job starts until your apps free some | color=#F5A623" ;;
esac
echo "---"

# ---- one click each
item() {   # label, the rdocker-share arguments (1 or 2), ticked when $3 = 1
  printf '%s | bash="%s" param1=%s' "$1" "$cmd" "$2"
  [ -n "${4:-}" ] && printf ' param2=%s' "$4"
  printf ' terminal=false refresh=true'
  [ "${3:-}" = 1 ] && printf ' checked=true'
  printf '\n'
}
tick() { [ "$1" = "$2" ] && echo 1; }

item "Off - no new jobs (running ones finish)" off "$(tick "$lvl" off)"
for p in low medium high; do
  # shellcheck disable=SC2046  # two words on purpose
  set -- $(v "p_$p")          # "<cpu %> <ram GB>"
  pc=${1:-?} pr=${2:-}
  if [ "$pc" = 100 ]; then label="$(name "$p") - all $ncpu cores"; else label="$(name "$p") - $(cores_of "$pc") cores"; fi
  [ -n "$pr" ] && label="$label, up to $pr GB"
  item "$label" "$p" "$(tick "$lvl" "$p")"
done
echo "---"

# ---- your own limits: CPU and RAM picked independently (each keeps the other's current value)
if [ -n "$on" ]; then echo "CPU: $cpu % ($cores cores)"; else echo "CPU: -"; fi
for c in 25 50 75 100; do
  item "--$c % ($(cores_of "$c") cores)" cpu "$([ -n "$on" ] && tick "$cpu" "$c")" "$c"
done
if [ -z "$on" ]; then echo "RAM: -"; elif [ -n "$ram" ]; then echo "RAM: up to $ram GB"; else echo "RAM: no cap"; fi
rams="2 4 6 8 12 16 24 32 48 64"
for r in $rams; do
  case $mem in ''|*[!0-9]*) [ "$r" -gt 8 ] && continue ;; *) [ "$r" -gt $((mem - 2)) ] && continue ;; esac
  item "--up to $r GB" ram "$([ -n "$on" ] && tick "$ram" "$r")" "$r"
done
echo "---"
item "Stop the jobs running here now" stop
echo "Open fleet dashboard | href=https://spine-fleet.zomid777.workers.dev"
