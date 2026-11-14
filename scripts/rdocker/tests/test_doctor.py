"""server/rd-doctor.sh (the worker's self-healing watchdog), its install (rd-resilience, rd-verify, the Mac
LaunchDaemon) and rd-tune honouring its drain. Every rule runs for real against a fake ~/rr, real
processes we spawn (dead pids, a fake runner holding a slot), and fake docker/ps/systemctl/launchctl/df
through the script's env hooks. Nothing touches this machine's real services."""
import json
import os
import pwd
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

import rdmods
from rdmods import STAGE

SERVER = os.path.join(STAGE, "server")
SHARE = os.path.join(STAGE, "share")
DOCTOR = os.path.join(SERVER, "rd-doctor.sh")
TUNE = os.path.join(SERVER, "rd-tune.sh")
RESIL = os.path.join(SERVER, "rd-resilience.sh")
VERIFY = os.path.join(SERVER, "rd-verify.sh")
MAC_INSTALL = os.path.join(SHARE, "install-doctor-mac.sh")
MAC_PLIST = os.path.join(SHARE, "com.rdocker.doctor.plist")
ME = pwd.getpwuid(os.getuid()).pw_name

# A stand-in for rr_runner.pl holding slot 0: flocks the lock, setsid()s its command (a sleep) into its own
# group, writes .who "<slug> <epoch> <pid> <wt12>" (epoch shifted by argv[2]) and the child pid to ./child.
# argv[1] = 1: both ignore TERM (only KILL ends them).
RUNNER = r'''
use POSIX (); use Fcntl qw(:flock);
my ($dir, $ign, $off, $who_extra) = @ARGV;
$0 = "rrun-runner owner=test";
open(my $l, ">>", "$dir/0") or die; flock($l, LOCK_EX) or die;
my $c = fork;
if (!$c) { POSIX::setsid(); $SIG{TERM} = "IGNORE" if $ign; exec "/bin/sleep", "60"; }
open(my $w, ">", "$dir/0.who.tmp") or die;
print $w "repo " . (int(time) + $off) . " $$ abcdef012345$who_extra\n"; close $w;
rename "$dir/0.who.tmp", "$dir/0.who";
open(my $k, ">", "$dir/child.tmp"); print $k "$c\n"; close $k; rename "$dir/child.tmp", "$dir/child";
$SIG{TERM} = $ign ? "IGNORE" : sub { kill "TERM", -$c; waitpid($c, 0); unlink "$dir/0.who"; exit 143 };
sleep 1 while 1;
'''


def read(p):
    with open(p) as f:
        return f.read()


def write(p, text, mode=None):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)
    if mode:
        os.chmod(p, mode)
    return p


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # a zombie child of ours counts as gone
    try:
        return os.waitpid(pid, os.WNOHANG) == (0, 0)
    except ChildProcessError:
        return True


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class DoctorBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-doc-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.rr = os.path.join(self.tmp, "rr")
        self.slots = os.path.join(self.rr, "slots")
        for d in ("slots", "log", "tmp"):
            os.makedirs(os.path.join(self.rr, d))
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.st = os.path.join(self.tmp, "st")
        self.status = os.path.join(self.tmp, "run", "doctor")
        self.drain = os.path.join(self.tmp, "run", "drain")
        self.cap = os.path.join(self.rr, "slots.cap")
        self.df = self.fake_df(50)

    # ---- helpers
    def stub(self, name, body):
        return write(os.path.join(self.bin, name), "#!/bin/sh\n" + body + "\n", 0o755)

    def fake_df(self, free_pct):
        return self.stub("fake-df-%d" % free_pct,
                         "echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'\n"
                         "echo 'fake 1000000 %d %d 0%% /'" % (1000000 - free_pct * 10000, free_pct * 10000))

    def conf(self, **kv):
        kv = {"RD_USER": ME, **kv}
        return write(os.path.join(self.tmp, "doctor.conf"), "".join('%s="%s"\n' % i for i in sorted(kv.items())))

    def doctor(self, *args, conf=None, os_name="linux", services=False, **extra):
        env = dict(RD_OS=os_name, RD_DOCTOR_CONF=self.conf(**(conf or {})), RD_CONF="/nonexistent",
                   RD_RR_ROOT=self.rr, RD_STATE_DIR=self.st, RD_DOCTOR_STATUS=self.status,
                   RD_DRAIN_FILE=self.drain, RD_DOCKER="/nonexistent", RD_MEM_PCT="50", RD_DF_CMD=self.df)
        if not services:
            env["RD_NO_SERVICES"] = "1"
        env.update(extra)
        r = subprocess.run(["/bin/bash", DOCTOR] + list(args), capture_output=True, text=True, timeout=90,
                           env=rdmods.child_env(self.tmp, self.bin, **env))
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def log(self):
        p = os.path.join(self.rr, "log", "doctor.log")
        return read(p) if os.path.exists(p) else ""

    def dead_pid(self):
        p = subprocess.Popen(["/bin/sleep", "30"])
        p.kill()
        p.wait()
        return p.pid

    def sleeper(self):
        p = subprocess.Popen(["/bin/sleep", "60"])
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        return p.pid

    def who(self, slot, pid, epoch=None, extra="", own=None):
        lock = os.path.join(self.slots, str(slot))
        open(lock, "a").close()
        write(lock + ".who", "repo %d %d abcdef012345%s\n" % (time.time() if epoch is None else epoch, pid, extra))
        if own is not None:
            write(lock + ".own", own + "\n")
        return lock

    def hold(self, lock):
        """Hold a slot flock like the runner (perl flock(2)) -> the holder's pid."""
        ready = lock + ".ready"
        p = subprocess.Popen(["/usr/bin/perl", "-e", 'use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die;'
                              ' flock($f, LOCK_EX) or die; open(my $r, ">", $ARGV[1]); close $r; sleep 60',
                              lock, ready])
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        self.wait_for(ready)
        return p.pid

    def wait_for(self, path):
        for _ in range(200):
            if os.path.exists(path):
                return
            time.sleep(0.05)
        self.fail("timed out waiting for " + path)

    def runner(self, ignore_term=False, epoch_off=0, who_extra=""):
        """-> (runner Popen, command pid). The command leads its own process group."""
        p = subprocess.Popen(["/usr/bin/perl", "-e", RUNNER, self.slots, "1" if ignore_term else "0",
                              str(epoch_off), who_extra])
        self.addCleanup(p.wait)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        child_f = os.path.join(self.slots, "child")
        self.wait_for(child_f)
        child = int(read(child_f))

        def reap_child():
            try:
                os.killpg(child, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        self.addCleanup(reap_child)
        return p, child

    def status_json(self):
        return json.loads(read(self.status))


# ------------------------------------------------------------------------------------------- static
class Static(unittest.TestCase):
    def test_bash_syntax(self):
        for p in (DOCTOR, MAC_INSTALL):
            r = subprocess.run(["/bin/bash", "-n", p], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_shellcheck_when_available(self):
        sc = shutil.which("shellcheck", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin")
        if not sc:
            self.skipTest("shellcheck not installed")
        r = subprocess.run([sc, "-S", "warning", DOCTOR, MAC_INSTALL, TUNE, RESIL, VERIFY], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_linux_units_every_30s_as_root_oneshot(self):
        t = read(os.path.join(SERVER, "rd-doctor.timer"))
        self.assertIn("OnUnitActiveSec=30", t)
        self.assertIn("WantedBy=timers.target", t)
        s = read(os.path.join(SERVER, "rd-doctor.service"))
        self.assertIn("ExecStart=/usr/local/bin/rd-doctor", s)
        self.assertIn("Type=oneshot", s)
        self.assertNotIn("User=", s)                       # root: signals go through runuser -u rd

    def test_mac_launchdaemon_runs_as_rd_every_30s(self):
        p = read(MAC_PLIST)
        for needle in ("<string>com.rdocker.doctor</string>", "<key>StartInterval</key><integer>30</integer>",
                       "<key>UserName</key><string>__USER__</string>", "/usr/local/libexec/rd-doctor"):
            self.assertIn(needle, p)
        s = read(MAC_INSTALL)
        for needle in ("launchctl bootstrap system", "launchctl bootout system/com.rdocker.doctor", "--lift",
                       "/Library/LaunchDaemons/com.rdocker.doctor.plist", "../server/rd-doctor.sh"):
            self.assertIn(needle, s)

    def test_every_rule_documented_and_switchable(self):
        s = read(DOCTOR)
        for rule in ("orphan-slot", "hung-job", "orphan-container", "reporter", "drain", "disk", "spotlight"):
            self.assertIn("rule_on %s" % rule if rule != "orphan-slot" else "rule_on orphan-slot", s)
        for knob in ("DOCTOR_DISABLE", "RD_DOCTOR_DRY", "DOCTOR_RULES"):
            self.assertIn(knob, s)


# ---------------------------------------------------------------------------------------- orphan slots
class OrphanSlot(DoctorBase):
    def test_dead_pid_and_free_lock_removes_who_and_own_never_the_lock(self):
        pid = self.dead_pid()
        lock = self.who(0, pid, own="id=x\tpid=%d" % pid)
        self.doctor()
        self.assertFalse(os.path.exists(lock + ".who"))
        self.assertFalse(os.path.exists(lock + ".own"))
        self.assertTrue(os.path.exists(lock))
        self.assertRegex(self.log(), r"^\S+ orphan-slot remove slot:0 pid=%d repo=repo " % pid)

    def test_held_lock_is_never_touched_even_with_a_dead_pid(self):
        lock = self.who(0, self.dead_pid())
        self.hold(lock)
        self.doctor()
        self.assertTrue(os.path.exists(lock + ".who"))
        self.assertNotIn("orphan-slot", self.log())

    def test_live_pid_on_a_free_slot_is_left(self):
        lock = self.who(0, self.sleeper())
        self.doctor()
        self.assertTrue(os.path.exists(lock + ".who"))

    def test_dry_run_only_logs(self):
        lock = self.who(0, self.dead_pid())
        self.doctor(RD_DOCTOR_DRY="1")
        self.assertTrue(os.path.exists(lock + ".who"))
        self.assertIn("orphan-slot would-remove slot:0", self.log())


# ------------------------------------------------------------------------------------------- hung jobs
class HungJob(DoctorBase):
    FAST = {"DOCTOR_CAPS": "light=1 normal=1 heavy=1 db=1 build=1", "DOCTOR_GRACE_S": "0", "DOCTOR_TERM_WAIT_S": "2"}

    def test_past_cap_terms_runner_and_its_command_group(self):
        p, child = self.runner()
        time.sleep(2.2)
        self.doctor(conf=self.FAST)
        p.wait(timeout=10)
        self.assertFalse(group_alive(child))
        self.assertRegex(self.log(), r"hung-job kill slot:0 pid=%d repo=repo age=\d+s cap=1s cls=- groups=%d "
                                     r"signal=TERM result=gone" % (p.pid, child))

    def test_term_ignored_gets_kill_and_is_confirmed_gone(self):
        p, child = self.runner(ignore_term=True)
        time.sleep(2.2)
        self.doctor(conf=self.FAST)
        p.wait(timeout=10)
        self.assertFalse(group_alive(child))
        self.assertIn("signal=KILL result=gone", self.log())
        # the runner died by KILL: its .who is left, and the next tick reaps it (orphan-slot)
        self.doctor(conf=self.FAST)
        self.assertFalse(os.path.exists(os.path.join(self.slots, "0.who")))
        self.assertIn("orphan-slot remove slot:0 pid=%d" % p.pid, self.log())

    def test_within_cap_plus_grace_is_left(self):
        p, child = self.runner()
        time.sleep(1.2)
        self.doctor(conf={**self.FAST, "DOCTOR_GRACE_S": "300"})
        self.assertIsNone(p.poll())
        self.assertTrue(group_alive(child))
        self.assertNotIn("hung-job", self.log())

    def test_class_cap_read_from_who_or_own_else_longest(self):
        caps = {**self.FAST, "DOCTOR_CAPS": "light=1 normal=1 heavy=1 db=100000 build=1"}
        p, child = self.runner()                           # no class anywhere: the longest cap (db)
        time.sleep(2.2)
        self.doctor(conf=caps)
        self.assertIsNone(p.poll())
        write(os.path.join(self.slots, "0.own"), "id=x\tpid=999999\tcls=light\n")   # .own of another pid: ignored
        self.doctor(conf=caps)
        self.assertIsNone(p.poll())
        write(os.path.join(self.slots, "0.own"), "id=x\tpid=%d\tcls=light\n" % p.pid)
        self.doctor(conf=caps)
        p.wait(timeout=10)
        self.assertIn("cls=light", self.log())

    def test_class_word_on_who_and_explicit_no_cap(self):
        caps = {**self.FAST, "DOCTOR_CAPS": "light=1 normal=1 heavy=1 db=100000 build=1"}
        p, _ = self.runner(who_extra=" cap_s=0")           # RRUN_TIMEOUT=0: the job asked for no cap
        time.sleep(2.2)
        self.doctor(conf=caps)
        self.assertIsNone(p.poll())
        p.kill()
        p.wait()
        os.unlink(os.path.join(self.slots, "child"))
        p2, _ = self.runner(who_extra=" light")
        time.sleep(2.2)
        self.doctor(conf=caps)
        p2.wait(timeout=10)
        self.assertIn("pid=%d repo=repo age=" % p2.pid, self.log())

    def test_reused_pid_is_never_killed(self):
        """The .who epoch is from long before this process started: its pid was reused."""
        pid = self.sleeper()
        self.hold(self.who(0, pid, epoch=int(time.time()) - 100000))
        self.doctor(conf=self.FAST)
        self.assertTrue(alive(pid))
        self.assertRegex(self.log(), r"hung-job skip slot:0 pid=%d started \d+s after the .who epoch" % pid)

    def test_process_of_another_user_is_never_killed(self):
        pid = self.sleeper()
        self.hold(self.who(0, pid, epoch=int(time.time()) - 10))
        ps = self.stub("fake-ps", "echo '%d 1 %d 0 00:30 S rrun-runner owner=x'" % (pid, pid))
        self.doctor(conf=self.FAST, RD_PS_CMD=ps)
        self.assertTrue(alive(pid))
        self.assertIn("hung-job skip slot:0 pid=%d uid=0 is not %s" % (pid, ME), self.log())

    def test_dry_run_kills_nothing(self):
        p, child = self.runner()
        time.sleep(2.2)
        self.doctor(conf=self.FAST, RD_DOCTOR_DRY="1")
        self.assertIsNone(p.poll())
        self.assertTrue(group_alive(child))
        self.assertIn("hung-job would-kill slot:0 pid=%d" % p.pid, self.log())


# ----------------------------------------------------------------------------------- orphan containers
class OrphanContainers(DoctorBase):
    def setUp(self):
        super().setUp()
        self.calls = os.path.join(self.tmp, "docker-calls")
        self.fix = os.path.join(self.tmp, "docker-ps")
        self.docker = self.stub("fake-docker", 'case "$1" in ps) cat "%s" ;; rm) echo "$*" >> "%s" ;; *) exit 1 ;; esac'
                                % (self.fix, self.calls))

    @staticmethod
    def created(age_s):
        return time.strftime("%Y-%m-%d %H:%M:%S +0000 UTC", time.gmtime(time.time() - age_s))

    def ct(self, cid, age_s, labels):
        return "%s\t%s\t%s\n" % (cid * 64 if len(cid) == 1 else cid, self.created(age_s), labels)

    def removed(self):
        return read(self.calls) if os.path.exists(self.calls) else ""

    def test_only_old_unowned_run_containers_go(self):
        live_shim, live_own, dead = "1" * 32, "2" * 32, "3" * 32
        # a live run: slot 0 held, its shim written just after its .who epoch
        lock0 = self.who(0, os.getpid())
        self.hold(lock0)
        write(os.path.join(self.rr, "tmp", "run-abcd1234", "docker"), "LABEL='rdocker.rrun=%s'\n" % live_shim)
        # a live run that names its label in .own (exact)
        lock1 = self.who(1, os.getpid(), own="id=x\tpid=%d\tlabel=%s" % (os.getpid(), live_own))
        self.hold(lock1)
        # a dead run's shim, written long before any live .who epoch
        old = os.path.join(self.rr, "tmp", "run-dead0000", "docker")
        write(old, "LABEL='rdocker.rrun=%s'\n" % dead)
        os.utime(old, (time.time() - 7200, time.time() - 7200))
        with open(self.fix, "w") as f:
            f.write(self.ct("a", 600, "rdocker.rrun=%s,com.docker.compose.project=x" % dead))   # orphan -> rm
            f.write(self.ct("b", 30, "rdocker.rrun=%s" % dead))                                 # too young
            f.write(self.ct("c", 600, "rdocker.rrun=%s,rdocker.keep=1" % dead))                 # keep
            f.write(self.ct("d", 600, "rdocker.keep=0,rdocker.rrun=%s" % dead))                 # keep (any value)
            f.write(self.ct("e", 600, "rdocker.rrun=%s" % live_shim))                           # live via shim
            f.write(self.ct("f", 600, "rdocker.rrun=%s" % live_own))                            # live via .own
            f.write(self.ct("9", 600, "app=db"))                                                # no run label
        self.doctor(RD_DOCKER=self.docker)
        self.assertEqual(self.removed().strip(), "rm -f -v " + "a" * 64)
        self.assertIn("orphan-container rm aaaaaaaaaaaa run=333333333333 age=", self.log())

    def test_no_live_run_at_all_means_every_old_run_container_is_orphan(self):
        with open(self.fix, "w") as f:
            f.write(self.ct("a", 600, "rdocker.rrun=%s" % ("4" * 32)))
        self.doctor(RD_DOCKER=self.docker)
        self.assertIn("rm -f -v " + "a" * 64, self.removed())

    def test_dry_run_removes_nothing(self):
        with open(self.fix, "w") as f:
            f.write(self.ct("a", 600, "rdocker.rrun=%s" % ("4" * 32)))
        self.doctor(RD_DOCKER=self.docker, RD_DOCTOR_DRY="1")
        self.assertEqual(self.removed(), "")
        self.assertIn("orphan-container would-rm aaaaaaaaaaaa", self.log())

    def test_no_engine_is_a_quiet_no_op(self):
        self.doctor(RD_DOCKER=os.path.join(self.tmp, "no-docker"))
        self.assertNotIn("orphan-container", self.log())


# --------------------------------------------------------------------------------------------- reporter
class Reporter(DoctorBase):
    def setUp(self):
        super().setUp()
        self.calls = os.path.join(self.tmp, "calls")
        self.active = os.path.join(self.tmp, "active-rc")

    def linux(self, active):
        write(self.active, "0" if active else "3")
        write(os.path.join(self.tmp, ".config", "systemd", "user", "rd-reporter.service"), "[Service]\n")
        self.stub("systemctl", 'echo "$*" >> "%s"\ncase "$*" in *is-active*) exit $(cat "%s") ;; esac'
                  % (self.calls, self.active))
        return self.doctor(services=True)

    def test_linux_inactive_reporter_restarted_once_per_cooldown(self):
        self.linux(active=False)
        self.assertIn("--user restart rd-reporter.service", read(self.calls))
        self.assertIn("reporter restart rd-reporter", self.log())
        self.linux(active=False)                                  # within 5 min: no second restart
        self.assertEqual(read(self.calls).count("restart rd-reporter.service"), 1)

    def test_linux_active_reporter_left_alone(self):
        self.linux(active=True)
        self.assertNotIn("restart", read(self.calls))

    def test_linux_not_installed_is_skipped(self):
        self.stub("systemctl", 'echo "$*" >> "%s"; exit 3' % self.calls)
        self.doctor(services=True)
        self.assertFalse(os.path.exists(self.calls))

    def test_mac_kickstart_when_label_loaded_but_not_running(self):
        self.stub("launchctl", 'case "$1" in print) echo "state = not running" ;; kickstart) echo "kickstart $2" >> "%s" ;; esac'
                  % self.calls)
        self.doctor(os_name="darwin", services=True, conf={"DOCTOR_RULES": "reporter"})
        self.assertEqual(read(self.calls).strip(), "kickstart gui/%d/com.rdocker.reporter" % os.getuid())

    def test_mac_label_absent_does_nothing(self):
        self.stub("launchctl", 'case "$1" in print) exit 113 ;; kickstart) echo "kickstart $2" >> "%s" ;; esac' % self.calls)
        self.doctor(os_name="darwin", services=True, conf={"DOCTOR_RULES": "reporter"})
        self.assertFalse(os.path.exists(self.calls))


# ------------------------------------------------------------------------------------------------ drain
class Drain(DoctorBase):
    def runs(self, *ages_outcomes):
        lines = []
        for age, outcome in ages_outcomes:
            ts = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(time.time() - age))
            lines.append("%s repo=r wt=w sha=abc outcome=%s prepare_s=1.0 cmd_s=2.0 argv=npm test\n" % (ts, outcome))
        write(os.path.join(self.rr, "log", "runs.log"), "".join(lines))

    def test_three_infra_failures_drain_then_three_healthy_ticks_reopen(self):
        write(self.cap, "4\n")
        self.runs((10, "lost rc=255"), (20, "deps-failed"), (30, "rc=134"), (40, "rc=1"), (50, "busy"))
        self.doctor()
        self.assertEqual(read(self.cap).strip(), "0")
        self.assertIn("prev=4", read(self.drain))
        self.assertTrue(self.status_json()["drained"])
        self.assertIn("drain drain worker infra=3/300s (slots.cap 4 -> 0)", self.log())
        self.runs((10, "rc=0"))
        self.doctor()
        self.doctor()
        self.assertTrue(os.path.exists(self.drain))
        self.assertEqual(read(self.cap).strip(), "0")
        self.doctor()
        self.assertFalse(os.path.exists(self.drain))
        self.assertEqual(read(self.cap).strip(), "4")
        st = self.status_json()
        self.assertFalse(st["drained"])
        self.assertIn("drain undrain worker healthy 3 checks in a row (slots.cap -> 4)", self.log())

    def test_runner_pre_start_errors_drain(self):
        """error rc=70 = the runner's own failure before the start (2026-11-13: an unwritable ~/rr/w2)."""
        self.runs((10, "error rc=70"), (20, "error rc=70"), (30, "error rc=70"), (40, "error rc=2"))
        self.doctor()
        self.assertIn("infra=3/300s", read(self.drain))

    def test_old_or_command_failures_do_not_drain(self):
        # bare "lost" (pre-2026-11-11 label of a client that left before the start), abandoned-setup,
        # moved and warm are not worker faults; only "lost rc=N" (started, never reattached) is
        self.runs((400, "lost rc=255"), (500, "lost"), (10, "rc=1"), (20, "timeout rc=124"), (30, "lost"), (40, "rc=2"),
                  (41, "abandoned-setup"), (42, "moved"), (43, "warm"), (44, "lost rc=255"))
        self.doctor()
        self.assertFalse(os.path.exists(self.drain))
        self.assertEqual(self.status_json()["infra_recent"], 1)

    def test_critical_memory_or_disk_drains(self):
        self.doctor(RD_MEM_PCT="3")
        self.assertIn("mem_free=3%", read(self.drain))
        self.assertEqual(read(self.cap).strip(), "0")
        os.unlink(self.drain)
        self.df = self.fake_df(2)
        self.doctor()
        self.assertIn("disk_free=2%", read(self.drain))

    def test_disk_under_the_rr_image_counts_too(self):
        """rd-rrfs: ~/rr on a sparse image; its own fs can look fine while the disk under it is full."""
        imgdir = os.path.join(self.tmp, "varlib")
        os.makedirs(imgdir)
        img = write(os.path.join(imgdir, "rr.xfs"), "")
        self.df = self.stub("fake-df-split", 'case "$1" in %s) f=3 ;; *) f=50 ;; esac\n'
                            "echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'\n"
                            "echo \"fake 1000000 0 $((f * 10000)) 0%% /\"" % imgdir)
        self.doctor(RD_RRFS_IMG=img)
        self.assertIn("disk_free=3%", read(self.drain))
        self.assertIn("disk critical %s free=3%%" % imgdir, self.log())
        os.unlink(self.drain)
        self.doctor(RD_RRFS_IMG=os.path.join(imgdir, "absent.xfs"))     # no image: only ~/rr counts
        self.assertFalse(os.path.exists(self.drain))

    def test_unhealthy_tick_resets_the_streak(self):
        self.doctor(RD_MEM_PCT="3")
        self.doctor()
        self.doctor()
        self.doctor(RD_MEM_PCT="3")
        self.doctor()
        self.doctor()
        self.assertTrue(os.path.exists(self.drain))
        self.doctor()
        self.assertFalse(os.path.exists(self.drain))
        self.assertFalse(os.path.exists(self.cap))            # there was no cap file before the drain

    def test_dry_run_never_drains(self):
        self.doctor(RD_MEM_PCT="3", RD_DOCTOR_DRY="1")
        self.assertFalse(os.path.exists(self.drain))
        self.assertFalse(os.path.exists(self.cap))
        self.assertIn("drain would-drain worker mem_free=3%", self.log())

    def test_lift_by_hand(self):
        write(self.cap, "2\n")
        self.doctor(RD_MEM_PCT="3")
        self.doctor("--lift")
        self.assertFalse(os.path.exists(self.drain))
        self.assertEqual(read(self.cap).strip(), "2")


class WakeGrace(DoctorBase):
    """A lid close cuts every running job; on wake each is logged `lost rc=N` at once. On macOS rows from the
    DOCTOR_WAKE_GRACE_S after the last wake are the sleep's, not a sick worker's: no drain."""
    LOSSES = ((10, "lost rc=255"), (20, "lost rc=255"), (30, "lost rc=255"))
    runs = Drain.runs

    def test_losses_logged_right_after_a_wake_do_not_drain_a_mac(self):
        self.runs(*self.LOSSES)
        self.doctor(os_name="darwin", conf={"DOCTOR_RULES": "drain"}, RD_WAKE_TIME=str(int(time.time()) - 60))
        self.assertFalse(os.path.exists(self.drain))
        self.assertEqual(self.status_json()["infra_recent"], 0)

    def test_losses_long_after_the_wake_still_drain(self):
        self.runs(*self.LOSSES)
        self.doctor(os_name="darwin", conf={"DOCTOR_RULES": "drain"}, RD_WAKE_TIME=str(int(time.time()) - 3600))
        self.assertTrue(os.path.exists(self.drain))
        self.assertEqual(self.status_json()["infra_recent"], 3)

    def test_linux_has_no_wake_grace(self):
        self.runs(*self.LOSSES)
        self.doctor(RD_WAKE_TIME=str(int(time.time()) - 60))
        self.assertTrue(os.path.exists(self.drain))


class ColimaWedged(DoctorBase):
    """macOS: rd's Colima socket is there but the engine does not answer (a VM wedged by sleep) -> after
    DOCTOR_COLIMA_BAD_N ticks, with no slot held, `colima stop --force`; the next job starts it fresh."""
    def setUp(self):
        super().setUp()
        import socket
        self.sock_path = os.path.join(self.tmp, "c.sock")
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.bind(self.sock_path)
        self.addCleanup(self.sock.close)
        self.calls = os.path.join(self.tmp, "colima.calls")
        self.colima = self.stub("colima", 'echo "$*" >> "%s"' % self.calls)
        self.docker_bad = self.stub("docker-bad", "exit 1")
        self.docker_ok = self.stub("docker-ok", "exit 0")
        write(os.path.join(self.rr, "state", "colima.started"), "")

    def tick(self, docker=None, os_name="darwin"):
        return self.doctor(os_name=os_name, conf={"DOCTOR_RULES": "colima"}, RD_COLIMA=self.colima,
                           RD_COLIMA_SOCK=self.sock_path, RD_DOCKER=docker or self.docker_bad)

    def stops(self):
        return read(self.calls).splitlines() if os.path.exists(self.calls) else []

    def test_two_wedged_ticks_stop_it_once(self):
        self.tick()
        self.assertEqual(self.stops(), [])                              # one bad tick: could be a slow answer
        self.tick()
        self.assertEqual(self.stops(), ["stop --force"])
        self.assertIn("colima stop colima engine not answering for 2 checks", self.log())
        self.assertFalse(os.path.exists(os.path.join(self.rr, "state", "colima.started")))
        self.assertFalse(os.path.exists(os.path.join(self.rr, "colima.lock")))
        self.tick()
        self.tick()
        self.assertEqual(self.stops(), ["stop --force"])                # 10 min cooldown

    def test_an_answering_engine_resets_the_count(self):
        self.tick()
        self.tick(docker=self.docker_ok)
        self.tick()
        self.assertEqual(self.stops(), [])

    def test_never_under_a_held_slot_or_a_start_in_progress(self):
        self.hold(self.who(0, os.getpid()))
        for _ in range(3):
            self.tick()
        self.assertEqual(self.stops(), [])

    def test_a_job_taking_a_slot_after_the_slot_scan_blocks_the_stop(self):
        """The race: the tick's slot list is empty, then a runner takes a slot before the stop. The stop runs
        only while the doctor holds every slot lock, so it must not happen (and no cooldown is spent)."""
        lock = os.path.join(self.slots, "0")
        open(lock, "a").close()
        pidf, ready = os.path.join(self.tmp, "holder.pid"), os.path.join(self.tmp, "holder.ready")
        # `docker info` runs after rule_slots: it starts a detached holder of slot 0, then reports a dead engine
        racer = self.stub("docker-race",
                          '[ -f "%s" ] || { /usr/bin/perl -e \'use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die;'
                          ' flock($f, LOCK_EX) or die; open(my $r, ">", $ARGV[1]); close $r; sleep 30\' "%s" "%s" '
                          '</dev/null >/dev/null 2>&1 & echo $! > "%s"; while [ ! -f "%s" ]; do sleep 0.05; done; }\n'
                          'exit 1' % (pidf, lock, ready, pidf, ready))

        def kill_holder():
            if os.path.exists(pidf):
                try:
                    os.kill(int(read(pidf)), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.addCleanup(kill_holder)
        self.tick(docker=self.docker_bad)
        self.tick(docker=racer)                                         # 2nd bad tick: would stop, but slot 0 is taken
        self.assertTrue(os.path.exists(ready))
        self.assertEqual(self.stops(), [])
        self.assertFalse(os.path.exists(os.path.join(self.rr, "colima.lock")))
        kill_holder()
        time.sleep(0.2)
        self.tick()                                                     # slot free again: no cooldown was spent
        self.assertEqual(self.stops(), ["stop --force"])

    def test_never_while_colima_lock_is_held(self):
        os.makedirs(os.path.join(self.rr, "colima.lock"))
        for _ in range(3):
            self.tick()
        self.assertEqual(self.stops(), [])

    def test_dry_run_and_linux_never_stop(self):
        self.doctor(os_name="darwin", conf={"DOCTOR_RULES": "colima"}, RD_COLIMA=self.colima,
                    RD_COLIMA_SOCK=self.sock_path, RD_DOCKER=self.docker_bad, RD_DOCTOR_DRY="1")
        self.doctor(os_name="darwin", conf={"DOCTOR_RULES": "colima"}, RD_COLIMA=self.colima,
                    RD_COLIMA_SOCK=self.sock_path, RD_DOCKER=self.docker_bad, RD_DOCTOR_DRY="1")
        self.assertEqual(self.stops(), [])
        self.assertIn("colima would-stop colima", self.log())
        self.tick(os_name="linux")
        self.tick(os_name="linux")
        self.assertEqual(self.stops(), [])


class TuneHonoursDrain(unittest.TestCase):
    """rd-tune keeps slots.cap at 0 while the doctor's drain marker is fresh, and ignores a stale one."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-tdr-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.rr = os.path.join(self.tmp, "rr")
        os.makedirs(os.path.join(self.rr, "slots"))
        self.cap = os.path.join(self.rr, "slots.cap")
        self.drain = write(os.path.join(self.tmp, "drain"), "since=1\nreason=x\nprev=4\n")
        write(os.path.join(self.tmp, "meminfo"), "MemTotal: 1000 kB\nMemAvailable: 900 kB\n")
        write(os.path.join(self.tmp, "tune.conf"), "RD_USER=nobody\nMAX_SLOTS=4\nIS_HOME=0\n")

    def tune(self):
        env = rdmods.child_env(self.tmp, RD_CONF=os.path.join(self.tmp, "tune.conf"),
                               RD_MEMINFO=os.path.join(self.tmp, "meminfo"), RD_CAP_FILE=self.cap,
                               RD_RR_ROOT=self.rr, RD_STATE_DIR=os.path.join(self.tmp, "st"), RD_NO_SERVICES="1",
                               RD_TEMP_FILES="/nonexistent", RD_DRAIN_FILE=self.drain, RD_DF_CMD="true")
        r = subprocess.run(["/bin/bash", TUNE], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return read(self.cap).strip()

    def test_fresh_marker_means_cap_zero_stale_marker_is_ignored(self):
        self.assertEqual(self.tune(), "0")
        old = time.time() - 600
        os.utime(self.drain, (old, old))
        self.assertEqual(self.tune(), "4")
        os.unlink(self.drain)
        self.assertEqual(self.tune(), "4")


# ---------------------------------------------------------------------------------- kill switch / disk
class KillSwitchAndDisk(DoctorBase):
    def test_kill_switch_does_nothing_and_lifts_its_drain(self):
        lock = self.who(0, self.dead_pid())
        write(self.cap, "0\n")
        write(self.drain, "since=1\nreason=x\nprev=3\n")
        self.doctor(conf={"DOCTOR_DISABLE": "1"}, RD_MEM_PCT="3")
        self.assertTrue(os.path.exists(lock + ".who"))
        self.assertFalse(os.path.exists(self.drain))
        self.assertEqual(read(self.cap).strip(), "3")
        st = self.status_json()
        self.assertTrue(st["disabled"])
        self.assertFalse(st["drained"])
        self.assertIn("drain undrain worker kill switch", self.log())

    def test_rules_can_be_switched_off_one_by_one(self):
        lock = self.who(0, self.dead_pid())
        self.doctor(conf={"DOCTOR_RULES": "drain disk"})
        self.assertTrue(os.path.exists(lock + ".who"))

    def test_low_disk_logs_one_critical_line_per_10_min(self):
        self.df = self.fake_df(8)
        self.doctor()
        self.doctor()
        self.assertEqual(self.log().count("disk critical %s free=8%%" % self.rr), 1)
        self.assertFalse(os.path.exists(self.drain))            # 8 % logs; only < 5 % drains

    def test_status_contract(self):
        pid = self.dead_pid()
        self.who(0, pid)
        self.doctor()
        st = self.status_json()
        for k in ("v", "os", "ts", "disabled", "dry", "drained", "drain_since", "drain_reason", "ok_streak",
                  "infra_recent", "mem_free_pct", "disk_free_pct", "actions_1h", "last_action"):
            self.assertIn(k, st)
        self.assertEqual((st["v"], st["os"], st["actions_1h"], st["drained"], st["mem_free_pct"]), (1, "linux", 1, False, 50))
        self.assertIn("orphan-slot remove slot:0", st["last_action"])
        self.assertLess(abs(st["ts"] - time.time()), 30)

    def test_log_line_format_and_no_symlink_follow(self):
        target = write(os.path.join(self.tmp, "victim"), "keep\n")
        os.symlink(target, os.path.join(self.rr, "log", "doctor.log"))
        self.who(0, self.dead_pid())
        self.doctor()
        self.assertEqual(read(target), "keep\n")
        line = self.log().splitlines()[0].split()
        self.assertRegex(line[0], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}$")
        self.assertEqual(line[1:4], ["orphan-slot", "remove", "slot:0"])

    def test_linux_refuses_a_symlinked_rr(self):
        real = os.path.join(self.tmp, "real-rr")
        os.rename(self.rr, real)
        os.symlink(real, self.rr)
        r = subprocess.run(["/bin/bash", DOCTOR], capture_output=True, text=True, timeout=60,
                           env=rdmods.child_env(self.tmp, self.bin, RD_OS="linux", RD_DOCTOR_CONF=self.conf(),
                                                RD_RR_ROOT=self.rr, RD_STATE_DIR=self.st, RD_NO_SERVICES="1"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("symlink; refusing", r.stderr)


# -------------------------------------------------------------------------------------- spotlight (Mac)
class Spotlight(DoctorBase):
    def setUp(self):
        super().setUp()
        self.ps = self.stub("fake-ps", "true")                    # no runner processes
        write(os.path.join(self.rr, "w", "repo-abc", "file"), "x")
        open(os.path.join(self.slots, "0"), "a").close()

    def mac(self, **extra):
        return self.doctor(os_name="darwin", conf={"DOCTOR_RULES": "spotlight"}, RD_PS_CMD=self.ps,
                           RD_DOCTOR_STATUS=os.path.join(self.tmp, "doctor.json"), **extra)

    def test_idle_rr_moves_to_noindex_behind_a_symlink(self):
        self.mac()
        self.assertTrue(os.path.islink(self.rr))
        self.assertEqual(os.readlink(self.rr), "rr.noindex")
        self.assertEqual(read(os.path.join(self.rr, "w", "repo-abc", "file")), "x")
        self.assertIn("spotlight move %s" % self.rr, read(os.path.join(self.rr, "log", "doctor.log")))
        self.mac()                                                # idempotent
        self.assertEqual(os.readlink(self.rr), "rr.noindex")

    def test_held_slot_or_running_runner_blocks_the_move(self):
        self.hold(os.path.join(self.slots, "0"))
        self.mac()
        self.assertFalse(os.path.islink(self.rr))
        self.ps = self.stub("fake-ps2", "echo '4242 1 4242 501 00:10 S rrun-runner owner=x'")
        os.unlink(os.path.join(self.slots, "0"))
        self.mac()
        self.assertFalse(os.path.islink(self.rr))

    def test_dry_run_and_linux_never_move(self):
        self.mac(RD_DOCTOR_DRY="1")
        self.assertFalse(os.path.islink(self.rr))
        self.assertIn("spotlight would-move", self.log())
        self.doctor(conf={"DOCTOR_RULES": "spotlight"}, RD_PS_CMD=self.ps)
        self.assertFalse(os.path.islink(self.rr))


# ---------------------------------------------------------------------------------- install + verify
class Install(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-dri-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.root)

    def test_resilience_installs_and_enables_the_doctor_timer(self):
        r = subprocess.run(["/bin/bash", RESIL, "--root", self.root, "--src", SERVER, "--codename", "noble"],
                           capture_output=True, text=True, timeout=60,
                           env=rdmods.child_env(self.tmp, RD_DMI_PRODUCT="OptiPlex 7040"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(os.path.join(self.root, "usr/local/bin/rd-doctor")), read(DOCTOR))
        self.assertTrue(os.access(os.path.join(self.root, "usr/local/bin/rd-doctor"), os.X_OK))
        self.assertIn("OnUnitActiveSec=30", read(os.path.join(self.root, "etc/systemd/system/rd-doctor.timer")))
        self.assertIn("ExecStart=/usr/local/bin/rd-doctor", read(os.path.join(self.root, "etc/systemd/system/rd-doctor.service")))
        log = read(os.path.join(self.root, "systemctl.log"))
        self.assertIn("systemctl enable rd-doctor.timer", log)
        self.assertIn("systemctl start rd-doctor.timer", log)
        self.assertFalse(os.path.exists(os.path.join(self.root, "etc/rdocker/doctor.conf")))   # owner's file, never written

    def verify(self, conf=None):
        if conf is not None:
            write(os.path.join(self.root, "etc", "rdocker", "doctor.conf"), conf)
        r = subprocess.run(["/bin/bash", VERIFY], capture_output=True, text=True, timeout=60,
                           env=rdmods.child_env(self.tmp, RD_VERIFY_ROOT=self.root))
        return next(ln for ln in r.stdout.splitlines() if ln.split()[1:2] == ["doctor-timer"])

    def test_verify_has_a_doctor_timer_row(self):
        self.assertTrue(self.verify().startswith("FAIL doctor-timer rd-doctor.timer not enabled"))   # no systemd here
        self.assertEqual(self.verify("DOCTOR_DISABLE=1\n"),
                         "FAIL doctor-timer disabled: DOCTOR_DISABLE=1 in /etc/rdocker/doctor.conf")


if __name__ == "__main__":
    unittest.main()
