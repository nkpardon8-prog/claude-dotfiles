"""Mini engine tests: the mini lock, engine recovery (kick), apply_when_idle, setup-mini config edit.

No ssh: rd_janitor.mini_sh is replaced by a runner that feeds the generated POSIX sh scripts to the
LOCAL /bin/sh with HOME = a temp dir ("the mini") and PATH = a temp bin holding fake `colima` and
`docker` stubs (BREW_PATH is patched to that bin, so /opt/homebrew is never on PATH). The real
lock / kick / restart / config-edit shell logic runs; only colima and docker are fakes.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock

import rdmods
from rdmods import MODULES

rd_common, rd_janitor, rd_daemon, rd_setup = (
    next(m for m in MODULES if m.__name__ == n)
    for n in ("rd_common", "rd_janitor", "rd_daemon", "rd_setup"))

# Fakes on the temp PATH. colima: `status` exits with $HOME/colima.status (default 0); start and
# restart bring the VM "up" (status 0). launchctl: `print` succeeds only if $HOME/launchd.loaded
# exists (agent loaded in the GUI domain); kickstart brings the VM up. Every non-status colima /
# launchctl action is logged to $HOME/engine.log, with "locked" if the mini lock dir existed then.
COLIMA = """#!/bin/sh
case "$1" in
  status) exit $(cat "$HOME/colima.status" 2>/dev/null || echo 0) ;;
esac
echo "colima $*" >> "$HOME/engine.log"
[ -d "$HOME/.rdocker/janitor.lock" ] && echo locked >> "$HOME/engine.log"
[ -f "$HOME/stays.down" ] || { echo 0 > "$HOME/colima.status"; rm -f "$HOME/docker.info"; }
exit 0
"""
LAUNCHCTL = """#!/bin/sh
case "$1" in
  print) [ -f "$HOME/launchd.loaded" ]; exit $? ;;
esac
shift
echo "kickstart $*" | sed "s/[0-9][0-9]*/UID/" >> "$HOME/engine.log"
[ -d "$HOME/.rdocker/janitor.lock" ] && echo locked >> "$HOME/engine.log"
[ -f "$HOME/stays.down" ] || { echo 0 > "$HOME/colima.status"; rm -f "$HOME/docker.info"; }
exit 0
"""
# docker: `info` per $HOME/docker.info (absent = answers; "fail" = exit 1; "hang" = never returns),
# `ps` per $HOME/docker.ps (listed ids) and $HOME/docker.ps.mode ("fail" / "hang"). A colima or
# launchctl restart/start removes docker.info (the engine is back).
DOCKER = """#!/bin/sh
case "$1" in
  info) case "$(cat "$HOME/docker.info" 2>/dev/null)" in
          fail) exit 1 ;; hang) exec sleep 30 ;; esac ;;
  ps) case "$(cat "$HOME/docker.ps.mode" 2>/dev/null)" in
        fail) exit 1 ;; hang) exec sleep 30 ;; esac
      cat "$HOME/docker.ps" 2>/dev/null ;;
esac
exit 0
"""


class MiniCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-eng-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.mhome = os.path.join(self.tmp, "mini")
        self.bin = os.path.join(self.tmp, "bin")
        self.state = os.path.join(self.tmp, "state")
        for d in (self.mhome, self.bin, self.state):
            os.makedirs(d)
        for name, body in (("colima", COLIMA), ("docker", DOCKER), ("launchctl", LAUNCHCTL)):
            path = os.path.join(self.bin, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)
        self.logs = []
        self.ssh_calls = 0
        for mod, name, val in (
                (rd_janitor, "BREW_PATH", self.bin),
                (rd_janitor, "mini_sh", self.mini_sh),
                (rd_common, "JANITOR_PATH", os.path.join(self.state, "janitor.json")),
                (rd_common, "ATTENTION_PATH", os.path.join(self.state, "attention.json")),
                (rd_common, "ATTENTION_SHOWN_PATH", os.path.join(self.state, "shown.json")),
                (rd_common, "log", lambda msg, **k: self.logs.append(msg))):
            p = mock.patch.object(mod, name, val)
            p.start()
            self.addCleanup(p.stop)
        self.cfg = rd_common.merge_cfg({})

    def mini_sh(self, cfg, script, timeout=60):
        self.ssh_calls += 1
        env = {"HOME": self.mhome, "PATH": rdmods.safe_path(self.bin)}   # mini side: no RDOCKER_*
        p = subprocess.run(["/bin/sh", "-s"], input=script, capture_output=True, text=True,
                           env=env, timeout=timeout)
        return p.returncode, p.stdout, p.stderr

    def runner(self, script):
        return self.mini_sh(self.cfg, script)

    # --- the fake mini
    @property
    def lockdir(self):
        return os.path.join(self.mhome, ".rdocker", "janitor.lock")

    def set_owner(self, owner, age):
        os.makedirs(self.lockdir, exist_ok=True)
        with open(os.path.join(self.lockdir, "owner"), "w") as f:
            f.write("%s %d\n" % (owner, int(time.time()) - age))

    def owner(self):
        with open(os.path.join(self.lockdir, "owner")) as f:
            return f.read().split()

    def colima(self):
        try:
            with open(os.path.join(self.mhome, "engine.log")) as f:
                return f.read().splitlines()
        except OSError:
            return []

    def mini_file(self, rel, text):
        path = os.path.join(self.mhome, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        return path

    def jstate(self):
        return rd_common.load_json(rd_common.JANITOR_PATH, {})

    def attention(self):
        return {i["key"]: i["msg"] for i in rd_common.attention_items()}


class Lock(MiniCase):
    def lock(self, clock=None):
        return rd_janitor.MiniLock(self.cfg, "test", runner=self.runner, clock=clock)

    def test_acquire_free_then_release(self):
        lk = self.lock().acquire()
        me, ts = self.owner()
        self.assertEqual(me, lk.me)
        self.assertLessEqual(abs(int(ts) - time.time()), 5)
        lk.release()
        self.assertFalse(os.path.exists(self.lockdir))

    def test_fresh_lock_held_elsewhere_is_busy(self):
        self.set_owner("otherhost:99", age=300)
        with self.assertRaises(rd_janitor.MiniLockBusy) as e:
            self.lock().acquire()
        self.assertIn("otherhost:99", str(e.exception))
        self.assertEqual(self.owner()[0], "otherhost:99")

    def test_dir_without_owner_file_ages_by_mtime(self):
        os.makedirs(self.lockdir)            # owner between mkdir and write: fresh, not stealable
        with self.assertRaises(rd_janitor.MiniLockBusy):
            self.lock().acquire()

    def test_stale_lock_is_stolen(self):
        self.set_owner("otherhost:99", age=rd_janitor.MINI_LOCK_STALE + 100)
        lk = self.lock().acquire()
        self.assertEqual(self.owner()[0], lk.me)
        self.assertTrue(any("stale" in m for m in self.logs))

    def test_release_only_if_still_ours(self):
        lk = self.lock().acquire()
        self.set_owner("thief:1", age=0)
        lk.release()
        self.assertEqual(self.owner()[0], "thief:1")

    def test_heartbeat_refreshes_throttled_and_detects_loss(self):
        now = [100.0]
        lk = self.lock(clock=lambda: now[0]).acquire()
        calls = self.ssh_calls
        self.set_owner(lk.me, age=500)
        lk.heartbeat()                       # within HEARTBEAT_EVERY: no round-trip
        self.assertEqual(self.ssh_calls, calls)
        now[0] += rd_janitor.HEARTBEAT_EVERY
        lk.heartbeat()
        self.assertLessEqual(abs(int(self.owner()[1]) - time.time()), 5)
        self.set_owner("thief:1", age=0)
        with self.assertRaises(rd_janitor.MiniLockLost):
            lk.heartbeat(force=True)

    def test_unreachable_mini_is_busy_not_held(self):
        lk = rd_janitor.MiniLock(self.cfg, "t", runner=lambda s: (255, "", "ssh: no route"))
        with self.assertRaises(rd_janitor.MiniLockBusy) as e:
            lk.acquire()
        self.assertIn("unreachable", str(e.exception))
        self.assertFalse(lk.held)

    def test_acquire_waits_for_lock_to_free(self):
        self.set_owner("otherhost:99", age=10)
        now, slept = [0.0], []

        def sleep(s):
            slept.append(s)
            now[0] += s
            if len(slept) == 2:              # the daemon's janitor finishes meanwhile
                shutil.rmtree(self.lockdir)

        lk = rd_janitor.MiniLock(self.cfg, "t", runner=self.runner, clock=lambda: now[0],
                                 sleep=sleep).acquire(wait=rd_janitor.CLEAN_LOCK_WAIT)
        self.assertEqual(self.owner()[0], lk.me)
        self.assertEqual(slept, [rd_janitor.LOCK_POLL] * 2)

    def test_acquire_wait_gives_up_after_deadline(self):
        self.set_owner("otherhost:99", age=10)
        now, slept = [0.0], []

        def sleep(s):
            slept.append(s)
            now[0] += s

        lk = rd_janitor.MiniLock(self.cfg, "t", runner=self.runner, clock=lambda: now[0], sleep=sleep)
        with self.assertRaises(rd_janitor.MiniLockBusy):
            lk.acquire(wait=90)
        self.assertEqual(sum(slept), 90)
        self.assertEqual(self.owner()[0], "otherhost:99")

    def test_manual_clean_waits_then_raises(self):
        self.set_owner("otherhost:99", age=10)
        with mock.patch.object(rd_janitor, "LOCK_POLL", 0.05), \
                mock.patch.object(rd_janitor, "janitor_pass") as jp:
            t0 = time.monotonic()
            with self.assertRaises(rd_janitor.MiniLockBusy):
                rd_janitor.janitor(self.cfg, lock_wait=0.3)
            self.assertGreaterEqual(time.monotonic() - t0, 0.25)
        jp.assert_not_called()

    def test_janitor_skips_when_lock_held(self):
        self.set_owner("otherhost:99", age=10)
        with mock.patch.object(rd_janitor, "janitor_pass") as jp:
            acts = rd_janitor.janitor(self.cfg)
        jp.assert_not_called()
        self.assertTrue(acts[0].startswith("skipped: mini lock held by otherhost:99"))

    def test_janitor_holds_lock_and_releases(self):
        seen = []
        with mock.patch.object(rd_janitor, "janitor_pass",
                               lambda J, only, fc: seen.append(os.path.isdir(self.lockdir)) or []):
            rd_janitor.janitor(self.cfg)
        self.assertEqual(seen, [True])
        self.assertFalse(os.path.exists(self.lockdir))


class Kick(MiniCase):
    PROFILE = ".colima/default/colima.yaml"
    KS = "kickstart gui/UID/sh.brew.colima"

    def vm(self, up, launchd=False, engine_dead=False):
        self.mini_file("colima.status", "0" if up else "1")
        if launchd:
            self.mini_file("launchd.loaded", "")
        if engine_dead:
            self.mini_file("docker.info", "fail")

    def test_vm_down_without_profile_does_not_start(self):
        self.vm(False, launchd=True)
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg), "no-profile")
        self.assertEqual(self.colima(), [])
        self.assertTrue(any("setup-mini" in m for m in self.logs))

    def test_vm_down_agent_loaded_kickstarts_launchd(self):
        self.vm(False, launchd=True)
        self.mini_file(self.PROFILE, "cpu: 6\n")
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg), "started")
        self.assertEqual(self.colima(), [self.KS])
        self.assertTrue(any("via launchd" in m for m in self.logs))

    def test_vm_down_no_gui_session_falls_back_to_colima_start(self):
        self.vm(False)
        self.mini_file(self.PROFILE, "cpu: 6\n")
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg), "started")
        self.assertEqual(self.colima(), ["colima start"])
        self.assertTrue(any("via colima" in m for m in self.logs))

    def test_start_that_never_comes_up_reports_failure(self):
        self.vm(False, launchd=True)
        self.mini_file(self.PROFILE, "cpu: 6\n")
        self.mini_file("stays.down", "")
        with mock.patch.object(rd_janitor, "ENGINE_WAIT_S", 2):    # one bounded wait round
            self.assertEqual(rd_janitor.mini_engine_kick(self.cfg), "start-failed")
        self.assertTrue(any("FAILED: start-failed launchd" in m for m in self.logs))

    def test_vm_up_first_failure_does_not_restart(self):
        self.vm(True, launchd=True)
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=False), "vm-up")
        self.assertEqual(self.colima(), [])

    def test_vm_up_restart_via_launchd_under_lock_then_rate_limited(self):
        self.vm(True, launchd=True, engine_dead=True)
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=True), "ok")
        self.assertEqual(self.colima(), ["kickstart -k gui/UID/sh.brew.colima", "locked"])
        self.assertFalse(os.path.exists(self.lockdir))          # released
        self.assertNotIn("engine", self.attention())
        last = self.jstate()["last_engine_restart"]
        self.mini_file("docker.info", "fail")
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=True), "rate-limited")
        self.assertEqual(len(self.colima()), 2)
        self.assertIn("rate-limited", self.attention()["engine"])
        with mock.patch.object(rd_janitor.time, "time", lambda: last + rd_janitor.RESTART_MIN_GAP):
            self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=True), "ok")
        self.assertEqual(len(self.colima()), 4)
        self.assertNotIn("engine", self.attention())

    def test_vm_up_restart_without_gui_session_uses_colima_restart(self):
        self.vm(True, engine_dead=True)
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=True), "ok")
        self.assertEqual(self.colima(), ["colima restart", "locked"])

    def test_slow_tunnel_engine_answering_on_mini_is_not_restarted(self):
        self.vm(True, launchd=True)                   # docker info answers on the mini itself
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=True), "engine-ok")
        self.assertEqual(self.colima(), [])
        self.assertNotIn("last_engine_restart", self.jstate())   # no 30-min clock burned
        self.assertFalse(os.path.exists(self.lockdir))
        self.assertIn("not restarted", self.attention()["engine"])

    def test_running_containers_listed_block_restart(self):
        self.vm(True, launchd=True, engine_dead=True)
        self.mini_file("docker.ps", "abc123\ndef456\n")
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=True), "busy")
        self.assertEqual(self.colima(), [])
        self.assertNotIn("last_engine_restart", self.jstate())
        self.assertIn("2 container(s) run there", self.attention()["engine"])

    def test_dead_engine_whose_ps_fails_or_hangs_is_restarted(self):
        for mode in ("fail", "hang"):
            self.setUp()
            self.vm(True, launchd=True)
            self.mini_file("docker.info", "hang")      # info times out on the mini too
            self.mini_file("docker.ps", "abc123\n")    # never seen: ps itself fails / hangs
            self.mini_file("docker.ps.mode", mode)
            with mock.patch.object(rd_janitor, "ENGINE_CHECK_TIMEOUT", 1):
                self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=True), "ok", mode)
            self.assertEqual(self.colima(), ["kickstart -k gui/UID/sh.brew.colima", "locked"])

    def test_vm_down_problems_raise_attention_and_start_clears_it(self):
        self.vm(False, launchd=True)
        rd_janitor.mini_engine_kick(self.cfg)
        self.assertIn("setup-mini", self.attention()["engine"])
        self.mini_file(self.PROFILE, "cpu: 6\n")
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg), "started")
        self.assertEqual(self.attention(), {})

    def test_restart_deferred_when_lock_held(self):
        self.vm(True, launchd=True, engine_dead=True)
        self.set_owner("otherhost:99", age=5)
        self.assertEqual(rd_janitor.mini_engine_kick(self.cfg, restart_ok=True), "lock-busy")
        self.assertEqual(self.colima(), [])
        self.assertNotIn("last_engine_restart", self.jstate())


class DaemonCounting(unittest.TestCase):
    ENGINE = {"reachable": True, "docker_ok": False, "failure": "engine"}
    TUNNEL = {"reachable": True, "docker_ok": False, "failure": "tunnel"}
    OK = {"reachable": True, "docker_ok": True, "failure": None}

    def test_failure_run_is_continuous_engine_failures_only(self):
        since, seen = None, []
        for t, h in enumerate((self.ENGINE, self.ENGINE, self.TUNNEL, self.ENGINE, self.OK,
                               self.ENGINE)):
            since = rd_daemon.engine_fail_since(since, h, t * 15)
            seen.append(since)
        self.assertEqual(seen, [0, 0, None, 45, None, 75])

    def test_kick_args(self):
        every, after = rd_daemon.ENGINE_KICK_EVERY, rd_janitor.ENGINE_RESTART_AFTER_S
        self.assertEqual(after, 600)
        self.assertEqual(rd_daemon.kick_args(0, None, 0), [])               # first failure: start only
        self.assertIsNone(rd_daemon.kick_args(0, 0, 60))                    # 2 failures in 1 min: nothing
        self.assertIsNone(rd_daemon.kick_args(0, 0, after - 15))            # 9m45s: not yet
        self.assertEqual(rd_daemon.kick_args(0, 0, after), ["--restart-ok"])     # 10 min continuous
        self.assertIsNone(rd_daemon.kick_args(0, after, after + 15))             # then the cadence
        self.assertEqual(rd_daemon.kick_args(0, after, after + every), ["--restart-ok"])
        self.assertEqual(rd_daemon.kick_args(500, 0, every), [])            # run only 100 s old

    def test_loop_spawns_restart_ok_only_after_ten_minutes_of_failures(self):
        from test_daemon import FakeTime, StopLoop

        def run(healths):
            ft = FakeTime(len(healths) - 1)
            seq = iter(healths)
            spawned = []
            cfg = rd_common.merge_cfg({"mode": "auto"})
            with mock.patch.object(rd_daemon, "time", ft), \
                    mock.patch.object(rd_common, "load_cfg", lambda: dict(cfg)), \
                    mock.patch.object(rd_common, "log", lambda *a, **k: None), \
                    mock.patch.object(rd_daemon.rd_tunnel, "refresh_health", lambda c, **k: next(seq)), \
                    mock.patch.object(rd_daemon.rd_tunnel, "resolve_target", lambda c: ("local", "")), \
                    mock.patch.object(rd_daemon, "set_global_context", lambda c, t: None), \
                    mock.patch.object(rd_daemon, "idle_step", lambda *a: False), \
                    mock.patch.object(rd_daemon, "reload_step", lambda *a, **k: False), \
                    mock.patch.object(rd_daemon, "reap_jobs", lambda j: None), \
                    mock.patch.object(rd_daemon, "tailscale_up", lambda: False), \
                    mock.patch.object(rd_daemon, "flag_drift_check", lambda: []), \
                    mock.patch.object(rd_daemon, "spawn_job",
                                      lambda name, jobs, extra=(): spawned.append((name, list(extra)))):
                with self.assertRaises(StopLoop):
                    rd_daemon.daemon()
            return [e for n, e in spawned if n == "kick"]

        ticks = rd_janitor.ENGINE_RESTART_AFTER_S // rd_common.PERIODIC     # 40 ticks of 15 s
        self.assertEqual(run([self.ENGINE] * 3), [[]])                      # 30 s: start-only kick
        self.assertEqual(run([self.ENGINE] * ticks), [[]])                  # 9m45s: still no restart
        self.assertEqual(run([self.ENGINE] * (ticks + 1)), [[], ["--restart-ok"]])
        # one success inside the window resets the clock
        self.assertEqual(run([self.ENGINE] * 20 + [self.OK] + [self.ENGINE] * 30), [[], []])
        self.assertEqual(run([self.ENGINE, self.TUNNEL, self.ENGINE, self.TUNNEL]), [[]])


class ApplyWhenIdle(MiniCase):
    def setUp(self):
        super().setUp()
        self.local_ps = (0, "", "")
        p = mock.patch.object(rd_common, "dk", lambda ctx, *a, **k: self.local_ps)
        p.start()
        self.addCleanup(p.stop)

    def pending(self):
        rd_common.save_json(rd_common.JANITOR_PATH, {"restart_pending": True})

    def test_pending_over_a_day_raises_attention_cleared_when_applied(self):
        self.pending()
        self.local_ps = (0, "abc\n", "")                 # busy: stays pending
        self.assertEqual(rd_janitor.apply_when_idle(self.cfg), "busy")
        since = self.jstate()["restart_pending_since"]   # old flag without a start time: stamped
        self.assertEqual(self.attention(), {})
        with mock.patch.object(rd_janitor.time, "time",
                               lambda: since + rd_janitor.PENDING_WARN_AFTER + 1):
            self.assertEqual(rd_janitor.apply_when_idle(self.cfg), "busy")
        self.assertIn("pending for 24h", self.attention()["restart-pending"])
        self.local_ps = (0, "", "")
        self.assertEqual(rd_janitor.apply_when_idle(self.cfg), "ok")
        self.assertEqual(self.attention(), {})
        self.assertNotIn("restart_pending_since", self.jstate())

    def test_nothing_pending_no_ssh(self):
        self.assertIsNone(rd_janitor.apply_when_idle(self.cfg))
        self.assertEqual(self.ssh_calls, 0)

    def test_running_containers_keep_pending_without_lock(self):
        self.pending()
        self.local_ps = (0, "abc\n", "")
        self.assertEqual(rd_janitor.apply_when_idle(self.cfg), "busy")
        self.assertEqual(self.ssh_calls, 0)
        self.assertTrue(self.jstate()["restart_pending"])

    def test_container_started_after_precheck_blocks_restart(self):
        self.pending()
        self.mini_file("docker.ps", "def\n")      # fresh check under the lock sees it
        self.assertEqual(rd_janitor.apply_when_idle(self.cfg), "busy")
        self.assertEqual(self.colima(), [])
        st = self.jstate()
        self.assertTrue(st["restart_pending"])
        self.assertNotIn("last_engine_restart", st)
        self.assertFalse(os.path.exists(self.lockdir))

    def test_idle_restarts_under_lock_and_clears_pending(self):
        self.pending()
        self.assertEqual(rd_janitor.apply_when_idle(self.cfg), "ok")
        self.assertEqual(self.colima(), ["colima restart", "locked"])
        self.assertFalse(self.jstate()["restart_pending"])

    def test_idle_restart_prefers_launchd_agent(self):
        self.pending()
        self.mini_file("launchd.loaded", "")
        self.assertEqual(rd_janitor.apply_when_idle(self.cfg), "ok")
        self.assertEqual(self.colima(), ["kickstart -k gui/UID/sh.brew.colima", "locked"])

    def test_lock_held_keeps_pending(self):
        self.pending()
        self.set_owner("otherhost:99", age=5)
        self.assertEqual(rd_janitor.apply_when_idle(self.cfg), "lock-busy")
        self.assertEqual(self.colima(), [])
        self.assertTrue(self.jstate()["restart_pending"])


BLOCK = rd_setup.COLIMA_DOCKER_BLOCK


class SetupMiniConfig(MiniCase):
    CY = ".colima/default/colima.yaml"
    OV = ".colima/_lima/_config/override.yaml"

    def edit(self):
        rc, out, err = self.runner(rd_setup.mini_config_script())
        return rd_janitor.marker(out, "RDSETUP"), err

    def read(self, rel):
        with open(os.path.join(self.mhome, rel)) as f:
            return f.read()

    def baks(self, rel):
        d = os.path.dirname(os.path.join(self.mhome, rel))
        return [n for n in os.listdir(d) if ".bak." in n]

    def test_replaces_inline_docker_block_keeps_rest_and_is_idempotent(self):
        self.mini_file(self.CY, "# CPUs\ncpu: 6\n\n# Docker daemon config\ndocker: {}\n\n"
                                "# VM type\nvmType: vz\nrosetta: true\n")
        self.assertEqual(self.edit()[0], ["changed"])
        self.assertEqual(self.read(self.CY),
                         "# CPUs\ncpu: 6\n\n# Docker daemon config\n" + BLOCK
                         + "\n# VM type\nvmType: vz\nrosetta: true\n")
        self.assertEqual(self.read(self.OV), rd_setup.LIMA_OVERRIDE)
        self.assertEqual(len(self.baks(self.CY)), 1)
        self.assertEqual(self.edit()[0], ["unchanged"])
        self.assertEqual(len(self.baks(self.CY)), 1)

    def test_replaces_multiline_block_at_end(self):
        self.mini_file(self.CY, "cpu: 6\ndocker:\n  ip: 0.0.0.0\n  log-opts:\n    max-size: 1g\n")
        self.assertEqual(self.edit()[0], ["changed"])
        self.assertEqual(self.read(self.CY), "cpu: 6\n" + BLOCK)
        self.assertEqual(self.edit()[0], ["unchanged"])

    def test_appends_when_no_docker_key(self):
        self.mini_file(self.CY, "cpu: 6\n")
        self.assertEqual(self.edit()[0], ["changed"])
        self.assertEqual(self.read(self.CY), "cpu: 6\n\n" + BLOCK)
        self.assertEqual(self.edit()[0], ["unchanged"])

    def test_only_override_drift_still_reports_changed(self):
        self.mini_file(self.CY, "cpu: 6\n" + BLOCK)
        self.mini_file(self.OV, "portForwards: []\n")
        self.assertEqual(self.edit()[0], ["changed"])
        self.assertEqual(self.read(self.OV), rd_setup.LIMA_OVERRIDE)
        self.assertEqual(self.baks(self.CY), [])
        self.assertEqual(len(self.baks(self.OV)), 1)

    def test_no_profile(self):
        self.assertEqual(self.edit()[0], ["no-profile"])

    def test_result_sets_restart_pending_only_on_change(self):
        with mock.patch("builtins.print"):
            self.assertEqual(rd_setup.setup_mini_result(self.cfg, 0, ["unchanged"]), 0)
            self.assertNotIn("restart_pending", self.jstate())
            self.assertEqual(rd_setup.setup_mini_result(self.cfg, 0, ["changed"]), 0)
            self.assertTrue(self.jstate()["restart_pending"])
            self.assertEqual(rd_setup.setup_mini_result(self.cfg, 1, []), 1)


if __name__ == "__main__":
    unittest.main()


class DoctorEngine(unittest.TestCase):
    def test_doctor_repairs_engine_via_kick_never_bare_colima_start(self):
        """`rdocker doctor` with the engine down goes through mini_engine_kick (profile guard,
        launchd path) without restart_ok - never a raw `colima start` over ssh."""
        healths = iter([{"reachable": True, "docker_ok": False},
                        {"reachable": True, "docker_ok": True, "server_version": "28", "rtt_ms": 9}])
        cfg = rd_common.merge_cfg({})
        with mock.patch.object(rd_setup.rd_tunnel, "refresh_health", lambda c, **k: next(healths)), \
                mock.patch.object(rd_janitor, "mini_engine_kick", return_value="started") as kick, \
                mock.patch.object(rd_common, "run", return_value=(0, "", "")) as run_, \
                mock.patch.object(rd_setup.rd_tunnel, "resolve_target", lambda c: ("mini", "ok")), \
                mock.patch.object(rd_setup.rd_tunnel, "sync_forwards", lambda c, **k: (True, None)), \
                mock.patch.object(rd_setup.rd_tunnel, "local_engine_up", lambda c: False), \
                mock.patch.object(rd_setup, "daemon_loaded", lambda: True), \
                mock.patch.object(rd_daemon, "flag_drift_check", lambda: []), \
                mock.patch.object(rd_daemon, "TS_CLI", "/nonexistent"), \
                mock.patch("builtins.print"):
            rd_setup.status(cfg, fix=True)
        kick.assert_called_once_with(cfg)
        self.assertFalse([c for c in run_.call_args_list if "colima" in " ".join(map(str, c[0][0]))])


class CleanCommand(unittest.TestCase):
    """CLI `rdocker clean` waits for the mini lock (CLEAN_LOCK_WAIT) and exits 1 if still held; the
    daemon's janitor-run keeps skip-if-busy (no lock_wait)."""

    def test_clean_busy_exits_1_with_message(self):
        busy = rd_janitor.MiniLockBusy("mini lock held by otherhost:99 12s")
        with mock.patch.object(rd_common, "load_cfg", lambda: rd_common.merge_cfg({})), \
                mock.patch.object(rd_janitor, "janitor", side_effect=busy) as j, \
                mock.patch.object(rd_common, "say") as say:
            self.assertEqual(rd_setup.command(["clean", "--only", "x-"]), 1)
        self.assertEqual(j.call_args[1]["lock_wait"], rd_janitor.CLEAN_LOCK_WAIT)
        self.assertIn("otherhost:99", say.call_args[0][0])

    def test_janitor_run_job_does_not_wait(self):
        tmp = tempfile.mkdtemp(prefix="rdk-job-")
        self.addCleanup(shutil.rmtree, tmp, True)
        with mock.patch.object(rd_common, "STATE_DIR", tmp), \
                mock.patch.object(rd_common, "CFG_DIR", tmp), \
                mock.patch.object(rd_janitor, "janitor", return_value=["skipped: x"]) as j, \
                mock.patch.object(rd_janitor, "apply_when_idle", return_value=None):
            self.assertEqual(rd_setup.run_job("janitor-run", rd_common.merge_cfg({})), 0)
        self.assertNotIn("lock_wait", j.call_args[1])
