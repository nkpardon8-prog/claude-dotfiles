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
#    only - stopped containers (> 24 h) and images (unused, built > 72 h ago), never anything labelled
#    rdocker.keep nor a KEEP_IMAGE_REPOS image (the DB images; see pin_keep_images) (the home host's
#    janitor owns those);
#  * `rd-tune prune` (as the rd user, e.g. a Mac worker): just the ~/rr prune below, single instance
#    (~/rr/state/prune.lock), at low priority (nice 19; macOS taskpolicy -b, Linux ionice -c3). A Mac worker
#    has no systemd: its root daemon rd-worker-mac runs this as rd every 10 min (install-worker-mac.sh copies
#    this file to /usr/local/libexec/rd-tune); `rd-tune prune-loop [interval s]` is the same as a loop rd can
#    start detached by itself (one per worker: ~/rr/state/prune-loop.lock; log ~/rr/log/prune.log).
#    On macOS ~/rr is its own small volume (an 80 GB APFS quota) that fills in an evening, so pressure starts
#    below 25 % free (target 30 %) and the recent-use guard is 10 min (defaults below; env / tune.conf win),
#    and under pressure the worker's Colima (its VM disk is on ~/rr too: ~/.colima -> ~/rr/home/colima) is
#    pruned as well - only while Colima already runs, never started for it (see docker_prune);
#  * `rd-tune bench` (any user, e.g. over ssh): fixed CPU fixture -> ~/rr/speed (float, i7-6700 = 1.0).
#    A Mac worker may have no rd-tune installed: `rdocker bench-worker <name>` pipes this file over ssh
#    (`bash -s bench`), so bench must never read stdin and must find mise's node without shims.
# Test hooks (env): RD_MEMINFO, RD_TEMP_FILES, RD_CAP_FILE, RD_CONF, RD_RR_ROOT, RD_STATE_DIR,
# RD_NO_SERVICES=1, RD_DRAIN_FILE, RD_WSL=0|1, RD_BENCH_N, RD_BENCH_REF, RD_DF_CMD (prints what `df -Pk <path>` does),
# RD_OS (default uname -s), RD_DOCKER_SOCK (a Mac's Colima socket), RR_COLIMA. `rd-tune --source` only defines the functions.
set -u
CONF="${RD_CONF:-/etc/rdocker/tune.conf}"
# shellcheck disable=SC2034  # HEAVY_SLOTS: read by the runner's probe via tune.conf
RD_USER=rd MAX_SLOTS=2 HEAVY_SLOTS=1 IS_HOME=0
OS=${RD_OS:-$(uname -s)}
is_mac() { [ "$OS" = Darwin ]; }
# ~/rr disk-pressure thresholds and the recent-use guard (env, or tune.conf, which wins): see prune()
if is_mac; then   # a Mac's ~/rr: its own small volume (see the header)
  PRUNE_MIN_FREE_PCT=${PRUNE_MIN_FREE_PCT:-25} PRUNE_TARGET_FREE_PCT=${PRUNE_TARGET_FREE_PCT:-30}
  PRUNE_MIN_FREE_GB=${PRUNE_MIN_FREE_GB:-10} PRUNE_TARGET_FREE_GB=${PRUNE_TARGET_FREE_GB:-15}
  PRUNE_RECENT_S=${PRUNE_RECENT_S:-600}
fi
PRUNE_MIN_FREE_PCT=${PRUNE_MIN_FREE_PCT:-20} PRUNE_TARGET_FREE_PCT=${PRUNE_TARGET_FREE_PCT:-25}
PRUNE_MIN_FREE_GB=${PRUNE_MIN_FREE_GB:-25} PRUNE_TARGET_FREE_GB=${PRUNE_TARGET_FREE_GB:-30}
PRUNE_RECENT_S=${PRUNE_RECENT_S:-1800}
# image repositories (any tag; space-separated) the docker prune never removes: see pin_keep_images
KEEP_IMAGE_REPOS=${KEEP_IMAGE_REPOS:-postgres}
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

user_home() {   # getent (Linux), else dscl (macOS)
  local h; h=$(getent passwd "$RD_USER" 2>/dev/null | cut -d: -f6)
  [ -n "$h" ] || h=$(dscl . -read "/Users/$RD_USER" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }')
  echo "$h"
}
rr_root() { echo "${RD_RR_ROOT:-$(user_home)/rr}"; }

idle_run() {   # $1 = what: `rd-tune __idle $1` once no rrun slot is held (a run in progress could be using
  # anything). Any slot held, or one it cannot open, or a symlink = nothing done, status 0 (fail closed).
  # "pressure" (a Mac's Colima under disk pressure) keeps every slot held through the cleanup, so no run
  # starts meanwhile; "normal" releases them first, as Linux always did (a slow docker pass never makes
  # the worker refuse jobs). perl flock(2): macOS has no util-linux flock.
  perl -MFcntl=:flock,O_RDWR,O_NOFOLLOW -e '
    $^F = 1023;                                   # the slot fds stay open across the exec
    my ($d, @cmd) = @ARGV; my @held;
    if (-e $d || -l $d) {
      exit 0 if -l $d || !opendir(my $dh, $d);
      for (grep { /^\d+$/ } readdir $dh) {
        my $p = "$d/$_"; exit 0 if -l $p; next unless -f $p;
        sysopen(my $f, $p, O_RDWR | O_NOFOLLOW) or exit 0;
        flock($f, LOCK_EX | LOCK_NB) or exit 0;
        push @held, $f;
      }
    }
    @held = () unless $cmd[-1] eq "pressure";     # closed = released
    exec @cmd or exit 127' "$(rr_root)/slots" /bin/bash "$SELF" __idle "$1"
}

tmo() {   # $1 = seconds, then the command; over that its process group gets TERM, then KILL (exit 124).
  # (alarm + exec alone would not stop a Go CLI like docker or colima: it ignores SIGALRM)
  perl -e 'my $t = shift; my $p = fork; exit 1 unless defined $p;
    if (!$p) { setpgrp(0, 0); exec @ARGV or exit 127 }
    my $fired = 0;
    $SIG{ALRM} = sub { $fired = 1; kill "TERM", -$p; sleep 3; kill "KILL", -$p };
    alarm $t; waitpid($p, 0); exit($fired || $? & 127 ? 124 : $? >> 8)' "$@"
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
exit 0 if -l $dir;                                # never through a symlink out of ~/rr
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

# Docker on a non-home worker, only while holding every rrun slot (idle_run: a run may have pulled an image
# it has not started yet) and never anything labelled rdocker.keep. Normal (every 30 min): stopped containers > 24 h,
# unused images built > 72 h ago. "pressure" (a Mac whose ~/rr is low: its Colima VM disk lives there; at most every
# 10 min): also every image no container uses (created > 10 min ago) and every anonymous volume none uses
# (API 1.42+, client and server: older ones prune named volumes too), then fstrim in the VM so its sparse
# disk gives the space back. Linux: the system docker while systemd runs
# it. macOS: the worker's own Colima socket, only while Colima already runs (`docker info` answers within
# 20 s); never started here.
docker_up() {
  if is_mac; then
    local s=${RD_DOCKER_SOCK:-$(dirname "$(rr_root)")/.colima/default/docker.sock}
    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
    [ -S "$s" ] && command -v docker >/dev/null 2>&1 || return 1
    unset DOCKER_CONTEXT DOCKER_API_VERSION          # they would override this socket / the API version
    export DOCKER_HOST="unix://$s"
    tmo 20 docker info >/dev/null 2>&1
  else
    [ -z "${RD_NO_SERVICES:-}" ] && command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker
  fi
}
# The DB images (KEEP_IMAGE_REPOS, any tag) stay through docker's own prune. `image prune -a --filter until=`
# tests an image's BUILD date, not its last use, and cannot exclude a repository: postgres:17 (dentall's
# provisioner) and postgres:16-alpine (rr_pg_lanes) went at every prune that found no container up, and the
# next DB job re-pulled ~450 MB (2026-11-24). `image prune -a` keeps every image a container uses, even a
# stopped one, and the container prune skips rdocker.keep: so each such local image gets one created,
# never-started pin container (rd-pin-<repo>-<tag>, labels rdocker.keep=1 + rdocker.pin=<repo:tag>, no
# network). When the tag moves to a newer pull, the pin is re-made on it and the old image becomes prunable.
# A pin is removed (by the id just checked) only when its name AND its rdocker.pin label are ours;
# nothing else is touched. A pin that cannot be made (or a listing that fails) skips that image prune.
pin_keep_images() {   # status 1 = a pin could not be made (the caller then skips the image prune)
  local repo list="" ref iid name have hid rest bad=0
  for repo in $KEEP_IMAGE_REPOS; do
    list="$list$(tmo 60 docker image ls --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' "$repo" 2>/dev/null || echo FAIL)
"
  done
  case "$list" in *FAIL*) return 1 ;; esac
  while read -r ref iid; do
    case "$ref" in *'<none>'*|'') continue ;; esac
    name="rd-pin-$(printf '%s' "$ref" | tr -c 'A-Za-z0-9_.-' '-')"
    # "<id>|<image>|<pin label>|", compared as exact strings (no field splitting: a label is not trimmed)
    have=$(tmo 30 docker container inspect --format '{{.Id}}|{{.Image}}|{{index .Config.Labels "rdocker.pin"}}|' "$name" 2>/dev/null)
    if [ -n "$have" ]; then
      hid=${have%%|*} rest=${have#*|}
      [ "$rest" = "$iid|$ref|" ] && continue                # pinned on the image the tag points at now
      if [ "${rest#*|}" != "$ref|" ]; then                  # that name is not our pin: never touched
        echo "rd-tune: pin $ref: the name $name is taken by another container"; bad=1; continue
      fi
      tmo 60 docker container rm "$hid" >/dev/null 2>&1 || { bad=1; continue; }   # by the id checked above
    fi
    tmo 60 docker container create --pull never --network none --name "$name" --label rdocker.keep=1 \
      --label "rdocker.pin=$ref" "$ref" >/dev/null 2>&1 || { echo "rd-tune: pin $ref: create failed"; bad=1; }
  done <<< "$list"
  return "$bad"
}
docker_prune() {   # $1 = pressure | (empty)
  [ "$IS_HOME" != 1 ] && docker_up || return 0
  local t="tmo 600" api   # a hung daemon never wedges the prune (and its locks)
  local pinned=1
  pin_keep_images || pinned=0                         # before any prune: the DB images stay
  $t docker container prune -f --filter until=24h --filter "label!=rdocker.keep" >/dev/null 2>&1
  if [ "${1:-}" = pressure ]; then
    [ "$pinned" = 1 ] && $t docker image prune -a -f --filter until=10m --filter "label!=rdocker.keep" >/dev/null 2>&1
    # anonymous volumes only (as the mini's janitor): a named one may be kept alive by rdocker.ttl
    api=$(tmo 20 docker version --format '{{.Client.APIVersion}} {{.Server.APIVersion}}' 2>/dev/null)
    if awk -v v="$api" 'BEGIN { n = split(v, w, " "); if (n != 2) exit 1
         for (i = 1; i <= 2; i++) { split(w[i], a, "."); if (a[1] + 0 < 1 || (a[1] == 1 && a[2] + 0 < 42)) exit 1 } }'; then
      $t docker volume prune -f --filter "label!=rdocker.keep" >/dev/null 2>&1
    fi
    local colima=${RR_COLIMA:-/opt/homebrew/bin/colima}   # rr_runner.pl's
    is_mac && [ -x "$colima" ] && tmo 120 "$colima" ssh -- sudo fstrim -a >/dev/null 2>&1
    echo "rd-tune: prune docker (disk low: unused images and volumes)"
  else
    [ "$pinned" = 1 ] && $t docker image prune -a -f --filter until=72h --filter "label!=rdocker.keep" >/dev/null 2>&1
  fi
}

prune() {
  local rr home_dir g kind low=0; rr=$(rr_root); home_dir=$(dirname "$rr")
  [ -d "$rr" ] || return 0
  empty_trash "$rr"                                   # leftovers of a prune that was killed
  if disk_low "$rr"; then                             # LRU first, one entry per df; mirrors, then the store
    low=1
    for kind in w w2 deps; do
      while ! disk_ok "$rr" && evict "$rr" "$kind" 0 1 "disk low: $(disk_free "$rr" | awk '{ print $1 "% / " $2 " GB free" }')"; do :; done
    done
  fi
  if [ "$low" = 1 ] && is_mac; then idle_run pressure; fi
  cooldown_ok prune 1800 || return 0
  prune_rcache "$rr"
  evict "$rr" w $(( 2 * 86400 )) 0 "unused 2d"
  evict "$rr" w2 $(( 2 * 86400 )) 0 "unused 2d"   # mirrors of runners since 2026-11-11
  for g in "$rr"/git/*.git; do [ -d "$g" ] && git --git-dir="$g" worktree prune 2>/dev/null; done
  evict "$rr" deps $(( 2 * 86400 )) 0 "unused 2d"
  sweep_spool "$rr"
  idle_run normal                                     # npm cache / docker: no per-run owner to check
}

idle_cleanup() {   # $1 = normal | pressure; run by idle_run, every slot held
  local home_dir; home_dir=$(dirname "$(rr_root)")
  if [ "$1" = pressure ]; then cooldown_ok docker-pressure 540 && docker_prune pressure; return; fi
  if [ ! -L "$home_dir/.npm" ] && [ ! -L "$home_dir/.npm/_cacache" ] &&
     [ "$(du -sm "$home_dir/.npm/_cacache" 2>/dev/null | cut -f1)" -gt 1024 ] 2>/dev/null; then rm -rf "$home_dir/.npm/_cacache"; fi
  docker_prune
}

# `rd-tune prune` / `prune-loop`: as the worker user (rd), one at a time (a flock held across the exec).
# Exit 75 = another one holds the lock (nothing done); 1 = the lock file cannot be made.
locked() {   # $1 = lock file, then the command
  mkdir -p "$(dirname "$1")" 2>/dev/null
  perl -MFcntl=:flock,O_WRONLY,O_CREAT,O_NOFOLLOW,O_NONBLOCK -e '
    $^F = 255;                                    # keep the lock fd open across the exec
    my $l = shift; my $f;
    sysopen($f, $l, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0600) && -f $f or exit 1;
    flock($f, LOCK_EX | LOCK_NB) or exit 75;
    exec @ARGV or exit 127' "$@"
}
prune_loop() {   # $1 = interval s; logs what it did (timestamped, kept under 1 MB)
  local every=${1:-600} log out; log="$(rr_root)/log/prune.log"
  case $every in ''|*[!0-9]*|0) every=600 ;; esac
  mkdir -p "$(dirname "$log")" 2>/dev/null
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) rd-tune: prune-loop start (pid $$, every ${every}s)" >> "$log"
  while :; do
    out=$(/bin/bash "$SELF" prune 2>&1)             # re-read each time: an updated rd-tune takes effect
    [ -n "$out" ] && printf '%s\n' "$out" | sed "s/^/$(date +%Y-%m-%dT%H:%M:%S%z) /" >> "$log"
    [ "$(wc -c < "$log" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$log" "$log.1"
    sleep "$every"
  done
}
SELF=$0

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

case "${1:-}" in
  --source) ;;
  bench) bench ;;
  prune)   # low priority: nice 19 plus background I/O (macOS taskpolicy -b, Linux ionice -c3)
    set -- /bin/bash "$SELF" __prune
    if command -v taskpolicy >/dev/null 2>&1; then set -- taskpolicy -b "$@"
    elif command -v ionice >/dev/null 2>&1; then set -- ionice -c3 "$@"; fi
    locked "$(rr_root)/state/prune.lock" nice -n 19 "$@" ;;
  prune-loop)   # detaches itself (own session, no terminal) once it holds the lock; prints its pid
    # shellcheck disable=SC2016  # Perl
    locked "$(rr_root)/state/prune-loop.lock" perl -MPOSIX -e '
      my $p = fork; exit 1 unless defined $p;
      if ($p) { print "rd-tune: prune-loop started (pid $p)\n"; exit 0 }
      POSIX::setsid(); open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">&", \*STDOUT);
      exec @ARGV or exit 127' /bin/bash "$SELF" __prune-loop "${2:-600}" ;;
  __prune) RD_STATE_DIR=${RD_STATE_DIR:-$(rr_root)/state/tune}; export RD_STATE_DIR; STATE=$RD_STATE_DIR; prune ;;
  __idle) idle_cleanup "${2:-normal}" ;;
  __prune-loop) prune_loop "${2:-}" ;;
  *) main ;;
esac
