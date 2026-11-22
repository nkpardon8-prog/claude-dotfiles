"""share/rd-worker-mac.sh (the Mac worker's stay-in-the-pool loop: AC-only keep-awake while sharing, sshd
re-kick when Tailscale returns, the menu's jobs count, the owner's "Off now"), its LaunchDaemon plist,
install-worker-mac.sh and setup-mac-worker.sh. The loop runs for real
against a temp share file and fake ifconfig / lsof / launchctl / caffeinate; nothing touches this machine's
real services, its share file or its sleep settings."""
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
from rdmods import STAGE  # noqa: E402

SHARE_DIR = os.path.join(STAGE, "share")
WORKER = os.path.join(SHARE_DIR, "rd-worker-mac.sh")
SHARE_CMD = os.path.join(SHARE_DIR, "rdocker-share.sh")
PLIST = os.path.join(SHARE_DIR, "com.rdocker.worker.plist")
INSTALL = os.path.join(SHARE_DIR, "install-worker-mac.sh")
SETUP = os.path.join(SHARE_DIR, "setup-mac-worker.sh")
TS_IP = "100.125.118.77"


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


class WorkerLoop(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="rdk-wm-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.d, True)
        self.bin = os.path.join(self.d, "bin")
        self.share_file = os.path.join(self.d, "Shared", "rdocker", "share")
        self.calls = os.path.join(self.d, "calls")
        self.conf = write(os.path.join(self.d, "sshd_config"),
                          "Port 2222\nListenAddress %s\nAllowUsers rd\n" % TS_IP)
        self.plist = write(os.path.join(self.d, "com.rdocker.sshd.plist"), "<plist/>\n")
        # fakes: each appends "<name> <args>" to calls; behaviour comes from files the test writes
        self.ifconfig = self.stub("ifconfig", 'cat "%s/ifconfig.out" 2>/dev/null' % self.d)
        self.lsof = self.stub("lsof", 'test -f "%s/listening"' % self.d)
        self.lctl = self.stub("launchctl", '[ "$1" = print ] && { test -f "%s/loaded"; exit; }; exit 0' % self.d)
        # caffeinate holds until killed (like the real one with -w): a perl whose process name (ps comm) is
        # "caffeinate", so the loop's "still my caffeinate" check (ppid + command name) sees what it sees on a Mac
        self.caff = self.stub("caffeinate", "exec /usr/bin/perl -e '$0 = \"caffeinate\"; sleep 30'")
        self.pkill = self.stub("pkill", "exit 0")
        self.slots = os.path.join(self.d, "rd-rr", "slots")
        self.status_file = os.path.join(self.d, "Shared", "rdocker", "status")
        self.req = os.path.join(self.d, "Shared", "rdocker", "stop-jobs")
        self.set_share(None)

    def stub(self, name, body):
        return write(os.path.join(self.bin, name),
                     '#!/bin/sh\necho "%s $*" >> "%s"\n%s\n' % (name, self.calls, body), 0o755)

    def set_share(self, level):
        if level is None:
            if os.path.exists(self.share_file):
                os.unlink(self.share_file)
        else:
            write(self.share_file, level + "\n")

    def tailscale_up(self, up=True):
        p = os.path.join(self.d, "ifconfig.out")
        write(p, "utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280\n"
                 "\tinet %s --> %s netmask 0xffffffff\n" % (TS_IP, TS_IP) if up else
                 "en0: flags=8863<UP> mtu 1500\n\tinet 192.168.1.20 netmask 0xffffff00\n")

    def run_worker(self, ticks, **extra):
        env = rdmods.child_env(self.d, self.bin, **{**dict(
            RR_SHARE_FILE=self.share_file, RD_SHARE_CMD=SHARE_CMD, RD_SSHD_CONF=self.conf, RD_SSHD_PLIST=self.plist,
            RD_IFCONFIG=self.ifconfig, RD_LSOF=self.lsof, RD_LAUNCHCTL=self.lctl, RD_CAFFEINATE=self.caff,
            RD_TICK_S="0.1", RD_TICKS=str(ticks), RD_SLOTS_DIR=self.slots, RD_STATUS_FILE=self.status_file,
            RD_STOP_REQ=self.req, RD_PKILL=self.pkill), **extra})
        r = subprocess.run(["/bin/sh", WORKER], capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def calls_of(self, name):
        if not os.path.exists(self.calls):
            return []
        return [ln.split(" ", 1)[1] if " " in ln else "" for ln in read(self.calls).splitlines()
                if ln.split(" ", 1)[0] == name]

    def caffeinate_alive(self):
        return subprocess.run(["/usr/bin/pgrep", "-f", "^caffeinate$"], capture_output=True).returncode == 0

    # ---- awake
    def test_sharing_on_holds_an_ac_only_assertion_tied_to_the_loop(self):
        for level, word in (("max", "high"), ("some", "medium"), ("low", "low"), ("cpu=75 ram=4", "custom")):
            os.path.exists(self.calls) and os.unlink(self.calls)
            self.set_share(level)
            out = self.run_worker(3)
            self.assertIn("share level %s" % word, out)
            self.assertEqual(out.count("awake hold"), 1, out)          # held once, not re-spawned every tick
            args = self.calls_of("caffeinate")
            self.assertEqual(len(args), 1)
            self.assertTrue(args[0].startswith("-s -w "), args)       # -s: valid only on AC power
            for _ in range(50):                                        # released when the loop ends
                if not self.caffeinate_alive():
                    break
                time.sleep(0.1)
            self.assertFalse(self.caffeinate_alive())

    def test_sharing_off_or_unknown_never_keeps_the_mac_awake(self):
        self.set_share("off")
        out = self.run_worker(2)
        self.assertIn("share level off", out)
        self.assertEqual(self.calls_of("caffeinate"), [])
        env = rdmods.child_env(self.d, self.bin, RD_SHARE_CMD=os.path.join(self.d, "no-such-cmd"),
                               RD_SSHD_CONF=self.conf, RD_IFCONFIG=self.ifconfig, RD_LSOF=self.lsof,
                               RD_LAUNCHCTL=self.lctl, RD_CAFFEINATE=self.caff, RD_TICK_S="0.1", RD_TICKS="2")
        r = subprocess.run(["/bin/sh", WORKER], capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("share level unknown", r.stdout)                 # switch missing: no keep-awake
        self.assertEqual(self.calls_of("caffeinate"), [])

    def test_never_signals_a_pid_that_is_not_its_caffeinate(self):
        # the assertion process turns out to be something else (here: plain sleep, as after a pid reuse):
        # the loop must not kill it, only forget it
        marker = os.path.join(self.d, "stranger")
        self.caff = self.stub("caffeinate", 'exec /bin/sleep 31 </dev/null >/dev/null 2>&1 # %s' % marker)
        self.set_share("max")
        self.run_worker(1)
        p = subprocess.run(["/usr/bin/pgrep", "-f", "^/bin/sleep 31"], capture_output=True, text=True)
        pids = [int(x) for x in p.stdout.split()]
        for pid in pids:
            self.addCleanup(lambda pid=pid: subprocess.run(["/bin/kill", "-9", str(pid)], capture_output=True))
        self.assertTrue(pids, "the stranger process was killed")

    def test_no_share_file_is_max_like_the_worker(self):
        out = self.run_worker(1)                                       # no file = max (rdocker-share's rule)
        self.assertIn("share level max", out)
        self.assertEqual(len(self.calls_of("caffeinate")), 1)

    def test_the_loop_never_writes_the_share_level(self):
        self.set_share("some")
        before = (read(self.share_file), os.stat(self.share_file).st_mtime_ns)
        self.tailscale_up()
        self.run_worker(4)
        self.assertEqual((read(self.share_file), os.stat(self.share_file).st_mtime_ns), before)
        self.assertNotIn("share", " ".join(self.calls_of("launchctl")))
        # the script has no write path to the share file at all
        self.assertNotIn("Shared/rdocker/share", read(WORKER))
        self.assertNotRegex(read(WORKER), r'SHARE"?\s+(off|some|max)\b')

    # ---- the menu's jobs count, the owner's stop
    def test_status_file_counts_rd_jobs_for_the_owners_menu(self):
        write(os.path.join(self.slots, "0.who"), "app 1700000000 %d 0123456789ab\n" % os.getpid())   # alive
        write(os.path.join(self.slots, "1.who"), "app 1700000000 999999 0123456789ab\n")            # gone
        write(os.path.join(self.d, "elsewhere"), "app 1700000000 %d x\n" % os.getpid())
        os.symlink(os.path.join(self.d, "elsewhere"), os.path.join(self.slots, "2.who"))       # never followed
        self.set_share("medium")
        out = self.run_worker(2)
        text = read(self.status_file)
        self.assertRegex(text, r"^jobs=1\nts=\d+\n$")
        self.assertLess(abs(int(text.split("ts=")[1]) - time.time()), 30)
        self.assertEqual(os.stat(self.status_file).st_mode & 0o777, 0o644)
        self.assertEqual(out.count("jobs running here: 1"), 1)                  # logged once, on change
        self.assertEqual([n for n in os.listdir(os.path.dirname(self.status_file)) if n.startswith(".status")], [])
        # the owner's switch reads it (it cannot read rd's slots)
        env = rdmods.child_env(self.d, RR_SHARE_FILE=self.share_file, RR_SLOTS_DIR=os.path.join(self.d, "none"))
        r = subprocess.run(["/bin/sh", SHARE_CMD, "status"], capture_output=True, text=True, env=env, timeout=30)
        self.assertIn("Jobs running now: 1", r.stdout)

    def test_owner_stop_signals_only_rds_runners_now_and_once_more(self):
        self.set_share("off")
        write(self.req, "")
        out = self.run_worker(3)
        self.assertFalse(os.path.exists(self.req))                               # done: the request is gone
        self.assertEqual(self.calls_of("pkill"), ["-USR1 -U rd -f ^rrun-runner"] * 2)   # rd's only, never the owner's
        self.assertIn("stop: the owner stopped the jobs here", out)
        os.unlink(self.calls)
        self.run_worker(2)
        self.assertEqual(self.calls_of("pkill"), [])                             # no request: nothing
        os.symlink(os.path.join(self.d, "elsewhere-req"), self.req)
        self.run_worker(1)
        self.assertEqual(self.calls_of("pkill"), [])                             # a planted link: ignored, removed
        self.assertFalse(os.path.lexists(self.req))
        self.assertNotIn("kill -", read(WORKER).replace("kill -0", ""))          # signals only through pkill -U

    # ---- sshd
    def test_tailscale_up_but_nothing_listening_kickstarts_sshd_after_two_ticks(self):
        self.set_share("off")
        self.tailscale_up()
        open(os.path.join(self.d, "loaded"), "w").close()
        out = self.run_worker(1)
        self.assertNotIn("kickstart", " ".join(self.calls_of("launchctl")))     # one miss: wait
        out = self.run_worker(2)
        self.assertIn("kickstart -k system/com.rdocker.sshd", self.calls_of("launchctl"))
        self.assertIn("sshd kickstart (nothing listening on %s:2222)" % TS_IP, out)
        self.assertIn("-nP -iTCP@%s:2222 -sTCP:LISTEN -t" % TS_IP, self.calls_of("lsof"))

    def test_kickstart_backs_off_after_a_try(self):
        self.set_share("off")
        self.tailscale_up()
        open(os.path.join(self.d, "loaded"), "w").close()
        self.run_worker(5)                                             # miss, kick, -1, 0, 1: one kick only
        self.assertEqual(self.calls_of("launchctl").count("kickstart -k system/com.rdocker.sshd"), 1)

    def test_a_listening_sshd_or_tailscale_down_is_left_alone(self):
        self.set_share("off")
        self.tailscale_up()
        open(os.path.join(self.d, "listening"), "w").close()
        self.run_worker(3)
        self.assertEqual(self.calls_of("launchctl"), [])
        os.unlink(os.path.join(self.d, "listening"))
        os.unlink(self.calls)
        self.tailscale_up(False)                                       # asleep network / Tailscale off
        self.run_worker(3)
        self.assertEqual(self.calls_of("launchctl"), [])
        self.assertEqual(self.calls_of("lsof"), [])

    def test_an_unloaded_sshd_job_is_bootstrapped_from_its_plist(self):
        self.set_share("off")
        self.tailscale_up()
        out = self.run_worker(2)
        self.assertIn("bootstrap system %s" % self.plist, self.calls_of("launchctl"))
        self.assertIn("was not loaded", out)

    def test_no_listen_address_means_no_sshd_rule(self):
        write(self.conf, "Port 2222\n")
        self.set_share("off")
        self.tailscale_up()
        self.run_worker(3)
        self.assertEqual(self.calls_of("launchctl"), [])


    # ---- prune
    def test_prunes_rr_as_rd_at_start_then_every_interval_in_the_background(self):
        tune = write(os.path.join(self.d, "rd-tune"), "echo should-not-run-directly\n")
        sudo = self.stub("sudo", 'shift 4; echo "pruned $*"; sleep 1')   # drops "-n -u rd -H"; slow on purpose
        t0 = time.time()
        out = self.run_worker(3, RD_TUNE=tune, RD_SUDO=sudo)
        self.assertLess(time.time() - t0, 5)                               # never waited for: background
        time.sleep(1.5)
        self.assertEqual(self.calls_of("sudo"), ["-n -u rd -H /bin/bash %s prune" % tune])   # once in 3 ticks
        os.unlink(self.calls)
        self.run_worker(3, RD_TUNE=tune, RD_SUDO=sudo, RD_PRUNE_EVERY_S="0")
        time.sleep(1.5)
        self.assertEqual(len(self.calls_of("sudo")), 3)
        self.assertNotIn("should-not-run-directly", out)

    def test_prune_output_is_logged_and_a_missing_rd_tune_is_skipped(self):
        tune = write(os.path.join(self.d, "rd-tune"), "")
        sudo = self.stub("sudo", 'echo "rd-tune: prune rm mirror x (disk low)"')
        out = self.run_worker(2, RD_TUNE=tune, RD_SUDO=sudo, RD_TICK_S="0.5")
        self.assertRegex(out, r"\d{4}-\d\d-\d\dT[^ ]+ rd-tune: prune rm mirror x")
        os.unlink(self.calls)
        self.run_worker(2, RD_TUNE=os.path.join(self.d, "none"), RD_SUDO=sudo)
        self.assertEqual(self.calls_of("sudo"), [])


class Units(unittest.TestCase):
    def test_plist_is_a_boot_daemon_that_launchd_keeps_alive(self):
        with open(PLIST, "rb") as f:
            p = plistlib.load(f)
        self.assertEqual(p["Label"], "com.rdocker.worker")
        self.assertIs(p["RunAtLoad"], True)
        self.assertIs(p["KeepAlive"], True)
        self.assertNotIn("UserName", p)                                # root: launchctl kickstart system/...
        self.assertEqual(p["ProgramArguments"], ["/bin/sh", "/usr/local/libexec/rd-worker-mac"])
        self.assertIn("/usr/local/libexec/rd-worker-mac", read(INSTALL))   # where the installer puts it

    def test_installer_parses_refuses_non_root_and_never_writes_the_share(self):
        for f in (INSTALL, WORKER):
            r = subprocess.run(["/bin/sh", "-n", f], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
        if os.getuid() != 0:
            r = subprocess.run(["/bin/sh", INSTALL], capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 1)
            self.assertIn("run with sudo", r.stdout)
        text = read(INSTALL)
        self.assertNotRegex(text, r"rdocker-share (off|some|max)\b")
        self.assertNotIn("/Users/Shared/rdocker/share", text)
        # the share folder is made for the owner (0755, no group/world write) BEFORE install-power-mac.sh,
        # which would create it root-owned
        mk = text.index('install -d -o "$OWNER" -g staff -m 755 "$SD"')
        self.assertLess(mk, text.index('sh "$SRC/install-power-mac.sh"'))
        self.assertIn('chmod go-w "$SD"', text)
        for dep in ("install-doctor-mac.sh", "install-power-mac.sh", "com.rdocker.worker.plist"):
            self.assertTrue(os.path.exists(os.path.join(SHARE_DIR, dep)), dep)


class Setup(unittest.TestCase):
    """setup-mac-worker.sh: the one Mac worker installer. It needs root, so the suite checks its parsing, its
    refusals and the guarantees its text must keep (it is run for real by the owner, once per Mac)."""

    def run_setup(self, *args, **env):
        e = rdmods.child_env(tempfile.mkdtemp(prefix="rdk-setup-", dir=rdmods.TEST_HOME), **env)
        return subprocess.run(["/bin/sh", SETUP] + list(args), capture_output=True, text=True, env=e, timeout=30)

    def test_parses_its_arguments_and_the_bundles_fleet(self):
        r = self.run_setup("--docker", "--port", "2222", RD_SETUP_PARSE_ONLY="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout, r"^user=rd owner=\S* port=2222 ip= docker=1 swiftbar=1 node_major=25 keys=2\n$")
        self.assertEqual(self.run_setup("--bogus", RD_SETUP_PARSE_ONLY="1").returncode, 1)
        self.assertEqual(self.run_setup("--user", "Bad User", RD_SETUP_PARSE_ONLY="1").returncode, 1)
        if os.getuid() != 0:
            r = self.run_setup()
            self.assertEqual(r.returncode, 1)
            self.assertIn("run with sudo", r.stdout)
        r = subprocess.run(["/bin/sh", "-n", SETUP], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def share_step(self, sd, owner, seed_ok=True):
        """Run setup-mac-worker.sh's real share-first step (between its 1. and 2. markers) against a temp
        folder: as_owner is the plain command (or a failure), say prints."""
        t = read(SETUP)
        step = t[t.index("# ---------------------------------------------------------------------------------- 1. the share switch"):
                 t.index("# ---------------------------------------------------------------------------------- 2. the rd user")]
        self.assertEqual(step.count("SD=/Users/Shared/rdocker"), 1)
        step = step.replace("SD=/Users/Shared/rdocker", "SD=%s" % sd)
        prog = 'set -eu\nSRC=%s OWNER=%s\nsay() { echo "setup: $*"; }\nas_owner() { %s; }\n%s\necho STEP-DONE\n' % (
            SHARE_DIR, owner, 'RR_SHARE_FILE="$SD/share" "$@"' if seed_ok else "return 1", step)
        return subprocess.run(["/bin/sh", "-c", prog], capture_output=True, text=True, timeout=30,
                              env=rdmods.child_env(tempfile.mkdtemp(prefix="rdk-step-", dir=rdmods.TEST_HOME)))

    def test_an_interrupted_install_never_leaves_sshd_up_without_share_off(self):
        """No share file means everything on a Mac: the switch is seeded OFF (and checked) before any account,
        key or sshd exists, and a failed seed stops the install; an existing setting is kept."""
        t = read(SETUP)
        t = t[t.index("\nset -eu\n"):]                                    # the code, not the header
        seeded = t.index('say "share switch: $lvl"')
        for later in ("/usr/sbin/sysadminctl -addUser", "authorized_keys", "DenyUsers", 'cat > "$CONF.tmp"',
                      '/bin/launchctl bootstrap system "$PL"', 'sh "$SRC/install-worker-mac.sh"'):
            self.assertLess(seeded, t.index(later), later)
        me = subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()
        base = tempfile.mkdtemp(prefix="rdk-sd-", dir=rdmods.TEST_HOME)
        sd = os.path.join(base, "rdocker")
        r = self.share_step(sd, me)                                        # fresh Mac: created and OFF
        self.assertIn("STEP-DONE", r.stdout, r.stdout + r.stderr)
        self.assertEqual(read(os.path.join(sd, "share")), "off\n")
        self.assertEqual(os.stat(sd).st_mode & 0o777, 0o755)
        write(os.path.join(sd, "share"), "cpu=75 ram=4\n")                # re-run: the owner's setting stays
        r = self.share_step(sd, me)
        self.assertIn("share switch: custom", r.stdout)
        self.assertEqual(read(os.path.join(sd, "share")), "cpu=75 ram=4\n")
        os.unlink(os.path.join(sd, "share"))                              # the seed fails: stop, before any sshd
        r = self.share_step(sd, me, seed_ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("STEP-DONE", r.stdout)
        self.assertIn("stopping before any sshd", r.stdout)
        r = self.share_step(sd, "someone-else")                            # a folder of a third user: refused
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refusing (it holds the share switch)", r.stdout)
        os.chmod(sd, 0o777)
        self.share_step(sd, me)
        self.assertEqual(os.stat(sd).st_mode & 0o777, 0o755)              # group/world write taken away
        it = read(INSTALL)                                                 # the daemons step checks the same
        self.assertIn('so=$(stat -f %Su "$SD")', it)
        self.assertIn("refusing (it holds the share switch)", it)

    def test_remote_login_never_lets_rd_in_and_nothing_is_forwarded(self):
        t = read(SETUP)
        self.assertIn("grep -q '^Include /etc/ssh/sshd_config.d/\\*' \"$MAIN\" || {", t)     # else refuse
        self.assertIn("DROP=/etc/ssh/sshd_config.d/100-rdocker-deny-$RD_USER.conf", t)
        self.assertIn("DenyUsers %s", t)
        self.assertIn("/usr/sbin/sshd -t -h \"$D/ssh_host_ed25519_key\" || { rm -f \"$DROP\"", t)
        for line in ("AllowTcpForwarding no", "AllowStreamLocalForwarding no", "X11Forwarding no",
                     "PermitTunnel no", "AllowAgentForwarding no"):
            self.assertIn(line + "\n", t)

    def test_the_root_daemon_runs_its_own_root_owned_switch(self):
        w, it = read(WORKER), read(INSTALL)
        self.assertIn("SHARE=${RD_SHARE_CMD:-/usr/local/libexec/rdocker-share}", w)
        self.assertNotIn("/usr/local/bin/rdocker-share", w)
        self.assertIn('install -o root -g wheel -m 755 "$SRC/rdocker-share.sh" /usr/local/libexec/rdocker-share', it)
        self.assertIn("chown root:wheel /usr/local/libexec && chmod 755 /usr/local/libexec", it)
        # its ~/rr prune: the Linux workers' rd-tune.sh, root-owned, run as rd (never as root)
        self.assertIn("TUNE=${RD_TUNE:-/usr/local/libexec/rd-tune}", w)
        self.assertIn('install -o root -g wheel -m 755 "$TUNE" /usr/local/libexec/rd-tune', it)
        self.assertIn('TUNE="$SRC/../server/rd-tune.sh"', it)
        self.assertTrue(os.path.exists(os.path.join(SHARE_DIR, "..", "server", "rd-tune.sh")))
        self.assertIn('"$SUDO" -n -u "$RDU" -H /bin/bash "$TUNE" prune', w)

    def test_sshd_is_tailscale_only_and_reloaded_only_on_change(self):
        t = read(SETUP)
        code = "\n".join(ln for ln in t.splitlines() if not ln.lstrip().startswith("#"))
        self.assertFalse("0.0.0.0" in code or "ListenAddress *" in code, "sshd must never bind every address")
        self.assertIn("ListenAddress $IP\n", t)
        self.assertEqual(t.count("ListenAddress"), 1)
        # the address is checked (CGNAT 100.64.0.0/10, up on an interface) before the config is written
        check = t.index('[ "$o2" -ge 64 ] && [ "$o2" -le 127 ]')
        self.assertLess(t.index('grep -q "inet $IP "'), t.index("ListenAddress $IP"))
        self.assertLess(check, t.index("ListenAddress $IP"))
        self.assertIn('/usr/sbin/sshd -t -f "$CONF.tmp"', t)                     # validated before it replaces
        self.assertIn('if [ "$before" != "$(sum "$CONF") $(sum "$PL")" ]', t)    # reload only on change
        for line in ("PasswordAuthentication no", "PermitRootLogin no", "AuthenticationMethods publickey",
                     "AllowUsers $RD_USER", "UsePAM no"):
            self.assertIn(line + "\n", t)
        for tool in ("systemsetup", "pmset", "socketfilterfw"):                  # Remote Login, sleep, firewall
            self.assertFalse(tool in code, tool)

    def test_root_never_writes_inside_rds_home_and_the_share_is_only_seeded(self):
        t = read(SETUP)
        self.assertIn('sudo -u "$RD_USER" -H /bin/sh -c', t)                    # keys written as rd
        self.assertNotRegex(t, r'chown[^\n]*\$H/')
        self.assertNotRegex(t, r'> "\$H/')
        self.assertIn('if [ ! -e "$SD/share" ] && [ ! -L "$SD/share" ]; then', t)   # never over a setting
        self.assertNotRegex(t, r"rdocker-share\.sh\" (low|medium|high|some|max)\b")
        self.assertIn('rdocker-share.sh" off', t)                                # opt-in: seeded off
        self.assertIn("dseditgroup -o checkmember -m \"$RD_USER\" admin", t)   # never an admin account
        self.assertIn('sh "$SRC/install-worker-mac.sh" --user "$RD_USER"', t)
        for dep in ("install-worker-mac.sh", "rdocker-share.sh", "rdocker-share.1m.sh"):
            self.assertTrue(os.path.exists(os.path.join(SHARE_DIR, dep)), dep)


if __name__ == "__main__":
    unittest.main()
