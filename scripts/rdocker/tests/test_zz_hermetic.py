"""Hermeticity guard: no test may write the real ~/.config/rdocker or ~/.local/state/rdocker, or
reach a real ssh / launchctl / osascript / open / Tailscale / docker.

Mechanism (tests/rdmods.py, imported before any rd_* module): RDOCKER_HOME -> a marked temp home
(rd_common derives every path from it), a fail-closed stub dir first on PATH, rd_daemon.TS_CLI ->
the stub, and child_env()/safe_path() for every spawned process. This file checks the mechanism
itself, so a new path constant, a new spawn site with a hand-built env, or a lost import fails
loudly instead of silently polluting the live daemon's state again. Named zz to sort last.
"""
import os
import pwd
import re
import shutil
import sys
import unittest
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
from rdmods import MODULES, STAGE, STUB_BIN, TEST_HOME  # noqa: E402

TESTS = os.path.dirname(os.path.abspath(__file__))
REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir      # what ~ means to ssh/launchd, whatever $HOME says
# Absolute strings that name something outside our home on purpose (not a file rdocker writes).
NOT_PATHS = {("rd_janitor", "BREW_PATH"), ("rd_args", "DOCKER_SOCKETS")}
rd_common = next(m for m in MODULES if m.__name__ == "rd_common")


def under(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def strings(val):
    if isinstance(val, str):
        yield val
    elif isinstance(val, dict):
        for v in val.values():
            yield from strings(v)
    elif isinstance(val, (list, tuple)):
        for v in val:
            yield from strings(v)


class Hermetic(unittest.TestCase):
    def test_test_home_is_a_marked_temp_dir_outside_real_home(self):
        self.assertEqual(os.environ.get("RDOCKER_HOME"), TEST_HOME)
        self.assertTrue(os.path.isfile(os.path.join(TEST_HOME, rdmods.MARKER)))
        self.assertFalse(under(TEST_HOME, REAL_HOME))
        self.assertEqual(rd_common.HOME, TEST_HOME)

    def test_every_path_constant_lives_under_test_home(self):
        bad = []
        for m in MODULES:
            for name, val in vars(m).items():
                if not name.isupper() or (m.__name__, name) in NOT_PATHS:
                    continue
                for s in strings(val):
                    if not s.startswith("/"):
                        continue
                    if not (under(s, TEST_HOME) or under(s, STAGE) or
                            (rd_common.IS_LINUX and s == "/var/run/docker.sock")):
                        bad.append("%s.%s = %r" % (m.__name__, name, s))
        self.assertEqual(bad, [], "path constants outside the temp RDOCKER_HOME")

    def test_guarded_binaries_resolve_to_fail_closed_stubs(self):
        for name in rdmods.GUARDED:
            self.assertEqual(shutil.which(name), os.path.join(STUB_BIN, name), name)
        self.assertTrue(under(rd_common.real_docker(), STUB_BIN))
        ts_cli = next(m for m in MODULES if m.__name__ == "rd_daemon").TS_CLI
        self.assertTrue(under(ts_cli, STUB_BIN), ts_cli)
        for name in ("ssh", "osascript", "launchctl"):
            rc, _, err = rd_common.run([name, "-V"], timeout=10)
            self.assertEqual(rc, rdmods.STUB_EXIT, err)
        self.assertTrue(rdmods.safe_path("/tmp/x").startswith("/tmp/x:" + STUB_BIN + ":"))

    def test_child_env_carries_its_home_and_stubs(self):
        home = os.path.join(TEST_HOME, "child")
        os.makedirs(home, exist_ok=True)
        e = rdmods.child_env(home, "/tmp/bin-x")
        self.assertEqual((e["HOME"], e["RDOCKER_HOME"]), (home, home))
        self.assertTrue(os.path.isfile(os.path.join(home, rdmods.MARKER)))   # a child keeps it
        self.assertTrue(e["PATH"].startswith("/tmp/bin-x:" + STUB_BIN + ":"))

    def test_writes_land_in_test_home_not_real_state(self):
        canary = "hermetic-canary-%s" % uuid.uuid4().hex
        rd_common.log(canary)
        with open(os.path.join(TEST_HOME, ".local", "state", "rdocker", "daemon.log")) as f:
            self.assertIn(canary, f.read())
        real = os.path.join(REAL_HOME, ".local", "state", "rdocker", "daemon.log")
        if os.path.exists(real):
            with open(real, "rb") as f:
                f.seek(max(0, os.path.getsize(real) - 1_000_000))
                self.assertNotIn(canary.encode(), f.read())

    def test_no_test_hand_builds_a_child_env(self):
        """Spawned rdockers must get their env from rdmods.child_env()/safe_path(): a hand-built
        env drops RDOCKER_HOME or puts /usr/bin (real ssh, launchctl, osascript) before the stubs."""
        forbidden = [r'startswith\("RDOCKER_"\)', r"/usr/bin:/bin", r"dict\(os\.environ",
                     r'\bHOME=', r'"HOME":']
        bad = []
        for fn in sorted(os.listdir(TESTS)):
            if not fn.endswith(".py") or fn in ("rdmods.py", os.path.basename(__file__)):
                continue
            with open(os.path.join(TESTS, fn)) as f:
                for i, line in enumerate(f, 1):
                    bad += ["%s:%d: %s" % (fn, i, line.strip()) for pat in forbidden
                            if re.search(pat, line) and "mini side" not in line]
        self.assertEqual(bad, [])

    def test_every_test_module_imports_rdmods(self):
        missing = []
        for fn in sorted(os.listdir(TESTS)):
            if fn.startswith("test_") and fn.endswith(".py"):
                with open(os.path.join(TESTS, fn)) as f:
                    if not re.search(r"^(import rdmods|from rdmods import|from test_shim_safety import)",
                                     f.read(), re.M):
                        missing.append(fn)
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
