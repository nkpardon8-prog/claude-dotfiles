"""server_os=linux branches: janitor_disk commands, systemd engine kick/restart (fake systemctl/sudo/docker
run through /bin/sh). The mac defaults are covered by the existing suites."""
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import rdmods
from rdmods import MODULES

rd_common, rd_janitor, rd_setup = (
    next(m for m in MODULES if m.__name__ == n) for n in ("rd_common", "rd_janitor", "rd_setup"))

SYSTEMCTL = """#!/bin/sh
echo "systemctl $*" >> "$HOME/engine.log"
case "$1" in
  is-active) [ -f "$HOME/docker.active" ]; exit $? ;;
  start|restart) [ -f "$HOME/stays.down" ] || touch "$HOME/docker.active" ;;
esac
exit 0
"""
SUDO = """#!/bin/sh
[ "$1" = -n ] || { echo "sudo without -n: $*" >> "$HOME/engine.log"; exit 1; }
shift
exec "$@"
"""
DOCKER = """#!/bin/sh
[ "$1" = info ] && { [ -f "$HOME/docker.active" ]; exit $?; }
exit 0
"""


class LinuxServer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-srvlinux-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home, self.bin, self.state = (os.path.join(self.tmp, d) for d in ("h", "bin", "state"))
        for d in (self.home, self.bin, self.state):
            os.makedirs(d)
        for name, body in (("systemctl", SYSTEMCTL), ("sudo", SUDO), ("docker", DOCKER)):
            with open(os.path.join(self.bin, name), "w") as f:
                f.write(body)
            os.chmod(os.path.join(self.bin, name), 0o755)
        self.scripts, self.logs = [], []
        for mod, name, val in (
                (rd_janitor, "LINUX_PATH", self.bin), (rd_janitor, "low_disk_housekeeping", lambda cfg: None), (rd_janitor, "mini_sh", self.mini_sh),
                (rd_common, "JANITOR_PATH", os.path.join(self.state, "janitor.json")),
                (rd_common, "ATTENTION_PATH", os.path.join(self.state, "attention.json")),
                (rd_common, "ATTENTION_SHOWN_PATH", os.path.join(self.state, "shown.json")),
                (rd_common, "log", lambda msg, **k: self.logs.append(msg))):
            p = mock.patch.object(mod, name, val)
            p.start()
            self.addCleanup(p.stop)
        self.cfg = rd_common.merge_cfg({"server_os": "linux"})

    def mini_sh(self, cfg, script, timeout=60):
        self.scripts.append(script)
        env = {"HOME": self.home, "PATH": rdmods.safe_path(self.bin)}   # mini side: no RDOCKER_*
        p = subprocess.run(["/bin/sh", "-s"], input=script, capture_output=True, text=True,
                           env=env, timeout=timeout)
        return p.returncode, p.stdout, p.stderr

    def engine_log(self):
        try:
            with open(os.path.join(self.home, "engine.log")) as f:
                return f.read().splitlines()
        except OSError:
            return []

    def test_default_is_linux_mac_still_selectable(self):
        self.assertEqual(rd_common.merge_cfg({})["server_os"], "linux")   # WSL2 server since 2026-11-01
        cfg = rd_common.merge_cfg({"server_os": "mac"})
        self.assertFalse(rd_common.server_linux(cfg))
        self.assertEqual(rd_common.server_docker_bin(cfg), "/opt/homebrew/bin/docker")
        self.assertEqual(rd_common.server_docker_bin(self.cfg), "/usr/bin/docker")

    def test_disk_script_has_no_colima_and_uses_sudo_n(self):
        rd_janitor.janitor_disk(self.cfg, housekeeping=True)
        s = self.scripts[0]
        for bad in ("colima", "brew", "timesyncd", "stat -f"):
            self.assertNotIn(bad, s)
        self.assertIn("df -P /var/lib/docker", s)
        self.assertIn("sudo -n journalctl --vacuum-size=50M", s)
        self.assertIn("sudo -n fstrim -a", s)
        self.assertIn("HOSTFREE", s)

    def test_disk_without_housekeeping_or_vm(self):
        rd_janitor.janitor_disk(self.cfg, housekeeping=False)
        self.assertNotIn("sudo", self.scripts[-1])
        rd_janitor.janitor_disk(self.cfg, housekeeping=True, vm=False)
        self.assertNotIn("VMDISK", self.scripts[-1])
        self.assertNotIn("sudo", self.scripts[-1])

    def test_disk_parses_markers(self):
        with mock.patch.object(rd_janitor, "mini_sh", lambda *a, **k: (0, "VMDISK 42%\nHOSTFREE 77\n", "")):
            self.assertEqual(rd_janitor.janitor_disk(self.cfg, housekeeping=False), (42, 77))

    def test_kick_starts_via_systemctl_never_colima(self):
        rd_janitor.mini_engine_kick(self.cfg)
        self.assertEqual(self.engine_log()[:2], ["systemctl is-active docker", "systemctl start docker"])
        self.assertTrue(any("started via systemd" in m for m in self.logs), self.logs)
        for s in self.scripts:
            for bad in ("colima", "launchctl", "brew"):
                self.assertNotIn(bad, s)
        self.assertFalse(any("no colima profile" in m for m in self.logs))
        self.assertNotIn("engine", rd_common.load_json(rd_common.ATTENTION_PATH, {}) or {})

    def test_kick_start_failure_sets_attention_not_noprofile(self):
        open(os.path.join(self.home, "stays.down"), "w").close()
        with mock.patch.object(rd_janitor, "ENGINE_WAIT_S", 2):
            res = rd_janitor.mini_engine_kick(self.cfg)
        self.assertEqual(res, "start-failed")
        self.assertTrue(any("start FAILED" in m for m in self.logs))

    def test_restart_script_linux_uses_sudo_n_restart(self):
        s = rd_janitor.restart_script(False, linux=True)
        self.assertIn("sudo -n systemctl restart docker", s)
        for bad in ("colima", "launchctl"):
            self.assertNotIn(bad, s)
        rc, out, _ = self.mini_sh(self.cfg, s)
        self.assertIn("RDRESTART ok systemd", out)
        self.assertIn("systemctl restart docker", self.engine_log())

    def test_mac_scripts_unchanged(self):
        self.assertIn("colima", rd_janitor.kick_script())
        self.assertIn("launchctl", rd_janitor.restart_script(False))


if __name__ == "__main__":
    unittest.main()
