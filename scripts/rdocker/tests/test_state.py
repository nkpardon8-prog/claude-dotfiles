"""State/config/health tests. Each case runs rdocker in a subprocess with HOME pointed at a temp dir
(rdocker computes every path from HOME at import), so nothing touches the real ~/.config / state.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

STAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

PRELUDE = textwrap.dedent("""
    import json, os, sys, time
    sys.path.insert(0, %r)
    import rdocker as r
""" % os.path.abspath(STAGE))


class InHome(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="rdocker-test-")
        self.addCleanup(shutil.rmtree, self.home, True)

    def run_py(self, body):
        """Run PRELUDE + body as a script under HOME=self.home; return its last stdout line as JSON."""
        script = os.path.join(self.home, "case.py")
        with open(script, "w") as f:
            f.write(PRELUDE + textwrap.dedent(body))
        env = dict(os.environ, HOME=self.home)
        p = subprocess.run([sys.executable, "-I", script], capture_output=True, text=True,
                           env=env, timeout=120)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout.strip().splitlines()[-1])

    def cfg_file(self):
        with open(os.path.join(self.home, ".config", "rdocker", "config.json")) as f:
            return json.load(f)


class UpdateJsonConcurrency(InHome):
    def test_eight_processes_fifty_increments_each(self):
        out = self.run_py("""
            import multiprocessing as mp
            PATH = os.path.join(r.STATE_DIR, "counter.json")

            def bump(_):
                for _ in range(50):
                    r.update_json(PATH, lambda d: {"n": (d or {}).get("n", 0) + 1}, default={})

            if __name__ == "__main__":
                r.ensure_dirs()
                procs = [mp.Process(target=bump, args=(i,)) for i in range(8)]
                for p in procs:
                    p.start()
                for p in procs:
                    p.join()
                with open(PATH) as f:
                    data = json.load(f)          # must be valid JSON
                leftovers = [x for x in os.listdir(r.STATE_DIR) if x.endswith(".tmp")]
                print(json.dumps({"n": data["n"], "codes": [p.exitcode for p in procs],
                                  "tmp": leftovers}))
        """)
        self.assertEqual(out["codes"], [0] * 8)
        self.assertEqual(out["n"], 400)
        self.assertEqual(out["tmp"], [])


class ConfigPersistence(InHome):
    def test_save_cfg_omits_default_valued_keys(self):
        self.run_py("""
            cfg = r.load_cfg()
            cfg["mode"] = "mini"
            cfg["pins"]["containers"] = ["pg"]
            r.save_cfg(cfg)
            print("{}")
        """)
        stored = self.cfg_file()
        self.assertEqual(stored.get("mode"), "mini")
        self.assertEqual(stored.get("pins"), {"containers": ["pg"]})
        for k in ("max_rtt_ms", "host", "janitor_interval_min", "ephemeral_port_range"):
            self.assertNotIn(k, stored)

    def test_load_cfg_deep_merges_pins_and_new_defaults(self):
        out = self.run_py("""
            os.makedirs(r.CFG_DIR)
            with open(r.CFG_PATH, "w") as f:
                json.dump({"pins": {"containers": ["a"]}}, f)
            c = r.load_cfg()
            print(json.dumps({"pins": c["pins"], "range": c["ephemeral_port_range"],
                              "defaults_untouched": r.DEFAULTS["pins"]["containers"] == []}))
        """)
        self.assertEqual(out["pins"], {"containers": ["a"], "compose_projects": [], "fallback": []})
        self.assertEqual(out["range"], [20000, 29999])
        self.assertTrue(out["defaults_untouched"])

    def test_rtt_migration_150_to_300_runs_once(self):
        out = self.run_py("""
            os.makedirs(r.CFG_DIR)
            with open(r.CFG_PATH, "w") as f:
                json.dump({"max_rtt_ms": 150, "mode": "mini"}, f)
            first = r.load_cfg()["max_rtt_ms"]
            with open(r.CFG_PATH) as f:
                after = json.load(f)
            # the user deliberately sets 150 again: must NOT be migrated a second time
            r.update_cfg(lambda c: dict(c, max_rtt_ms=150))
            second = r.load_cfg()["max_rtt_ms"]
            print(json.dumps({"first": first, "after": after, "second": second}))
        """)
        self.assertEqual(out["first"], 300)
        self.assertNotIn("max_rtt_ms", out["after"])      # 300 is the default -> not stored
        self.assertIn("rtt300", out["after"]["migrated"])
        self.assertEqual(out["after"]["mode"], "mini")
        self.assertEqual(out["second"], 150)


class HealthFreshness(InHome):
    def test_future_dated_and_stale_readings_are_rejected(self):
        out = self.run_py("""
            now = time.time()
            print(json.dumps({
                "fresh": r.health_fresh({"ts": now - 5}, now),
                "future": r.health_fresh({"ts": now + 100}, now),
                "stale": r.health_fresh({"ts": now - 31}, now),
                "missing": r.health_fresh({}, now),
            }))
        """)
        self.assertEqual(out, {"fresh": True, "future": False, "stale": False, "missing": False})

    def test_health_reprobes_future_dated_file_without_carrying_docker_ok(self):
        out = self.run_py("""
            r.ensure_dirs()
            with open(r.HEALTH_PATH, "w") as f:
                json.dump({"ts": time.time() + 3600, "reachable": True, "docker_ok": True,
                           "rtt_ms": 10}, f)
            calls = []
            def fake_probe(cfg):
                calls.append(1)
                return {"ts": time.time(), "reachable": False, "docker_ok": False,
                        "rtt_ms": None, "server_version": ""}
            r.probe_health = fake_probe
            h = r.health(r.load_cfg())
            again = r.health(r.load_cfg())       # now fresh -> served from the file
            with open(r.HEALTH_PATH) as f:
                stored = json.load(f)
            print(json.dumps({"calls": len(calls), "docker_ok": h["docker_ok"],
                              "stored_ok": stored["docker_ok"], "again": again["docker_ok"]}))
        """)
        self.assertEqual(out, {"calls": 1, "docker_ok": False, "stored_ok": False, "again": False})


class ProbeFailureClassification(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, os.path.abspath(STAGE))
        import rdocker
        self.r = rdocker

    def test_live_tunnel_means_engine_problem(self):
        self.assertEqual(self.r.classify_probe_failure(False, True), "engine")

    def test_dead_tunnel_means_reset(self):
        self.assertEqual(self.r.classify_probe_failure(False, False), "tunnel")

    def test_success_needs_no_classification(self):
        self.assertIsNone(self.r.classify_probe_failure(True, False))


class ProbeHealthBranches(InHome):
    """probe_health with the ssh/docker edges stubbed: only a dead tunnel may reset the master."""
    BODY = """
        resets = []
        r.docker_probe = lambda cfg: (False, "", 4000.0)
        r.master_pid = lambda cfg: 4242
        r.tunnel_alive = lambda cfg: %s
        r.reset_master = lambda cfg: resets.append(1)
        h = r.probe_health(r.load_cfg())
        print(json.dumps({"resets": len(resets), "reachable": h["reachable"],
                          "docker_ok": h["docker_ok"]}))
    """

    def test_engine_down_keeps_master(self):
        out = self.run_py(self.BODY % "True")
        self.assertEqual(out, {"resets": 0, "reachable": True, "docker_ok": False})

    def test_stale_tunnel_resets_and_retries(self):
        out = self.run_py(self.BODY % "False")
        self.assertEqual(out, {"resets": 1, "reachable": True, "docker_ok": False})


class RawSocketProbe(unittest.TestCase):
    """http_unix / docker_probe against a fake docker API on a unix socket in a temp dir."""

    def setUp(self):
        sys.path.insert(0, os.path.abspath(STAGE))
        import rdocker
        self.r = rdocker
        d = tempfile.mkdtemp(prefix="rdp-", dir="/tmp")     # macOS caps unix paths at 104 bytes
        self.addCleanup(shutil.rmtree, d, True)
        self.path = os.path.join(d, "d.sock")
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(self.path)
        self.srv.listen(8)
        self.addCleanup(self.srv.close)
        self.held = []
        self.addCleanup(lambda: [c.close() for c in self.held])

    def serve(self, handler):
        def loop():
            while True:
                try:
                    c, _ = self.srv.accept()
                except OSError:
                    return
                req = b""
                while b"\r\n\r\n" not in req:
                    got = c.recv(4096)
                    if not got:
                        break
                    req += got
                line = req.split(b"\r\n", 1)[0].decode()
                if handler(c, line.split(" ")[1] if " " in line else ""):
                    c.close()
                else:
                    self.held.append(c)            # hung: never answers, never closes
        threading.Thread(target=loop, daemon=True).start()

    @staticmethod
    def docker_api(c, path):
        if path == "/_ping":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK")
        elif path == "/version":
            body = json.dumps({"Version": "28.5.1", "ApiVersion": "1.51"}).encode()
            chunked = b"%x\r\n%s\r\n0\r\n\r\n" % (len(body), body)
            c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunked)
        else:
            c.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        return True

    def patch(self, name, value):
        self.addCleanup(setattr, self.r, name, getattr(self.r, name))
        setattr(self.r, name, value)

    def probe(self):
        self.patch("MINI_SOCK", self.path)
        self.patch("ensure_mini_socket", lambda cfg: True)
        return self.r.docker_probe({})

    def test_ping_and_chunked_version(self):
        self.serve(self.docker_api)
        self.assertEqual(self.r.http_unix(self.path, "/_ping"), (200, b"OK"))
        ok, ver, ms = self.probe()
        self.assertTrue(ok)
        self.assertEqual(ver, "28.5.1")
        self.assertLess(ms, 1000)

    def test_hung_server_times_out_as_failure(self):
        self.serve(lambda c, path: False)
        self.patch("PROBE_TIMEOUT", 0.5)
        t0 = time.time()
        ok, ver, _ = self.probe()
        self.assertFalse(ok)
        self.assertEqual(ver, "")
        self.assertLess(time.time() - t0, 3)

    def test_non_ok_ping_is_failure(self):
        self.serve(lambda c, path: c.sendall(
            b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 4\r\n\r\nboom") or True)
        self.assertFalse(self.probe()[0])

    def test_no_listener_is_failure(self):
        os.unlink(self.path)
        self.assertFalse(self.probe()[0])


if __name__ == "__main__":
    unittest.main()
