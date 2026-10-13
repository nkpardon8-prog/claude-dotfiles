"""Entry-point tests: rdocker.py's import fallback and docker-shim's symlink resolution.

The fallback runs rdocker.py copied ALONE into a temp dir, so none of the rd_* modules import.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TESTS)
import rdmods  # noqa: E402  (hermetic RDOCKER_HOME + fail-closed stubs)
STAGE = os.path.abspath(os.path.join(TESTS, ".."))
FAKE = os.path.join(TESTS, "fake_docker.py")


class ImportFallback(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="rdk-entry-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.lone = os.path.join(self.home, "lone")
        os.makedirs(self.lone)
        shutil.copy(os.path.join(STAGE, "rdocker.py"), self.lone)
        self.bin = os.path.join(self.home, "bin")
        os.makedirs(self.bin)
        os.symlink(FAKE, os.path.join(self.bin, "docker"))
        self.log = os.path.join(self.home, "docker.log")
        self.fixture = os.path.join(self.home, "fixture.json")
        with open(self.fixture, "w") as f:
            json.dump({"default": {"containers": {}}}, f)

    def run_entry(self, *argv, env=None):
        e = rdmods.child_env(self.home, self.bin, FAKE_DOCKER_FIXTURE=self.fixture,
                             FAKE_DOCKER_LOG=self.log, **(env or {}))
        return subprocess.run(["/usr/bin/python3", "-I", os.path.join(self.lone, "rdocker.py")] + list(argv),
                              capture_output=True, text=True, env=e, timeout=60)

    def docker_calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(line) for line in f if line.strip()]

    def test_read_only_command_execs_real_docker(self):
        p = self.run_entry("shim", "ps")
        self.assertIn("modules failed to import", p.stderr)
        self.assertEqual(self.docker_calls(), [["ps"]])

    def test_container_creating_and_targeted_commands_are_refused(self):
        for argv in (["run", "-d", "redis"], ["-l", "debug", "stop", "db"], ["compose", "up", "-d"],
                     ["container", "rm", "x"], ["exec", "db", "sh"]):
            p = self.run_entry("shim", *argv)
            self.assertEqual(p.returncode, 1, argv)
            sub = [a for a in argv if not a.startswith("-") and a != "debug"][0]
            self.assertIn("refusing %s (run `rdocker doctor`)" % sub, p.stderr)
        self.assertEqual(self.docker_calls(), [])

    def test_bypass_and_explicit_context_stay_unrouted(self):
        self.run_entry("shim", "run", "-d", "redis", env={"RDOCKER_BYPASS": "1"})
        self.run_entry("shim", "--context", "x", "rm", "db")
        self.assertEqual(self.docker_calls(), [["run", "-d", "redis"], ["--context", "x", "rm", "db"]])

    def test_cli_commands_fail(self):
        p = self.run_entry("status")
        self.assertEqual(p.returncode, 1)
        self.assertIn("modules failed to import", p.stderr)


class EntryImports(unittest.TestCase):
    def test_usage_through_full_entry(self):
        home = tempfile.mkdtemp(prefix="rdk-entry-")
        self.addCleanup(shutil.rmtree, home, True)
        p = subprocess.run(["/usr/bin/python3", "-I", os.path.join(STAGE, "rdocker.py"), "--help"],
                           capture_output=True, text=True, env=rdmods.child_env(home), timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)       # argparse --help
        self.assertTrue(p.stdout.startswith("usage: rdocker"))
        p = subprocess.run(["/usr/bin/python3", "-I", os.path.join(STAGE, "rdocker.py"), "bogus"],
                           capture_output=True, text=True, env=rdmods.child_env(home), timeout=60)
        self.assertEqual(p.returncode, 2)
        self.assertTrue(p.stderr.startswith("usage: rdocker"), p.stderr)


class ShimResolvesItsDirectory(unittest.TestCase):
    def test_follows_relative_symlink_chain(self):
        root = tempfile.mkdtemp(prefix="rdk-shim-")
        self.addCleanup(shutil.rmtree, root, True)
        real = os.path.join(root, "real")
        os.makedirs(real)
        shutil.copy(os.path.join(STAGE, "docker-shim"), real)
        with open(os.path.join(real, "rdocker.py"), "w") as f:
            f.write("import os, sys\nprint(os.path.realpath(__file__)); print(sys.argv[1:])\n")
        for d in ("a", "bin"):
            os.makedirs(os.path.join(root, d))
        os.symlink("../real/docker-shim", os.path.join(root, "a", "link1"))
        os.symlink(os.path.join(root, "a", "link1"), os.path.join(root, "bin", "docker"))
        p = subprocess.run([os.path.join(root, "bin", "docker"), "ps", "-a"],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        out = p.stdout.splitlines()
        self.assertEqual(out[0], os.path.realpath(os.path.join(real, "rdocker.py")))
        self.assertEqual(out[1], "['shim', 'ps', '-a']")


if __name__ == "__main__":
    unittest.main()
