#!/bin/bash
# rd-doctor: the worker's on-host, deterministic self-healing watchdog (no AI, no laptop needed).
# Linux: run as root every 30 s by rd-doctor.timer (installed by rd-resilience.sh). macOS: run as the
# rd user every 30 s by the com.rdocker.doctor LaunchDaemon (share/install-doctor-mac.sh).
# Every tick applies the rules below; each one is idempotent and logs one line per action to
# ~rd/rr/log/doctor.log:  `<ISO ts> <rule> <action> <target> <detail...>`
# (dry run: action = would-<action>; skip = an action withheld on purpose, e.g. a reused pid).
#
#  orphan-slot       slots/<n>.who whose pid is dead AND whose slot lock is free -> remove the .who (and
#                    its .own). Checked and removed while holding that slot's flock, so a runner can
#                    never take the slot in between. A lock file is never unlinked.
#  hung-job          a held slot whose .who start is older than its class hard cap + DOCTOR_GRACE_S ->
#                    TERM the runner and its command's process group(s), KILL what is left after
#                    DOCTOR_TERM_WAIT_S, confirm everything is gone. Identity first: the pid must belong to
#                    rd, look like the runner, and have started no later than the .who epoch (a reused
#                    pid started later), else `skip`. Signals are sent as rd (runuser), never as root.
#  orphan-container  containers with the run label (rdocker.rrun=<token>) whose run is gone, created more
#                    than DOCTOR_CT_MIN_AGE_S ago -> docker rm -f -v. Never one with any rdocker.keep
#                    label or without the run label. "Gone" = no live run owns the token (see CT_PL).
#  reporter          rd-reporter not active -> restart (Linux user unit; macOS launchctl kickstart when the
#                    com.rdocker.reporter label is loaded). At most once per 5 min.
#  drain             >= DOCTOR_INFRA_N infrastructure failures (outcome=lost rc=N | deps-failed | rc=134) in the
#                    last DOCTOR_INFRA_WINDOW_S of runs.log, or memory / disk critical -> drain: write the
#                    drain marker and slots.cap = 0 (the runner and the pool probe then admit nothing; jobs
#                    already running are untouched). Re-open after DOCTOR_REOPEN_OK healthy ticks in a
#                    row: remove the marker and restore the slots.cap from before the drain.
#                    macOS: rows logged within DOCTOR_WAKE_GRACE_S of the last wake or boot are not counted -
#                    a lid close cuts every running job (no heartbeat while asleep), and each one is logged
#                    `lost rc=N` at once on wake; that is the sleep, not a sick worker.
#  disk              ~/rr (and /var/lib/docker) below DOCTOR_DISK_CRIT_PCT % free -> a `critical` line
#                    (at most every 10 min). rd-tune owns pruning; the doctor never deletes data.
#  colima            macOS only: rd's Colima socket is there but `docker info` has not answered for
#                    DOCTOR_COLIMA_BAD_N ticks in a row (a VM that came back wedged from sleep), no slot is
#                    held and no start/stop holds ~/rr/colima.lock -> `colima stop --force` (at most every
#                    10 min), run while holding every slot's lock (a job that took a slot meanwhile = skip).
#                    Never starts it: the next job that needs Docker starts it fresh.
#  spotlight         macOS only: ~/rr a real directory -> while no slot is held and no runner runs, move it
#                    to ~/rr.noindex and leave the symlink ~/rr -> rr.noindex (Spotlight skips *.noindex).
#
# Slot cap precedence (one writer per input, the runner and probe take the minimum of all):
#   owner share switch (off/some/max, never written here) > doctor drain (cap 0) > rd-tune live cap > fleet slots.
#   The drain marker (DRAIN, below) is the doctor's alone. rd-tune writes slots.cap = 0 while the marker is
#   fresh (touched in the last 5 min: a doctor that died or was disabled can never hold a worker drained),
#   so the two never fight. macOS has no rd-tune: the doctor itself restores the old cap.
#
# Status (read by the reporter / steward; written every tick, 0644, atomic):
#   Linux /run/rdocker/doctor, macOS ~/rr/state/doctor.json - one JSON object:
#   {"v":1,"os":"linux|darwin","ts":<epoch>,"disabled":bool,"dry":bool,"drained":bool,
#    "drain_since":<epoch>|null,"drain_reason":"<str>","ok_streak":<n>,"infra_recent":<n>,
#    "mem_free_pct":<n>|null,"disk_free_pct":<n>|null,"actions_1h":<n>,"last_action":"<doctor.log line>"}
#
# Kill switch: DOCTOR_DISABLE=1 in /etc/rdocker/doctor.conf (lifts its own drain, then does nothing).
# Dry run: RD_DOCTOR_DRY=1 (or DOCTOR_DRY=1 in doctor.conf): every action is only logged as would-<action>.
# Rules on/off: DOCTOR_RULES (space list of the rule names above). Thresholds: the DOCTOR_* defaults below.
# `rd-doctor --lift` removes a doctor drain now (an uninstall runs it); `--source` only defines the functions.
# Test hooks (env): RD_OS (linux|darwin), RD_DOCTOR_CONF, RD_CONF (tune.conf), RD_RR_ROOT, RD_STATE_DIR,
# RD_DOCTOR_STATUS, RD_DRAIN_FILE, RD_PS_CMD (an executable printing what `ps -A -o pid=,ppid=,pgid=,uid=,
# etime=,stat=,args=` prints), RD_DOCKER (docker binary), RD_MEMINFO, RD_MEM_PCT, RD_DF_CMD (prints what
# `df -Pk <path>` does), RD_NO_SERVICES=1 (no reporter rule), RD_DOCTOR_DRY, RD_WAKE_TIME (epoch of the last
# wake), RD_COLIMA (colima binary), RD_COLIMA_SOCK (rd's Colima docker socket).
set -u
OS=$(printf '%s' "${RD_OS:-$(uname -s)}" | tr '[:upper:]' '[:lower:]')
CONF="${RD_DOCTOR_CONF:-/etc/rdocker/doctor.conf}"
TUNE_CONF="${RD_CONF:-/etc/rdocker/tune.conf}"
if [ "$OS" = linux ]; then
  RD_USER=rd
  [ -r "$TUNE_CONF" ] && { _u=$(sed -n 's/^RD_USER=//p' "$TUNE_CONF" | head -1); [ -n "$_u" ] && RD_USER=$_u; }
else
  RD_USER=$(id -un)   # the LaunchDaemon runs as rd
fi
DOCTOR_DISABLE=0 DOCTOR_DRY=0
DOCTOR_RULES="orphan-slot hung-job orphan-container reporter drain disk colima spotlight"
DOCTOR_CAPS="light=1800 normal=1800 heavy=3600 db=5400 build=3600"   # s; = rd_run TIMEOUT_MIN
DOCTOR_GRACE_S=300 DOCTOR_TERM_WAIT_S=10 DOCTOR_START_SLOP_S=5
DOCTOR_CT_MIN_AGE_S=120 DOCTOR_SHIM_WINDOW_S=600
DOCTOR_INFRA_N=3 DOCTOR_INFRA_WINDOW_S=300 DOCTOR_REOPEN_OK=3 DOCTOR_WAKE_GRACE_S=300 DOCTOR_COLIMA_BAD_N=2
DOCTOR_MEM_CRIT_PCT=5 DOCTOR_DISK_DRAIN_PCT=5 DOCTOR_DISK_CRIT_PCT=10
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
[ -n "${RD_DOCTOR_DRY:-}" ] && DOCTOR_DRY=$RD_DOCTOR_DRY

user_home() { if [ "$OS" = linux ]; then getent passwd "$RD_USER" 2>/dev/null | cut -d: -f6; else echo "$HOME"; fi; }
RR="${RD_RR_ROOT:-$(user_home)/rr}"
if [ "$OS" = linux ]; then
  STATUS="${RD_DOCTOR_STATUS:-/run/rdocker/doctor}"
  DRAIN="${RD_DRAIN_FILE:-/run/rdocker/drain}"
  STATE="${RD_STATE_DIR:-/run/rdocker-doctor}"
else
  STATUS="${RD_DOCTOR_STATUS:-$RR/state/doctor.json}"
  DRAIN="${RD_DRAIN_FILE:-$RR/state/drain}"
  STATE="${RD_STATE_DIR:-$HOME/.local/state/rdocker-doctor}"
fi
LOG="$RR/log/doctor.log"
CAP_FILE="$RR/slots.cap"
RD_UID=$(id -u "$RD_USER" 2>/dev/null || echo -1)
RD_GID=$(id -g "$RD_USER" 2>/dev/null || echo -1)
NOW=$(date +%s)

is_dry() { [ "$DOCTOR_DRY" = 1 ]; }
rule_on() { case " $DOCTOR_RULES " in *" $1 "*) return 0 ;; esac; return 1; }
am_root() { [ "$(id -u)" = 0 ]; }

# ------------------------------------------------------------------------------------------- logging
# Append one line to doctor.log without ever following a planted symlink/hardlink (~/rr is rd-writable and
# the Linux doctor is root); rotated to doctor.log.1 past 1 MB; 0600, owned by rd.
# shellcheck disable=SC2016  # Perl, expanded by perl
APPEND_PL='
use strict; use warnings; use Fcntl qw(O_WRONLY O_APPEND O_CREAT O_NOFOLLOW);
my ($f, $line, $uid, $gid) = @ARGV;
(my $d = $f) =~ s{/[^/]+$}{};
exit 0 if -l $d;
if (!-d $d) { mkdir $d, 0700 or exit 0; chown $uid, $gid, $d if $< == 0 && $uid >= 0 }
my @st = lstat $f;
rename $f, "$f.1" if @st && -f _ && $st[7] > 1_000_000;
@st = lstat $f;
unlink $f if @st && (!-f _ || $st[3] != 1);
sysopen(my $fh, $f, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600) or exit 0;
print {$fh} "$line\n";
close $fh;
chown $uid, $gid, $f if $< == 0 && $uid >= 0;
'
ACTION_VERBS=" remove kill rm restart drain undrain move stop "
logl() {   # rule action target detail...
  local line
  line="$(date +%Y-%m-%dT%H:%M:%S%z) $1 $2 $3${4:+ ${*:4}}"
  echo "$line"
  perl -e "$APPEND_PL" "$LOG" "$line" "$RD_UID" "$RD_GID" 2>/dev/null
  case "$ACTION_VERBS" in *" $2 "*) mkdir -p "$STATE" && echo "$NOW $line" >> "$STATE/actions" ;; esac
}
act() {    # rule verb target detail...: true when the action may go ahead; a dry run logs would-<verb>
  if is_dry; then logl "$1" "would-$2" "$3" "${@:4}"; return 1; fi
}

cooldown_ok() {   # $1 = name, $2 = seconds (default 300); true when not acted on within that long (then stamps it)
  local f="$STATE/cd-$1" gap=${2:-300}
  mkdir -p "$STATE"
  [ -f "$f" ] && [ $(( NOW - $(cat "$f" 2>/dev/null || echo 0) )) -lt "$gap" ] && return 1
  echo "$NOW" > "$f"
}

as_rd() {   # run a command as rd (a kill can then only ever reach rd's own processes)
  if am_root && [ "$RD_USER" != root ]; then runuser -u "$RD_USER" -- "$@"; else "$@"; fi
}

# -------------------------------------------------------------------------------------- processes
# One snapshot: "pid ppid pgid uid start_epoch args..." per live process (start from etime, 1 s resolution;
# zombies are dropped: they hold nothing and are gone as far as any rule cares).
ps_snap() {
  local now; now=$(date +%s)
  { if [ -n "${RD_PS_CMD:-}" ]; then "$RD_PS_CMD"; else ps -A -o pid=,ppid=,pgid=,uid=,etime=,stat=,args= 2>/dev/null; fi; } |
    awk -v now="$now" '
      function secs(e,   d, n, a, i, s, x) {
        d = 0; if (index(e, "-")) { split(e, x, "-"); d = x[1]; e = x[2] }
        n = split(e, a, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i]
        return d * 86400 + s }
      $1 ~ /^[0-9]+$/ && $5 ~ /^[0-9:-]+$/ && $6 !~ /^Z/ {
        l = $1 " " $2 " " $3 " " $4 " " (now - secs($5)); for (i = 7; i <= NF; i++) l = l " " $i; print l }'
}

descendants() {   # $1 pid; snapshot on stdin -> "pid pgid uid" of every descendant
  awk -v root="$1" '
    { pg[$1] = $3; u[$1] = $4; kids[$2] = kids[$2] " " $1 }
    END { q = root; seen[root] = 1
      while (q != "") { n = split(q, a, " "); q = ""
        for (i = 1; i <= n; i++) { m = split(kids[a[i]], k, " ")
          for (j = 1; j <= m; j++) if (!(k[j] in seen)) { seen[k[j]] = 1; print k[j], pg[k[j]], u[k[j]]; q = q " " k[j] } } } }'
}

# --------------------------------------------------------------------------------- slots (a + jobs)
# For every slot: under its flock (non-blocking), a .who whose pid is dead is removed (with the .who's
# .own); a held slot prints "JOB <n> <pid> <epoch> <cls> <cap_s> <label> <slug>" for the hung-job and
# orphan-container rules. .who = "<slug> <epoch> <pid> [<wt12>] [k=v ...]" (4 fields today; a 5th bare
# class word or k=v tokens cls=/cap_s=/timeout_s=/label= are read when present). .own (tab-separated
# k=v, written by the runner) adds cls/class, cap_s/timeout_s/timeout/cap, label - only when its pid=
# matches the .who pid. Missing fields print "-".
# shellcheck disable=SC2016  # Perl, expanded by perl
SLOTS_PL='
use strict; use warnings; use Fcntl qw(:flock O_RDWR O_RDONLY O_NOFOLLOW); use POSIX ();
my ($R, $reap, $dry) = @ARGV;
my $d = "$R/slots";
exit 0 if -l $d || !-d $d;
opendir(my $dh, $d) or exit 0;
my %ids = map { /^(\d+)(?:\.who)?$/ ? ($1 => 1) : () } readdir $dh;
sub slurp { my ($p) = @_; return "" if -l $p; sysopen(my $f, $p, O_RDONLY | O_NOFOLLOW) or return ""; local $/; my $s = <$f> // ""; close $f; $s }
sub alive { my ($p) = @_; return 0 unless defined $p && $p =~ /^\d+$/ && $p > 1; kill(0, $p) ? 1 : $!{EPERM} ? 1 : 0 }
for my $n (sort { $a <=> $b } keys %ids) {
    my $wf = "$d/$n.who";
    next if -l $wf || !-f $wf;
    my $who = (slurp($wf) =~ /^([^\n]*)/)[0] // "";
    my @f = split " ", $who;
    my ($slug, $epoch, $pid) = @f[0 .. 2];
    my %x;
    for my $t (@f[3 .. $#f]) {
        if ($t =~ /^([a-z_]+)=([A-Za-z0-9._:-]*)$/) { $x{$1} = $2 }
        elsif ($t =~ /^(light|normal|heavy|db|build)$/) { $x{cls} = $1 }
    }
    my %o = map { /^([a-z_]+)=(.*)$/ ? ($1 => $2) : () } split /\t/, ((slurp("$d/$n.own") =~ /^([^\n]*)/)[0] // "");
    if (defined $o{pid} && defined $pid && $o{pid} eq $pid) { $x{$_} //= $o{$_} for keys %o }
    my $cls = $x{cls} // $x{class} // "-";
    my ($cap) = grep { defined && /^\d+$/ } @x{qw(cap_s timeout_s timeout cap)};
    my $label = $x{label} // "-";
    $cls = "-" unless $cls =~ /^[a-z]+$/;
    $label = "-" unless $label =~ /^[0-9a-f]{8,64}$/;
    $slug = "-" unless defined $slug && $slug =~ /^[A-Za-z0-9._-]+$/;
    my $held = 0; my $fh;
    if (-e "$d/$n" && !-l "$d/$n") {
        if (sysopen($fh, "$d/$n", O_RDWR | O_NOFOLLOW)) { $held = flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1 }
    }
    if ($held) {
        printf "JOB %s %s %s %s %s %s %s\n", $n, (defined $pid && $pid =~ /^\d+$/ ? $pid : "-"),
            (defined $epoch && $epoch =~ /^\d+$/ ? $epoch : "-"), $cls, $cap // "-", $label, $slug;
        next;
    }
    next if alive($pid) || !$reap;           # a free slot whose pid lives: leave it (the runner is in finish)
    my $p = defined $pid && $pid =~ /^\d+$/ ? $pid : "-";
    if ($dry) { print "ORPHAN $n $p $slug would\n"; next }
    # re-read under the lock: remove only the .who we judged
    next unless ((slurp($wf) =~ /^([^\n]*)/)[0] // "") eq $who;
    unlink $wf;
    my %o2 = map { /^([a-z]+)=(.*)$/ ? ($1 => $2) : () } split /\t/, ((slurp("$d/$n.own") =~ /^([^\n]*)/)[0] // "");
    unlink "$d/$n.own" if -f "$d/$n.own" && !-l "$d/$n.own" && (!defined $o2{pid} || !alive($o2{pid}));
    print "ORPHAN $n $p $slug removed\n";
}
'

cap_for() {   # $1 class ("-" = unknown) -> hard cap seconds (unknown class: the longest cap)
  local kv k v best=0
  for kv in $DOCTOR_CAPS; do
    k=${kv%%=*}; v=${kv#*=}
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "$k" = "$1" ] && { echo "$v"; return; }
    [ "$v" -gt "$best" ] && best=$v
  done
  echo "$best"
}

SLOT_OUT=""
rule_slots() {   # orphan-slot (when on) + collect the held jobs for hung-job / orphan-container
  local reap=0 line
  rule_on orphan-slot && reap=1
  SLOT_OUT=$(perl -e "$SLOTS_PL" "$RR" "$reap" "$( is_dry && echo 1 || echo 0 )" 2>/dev/null)
  while read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    [ "${1:-}" = ORPHAN ] || continue
    if [ "$5" = would ]; then logl orphan-slot would-remove "slot:$2" "pid=$3 repo=$4 (pid dead, lock free)"
    else logl orphan-slot remove "slot:$2" "pid=$3 repo=$4 (pid dead, lock free: stale .who removed)"; fi
  done <<< "$SLOT_OUT"
}

# ------------------------------------------------------------------------------------- hung jobs (b)
alive_any() {   # $1 = space list of pids, $2 = space list of pgids; true while any still exists
  local snap; snap=$(ps_snap)
  awk -v pids=" $1 " -v pgs=" $2 " 'index(pids, " " $1 " ") || index(pgs, " " $3 " ") { found = 1 } END { exit !found }' <<< "$snap"
}

rule_hung() {
  local line n pid epoch cls capf slug cap age snap row puid pstart args groups singles g d dp dg du t waited result sig
  local -a jobs=()
  while read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    [ "${1:-}" = JOB ] || continue
    n=$2 pid=$3 epoch=$4 cls=$5 capf=$6 slug=$8
    case "$pid$epoch" in *-*) continue ;; esac
    if [ "$capf" != - ]; then
      [ "$capf" = 0 ] && continue          # the job asked for no cap (RRUN_TIMEOUT=0)
      cap=$capf
    else cap=$(cap_for "$cls"); fi
    age=$(( NOW - epoch ))
    [ "$age" -gt $(( cap + DOCTOR_GRACE_S )) ] || continue
    snap=${snap:-$(ps_snap)}
    row=$(awk -v p="$pid" '$1 == p' <<< "$snap")
    [ -n "$row" ] || continue               # gone already
    puid=$(awk '{ print $4 }' <<< "$row"); pstart=$(awk '{ print $5 }' <<< "$row")
    args=$(cut -d' ' -f6- <<< "$row")
    if [ "$puid" != "$RD_UID" ]; then logl hung-job skip "slot:$n" "pid=$pid uid=$puid is not $RD_USER"; continue; fi
    if [ "$pstart" -gt $(( epoch + DOCTOR_START_SLOP_S )) ]; then
      logl hung-job skip "slot:$n" "pid=$pid started $(( pstart - epoch ))s after the .who epoch (reused pid)"; continue
    fi
    case "$args" in *rrun-runner*|*perl*) ;; *) logl hung-job skip "slot:$n" "pid=$pid is not a runner"; continue ;; esac
    # whole tree: process groups led by a descendant (the command: the runner setsid()s it) + the rest by pid
    groups="" singles="$pid"
    [ "$(awk '{ print $3 }' <<< "$row")" = "$pid" ] && { groups="$pid"; singles=""; }
    while read -r d dg du; do
      [ -n "$d" ] && [ "$du" = "$RD_UID" ] || continue
      if [ "$dg" = "$d" ]; then groups="$groups $d"
      else case " $groups " in *" $dg "*) ;; *) singles="$singles $d" ;; esac; fi
    done < <(descendants "$pid" <<< "$snap")
    if ! act hung-job kill "slot:$n" "pid=$pid repo=$slug age=${age}s cap=${cap}s cls=$cls"; then continue; fi
    jobs+=("$n|$pid|$slug|$age|$cap|$cls|$groups|$singles")
    t=""
    for g in $groups; do t="$t -$g"; done
    # shellcheck disable=SC2086
    as_rd kill -s TERM -- $t $singles 2>/dev/null
  done <<< "$SLOT_OUT"
  [ ${#jobs[@]} -gt 0 ] || return 0
  local all_p="" all_g="" j
  for j in "${jobs[@]}"; do IFS='|' read -r _ dp _ _ _ _ dg du <<< "$j"; all_p="$all_p $dp $du"; all_g="$all_g $dg"; done
  waited=0
  while [ "$waited" -lt "$DOCTOR_TERM_WAIT_S" ] && alive_any "$all_p" "$all_g"; do sleep 1; waited=$((waited + 1)); done
  for j in "${jobs[@]}"; do
    IFS='|' read -r n pid slug age cap cls groups singles <<< "$j"
    sig=TERM
    if alive_any "$singles" "$groups"; then
      sig=KILL
      t=""; for g in $groups; do t="$t -$g"; done
      local others; others=$(tr ' ' '\n' <<< "$singles" | grep -vx "$pid" | tr '\n' ' ')
      # shellcheck disable=SC2086
      [ -n "${t// /}${others// /}" ] && as_rd kill -s KILL -- $t $others 2>/dev/null
      # the runner itself gets 5 s to clean up (slot, runs.log) after its command is gone
      waited=0; while [ "$waited" -lt 5 ] && alive_any "$pid" ""; do sleep 1; waited=$((waited + 1)); done
      alive_any "$pid" "" && as_rd kill -s KILL -- "$pid" 2>/dev/null
    fi
    waited=0; while [ "$waited" -lt 5 ] && alive_any "$singles" "$groups"; do sleep 1; waited=$((waited + 1)); done
    if alive_any "$singles" "$groups"; then result=survived; else result=gone; fi
    groups=$(echo $groups | tr ' ' ','); [ -n "$groups" ] || groups=-
    logl hung-job kill "slot:$n" "pid=$pid repo=$slug age=${age}s cap=${cap}s cls=$cls groups=$groups signal=$sig result=$result"
  done
}

# ------------------------------------------------------------------------------- orphan containers (c)
docker_bin() {   # the engine the runner's shim talks to; empty when there is none to ask
  if [ -n "${RD_DOCKER:-}" ]; then [ -x "$RD_DOCKER" ] && echo "$RD_DOCKER"; return; fi
  if [ "$OS" = linux ]; then [ -x /usr/bin/docker ] && echo /usr/bin/docker; return; fi
  # macOS: only rd's own Colima (never start it, never another engine)
  [ -S "$HOME/.colima/default/docker.sock" ] && [ -x /opt/homebrew/bin/docker ] && echo /opt/homebrew/bin/docker
}
dk() {   # docker with a 20 s limit (macOS has no timeout(1))
  local b; b=$(docker_bin) || return 1; [ -n "$b" ] || return 1
  if [ -z "${RD_DOCKER:-}" ] && [ "$OS" != linux ]; then
    DOCKER_HOST="unix://$HOME/.colima/default/docker.sock" perl -e 'alarm shift; exec @ARGV' 20 "$b" "$@"
  else perl -e 'alarm shift; exec @ARGV' 20 "$b" "$@"; fi
}

# A token is live when a held slot's .own names it (label=, exact), or when a run's docker shim
# (~/rr/tmp/run-*/docker, LABEL='rdocker.rrun=<token>', written right after the runner takes its slot) was
# written within DOCTOR_SHIM_WINDOW_S of a held slot's .who epoch. Over-matching only keeps a container
# one more tick; nothing else is "live". stdin: docker ps lines "<id>\t<created>\t<labels>".
# Prints "ORPHAN <id> <token> <age_s>" / "KEEP <id>" / "YOUNG <id>" / "LIVE <id>".
# shellcheck disable=SC2016  # Perl, expanded by perl
CT_PL='
use strict; use warnings; use Time::Local qw(timegm); use Fcntl qw(O_RDONLY O_NOFOLLOW);
my ($R, $win, $now, $minage, @jobs) = @ARGV;
my (%live, @epochs);
for (@jobs) { my ($e, $l) = split /:/; push @epochs, $e if $e =~ /^\d+$/; $live{$l} = 1 if $l =~ /^[0-9a-f]+$/ }
if (!-l "$R/tmp" && opendir(my $td, "$R/tmp")) {
    for my $r (grep { /^run-/ } readdir $td) {
        my $s = "$R/tmp/$r/docker";
        next if -l $s || -l "$R/tmp/$r";
        my @st = stat $s or next;
        sysopen(my $f, $s, O_RDONLY | O_NOFOLLOW) or next;
        local $/; my $txt = <$f> // ""; close $f;
        my ($tok) = $txt =~ /LABEL\s*=\s*.rdocker\.rrun=([0-9a-f]+)/ or next;   # the shim says: my $LABEL = <quote>rdocker.rrun=<t><quote>;
        $live{$tok} = 1 if grep { abs($st[9] - $_) <= $win } @epochs;
    }
}
while (my $l = <STDIN>) {
    chomp $l;
    my ($id, $created, $labels) = split /\t/, $l, 3;
    next unless defined $labels && $id =~ /^[0-9a-f]{6,64}$/;
    my ($tok) = ",$labels," =~ /,rdocker\.rrun=([0-9a-f]+),/ or next;   # run label required
    if (",$labels" =~ /,rdocker\.keep=/) { print "KEEP $id\n"; next }    # any keep value: never
    my ($y, $mo, $d, $h, $mi, $s, $sg, $oh, $om) =
        $created =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)(?:\.\d+)?\s*(?:([+-])(\d\d):?(\d\d)|Z)?/ or next;
    my $t = timegm($s, $mi, $h, $d, $mo - 1, $y) - (defined $sg ? ($sg eq "-" ? -1 : 1) * ($oh * 3600 + $om * 60) : 0);
    my $age = $now - $t;
    if ($age < $minage) { print "YOUNG $id\n"; next }
    if ($live{$tok}) { print "LIVE $id\n"; next }
    print "ORPHAN $id $tok $age\n";
}
'

rule_containers() {
  local out jobs=() line id tok age
  [ -n "$(docker_bin)" ] || return 0
  out=$(dk ps -a --no-trunc --filter label=rdocker.rrun --format '{{.ID}}	{{.CreatedAt}}	{{.Labels}}' 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  while read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    [ "${1:-}" = JOB ] && jobs+=("$4:$7")
  done <<< "$SLOT_OUT"
  while read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    [ "${1:-}" = ORPHAN ] || continue
    id=$2 tok=$3 age=$4
    act orphan-container rm "${id:0:12}" "run=${tok:0:12} age=${age}s (no live run)" || continue
    if dk rm -f -v "$id" >/dev/null 2>&1; then logl orphan-container rm "${id:0:12}" "run=${tok:0:12} age=${age}s (no live run)"
    else logl orphan-container failed "${id:0:12}" "docker rm -f -v failed"; fi
  done < <(printf '%s\n' "$out" | perl -e "$CT_PL" "$RR" "$DOCTOR_SHIM_WINDOW_S" "$NOW" "$DOCTOR_CT_MIN_AGE_S" ${jobs[@]+"${jobs[@]}"})
}

# ------------------------------------------------------------------------------------- reporter (d)
rule_reporter() {
  [ -z "${RD_NO_SERVICES:-}" ] || return 0
  if [ "$OS" = linux ]; then
    local home unit
    home=$(dirname "$RR"); unit="$home/.config/systemd/user/rd-reporter.service"
    [ -f "$unit" ] || return 0                                    # not installed here
    uctl() { if am_root; then runuser -u "$RD_USER" -- env XDG_RUNTIME_DIR="/run/user/$RD_UID" systemctl --user "$@"
             else systemctl --user "$@"; fi; }
    uctl is-active --quiet rd-reporter.service 2>/dev/null && return 0
    cooldown_ok reporter 300 || return 0
    act reporter restart rd-reporter "user unit not active" || return 0
    if am_root && [ ! -S "/run/user/$RD_UID/bus" ]; then systemctl start "user@$RD_UID.service" 2>/dev/null; fi
    if uctl restart rd-reporter.service 2>/dev/null; then logl reporter restart rd-reporter "user unit was not active"
    else logl reporter failed rd-reporter "systemctl --user restart failed"; fi
  else
    local dom out
    for dom in "gui/$RD_UID" "user/$RD_UID"; do
      out=$(launchctl print "$dom/com.rdocker.reporter" 2>/dev/null) || continue
      grep -q 'state = running' <<< "$out" && return 0
      cooldown_ok reporter 300 || return 0
      act reporter restart "$dom/com.rdocker.reporter" "not running" || return 0
      if launchctl kickstart "$dom/com.rdocker.reporter" >/dev/null 2>&1; then logl reporter restart "$dom/com.rdocker.reporter" "was not running"
      else logl reporter failed "$dom/com.rdocker.reporter" "launchctl kickstart failed"; fi
      return 0
    done
  fi
}

# ------------------------------------------------------------------------------------ health / drain (e)
mem_free_pct() {   # empty when unknown
  if [ -n "${RD_MEM_PCT:-}" ]; then echo "$RD_MEM_PCT"; return; fi
  if [ "$OS" = linux ]; then
    awk '$1 == "MemTotal:" { t = $2 } $1 == "MemAvailable:" { a = $2 } END { if (t > 0 && a != "") printf "%d\n", a * 100 / t }' "${RD_MEMINFO:-/proc/meminfo}" 2>/dev/null
  else sysctl -n kern.memorystatus_level 2>/dev/null; fi
}
disk_free_pct() {  # $1 path -> free %; empty when unknown
  ${RD_DF_CMD:-df -Pk} "$1" 2>/dev/null | awk 'NR == 2 && $2 > 0 { printf "%d\n", $4 * 100 / $2 }'
}
# runs.log lines of the last <window> s that failed for an infrastructure reason (not the command's own rc)
# shellcheck disable=SC2016  # Perl, expanded by perl
INFRA_PL='
use strict; use warnings; use Time::Local qw(timegm); use Fcntl qw(O_RDONLY O_NOFOLLOW);
my ($f, $now, $win, $floor) = @ARGV;
sysopen(my $fh, $f, O_RDONLY | O_NOFOLLOW) or do { print "0\n"; exit 0 };
my $sz = -s $fh || 0; seek($fh, $sz > 262144 ? $sz - 262144 : 0, 0);
my $n = 0;
while (my $l = <$fh>) {
    my ($y, $mo, $d, $h, $mi, $s, $sg, $oh, $om) = $l =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)([+-])(\d\d):?(\d\d)\s/ or next;
    my $t = timegm($s, $mi, $h, $d, $mo - 1, $y) - ($sg eq "-" ? -1 : 1) * ($oh * 3600 + $om * 60);
    next if $now - $t > $win || $t - $now > 60 || $t < ($floor || 0);
    # truthful labels (2026-11-11): only a STARTED run lost for good is "lost rc=N"; a bare "lost" is the
    # old label of a client that left before the start (now abandoned-setup / moved): not a worker fault
    $n++ if $l =~ /\soutcome=(?:lost rc=\d+|deps-failed)\s/ || $l =~ /\soutcome=(?:[a-z]+ )?rc=134\b/;
}
print "$n\n";
'

write_cap() {   # atomic, only when changed; owned by rd (same as rd-tune's write_cap)
  local want=$1 dir tmp
  [ "$(cat "$CAP_FILE" 2>/dev/null)" = "$want" ] && return 0
  dir=$(dirname "$CAP_FILE"); mkdir -p "$dir"
  tmp=$(mktemp "$dir/.slots.cap.XXXXXX") && echo "$want" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$CAP_FILE"
  am_root && chown -h "$RD_USER": "$CAP_FILE" 2>/dev/null
  return 0
}
drain_field() { sed -n "s/^$1=//p" "$DRAIN" 2>/dev/null | head -1; }

drain_on() {   # $1 reason
  local prev tmp
  prev=$(sed -n '1s/^\([0-9][0-9]*\).*/\1/p' "$CAP_FILE" 2>/dev/null); [ -n "$prev" ] || prev=none
  act drain drain worker "$1 (slots.cap $prev -> 0)" || return 0
  mkdir -p "$(dirname "$DRAIN")"
  tmp="$DRAIN.tmp.$$"
  printf 'since=%s\nreason=%s\nprev=%s\n' "$NOW" "$1" "$prev" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$DRAIN"
  write_cap 0
  logl drain drain worker "$1 (slots.cap $prev -> 0)"
}
drain_off() {   # $1 why
  local prev
  [ -f "$DRAIN" ] || return 0
  prev=$(drain_field prev)
  act drain undrain worker "$1 (slots.cap -> ${prev:-none})" || return 0
  rm -f "$DRAIN"
  case "$prev" in
    ''|none) [ "$(cat "$CAP_FILE" 2>/dev/null)" = 0 ] && rm -f "$CAP_FILE" ;;
    *[!0-9]*) ;;
    *) write_cap "$prev" ;;
  esac
  echo 0 > "$STATE/ok_streak"
  logl drain undrain worker "$1 (slots.cap -> ${prev:-none})"
}

# macOS: epoch before which runs.log rows are the last sleep's own losses (last wake or boot + the grace);
# 0 elsewhere. RD_WAKE_TIME (tests) stands in for sysctl's kern.waketime / kern.boottime.
infra_floor() {
  local w
  [ "$OS" = darwin ] || { echo 0; return; }
  w=${RD_WAKE_TIME:-$(sysctl -n kern.waketime kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p' | sort -n | tail -1)}
  case "$w" in ''|*[!0-9]*) echo 0 ;; *) echo $(( w + DOCTOR_WAKE_GRACE_S )) ;; esac
}

INFRA="" MEMP="" DISKP=""
rule_drain() {
  local why="" streak
  INFRA=$(perl -e "$INFRA_PL" "$RR/log/runs.log" "$NOW" "$DOCTOR_INFRA_WINDOW_S" "$(infra_floor)" 2>/dev/null)
  [ "${INFRA:-0}" -ge "$DOCTOR_INFRA_N" ] 2>/dev/null && why="infra=${INFRA}/${DOCTOR_INFRA_WINDOW_S}s"
  [ -n "$MEMP" ] && [ "$MEMP" -lt "$DOCTOR_MEM_CRIT_PCT" ] 2>/dev/null && why="${why:+$why,}mem_free=${MEMP}%"
  [ -n "$DISKP" ] && [ "$DISKP" -lt "$DOCTOR_DISK_DRAIN_PCT" ] 2>/dev/null && why="${why:+$why,}disk_free=${DISKP}%"
  mkdir -p "$STATE"
  if [ -n "$why" ]; then
    echo 0 > "$STATE/ok_streak"
    if [ -f "$DRAIN" ]; then is_dry || { touch "$DRAIN"; write_cap 0; }
    else drain_on "$why"; fi
    return 0
  fi
  [ -f "$DRAIN" ] || { echo 0 > "$STATE/ok_streak"; return 0; }
  streak=$(( $(cat "$STATE/ok_streak" 2>/dev/null || echo 0) + 1 ))
  echo "$streak" > "$STATE/ok_streak"
  if [ "$streak" -ge "$DOCTOR_REOPEN_OK" ]; then drain_off "healthy $streak checks in a row"
  else is_dry || { touch "$DRAIN"; write_cap 0; }; fi
}

# ---------------------------------------------------------------------------------------- disk (f)
rule_disk() {
  local p pct
  for p in "$RR" /var/lib/docker; do
    [ "$p" = /var/lib/docker ] && { [ "$OS" = linux ] && [ -d "$p" ] && [ -z "${RD_RR_ROOT:-}" ] || continue; }
    pct=$(disk_free_pct "$p"); [ -n "$pct" ] || continue
    [ "$pct" -lt "$DOCTOR_DISK_CRIT_PCT" ] || continue
    cooldown_ok "disk-$(echo "$p" | tr '/' '_')" 600 || continue
    logl disk critical "$p" "free=${pct}% (< ${DOCTOR_DISK_CRIT_PCT}%: rd-tune's prune did not keep up)"
  done
}

# Prologue of the two rules that act only while NO run can start: take every slot's flock (non-blocking;
# fds are close-on-exec) or print "BUSY <slot>" and exit. $R = $ARGV[0]. The locks hold until perl exits.
# shellcheck disable=SC2016  # Perl, expanded by perl
HOLD_ALL_PL='
use strict; use warnings; use Fcntl qw(:flock O_RDWR O_NOFOLLOW);
my $R = $ARGV[0];
my @held;
if (opendir(my $d, "$R/slots")) {
    for my $s (grep { /^(?:\d+|heavy-\d+)$/ } readdir $d) {
        next if -l "$R/slots/$s";
        sysopen(my $fh, "$R/slots/$s", O_RDWR | O_NOFOLLOW) or next;
        flock($fh, LOCK_EX | LOCK_NB) or do { print "BUSY $s\n"; exit 0 };
        push @held, $fh;
    }
}
'
# colima: run `<colima> stop --force` (120 s limit) while holding every slot -> OK | FAILED ... | BUSY <slot>
# shellcheck disable=SC2016  # Perl, expanded by perl
COLIMA_STOP_PL=$HOLD_ALL_PL'
my $pid = fork; defined $pid or do { print "FAILED fork\n"; exit 0 };
if (!$pid) { open STDOUT, ">", "/dev/null"; open STDERR, ">&", \*STDOUT; alarm 120; exec $ARGV[1], "stop", "--force"; exit 127 }
waitpid($pid, 0);
print $? == 0 ? "OK\n" : "FAILED rc=" . ($? >> 8) . "\n";
'

# ------------------------------------------------------------------------------------- colima (macOS)
rule_colima() {
  [ "$OS" = darwin ] || return 0
  local sock="${RD_COLIMA_SOCK:-$HOME/.colima/default/docker.sock}" colima="${RD_COLIMA:-/opt/homebrew/bin/colima}"
  local bad="$STATE/colima_bad" n lock="$RR/colima.lock" out
  if ! [ -x "$colima" ] || ! [ -S "$sock" ] || dk info >/dev/null 2>&1; then rm -f "$bad"; return 0; fi
  mkdir -p "$STATE"
  n=$(( $(cat "$bad" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$bad"
  [ "$n" -ge "$DOCTOR_COLIMA_BAD_N" ] || return 0
  [ -d "$lock" ] && return 0                                  # a start or stop is under way
  grep -q '^JOB ' <<< "$SLOT_OUT" && return 0                 # a job held a slot at the tick's start
  cooldown_ok colima 600 || return 0
  if is_dry; then act colima stop colima "engine not answering for $n checks (socket there)"; return 0; fi
  mkdir "$lock" 2>/dev/null || { rm -f "$STATE/cd-colima"; return 0; }
  # the stop itself runs holding EVERY slot lock: a job that took a slot since the tick began wins (skip)
  out=$(perl -e "$COLIMA_STOP_PL" "$RR" "$colima" 2>/dev/null)
  rmdir "$lock" 2>/dev/null
  case "$out" in
    BUSY*) rm -f "$STATE/cd-colima"; return 0 ;;               # retried next tick; no cooldown spent
    OK) logl colima stop colima "engine not answering for $n checks: stopped; the next job starts it" ;;
    *) logl colima failed colima "colima stop --force: ${out:-no output}" ;;
  esac
  rm -f "$bad" "$RR/state/colima.started"
  return 0
}

# ----------------------------------------------------------------------------------- spotlight (g, macOS)
# Holds every slot's flock (and refuses when any is taken) while it renames ~/rr -> ~/rr.noindex and links
# ~/rr back, so no run can start in between; a failed link renames it back.
# shellcheck disable=SC2016  # Perl, expanded by perl
SPOT_PL=$HOLD_ALL_PL'
my $N = $ARGV[1]; my $dry = $ARGV[2];
if ($dry) { print "WOULD\n"; exit 0 }
rename($R, $N) or do { print "FAILED rename: $!\n"; exit 0 };
if (symlink((split m{/}, $N)[-1], $R)) { print "MOVED\n"; exit 0 }
my $e = "$!";
rename($N, $R);
print "FAILED symlink: $e\n";
'
rule_spotlight() {
  [ "$OS" = darwin ] || return 0
  local nidx="$RR.noindex" out
  [ -L "$RR" ] && return 0
  [ -d "$RR" ] || return 0
  if [ -e "$nidx" ] || [ -L "$nidx" ]; then
    cooldown_ok spotlight-conflict 3600 && logl spotlight skip "$RR" "both $RR and $nidx exist: left alone"
    return 0
  fi
  if ps_snap | awk '{ $1 = $2 = $3 = $4 = $5 = ""; print }' | grep -q 'rrun-runner'; then return 0; fi
  out=$(perl -e "$SPOT_PL" "$RR" "$nidx" "$( is_dry && echo 1 || echo 0 )" 2>/dev/null)
  case "$out" in
    BUSY*) ;;
    WOULD) logl spotlight would-move "$RR" "-> $nidx + symlink (no slot held)" ;;
    MOVED) logl spotlight move "$RR" "-> $nidx + symlink (Spotlight skips .noindex)" ;;
    *) logl spotlight failed "$RR" "${out:-no output}" ;;
  esac
}

# ---------------------------------------------------------------------------------------------- status
json_num() { case "${1:-}" in ''|*[!0-9]*) echo null ;; *) echo "$1" ;; esac; }
write_status() {   # $1 disabled (true|false)
  local acts=0 last="" drained=false since=null reason="" streak tmp dir
  if [ -f "$STATE/actions" ]; then
    awk -v c=$(( NOW - 3600 )) '$1 >= c' "$STATE/actions" > "$STATE/actions.tmp" 2>/dev/null && mv -f "$STATE/actions.tmp" "$STATE/actions"
    acts=$(wc -l < "$STATE/actions" | tr -d ' ')
    last=$(tail -n 1 "$STATE/actions" | cut -d' ' -f2- | tr -d '"\\' | tr -cd '[:print:]')
  fi
  if [ -f "$DRAIN" ]; then drained=true; since=$(json_num "$(drain_field since)"); reason=$(drain_field reason | tr -d '"\\'); fi
  streak=$(json_num "$(cat "$STATE/ok_streak" 2>/dev/null)"); [ "$streak" = null ] && streak=0
  dir=$(dirname "$STATUS"); mkdir -p "$dir" 2>/dev/null; [ "$OS" = linux ] && am_root && chmod 755 "$dir"
  tmp="$STATUS.tmp.$$"
  printf '{"v":1,"os":"%s","ts":%s,"disabled":%s,"dry":%s,"drained":%s,"drain_since":%s,"drain_reason":"%s","ok_streak":%s,"infra_recent":%s,"mem_free_pct":%s,"disk_free_pct":%s,"actions_1h":%s,"last_action":"%s"}\n' \
    "$OS" "$NOW" "$1" "$(is_dry && echo true || echo false)" "$drained" "$since" "$reason" "$streak" \
    "$(json_num "$INFRA")" "$(json_num "$MEMP")" "$(json_num "$DISKP")" "$acts" "$last" > "$tmp" \
    && chmod 644 "$tmp" && mv -f "$tmp" "$STATUS"
}

# ------------------------------------------------------------------------------------------------ main
take_lock() {   # one doctor at a time (a tick that kills can take ~30 s); a lock older than 5 min is stale
  mkdir -p "$STATE"
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    [ -n "$(find "$STATE/lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] || return 1
    rmdir "$STATE/lock" 2>/dev/null; mkdir "$STATE/lock" 2>/dev/null || return 1
  fi
  trap 'rmdir "$STATE/lock" 2>/dev/null' EXIT
}

main() {
  if [ "$OS" = linux ] && [ -L "$RR" ]; then   # never on Linux: refuse to act as root through a link
    echo "rd-doctor: $RR is a symlink; refusing" >&2; return 1
  fi
  take_lock || return 0
  if [ "$DOCTOR_DISABLE" = 1 ]; then
    [ -f "$DRAIN" ] && drain_off "kill switch (DOCTOR_DISABLE=1)"
    cooldown_ok disabled 3600 && logl doctor note all "disabled by DOCTOR_DISABLE=1 in $CONF"
    write_status true
    return 0
  fi
  MEMP=$(mem_free_pct); DISKP=$(disk_free_pct "$RR")
  rule_slots
  rule_on hung-job && rule_hung
  rule_on orphan-container && rule_containers
  rule_on reporter && rule_reporter
  rule_on drain && rule_drain
  rule_on disk && rule_disk
  rule_on colima && rule_colima
  rule_on spotlight && rule_spotlight
  write_status false
}

case "${1:-}" in
  --source) ;;
  --lift) take_lock || exit 1; drain_off "lifted by hand (rd-doctor --lift)"; write_status false ;;
  *) main ;;
esac
