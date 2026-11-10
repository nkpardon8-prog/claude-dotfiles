"""share/rdocker-share.sh (the Mac owner's off/some/max switch) and its SwiftBar plugin, run against a
temp share file - never /Users/Shared/rdocker/share - and agreeing with the worker's own reading
(rd_pool.PROBE) of the level they write."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402

import rd_pool  # noqa: E402

SHARE = os.path.join(rdmods.STAGE, "share", "rdocker-share.sh")
PLUGIN = os.path.join(rdmods.STAGE, "share", "rdocker-share.1m.sh")


class ShareScript(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="share-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        self.file = os.path.join(self.d, "Shared", "rdocker", "share")
        self.slots = os.path.join(self.d, "slots")
        self.env = rdmods.child_env(self.d, RR_SHARE_FILE=self.file, RR_SLOTS_DIR=self.slots)

    def share(self, *args, cmd=SHARE):
        return subprocess.run(["/bin/sh", cmd] + list(args), capture_output=True, text=True, env=self.env, timeout=30)

    def probe_level(self):
        root = os.path.join(self.d, "rr")
        os.makedirs(root, exist_ok=True)
        env = dict(self.env, RR_ROOT=root, RR_OS="linux", RR_PROC=os.path.join(self.d, "noproc"))
        p = subprocess.run(["/usr/bin/perl", "-e", rd_pool.PROBE], input="{}", env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)["share"]

    def test_levels_are_written_atomically_and_read_back_by_the_worker(self):
        r = self.share("status")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Sharing is MAX", r.stdout)                      # no file = max
        self.assertNotIn("Jobs running", r.stdout)                     # slots unreadable: level only
        for lvl in ("off", "some", "max"):
            r = self.share(lvl)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("Sharing is %s" % lvl.upper(), r.stdout)
            with open(self.file) as f:
                self.assertEqual(f.read(), lvl + "\n")
            self.assertEqual(os.stat(self.file).st_mode & 0o777, 0o644)    # the rd user must read it
            self.assertEqual(self.probe_level(), lvl)
        self.assertEqual(os.stat(os.path.dirname(self.file)).st_mode & 0o777, 0o755)
        self.assertEqual([n for n in os.listdir(os.path.dirname(self.file)) if n != "share"], [])  # no temp left
        self.assertEqual(self.share("bogus").returncode, 2)
        with open(self.file, "w") as f:
            f.write("whatever\n")
        self.assertIn("Sharing is OFF", self.share("status").stdout)  # same rule as the worker
        self.assertEqual(self.probe_level(), "off")

    def test_status_counts_live_jobs_when_the_slots_are_readable(self):
        os.makedirs(self.slots)
        with open(os.path.join(self.slots, "0.who"), "w") as f:
            f.write("app.1234 1700000000 %d 0123456789ab\n" % os.getpid())   # alive
        with open(os.path.join(self.slots, "1.who"), "w") as f:
            f.write("app.1234 1700000000 999999 0123456789ab\n")              # gone
        r = self.share("status")
        self.assertIn("Jobs running now: 1", r.stdout)
        r = self.share("off")
        self.assertIn("1 job(s) still running will finish.", r.stdout)

    def test_menu_bar_plugin_shows_the_level_and_offers_the_three(self):
        bindir = os.path.join(self.d, "plugin")
        os.makedirs(bindir)
        plugin = os.path.join(bindir, "rdocker-share.1m.sh")
        shutil.copy(PLUGIN, plugin)
        r = self.share(cmd=plugin)
        self.assertIn("rdocker-share not installed", r.stdout)         # never guesses
        shutil.copy(SHARE, os.path.join(bindir, "rdocker-share.sh"))
        os.chmod(os.path.join(bindir, "rdocker-share.sh"), 0o755)
        self.share("some")
        out = self.share(cmd=plugin).stdout.splitlines()
        self.assertEqual(out[0], "rd | sfimage=bolt.fill sfcolor=#F5C26B")      # amber bolt = some, no jobs
        self.assertIn("Sharing: SOME (half this Mac) | color=#F5C26B", out)
        toggle = [l for l in out if l.startswith("Turn sharing ")]
        self.assertEqual(len(toggle), 1)                                      # one-click toggle
        self.assertRegex(toggle[0], r'^Turn sharing OFF \| bash="[^"]+rdocker-share\.sh" param1=off terminal=false refresh=true')
        items = [l for l in out if l.startswith(("Off:", "Some:", "Max:"))]
        self.assertEqual(len(items), 3)
        self.assertTrue(items[1].startswith("Some: half the cores | bash=") and items[1].endswith("checked=true"))
        self.assertRegex(items[0], r'param1=off terminal=false refresh=true$')
        self.share("off")
        out = self.share(cmd=plugin).stdout.splitlines()
        self.assertEqual(out[0], "rd off | sfimage=bolt.slash sfcolor=#8a8a8a")
        self.assertTrue(any(l.startswith("Turn sharing ON (Max) |") and "param1=max" in l for l in out))


if __name__ == "__main__":
    unittest.main()
