"""Shim routing-safety tests: run `rdocker.py shim ...` as a subprocess against tests/fake_docker.py.

Seams (no code-level test hooks in rdocker.py):
  * HOME is a temp dir - rdocker derives every path from HOME at import.
  * PATH starts with a temp bin dir holding `docker` -> fake_docker.py, plus `ssh`/`open` stubs that
    fail fast, so nothing ever reaches a real engine, the network, or Docker Desktop.
  * A fresh health.json (ts=now) is pre-written, so the shim never probes.
  * "Tunnel up" / "Docker Desktop up" = a listening unix socket at MINI_SOCK / the configured
    local_socket (rdocker only connect()s to them).

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

TESTS = os.path.dirname(os.path.abspath(__file__))
STAGE = os.path.abspath(os.path.join(TESTS, ".."))
RDOCKER = os.path.join(STAGE, "rdocker.py")
FAKE = os.path.join(TESTS, "fake_docker.py")
sys.path.insert(0, STAGE)
import rdocker as r  # noqa: E402


def listen(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    s.listen(16)
    return s


class ShimCase(unittest.TestCase):
    def setUp(self):
        # Unix socket paths are capped at 104 bytes on macOS; keep HOME short.
        self.home = tempfile.mkdtemp(prefix="rdk-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.state = os.path.join(self.home, ".local", "state", "rdocker")
        self.cfgdir = os.path.join(self.home, ".config", "rdocker")
        os.makedirs(self.state)
        os.makedirs(self.cfgdir)
        self.bin = os.path.join(self.home, "bin")
        os.makedirs(self.bin)
        os.symlink(FAKE, os.path.join(self.bin, "docker"))
        for stub in ("ssh", "open"):
            p = os.path.join(self.bin, stub)
            with open(p, "w") as f:
                f.write("#!/bin/sh\nexit 255\n")
            os.chmod(p, 0o755)
        self.log = os.path.join(self.home, "docker.log")
        self.fixture = os.path.join(self.home, "fixture.json")
        self.local_sock = os.path.join(self.home, "dsk.sock")
        self.socks = []
        self.addCleanup(lambda: [s.close() for s in self.socks])

    # -- scenario builders -------------------------------------------------------------------
    def scenario(self, mini=None, laptop=None, health=None, pins=None, cfg=None, compose_model=None,
                 tunnel=True, laptop_up=True):
        fx = {"mini": mini if mini is not None else {"containers": {}},
              "desktop-linux": laptop if laptop is not None else {"containers": {}}}
        if compose_model is not None:
            fx["_compose_model"] = compose_model
        with open(self.fixture, "w") as f:
            json.dump(fx, f)
        h = {"ts": time.time(), "reachable": True, "docker_ok": True, "rtt_ms": 20.0,
             "server_version": "28.5.1"}
        h.update(health or {})
        with open(os.path.join(self.state, "health.json"), "w") as f:
            json.dump(h, f)
        c = {"local_socket": self.local_sock, "migrated": ["rtt300"]}
        if pins:
            c["pins"] = pins
        c.update(cfg or {})
        with open(os.path.join(self.cfgdir, "config.json"), "w") as f:
            json.dump(c, f)
        if tunnel:
            self.socks.append(listen(os.path.join(self.state, "mini-docker.sock")))
        if laptop_up:
            self.socks.append(listen(self.local_sock))

    def shim(self, *argv, env=None, cwd=None):
        e = {k: v for k, v in os.environ.items()
             if not k.startswith("RDOCKER_") and k not in ("DOCKER_HOST", "DOCKER_CONTEXT")}
        e.update(HOME=self.home, PATH=self.bin + ":/usr/bin:/bin",
                 FAKE_DOCKER_FIXTURE=self.fixture, FAKE_DOCKER_LOG=self.log)
        e.update(env or {})
        cmd = ["/usr/bin/python3", "-I", RDOCKER, "shim"] + list(argv)
        if cwd == "deleted":
            d = os.path.join(self.home, "gone")
            os.makedirs(d)
            cmd = ["/bin/sh", "-c", 'cd "$1" && rmdir "$1" && shift && exec "$@"', "sh", d] + cmd
        return subprocess.run(cmd, capture_output=True, text=True, env=e, timeout=60)

    def calls(self, verb=None):
        """Logged docker argvs (minus probes), optionally only those whose subcommand is `verb`."""
        try:
            with open(self.log) as f:
                rows = [json.loads(line) for line in f if line.strip()]
        except OSError:
            return []
        out = []
        for a in rows:
            ctx = a[1] if a[:1] == ["--context"] else None
            rest = a[2:] if ctx else a
            if verb is None or rest[:1] == [verb]:
                out.append((ctx, rest))
        return out

    def pins(self):
        with open(os.path.join(self.cfgdir, "config.json")) as f:
            return json.load(f).get("pins") or {}


class ExecuteOnce(ShimCase):
    def test_exception_after_docker_ran_does_not_rerun(self):
        self.scenario()
        os.makedirs(os.path.join(self.state, "sync.lock"))   # sync_forwards' open() now raises
        p = self.shim("run", "-d", "--name", "web", "alpine", "sleep", "1")
        runs = self.calls("run")
        self.assertEqual(len(runs), 1, runs)
        self.assertEqual(runs[0][0], "mini")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("after docker ran", p.stderr)

    def test_deleted_cwd_still_routes(self):
        self.scenario(mini={"containers": {"X": {}}})
        p = self.shim("exec", "X", "ls", cwd="deleted")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("exec")], ["mini"])
        with open(os.path.join(self.state, "route.log")) as f:
            self.assertIn("| ?", f.read())


class RefuseUnknown(ShimCase):
    def test_mini_unreachable_rm_of_unknown_refuses(self):
        self.scenario(health={"reachable": False, "docker_ok": False, "rtt_ms": None})
        p = self.shim("rm", "-f", "X")
        self.assertEqual(p.returncode, 1)
        self.assertIn("cannot tell where container X lives (mini unreachable)", p.stderr)
        self.assertEqual(self.calls("rm"), [])

    def test_mini_engine_error_is_unknown_not_missing(self):
        self.scenario(mini={"down": True})
        p = self.shim("stop", "X")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.calls("stop"), [])

    def test_found_only_locally_while_mini_down_mutating_refuses(self):
        self.scenario(health={"reachable": False, "docker_ok": False},
                      laptop={"containers": {"X": {}}})
        p = self.shim("rm", "-f", "X")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.calls("rm"), [])

    def test_found_only_locally_while_mini_down_read_only_runs_locally(self):
        self.scenario(health={"reachable": False, "docker_ok": False},
                      laptop={"containers": {"X": {}}})
        p = self.shim("logs", "X")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("logs")], ["desktop-linux"])
        self.assertIn("found only on the laptop", p.stderr)

    def test_missing_everywhere_goes_to_default_engine(self):
        self.scenario()
        # (`logs`, not `rm`: a mini rm spawns the detached port-sync, which would outlive the test)
        self.shim("logs", "nope")
        self.assertEqual([c for c, _ in self.calls("logs")], ["mini"])

    def test_mode_mini_never_falls_back(self):
        self.scenario(health={"reachable": False, "docker_ok": False})
        p = self.shim("ps", env={"RDOCKER_MODE": "mini"})
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.calls("ps"), [])


class LocateBeforeDecide(ShimCase):
    def test_slow_mini_still_owns_its_container(self):
        self.scenario(health={"rtt_ms": 5000.0}, mini={"containers": {"X": {}}})
        p = self.shim("exec", "X", "ls")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("exec")], ["mini"])

    def test_logs_tail_value_and_pinned_laptop_container(self):
        self.scenario(laptop={"containers": {"pinnedX": {}}}, pins={"containers": ["pinnedX"]})
        p = self.shim("logs", "-n", "5", "pinnedX")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("logs"), [("desktop-linux", ["logs", "-n", "5", "pinnedX"])])

    def test_stop_timeout_value_parses_target(self):
        self.scenario(laptop={"containers": {"X": {}}})
        p = self.shim("stop", "-t", "0", "X")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("stop"), [("desktop-linux", ["stop", "-t", "0", "X"])])

    def test_image_inspect_is_not_located(self):
        self.scenario()
        self.shim("image", "inspect", "alpine")
        self.assertEqual(self.calls("container"), [])     # no container-inspect probe


class FallbackPolicy(ShimCase):
    DOWN = {"reachable": False, "docker_ok": False, "rtt_ms": None}

    def test_throwaway_run_falls_back_with_notice(self):
        self.scenario(health=self.DOWN)
        p = self.shim("run", "--rm", "alpine", "true")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("run")], ["desktop-linux"])
        self.assertIn("running on the laptop (mini unreachable)", p.stderr)

    def test_named_volume_run_refuses(self):
        self.scenario(health=self.DOWN)
        p = self.shim("run", "-d", "-v", "data:/d", "postgres")
        self.assertEqual(p.returncode, 1)
        self.assertIn("named volume data", p.stderr)
        self.assertEqual(self.calls("run"), [])

    def test_keep_label_run_refuses_and_mode_local_forces(self):
        self.scenario(health=self.DOWN)
        self.assertEqual(self.shim("run", "-d", "-l", "rdocker.keep=1", "redis").returncode, 1)
        p = self.shim("run", "-d", "-l", "rdocker.keep=1", "redis", env={"RDOCKER_MODE": "local"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("run")], ["desktop-linux"])

    def test_fallback_pin_added_then_dropped_on_laptop_rm(self):
        self.scenario(health=self.DOWN, laptop={"containers": {"tmp1": {}}})
        self.assertEqual(self.shim("run", "-d", "--name", "tmp1", "alpine", "sleep", "9").returncode, 0)
        self.assertEqual([p["name"] for p in self.pins()["fallback"]], ["tmp1"])
        # the mini comes back and does not have tmp1 -> rm runs on the laptop and drops the pin
        with open(os.path.join(self.state, "health.json"), "w") as f:
            json.dump({"ts": time.time(), "reachable": True, "docker_ok": True, "rtt_ms": 20.0}, f)
        p = self.shim("rm", "-f", "tmp1")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("rm"), [("desktop-linux", ["rm", "-f", "tmp1"])])
        self.assertEqual(self.pins().get("fallback", []), [])

    def test_compose_named_volume_refuses(self):
        model = {"name": "proj", "services": {"db": {"image": "postgres", "volumes": [
            {"type": "volume", "source": "pg", "target": "/var/lib/postgresql/data"}]}},
            "volumes": {"pg": {}}}
        self.scenario(health=self.DOWN, compose_model=model)
        p = self.shim("compose", "up", "-d")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.calls("compose")[1:], [])   # only the client-side config render


class SlowMiniOnlyMovesThrowaways(ShimCase):
    """Auto mode, mini usable but rtt_ms > max_rtt_ms: only NEW throwaway containers go to the laptop."""
    SLOW = {"rtt_ms": 500.0}

    def test_ps_stays_on_mini(self):
        self.scenario(health=self.SLOW)
        p = self.shim("ps")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("ps")[0][0], "mini")
        self.assertNotIn("running on the laptop", p.stderr)

    def test_images_stays_on_mini(self):
        self.scenario(health=self.SLOW)
        self.assertEqual(self.shim("images").returncode, 0)
        self.assertEqual([c for c, _ in self.calls("images")], ["mini"])

    def test_throwaway_run_goes_to_laptop_with_notice(self):
        self.scenario(health=self.SLOW)
        p = self.shim("run", "--rm", "alpine", "true")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("run")], ["desktop-linux"])
        self.assertIn("running on the laptop (mini round-trip 500.0ms > 300ms)", p.stderr)

    def test_named_volume_run_stays_on_mini(self):
        self.scenario(health=self.SLOW)
        p = self.shim("run", "-d", "-v", "data:/d", "postgres")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("run")], ["mini"])

    def test_rm_of_mini_container_stays_on_mini(self):
        self.scenario(health=self.SLOW, mini={"containers": {"X": {}}})
        self.addCleanup(wait_bg_sync)
        p = self.shim("rm", "-f", "X")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("rm"), [("mini", ["rm", "-f", "X"])])


def wait_bg_sync(limit=10.0):
    """A mini `rm` spawns a detached one-shot `rdocker.py sync`; let it finish before HOME is removed."""
    deadline = time.time() + limit
    while time.time() < deadline:
        p = subprocess.run(["/usr/bin/pgrep", "-f", RDOCKER + " sync"], capture_output=True)
        if p.returncode != 0:
            return
        time.sleep(0.1)


class FlagParsing(unittest.TestCase):
    def test_container_targets_with_value_flags(self):
        self.assertEqual(r.container_targets("logs", ["-n", "5", "db"]), ["db"])
        self.assertEqual(r.container_targets("logs", ["-n5", "-f", "db"]), ["db"])
        self.assertEqual(r.container_targets("logs", ["--tail=5", "-ft", "db"]), ["db"])
        self.assertEqual(r.container_targets("stop", ["-t", "0", "a", "b"]), ["a", "b"])
        self.assertEqual(r.container_targets("kill", ["-s", "KILL", "a"]), ["a"])
        self.assertEqual(r.container_targets("exec", ["-it", "-u", "0", "db", "sh"]), ["db"])
        self.assertEqual(r.container_targets("inspect", ["-f", "{{.Id}}", "db"]), ["db"])
        self.assertEqual(r.container_targets("top", ["db", "-o", "pid"]), ["db"])
        self.assertEqual(r.container_targets("commit", ["-m", "msg", "db", "img"]), ["db"])

    def test_run_detached_only_before_image(self):
        self.assertTrue(r.is_detached(["-dit", "--rm", "alpine"]))
        self.assertTrue(r.is_detached(["--name", "x", "-d", "alpine"]))
        self.assertFalse(r.is_detached(["--rm", "alpine", "sh", "-d"]))
        self.assertFalse(r.is_detached(["-e", "d=1", "alpine"]))
        self.assertFalse(r.is_detached(["-a", "stdout", "alpine"]))

    def test_run_short_values(self):
        self.assertEqual(r.positionals_index(["-a", "stdout", "-p", "80", "img"]), 4)
        self.assertEqual(r.positionals_index(["-itv/x:/y", "img"]), 1)

    def test_throwaway(self):
        self.assertIsNone(r.run_not_throwaway(["--rm", "-v", "data:/d", "pg"]))
        self.assertIsNone(r.run_not_throwaway(["-d", "-v", "/var/run/docker.sock:/s", "x"]))
        self.assertIsNone(r.run_not_throwaway(["-d", "-v", "/anon", "x"]))
        self.assertTrue(r.run_not_throwaway(["-d", "-v", "data:/d", "pg"]))
        self.assertTrue(r.run_not_throwaway(["-d", "--mount", "source=data,target=/d", "pg"]))
        self.assertTrue(r.run_not_throwaway(["-d", "--label", "rdocker.keep=1", "pg"]))
        self.assertIsNone(r.run_not_throwaway(["alpine", "-v", "data:/d"]))   # after the image


if __name__ == "__main__":
    unittest.main()
