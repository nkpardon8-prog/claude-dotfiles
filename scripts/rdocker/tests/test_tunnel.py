"""Tunnel tests: sync_forwards (ok / missing / conflicts, IPv4+IPv6 bookkeeping, master change),
exists_on tri-state on both engines, mirrorable ports from `docker inspect`, ensure_local_running.
In-process with stubs - no ssh, no docker; state files go to a temp dir.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

from rdmods import r, MODULES

rd_common, rd_route, rd_tunnel = (next(m for m in MODULES if m.__name__ == n)
                                  for n in ("rd_common", "rd_route", "rd_tunnel"))

CFG = {"host": "mini", "remote_context": "mini", "local_context": "desktop-linux",
       "local_socket": "/nonexistent.sock"}


class FakeSsh:
    """ssh -S <sock> -O forward|cancel -L <spec> <host>: records specs; `busy` ports fail on IPv4,
    `no6` ports fail on IPv6."""

    def __init__(self, busy=(), no6=()):
        self.busy, self.no6, self.calls = set(busy), set(no6), []

    def __call__(self, cfg, *args, timeout=10):
        op, spec = args[1], args[3]
        self.calls.append((op, spec))
        port = int(spec.split(":")[-1])
        if op == "forward" and spec.startswith("127.") and port in self.busy:
            return 255, "", "bind: Address already in use"
        if op == "forward" and spec.startswith("[::1]") and port in self.no6:
            return 255, "", "cannot listen"
        return 0, "", ""


class SyncForwards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-tun-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        for name, val in (("STATE_DIR", self.tmp), ("CFG_DIR", self.tmp),
                          ("LOCK_PATH", os.path.join(self.tmp, "sync.lock")),
                          ("FORWARDS_PATH", os.path.join(self.tmp, "forwards.json")),
                          ("LOG_PATH", os.path.join(self.tmp, "daemon.log"))):
            p = mock.patch.object(rd_common, name, val)
            p.start()
            self.addCleanup(p.stop)
        self.pid = 4242
        self.desired = set()
        for name, fn in (("ensure_master", lambda cfg: self.pid),
                         ("remote_ports", self.remote_ports)):
            p = mock.patch.object(rd_tunnel, name, fn)
            p.start()
            self.addCleanup(p.stop)

    def remote_ports(self, cfg):
        if isinstance(self.desired, Exception):
            raise self.desired
        return set(self.desired)

    def sync(self, ssh, want=()):
        with mock.patch.object(rd_tunnel, "ssh_ctl", ssh), mock.patch.object(rd_common, "say"):
            return rd_tunnel.sync_forwards(CFG, want=want)

    def state(self):
        with open(rd_common.FORWARDS_PATH) as f:
            return json.load(f)

    def test_ok_with_unrelated_conflict(self):
        self.desired = {5432, 6379, 8080}
        ssh = FakeSsh(busy={8080})
        self.assertEqual(self.sync(ssh, want={5432}), (True, [], [8080]))
        st = self.state()
        self.assertEqual((st["tcp4"], st["tcp6"], st["conflicts"], st["master_pid"]),
                         ([5432, 6379], [5432, 6379], [8080], 4242))

    def test_wanted_port_busy_is_missing_and_conflict(self):
        self.desired = {8080}
        self.assertEqual(self.sync(FakeSsh(busy={8080}), want={8080}), (False, [8080], [8080]))

    def test_no_master_reports_all_wanted_missing(self):
        self.pid = None
        self.desired = {5432}
        self.assertEqual(self.sync(FakeSsh(), want={5432, 80}), (False, [80, 5432], []))
        self.assertFalse(os.path.exists(rd_common.FORWARDS_PATH))

    def test_mini_unreadable_keeps_existing_mirrors(self):
        self.desired = {5432}
        self.sync(FakeSsh())
        self.desired = RuntimeError("docker ps on mini failed")
        self.assertEqual(self.sync(FakeSsh(), want={5432, 6000}), (False, [6000], []))
        self.assertEqual(self.state()["tcp4"], [5432])

    def test_ipv6_tracked_separately_and_retried(self):
        self.desired = {5432}
        self.sync(FakeSsh(no6={5432}))
        self.assertEqual((self.state()["tcp4"], self.state()["tcp6"]), ([5432], []))
        ssh = FakeSsh()
        self.assertEqual(self.sync(ssh), (True, [], []))
        self.assertEqual(ssh.calls, [("forward", "[::1]:5432:127.0.0.1:5432")])
        self.assertEqual(self.state()["tcp6"], [5432])

    def test_gone_port_cancelled_and_conflict_cleared(self):
        self.desired = {5432, 8080}
        self.sync(FakeSsh(busy={8080}))
        self.desired = {6379}
        ssh = FakeSsh()
        self.assertEqual(self.sync(ssh), (True, [], []))
        self.assertIn(("cancel", "127.0.0.1:5432:127.0.0.1:5432"), ssh.calls)
        self.assertIn(("cancel", "[::1]:5432:127.0.0.1:5432"), ssh.calls)
        self.assertEqual((self.state()["tcp4"], self.state()["conflicts"]), ([6379], []))

    def test_new_master_forgets_old_mirrors(self):
        self.desired = {5432}
        self.sync(FakeSsh())
        self.pid = 5555
        ssh = FakeSsh()
        self.sync(ssh)
        self.assertIn(("forward", "127.0.0.1:5432:127.0.0.1:5432"), ssh.calls)
        self.assertEqual(self.state()["master_pid"], 5555)


class ExistsOn(unittest.TestCase):
    def check(self, ctx_key, result, expected):
        with mock.patch.object(rd_common, "dk", return_value=result) as dk:
            self.assertIs(rd_route.exists_on(CFG, ctx_key, "db"), expected)
        self.assertEqual(dk.call_args[0][0], CFG[ctx_key])
        self.assertEqual(dk.call_args[0][-1], "db")

    def test_tri_state_on_both_engines(self):
        for ctx_key in ("remote_context", "local_context"):
            with self.subTest(ctx_key):
                self.check(ctx_key, (0, "abc123\n", ""), True)
                self.check(ctx_key, (1, "", "Error: No such container: db"), False)
                self.check(ctx_key, (1, "[]", "Error response from daemon: no such object: db"), False)
                self.check(ctx_key, (1, "", "Cannot connect to the Docker daemon"), None)
                self.check(ctx_key, (124, "", "Command timed out after 12 seconds"), None)


class MirrorPortsOf(unittest.TestCase):
    def test_mirror_ports_from_inspect(self):
        ports = {"5432/tcp": [{"HostIp": "127.0.0.1", "HostPort": "5715"}],
                 "80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "80"}, {"HostIp": "::", "HostPort": "80"}],
                 "9/tcp": [{"HostIp": "10.0.0.5", "HostPort": "9"}],
                 "53/udp": [{"HostIp": "0.0.0.0", "HostPort": "53"}],
                 "6379/tcp": None}
        self.assertEqual(sorted(r.mirror_ports_of(ports)), [80, 5715])

    def test_remote_ports_skips_stopped_containers(self):
        data = [{"Id": "a", "State": {"Running": True},
                 "NetworkSettings": {"Ports": {"5432/tcp": [{"HostIp": "", "HostPort": "5432"}]}}},
                {"Id": "b", "State": {"Running": False},
                 "NetworkSettings": {"Ports": {"80/tcp": [{"HostIp": "", "HostPort": "80"}]}}}]

        def dk(ctx, *args, timeout=30):
            return (0, "a\nb\n", "") if args[0] == "ps" else (0, json.dumps(data), "")
        with mock.patch.object(rd_common, "dk", dk):
            self.assertEqual(rd_tunnel.remote_ports(CFG), {5432})
            self.assertEqual(rd_tunnel.published_ports(CFG, ["a", "b"]), {"a": {5432}})

    def test_remote_ports_skips_rrun_containers(self):
        # rrun job DBs live and are used on the mini only; mirroring them could collide on the laptop
        data = [{"Id": "a", "State": {"Running": True}, "Config": {"Labels": {"x": "1"}},
                 "NetworkSettings": {"Ports": {"5432/tcp": [{"HostIp": "", "HostPort": "5432"}]}}},
                {"Id": "b", "State": {"Running": True},
                 "Config": {"Labels": {"rdocker.rrun": "0123abcd"}},
                 "NetworkSettings": {"Ports": {"5432/tcp": [{"HostIp": "", "HostPort": "25001"}]}}},
                {"Id": "c", "State": {"Running": True}, "Config": {"Labels": None},
                 "NetworkSettings": {"Ports": {"80/tcp": [{"HostIp": "", "HostPort": "8080"}]}}}]

        def dk(ctx, *args, timeout=30):
            return (0, "a\nb\nc\n", "") if args[0] == "ps" else (0, json.dumps(data), "")
        with mock.patch.object(rd_common, "dk", dk):
            self.assertEqual(rd_tunnel.remote_ports(CFG), {5432, 8080})

    def test_remote_ports_raises_when_unreadable(self):
        with mock.patch.object(rd_common, "dk", return_value=(1, "", "boom")):
            self.assertRaises(RuntimeError, rd_tunnel.remote_ports, CFG)


class EnsureLocalRunning(unittest.TestCase):
    """Docker Desktop counts as running only when `docker info` answers, not when the socket does."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-loc-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        for name in ("STATE_DIR", "CFG_DIR"):
            p = mock.patch.object(rd_common, name, self.tmp)
            p.start()
            self.addCleanup(p.stop)

    def run_case(self, sock_up, info_rcs):
        rcs = list(info_rcs)
        info_calls = []

        def dk(ctx, *args, timeout=30):
            info_calls.append((ctx,) + args)
            return (rcs.pop(0) if rcs else 1), "x", ""
        with mock.patch.object(rd_tunnel, "local_engine_up", lambda cfg: sock_up), \
                mock.patch.object(rd_common, "dk", dk), \
                mock.patch.object(rd_common, "run", return_value=(0, "", "")) as run, \
                mock.patch.object(rd_common, "say"), \
                mock.patch.object(rd_tunnel, "LOCAL_START_WAIT", 0.2), \
                mock.patch.object(rd_tunnel.time, "sleep", lambda s: None):
            ok = rd_tunnel.ensure_local_running(CFG)
        return ok, info_calls, run.call_args_list

    def test_answers_info_no_start(self):
        ok, info, runs = self.run_case(True, [0])
        self.assertTrue(ok)
        self.assertEqual(info, [("desktop-linux", "info", "--format", "x")])
        self.assertEqual(runs, [])

    def test_socket_up_but_booting_waits_for_info(self):
        ok, info, runs = self.run_case(True, [1, 1, 0])
        self.assertTrue(ok)
        self.assertEqual(len(info), 3)
        self.assertEqual(runs, [])          # no `open -ga Docker`: it is already starting

    def test_successful_info_cached_for_ttl(self):
        stamp = os.path.join(self.tmp, "local-info.ok")
        self.assertEqual(len(self.run_case(True, [0])[1]), 1)
        self.assertTrue(os.path.exists(stamp))
        ok, info, _ = self.run_case(True, [])
        self.assertEqual((ok, info), (True, []))                 # within 30 s: no info
        old = os.stat(stamp).st_mtime - rd_tunnel.LOCAL_INFO_TTL - 1
        os.utime(stamp, (old, old))                              # expired
        ok, info, _ = self.run_case(True, [0])
        self.assertEqual((ok, len(info)), (True, 1))
        self.run_case(False, [])                                 # socket down drops the stamp
        self.assertFalse(os.path.exists(stamp))
        self.assertEqual(len(self.run_case(True, [0])[1]), 1)

    def test_failed_info_drops_stamp(self):
        self.run_case(True, [0])
        stamp = os.path.join(self.tmp, "local-info.ok")
        old = os.stat(stamp).st_mtime - rd_tunnel.LOCAL_INFO_TTL - 1
        os.utime(stamp, (old, old))
        self.run_case(True, [1, 0])
        self.assertTrue(os.path.exists(stamp))                   # re-stamped after recovery
        os.utime(stamp, (old, old))
        self.assertFalse(self.run_case(True, [])[0])             # info keeps failing
        self.assertFalse(os.path.exists(stamp))

    def test_socket_down_opens_desktop_and_gives_up(self):
        ok, info, runs = self.run_case(False, [])
        self.assertFalse(ok)
        self.assertEqual(info, [])          # never asks info while the socket is closed
        self.assertEqual(runs[0][0][0], ["open", "-ga", "Docker"])


if __name__ == "__main__":
    unittest.main()
