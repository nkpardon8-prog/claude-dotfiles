"""Runs the reporter's zero-dependency node tests (reporter/tests/*.test.mjs: /proc, vm_stat,
tailscale, runs.log parsers with fixtures; hello signing; config 0600) inside this suite, so the
plan's single validation command covers the reporter too. Skipped when node 22+ is missing."""
import glob
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402

NODE = shutil.which("node")
REPORTER = os.path.join(rdmods.STAGE, "reporter")


def node_major():
    if not NODE:
        return 0
    out = subprocess.run([NODE, "--version"], capture_output=True, text=True, timeout=10).stdout
    return int(out.strip().lstrip("v").split(".")[0] or 0)


@unittest.skipUnless(node_major() >= 22, "node 22+ not installed")
class ReporterNodeTests(unittest.TestCase):
    def test_syntax(self):
        home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, home, True)
        env = rdmods.child_env(home, os.path.dirname(NODE))
        r = subprocess.run([NODE, "--check", os.path.join(REPORTER, "rd-reporter.mjs")],
                           capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_node_suite(self):
        home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, home, True)
        env = rdmods.child_env(home, os.path.dirname(NODE))
        files = sorted(glob.glob(os.path.join(REPORTER, "tests", "*.test.mjs")))
        self.assertTrue(files)
        r = subprocess.run([NODE, "--test", *files], capture_output=True, text=True, env=env,
                           cwd=REPORTER, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
