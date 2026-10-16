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
#        optional env_files[], hb_timeout, slots_base, spare_min_free_pct, spare_max_load}
#   then tar_len bytes of an overlay tar (dirty/untracked/env files)
#   then the laptop stream: "." = heartbeat (alive); "INT\n" = forward SIGINT; "GO\n" = start.
# Exactly-once handshake: after checkout, overlay, deps and the slot, the runner prints
# "<nonce> READY" and waits. It spawns the command ONLY after reading "GO\n" (then prints
# "<nonce> STARTED"); EOF / INT / heartbeat timeout before GO => exit without running anything.
# So a laptop that never wrote GO knows the command never ran (=> safe to run it locally).
# Status lines go to STDERR as "<nonce> READY|STARTED|WAIT ...|BUSY|KEPT ...". The nonce is 128
# random bits the tested code never sees (not in its env, shim or container labels; those use a
# separate random label token), so it cannot forge them. Exit = the command's rc (or 128+sig);
# 65 bad header/overlay/unsafe path, 69 missing bare repo, 70 runner error, 73 no free slot,
# 78 dependency install (npm ci / prisma generate) failed, 130 gave up before the command started.
# Every run appends one line to $ROOT/log/runs.log (see run_log; no env values, never fails a run).
# Test-only overrides: RR_ROOT (default ~/rr), RR_PATH (command PATH after the shim dir),
# RR_REAL_DOCKER (default /opt/homebrew/bin/docker).
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
my $REAL_DOCKER = $ENV{RR_REAL_DOCKER} || '/opt/homebrew/bin/docker';
my $SLUG = qr/^(?!\.\.?$)[A-Za-z0-9._-]+$/;    # one path component; never "." or ".."

my (%h, $nonce, $label, $tmp, $mirror, $envlist, $lock_fh, $who, $started);
my (@env_written, @overlay);
my ($stdin_open, $inbuf, $last_hb, $go) = (1, '', time, 0);
my ($lost, $intr, $intr_done) = (0, 0, 0);    # lost: laptop gone / runner signalled; intr: Ctrl-C count
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
    $label = rand_hex();    # container label token: never the nonce (the command can read labels)
    take_slot();
    $t_slot = time;
    $tmp = File::Temp::tempdir("run-XXXXXXXX", DIR => mk("$ROOT/tmp"));
    write_shim("$tmp/docker");
    my $path = "$tmp:" . ($ENV{RR_PATH} // join ':', grep { defined } node_dir(), '/opt/homebrew/bin', '/usr/bin', '/bin');
    $ENV{PATH} = $path;    # git/node/npm below resolve the same way the command will
    $ENV{GIT_TERMINAL_PROMPT} = '0';
    exclude_root();
    my %env = map { defined $ENV{$_} ? ($_ => $ENV{$_}) : () } qw(HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL TERM);
    %env = (%env, %{ $h{env} }, PATH => $path, RRUN_REMOTE => '1');

    my $cwd = prepare_mirror();
    deps(\%env);
    return 128 + 15 if $lost;
    fail("interrupted before the command started", 130) if $intr;
    $t_ready = time;
    await_go();
    $started = 1;
    $t_spawn = time;
    my $pid = spawn($h{argv}, \%env, $cwd);
    status('STARTED');
    return supervise($pid);
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
        write_file($marker, "1\n");
    }
    my $ni = "$ROOT/.metadata_never_index";
    write_file($ni, '') unless -f $ni && !-l $ni;
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
sub spare_room {
    my $min = $h{spare_min_free_pct} // 25;
    my $max = $h{spare_max_load} // 1.5;
    my ($free) = sysctl_n('kern.memorystatus_level') =~ /^(\d+)/;
    my ($load) = sysctl_n('vm.loadavg') =~ /([\d.]+)/;
    my ($ncpu) = sysctl_n('hw.ncpu') =~ /^(\d+)/;
    return 0 unless defined $free && defined $load && $ncpu;
    return $free >= $min && $load / $ncpu <= $max;
}

sub take_slot {
    my $dir = mk("$ROOT/slots");
    my $n = $h{slots} && $h{slots} =~ /^\d+$/ ? $h{slots} : 1;
    my $base = defined $h{slots_base} && $h{slots_base} =~ /^\d+$/ && $h{slots_base} >= 1
        && $h{slots_base} < $n ? $h{slots_base} : $n;
    my $deadline = time + 60 * ($h{wait_min} // 30);
    my $said;
    while (1) {
        my $spare = $base < $n && spare_room();
        for my $i (0 .. ($spare ? $n : $base) - 1) {
            # flock(2) == the lock `/usr/bin/lockf -k` takes; it dies with this process (even -9).
            my $fh = open_nofollow("$dir/$i", O_RDWR);
            if (flock($fh, LOCK_EX | LOCK_NB)) {
                # Before anything else: bump the lock's mtime, then rewrite .who (with our pid).
                # The janitor trusts a held slot's .who only when it is not older than the lock
                # and its pid is alive, so a stale .who left by a run killed -9 never names the
                # wrong repo in the moment between our flock and this rewrite.
                utime(undef, undef, $fh);
                ($lock_fh, $who) = ($fh, "$dir/$i.who");
                write_file($who, "$h{repo_slug} " . int(time) . " $$\n");
                return;
            }
        }
        if (!$said++) {
            my ($slug, $t) = split ' ', slurp("$dir/0.who");
            status(sprintf "WAIT holder=%s age=%d", $slug // '?', time - ($t // time));
        }
        my $left = $deadline - time;
        if ($left <= 0) { status('BUSY'); fail(undef, 73) }
        pump($left < 5 ? $left : 5);    # EOF or Ctrl-C while we wait = the user gave up
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
sub sha_files { my $d = Digest::SHA->new(256); for (@_) { $d->add("$_\0"); $d->addfile($_) if -f $_ } $d->hexdigest }
sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; <$fh> // '' }

sub deps {
    my ($env) = @_;
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
        if (slurp("$dir/node_modules/.rr-deps-stamp") ne $stamp) {
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
sub spawn {
    my ($argv, $env, $cwd, $out) = @_;
    my $pid = fork // fail("fork: $!");
    return $pid if $pid;
    $SIG{$_} = 'DEFAULT' for qw(INT TERM HUP PIPE);    # ignored signals would survive exec
    setsid();                                          # own session + group: the only group we signal
    open STDIN, '<', '/dev/null';
    if ($out) { open STDOUT, '>', $out; open STDERR, '>&', \*STDOUT }
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

sub supervise {
    my ($pid) = @_;
    local $supervising = 1;
    my $hb = hb_timeout();
    my $term_at;
    while (alive($pid)) {
        pump(0.1);
        while ($intr > $intr_done) { $intr_done++; signal_group($pid, 'INT') }
        $lost = 1 if !$stdin_open || time - $last_hb > $hb;
        if ($lost && !$term_at) { signal_group($pid, 'TERM'); $term_at = time }
        signal_group($pid, 'KILL') if $term_at && time - $term_at > 10;    # skipped once reaped
    }
    my $s = $reaped{$pid};
    $s & 127 ? 128 + ($s & 127) : $s >> 8;
}

# ------------------------------------------------------------------------------------ end
sub finish {
    my ($rc) = @_;
    local $SIG{$_} = 'IGNORE' for qw(INT TERM HUP);    # cleanup must not be cut short
    eval { delete_env_files(0) };
    eval { containers($rc) } if $started;
    if ($who) { unlink $who; close $lock_fh }
    remove_tree($tmp) if $tmp;
    eval { run_log($rc) };    # bookkeeping only: never changes the run's outcome
}

# One line per run in $ROOT/log/runs.log (0600; dir 0700; one rotated generation, runs.log.1, past
# 5 MB): time, repo, worktree, commit, outcome, prepare/command seconds, then the first 120 chars
# of the argv with env-looking values redacted (-e X=.., --env=.., NAME=..). The header env is
# never logged. Tested code can write ~/rr: a planted symlink/hardlink at the log is replaced,
# never written through.
sub run_outcome {
    my ($rc) = @_;
    if ($started) { return $lost ? "lost rc=$rc" : $intr ? "interrupted rc=$rc" : "rc=$rc" }
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
        redact_argv();
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
    write_file($path, $sh);
    chmod 0700, $path;
}

sub node_dir {    # $RR_NODE (from the header env) = a mise node version; else brew's node
    my $v = $h{env}{RR_NODE} // $ENV{RR_NODE};
    if (defined $v && $v =~ /^[A-Za-z0-9._-]+$/) {
        my ($mise) = grep { -x } '/opt/homebrew/bin/mise', "$ENV{HOME}/.local/bin/mise";
        if ($mise && open(my $ph, '-|', $mise, 'which', 'node', '--tool', "node\@$v")) {
            my $p = <$ph> // '';
            close $ph;
            return $1 if $p =~ m{^(/.*)/node\s*$};
        }
        print STDERR "rrun-runner: RR_NODE=$v not found via mise; using brew node\n";
    }
    -d '/opt/homebrew/opt/node/bin' ? '/opt/homebrew/opt/node/bin' : undef;
}
