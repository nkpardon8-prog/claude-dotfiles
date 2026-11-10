#!/bin/sh
# rd-power-mac: averaged Apple Silicon / Intel Mac power for the fleet reporter (dashboard "power").
# powermetrics needs root, so this runs as a LaunchDaemon (com.rdocker.power) and publishes only a
# 5 s average - "<watts> <epoch>" (CPU + GPU + ANE package power) - to /Users/Shared/rdocker/power.
OUT=${RD_POWER_OUT:-/Users/Shared/rdocker/power}
INT_MS=${RD_POWER_INTERVAL_MS:-5000}
mkdir -p "$(dirname "$OUT")" && chmod 755 "$(dirname "$OUT")"
# "Combined Power (CPU + GPU + ANE): 4123 mW" (Apple Silicon) or "Intel energy model derived package power (CPUs+GT+SA): 7.43W"
# One sample per run (-n 1): a long-running powermetrics block-buffers into the pipe and lags.
AWKPROG=$(cat <<'AWK'

function publish(w,   tmp, t) {
  srand(); t = srand()                     # epoch seconds, portable (macOS awk has no systime)
  tmp = ENVIRON["RD_OUT"] ".tmp"
  printf "%.1f %d\n", w, t > tmp; close(tmp)
  system("chmod 644 \"" tmp "\" && mv -f \"" tmp "\" \"" ENVIRON["RD_OUT"] "\"")
}
/^Combined Power/ && $NF == "mW" { publish($(NF-1) / 1000) }
/package power/ { v = $NF; sub(/W$/, "", v); publish(v + 0) }
AWK
)
while :; do
  /usr/bin/powermetrics --samplers cpu_power -i "$INT_MS" -n 1 2>/dev/null | RD_OUT="$OUT" /usr/bin/awk "$AWKPROG" || sleep 5
done
