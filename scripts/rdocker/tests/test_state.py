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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402  (hermetic RDOCKER_HOME + fail-closed stubs)

STAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

PRELUDE = textwrap.dedent("""
    import json, os, sys, time
    sys.path.insert(0, %r)
    from rdmods import r
    import rd_tunnel
""" % os.path.dirname(os.path.abspath(__file__)))


class InHome(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="rdocker-test-")
        self.addCleanup(shutil.rmtree, self.home, True)

    def run_py(self, body):
        """Run PRELUDE + body as a script with self.home as its home; return its last stdout line as JSON."""
        script = os.path.join(self.home, "case.py")
        with open(script, "w") as f:
            f.write(PRELUDE + textwrap.dedent(body))
        env = rdmods.child_env(self.home)
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
            rd_tunnel.probe_health = fake_probe
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
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from rdmods import r
        self.r = r

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
        rd_tunnel.docker_probe = lambda cfg: (False, "", 4000.0)
        rd_tunnel.master_pid = lambda cfg: 4242
        rd_tunnel.tunnel_alive = lambda cfg: %s
        rd_tunnel.reset_master = lambda cfg: resets.append(1)
        h = r.probe_health(r.load_cfg())
        print(json.dumps({"resets": len(resets), "reachable": h["reachable"],
                          "docker_ok": h["docker_ok"], "failure": h["failure"]}))
    """

    def test_engine_down_keeps_master(self):
        out = self.run_py(self.BODY % "True")
        self.assertEqual(out, {"resets": 0, "reachable": True, "docker_ok": False,
                               "failure": "engine"})

    def test_stale_tunnel_resets_and_retries(self):
        out = self.run_py(self.BODY % "False")
        self.assertEqual(out, {"resets": 1, "reachable": True, "docker_ok": False,
                               "failure": "tunnel"})


class RawSocketProbe(unittest.TestCase):
    """http_unix / docker_probe against a fake docker API on a unix socket in a temp dir."""

    def setUp(self):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from rdmods import r
        self.r = r
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
        from rdmods import owner
        mod = owner(name)          # the module that reads it; r itself refuses assignment
        self.addCleanup(setattr, mod, name, getattr(mod, name))
        setattr(mod, name, value)

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


class RouteLogRotation(InHome):
    """route.log is written by many shim processes: rotation + append run under one flock, so the
    single rotation in this run loses and duplicates nothing and no line is torn."""

    def test_eight_writers_one_rotation_nothing_lost(self):
        out = self.run_py("""
            import multiprocessing as mp, re
            import rd_common
            rd_common.LOG_MAX = 60000          # 8 x 150 lines x ~75 B = ~90 KB -> exactly one rotation

            def write(i):
                for n in range(150):
                    rd_common.log("worker %d line %04d %s" % (i, n, "x" * 30), rd_common.ROUTE_LOG)

            if __name__ == "__main__":
                r.ensure_dirs()
                procs = [mp.Process(target=write, args=(i,)) for i in range(8)]
                for p in procs:
                    p.start()
                for p in procs:
                    p.join()
                lines = []
                for path in (r.ROUTE_LOG + ".1", r.ROUTE_LOG):
                    with open(path) as f:
                        lines += f.read().splitlines()
                pat = re.compile(r"^\\d{4}-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d worker \\d line \\d{4} x{30}$")
                print(json.dumps({"codes": [p.exitcode for p in procs], "n": len(lines),
                                  "unique": len(set(l[20:] for l in lines)),
                                  "torn": [l for l in lines if not pat.match(l)][:3],
                                  "cur": os.path.getsize(r.ROUTE_LOG),
                                  "old": os.path.getsize(r.ROUTE_LOG + ".1")}))
        """)
        self.assertEqual(out["codes"], [0] * 8)
        self.assertEqual(out["torn"], [])
        self.assertEqual((out["n"], out["unique"]), (1200, 1200))
        self.assertGreater(out["old"], 60000)
        self.assertLess(out["cur"], 60000)


# ---------------------------------------------------------------------------- CLI (in-process)

from unittest import mock  # noqa: E402
import contextlib  # noqa: E402
import io  # noqa: E402

from rdmods import MODULES  # noqa: E402

rd_common, rd_route, rd_daemon, rd_tunnel, rd_janitor, rd_setup = (
    next(m for m in MODULES if m.__name__ == n)
    for n in ("rd_common", "rd_route", "rd_daemon", "rd_tunnel", "rd_janitor", "rd_setup"))


class CliParsing(unittest.TestCase):
    def ns(self, *argv):
        ns, rc = rd_setup.parse_args(list(argv))
        self.assertIsNone(rc, argv)
        return ns

    def test_every_subcommand(self):
        self.assertEqual((self.ns().cmd, self.ns().fix), ("status", False))
        self.assertTrue(self.ns("status", "--fix").fix)
        self.assertEqual(self.ns("doctor").cmd, "doctor")
        for m in ("auto", "mini", "local", "off"):
            self.assertEqual(self.ns("use", m).mode, m)
        self.assertEqual(self.ns("where", "db").name, "db")
        n = self.ns("pin", "proj", "--compose")
        self.assertEqual((n.cmd, n.name, n.compose), ("pin", "proj", True))
        self.assertEqual(self.ns("unpin", "db").name, "db")
        n = self.ns("sync", "--repeat", "6", "--interval", "0.5")
        self.assertEqual((n.repeat, n.interval), (6, 0.5))
        self.assertEqual((self.ns("sync").repeat, self.ns("sync").interval), (1, 1.5))
        self.assertTrue(self.ns("logs", "--route").route)
        n = self.ns("clean", "--only", "e2e-", "--force-critical", "--exited_rm_hours", "0", "--dry-run")
        self.assertEqual((n.only, n.force_critical, n.exited_rm_hours, n.dry_run, n.idle_stop_hours),
                         ("e2e-", True, 0.0, True, None))
        self.assertEqual(self.ns("install").cmd, "install")
        n = self.ns("setup-mini")
        self.assertEqual((n.cpu, n.mem, n.disk), ("6", "8", "30"))
        n = self.ns("setup-mini", "4", "12")
        self.assertEqual((n.cpu, n.mem, n.disk), ("4", "12", "30"))
        self.assertEqual(self.ns("daemon").cmd, "daemon")
        self.assertEqual(self.ns("janitor-run").cmd, "janitor-run")
        self.assertTrue(self.ns("kick", "--restart-ok").restart_ok)

    def test_bad_usage_is_2_and_help_is_0(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            for argv in (["bogus"], ["use"], ["use", "sideways"], ["where"], ["sync", "--repeat", "x"]):
                self.assertEqual(rd_setup.command(argv), 2, argv)
        self.assertIn("usage: rdocker", err.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(rd_setup.command(["status", "--help"]), 0)
        self.assertIn("--fix", out.getvalue())

    def test_help_hides_internal_jobs(self):
        text = rd_setup.build_parser().format_help()
        self.assertIn("setup-mini", text)
        self.assertNotIn("janitor-run", text)
        self.assertNotIn("kick", text)


class CliDispatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-cli-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cfg = rd_common.merge_cfg({})
        for target, name, val in (
                (rd_common, "HEALTH_PATH", os.path.join(self.tmp, "health.json")),
                (rd_common, "load_cfg", lambda: dict(self.cfg)),
                (rd_common, "update_cfg", self.update_cfg)):
            p = mock.patch.object(target, name, val)
            p.start()
            self.addCleanup(p.stop)

    def update_cfg(self, fn):
        self.cfg = fn(self.cfg)
        return self.cfg

    def cmd(self, *argv):
        with contextlib.redirect_stdout(io.StringIO()):
            return rd_setup.command(list(argv))

    def test_use_off_points_global_context_at_laptop(self):
        open(rd_common.HEALTH_PATH, "w").close()
        with mock.patch.object(rd_daemon, "set_global_context") as sgc, \
                mock.patch.object(rd_tunnel, "resolve_target") as rt:
            self.assertEqual(self.cmd("use", "off"), 0)
        self.assertEqual(self.cfg["mode"], "off")
        sgc.assert_called_once_with(self.cfg, "local")
        rt.assert_not_called()
        self.assertFalse(os.path.exists(rd_common.HEALTH_PATH))

    def test_use_auto_follows_resolved_target(self):
        with mock.patch.object(rd_daemon, "set_global_context") as sgc, \
                mock.patch.object(rd_tunnel, "resolve_target", return_value=("mini", "ok")):
            self.assertEqual(self.cmd("use", "auto"), 0)
        sgc.assert_called_once_with(self.cfg, "mini")

    def test_clean_threshold_override(self):
        with mock.patch.object(rd_janitor, "janitor", return_value=["rm x"]) as j:
            self.assertEqual(self.cmd("clean", "--only", "e2e-", "--force-critical",
                                      "--exited_rm_hours", "0"), 0)
        cfg = j.call_args[0][0]
        self.assertEqual(cfg["exited_rm_hours"], 0.0)
        self.assertEqual(cfg["idle_stop_hours"], self.cfg["idle_stop_hours"])
        self.assertEqual(j.call_args[1], {"dry": False, "only": "e2e-", "force_critical": True,
                                          "lock_wait": rd_janitor.CLEAN_LOCK_WAIT})

    def test_pin_unpin(self):
        self.cmd("pin", "proj", "--compose")
        self.cmd("pin", "db")
        self.assertEqual((self.cfg["pins"]["compose_projects"], self.cfg["pins"]["containers"]),
                         (["proj"], ["db"]))
        self.cmd("unpin", "proj")
        self.assertEqual(self.cfg["pins"]["compose_projects"], [])

    def test_jobs_setup_sync(self):
        with mock.patch.object(rd_setup, "run_job", return_value=0) as rj:
            self.cmd("kick", "--restart-ok")
            self.cmd("janitor-run")
        self.assertEqual([c[0][2] for c in rj.call_args_list], [["--restart-ok"], []])
        with mock.patch.object(rd_setup, "setup_mini", return_value=0) as sm:
            self.cmd("setup-mini", "4")
        self.assertEqual(sm.call_args[0][1:], ("4", "8", "30"))
        with mock.patch.object(rd_tunnel, "sync_forwards", return_value=(False, [1], [])) as sf:
            self.assertEqual(self.cmd("sync", "--repeat", "2", "--interval", "0"), 1)
        self.assertEqual(sf.call_count, 2)


class MergedPs(unittest.TestCase):
    LOCAL = "CONTAINER ID   IMAGE   NAMES\nabc123   redis   cache\n"

    def run_ps(self, args, rc1=0, rc2=0, out=LOCAL):
        with mock.patch.object(rd_route, "call_docker", return_value=rc1) as cd, \
                mock.patch.object(rd_common, "real_docker", return_value="/x/docker"), \
                mock.patch.object(rd_common, "run", return_value=(rc2, out, "daemon boom\n")) as run, \
                mock.patch.object(rd_common, "say") as say, \
                contextlib.redirect_stdout(io.StringIO()) as so:
            rc = rd_route.merged_ps(rd_common.merge_cfg({}), ["/x/docker", "--context", "mini"], [],
                                    ["ps"] + args, args)
        self.assertEqual(cd.call_args[0][0], ["/x/docker", "--context", "mini", "ps"] + args)
        self.assertEqual(run.call_args[0][0], ["/x/docker", "--context", "desktop-linux", "ps"] + args)
        return rc, so.getvalue(), [c[0][0] for c in say.call_args_list]

    def test_table_header_printed_once(self):
        rc, out, said = self.run_ps(["-a"])
        self.assertEqual((rc, out, said), (0, "abc123   redis   cache\n", []))
        self.assertEqual(self.run_ps(["--format", "table {{.Names}}"])[1], "abc123   redis   cache\n")

    def test_non_table_output_kept_whole(self):
        for args in (["-q"], ["-aq"], ["--quiet"], ["--format", "{{.Names}}"], ["--format=json"],
                     ["--format", "json"]):
            self.assertEqual(self.run_ps(args)[1], self.LOCAL, args)

    def test_rc_from_either_engine(self):
        rc, out, said = self.run_ps(["-a"], rc2=1, out="")
        self.assertEqual(rc, 1)
        self.assertIn("laptop engine failed (rc=1): daemon boom", " ".join(said).replace("ps on the ", ""))
        rc, out, said = self.run_ps(["-a"], rc1=125)
        self.assertEqual(rc, 125)
        self.assertIn("mini failed", said[0])

    def test_ps_tabular(self):
        self.assertTrue(rd_route.ps_tabular(["-a", "-f", "name=q", "-n", "3"]))
        self.assertFalse(rd_route.ps_tabular(["-qa"]))


class StatusRows(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-st-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        for name in ("DAEMON_PATH", "JANITOR_PATH"):
            p = mock.patch.object(rd_common, name, os.path.join(self.tmp, name.lower()))
            p.start()
            self.addCleanup(p.stop)

    def write(self, path, data):
        with open(path, "w") as f:
            json.dump(data, f)

    def test_daemon_code_vs_running(self):
        now = 10_000.0
        self.assertFalse(rd_setup.daemon_rows(now)[0][0])                     # no daemon.json
        self.write(rd_common.DAEMON_PATH, {"pid": os.getpid(), "started": now - 60, "code_mtime": 500})
        with mock.patch.object(rd_daemon, "module_mtimes", return_value={"a": 400, "b": 500}):
            ok, _, detail = rd_setup.daemon_rows(now)[0]
        self.assertTrue(ok)
        self.assertIn("pid %d, started 1m ago, running the code on disk" % os.getpid(), detail)
        with mock.patch.object(rd_daemon, "module_mtimes", return_value={"a": now - 5}):
            ok, _, detail = rd_setup.daemon_rows(now)[0]
        self.assertTrue(ok)
        self.assertIn("reload pending", detail)
        with mock.patch.object(rd_daemon, "module_mtimes", return_value={"a": now - 600}):
            ok, _, detail = rd_setup.daemon_rows(now)[0]
        self.assertFalse(ok)
        self.assertIn("NOT picked up", detail)
        with mock.patch.object(rd_daemon, "pid_alive", return_value=False):
            self.assertFalse(rd_setup.daemon_rows(now)[0][0])

    def test_janitor_health_fallback(self):
        now = 100_000.0
        cfg = rd_common.merge_cfg({"pins": {"fallback": [{"name": "db", "kind": "container", "ts": 1}]}})
        self.assertEqual(rd_setup.janitor_rows(cfg, now), [(True, "janitor last run", "never")])
        self.write(rd_common.JANITOR_PATH, {
            "last_run": now - 120, "vm_disk_pct": 41, "mini_free_gb": 80,
            "last_error": {"ts": now - 300, "action": "prune dangling images", "err": "boom"}})
        rows = {label: (ok, d) for ok, label, d in rd_setup.janitor_rows(cfg, now)}
        self.assertEqual(rows["janitor last run"], (True, "2m ago"))
        self.assertEqual(rows["janitor last error"], (False, "5m ago: prune dangling images: boom"))
        self.assertEqual(rows["mini disk"], (True, "VM 41% used, mini 80 GB free"))
        self.write(rd_common.JANITOR_PATH, {"last_error": {"ts": now - 86400, "action": "a", "err": "e"}})
        self.assertTrue(rd_setup.janitor_rows(cfg, now)[1][0])                 # old error: informational
        self.assertEqual(rd_setup.fallback_pins_row(cfg)[2], "db (container)")
        self.assertIn("12s old", rd_setup.health_age_row({"ts": now - 12}, now)[2])
        self.assertIn("none on file", rd_setup.health_age_row(None, now)[2])


class Attention(unittest.TestCase):
    """attention.json: set/clear by key, `since` kept; WARN rows; the shim's hourly stderr notice."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-att-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        for name in ("ATTENTION_PATH", "ATTENTION_SHOWN_PATH"):
            p = mock.patch.object(rd_common, name, os.path.join(self.tmp, name.lower()))
            p.start()
            self.addCleanup(p.stop)

    def test_set_dedups_keeps_since_and_clear_resolves(self):
        rd_common.attention_set("engine", "down", now=100)
        rd_common.attention_set("engine", "still down", now=200)
        rd_common.attention_set("flag-drift", "new flags", now=300)
        items = rd_common.attention_items()
        self.assertEqual([(i["key"], i["msg"], i["since"]) for i in items],
                         [("engine", "still down", 100), ("flag-drift", "new flags", 300)])
        rd_common.attention_clear("engine", "nope")
        self.assertEqual([i["key"] for i in rd_common.attention_items()], ["flag-drift"])

    def test_status_rows_are_warn_and_never_faults(self):
        rd_common.attention_set("restart-pending", "config pending for 30h", now=1000)
        rows = rd_setup.attention_rows(1000 + 7200)
        self.assertEqual(rows, ["WARN config pending for 30h (since 2h ago)"])
        self.assertFalse(any(row.startswith("-- ") for row in rows))

    def test_notify_once_per_hour_per_item_on_stderr(self):
        rd_common.attention_set("a", "first thing", now=0)
        with mock.patch.object(rd_common, "say") as say:
            self.assertEqual(rd_common.attention_notify(now=1000), ["first thing"])
            self.assertEqual(rd_common.attention_notify(now=1000 + 3599), [])
            rd_common.attention_set("b", "second thing", now=2000)
            self.assertEqual(rd_common.attention_notify(now=2100), ["second thing"])
            self.assertEqual(rd_common.attention_notify(now=1000 + 3600), ["first thing"])
        self.assertEqual(say.call_args_list[0][0][0],
                         "needs attention: first thing (run rdocker status)")

    def test_notify_never_raises(self):
        with open(rd_common.ATTENTION_PATH, "w") as f:
            f.write('[{"key": "k", "msg": "m"}]')
        with mock.patch.object(rd_common, "update_state", side_effect=RuntimeError("boom")), \
                mock.patch.object(rd_common, "log"):
            self.assertEqual(rd_common.attention_notify(now=5), [])


if __name__ == "__main__":
    unittest.main()
