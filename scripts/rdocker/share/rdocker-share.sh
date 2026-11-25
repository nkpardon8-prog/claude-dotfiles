#!/bin/sh
# rdocker-share - the OWNER's switch for a Mac rdocker worker: how much of this Mac the pool may use.
#
# Lends this Mac's compute to the rdocker pool (jobs run as the separate, non-admin `rd` user; nothing here
# touches your account or files). The pool reads the setting live before every job (no reinstall):
#   off                 no new jobs (running ones finish); the Docker VM stops once the worker is idle
#   low | medium | high presets: 25 % of the cores + 25 % of the memory / 75 % + 50 % / all + 75 %
#   cpu <10-100>        custom: this percent of the cores (keeps the RAM cap you have)
#   ram <1-256>         custom: jobs may use at most this many GB together (keeps the CPU share)
#   stop                off now AND stop the jobs running here (rd-worker-mac stops them within 15 s)
#   status | info | level   what it is now (info: key=value lines for the menu; level: just the word)
# The old words still work: some = medium, max = high. Whatever the setting, a new job starts only while
# macOS memory pressure is normal and free memory stays above a floor (20 % of RAM, at most 4 GB), so
# your own apps come first; running jobs are never stopped for that.
# The setting is sticky: it survives sleep, wifi changes and reboots; only this switch changes it.
# No root needed. Install: share/setup-mac-worker.sh (see share/README.md).
# Env (tests): RR_SHARE_FILE (default /Users/Shared/rdocker/share), RR_SLOTS_DIR (default /Users/rd/rr/slots),
# RR_STATUS_FILE (default: "status" next to the share file), RR_OS, RR_SYSCTL_* (see rr_runner.pl).
set -u
FILE=${RR_SHARE_FILE:-/Users/Shared/rdocker/share}
SLOTS=${RR_SLOTS_DIR:-/Users/rd/rr/slots}
STATUS=${RR_STATUS_FILE:-$(dirname "$FILE")/status}

# One perl program for every read: the share-spec block is the runner's own (rr_runner.pl; a test keeps the
# two copies identical), so this switch, the worker's runner and the pool's probe can never disagree.
# shellcheck disable=SC2016  # Perl, expanded by perl
PL='use strict; use warnings; use Fcntl;
# >>> share-spec: kept verbatim in rr_runner.pl and share/rdocker-share.sh; rd_pool.PROBE splices it from
# rr_runner.pl (tests/test_share.py fails when the copies differ). No single quotes in this block: the
# share script runs it from a quoted shell string.
#
# The share switch of the owner, one short line in the share file:
#   off | low | medium | high     presets (the old words: some = medium, max = high)
#   cpu=<10-100> ram=<1-256>      custom, either or both: the percent of the cores jobs may use, and the
#                                 most memory (GB) they may use together (no cpu= = 100, no ram= = no cap)
#   preset   cpu   RAM cap (share of the memory of this machine)
#   low       25 %   25 %
#   medium    75 %   50 %
#   high     100 %   75 %
# No file = no switch: every slot, no cap (a Linux worker, as before). A file that is not a small regular
# file, or says anything else, = off (the intent of the owner wins).
# (tables live in subs: the runner calls main() before any file-level assignment below it has run)
sub share_presets { (low => [25, 25], medium => [75, 50], high => [100, 75]) }
sub share_aliases { (some => "medium", max => "high") }
# -> undef (no file) or its text ("" when it cannot be read safely: off). Never through a symlink, never a
# FIFO or a device (opened non-blocking, must be a regular file), at most 64 bytes.
sub share_read {
    my ($f) = @_;
    my @st = lstat $f;
    return undef if !@st && $!{ENOENT};
    my ($v, $h) = ("");
    sysread($h, $v, 65) if @st && -f _ && sysopen($h, $f, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) && -f $h;
    length $v > 64 ? "" : $v;
}
# share_read text -> {level => off|low|medium|high|custom|max, cpu => percent, ram => GB, ram_pct => percent}
# (level max = no file at all). Off refuses before any cap counts: its counts stay whole (cpu 100), so the
# jobs still running there are all counted.
sub share_spec {
    my ($t) = @_;
    return { level => "max", cpu => 100 } unless defined $t;
    my ($off, %preset, %alias) = ({ level => "off", cpu => 100 }, share_presets());
    %alias = share_aliases();
    (my $s = $t) =~ s/^\s+|\s+$//g;
    $s = $alias{$s} // $s;
    return $off if $s eq "off";
    return { level => $s, cpu => $preset{$s}[0], ram_pct => $preset{$s}[1] } if $preset{$s};
    my %v;
    for (split /\s+/, $s) {
        my ($k, $n) = /^(cpu|ram)=(\d{1,3})$/ or return $off;
        return $off if exists $v{$k} || ($k eq "cpu" ? $n < 10 || $n > 100 : $n < 1 || $n > 256);
        $v{$k} = $n + 0;
    }
    %v ? { level => "custom", cpu => $v{cpu} // 100, ram => $v{ram} } : $off;
}
# share_caps(spec, slots, heavy_slots or undef, logical cpus, RAM MB) -> what the level allows:
#   slots, heavy   the fleet counts x cpu % (floor, at least 1; 0 stays 0), then at most one job per 2 GB of
#                  the RAM cap and one heavy job per 6 GB (rd_pool NEED_GB; 0 = no heavy job here)
#   cores          logical cpus x cpu % (floor, at least 1): what the jobs together may keep busy (fair_share)
#   ram_mb         the RAM cap: ram= GB, or the preset share of the machine; undef = none
#   vm_cpu, vm_mem a Colima VM: 12 CPU / 24 GB x cpu % (some = 6 / 12, max = 12 / 24, as before), never more
#                  than the cores, the RAM cap or half the machine
sub share_caps {
    my ($sp, $slots, $heavy, $ncpu, $tot) = @_;
    my $pct = $sp->{cpu};
    my $scale = sub { defined $_[0] && $_[0] > 0 ? (int($_[0] * $pct / 100) || 1) : $_[0] };
    my $ram = defined $sp->{ram} ? $sp->{ram} * 1024
            : defined $sp->{ram_pct} && $tot ? int($tot * $sp->{ram_pct} / 100) : undef;
    my %c = (slots => $scale->($slots), heavy => $scale->($heavy), ram_mb => $ram,
             cores => $ncpu ? (int($ncpu * $pct / 100) || 1) : undef);
    if (defined $ram) {
        my ($m, $hm) = (int($ram / 2048) || 1, int($ram / 6144));
        $c{slots} = $m if defined $c{slots} && $c{slots} > $m;
        $c{heavy} = $hm if defined $c{heavy} && $c{heavy} > $hm;
    }
    $c{vm_cpu} = int(12 * $pct / 100) || 1;
    $c{vm_cpu} = $c{cores} if $c{cores} && $c{vm_cpu} > $c{cores};
    $c{vm_mem} = int(24 * $pct / 100) || 1;
    for my $m ((defined $ram ? int($ram / 1024) : ()), ($tot ? int($tot / 2048) : ())) {
        $c{vm_mem} = $m if $m >= 1 && $c{vm_mem} > $m;
    }
    \%c;
}
# The memory guard: a Mac worker is a personal Mac, so a new job starts only while macOS memory pressure
# is normal and, after the need of the job (MB), free memory stays above a floor (20 % of RAM, at most 4 GB).
# -> "" (take it) or why not: "pressure" / "memory". Running jobs are never touched. Linux: always "".
# A reading that cannot be had does not block (like the need_gb gate).
sub share_floor_mb { my $f = int($_[0] / 5); $f > 4096 ? 4096 : $f }
sub share_guard {
    my ($os, $need) = @_;
    return "" if $os eq "linux";
    my ($pl) = sysctl_n("kern.memorystatus_vm_pressure_level") =~ /^(\d+)/;
    return "pressure" if defined $pl && $pl > 1;
    my ($lvl) = sysctl_n("kern.memorystatus_level") =~ /^(\d+)/;
    my ($tot) = sysctl_n("hw.memsize") =~ /^(\d+)/;
    return "" unless defined $lvl && $tot;
    my $mb = int($tot / 1048576);
    int($mb * $lvl / 100) - ($need // 0) < share_floor_mb($mb) ? "memory" : "";
}
# Memory (RSS, MB) of the processes of this user - the jobs, their DBs, a Colima VM: what counts against the RAM
# cap. undef when ps cannot be read. RR_USED_MB overrides (tests).
sub share_used_mb {
    return $ENV{RR_USED_MB} + 0 if ($ENV{RR_USED_MB} // "") =~ /^\d+$/;
    my $uid = $< + 0;
    my @kb = `/bin/ps -U $uid -o rss= 2>/dev/null` or return undef;
    my $s = 0;
    $s += $_ for map { /^\s*(\d+)/ ? $1 : 0 } @kb;
    int($s / 1024);
}
# sysctl -n <name> ("" when unknown). RR_SYSCTL_<name, dots as _> overrides (tests).
sub sysctl_n {
    (my $k = "RR_SYSCTL_$_[0]") =~ tr/./_/;
    return $ENV{$k} if defined $ENV{$k};
    my $v = `/usr/sbin/sysctl -n $_[0] 2>/dev/null`;
    defined $v ? $v : "";
}
# <<< share-spec
my ($mode, $f, $slots, $status, $arg) = @ARGV;
my $os = $ENV{RR_OS} || $^O;
my $sp = share_spec(share_read($f));
my ($ncpu) = sysctl_n("hw.logicalcpu") =~ /^(\d+)/;
($ncpu) = sysctl_n("hw.ncpu") =~ /^(\d+)/ unless $ncpu;
my ($b) = sysctl_n("hw.memsize") =~ /^(\d+)/;
my $tot = $b ? int($b / 1048576) : undef;
my $gb = sub { my $c = share_caps($_[0], 1, undef, $ncpu, $tot); defined $c->{ram_mb} ? int($c->{ram_mb} / 1024) : "" };
if ($mode eq "level") { print "$sp->{level}\n"; exit 0 }
if ($mode eq "set") {    # a custom pick: cpu=N or ram=N on top of what is set now (off / no file: medium)
    my ($k, $n) = $arg =~ /^(cpu|ram)=(\d{1,3})$/ or exit 2;
    my $base = $sp->{level} eq "off" || $sp->{level} eq "max" ? share_spec("medium") : $sp;
    my %v = (cpu => $base->{cpu}, ram => $gb->($base));
    $v{$k} = $n;
    my $line = join " ", map { "$_=$v{$_}" } grep { $v{$_} ne "" } qw(cpu ram);
    exit 2 if share_spec($line)->{level} ne "custom";    # out of range: refused, nothing written
    print "$line\n"; exit 0;
}
# jobs running here: rd-worker-mac (root) writes "jobs=N ts=EPOCH" to the status file every 15 s; else the
# slot files when this user can read them (held .who whose pid lives); "?" = not known
my $jobs = "?";
if (open(my $s, "<", $status)) {
    my $t = do { local $/; <$s> } // "";
    my ($n) = $t =~ /^jobs=(\d+)/m; my ($ts) = $t =~ /^ts=(\d+)/m;
    $jobs = $n if defined $n && $ts && abs(time - $ts) < 90;
}
if ($jobs eq "?" && opendir(my $d, $slots)) {
    $jobs = 0;
    for (grep { /\.who$/ } readdir $d) {
        open(my $w, "<", "$slots/$_") or next;
        my (undef, undef, $pid) = split " ", (<$w> // "");
        $jobs++ if defined $pid && $pid =~ /^\d+$/ && (kill(0, $pid) || $!{EPERM});
    }
}
my $guard = $sp->{level} eq "off" ? "" : share_guard($os, 2048);    # would a normal (2 GB) job start now?
my %c = %{ share_caps($sp, 1, undef, $ncpu, $tot) };
if ($mode eq "info") {
    my %p = share_presets();
    print "level=$sp->{level}\ncpu=$sp->{cpu}\nram_gb=", $gb->($sp), "\ncores=", $c{cores} // "", "\nncpu=", $ncpu // "",
        "\nmem_gb=", $tot ? int($tot / 1024) : "", "\njobs=$jobs\nguard=$guard\n";
    print "p_$_=$p{$_}[0] ", $gb->(share_spec($_)), "\n" for qw(low medium high);
    exit 0;
}
# status: plain words for a person
my $l = $sp->{level};
if ($l eq "off") { print "Sharing is OFF: no new jobs start here (running ones finish); the Docker VM stops once idle.\n" }
else {
    my $ram = $gb->($sp);
    printf "Sharing is %s: jobs may use %d %% of the cores (%s of %s)%s.\n", uc($l eq "max" ? "max" : $l), $sp->{cpu},
        $c{cores} // "?", $ncpu // "?", $ram eq "" ? " and no memory cap" : " and up to $ram GB of memory";
    print { "pressure" => "Paused for memory: macOS memory pressure is up - no new job starts here until it is normal (running ones carry on).\n",
            "memory" => "Paused for memory: free memory is under the floor - no new job starts here until your apps free some (running ones carry on).\n" }->{$guard} // "";
}
print "Jobs running now: $jobs\n" unless $jobs eq "?";
'

run() { /usr/bin/perl -e "$PL" "$1" "$FILE" "$SLOTS" "$STATUS" "${2:-}"; }

set_level() {
  dir=$(dirname "$FILE")
  if [ ! -d "$dir" ]; then mkdir -p "$dir" && chmod 755 "$dir"; fi
  tmp="$dir/.share.$$"
  printf '%s\n' "$1" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$FILE" || {
    rm -f "$tmp"; echo "rdocker share: could not write $FILE" >&2; exit 1; }
}

jobs_now() { run info | sed -n 's/^jobs=//p'; }

case "${1:-status}" in
  off|low|medium|high|some|max)
    set_level "$1"
    run status | head -1
    if [ "$1" = off ]; then j=$(jobs_now); [ "$j" != "?" ] && [ "$j" -gt 0 ] && echo "$j job(s) still running will finish."; fi
    exit 0 ;;
  cpu|ram)
    case ${2:-} in ''|*[!0-9]*) echo "usage: rdocker share $1 <number>" >&2; exit 2 ;; esac
    line=$(run set "$1=$2") || { echo "rdocker share: $1 must be $( [ "$1" = cpu ] && echo 10-100 || echo 1-256 )" >&2; exit 2; }
    set_level "$line"
    run status | head -1
    exit 0 ;;
  stop)
    set_level off
    # the root daemon rd-worker-mac sees this request and stops rd's running jobs (as the owner you cannot)
    req="$(dirname "$FILE")/stop-jobs"
    rm -f "$req" && : > "$req" && chmod 644 "$req" || { echo "rdocker share: could not ask for the stop ($req)" >&2; exit 1; }
    echo "Sharing is OFF, and the jobs running here are being stopped (within about 15 s)."
    exit 0 ;;
  status) run status; exit 0 ;;
  info) run info; exit 0 ;;
  level) run level; exit 0 ;;
  -h|--help|help)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *)
    echo "usage: rdocker share [off|low|medium|high|cpu <10-100>|ram <GB>|stop|status|info|level]" >&2
    exit 2 ;;
esac
