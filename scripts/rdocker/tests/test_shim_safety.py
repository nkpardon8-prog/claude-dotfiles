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
sys.path.insert(0, TESTS)
import rdmods  # noqa: E402
from rdmods import r  # noqa: E402,F401  (re-exported to the other test modules)


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
        # blip_wait_s 0: refusal tests must not sit out the 30 s blip wait (BlipWait sets its own)
        c = {"local_socket": self.local_sock, "migrated": ["rtt300"], "blip_wait_s": 0}
        if pins:
            c["pins"] = pins
        c.update(cfg or {})
        with open(os.path.join(self.cfgdir, "config.json"), "w") as f:
            json.dump(c, f)
        if tunnel:
            self.socks.append(listen(os.path.join(self.state, "mini-docker.sock")))
        if laptop_up:
            self.socks.append(listen(self.local_sock))

    def shim(self, *argv, env=None, cwd=None, input=None):
        e = rdmods.child_env(self.home, self.bin, FAKE_DOCKER_FIXTURE=self.fixture,
                             FAKE_DOCKER_LOG=self.log, FAKE_DOCKER_STDIN_LOG=self.log + ".stdin")
        e.update(env or {})
        cmd = ["/usr/bin/python3", "-I", RDOCKER, "shim"] + list(argv)
        if cwd == "deleted":
            d = os.path.join(self.home, "gone")
            os.makedirs(d)
            cmd = ["/bin/sh", "-c", 'cd "$1" && rmdir "$1" && shift && exec "$@"', "sh", d] + cmd
        if input is not None:
            return subprocess.run(cmd, capture_output=True, input=input, env=e, timeout=60)
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

    def test_fallback_pinned_laptop_container_execs_while_mini_unknown(self):
        # live 2026-10-13: a throwaway run fell back (slow mini) and every later `exec` was refused
        pin = {"fallback": [{"name": "vit-db", "kind": "container", "ts": time.time()}]}
        for i, health in enumerate(({"reachable": False, "docker_ok": False, "rtt_ms": None},
                                    {"reachable": True, "docker_ok": False, "rtt_ms": None})):
            with self.subTest(health=health):
                if os.path.exists(self.log):
                    os.unlink(self.log)
                self.scenario(health=health, pins=pin, laptop={"containers": {"vit-db": {}}},
                              tunnel=False, laptop_up=(i == 0))   # Desktop socket stays bound
                p = self.shim("exec", "vit-db", "psql")
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual([c for c, _ in self.calls("exec")], ["desktop-linux"])

    def test_manually_pinned_laptop_container_stops_while_mini_down(self):
        self.scenario(health={"reachable": False, "docker_ok": False},
                      pins={"containers": ["X"]}, laptop={"containers": {"X": {}}}, tunnel=False)
        p = self.shim("stop", "X")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("stop")], ["desktop-linux"])

    def test_unpinned_laptop_container_exec_while_mini_unknown_refuses(self):
        self.scenario(health={"reachable": True, "docker_ok": False},
                      laptop={"containers": {"X": {}}}, tunnel=False)
        p = self.shim("exec", "X", "ls")
        self.assertEqual(p.returncode, 1)
        self.assertIn("refusing to guess", p.stderr)
        self.assertEqual(self.calls("exec"), [])

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
    """Auto mode, mini usable but rtt_ms > max_rtt_ms on the last 2 consecutive health readings: only
    NEW throwaway containers go to the laptop."""
    NOW = time.time()
    SLOW = {"rtt_ms": 500.0, "rtt_hist": [[NOW - 30, 20.0], [NOW - 15, 450.0], [NOW, 500.0]]}
    SPIKE = {"rtt_ms": 827.4, "rtt_hist": [[NOW - 30, 20.0], [NOW - 15, 25.0], [NOW, 827.4]]}

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
        self.assertIn("running on the laptop (mini round-trip 500.0ms > 300ms on 2 consecutive "
                      "readings)", p.stderr)

    def test_single_slow_reading_keeps_throwaway_on_mini(self):
        # live 2026-10-13: one 827 ms sample sent a vitest db to the laptop (starting Docker Desktop)
        self.scenario(health=self.SPIKE)
        p = self.shim("run", "--rm", "alpine", "true")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("run")], ["mini"])
        self.assertNotIn("running on the laptop", p.stderr)

    def test_engine_silent_still_falls_back_immediately(self):
        self.scenario(health={"docker_ok": False, "rtt_ms": None, "rtt_hist": [[self.NOW, None]]})
        p = self.shim("run", "--rm", "alpine", "true")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("run")], ["desktop-linux"])

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


class RoutingError(ShimCase):
    """Routing raised before docker ran: only FALLBACK_SAFE commands run (on the real docker);
    anything that targets or creates a container exits 1. The traceback lands in route.log."""

    def broken(self):
        self.scenario(mini={"containers": {"db": {}}})
        with open(os.path.join(self.cfgdir, "config.json"), "w") as f:
            json.dump({"pins": "not-a-dict", "migrated": ["rtt300"]}, f)   # load_cfg raises

    def test_safe_command_runs_real_docker(self):
        self.broken()
        p = self.shim("ps")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls(), [(None, ["ps"])])

    def test_container_commands_refused_without_docker(self):
        self.broken()
        for argv, sub in ((["run", "-d", "redis"], "run"), (["stop", "db"], "stop"),
                          (["compose", "up", "-d"], "compose")):
            p = self.shim(*argv)
            self.assertEqual(p.returncode, 1, argv)
            self.assertIn("rdocker: internal error routing %s: " % sub, p.stderr)
            self.assertIn("(run rdocker doctor)", p.stderr)
        self.assertEqual(self.calls(), [])
        with open(os.path.join(self.state, "route.log")) as f:
            self.assertIn("Traceback", f.read())


class AttentionNotice(ShimCase):
    def test_one_stderr_line_per_hour_stdout_and_rc_untouched(self):
        self.scenario(mini={"containers": {"db": {}}})
        with open(os.path.join(self.state, "attention.json"), "w") as f:
            json.dump([{"key": "engine", "msg": "mini engine needs a look", "since": 1}], f)
        first = self.shim("ps", "-q")
        quiet = self.shim("ps", "-q")
        line = "rdocker: needs attention: mini engine needs a look (run rdocker status)\n"
        self.assertEqual(first.stderr.count(line), 1, first.stderr)
        self.assertNotIn("needs attention", quiet.stderr)
        self.assertEqual((first.returncode, first.stdout), (quiet.returncode, quiet.stdout))
        self.assertNotIn("attention", first.stdout)



class RrunSafetyNet(ShimCase):
    """A container created from inside a heavy npm script (npm_lifecycle_event / _script matches
    rr_route_patterns) that is not running under rrun goes to the laptop with a one-line hint."""
    HINT = "run it as `rrun <cmd>`"

    def test_test_db_script_run_goes_to_laptop_with_hint(self):
        self.scenario()
        p = self.shim("run", "-d", "-p", "5432", "postgres", env={"npm_lifecycle_event": "test:db"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("run")], ["desktop-linux"])
        self.assertEqual(p.stderr.count(self.HINT), 1, p.stderr)
        self.assertIn("rdocker: heavy test script npm run test:db: its DB goes to the laptop",
                      p.stderr)

    def test_script_body_matches_too(self):
        self.scenario()
        p = self.shim("run", "--rm", "postgres", env={
            "npm_lifecycle_event": "itest", "npm_lifecycle_script": "node scripts/test-with-db.mjs"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, _ in self.calls("run")], ["desktop-linux"])
        self.assertIn(self.HINT, p.stderr)

    def test_compose_up_goes_to_laptop(self):
        model = {"name": "proj", "services": {"db": {"image": "postgres"}}}
        self.scenario(compose_model=model)
        p = self.shim("compose", "up", "-d", env={"npm_lifecycle_event": "test:db:rls"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual({c for c, _ in self.calls("compose")[1:]}, {"desktop-linux"})
        self.assertIn(self.HINT, p.stderr)

    def test_under_rrun_or_other_scripts_or_non_auto_mode_stays_on_mini(self):
        cases = (("rrun job", {"npm_lifecycle_event": "test:db", "RRUN_REMOTE": "1"}),
                 ("other script", {"npm_lifecycle_event": "test"}),
                 ("look-alike", {"npm_lifecycle_event": "test:dbx"}),
                 ("forced mini", {"npm_lifecycle_event": "test:db", "RDOCKER_MODE": "mini"}),
                 ("no npm", {}))
        for label, env in cases:
            with self.subTest(label):
                if os.path.exists(self.log):
                    os.unlink(self.log)
                self.scenario(laptop_up=False)
                p = self.shim("run", "-d", "postgres", env=env)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual([c for c, _ in self.calls("run")], ["mini"])
                self.assertNotIn("rrun", p.stderr)
                for s in self.socks:
                    s.close()
                self.socks.clear()

    def test_user_patterns_override_defaults(self):
        self.scenario(cfg={"rr_route_patterns": [r"^e2e:heavy$"]})
        p = self.shim("run", "-d", "postgres", env={"npm_lifecycle_event": "e2e:heavy"})
        self.assertEqual([c for c, _ in self.calls("run")], ["desktop-linux"])
        self.assertIn(self.HINT, p.stderr)
        os.unlink(self.log)
        p = self.shim("run", "-d", "postgres", env={"npm_lifecycle_event": "test:db"})
        self.assertEqual([c for c, _ in self.calls("run")], ["mini"])
        self.assertNotIn("rrun", p.stderr)

    def test_non_creating_commands_unaffected(self):
        self.scenario(mini={"containers": {"X": {}}})
        p = self.shim("exec", "X", "ls", env={"npm_lifecycle_event": "test:db"})
        self.assertEqual([c for c, _ in self.calls("exec")], ["mini"])
        self.assertNotIn("rrun", p.stderr)


class PingServer:
    """Stands in for the forwarded mini engine socket: answers `GET /_ping` with 200 OK (and
    /version) when `answer` is true, else closes every connection at once (a fast probe failure).
    Connections that send nothing (unix_alive checks) are just closed."""

    def __init__(self, path, answer=True):
        import threading
        self.answer, self.pings = answer, 0
        self.sock = listen(path)
        self.sock.settimeout(0.2)
        self.stop = False
        self.t = threading.Thread(target=self.loop, daemon=True)
        self.t.start()

    def loop(self):
        while not self.stop:
            try:
                c, _ = self.sock.accept()
            except OSError:
                continue
            try:
                c.settimeout(1.0)
                try:
                    req = c.recv(4096)
                except OSError:
                    req = b""
                if req and self.answer:
                    if b"/_ping" in req:
                        self.pings += 1
                        body = b"OK"
                    else:
                        body = b'{"Version": "28.5.1"}'
                    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            finally:
                c.close()

    def close(self):
        self.stop = True
        self.t.join(2)
        self.sock.close()


class BlipWait(ShimCase):
    """A targeted command refused only because the mini's side is unknown first waits out a short
    blip: locate is retried (forced health probe each time) for up to blip_wait_s."""
    UNREACHABLE = {"reachable": False, "docker_ok": False, "rtt_ms": None, "failure": "tunnel"}

    def server(self, answer=True):
        srv = PingServer(os.path.join(self.state, "mini-docker.sock"), answer)
        self.addCleanup(srv.close)
        return srv

    def timed(self, *argv, **kw):
        t = time.monotonic()
        p = self.shim(*argv, **kw)
        return p, time.monotonic() - t

    def health_file(self):
        with open(os.path.join(self.state, "health.json")) as f:
            return json.load(f)

    def test_inspect_unanswered_once_then_runs_on_mini_once(self):
        # live 2026-10-14 14:22: `refuse exec cannot tell where container wlpg-... lives (mini did
        # not answer)` during a short link drop
        hist = [[time.time() - 15, 20.0], [time.time(), 21.0]]
        self.scenario(mini={"containers": {"X": {}}, "fail_once": ["container inspect"]},
                      health={"rtt_hist": hist}, cfg={"blip_wait_s": 30}, tunnel=False)
        srv = self.server()
        p, took = self.timed("exec", "X", "ls")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("rdocker: mini not answering - waiting up to 30s...", p.stderr)
        self.assertEqual([c for c, _ in self.calls("exec")], ["mini"])     # exactly once
        self.assertLess(took, 20)
        self.assertGreaterEqual(srv.pings, 1)                             # a forced probe ran
        self.assertEqual(self.health_file()["rtt_hist"], hist)            # blip probes not counted

    def test_mini_comes_back_after_unreachable(self):
        self.scenario(mini={"containers": {"X": {}}}, health=self.UNREACHABLE,
                      cfg={"blip_wait_s": 30}, tunnel=False)
        self.server()
        p, took = self.timed("stop", "X")
        self.addCleanup(wait_bg_sync)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("stop"), [("mini", ["stop", "X"])])
        self.assertLess(took, 20)

    def test_never_back_refuses_by_the_deadline(self):
        self.scenario(mini={"containers": {"X": {}}}, health=self.UNREACHABLE,
                      cfg={"blip_wait_s": 8}, tunnel=False)
        self.server(answer=False)
        p, took = self.timed("rm", "-f", "X")
        self.assertEqual(p.returncode, 1)
        self.assertIn("waiting up to 8s", p.stderr)
        self.assertIn("cannot tell where container X lives (mini unreachable)", p.stderr)
        self.assertEqual(self.calls("rm"), [])
        self.assertGreaterEqual(took, 3)          # one retry round ran
        self.assertLess(took, 8 + 2)              # and nothing ran past the budget

    def test_no_round_started_with_less_than_a_probe_timeout_left(self):
        self.scenario(mini={"containers": {"X": {}}}, health=self.UNREACHABLE,
                      cfg={"blip_wait_s": 2}, tunnel=False)
        self.server(answer=False)
        p, took = self.timed("rm", "-f", "X")
        self.assertEqual(p.returncode, 1)
        self.assertLess(took, 2)

    def test_stuck_tunnel_class_does_not_wait(self):
        # live master (`ssh -O check` answers) + tunnel-class failure: only the daemon can rebuild it
        with open(os.path.join(self.bin, "ssh"), "w") as f:
            f.write('#!/bin/sh\necho "Master running (pid=4242)" >&2\nexit 0\n')
        self.scenario(mini={"containers": {"X": {}}},
                      health={"reachable": True, "docker_ok": False, "rtt_ms": None,
                              "failure": "tunnel"}, cfg={"blip_wait_s": 30})
        p, took = self.timed("rm", "-f", "X")
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("waiting", p.stderr)
        self.assertIn("cannot tell where container X lives", p.stderr)
        self.assertLess(took, 10)

    def test_paths_that_do_not_need_the_mini_do_not_wait(self):
        pin = {"fallback": [{"name": "vit-db", "kind": "container", "ts": time.time()}]}
        cases = (
            ("throwaway run falls back", None, ("run", "--rm", "alpine", "true"), 0),
            ("fallback-pinned exec", pin, ("exec", "vit-db", "ls"), 0),
            ("non-throwaway create refusal", None, ("run", "-d", "-v", "data:/d", "postgres"), 1),
            ("mode=mini refusal", None, ("exec", "X", "ls"), 1),
        )
        for i, (label, pins, argv, rc) in enumerate(cases):
            with self.subTest(label):
                for f in (self.log, os.path.join(self.state, "health.json")):
                    if os.path.exists(f):
                        os.unlink(f)
                self.scenario(laptop={"containers": {"vit-db": {}}}, health=self.UNREACHABLE,
                              pins=pins, cfg={"blip_wait_s": 30}, tunnel=False,
                              laptop_up=i == 0)      # the Desktop socket stays up across cases
                env = {"RDOCKER_MODE": "mini"} if label.startswith("mode=mini") else None
                p, took = self.timed(*argv, env=env)
                self.assertEqual(p.returncode, rc, p.stderr)
                self.assertNotIn("waiting", p.stderr)
                self.assertLess(took, 10)


if __name__ == "__main__":
    unittest.main()
