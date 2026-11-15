#!/bin/sh
# <xbar.title>rdocker share</xbar.title>
# <xbar.desc>How much of this Mac the team pool may use: Off / Low / Medium / High, or a custom CPU % and RAM cap.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# SwiftBar / xbar menu-bar plugin, refreshed every minute and right after each click. It only wraps
# rdocker-share (found as $RDOCKER_SHARE_CMD, next to this plugin, in /usr/local/bin or /opt/homebrew/bin):
# `rdocker-share info` for what to show, `rdocker-share <level>` / `cpu N` / `ram N` / `stop` for the clicks.
# Title: "⚙ 75% · 4G" (CPU share · RAM cap), "· 2▶" with jobs running here, "⏸" while the memory guard
# holds new jobs back, "⚙ off" when sharing is off.
here=$(cd "$(dirname "$0")" && pwd)
cmd=${RDOCKER_SHARE_CMD:-}
for c in "$here/rdocker-share.sh" /usr/local/bin/rdocker-share /opt/homebrew/bin/rdocker-share; do
  [ -z "$cmd" ] && [ -x "$c" ] && cmd=$c
done
if [ -z "$cmd" ]; then
  echo "⚙ ? | sfimage=exclamationmark.triangle"; echo "---"; echo "rdocker-share not installed"; exit 0
fi
info=$("$cmd" info 2>/dev/null)
v() { printf '%s\n' "$info" | sed -n "s/^$1=//p" | head -1; }
lvl=$(v level) cpu=$(v cpu) ram=$(v ram_gb) cores=$(v cores) ncpu=$(v ncpu) jobs=$(v jobs) guard=$(v guard)
[ -n "$lvl" ] || { echo "⚙ ? | sfimage=exclamationmark.triangle"; echo "---"; echo "rdocker-share info failed"; exit 0; }

# ---- title
if [ "$lvl" = off ]; then
  t="⚙ off"; col="#8a8a8a"
else
  t="⚙ ${cpu}%"; [ -n "$ram" ] && t="$t · ${ram}G"
  col="#36D399"
fi
case $jobs in ''|'?'|0) ;; *) t="$t · ${jobs}▶" ;; esac
[ -n "$guard" ] && { t="$t ⏸"; col="#F5A623"; }
echo "$t | color=$col"
echo "---"

# ---- what it is now
name() { case $1 in off) echo Off ;; low) echo Low ;; medium) echo Medium ;; high) echo High ;; custom) echo Custom ;; *) echo "Max (no switch file)" ;; esac; }
if [ "$lvl" = off ]; then
  echo "Sharing is OFF: no new jobs start here | color=gray"
else
  rt="no RAM cap"; [ -n "$ram" ] && rt="up to $ram GB"
  echo "Sharing: $(name "$lvl") - $cores of $ncpu cores ($cpu %), $rt | color=#36D399"
fi
case $jobs in
  '?') ;;
  *) echo "Team jobs running here now: $jobs | color=gray" ;;
esac
case $guard in
  pressure) echo "Paused for memory: macOS memory pressure is up; no new job starts until it is normal | color=#F5A623" ;;
  memory) echo "Paused for memory: free memory is low; no new job starts until your apps free some | color=#F5A623" ;;
esac
echo "---"

# ---- presets: one click each
item() {   # label, then the rdocker-share arguments; checked when $3 says so
  printf '%s | bash="%s" param1=%s' "$1" "$cmd" "$2"
  [ -n "${4:-}" ] && printf ' param2=%s' "$4"
  printf ' terminal=false refresh=true'
  [ "${3:-}" = 1 ] && printf ' checked=true'
  printf '\n'
}
item "Off - no new jobs (running ones finish)" off "$([ "$lvl" = off ] && echo 1)"
for p in low medium high; do
  # shellcheck disable=SC2046  # two words on purpose
  set -- $(v "p_$p")          # "<cpu %> <ram GB>"
  pc=${1:-?} pr=${2:-}
  label="$(name "$p") - $pc % CPU"; [ "$pc" = 100 ] && label="$(name "$p") - all CPU"
  [ -n "$pr" ] && label="$label, up to $pr GB"
  item "$label" "$p" "$([ "$lvl" = "$p" ] && echo 1)"
done

# ---- custom: CPU and RAM picked independently (each keeps the other's current value)
ct="Custom"; [ "$lvl" = custom ] && ct="Custom ($cpu % · ${ram:-no cap}${ram:+ GB})"
if [ "$lvl" = custom ]; then echo "$ct | checked=true"; else echo "$ct"; fi
on=""; [ "$lvl" != off ] && on=1
for c in 25 50 75 100; do
  item "--CPU $c %" cpu "$([ -n "$on" ] && [ "$cpu" = "$c" ] && echo 1)" "$c"
done
echo "-----"
for r in 2 4 6 8; do
  item "--RAM cap $r GB" ram "$([ -n "$on" ] && [ "$ram" = "$r" ] && echo 1)" "$r"
done
echo "---"
item "Off now (stop jobs)" stop
echo "---"
echo "Running jobs finish unless you pick Off now. | size=11 color=gray"
echo "New jobs start only while this Mac has memory to spare. | size=11 color=gray"
echo "Open fleet dashboard | href=https://spine-fleet.zomid777.workers.dev"
