#!/bin/bash
# rd-tune: the worker optimizer, run as root every 30 s by rd-tune.timer (installed by provision-linux.sh).
#  * slots.cap: ~$RD_USER/rr/slots.cap = how many rrun slots the runner may use right now, from live
#    free memory and temperature (never above MAX_SLOTS from /etc/rdocker/tune.conf); 0 while rd-doctor's
#    drain marker (/run/rdocker/drain) is fresh (touched in the last 5 min: a dead doctor never holds a
#    worker drained). Precedence: owner share switch > doctor drain > this cap > fleet slots (rd-doctor.sh);
#  * WSL only: drop the page cache when memory runs low (the Windows host does not reclaim it);
#  * restart docker / sshd when they are down (at most once per 5 min each);
#  * prune ~/rr, also while runs are in progress (never a mirror a run uses, nothing used in the last
#    30 min): every 30 min, ~/rr/w mirrors and ~/rr/deps entries unused 2 days; on every tick, while the
#    ~/rr filesystem is low on space, least-recently-used mirrors, then store entries (see prune());
#    every 30 min, the pool result cache ~/rr/rcache (home worker): expired, then LRU over RCACHE_MAX_MB;
#    Every 30 min and only while no rrun slot is held: npm cache over 1 GB, and - on non-home workers
#    only - stopped containers (> 24 h) and images (unused > 72 h), never anything labelled
#    rdocker.keep (the home host's janitor owns those);
#  * `rd-tune bench` (any user, e.g. over ssh): fixed CPU fixture -> ~/rr/speed (float, i7-6700 = 1.0).
#    A Mac worker has no rd-tune installed: `rdocker bench-worker <name>` pipes this file over ssh
#    (`bash -s bench`), so bench must never read stdin and must find mise's node without shims.
# Test hooks (env): RD_MEMINFO, RD_TEMP_FILES, RD_CAP_FILE, RD_CONF, RD_RR_ROOT, RD_STATE_DIR,
# RD_NO_SERVICES=1, RD_DRAIN_FILE, RD_WSL=0|1, RD_BENCH_N, RD_BENCH_REF, RD_DF_CMD (prints what `df -Pk <path>` does). `rd-tune --source` only defines the functions.
set -u
CONF="${RD_CONF:-/etc/rdocker/tune.conf}"
# shellcheck disable=SC2034  # HEAVY_SLOTS: read by the runner's probe via tune.conf
RD_USER=rd MAX_SLOTS=2 HEAVY_SLOTS=1 IS_HOME=0
# ~/rr disk-pressure thresholds and the recent-use guard (env, or tune.conf, which wins): see prune()
PRUNE_MIN_FREE_PCT=${PRUNE_MIN_FREE_PCT:-20} PRUNE_TARGET_FREE_PCT=${PRUNE_TARGET_FREE_PCT:-25}
PRUNE_MIN_FREE_GB=${PRUNE_MIN_FREE_GB:-25} PRUNE_TARGET_FREE_GB=${PRUNE_TARGET_FREE_GB:-30}
PRUNE_RECENT_S=${PRUNE_RECENT_S:-1800}
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
# sha256 chain steps/s (4 threads) of the i7-6700 reference. UNCALIBRATED until measured on the HP.
BENCH_REF=${RD_BENCH_REF:-1200000}
MEMINFO="${RD_MEMINFO:-/proc/meminfo}"
CAP_FILE="${RD_CAP_FILE:-$(getent passwd "$RD_USER" 2>/dev/null | cut -d: -f6)/rr/slots.cap}"   # no getent on macOS
STATE="${RD_STATE_DIR:-/run/rdocker-tune}"
DRAIN_FILE="${RD_DRAIN_FILE:-/run/rdocker/drain}"   # rd-doctor's; only rd-doctor writes or removes it

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

doctor_drained() { [ -f "$DRAIN_FILE" ] && [ -n "$(find "$DRAIN_FILE" -mmin -5 2>/dev/null)" ]; }

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

# ~/rr pruning. A busy pool always holds some slot, so pruning no longer waits for an idle worker
# (2026-11-11: the HP reached 92% used, 133 GB of mirrors + 53 GB of store, because it did). Instead:
#  * age rule (every 30 min): mirrors ~/rr/w/<slug>-<wt12> and store entries ~/rr/deps/<key> unused 2 days;
#  * disk-pressure rule (every tick; just one df unless low): below PRUNE_MIN_FREE_PCT % or
#    PRUNE_MIN_FREE_GB free on the ~/rr filesystem, least-recently-used mirrors go first, then store
#    entries, one at a time, until PRUNE_TARGET_FREE_PCT % and PRUNE_TARGET_FREE_GB are free or nothing
#    more is eligible.
# Never evicted: a mirror a run uses, and anything used in the last PRUNE_RECENT_S (a run may be preparing
# it). "Uses": the runner flocks slots/<i> for the run's whole life, BEFORE it touches its mirror or the
# store, and writes <i>.who = "<repo_slug> <epoch> <pid> <wt12>". PRUNE_PL takes every free slot (so no
# run can start while it picks), protects the mirror a held slot's .who names (an old 3-field .who: the
# whole repo; a held slot with a garbled/stale .who: every mirror, fail closed) and the mirror a .who
# with a live pid names even when its slot is free; a dead pid on a free slot protects nothing (the same
# rules as rd_janitor's ~/rr housekeeping). A picked entry is renamed into ~/rr/.trash (atomic: a
# concurrent `cp` of a store entry then fails loudly and the runner falls back to npm ci, it never gets
# half a tree) and deleted at low priority after the slots are released.
# Store entries are copied into a mirror (store_clone: cp -a --reflink=auto), never linked, so deleting
# one never touches a mirror; store_clone bumps the entry's mtime right before its cp, and store_save
# writes a .tmp-<key>.<pid> (kept 1 h) then renames it, so the recent guard covers a prepare in progress.
# shellcheck disable=SC2016  # Perl, expanded by perl
PRUNE_PL='
use strict; use warnings;
use Fcntl qw(:flock O_RDWR O_NOFOLLOW);
my ($R, $kind, $max_age, $recent, $limit, $trash) = @ARGV;
$ENV{PATH} = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin";
sub mtime { my @s = lstat $_[0]; @s ? $s[9] : 0 }
sub git { system("git", "-c", "core.hooksPath=/dev/null", @_) == 0 }
my (%busy, %inuse, @held);
if ($kind =~ /^w2?$/ && opendir(my $sd, "$R/slots")) {
    for my $s (sort grep { /^\d+$/ } readdir $sd) {
        sysopen(my $fh, "$R/slots/$s", O_RDWR | O_NOFOLLOW) or next;
        my $free = flock($fh, LOCK_EX | LOCK_NB);
        my ($who, $slug, $pid, $wt) = ("");
        if (open(my $w, "<", "$R/slots/$s.who")) { $who = <$w> // ""; close $w }
        chomp $who;
        ($slug, $pid, $wt) = $who =~ /^([A-Za-z0-9._-]+) \d+ (\d+)(?: ([A-Za-z0-9._-]+))?$/;
        my $alive = defined $pid && $pid > 0 && kill(0, $pid);
        if ($free) {
            push @held, $fh;                      # held until we exit: no run starts in this slot
            next unless $alive;                   # stale .who (dead pid) protects nothing
        } else {
            my @wst = lstat "$R/slots/$s.who";
            my @lst = stat $fh;
            undef $slug unless $alive && @wst && @lst && $wst[9] >= $lst[9];
        }
        if    (!defined $slug) { $busy{"*"} = 1 }
        elsif (defined $wt)    { $inuse{"$slug-$wt"} = 1 }
        else                   { $busy{$slug} = 1 }
    }
}
sub last_use {                                    # newest of the dir and (mirror) its worktree index/HEAD
    my ($p) = @_;
    my $last = mtime($p);
    if ($kind =~ /^w2?$/ && open(my $g, "<", "$p/.git")) {
        my ($admin) = (<$g> // "") =~ /^gitdir: (.+)$/;
        close $g;
        if (defined $admin) {
            for ("$admin/index", "$admin/HEAD") { my $t = mtime($_); $last = $t if $t > $last }
        }
    }
    $last;
}
my $dir = "$R/$kind";
opendir(my $dh, $dir) or exit 0;
my @cand;
for my $e (readdir $dh) {
    my $p = "$dir/$e";
    next if -l $p || !-d _;
    my $floor = $recent;
    if ($kind =~ /^w2?$/) {
        my ($slug) = $e =~ /^(?!\.)([A-Za-z0-9._-]+)-[0-9a-f]{12}$/ or next;
        next if $busy{"*"} || $busy{$slug} || $inuse{$e};
    } elsif ($e =~ /^\.tmp-[0-9a-f]{32}\.\d+$/) { $floor = 3600 if $floor < 3600 }   # a save in progress
    elsif ($e !~ /^[0-9a-f]{32}$/) { next }
    my $age = time - last_use($p);
    next if $age < $floor || $age < $max_age;
    push @cand, [$age, $e];
}
my $n = 0;
for (sort { $b->[0] <=> $a->[0] || $a->[1] cmp $b->[1] } @cand) {   # least recently used first
    last if $limit && $n >= $limit;
    my ($age, $e) = @$_;
    my $p = "$dir/$e";
    next if time - last_use($p) < $recent;       # used since we listed it
    rename($p, "$trash/$kind-$e.$$.$n") or next;
    $n++;
    printf "TRASH %s %s %d\n", $kind, $e, $age / 3600;
    next unless $kind =~ /^w2?$/;
    unlink "$dir/.$e.envlist";
    my ($slug, $wt12) = $e =~ /^(.+)-([0-9a-f]{12})$/;
    my $bare = "$R/git/$slug.git";
    if (-d $bare && !-l $bare) {
        git("-C", $bare, "worktree", "prune");
        git("-C", $bare, "update-ref", "-d", "refs/rrun/$wt12");
    }
}
'

# Free space of the ~/rr filesystem -> "<free %> <free GB>"; empty when unknown.
# RD_DF_CMD: test hook, a command printing what `df -Pk <path>` prints.
disk_free() {
  ${RD_DF_CMD:-df -Pk} "$1" 2>/dev/null | awk 'NR == 2 && $2 > 0 { printf "%d %d\n", $4 * 100 / $2, $4 / 1048576 }'
}

disk_low() {   # $1 = rr: true below the minimum free (% or GB); unknown = not low
  local f; f=$(disk_free "$1"); [ -n "$f" ] || return 1
  # shellcheck disable=SC2086
  set -- $f
  [ "$1" -lt "$PRUNE_MIN_FREE_PCT" ] || [ "$2" -lt "$PRUNE_MIN_FREE_GB" ]
}

disk_ok() {    # $1 = rr: true once the target free (% and GB) is reached; unknown = done
  local f; f=$(disk_free "$1"); [ -n "$f" ] || return 0
  # shellcheck disable=SC2086
  set -- $f
  [ "$1" -ge "$PRUNE_TARGET_FREE_PCT" ] && [ "$2" -ge "$PRUNE_TARGET_FREE_GB" ]
}

empty_trash() {   # $1 = rr; low priority, so a big delete does not starve the runs
  local t="$1/.trash" io=""
  [ -d "$t" ] && [ ! -L "$t" ] || return 0
  command -v ionice >/dev/null 2>&1 && io="ionice -c3"
  # shellcheck disable=SC2086
  find "$t" -mindepth 1 -maxdepth 1 -exec nice -n 19 $io rm -rf {} + 2>/dev/null
}

evict() {   # $1 rr, $2 w|w2|deps, $3 max age s, $4 limit (0 = all), $5 why; logs what went; 0 when anything did
  local rr=$1 kind=$2 why=$5 out line what
  mkdir -p "$rr/.trash" 2>/dev/null
  [ -d "$rr/.trash" ] && [ ! -L "$rr/.trash" ] || return 1
  out=$(perl -e "$PRUNE_PL" "$rr" "$kind" "$3" "$PRUNE_RECENT_S" "$4" "$rr/.trash" 2>/dev/null)
  empty_trash "$rr"
  [ -n "$out" ] || return 1
  what=mirror; [ "$kind" = deps ] && what="store entry"
  while read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    echo "rd-tune: prune rm $what $3 ($why, last used $4h ago)"
  done <<< "$out"
}

# ~/rr/spool (rr_runner.pl detached runs): a run's files 10 min after its result (.rc / .norun), or 1 h
# after their last change - never while a keeper holds <id>.lock (a live keeper also touches its files
# every 5 min). The same rule as rr_runner.pl spool_sweep, which runs only when a detached run ends.
sweep_spool() {
  perl -MFcntl=:flock,O_RDONLY,O_NOFOLLOW -e '
    my $d = "$ARGV[0]/spool"; exit 0 if -l $d || !opendir(my $dh, $d);
    my %g; for (readdir $dh) { push @{ $g{$1} }, $_ if /^([0-9a-f-]{36})\.(?:out|err|hb|ctl|rc|end|lock|norun|rc\.tmp|end\.tmp)$/ }
    for my $id (keys %g) {
      my $lk = "$d/$id.lock";
      if (!-l $lk && sysopen(my $fh, $lk, O_RDONLY | O_NOFOLLOW)) { my $free = flock($fh, LOCK_SH | LOCK_NB); close $fh; next unless $free }
      my ($new) = sort { $b <=> $a } map { (lstat "$d/$_")[9] // 0 } @{ $g{$id} };
      my $end = (lstat "$d/$id.rc")[9] // (lstat "$d/$id.norun")[9];
      next unless (defined $end && time - $end > 600) || time - $new > 3600;
      unlink map { "$d/$_" } @{ $g{$id} };
    }' "$1" 2>/dev/null
}

# ~/rr/rcache (rd_cache's pool result cache, on the home worker): entries past their TTL (pass 24 h,
# failure 20 min) or unreadable, leases past their expiry or untouched 1 h, temp files over 1 h; then
# the least recently used entries (mtime: a hit touches it) until the store is under RCACHE_MAX_MB.
RCACHE_MAX_MB=${RCACHE_MAX_MB:-512}
prune_rcache() {   # $1 = rr
  perl -MJSON::PP -e '
    my ($d, $cap, $now) = ("$ARGV[0]/rcache", $ARGV[1] * 1048576, time);
    exit 0 if -l $d || !opendir(my $dh, $d);
    my ($tot, @live) = (0);
    for my $n (readdir $dh) {
      my $p = "$d/$n";
      my @st = lstat $p or next;
      next unless -f _;
      if ($n =~ /\.tmp$/) { unlink $p if $now - $st[9] > 3600; next }
      my ($k, $ext) = $n =~ /^([0-9a-f]{64})\.(entry|lease)$/ or next;
      open(my $f, "<", $p) or next;
      my $line = <$f> // ""; close $f;
      my $m = eval { JSON::PP->new->decode($line) };
      if ($ext eq "lease") {
        unlink $p if ref $m ne "HASH" || ($m->{exp} // 0) < $now || $now - $st[9] > 3600;
        next;
      }
      my $ttl = ref $m eq "HASH" && ($m->{rc} // "") =~ /^\d+$/ ? ($m->{rc} == 0 ? 86400 : 1200) : -1;
      if ($ttl < 0 || ($m->{ts} // 0) !~ /^\d+(\.\d+)?$/ || $now - $m->{ts} > $ttl) { unlink $p; next }
      push @live, [$st[9], $st[7], $p, $k]; $tot += $st[7];
    }
    for (sort { $a->[0] <=> $b->[0] } @live) {
      last if $tot <= $cap;
      next unless unlink $_->[2];
      $tot -= $_->[1];
      printf "rd-tune: prune rm pool-cache entry %s (over %d MB, last used %dh ago)\n", substr($_->[3], 0, 12),
        $ARGV[1], ($now - $_->[0]) / 3600;
    }' "$1" "$RCACHE_MAX_MB" 2>/dev/null
}

prune() {
  local rr home_dir g kind; rr=$(rr_root); home_dir=$(dirname "$rr")
  [ -d "$rr" ] || return 0
  empty_trash "$rr"                                   # leftovers of a prune that was killed
  if disk_low "$rr"; then                             # LRU first, one entry per df; mirrors, then the store
    for kind in w w2 deps; do
      while ! disk_ok "$rr" && evict "$rr" "$kind" 0 1 "disk low: $(disk_free "$rr" | awk '{ print $1 "% / " $2 " GB free" }')"; do :; done
    done
  fi
  cooldown_ok prune 1800 || return 0
  prune_rcache "$rr"
  evict "$rr" w $(( 2 * 86400 )) 0 "unused 2d"
  evict "$rr" w2 $(( 2 * 86400 )) 0 "unused 2d"   # mirrors of runners since 2026-11-11
  for g in "$rr"/git/*.git; do [ -d "$g" ] && git --git-dir="$g" worktree prune 2>/dev/null; done
  evict "$rr" deps $(( 2 * 86400 )) 0 "unused 2d"
  sweep_spool "$rr"
  slots_idle || return 0                              # npm cache / docker: no per-run owner to check
  if [ "$(du -sm "$home_dir/.npm/_cacache" 2>/dev/null | cut -f1)" -gt 1024 ] 2>/dev/null; then rm -rf "$home_dir/.npm/_cacache"; fi
  if [ "$IS_HOME" != 1 ] && [ -z "${RD_NO_SERVICES:-}" ] && command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    docker container prune -f --filter until=24h --filter "label!=rdocker.keep" >/dev/null 2>&1
    docker image prune -a -f --filter until=72h --filter "label!=rdocker.keep" >/dev/null 2>&1
  fi
}

bench() {   # prints the speed (1.0 = i7-6700) and stores it in ~/rr/speed
  local js out speed
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
  if ! command -v node >/dev/null 2>&1; then   # mise without shims (the Mac rd user); RD_MISE: tests
    local m n
    for m in ${RD_MISE:-$(command -v mise) /opt/homebrew/bin/mise}; do
      [ -x "$m" ] && n=$("$m" which node 2>/dev/null </dev/null) && [ -x "$n" ] && { PATH="$(dirname "$n"):$PATH"; break; }
    done
  fi
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
  out=$(node "$js" </dev/null) || { rm -f "$js"; return 1; }   # stdin may be this script (bash -s)
  rm -f "$js"
  speed=$(awk -v o="$out" -v ref="$BENCH_REF" 'BEGIN { split(o, a, " "); printf "%.2f", (a[2] / a[1]) / ref }')
  (umask 077; mkdir -p "$HOME/rr") && echo "$speed" > "$HOME/rr/speed"
  echo "$speed"
}

main() {
  local pct temp cap
  pct=$(mem_free_pct); temp=$(max_temp_c); cap=$(compute_cap "$pct" "$temp")
  doctor_drained && cap=0
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
