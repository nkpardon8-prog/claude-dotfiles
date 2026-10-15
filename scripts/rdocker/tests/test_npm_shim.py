"""npm shim (~/.local/bin/npm): heavy `npm run` scripts go through rrun, everything else is the real npm."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402

SHIM = os.path.join(rdmods.STAGE, "npm-shim")


class NpmShim(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="rd-npmshim-")
        self.home = os.path.join(self.d, "home")
        self.shim_dir = os.path.join(self.d, "shim")           # plays ~/.local/bin
        self.real_dir = os.path.join(self.d, "real")           # plays /opt/homebrew/bin
        for x in (self.home, self.shim_dir, self.real_dir):
            os.makedirs(x)
        os.symlink(SHIM, os.path.join(self.shim_dir, "npm"))
        self.write(self.real_dir, "npm", 'echo "REAL npm $*"')
        self.write(self.shim_dir, "rrun", 'echo "RRUN $* (RRUN=${RRUN:-})"')

    def tearDown(self):
        shutil.rmtree(self.d, True)

    def write(self, d, name, body):
        p = os.path.join(d, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\n%s\n" % body)
        os.chmod(p, 0o755)

    def npm(self, *args, **env):
        e = rdmods.child_env(self.home, self.shim_dir, self.real_dir, **env)
        r = subprocess.run([os.path.join(self.shim_dir, "npm")] + list(args), env=e,
                           capture_output=True, text=True, timeout=30)
        return r.stdout.strip()

    def test_heavy_scripts_go_through_rrun(self):
        for args in (["run", "test:db"], ["run", "test:db", "--", "a.test.ts"], ["run-script", "test:db:rls"],
                     ["--prefix", "server", "run", "test:db"], ["-s", "run", "release:rehearse:migrations"], ["run", "check:db-all"], ["run", "check:server-test-typecheck"],
                     ["run", "--silent", "test:db"]):
            with self.subTest(args=args):
                self.assertEqual(self.npm(*args), "RRUN npm %s (RRUN=)" % " ".join(args))

    def test_everything_else_is_the_real_npm(self):
        for args in (["ci"], ["run", "test"], ["run", "test:dbx"], ["test"], ["run", "build", "--", "test:db"],
                     ["--prefix", "test:db", "run", "build"], ["exec", "test:db"]):
            with self.subTest(args=args):
                self.assertEqual(self.npm(*args), "REAL npm %s" % " ".join(args))

    def test_opt_outs_and_no_loop(self):
        self.assertEqual(self.npm("run", "test:db", RRUN="0"), "REAL npm run test:db")
        self.assertEqual(self.npm("run", "test:db", RRUN_REMOTE="1"), "REAL npm run test:db")
        for marker in ("src/real-od/x.test.ts", "scripts/doctor-drive/a.ts", "--approve=browser"):
            self.assertEqual(self.npm("run", "test:db", "--", marker), "REAL npm run test:db -- " + marker)
        os.remove(os.path.join(self.shim_dir, "rrun"))           # rrun not installed
        self.assertEqual(self.npm("run", "test:db"), "REAL npm run test:db")

    def test_shim_twice_on_path_still_finds_real_npm(self):
        e = rdmods.child_env(self.home, self.shim_dir, self.shim_dir, self.real_dir, RRUN="0")
        r = subprocess.run([os.path.join(self.shim_dir, "npm"), "ci"], env=e, capture_output=True,
                           text=True, timeout=30)
        self.assertEqual(r.stdout.strip(), "REAL npm ci")


if __name__ == "__main__":
    unittest.main()
