#!/bin/bash
# rd-tune: the worker optimizer, run as root every 30 s by rd-tune.timer (installed by provision-linux.sh).
#  * slots.cap: ~$RD_USER/rr/slots.cap = how many rrun slots the runner may use right now, from live
#    free memory and temperature (never above MAX_SLOTS from /etc/rdocker/tune.conf);
#  * WSL only: drop the page cache when memory runs low (the Windows host does not reclaim it);
#  * restart docker / sshd when they are down (at most once per 5 min each);
#  * prune (every 30 min, only while no rrun slot is held): ~/rr/w mirrors and ~/rr/deps entries unused
#    2 days, npm cache over 1 GB, and - on non-home workers only - stopped containers (> 24 h) and
#    images (unused > 72 h), never anything labelled rdocker.keep (the home host's janitor owns those);
#  * `rd-tune bench` (any user, e.g. over ssh): fixed CPU fixture -> ~/rr/speed (float, i7-6700 = 1.0).
# Test hooks (env): RD_MEMINFO, RD_TEMP_FILES, RD_CAP_FILE, RD_CONF, RD_RR_ROOT, RD_STATE_DIR,
# RD_NO_SERVICES=1, RD_WSL=0|1, RD_BENCH_N, RD_BENCH_REF. `rd-tune --source` only defines the functions.
set -u
CONF="${RD_CONF:-/etc/rdocker/tune.conf}"
# shellcheck disable=SC2034  # HEAVY_SLOTS: read by the runner's probe via tune.conf
RD_USER=rd MAX_SLOTS=2 HEAVY_SLOTS=1 IS_HOME=0
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
# sha256 chain steps/s (4 threads) of the i7-6700 reference. UNCALIBRATED until measured on the HP.
BENCH_REF=${RD_BENCH_REF:-1200000}
MEMINFO="${RD_MEMINFO:-/proc/meminfo}"
CAP_FILE="${RD_CAP_FILE:-$(getent passwd "$RD_USER" | cut -d: -f6)/rr/slots.cap}"
STATE="${RD_STATE_DIR:-/run/rdocker-tune}"

meminfo_kb() { awk -v k="$1:" '$1 == k { print $2 }' "$MEMINFO"; }

mem_free_pct() {
  local total avail
  total=$(meminfo_kb MemTotal); avail=$(meminfo_kb MemAvailable)
  [ -n "$total" ] && [ "${total:-0}" -gt 0 ] && [ -n "$avail" ] || { echo 0; return; }   # unreadable = no room
  echo $(( avail * 100 / total ))
}

max_temp_c() {   # hottest sensor in whole degrees C, 0 when none
  local f v best=0
  # shellcheck disable=SC2086
  for f in ${RD_TEMP_FILES:-/sys/class/hwmon/hwmon*/temp*_input}; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null) || continue
    case "$v" in ''|*[!0-9]*) continue ;; esac
    v=$(( v / 1000 )); [ "$v" -gt "$best" ] && best=$v
  done
  echo "$best"
}

compute_cap() {   # $1 free mem %, $2 temp C -> slots (>= 1: a worker with 0 slots would just look dead)
  local pct=$1 temp=$2 cap=$MAX_SLOTS half
  half=$(( (MAX_SLOTS + 1) / 2 ))
  if [ "$pct" -lt 15 ] || [ "$temp" -ge 90 ]; then cap=1
  elif [ "$pct" -lt 25 ] || [ "$temp" -ge 80 ]; then [ "$cap" -gt "$half" ] && cap=$half
  fi
  [ "$cap" -lt 1 ] && cap=1
  echo "$cap"
}

is_wsl() { [ "${RD_WSL:-}" = 1 ] || { [ "${RD_WSL:-}" != 0 ] && grep -qi microsoft /proc/version 2>/dev/null; }; }

cooldown_ok() {   # $1 = name, $2 = seconds (default 300); true when not acted on within that long (then stamps it)
  local f="$STATE/$1" now gap=${2:-300}; now=$(date +%s)
  mkdir -p "$STATE"
  [ -f "$f" ] && [ $(( now - $(cat "$f" 2>/dev/null || echo 0) )) -lt "$gap" ] && return 1
  echo "$now" > "$f"
}

write_cap() {   # only when the value changed; atomic; owned by RD_USER
  local want=$1 dir tmp
  [ "$(cat "$CAP_FILE" 2>/dev/null)" = "$want" ] && return 0
  dir=$(dirname "$CAP_FILE"); mkdir -p "$dir"
  tmp=$(mktemp "$dir/.slots.cap.XXXXXX") && echo "$want" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$CAP_FILE"
  [ "$(id -u)" = 0 ] && chown "$RD_USER": "$dir" "$CAP_FILE" 2>/dev/null
  return 0
}

rr_root() { echo "${RD_RR_ROOT:-$(getent passwd "$RD_USER" | cut -d: -f6)/rr}"; }

slots_idle() {   # true when no rrun slot is flocked (a run in progress could be using any mirror)
  local d s; d="$(rr_root)/slots"
  [ -d "$d" ] || return 0
  for s in "$d"/[0-9]*; do
    [ -f "$s" ] || continue
    case "$s" in *.who) continue ;; esac
    flock -n "$s" true 2>/dev/null || return 1
  done
}

prune() {
  local rr home_dir g; rr=$(rr_root); home_dir=$(dirname "$rr")
  cooldown_ok prune 1800 || return 0
  slots_idle || return 0
  find "$rr/w" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} + 2>/dev/null
  for g in "$rr"/git/*.git; do [ -d "$g" ] && git --git-dir="$g" worktree prune 2>/dev/null; done
  find "$rr/deps" -mindepth 1 -maxdepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null
  if [ "$(du -sm "$home_dir/.npm/_cacache" 2>/dev/null | cut -f1)" -gt 1024 ] 2>/dev/null; then rm -rf "$home_dir/.npm/_cacache"; fi
  if [ "$IS_HOME" != 1 ] && [ -z "${RD_NO_SERVICES:-}" ] && command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    docker container prune -f --filter until=24h --filter "label!=rdocker.keep" >/dev/null 2>&1
    docker image prune -a -f --filter until=72h --filter "label!=rdocker.keep" >/dev/null 2>&1
  fi
}

bench() {   # prints the speed (1.0 = i7-6700) and stores it in ~/rr/speed
  local js out speed
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
  command -v node >/dev/null 2>&1 || { echo "rd-tune: node not found" >&2; return 1; }
  js=$(mktemp "${TMPDIR:-/tmp}/rd-bench.XXXXXX") || return 1
  cat > "$js" <<'JS'
const { Worker, isMainThread } = require('worker_threads');
const c = require('crypto');
const N = +process.env.RD_BENCH_N || 300000, T = Math.min(require('os').cpus().length, 4);
if (isMainThread) {
  const t0 = process.hrtime.bigint(); let done = 0;
  for (let i = 0; i < T; i++) new Worker(__filename).on('exit', () => {
    if (++done === T) console.log(String(Number(process.hrtime.bigint() - t0) / 1e9) + ' ' + (T * N));
  });
} else { let h = Buffer.alloc(32); for (let i = 0; i < N; i++) h = c.createHash('sha256').update(h).digest(); }
JS
  mv "$js" "$js.js"; js="$js.js"
  out=$(node "$js") || { rm -f "$js"; return 1; }
  rm -f "$js"
  speed=$(awk -v o="$out" -v ref="$BENCH_REF" 'BEGIN { split(o, a, " "); printf "%.2f", (a[2] / a[1]) / ref }')
  mkdir -p "$HOME/rr" && echo "$speed" > "$HOME/rr/speed"
  echo "$speed"
}

main() {
  local pct temp cap
  pct=$(mem_free_pct); temp=$(max_temp_c); cap=$(compute_cap "$pct" "$temp")
  write_cap "$cap"
  if [ -n "${RD_NO_SERVICES:-}" ]; then echo "cap=$cap mem_free=$pct temp=$temp"; prune; return 0; fi
  if is_wsl && [ "$pct" -lt 30 ]; then sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; fi
  if systemctl is-enabled --quiet docker 2>/dev/null && ! systemctl is-active --quiet docker && cooldown_ok docker; then
    systemctl restart docker
  fi
  local ssh=ssh; systemctl cat sshd >/dev/null 2>&1 && ssh=sshd
  if ! systemctl is-active --quiet "$ssh" && cooldown_ok ssh; then systemctl restart "$ssh"; fi
  prune
}

case "${1:-}" in --source) ;; bench) bench ;; *) main ;; esac
