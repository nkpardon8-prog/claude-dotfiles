#!/bin/sh
# <xbar.title>rdocker share</xbar.title>
# <xbar.desc>One click to lend this Mac's compute to the team pool (Off / Some / Max).</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# SwiftBar / xbar menu-bar plugin, refreshed every minute and right after each click. It only wraps
# rdocker-share (found as $RDOCKER_SHARE_CMD, next to this plugin, in /opt/homebrew/bin or /usr/local/bin).
here=$(cd "$(dirname "$0")" && pwd)
cmd=${RDOCKER_SHARE_CMD:-}
for c in "$here/rdocker-share.sh" /opt/homebrew/bin/rdocker-share /usr/local/bin/rdocker-share; do
  [ -z "$cmd" ] && [ -x "$c" ] && cmd=$c
done
if [ -z "$cmd" ]; then
  echo "rd ? | sfimage=exclamationmark.triangle"; echo "---"; echo "rdocker-share not installed"; exit 0
fi
out=$("$cmd" status 2>/dev/null)
jobs=$(printf '%s\n' "$out" | sed -n 's/^Jobs running now: //p')
case $out in
  *"is OFF"*) lvl=off ;;
  *"is SOME"*) lvl=some ;;
  *) lvl=max ;;
esac
jt=""; [ -n "$jobs" ] && [ "$jobs" != "0" ] && jt=" $jobs"
case $lvl in
  off)  echo "rd off | sfimage=bolt.slash sfcolor=#8a8a8a" ;;
  some) echo "rd$jt | sfimage=bolt.fill sfcolor=#F5C26B" ;;
  max)  echo "rd$jt | sfimage=bolt.fill sfcolor=#36D399" ;;
esac
echo "---"
case $lvl in
  off) echo "Sharing is OFF | color=gray" ;;
  some) echo "Sharing: SOME (half this Mac) | color=#F5C26B" ;;
  max) echo "Sharing: MAX | color=#36D399" ;;
esac
[ -n "$jobs" ] && echo "Team jobs running here now: $jobs | color=gray"
echo "---"
if [ "$lvl" = off ]; then
  echo "Turn sharing ON (Max) | bash=\"$cmd\" param1=max terminal=false refresh=true sfimage=bolt.fill"
else
  echo "Turn sharing OFF | bash=\"$cmd\" param1=off terminal=false refresh=true sfimage=bolt.slash"
fi
echo "---"
for l in off some max; do
  case $l in off) t="Off: no new jobs" ;; some) t="Some: half the cores" ;; max) t="Max: most of this Mac" ;; esac
  mark=""; [ "$l" = "$lvl" ] && mark=" checked=true"
  echo "$t | bash=\"$cmd\" param1=$l terminal=false refresh=true$mark"
done
echo "---"
echo "Running jobs always finish; Off only stops new ones. | size=11 color=gray"
echo "Open fleet dashboard | href=https://spine-fleet.zomid777.workers.dev"
