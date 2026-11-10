#!/bin/bash
# rd-netcheck: run by rd-netcheck.timer every 2 min. When `tailscale status` has failed 3 checks in a row,
# restart tailscaled (a wedged Tailscale is the one network fault that does not heal itself).
# Test hooks (env): RD_NETCHECK_STATE (counter file).
set -u
STATE="${RD_NETCHECK_STATE:-/run/rdocker-netcheck.count}"
n=$(cat "$STATE" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
if timeout 20 tailscale status >/dev/null 2>&1; then
  echo 0 > "$STATE"
  exit 0
fi
n=$((n + 1))
if [ "$n" -ge 3 ]; then
  logger -t rd-netcheck "tailscale status failed $n checks in a row: restarting tailscaled"
  systemctl restart tailscaled
  n=0
fi
echo "$n" > "$STATE"
