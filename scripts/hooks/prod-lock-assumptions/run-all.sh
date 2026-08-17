#!/bin/bash
# run-all.sh — run every prod-lock assumption probe. Mirrors the convention in
# mission-bridge-assumptions/, mission-continuity-assumptions/, session-correlation-assumptions/.
#
# A mismatch means the ENVIRONMENT drifted -> re-validate the design against it. It never means
# "auto-fail the build". These probes check what the kernel, the filesystem and this Python actually
# do; if one goes red, the Part 1A design rests on something that is no longer true here.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
rc=0
for p in [0-9][0-9]-*.sh; do
  [ -f "$p" ] || continue
  printf '\n=== %s ===\n' "$p"
  bash "$p" || rc=1
done
printf '\n'
[ "$rc" -eq 0 ] && printf 'ALL PROBES GREEN\n' || printf 'AT LEAST ONE PROBE RED — see above\n'
exit "$rc"
