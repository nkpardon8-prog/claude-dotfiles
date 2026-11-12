#!/usr/bin/perl
# rr_runner.pl - the Mac-mini side of `rrun` (see the rrun plan, Revision 3 / 3.1).
#
# The laptop SENDS this file with every run; it is never trusted from disk on the mini, so code
# that tested programs plant under ~/rr cannot run on a later rrun. Core perl modules only.
#
# stdin protocol (nothing secret ever travels in argv, so nothing shows in `ps`):
#   "<len>\n" + <len> bytes of UTF-8 JSON header
#       {nonce, repo_slug, wt12, sha, relcwd, argv[], env{}, deleted[], tar_len,
#        stamps{dirs[], npm_args[]}, slots, wait_min, keep_containers_on_fail,
#        optional env_files[], hb_timeout, slots_base, spare_min_free_pct, spare_max_load,
#        cls, need_gb, heavy_slots, outputs[], owner{id, name, client}, timeout_s, exit_grace,
#        wait_every}
#   cls=heavy + heavy_slots: a heavy job also holds one of $ROOT/slots/heavy-<i> (flock);
#   need_gb: a slot is only taken while at least that much memory is available (re-checked here,
#   the client's probe can race another client); outputs: repo-relative build output paths,
#   deleted from the mirror before the command runs (git clean keeps ignored files) so a stale
#   dist never copies back. $ROOT/slots.cap (written by rd-tune) caps `slots`; a vitest/jest job gets
#   max(1, threads / slots) workers (fair_share).
#   owner: who asked (the client's agent session id or parent pid, its /line window name, its host):
#   written to $ROOT/slots/<i>.own beside <i>.who (a separate file, so the 4-field .who parsers in
#   rd_janitor / rd-tune / the reporter stay as they are), shown in our process title and given to
#   the command as RRUN_OWNER. timeout_s: hard wall-clock cap on the command (0 = none); past it the
#   command's process group is killed, "<nonce> TIMEOUT <s>" is printed and the run ends with 124.
#   exit_grace (10 s): when the command's main process exits, leftover children (a DB, a vitest
#   worker, a dev server) get this long to finish and close the output pipes, then the whole
#   process group is killed. The command's stdout/stderr are pipes WE relay, never the ssh channel
#   itself, so a leftover that escaped the group cannot keep the laptop's ssh open either.
#   wait_every (60 s): a slot wait repeats its "<nonce> WAIT ..." line this often.
#   then tar_len bytes of an overlay tar (dirty/untracked/env files)
#   then the laptop stream: "." = heartbeat (alive); "INT\n" = forward SIGINT; "GO\n" = start.
# Exactly-once handshake: after checkout, overlay, deps and the slot, the runner prints
# "<nonce> READY" and waits. It spawns the command ONLY after reading "GO\n" (then prints
# "<nonce> STARTED"); EOF / INT / heartbeat timeout before GO => exit without running anything.
# So a laptop that never wrote GO knows the command never ran (=> safe to run it locally).
# Status lines go to STDERR as "<nonce> READY|STARTED|WAIT ...|BUSY|KEPT ...|DOCKER|TIMEOUT <s>|EXIT <rc>"
# (DOCKER, just before EXIT: the command called docker through the shim - rrun never caches it). The nonce is 128
# random bits the tested code never sees (not in its env, shim or container labels; those use a
# separate random label token), so it cannot forge them. Exit = the command's rc (or 128+sig);
# 65 bad header/overlay/unsafe path, 69 missing bare repo, 70 runner error, 73 no free slot,
# 78 dependency install (npm ci / prisma generate) failed, 130 gave up before the command started,
# 124 the command ran past timeout_s and was killed.
# Every run appends one line to $ROOT/log/runs.log (see run_log; no env values, never fails a run).
# Test-only overrides: RR_ROOT (default ~/rr), RR_PATH (command PATH after the shim dir),
# RR_REAL_DOCKER (default /opt/homebrew/bin/docker, else /usr/bin/docker on a Linux server),
# RR_SHARE_FILE, RR_COLIMA (default /opt/homebrew/bin/colima), RR_COLIMA_TIMEOUT (default 120 s).
#
# Share switch (a worker's owner rents it in or out; see share_level): off = take no new job (exit 73
# with "<nonce> UNAVAIL share=off", the client moves on); some = half the slots and heavy slots;
# max (or no share file: every Linux worker) = full. On a Mac worker with Colima, a db job (and any
# docker call through the shim) first makes sure the engine answers, starting Colima sized by the
# level (exit 73 + "UNAVAIL docker" when it does not come up in time); with the share off and no slot
# busy, the Colima this runner started is stopped in the background when a job ends.
use strict;
use warnings;
use POSIX qw(setsid WNOHANG _exit);
use JSON::PP ();
use IO::Select;
use Time::HiRes qw(time sleep);
use Digest::SHA ();
use Fcntl qw(:flock O_RDWR O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_APPEND);
use File::Path qw(make_path remove_tree);
use File::Find ();
use File::Basename qw(dirname);
use File::Temp ();
use Cwd qw(realpath);

umask 077;    # everything the runner creates is owner-only (~/rr is 0700)
my $ROOT = $ENV{RR_ROOT} || "$ENV{HOME}/rr";
my $OS = $ENV{RR_OS} || $^O;                # RR_OS: tests only
my $REAL_DOCKER = $ENV{RR_REAL_DOCKER} || (-x '/opt/homebrew/bin/docker' || $^O ne 'linux' ? '/opt/homebrew/bin/docker' : '/usr/bin/docker');
my $COLIMA = $ENV{RR_COLIMA} || '/opt/homebrew/bin/colima';
my %VM = (max => [12, 24, 120], some => [6, 12, 120]);    # colima --cpu / --memory GB / --disk GB per share level
my $SLUG = qr/^(?!\.\.?$)[A-Za-z0-9._-]+$/;    # one path component; never "." or ".."
# fair_share: the env vars vitest 3-5 read for its worker count; config words that mean "a limit is set"
my @VITEST_ENV = qw(VITEST_MAX_WORKERS VITEST_MAX_THREADS VITEST_MAX_FORKS);
my $LIMIT_RE = qr/\b(?:maxWorkers|minWorkers|maxThreads|minThreads|maxForks|minForks|singleThread|singleFork|fileParallelism|runInBand|projects|workspace)\b/;
my $cpu_note;    # run log: the cpu share fair_share applied, if any

my (%h, $nonce, $label, $tmp, $mirror, $envlist, $lock_fh, $who, $started, $heavy_fh);
my (@env_written, @overlay);
my ($stdin_open, $inbuf, $last_hb, $go) = (1, '', time, 0);
my ($lost, $intr, $intr_done) = (0, 0, 0);    # lost: laptop gone / runner signalled; intr: Ctrl-C count
my $timed_out = 0;    # the command hit timeout_s (rc 124)
my $EX_TIMEOUT = 124; # like timeout(1)
my ($own, $waitf, $owner_id, $owner_name);    # slots/<i>.own, wait/<pid>, sanitized owner fields
my $EX_DEPS = 78;    # EX_CONFIG: npm ci / prisma generate failed (never the command's own rc)
our $supervising = 0;
our $QUIET = 0;    # run_cmd: also send the tool's stderr to /dev/null
my %reaped;
my ($t_slot, $t_ready, $t_spawn);    # run log timings: slot taken, READY (prepare done), command spawned

sub status { print STDERR "$nonce $_[0]\n" }
sub fail { my ($msg, $code) = @_; print STDERR "rrun-runner: $msg\n" if defined $msg; die { code => $code // 70 } }

# A signal to the runner itself (sshd hangup, kill): stop the command and still clean up.
for my $s (qw(INT TERM HUP)) {
    $SIG{$s} = sub { $lost = 1; die { code => 128 + POSIX->can("SIG$s")->() } unless $supervising };
}
$SIG{PIPE} = 'IGNORE';    # a dead ssh must not kill us before cleanup (reset to default for children)

my $rc = eval { main() };
if (!defined $rc) {
    my $e = $@;
    $rc = ref $e eq 'HASH' ? $e->{code} : do { print STDERR "rrun-runner: $e"; 70 };
}
finish($rc);
exit $rc;

# ------------------------------------------------------------------------------------- main
sub main {
    read_header();
    set_owner();
    $label = rand_hex();    # container label token: never the nonce (the command can read labels)
    take_slot();
    $t_slot = time;
    $tmp = File::Temp::tempdir("run-XXXXXXXX", DIR => mk("$ROOT/tmp"));
    write_docker_up("$tmp/docker-up") if colima_managed();
    write_shim("$tmp/docker");
    my $path = "$tmp:" . ($ENV{RR_PATH} // join ':', grep { defined } node_dir(), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin');
    $ENV{PATH} = $path;    # git/node/npm below resolve the same way the command will
    $ENV{GIT_TERMINAL_PROMPT} = '0';
    exclude_root();
    my %env = map { defined $ENV{$_} ? ($_ => $ENV{$_}) : () } qw(HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL TERM);
    %env = (%env, %{ $h{env} }, PATH => $path, RRUN_REMOTE => '1');
    $env{RRUN_OWNER} = $owner_id if defined $owner_id;
    node_heap(\%env);
    docker_up(\%env) if ($h{cls} // '') eq 'db' && colima_managed();

    my $cwd = prepare_mirror();
    deps(\%env);
    return 128 + 15 if $lost;
    fail("interrupted before the command started", 130) if $intr;
    my $argv = fair_share($h{argv}, \%env, $cwd);    # the spawned argv; $h{argv} stays as requested
    $t_ready = time;
    await_go();
    $started = 1;
    $t_spawn = time;
    my ($pid, $o_r, $e_r) = spawn($argv, \%env, $cwd, 'RELAY');
    status('STARTED');
    my $rc = supervise($pid, relay => [[$o_r, \*STDOUT], [$e_r, \*STDERR]],
                       grace => num_or($h{exit_grace}, 10), timeout => num_or($h{timeout_s}, 0));
    # the command called docker (the shim left its marker): the laptop never caches such a result
    status('DOCKER') if !$lost && -e "$tmp/docker.used";
    # the command's own exit code, the moment it ends (before cleanup): a link that dies after this
    # is not "lost mid-run" - the laptop has the real result and never re-runs it
    status("EXIT $rc") unless $lost;
    return $rc;
}

# The exactly-once handshake: announce READY, then spawn nothing until the laptop writes GO.
sub await_go {
    my $hb = hb_timeout();
    status('READY');
    until ($go) {
        fail("interrupted before the command started", 130) if $intr;
        fail("laptop went away before GO; the command was not started", 130)
            if !$stdin_open || time - $last_hb > $hb;
        pump(0.5);
    }
}

sub rand_hex {
    open(my $r, '<:raw', '/dev/urandom') or fail("urandom: $!");
    (read($r, my $b, 16) // 0) == 16 or fail("urandom: short read");
    unpack 'H*', $b;
}

# Keep ~/rr (env files, mirrors) out of Time Machine and Spotlight. `tmutil addexclusion` (no -p)
# is sticky and needs no sudo; it runs once per root (marker), and a failure is not retried.
sub exclude_root {
    my $marker = "$ROOT/.rr-tm-excluded";
    if (!(-f $marker && !-l $marker)) {
        { local $QUIET = 1; run_cmd('/dev/null', 'tmutil', 'addexclusion', $ROOT) }
        write_once($marker, "1\n");
    }
    my $ni = "$ROOT/.metadata_never_index";
    write_once($ni, '') unless -f $ni && !-l $ni;
}

# A marker file that two runners starting at once on a fresh worker (shards of one rrun, two
# laptops) may both create: whoever loses the O_EXCL race finds the winner's regular file and is
# done. A symlink / non-file planted there is still replaced, never written through.
sub write_once {
    my ($path, $data) = @_;
    for (1 .. 2) {
        return if -f $path && !-l $path;
        unlink $path if -l $path || -e _;
        if (sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)) {
            print {$fh} $data;
            close $fh or fail("write $path: $!");
            return;
        }
    }
    return if -f $path && !-l $path;
    fail("create $path: $!");
}

# ------------------------------------------------------------------------------ header + checks
sub read_exact {
    my ($n) = @_;
    my $buf = '';
    while (length($buf) < $n) {
        my $got = sysread(STDIN, $buf, $n - length($buf), length($buf));
        fail("truncated input", 65) unless $got;
    }
    $buf;
}

sub to_bytes {    # JSON strings -> UTF-8 byte strings, which is what exec/open/unlink need
    my ($v) = @_;
    return { map { my $k = $_; utf8::encode($k); ($k => to_bytes($v->{$_})) } keys %$v } if ref $v eq 'HASH';
    return [ map { to_bytes($_) } @$v ] if ref $v eq 'ARRAY';
    return $v if ref $v || !defined $v;
    my $s = "$v";
    utf8::encode($s);
    $s;
}

# Repo-relative path sent by the laptop. Refused: absolute, NUL, any ".." (escape), and any ".git"
# component (would let an overlay rewrite the worktree's link to the bare repo). Returns it
# normalised ("a//./b" -> "a/b").
sub check_rel {
    my ($what, $p, $allow_empty) = @_;
    fail("bad $what", 65) if !defined $p || ref $p || $p =~ /\0/ || $p =~ m{^/};
    my @c = grep { $_ ne '' && $_ ne '.' } split m{/}, $p;
    fail("bad $what: $p", 65) if grep { $_ eq '..' || $_ eq '.git' } @c;
    fail("empty $what", 65) if !@c && !$allow_empty;
    join '/', @c;
}

sub read_header {
    my $line = '';
    while ($line !~ /\n\z/) {
        fail("truncated header", 65) unless sysread(STDIN, my $c, 1);
        $line .= $c;
        fail("bad header length", 65) if length $line > 12;
    }
    fail("bad header length", 65) unless $line =~ /^(\d+)\n\z/;
    my $raw = eval { JSON::PP->new->utf8->decode(read_exact($1)) };
    fail("header is not a JSON object", 65) unless ref $raw eq 'HASH';
    %h = %{ to_bytes($raw) };
    # Every name that becomes a path component must be a plain slug; the commit must be a full sha.
    $nonce = $h{nonce} // '';
    fail("bad nonce", 65) unless $nonce =~ /^[0-9a-f]{32}$/;
    defined $h{$_} && $h{$_} =~ $SLUG or fail("bad $_", 65) for qw(repo_slug wt12);
    fail("bad sha", 65) unless ($h{sha} // '') =~ /^[0-9a-f]{40}$/;
    $h{relcwd} = check_rel('relcwd', $h{relcwd} // '', 1);
    # argv/env end up in execve: NUL would silently truncate them, so refuse instead.
    fail("bad argv", 65) unless ref $h{argv} eq 'ARRAY' && @{ $h{argv} } && !grep { ref || /\0/ } @{ $h{argv} };
    $h{env} //= {};
    fail("bad env", 65) unless ref $h{env} eq 'HASH';
    for (keys %{ $h{env} }) { fail("bad env name", 65) unless /^[A-Za-z_][A-Za-z0-9_]*$/ && $h{env}{$_} !~ /\0/ }
    delete $h{env}{PATH};    # PATH is the runner's decision (shim first)
    $h{deleted} = [ map { check_rel('deleted path', $_) } @{ $h{deleted} // [] } ];
    $h{stamps} //= {};
    $h{stamps}{dirs} = [ map { check_rel('deps dir', $_, 1) } @{ $h{stamps}{dirs} // [] } ];
    my $npm_args = $h{stamps}{npm_args} // [];
    fail("bad npm_args", 65) if grep { ref || /\0/ } @$npm_args;
    $h{stamps}{npm_args} = $npm_args;
    $h{outputs} = [ map { check_rel('output path', $_) } @{ ref $h{outputs} eq 'ARRAY' ? $h{outputs} : [] } ];
    fail("bad cls", 65) if defined $h{cls} && $h{cls} !~ /^[a-z]+$/;
    fail("bad need_gb", 65) if defined $h{need_gb} && $h{need_gb} !~ /^\d+(\.\d+)?$/;
    fail("bad heavy_slots", 65) if defined $h{heavy_slots} && $h{heavy_slots} !~ /^\d+$/;
    $h{tar_len} //= 0;
    fail("bad tar_len", 65) unless $h{tar_len} =~ /^\d+$/;
    @overlay = parse_tar(read_exact($h{tar_len}));    # validated before anything is written
}

# Parse the overlay tar in perl (no /usr/bin/tar, so no surprises from its own link handling).
# Only regular files and directories are accepted: symlinks, hardlinks and devices are refused
# outright, and every member path goes through check_rel.
sub parse_tar {
    my ($tar) = @_;
    my ($off, %pax, $long, @out) = (0);
    while ($off + 512 <= length $tar) {
        my $hd = substr($tar, $off, 512);
        $off += 512;
        last if $hd =~ /^\0{512}\z/;
        my ($name, $mode, $size, $sum, $type, $prefix) =
            unpack('Z100 A8 x8 x8 A12 x12 A8 a1 x100 x6 x2 x32 x32 x8 x8 Z155', $hd);
        (my $blank = $hd) =~ s/^(.{148}).{8}/$1        /s;    # checksum field counts as spaces
        fail("overlay tar: bad checksum", 65) unless ($sum =~ /^\s*([0-7]+)/ ? oct $1 : -1) == unpack('%32C*', $blank);
        $size = $pax{size} // ($size =~ /^\s*([0-7]+)/ ? oct $1 : fail("overlay tar: bad size", 65));
        my $data = substr($tar, $off, $size);
        $off += 512 * int(($size + 511) / 512);
        if ($type eq 'x') {    # pax header for the next member
            while ($data =~ /\G(\d+) ([^=]+)=/gc) {
                my $len = $1 - length("$1 $2=");
                $pax{$2} = substr($data, pos($data), $len - 1);
                pos($data) += $len;
            }
            next;
        }
        next if $type eq 'g';
        if ($type eq 'L') { ($long = $data) =~ s/\0.*//s; next }
        fail("overlay tar: refused member type '$type' (only files and dirs)", 65) unless $type =~ /^[05\0]$/;
        my $path = $pax{path} // $long // ($prefix ne '' ? "$prefix/$name" : $name);
        %pax = ();
        undef $long;
        push @out, [ check_rel('overlay member', $path), $type eq '5', $data, oct($mode || 0) ];
    }
    @out;
}

# ------------------------------------------------------------------------------------- slot
sub mk { make_path($_[0]); $_[0] }

# Open/create a lock file WITHOUT following a symlink (tested code can write ~/rr and could plant
# one pointing at, say, ~/.zshrc). It is never written, so a hardlink there is harmless.
sub open_nofollow {
    my ($path, $flags) = @_;
    unlink $path if -l $path;
    sysopen(my $fh, $path, $flags | O_CREAT | O_NOFOLLOW, 0600) or fail("open $path: $!");
    $fh;
}

# Files the runner (re)writes are always created fresh: unlinking first means an existing symlink
# OR hardlink planted at that name is replaced, never written through.
sub create_fresh {
    my ($path) = @_;
    unlink $path if -l $path || -e _;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or fail("create $path: $!");
    $fh;
}
sub write_file { my $fh = create_fresh($_[0]); print {$fh} $_[1]; close $fh or fail("write $_[0]: $!") }

sub hb_timeout { $h{hb_timeout} // $ENV{RR_HB_TIMEOUT} // 60 }

# Read what the laptop sent, waiting up to $secs: "." heartbeats (dropped; the writer never puts
# one inside a line), "INT" lines (counted in $intr) and the "GO" line ($go). Unknown lines are
# ignored. EOF clears $stdin_open. With stdin already closed it just sleeps.
sub pump {
    my ($secs) = @_;
    return sleep $secs unless $stdin_open;
    return unless IO::Select->new(\*STDIN)->can_read($secs);
    read_stdin();
}

sub read_stdin {
    my $n = sysread(STDIN, my $buf, 4096);
    if (!$n) { $stdin_open = 0; return }
    $last_hb = time;
    ($inbuf .= $buf) =~ tr/.//d;
    while ($inbuf =~ s/^([^\n]*)\n//) {
        if    ($1 eq 'INT') { $intr++ }
        elsif ($1 eq 'GO')  { $go = 1 }
    }
    $inbuf = substr($inbuf, -8) if length $inbuf > 8;    # no valid line is longer
}

# Slots 0..slots_base-1 are always usable; the extra ones up to `slots` only while the mini has room:
# free memory (kern.memorystatus_level, the % memory_pressure prints) >= spare_min_free_pct and the
# 1-min load per CPU <= spare_max_load. An unreadable reading counts as "no room" (fail safe).
sub sysctl_n { my $v = `/usr/sbin/sysctl -n $_[0] 2>/dev/null`; defined $v ? $v : '' }
# Linux: same three readings from /proc ($RR_PROC overrides the dir, for tests); free level =
# MemAvailable/MemTotal*100 (the kern.memorystatus_level analogue).
sub proc_readings {
    my $p = $ENV{RR_PROC} // '/proc';
    my $mi = slurp("$p/meminfo");
    my ($av) = $mi =~ /^MemAvailable:\s*(\d+)/m;
    my ($tot) = $mi =~ /^MemTotal:\s*(\d+)/m;
    my ($load) = slurp("$p/loadavg") =~ /^([\d.]+)/;
    my $ncpu = () = slurp("$p/cpuinfo") =~ /^processor\s*:/mg;
    return (($tot && defined $av) ? int($av * 100 / $tot) : undef, $load, $ncpu);
}
sub spare_room {
    my $min = $h{spare_min_free_pct} // 25;
    my $max = $h{spare_max_load} // 1.5;
    my ($free, $load, $ncpu);
    if ($OS eq 'linux') { ($free, $load, $ncpu) = proc_readings() }
    else {
        ($free) = sysctl_n('kern.memorystatus_level') =~ /^(\d+)/;
        ($load) = sysctl_n('vm.loadavg') =~ /([\d.]+)/;
        ($ncpu) = sysctl_n('hw.ncpu') =~ /^(\d+)/;
    }
    return 0 unless defined $free && defined $load && $ncpu;
    return $free >= $min && $load / $ncpu <= $max;
}

# Available memory in MB (Linux MemAvailable; macOS memorystatus_level % of hw.memsize), undef
# when unreadable (then the need_gb gate does not block: the run would otherwise never start).
sub mem_avail_mb {
    if ($OS eq 'linux') {
        my ($av) = slurp(($ENV{RR_PROC} // '/proc') . "/meminfo") =~ /^MemAvailable:\s*(\d+)/m;
        return defined $av ? int($av / 1024) : undef;
    }
    my ($lvl) = sysctl_n('kern.memorystatus_level') =~ /^(\d+)/;
    my ($tot) = sysctl_n('hw.memsize') =~ /^(\d+)/;
    return defined $lvl && $tot ? int($tot / 1048576 * $lvl / 100) : undef;
}
# V8 sizes its default heap from RAM: ~2 GB on an 8 GB worker, so a full `tsc -p server` that passes on
# a 16 GB Mac (4 GB default) dies with "JavaScript heap out of memory" here. Give node 70% of RAM,
# capped at 6 GB and never below 2 GB, unless the caller's NODE_OPTIONS already sets the heap size.
sub mem_total_mb {
    if ($OS eq 'linux') {
        my ($kb) = slurp(($ENV{RR_PROC} // '/proc') . "/meminfo") =~ /^MemTotal:\s*(\d+)/m;
        return defined $kb ? int($kb / 1024) : undef;
    }
    my $b = `/usr/sbin/sysctl -n hw.memsize 2>/dev/null`;
    return $b =~ /^(\d+)/ ? int($1 / 1048576) : undef;
}

sub node_heap {
    my ($env) = @_;
    my $opts = $env->{NODE_OPTIONS} // '';
    return if $opts =~ /--max-old-space-size/;
    my $tot = mem_total_mb() // return;
    my $mb = int($tot * 0.7);
    $mb = 6144 if $mb > 6144;
    $mb = 2048 if $mb < 2048;
    $env->{NODE_OPTIONS} = join ' ', grep { length } $opts, "--max-old-space-size=$mb";
}

# ----------------------------------------------------------------------------- cpu share
# vitest and jest start about one worker per logical CPU, so N jobs on one worker run ~N x threads
# workers (nickmbp: load 44 with 3 jobs), and the pool's overload hold-off then parks the worker.
# Each test job gets share = max(1, floor(threads / slots)); slots = the header's `slots` (fleet
# max_slots) lowered by slots.cap. The share switch's halving is left out on purpose: half the jobs
# x threads/slots = half the machine, which is what "some" means. Applied to the argv the runner
# spawns, never the header's: the laptop's cache key and shard split use the requested argv.
#   `vitest run ...`  -> --maxWorkers=<share> right after `run` (vitest 3-5; the CLI value still
#                        yields to fileParallelism:false / poolOptions limits in the config)
#   `jest ...`        -> --maxWorkers=<share> right after `jest`
#   `npm test` / `npm run <s>` whose script is ONE plain vitest command -> env VITEST_MAX_WORKERS
#                        (vitest 4+) + VITEST_MAX_THREADS / VITEST_MAX_FORKS (vitest 3)
# Never when the caller chose already (a worker/pool flag, one of those env vars), when a vitest/jest
# config in the cwd names a worker limit (the env vars override even fileParallelism:false, and a
# raised deliberate limit - sequential DB tests - is worse than oversubscribing), or when
# share >= threads (one slot: the default already fits). Jest has no env knob: an npm script that
# runs jest stays uncapped.

sub logical_cpus {
    if ($OS eq 'linux') {
        my $n = () = slurp(($ENV{RR_PROC} // '/proc') . "/cpuinfo") =~ /^processor\s*:/mg;
        return $n || undef;
    }
    my ($n) = sysctl_n('hw.logicalcpu') =~ /^(\d+)/;
    ($n) = sysctl_n('hw.ncpu') =~ /^(\d+)/ unless $n;
    $n || undef;
}

# -> the per-job worker count, or undef when there is nothing to cap
sub cpu_share {
    my $threads = logical_cpus() // return undef;
    my $n = $h{slots} && $h{slots} =~ /^\d+$/ ? $h{slots} : 1;
    my $cap = slots_cap();
    $n = $cap if defined $cap && $cap >= 1 && $cap < $n;
    my $share = int($threads / $n) || 1;
    $share < $threads ? $share : undef;
}

# A flag (before any `--`) by which the caller picked the parallelism: vitest/jest worker counts,
# vitest pool / file parallelism / inspect / browser, jest -w / -i / --runInBand.
sub chose_workers {
    for (@_) {
        last if $_ eq '--';
        return 1 if $_ eq '-w' || $_ eq '-i' || /^-w\d/;
        next unless /^--/;
        (my $n = lc((split /=/, $_, 2)[0])) =~ s/-//g;
        return 1 if $n =~ /^(?:maxworkers|minworkers|(?:no)?fileparallelism|pool|runinband|inspect|inspectbrk)$/
            || $n =~ /^(?:pooloptions|browser)/;
    }
    0;
}

# A config file's text (regular files only: a planted fifo/device must not hang the runner);
# undef = unreadable or too big to be a config.
sub small_text {
    my ($p) = @_;
    return undef unless -f $p && (-s _ // 0) < 1_000_000;
    open(my $fh, '<', $p) or return undef;
    local $/;
    <$fh> // '';
}

# Does a config the tool will load name a worker limit? (vitest/vite config or workspace in the cwd,
# or --root/--dir, plus --config; jest.config.* or package.json "jest"). Unreadable or a vitest
# workspace file = yes (no cap).
sub config_limits {
    my ($cwd, $tool, @args) = @_;
    my @files;
    my @dirs = ($cwd);
    for my $i (0 .. $#args) {
        last if $args[$i] eq '--';
        my ($n, $eq, $v) = $args[$i] =~ /^(--?[\w-]+)(=?)(.*)$/s or next;
        $v = $args[$i + 1] // '' unless $eq;
        my $p = $v =~ m{^/} ? $v : "$cwd/$v";
        if ($n eq '--config' || $n eq '-c') { push @files, $p }
        elsif ($tool eq 'vitest' && ($n eq '--root' || $n eq '--dir' || $n eq '-r')) { push @dirs, $p }
    }
    my $re = $tool eq 'jest' ? qr/^jest\.config\.[cm]?[jt]s(?:on)?$/
                             : qr/^(?:vitest|vite)\.(?:config|workspace)(?:\.[\w-]+)?\.[cm]?[jt]s(?:on)?$/;
    for my $d (@dirs) {
        opendir(my $dh, $d) or next;
        push @files, map { "$d/$_" } grep { $_ =~ $re } readdir $dh;
    }
    for my $f (@files) {
        return 1 if $f =~ m{(?:^|/)vitest\.workspace\.[^/]*$};    # each project's config may set its own
        my $t = small_text($f);
        return 1 if !defined $t || $t =~ $LIMIT_RE;
    }
    if ($tool eq 'jest' && -e "$cwd/package.json") {
        my $pj = eval { JSON::PP->new->decode(small_text("$cwd/package.json") // '') };
        return 1 if ref $pj ne 'HASH';
        return 1 if defined $pj->{jest} && (ref $pj->{jest} ne 'HASH' || JSON::PP->new->encode($pj->{jest}) =~ $LIMIT_RE);
    }
    0;
}

# `npm [-s] test|t|tst [-- args]` / `npm [-s] run|run-script <name> [-- args]` whose package.json
# script is one plain vitest command (optional VAR=value prefixes, optional npx, no shell operators)
# -> (vitest args from the script, args after --). Anything else (npm flags such as --prefix / -w,
# chained or wrapped scripts) -> () : the cwd or the command is not what we can see.
sub npm_vitest {
    my ($cwd, @a) = @_;
    shift @a while @a && $a[0] =~ /^(?:-s|--silent|-q|--quiet)$/;
    my $sub = shift @a // return;
    my $name = $sub =~ /^(?:test|t|tst)$/ ? 'test' : $sub =~ /^(?:run|run-script)$/ ? shift @a : undef;
    return unless defined $name && $name !~ /^-/;
    return if @a && $a[0] ne '--';
    shift @a;
    my $pj = eval { JSON::PP->new->decode(small_text("$cwd/package.json") // '') };
    my $s = ref $pj eq 'HASH' && ref $pj->{scripts} eq 'HASH' ? $pj->{scripts}{$name} : undef;
    return unless defined $s && !ref $s;
    return unless $s =~ /^\s*(?:[A-Za-z_]\w*=(?:"[^"]*"|'[^']*'|[^\s"';&|<>`\$]*)\s+)*(?:npx\s+)?vitest((?:\s+[^\s;&|<>`\$()"']+)*)\s*$/;
    return ([ split ' ', $1 ], \@a);
}

# -> the argv to spawn (a new array; $argv is the header's and stays as requested); may set $env vars.
sub fair_share {
    my ($argv, $env, $cwd) = @_;
    return $argv if grep { defined $env->{$_} } @VITEST_ENV;
    my $share = cpu_share() // return $argv;
    my @a = @$argv;
    my ($end) = grep { $a[$_] eq '--' } 0 .. $#a;
    $end //= scalar @a;
    my ($v) = grep { $a[$_] =~ m{(?:^|/)vitest$} && ($a[$_ + 1] // '') eq 'run' } 0 .. $end - 2;
    if (defined $v) {
        my @rest = @a[$v + 2 .. $#a];
        return $argv if chose_workers(@rest) || config_limits($cwd, 'vitest', @rest);
        $cpu_note = "cpu_share=$share --maxWorkers";
        return [ @a[0 .. $v + 1], "--maxWorkers=$share", @rest ];
    }
    my ($j) = grep { $a[$_] =~ m{(?:^|/)jest(?:\.js)?$} } 0 .. $end - 1;
    if (defined $j) {
        my @rest = @a[$j + 1 .. $#a];
        return $argv if chose_workers(@rest) || config_limits($cwd, 'jest', @rest);
        $cpu_note = "cpu_share=$share --maxWorkers";
        return [ @a[0 .. $j], "--maxWorkers=$share", @rest ];
    }
    if ($a[0] =~ m{(?:^|/)npm$}) {
        my ($script, $extra) = npm_vitest($cwd, @a[1 .. $#a]) or return $argv;
        return $argv if chose_workers(@$script) || chose_workers(@$extra)
            || config_limits($cwd, 'vitest', @$script, @$extra);
        $env->{$_} = $share for @VITEST_ENV;
        $cpu_note = "cpu_share=$share env";
    }
    $argv;
}

sub mem_ok {
    my $need = $h{need_gb} or return 1;
    my $mb = mem_avail_mb();
    return !defined $mb || $mb >= $need * 1024;
}
# rd-tune's live cap on concurrent runs ($ROOT/slots.cap: a number); undef = no cap file.
sub slots_cap {
    my $f = "$ROOT/slots.cap";
    return undef if -l $f;
    my ($c) = slurp($f) =~ /^\s*(\d+)/;
    $c;
}
# The owner's share switch: one word, off | some | max. RR_SHARE_FILE, else /Users/Shared/rdocker/share
# on macOS (the owner writes it with `rdocker share`), else $ROOT/share. No file = max (so a worker
# without one behaves exactly as before); a file that exists but is unreadable or says anything else
# = off (the owner's intent wins). Same rule as rd_pool's PROBE.
sub share_file { $ENV{RR_SHARE_FILE} || ($OS eq 'darwin' ? '/Users/Shared/rdocker/share' : "$ROOT/share") }
sub share_level {
    my $f = share_file();
    return 'max' unless -e $f || -l $f;
    my ($v) = slurp($f) =~ /^\s*(off|some|max)\s*$/;
    $v // 'off';
}
sub share_cap { my ($n, $lvl) = @_; $lvl eq 'some' && $n > 0 ? (int($n / 2) || 1) : $n }
sub share_off {
    status('UNAVAIL share=off');
    fail("this worker's owner has turned sharing off; not taking new jobs", 73);
}

# A heavy job (cls=heavy with heavy_slots in the header) also holds one heavy-<i> flock.
sub take_heavy {
    my ($dir) = @_;
    return 1 unless ($h{cls} // '') eq 'heavy' && defined $h{heavy_slots};
    for my $i (0 .. $h{heavy_slots} - 1) {
        my $fh = open_nofollow("$dir/heavy-$i", O_RDWR);
        if (flock($fh, LOCK_EX | LOCK_NB)) { $heavy_fh = $fh; return 1 }
        close $fh;
    }
    0;
}

# Who asked for this run (header "owner"): only plain characters survive, so the fields can go
# into a status line, a tab-separated file and our process title as they are.
sub clean_field {
    my ($v, $n) = @_;
    return undef if !defined $v || ref $v;
    $v =~ s{[^A-Za-z0-9 ._:@/+-]}{}g;
    $v =~ s/^\s+|\s+$//g;
    $v = substr($v, 0, $n);
    length $v ? $v : undef;
}
sub set_owner {
    my $o = ref $h{owner} eq 'HASH' ? $h{owner} : {};
    ($owner_id, $owner_name) = (clean_field($o->{id}, 64), clean_field($o->{name}, 48));
    $h{owner_client} = clean_field($o->{client}, 48);
    (my $w = $owner_name // '') =~ tr/ /_/;
    $0 = join ' ', 'rrun-runner', ($owner_id ? "owner=$owner_id" : ()), ($w ne '' ? "window=$w" : ()),
        ($h{owner_client} ? "from=$h{owner_client}" : ());
}

# Runs waiting for a slot register as $ROOT/wait/<pid> ("<epoch>"), so a waiter can say how many
# wait ahead of it. Best effort: a planted symlink or an unwritable dir just means "ahead=0".
sub join_waiters {
    my $d = "$ROOT/wait";
    return '' if -l $d;
    mkdir $d, 0700 unless -d $d;
    my $f = "$d/$$";
    eval { write_file($f, sprintf("%.3f\n", time)) } or return '';
    $f;
}
sub leave_waiters { unlink $waitf if $waitf; $waitf = '' }
sub waiters_ahead {
    return 0 unless $waitf;
    my ($mine) = slurp($waitf) =~ /^(\d+(?:\.\d+)?)/ or return 0;
    opendir(my $dh, "$ROOT/wait") or return 0;
    my $n = 0;
    for my $f (readdir $dh) {
        next unless $f =~ /^(\d+)$/ && $1 != $$;
        my $pid = $1;
        if (!kill(0, $pid)) { unlink "$ROOT/wait/$f"; next }    # its run is gone
        my ($t) = slurp("$ROOT/wait/$f") =~ /^(\d+(?:\.\d+)?)/;
        $n++ if defined $t && ($t < $mine || ($t == $mine && $pid < $$));
    }
    $n;
}
# "WAIT holder=<slug> age=<s> busy=<k> slots=<n> ahead=<a> [gate=heavy|mem] [howner=<who>]": the
# longest-running holder of the slots we just found locked (its .who; the one expected to finish
# first), how many slots are held and how many runs wait before us.
sub wait_line {
    my ($dir, $n, $gate, $held) = @_;
    my $old;
    for my $i (@$held) {
        my ($slug, $t) = split ' ', slurp("$dir/$i.who");
        next unless ($t // '') =~ /^\d+$/ && $t <= time;
        $old = [$i, $slug, $t] if !$old || $t < $old->[2];
    }
    my $line = sprintf 'WAIT holder=%s age=%d busy=%d slots=%d ahead=%d',
        $old ? $old->[1] // '?' : '?', $old ? time - $old->[2] : 0, scalar @$held, $n, waiters_ahead();
    $line .= " gate=$gate" if $gate;
    if ($old) {
        my %f = map { /^([a-z]+)=(.*)$/ ? ($1 => $2) : () } split /\t/, (slurp("$dir/$old->[0].own") =~ /^([^\n]*)/)[0] // '';
        (my $hw = $f{name} || $f{id} || '') =~ s/[^A-Za-z0-9._:@\/+-]/_/g;
        $line .= " howner=$hw" if $hw ne '';
    }
    $line;
}

sub take_slot {
    my $dir = mk("$ROOT/slots");
    my $share = share_level();
    share_off() if $share eq 'off';
    my $n = share_cap($h{slots} && $h{slots} =~ /^\d+$/ ? $h{slots} : 1, $share);
    $h{heavy_slots} = share_cap($h{heavy_slots}, $share) if defined $h{heavy_slots};
    my $cap = slots_cap();
    $n = $cap if defined $cap && $cap < $n;    # 0 = drained: wait (then 73) like a full mini
    my $base = defined $h{slots_base} && $h{slots_base} =~ /^\d+$/ && $h{slots_base} >= 1
        && $h{slots_base} < $n ? $h{slots_base} : $n;
    my $deadline = time + 60 * ($h{wait_min} // 30);
    my $every = num_or($h{wait_every}, 60) || 60;
    my ($said, @held);
    while (1) {
        share_off() if share_level() eq 'off';    # switched off while we waited: move on now
        my $spare = $base < $n && spare_room();
        my $heavy_ok = take_heavy($dir);
        my $gate = $heavy_ok && mem_ok();
        if (!$gate && $heavy_fh) { close $heavy_fh; undef $heavy_fh }
        my @try = $gate ? (0 .. ($spare ? $n : $base) - 1) : ();
        @held = () if @try;
        for my $i (@try) {
            # flock(2) == the lock `/usr/bin/lockf -k` takes; it dies with this process (even -9).
            my $fh = open_nofollow("$dir/$i", O_RDWR);
            if (flock($fh, LOCK_EX | LOCK_NB)) {
                # Before anything else: bump the lock's mtime, then rewrite .who (with our pid).
                # The janitor trusts a held slot's .who only when it is not older than the lock
                # and its pid is alive, so a stale .who left by a run killed -9 never names the
                # wrong repo in the moment between our flock and this rewrite. The 4th field
                # names our mirror (<repo_slug>-<wt12>): the janitor's disk-pressure eviction then
                # spares that mirror only, not every mirror of the repo (format: rd_janitor ~/rr).
                utime(undef, undef, $fh);
                ($lock_fh, $who) = ($fh, "$dir/$i.who");
                write_file($who, "$h{repo_slug} " . int(time) . " $$ $h{wt12}\n");
                # who asked, for `rrun --jobs` / the probe (a separate file: .who keeps its 4 fields)
                $own = "$dir/$i.own";
                eval { write_file($own, join("\t", "id=" . ($owner_id // '?'), "name=" . ($owner_name // ''),
                    "client=" . ($h{owner_client} // ''), "start=" . int(time), "pid=$$",
                    "cmd=" . redact_argv()) . "\n") };
                leave_waiters();
                return;
            }
            push @held, $i;
            close $fh;
        }
        if ($heavy_fh) { close $heavy_fh; undef $heavy_fh }
        $waitf //= join_waiters();
        if (!defined $said || time - $said >= $every) {
            $said = time;
            status(wait_line($dir, $n, $gate ? '' : $heavy_ok ? 'mem' : 'heavy', \@held));
        }
        my $left = $deadline - time;
        if ($left <= 0) { status('BUSY'); fail(undef, 73) }
        my $nap = $left < 5 ? $left : 5;
        $nap = $every if $every < $nap;
        pump($nap);    # EOF or Ctrl-C while we wait = the user gave up
        fail("laptop went away while waiting", 130) if !$stdin_open || $intr;
    }
}

# --------------------------------------------------------------------------------- mirror
sub run_cmd {    # internal tool; its stdout goes to $out (default: our stderr, never the command's stdout)
    my ($out, @cmd) = @_;
    my $pid = fork // fail("fork: $!");
    if (!$pid) {
        $SIG{$_} = 'DEFAULT' for qw(INT TERM HUP PIPE);
        open STDIN, '<', '/dev/null';
        $out ? open(STDOUT, '>', $out) : open(STDOUT, '>&', \*STDERR);
        open(STDERR, '>', '/dev/null') if $QUIET;
        { no warnings "exec"; exec { $cmd[0] } @cmd }
        _exit(127);
    }
    waitpid($pid, 0);
    $?;
}

# Hooks and fsmonitor are the two places a (possibly tampered) repo config would run code on
# checkout/clean; both are neutralised on every git call.
sub git { run_cmd(undef, 'git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', @_) == 0 or fail("git $_[2] failed") }

# Make sure no ancestor of $rel inside the mirror is a symlink (a tracked symlink dir would
# otherwise carry writes/unlinks outside the mirror). Creates missing dirs when $create.
sub safe_parent {
    my ($rel, $create) = @_;
    my @c = split m{/}, $rel;
    my $p = $mirror;
    for (@c[0 .. $#c - 1]) {
        $p .= "/$_";
        fail("refusing path through symlink: $rel", 65) if -l $p;
        next if -d _;
        return 0 unless $create && !-e _;
        mkdir $p or fail("mkdir $p: $!");
    }
    1;
}

sub prepare_mirror {
    my $bare = "$ROOT/git/$h{repo_slug}.git";
    fail("bare repo $bare is missing (the laptop pushes it before each run)", 69) unless -d $bare;
    my $wdir = mk("$ROOT/w");
    fail("$wdir is a symlink; refusing (remove it)", 65) if -l $wdir;
    $mirror = "$wdir/$h{repo_slug}-$h{wt12}";
    # Tested code can write ~/rr: a mirror swapped for a symlink would point checkout/clean/overlay
    # writes at any directory, so refuse it (the janitor never follows one either).
    fail("mirror $mirror is a symlink; refusing (remove it)", 65) if -l $mirror;
    if (!-e "$mirror/.git") {    # first run for this laptop worktree: make the mirror once
        remove_tree($mirror) if -e $mirror;
        git('-C', $bare, 'worktree', 'prune');
        git('-C', $bare, 'worktree', 'add', '-q', '-f', '--detach', $mirror, $h{sha});
    }
    my ($rw, $rm) = (realpath($wdir), realpath($mirror));
    fail("mirror $mirror resolves outside $wdir; refusing", 65)
        unless defined $rw && defined $rm && !-l $mirror && index($rm, "$rw/") == 0;
    git('-C', $mirror, 'checkout', '-q', '-f', '--detach', $h{sha});
    git('-C', $mirror, 'clean', '-fdq');    # not -x: ignored files (node_modules) survive
    for my $rel (@{ $h{outputs} }) {        # stale build outputs (ignored, so clean kept them)
        next unless safe_parent($rel, 0);
        my $p = "$mirror/$rel";
        if (-l $p || -f _) { unlink $p } elsif (-d _) { remove_tree($p) }
    }
    $envlist = "$ROOT/w/.$h{repo_slug}-$h{wt12}.envlist";
    delete_env_files(1);                    # leftovers of a run that was killed -9
    for my $rel (@{ $h{deleted} }) {
        next unless safe_parent($rel, 0);
        unlink "$mirror/$rel" if -l "$mirror/$rel" || -f _;    # files/links only, never a dir
    }
    my %envset = map { (check_rel('env file', $_), 1) } @{ $h{env_files} // [] };
    my @env = grep { !$_->[1] && ($envset{ $_->[0] } || $_->[0] =~ m{(^|/)\.env[^/]*$}) } @overlay;
    @env_written = map { $_->[0] } @env;
    write_file($envlist, join '', map { "$_\0" } @env_written);    # recorded BEFORE writing them
    my %is_env = map { $_ => 1 } @env_written;
    for (@overlay) {
        my ($rel, $is_dir, $data, $mode) = @$_;
        safe_parent($rel, 1);
        my $p = "$mirror/$rel";
        if ($is_dir) { fail("refusing symlink dir $rel", 65) if -l $p; mkdir $p unless -d $p; next }
        fail("overlay file over a directory: $rel", 65) if !-l $p && -d $p;
        my $fh = create_fresh($p);
        chmod(($is_env{$rel} || !($mode & 0100)) ? 0600 : 0700, $fh);    # env files: always 0600
        print {$fh} $data;
        close $fh or fail("write $rel: $!");
    }
    my $cwd = $h{relcwd} eq '' ? $mirror : "$mirror/$h{relcwd}";
    my $rc = realpath($cwd);
    fail("relcwd is not a directory inside the mirror", 65)
        unless defined $rc && -d $rc && ($rc eq $rm || index($rc, "$rm/") == 0);
    $cwd;
}

sub delete_env_files {
    my ($stale) = @_;
    return unless $envlist;
    my @list = $stale ? split(/\0/, slurp($envlist)) : @env_written;
    for my $rel (@list) {
        next unless eval { $rel = check_rel('env file', $rel); safe_parent($rel, 0) };
        unlink "$mirror/$rel";
    }
    unlink $envlist;
}

# ----------------------------------------------------------------------------------- deps
# Names are hashed relative to the mirror, so the same files give the same stamp in every mirror of a
# repo (the shared package store keys on it). Changed 2026-10-19: older absolute-path stamps simply
# no longer match, which costs each mirror one npm ci.
sub sha_files {
    my $d = Digest::SHA->new(256);
    my @pre = grep { defined && length } map { $_ ? "$_/" : undef } $mirror, ($mirror ? realpath($mirror) : undef);
    for (@_) {
        my $n = $_;
        for my $p (@pre) { last if $n =~ s/^\Q$p\E// }
        $d->add("$n\0");
        $d->addfile($_) if -f $_;
    }
    $d->hexdigest;
}
sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; <$fh> // '' }

# Shared package store: $ROOT/deps/<key>/node_modules, key = repo + deps dir + deps stamp. An entry is
# written whole into a temp dir and renamed into place, and never changed after, so a mirror can
# clone it (APFS clonefile, `cp -c`: shared blocks, near-zero disk, no npm ci) without ever seeing a
# half-written install. The janitor removes entries unused for a few days. Any failure (no APFS, a
# tampered or missing entry) just means a normal npm ci.
sub deps_key { substr(Digest::SHA::sha256_hex("$h{repo_slug}\0$_[0]\0$_[1]"), 0, 32) }

# Clone argv: APFS clonefile on macOS; Linux `cp -a --reflink=auto` (reflink where the fs has it, else a copy).
sub clone_cmd { $OS eq 'linux' ? ('/bin/cp', '-a', '--reflink=auto') : ('/bin/cp', '-cR') }

sub store_clone {    # -> 1 when $dir/node_modules is now a clone of the store entry for $stamp
    my ($rel, $dir, $stamp) = @_;
    my $entry = "$ROOT/deps/" . deps_key($rel, $stamp);
    return 0 if -l $entry || !-d "$entry/node_modules" || -l "$entry/node_modules";
    return 0 unless slurp("$entry/node_modules/.rr-deps-stamp") eq $stamp;
    utime(undef, undef, $entry);                          # used now (the janitor's LRU clock)
    local $QUIET = 1;                                     # cp's own complaints: we fall back quietly
    my $t = "$dir/.rr-nm-clone.$$";
    remove_tree($t) if -e $t || -l $t;
    if (run_cmd('/dev/null', clone_cmd(), "$entry/node_modules", $t) != 0
            || slurp("$t/.rr-deps-stamp") ne $stamp) {
        remove_tree($t);
        return 0;
    }
    my $nm = "$dir/node_modules";
    if (-l $nm) { unlink $nm } elsif (-e $nm) { remove_tree($nm) }
    return 1 if rename($t, $nm);
    remove_tree($t);
    return 0;
}

sub store_save {     # after a real install: publish $dir/node_modules (incl. its stamps) to the store
    my ($rel, $dir, $stamp) = @_;
    my $deps = mk("$ROOT/deps");
    my $entry = "$deps/" . deps_key($rel, $stamp);
    return if -e $entry || -l $entry || slurp("$dir/node_modules/.rr-deps-stamp") ne $stamp;
    my $t = "$deps/.tmp-" . deps_key($rel, $stamp) . ".$$";
    remove_tree($t) if -e $t || -l $t;
    mk($t);
    local $QUIET = 1;
    if (run_cmd('/dev/null', clone_cmd(), "$dir/node_modules", "$t/node_modules") == 0) {
        utime(undef, undef, $t);
        return if rename($t, $entry);                    # fails if another run saved it first
    }
    remove_tree($t);
}

sub deps {
    my ($env) = @_;
    my @saves;
    my $legacy = mk("$ROOT/state") . "/$h{repo_slug}.legacy-peer-deps";
    my $nodev = `node -v 2>/dev/null` // '';
    my $rm = realpath($mirror);
    for my $rel (@{ $h{stamps}{dirs} }) {
        my $dir = $rel eq '' ? $mirror : "$mirror/$rel";
        next unless -d $dir;
        # a tracked symlinked dir must not send npm ci / prisma outside the mirror
        my $rd = realpath($dir);
        fail("deps dir ./$rel resolves outside the mirror; refusing", 65)
            unless defined $rd && ($rd eq $rm || index($rd, "$rm/") == 0);
        my ($lock) = grep { -f } map { "$dir/$_" } qw(npm-shrinkwrap.json package-lock.json);
        next unless $lock && -f "$dir/package.json" && !-l $lock;
        # deps stamp: lockfile + package.json + .npmrc + node version + the exact npm args
        my @args = ('ci', '--no-audit', '--no-fund', @{ $h{stamps}{npm_args} }, (-e $legacy ? '--legacy-peer-deps' : ()));
        my $stamp = sha_files($lock, "$dir/package.json", "$dir/.npmrc") . " $nodev @args";
        my $installed = 0;
        if (slurp("$dir/node_modules/.rr-deps-stamp") ne $stamp && store_clone($rel, $dir, $stamp)) {
            print STDERR "rrun: packages for ./$rel reused from the mini's shared store (no npm ci)\n";
        } elsif (slurp("$dir/node_modules/.rr-deps-stamp") ne $stamp) {
            $installed = 1;
            print STDERR "rrun: npm @args  (in ./$rel)\n";
            my $rc = npm($env, $dir, @args);
            if ($rc && !-e $legacy && slurp("$tmp/npm.log") =~ /ERESOLVE/) {
                print STDERR "rrun: npm ERESOLVE, retrying with --legacy-peer-deps (remembered for $h{repo_slug})\n";
                write_file($legacy, "1\n");
                push @args, '--legacy-peer-deps';
                $stamp = sha_files($lock, "$dir/package.json", "$dir/.npmrc") . " $nodev @args";
                $rc = npm($env, $dir, @args);
            }
            my $what = "npm @args";
            if ($rc && !$lost && !$intr && slurp("$tmp/npm.log") =~
                    /can only install packages when your package\.json and package-lock\.json|code EUSAGE/) {
                # an out-of-sync lockfile (dentall's repo root, 2026-10-15): the laptop got its
                # node_modules from `npm install`, so do the same - it rewrites only the mirror's copy
                # of the lockfile, which the next checkout resets (the stamp stays the committed one's)
                my @inst = ('install', grep { $_ ne 'ci' } @args);
                print STDERR "rrun: package-lock.json is out of sync with package.json in ./$rel"
                           . " (npm ci refuses) - using npm @inst on the mirror\n";
                $rc = npm($env, $dir, @inst);
                $what = "npm @inst";
            }
            return if $lost || $intr;    # main() reports it
            deps_failed($what, $rel, $rc) if $rc;
            write_file("$dir/node_modules/.rr-deps-stamp", $stamp);
            push @saves, [$rel, $dir, $stamp];
        }
        # schema stamp: *.prisma in ./prisma and in the dir of a `--schema X` named by the package's own
        # postinstall; a change means generate, not a reinstall. When postinstall runs prisma generate
        # (it knows the schema path and generator), rerun it; else `npx prisma generate`. No schema
        # found -> nothing to generate. Right after npm ci, postinstall has just run it.
        my $pkg = eval { JSON::PP->new->decode(slurp("$dir/package.json")) } || {};
        next unless grep { ref $pkg->{$_} eq 'HASH' && ($pkg->{$_}{prisma} || $pkg->{$_}{'@prisma/client'}) } qw(dependencies devDependencies);
        my $post = ref $pkg->{scripts} eq 'HASH' ? ($pkg->{scripts}{postinstall} // '') : '';
        my $post_gen = $post =~ /\bprisma\s+generate\b/;
        my @sdirs = ("$dir/prisma");
        if ($post_gen && $post =~ /--schema[=\s]+(\S+)/) {
            my $sp = realpath("$dir/$1");
            if (defined $sp && index($sp, "$rm/") == 0) { push @sdirs, -d $sp ? $sp : dirname($sp) }
        }
        my %seen; my @schemas;
        for my $sd (grep { -d && !$seen{realpath($_) // $_}++ } @sdirs) {
            File::Find::find({ no_chdir => 1, wanted => sub { push @schemas, $_ if /\.prisma$/ && -f } }, $sd);
        }
        next unless @schemas;
        my $sstamp = sha_files(sort @schemas);
        if (!$installed || !$post_gen) {
            next if slurp("$dir/node_modules/.rr-schema-stamp") eq $sstamp;
            my @gen = $post_gen ? ('run', 'postinstall') : ('npx', 'prisma', 'generate');
            my $what = $post_gen ? 'npm run postinstall' : 'npx prisma generate';
            print STDERR "rrun: $what  (in ./$rel)\n";
            my $rc = npm($env, $dir, @gen);
            return if $lost || $intr;
            deps_failed($what, $rel, $rc) if $rc;
        }
        mk("$dir/node_modules");
        write_file("$dir/node_modules/.rr-schema-stamp", $sstamp);
    }
    store_save(@$_) for @saves;    # after the schema stamps, so a clone needs no prisma generate
}

# Dependency setup failed: show its log, exit $EX_DEPS (never the tool's own rc, which the laptop
# would otherwise take for the command's). The command was not started.
sub deps_failed {
    my ($what, $rel, $rc) = @_;
    print STDERR slurp("$tmp/npm.log");
    fail(sprintf("%s failed in ./%s on the Mac mini (exit %d); the command was not started", $what, $rel, $rc), $EX_DEPS);
}

sub npm {    # npm/npx under the same heartbeat supervision as the command (a dead laptop stops them)
    my ($env, $dir, @args) = @_;
    unshift @args, 'npm' unless $args[0] eq 'npx';
    supervise(spawn(\@args, $env, $dir, "$tmp/npm.log"));
}

# ------------------------------------------------------------------------------- process
# $out: undef = inherit our stdout/stderr; a path = both into that file; 'RELAY' = two fresh pipes
# whose read ends are returned (pid, stdout_r, stderr_r) for supervise() to relay. The command never
# gets the ssh channel itself: a leftover child (even one that left our process group) can then
# hold only our pipe, which we stop reading, never the laptop's ssh session.
sub spawn {
    my ($argv, $env, $cwd, $out) = @_;
    my $relay = defined $out && $out eq 'RELAY';
    my ($or, $ow, $er, $ew);
    if ($relay) { pipe($or, $ow) && pipe($er, $ew) or fail("pipe: $!") }
    my $pid = fork // fail("fork: $!");
    if ($pid) {
        return $pid unless $relay;
        close $ow; close $ew;
        return ($pid, $or, $er);
    }
    $SIG{$_} = 'DEFAULT' for qw(INT TERM HUP PIPE);    # ignored signals would survive exec
    setsid();                                          # own session + group: the only group we signal
    open STDIN, '<', '/dev/null';
    if ($relay) {
        close $or; close $er;
        open STDOUT, '>&', $ow; open STDERR, '>&', $ew; close $ow; close $ew;
    } elsif ($out) { open STDOUT, '>', $out; open STDERR, '>&', \*STDOUT }
    chdir $cwd or do { print STDERR "rrun-runner: chdir $cwd: $!\n"; _exit(127) };
    %ENV = %$env;
    { no warnings "exec"; exec { $argv->[0] } @$argv }
    print STDERR "rrun-runner: $argv->[0]: $!\n";
    _exit(127);
}

# Reap without blocking. A pid is only ever signalled while this says it is unreaped, so a
# recycled pid/pgid can never be hit.
sub alive {
    my ($pid) = @_;
    return 0 if exists $reaped{$pid};
    my $w = waitpid($pid, WNOHANG);
    return 1 if $w == 0;
    $reaped{$pid} = $w == $pid ? $? : 0;
    0;
}

sub signal_group { my ($pid, $sig) = @_; kill($sig, -$pid) || kill($sig, $pid) if alive($pid) }
# After the leader is reaped its group id stays reserved while any member lives (a pid is never
# reused as long as a process group of that id exists), so signalling -$pid then is safe.
sub group_alive { kill(0, -$_[0]) }
sub num_or { my ($v, $d) = @_; defined $v && !ref $v && $v =~ /^\d+(\.\d+)?$/ ? $v + 0 : $d }

# Copy everything readable from the relay pipes to our stdout/stderr (whole writes: a short write to
# a slow ssh is finished, never dropped). A pipe at EOF is closed and forgotten.
sub write_all {
    my ($fh, $data) = @_;
    while (length $data) {
        my $n = syswrite($fh, $data);
        return unless defined $n;    # the laptop is gone (EPIPE): stdin EOF ends the run
        substr($data, 0, $n, '');
    }
}
sub io_wait {
    my ($secs, $pipes) = @_;
    my $sel = IO::Select->new;
    $sel->add(\*STDIN) if $stdin_open;
    $sel->add($_->[0]) for values %$pipes;
    return sleep $secs unless $sel->count;
    for my $fh ($sel->can_read($secs)) {
        if (fileno($fh) == fileno(STDIN)) { read_stdin(); next }
        my $fd = fileno $fh;
        my $n = sysread($fh, my $buf, 65536);
        if ($n) { write_all($pipes->{$fd}[1], $buf); next }
        close $fh;
        delete $pipes->{$fd};
    }
}

# Wait for the command (or an npm step) while pumping the laptop stream: Ctrl-C lines go to its
# group, a lost laptop TERMs it (KILL 10 s later). With `relay` (the command): its output is copied
# through, `timeout` caps its wall-clock time (TIMEOUT status, rc 124), and once the main process has
# exited, leftover members of its group get `grace` seconds to close the pipes and go away before the
# group is TERMed, KILLed 10 s later, and checked empty; then we stop reading, whatever still holds a
# pipe. Silence never kills: only the cap (timeout), a lost laptop, Ctrl-C or the main's exit do.
sub supervise {
    my ($pid, %o) = @_;
    local $supervising = 1;
    my $hb = hb_timeout();
    my %pipes = map { (fileno($_->[0]) => $_) } @{ $o{relay} || [] };
    my $relay = %pipes ? 1 : 0;
    my ($term_at, $exit_at, $gterm_at, $gkill_at);
    my $t0 = time;
    while (1) {
        my $up = alive($pid);
        if ($up) {
            while ($intr > $intr_done) { $intr_done++; signal_group($pid, 'INT') }
            $lost = 1 if !$stdin_open || time - $last_hb > $hb;
            if ($o{timeout} && !$timed_out && time - $t0 > $o{timeout}) {
                $timed_out = 1;
                status(sprintf 'TIMEOUT %d', $o{timeout});
            }
            if (($lost || $timed_out) && !$term_at) { signal_group($pid, 'TERM'); $term_at = time }
            signal_group($pid, 'KILL') if $term_at && time - $term_at > 10;    # skipped once reaped
        } else {
            last unless $relay;
            $exit_at //= time;
            my $gone = !$stdin_open || time - $last_hb > $hb;    # nobody to relay to any more
            my $grace = $gone || $lost || $timed_out || $intr > $intr_done ? 0 : $o{grace} // 10;
            my $grp = group_alive($pid);
            last if !%pipes && !$grp;
            if (time - $exit_at >= $grace) {
                # TERM the group (already done when the cap / a lost laptop stopped the main), KILL
                # what is left 10 s later, then make sure the group is gone before the slot is freed
                if (!$gterm_at) { kill('TERM', -$pid) if $grp && !$term_at; $gterm_at = $term_at // time }
                elsif (!$gkill_at && time - $gterm_at >= 10) { kill('KILL', -$pid) if $grp; $gkill_at = time }
                if ($gkill_at && (!$grp || time - $gkill_at > 5)) {
                    print STDERR "rrun-runner: process group $pid survived SIGKILL; leaving it\n" if $grp;
                    last;    # whatever still holds a pipe (it left the group): stop reading
                }
            }
        }
        $relay ? io_wait(0.1, \%pipes) : pump(0.1);
    }
    close $_->[0] for values %pipes;
    return $EX_TIMEOUT if $timed_out && $relay;
    my $s = $reaped{$pid};
    $s & 127 ? 128 + ($s & 127) : $s >> 8;
}

# ------------------------------------------------------------------------------------ end
sub finish {
    my ($rc) = @_;
    local $SIG{$_} = 'IGNORE' for qw(INT TERM HUP);    # cleanup must not be cut short
    eval { delete_env_files(0) };
    eval { containers($rc) } if $started;
    leave_waiters();
    unlink $own if $own;
    if ($who) { unlink $who; close $lock_fh }
    close $heavy_fh if $heavy_fh;
    remove_tree($tmp) if $tmp;
    eval { colima_stop_if_off() };
    eval { run_log($rc) };    # bookkeeping only: never changes the run's outcome
}

# One line per run in $ROOT/log/runs.log (0600; dir 0700; one rotated generation, runs.log.1, past
# 5 MB): time, repo, worktree, commit, outcome, prepare/command seconds, then the first 120 chars
# of the argv with env-looking values redacted (-e X=.., --env=.., NAME=..). The header env is
# never logged. A test job fair_share capped ends with " [cpu_share=N --maxWorkers|env]" (after argv,
# so rd_pool's and the reporter's line parsers still match). Tested code can write ~/rr: a planted
# symlink/hardlink at the log is replaced, never written through.
sub run_outcome {
    my ($rc) = @_;
    if ($started) { return $timed_out ? "timeout rc=$rc" : $lost ? "lost rc=$rc" : $intr ? "interrupted rc=$rc" : "rc=$rc" }
    return 'deps-failed' if $rc == $EX_DEPS;
    return 'busy' if $rc == 73;
    return "refused rc=$rc" if $rc == 65 || $rc == 69;
    return $intr ? 'interrupted' : 'lost' if $rc == 130 || $lost;
    "error rc=$rc";
}

sub redact_argv {
    my @out;
    my $val = 0;
    for my $a (@{ $h{argv} // [] }) {
        if ($val) { push @out, '<redacted>'; $val = 0; next }
        if ($a eq '-e' || $a eq '--env') { push @out, $a; $val = 1; next }
        if ($a =~ /^(--env=|-e)(?=.*=)/s) { push @out, "$1<redacted>"; next }
        if ($a =~ /^(-*[A-Za-z_][A-Za-z0-9_-]*=)/) { push @out, "$1<redacted>"; next }
        push @out, $a;
    }
    (my $s = join ' ', @out) =~ s/[\x00-\x1f\x7f]/ /g;
    length $s > 120 ? substr($s, 0, 120) . '...' : $s;
}

sub run_log {
    my ($rc) = @_;
    my $now = time;
    my $dir = "$ROOT/log";
    return if -l $dir;
    mkdir $dir, 0700 unless -d $dir;
    chmod 0700, $dir;
    my $f = "$dir/runs.log";
    my @st = lstat $f;
    rename $f, "$f.1" if @st && -f _ && $st[7] > 5_000_000;
    @st = lstat $f;
    unlink $f if @st && (!-f _ || $st[3] != 1);    # symlink, hardlink or other: replace it
    sysopen(my $fh, $f, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600) or return;
    my $id = sub { my ($v, $re) = @_; defined $v && !ref $v && $v =~ $re ? $v : '?' };
    my $secs = sub { defined $_[0] && defined $_[1] ? sprintf('%.1f', $_[1] - $_[0]) : '-' };
    printf {$fh} "%s repo=%s wt=%s sha=%s outcome=%s prepare_s=%s cmd_s=%s argv=%s\n",
        POSIX::strftime('%Y-%m-%dT%H:%M:%S%z', localtime $now),
        $id->($h{repo_slug}, $SLUG), $id->($h{wt12}, $SLUG),
        substr($id->($h{sha}, qr/^[0-9a-f]{40}$/), 0, 12), run_outcome($rc),
        $secs->($t_slot, $t_ready // $now), $secs->($t_spawn, $t_spawn && $now),
        redact_argv() . ($cpu_note && $started ? " [$cpu_note]" : '');
    close $fh;
}

sub containers {
    my ($rc) = @_;
    return unless -x $REAL_DOCKER;
    open(my $ph, '-|', $REAL_DOCKER, 'ps', '-a', '--filter', "label=rdocker.rrun=$label", '--format', '{{.Names}}') or return;
    my @names = grep { /^[A-Za-z0-9._-]+$/ } map { chomp; $_ } <$ph>;
    close $ph;
    return unless @names;
    my $keep = $h{keep_containers_on_fail} // 1;
    if ($rc == 0 || $lost || $intr || !$keep) { run_cmd('/dev/null', $REAL_DOCKER, 'rm', '-f', '-v', @names) }
    else { status("KEPT @names") }    # failed DBs stay for inspection; the janitor's idle rule reaps them
}

# The per-run docker shim: labels every container the run creates so `containers` can find them,
# and after `run -d` waits (<=5 s per port) until each published port answers. Calls the real
# docker by absolute path; everything that is not run/create is a plain exec.
sub write_shim {
    my ($path) = @_;
    fail("RR_REAL_DOCKER must not contain a quote", 65) if $REAL_DOCKER =~ /'/;
    my $sh = <<'SH';
#!/bin/sh
# rrun per-run docker shim (generated; deleted when the run ends)
REAL='@REAL@'
LABEL='rdocker.rrun=@LABEL@'
UP='@UP@'
: > '@USED@' 2>/dev/null
if [ -n "$UP" ] && [ ! -f "$UP.ok" ]; then "$UP" || exit 73; fi
state=global sub= first=1 detach=0
for a do
  if [ $first = 1 ]; then set --; first=0; fi
  set -- "$@" "$a"
  case $state in
    global) case $a in
        -c|--context|-H|--host|--config|-l|--log-level|--tlscacert|--tlscert|--tlskey) state=gval ;;
        -*) ;;
        container) state=sub ;;
        run|create) sub=$a; set -- "$@" --label "$LABEL"; state=args ;;
        *) state=pass ;;
      esac ;;
    gval) state=global ;;
    sub) case $a in run|create) sub=$a; set -- "$@" --label "$LABEL"; state=args ;; *) state=pass ;; esac ;;
    args) case $a in -d|--detach|--detach=true|-d[it]|-d[it][it]|-[it]d|-[it]d[it]|-[it][it]d) detach=1 ;; esac ;;
  esac
done
if [ "$sub" != run ] || [ $detach != 1 ]; then exec "$REAL" "$@"; fi
out=$("$REAL" "$@") || { rc=$?; [ -n "$out" ] && printf '%s\n' "$out"; exit $rc; }
printf '%s\n' "$out"
id=$(printf '%s\n' "$out" | tail -n 1)
for p in $("$REAL" port "$id" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | sort -u); do
  i=0
  while [ $i -lt 50 ] && ! nc -z 127.0.0.1 "$p" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
done
exit 0
SH
    $sh =~ s/\@REAL\@/$REAL_DOCKER/;
    $sh =~ s/\@LABEL\@/$label/;
    my $up = -f "$tmp/docker-up" ? "$tmp/docker-up" : '';
    fail("tmp path must not contain a quote", 65) if $up =~ /'/;
    $sh =~ s/\@UP\@/$up/;
    fail("tmp path must not contain a quote", 65) if $tmp =~ /'/;
    $sh =~ s/\@USED\@/$tmp\/docker.used/;
    write_file($path, $sh);
    chmod 0700, $path;
}

# ------------------------------------------------------------------------ Mac worker Docker VM
# A Mac worker has no Docker until Colima runs (as the rd user: no root, no GUI session needed).
# Managed only on macOS and only when colima is installed; Linux workers never get here.
sub colima_managed { $OS ne 'linux' && -x $COLIMA }
# Colima's docker socket: present while it runs, also when someone started it by hand.
sub colima_sock { -S ($ENV{RR_COLIMA_SOCK} || "$ENV{HOME}/.colima/default/docker.sock") }
sub colima_timeout { ($ENV{RR_COLIMA_TIMEOUT} // '') =~ /^(\d+)$/ ? $1 : 120 }

# $tmp/docker-up: exit 0 once `docker info` answers; else start Colima under the $ROOT/colima.lock
# mkdir lock (one start at a time across runs; a lock older than 15 min is stale) and wait for the
# engine up to RR_COLIMA_TIMEOUT s, else exit 73. The start itself runs in its own session, so a run
# that gives up (or is lost) never kills a half-done first start (about 90 s cold); the next run
# finds it up. Used before a db job (below) and by the docker shim on its first call.
sub write_docker_up {
    my ($path) = @_;
    my ($cpu, $mem, $disk) = @{ $VM{ share_level() } || $VM{max} };
    for ($REAL_DOCKER, $COLIMA, $ROOT) { fail("docker-up: path must not contain a quote", 65) if /'/ }
    my $sh = <<'SH';
#!/bin/sh
# rrun: make sure this Mac worker's Docker engine answers (generated; deleted when the run ends)
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; export PATH
REAL='@REAL@' COLIMA='@COLIMA@' ROOT='@ROOT@' OK='@OK@'
LOCK="$ROOT/colima.lock" MARK="$ROOT/state/colima.started"
up() { "$REAL" info >/dev/null 2>&1; }
[ -f "$OK" ] && exit 0
up && { : > "$OK"; exit 0; }
end=$(( $(date +%s) + @TIMEOUT@ ))
echo "rrun: Docker is not running on this worker - starting Colima (@CPU@ CPU, @MEM@ GB; a cold start takes 1-2 min)" >&2
mine=0
while :; do
  up && { : > "$OK"; exit 0; }
  [ "$(date +%s)" -ge "$end" ] && break
  if [ $mine = 0 ]; then
    [ -n "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
      mine=1
      mkdir -p "$ROOT/log" "$ROOT/state" && : > "$MARK"
      /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); $SIG{HUP} = "IGNORE"; exec @ARGV' /bin/sh -c         '"$1" start --cpu "$2" --memory "$3" --disk "$4" --vm-type vz --vz-rosetta; rmdir "$5"'         sh "$COLIMA" @CPU@ @MEM@ @DISK@ "$LOCK" </dev/null >>"$ROOT/log/colima.log" 2>&1 &
    fi
  elif [ ! -d "$LOCK" ]; then
    up && { : > "$OK"; exit 0; }
    echo "rrun: colima start failed (see ~/rr/log/colima.log on the worker)" >&2
    exit 73
  fi
  sleep 1
done
echo "rrun: Docker did not come up within @TIMEOUT@ s (see ~/rr/log/colima.log on the worker)" >&2
exit 73
SH
    my %v = (REAL => $REAL_DOCKER, COLIMA => $COLIMA, ROOT => $ROOT, OK => "$path.ok",
             TIMEOUT => colima_timeout(), CPU => $cpu, MEM => $mem, DISK => $disk);
    $sh =~ s/\@([A-Z]+)\@/$v{$1}/g;
    write_file($path, $sh);
    chmod 0700, $path;
}

# Before a db job: the engine must answer, else 73 (nothing ran: the client tries the next worker).
# Runs under supervise(), so heartbeats are read while Colima boots and a lost laptop stops the wait.
sub docker_up {
    my ($env) = @_;
    # its notes (stderr only; it never writes stdout) reach the laptop live during a cold boot
    my $rc = supervise(spawn(['/bin/sh', "$tmp/docker-up"], $env, $tmp));
    return if $rc == 0;
    return if $lost || $intr;    # main() reports it
    status('UNAVAIL docker');
    fail("the Docker engine on this worker did not start; not running the db job here", 73);
}

# Share off and no slot held (ours is released by now): stop Colima (one a run started, or one that
# is running anyway: its socket is there), in its own
# session so this run's exit does not wait for it. The same lock as the start keeps them apart.
sub colima_stop_if_off {
    return unless colima_managed() && share_level() eq 'off';
    my $mark = "$ROOT/state/colima.started";
    return unless (-f $mark && !-l $mark) || colima_sock();
    for my $f (grep { !/\.who$/ } glob("$ROOT/slots/*")) {
        sysopen(my $fh, $f, O_RDWR | O_NOFOLLOW) or next;
        return unless flock($fh, LOCK_SH | LOCK_NB);    # someone holds a slot: not now
        close $fh;
    }
    mkdir "$ROOT/colima.lock" or return;
    my $pid = fork;
    if (!defined $pid) { rmdir "$ROOT/colima.lock"; return }
    return if $pid;
    eval {    # the child never returns into the runner's own cleanup, whatever happens here
        setsid();
        $SIG{$_} = 'IGNORE' for qw(HUP INT TERM);
        open STDIN, '<', '/dev/null';
        mkdir "$ROOT/log", 0700;
        open(STDOUT, '>>', "$ROOT/log/colima.log") or open(STDOUT, '>', '/dev/null');
        open STDERR, '>&', \*STDOUT;
        $ENV{PATH} = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';
        system($COLIMA, 'stop');
        unlink $mark;
    };
    rmdir "$ROOT/colima.lock";
    _exit(0);
}

sub node_dir {    # $RR_NODE (from the header env) = a mise node version; else brew's node
    my $v = $h{env}{RR_NODE} // $ENV{RR_NODE};
    if (defined $v && $v =~ /^[A-Za-z0-9._-]+$/) {
        my ($mise) = grep { -x } '/opt/homebrew/bin/mise', "$ENV{HOME}/.local/bin/mise", '/usr/local/bin/mise', '/usr/bin/mise';
        if ($mise && open(my $ph, '-|', $mise, 'which', 'node', '--tool', "node\@$v")) {
            my $p = <$ph> // '';
            close $ph;
            return $1 if $p =~ m{^(/.*)/node\s*$};
        }
        print STDERR "rrun-runner: RR_NODE=$v not found via mise; using brew node\n";
    }
    return '/opt/homebrew/opt/node/bin' if -d '/opt/homebrew/opt/node/bin';
    # Linux server / a Mac worker's rd user without brew node: mise's global node
    my ($mise) = grep { -x } "$ENV{HOME}/.local/bin/mise", '/opt/homebrew/bin/mise', '/usr/local/bin/mise', '/usr/bin/mise';
    if ($mise && open(my $ph, '-|', $mise, 'which', 'node')) {
        my $p = <$ph> // '';
        close $ph;
        return $1 if $p =~ m{^(/.*)/node\s*$};
    }
    undef;
}
