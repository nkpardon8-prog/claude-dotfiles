#!/bin/bash
# rd-power: averaged CPU package power for the fleet reporter (dashboard "power" bar).
# The RAPL energy counter is root-only (Platypus side channel), so this root service reads it and
# publishes only a coarse average - watts to 0.1 W over INTERVAL seconds - as "<watts> <epoch>" in
# /run/rdocker/power (0644). The reporter (user rd) reads that file and drops it when stale.
# This is CPU package power (cores + iGPU + uncore), not wall power: no meter on these boxes.
Z=${RD_POWERCAP:-/sys/class/powercap/intel-rapl:0}
OUT=${RD_POWER_OUT:-/run/rdocker/power}
INT=${RD_POWER_INTERVAL:-5}
[ -n "${RD_POWERCAP:-}" ] || modprobe intel_rapl_msr 2>/dev/null || true
[ -r "$Z/energy_uj" ] || { echo "rd-power: no RAPL package counter here; nothing to report"; exit 0; }
mkdir -p "$(dirname "$OUT")" && chmod 755 "$(dirname "$OUT")"
MAX=$(cat "$Z/max_energy_range_uj" 2>/dev/null || echo 0)
prev=$(cat "$Z/energy_uj"); pt=$(date +%s%N)
while sleep "$INT"; do
  e=$(cat "$Z/energy_uj" 2>/dev/null) || continue
  t=$(date +%s%N)
  d=$(( e - prev )); [ "$d" -lt 0 ] && d=$(( d + MAX ))      # counter wrapped
  dt=$(( (t - pt) / 1000 ))                                  # microseconds
  prev=$e; pt=$t
  [ "$dt" -gt 0 ] && [ "$d" -ge 0 ] || continue
  w10=$(( (d * 10 + dt / 2) / dt ))                          # uJ/us = W, in tenths
  printf '%d.%d %d\n' $(( w10 / 10 )) $(( w10 % 10 )) $(( t / 1000000000 )) > "$OUT.tmp" \
    && chmod 644 "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
  [ "${RD_POWER_ONCE:-0}" = 1 ] && exit 0
done
