#!/bin/sh
# <xbar.title>rdocker share</xbar.title>
# <xbar.desc>Off / Some / Max: how much of this Mac the rdocker pool may use.</xbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# SwiftBar / xbar menu-bar plugin (refreshes every minute; optional). It only wraps rdocker-share.sh,
# found as $RDOCKER_SHARE_CMD, next to this plugin, or /usr/local/bin/rdocker-share.
here=$(cd "$(dirname "$0")" && pwd)
cmd=${RDOCKER_SHARE_CMD:-}
for c in "$here/rdocker-share.sh" /usr/local/bin/rdocker-share; do
  [ -z "$cmd" ] && [ -x "$c" ] && cmd=$c
done
if [ -z "$cmd" ]; then
  echo "rd ?"; echo "---"; echo "rdocker-share not found (install it: see share/README.md)"; exit 0
fi
out=$("$cmd" status 2>/dev/null)
case $out in
  *"is OFF"*) lvl=Off; icon="rd off" ;;
  *"is SOME"*) lvl=Some; icon="rd some" ;;
  *) lvl=Max; icon="rd MAX" ;;
esac
echo "$icon"
echo "---"
printf '%s\n' "$out" | while IFS= read -r l; do echo "$l | color=gray"; done
echo "---"
for l in Off Some Max; do
  mark=""; [ "$l" = "$lvl" ] && mark="  (now)"
  low=$(echo "$l" | tr 'A-Z' 'a-z')
  echo "Share: $l$mark | bash=\"$cmd\" param1=$low terminal=false refresh=true"
done
