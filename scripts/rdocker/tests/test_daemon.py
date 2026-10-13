"""Daemon tests: monotonic scheduling, detached jobs + their locks, Docker Desktop idle-quit,
self-reload, events parsing. In-process with stubs (no docker/ssh/osascript/launchctl), except the
job-lock tests, which run `rdocker.py janitor-run|kick` against tests/fake_docker.py.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from test_janitor import JanitorCase
from test_shim_safety import RDOCKER, STAGE, ShimCase
from rdmods import r, MODULES

rd_common, rd_route, rd_daemon, rd_tunnel = (
    next(m for m in MODULES if m.__name__ == n)
    for n in ("rd_common", "rd_route", "rd_daemon", "rd_tunnel"))


class StopLoop(Exception):
    pass


class FakeTime:
    """Stands in for rd_daemon.time: sleep() advances both clocks; `jumps` steps the wall clock."""

    def __init__(self, max_sleeps, jumps=None):
        self.mono, self.wall, self.sleeps = 1000.0, 1.8e9, 0
        self.max_sleeps, self.jumps = max_sleeps, dict(jumps or {})

    def monotonic(self):
        return self.mono

    def time(self):
        return self.wall

    def sleep(self, s):
        self.sleeps += 1
        if self.sleeps > self.max_sleeps:
            raise StopLoop
        self.mono += s
        self.wall += s + self.jumps.pop(self.sleeps, 0)


class Schedule(unittest.TestCase):
    def test_due(self):
        self.assertTrue(r.due(None, 600, 5))
        self.assertFalse(r.due(100, 600, 699))
        self.assertTrue(r.due(100, 600, 700))

    def run_loop(self, jumps, max_sleeps=200):
        ft = FakeTime(max_sleeps, jumps)
        spawned = []
        cfg = rd_common.merge_cfg({"mode": "auto"})
        healthy = {"reachable": True, "docker_ok": True}
        with mock.patch.object(rd_daemon, "time", ft), \
                mock.patch.object(rd_common, "load_cfg", lambda: dict(cfg)), \
                mock.patch.object(rd_common, "log", lambda *a, **k: None), \
                mock.patch.object(rd_tunnel, "refresh_health", lambda c: healthy), \
                mock.patch.object(rd_tunnel, "resolve_target", lambda c: ("mini", "ok")), \
                mock.patch.object(rd_tunnel, "sync_forwards", lambda c, **k: (True, None)), \
                mock.patch.object(rd_daemon, "set_global_context", lambda c, t: None), \
                mock.patch.object(rd_daemon, "idle_step", lambda *a: False), \
                mock.patch.object(rd_daemon, "reload_step", lambda *a, **k: False), \
                mock.patch.object(rd_daemon, "reap_jobs", lambda j: None), \
                mock.patch.object(rd_daemon, "start_events", lambda c: None), \
                mock.patch.object(rd_daemon, "spawn_job",
                                  lambda name, jobs: spawned.append((name, ft.mono))):
            with self.assertRaises(StopLoop):
                rd_daemon.daemon()
        return [round(t - 1000) for n, t in spawned if n == "janitor-run"]

    def test_janitor_schedule_ignores_wall_clock_jumps(self):
        # 200 ticks of 15s = 3000s: janitor at +60, then every 600s.
        steady = self.run_loop({})
        self.assertEqual(steady, [60, 660, 1260, 1860, 2460])
        # wall clock jumps a day forward, then two days back: same schedule (no storm, no starve)
        jumped = self.run_loop({10: 86400, 50: -2 * 86400})
        self.assertEqual(jumped, steady)


class Jobs(unittest.TestCase):
    def test_spawn_argv_detached(self):
        jobs = {}
        with mock.patch.object(rd_daemon.subprocess, "Popen") as P:
            r.spawn_job("janitor-run", jobs)
        args, kw = P.call_args
        self.assertEqual(args[0], [sys.executable, "-I", r.ENTRY, "janitor-run"])
        self.assertTrue(kw["start_new_session"])
        for k in ("stdin", "stdout", "stderr"):
            self.assertEqual(kw[k], subprocess.DEVNULL)
        self.assertIn("janitor-run", jobs)

    def test_reap_removes_finished(self):
        done = subprocess.Popen(["/usr/bin/true"])
        done.wait()
        running = subprocess.Popen(["/bin/sleep", "5"])
        self.addCleanup(running.wait)
        self.addCleanup(running.kill)
        jobs = {"janitor-run": done, "kick": running}
        with mock.patch.object(rd_common, "log", lambda *a, **k: None):
            r.reap_jobs(jobs)
        self.assertEqual(list(jobs), ["kick"])


class JobLock(JanitorCase):
    def job(self, name):
        e = {k: v for k, v in os.environ.items() if not k.startswith("RDOCKER_")}
        e.update(HOME=self.home, PATH=self.bin + ":/usr/bin:/bin",
                 FAKE_DOCKER_FIXTURE=self.fixture, FAKE_DOCKER_LOG=self.log)
        return subprocess.run(["/usr/bin/python3", "-I", RDOCKER, name],
                              capture_output=True, text=True, env=e, timeout=60)

    def hold(self, lockname):
        fh = open(os.path.join(self.state, lockname), "a+")
        self.addCleanup(fh.close)
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_janitor_run_lock_held_exits_quietly(self):
        self.mini({})
        self.hold("janitor.lock")
        p = self.job("janitor-run")
        self.assertEqual((p.returncode, p.stdout, p.stderr), (0, "", ""))
        self.assertEqual(self.calls(), [])           # never touched docker

    def test_janitor_run_lock_free_runs(self):
        self.mini({})
        p = self.job("janitor-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.calls(), "janitor-run should have queried the mini")

    def test_kick_lock_held_exits_quietly(self):
        self.mini({})
        self.hold("kick.lock")
        with open(os.path.join(self.bin, "ssh"), "w") as f:
            f.write("#!/bin/sh\necho ran >> \"$HOME/ssh.ran\"\n")
        p = self.job("kick")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, "ssh.ran")))


class IdleQuit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-idle-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.markers = os.path.join(self.tmp, "local-active")
        self.last = os.path.join(self.tmp, "local-last")
        self.cfgpath = os.path.join(self.tmp, "config.json")
        for name, val in (("LOCAL_ACTIVE_DIR", self.markers), ("LOCAL_LAST_PATH", self.last),
                          ("CFG_PATH", self.cfgpath), ("LOG_PATH", os.path.join(self.tmp, "d.log"))):
            p = mock.patch.object(rd_common, name, val)
            p.start()
            self.addCleanup(p.stop)
        os.makedirs(self.markers)

    def marker(self, pid):
        open(os.path.join(self.markers, str(pid)), "w").close()

    def dead_pid(self):
        p = subprocess.Popen(["/usr/bin/true"])
        p.wait()
        return p.pid

    def test_live_marker_blocks(self):
        self.marker(os.getpid())
        self.assertEqual(r.live_local_markers(), 1)
        self.assertFalse(r.desktop_idle(False, r.live_local_markers(), None, 1e9, 900))

    def test_dead_marker_cleaned_and_not_blocking(self):
        pid = self.dead_pid()
        self.marker(pid)
        self.marker("garbage")
        self.assertEqual(r.live_local_markers(), 0)
        self.assertEqual(os.listdir(self.markers), [])
        self.assertTrue(r.desktop_idle(False, 0, None, 1e9, 900))

    def test_recent_local_route_blocks(self):
        open(self.last, "w").close()
        now = os.path.getmtime(self.last)
        self.assertFalse(r.desktop_idle(False, 0, r.last_local_route(), now + 60, 900))
        self.assertTrue(r.desktop_idle(False, 0, r.last_local_route(), now + 901, 900))
        self.assertFalse(r.desktop_idle(False, 0, now + 3600, now, 900))   # clock stepped back
        self.assertFalse(r.desktop_idle(True, 0, None, now, 900))         # running container

    def drive(self, ps_a=(0, "web\tproj\nsolo\t\n", "")):
        events = []

        def dk(ctx, *args, **kw):
            if args[:2] == ("ps", "-q"):
                return 0, "", ""
            if args[:2] == ("ps", "-a"):
                return ps_a
            raise AssertionError(args)

        def run(cmd, **kw):
            with open(self.cfgpath) as f:
                events.append(("quit", json.load(f).get("pins", {}).get("fallback", [])))
            return 0, "", ""
        cfg = rd_common.merge_cfg({})
        st = {"idle_since": None}
        with mock.patch.object(rd_tunnel, "local_engine_up", lambda c: True), \
                mock.patch.object(rd_common, "dk", dk), mock.patch.object(rd_common, "run", run):
            self.assertFalse(r.idle_step(cfg, "mini", st, 100.0, 2e9))     # idle starts
            self.assertFalse(r.idle_step(cfg, "mini", st, 100.0 + 899, 2e9))
            quit_ = r.idle_step(cfg, "mini", st, 100.0 + 901, 2e9)
        return quit_, events

    def test_pins_snapshot_written_before_quit(self):
        quit_, events = self.drive()
        self.assertTrue(quit_)
        self.assertEqual(len(events), 1)
        pinned = {(p["name"], p["kind"]) for p in events[0][1]}
        self.assertEqual(pinned, {("web", "container"), ("solo", "container"), ("proj", "compose")})

    def test_no_quit_when_snapshot_fails(self):
        with open(self.cfgpath, "w") as f:
            f.write("{}")
        quit_, events = self.drive(ps_a=(1, "", "boom"))
        self.assertFalse(quit_)
        self.assertEqual(events, [])

    def test_live_marker_prevents_quit(self):
        self.marker(os.getpid())
        quit_, events = self.drive()
        self.assertFalse(quit_)
        self.assertEqual(events, [])


class Reload(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-reload-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        for f in os.listdir(STAGE):
            if f == "rdocker.py" or (f.startswith("rd_") and f.endswith(".py")):
                shutil.copy(os.path.join(STAGE, f), self.tmp)
        self.logs = []
        for name, val in (("HERE", self.tmp), ("ENTRY", os.path.join(self.tmp, "rdocker.py")),
                          ("log", lambda m, *a, **k: self.logs.append(m))):
            p = mock.patch.object(rd_common, name, val)
            p.start()
            self.addCleanup(p.stop)

    def touch_module(self, text=None):
        path = os.path.join(self.tmp, "rd_route.py")
        if text is not None:
            with open(path, "a") as f:
                f.write(text)
        st = os.stat(path)
        os.utime(path, (st.st_atime, st.st_mtime + 10))

    def test_should_reload(self):
        self.assertFalse(r.should_reload({"a": 1}, {"a": 1}, True))
        self.assertFalse(r.should_reload({"a": 1}, {"a": 2}, False))
        self.assertTrue(r.should_reload({"a": 1}, {"a": 2}, True))

    def test_unchanged_no_import_check(self):
        st = {"mtimes": r.module_mtimes()}
        with mock.patch.object(rd_daemon, "import_check") as ic, mock.patch.object(os, "execv") as ex:
            self.assertFalse(r.reload_step(st))
        ic.assert_not_called()
        ex.assert_not_called()

    def test_broken_module_keeps_running_and_logs_once(self):
        st = {"mtimes": r.module_mtimes()}
        self.touch_module("\ndef broken(:\n")
        with mock.patch.object(os, "execv") as ex:
            self.assertFalse(r.reload_step(st))
            self.assertFalse(r.reload_step(st))      # same broken mtimes: no second log
        ex.assert_not_called()
        bad = [m for m in self.logs if "does not import" in m]
        self.assertEqual(len(bad), 1, self.logs)
        self.assertIn("SyntaxError", bad[0])

    def test_clean_change_execs(self):
        st = {"mtimes": r.module_mtimes()}
        self.touch_module("\n# harmless edit\n")
        stopped = []
        with mock.patch.object(os, "execv") as ex:
            r.reload_step(st, before_exec=lambda: stopped.append(1))
        ex.assert_called_once_with(sys.executable,
                                   [sys.executable, "-I", os.path.join(self.tmp, "rdocker.py"), "daemon"])
        self.assertEqual(stopped, [1])


class Events(unittest.TestCase):
    def test_parse(self):
        line = json.dumps({"Type": "container", "Action": "start",
                           "Actor": {"ID": "abc", "Attributes": {"name": "my db (test)"}}})
        self.assertEqual(r.parse_event(line), "start")
        self.assertEqual(r.parse_event(json.dumps({"status": "die", "id": "x"})), "die")
        self.assertEqual(r.parse_event('{"Action": "exec_start: sh -c ls"}'), "exec_start: sh -c ls")
        for bad in ("start", "{not json", "", "[1, 2]", '{"Action": 5}'):
            self.assertIsNone(r.parse_event(bad), bad)


class ShimMarksLocal(ShimCase):
    def test_local_route_writes_marker_and_last(self):
        self.scenario(cfg={"mode": "local"})
        p = self.shim("ps")
        self.assertEqual(p.returncode, 0, p.stderr)
        markers = os.listdir(os.path.join(self.state, "local-active"))
        self.assertEqual(len(markers), 1)
        self.assertTrue(markers[0].isdigit())
        self.assertTrue(os.path.exists(os.path.join(self.state, "local-last")))

    def test_mini_route_writes_no_marker(self):
        self.scenario()
        p = self.shim("ps")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.state, "local-active")))


if __name__ == "__main__":
    unittest.main()
