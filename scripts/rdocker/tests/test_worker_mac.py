"""share/rd-worker-mac.sh (the Mac worker's stay-in-the-pool loop: AC-only keep-awake while sharing, sshd
re-kick when Tailscale returns), its LaunchDaemon plist and install-worker-mac.sh. The loop runs for real
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

    def run_worker(self, ticks):
        env = rdmods.child_env(self.d, self.bin, RR_SHARE_FILE=self.share_file, RD_SHARE_CMD=SHARE_CMD,
                               RD_SSHD_CONF=self.conf, RD_SSHD_PLIST=self.plist, RD_IFCONFIG=self.ifconfig,
                               RD_LSOF=self.lsof, RD_LAUNCHCTL=self.lctl, RD_CAFFEINATE=self.caff,
                               RD_TICK_S="0.1", RD_TICKS=str(ticks))
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
        for level in ("max", "some"):
            os.path.exists(self.calls) and os.unlink(self.calls)
            self.set_share(level)
            out = self.run_worker(3)
            self.assertIn("share level %s" % level, out)
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


if __name__ == "__main__":
    unittest.main()
