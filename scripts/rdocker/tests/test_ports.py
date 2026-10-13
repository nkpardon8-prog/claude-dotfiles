"""Port reservation / preflight / mirror post-check tests (Task 1.6).

Same harness as test_shim_safety.py (temp HOME, fake docker on PATH, listening unix sockets for
tunnel/Desktop). `master_up()` swaps the failing ssh stub for one that reports a live ControlMaster
and accepts `-O forward`, except for laptop ports listed in $FAKE_SSH_BUSY (simulated busy).
Real TCP sockets are used only for laptop_free / busy-port cases, on ports picked by the kernel.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import errno
import json
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
from test_shim_safety import RDOCKER, ShimCase, r  # noqa: E402
import rd_common  # noqa: E402
import rd_tunnel  # noqa: E402

SSH_UP = """#!/bin/sh
echo "$*" >> "$HOME/ssh.log"
case "$*" in
  *"-O check"*) echo "Master running (pid=4242)" >&2; exit 0;;
  *"-O forward"*)
    for p in $FAKE_SSH_BUSY; do
      case "$*" in *"127.0.0.1:$p:127.0.0.1:$p"*)
        echo "mux_client_forward: forwarding request failed: Port forwarding failed" >&2; exit 255;;
      esac
    done
    exit 0;;
  *) exit 0;;
esac
"""


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def held_port(addr="127.0.0.1"):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((addr, 0))
    s.listen(4)
    return s, s.getsockname()[1]


class PortCase(ShimCase):
    def setUp(self):
        super().setUp()
        lo = random.randrange(42000, 48000)
        self.range = (lo, lo + 200)

    def master_up(self):
        p = os.path.join(self.bin, "ssh")
        with open(p, "w") as f:
            f.write(SSH_UP)
        os.chmod(p, 0o755)

    def go(self, mini=None, **kw):
        cfg = kw.pop("cfg", {})
        cfg.setdefault("ephemeral_port_range", list(self.range))
        self.scenario(mini=mini, cfg=cfg, **kw)

    def run_ports(self):
        """Host ports in the `-p` value of each logged mini `run`."""
        out = []
        for _, a in self.calls("run"):
            i = a.index("-p")
            out.append(int(a[i + 1].split(":")[1]))
        return out

    def forwards(self):
        with open(os.path.join(self.state, "forwards.json")) as f:
            return json.load(f)


class Preflight(PortCase):
    def test_a_busy_fixed_laptop_port_refuses_before_docker(self):
        self.go()
        s, p = held_port()
        self.addCleanup(s.close)
        res = self.shim("run", "-d", "-p", "127.0.0.1:%d:5432" % p, "postgres")
        self.assertEqual(res.returncode, 125, res.stderr)
        self.assertIn("Bind for 127.0.0.1:%d failed: port is already allocated" % p, res.stderr)
        self.assertEqual(self.calls("run") + self.calls("create"), [])

    def test_b_ephemeral_is_written_from_range_with_cidfile(self):
        self.master_up()
        self.go()
        res = self.shim("run", "-d", "-p", "127.0.0.1::5432", "postgres")
        self.assertEqual(res.returncode, 0, res.stderr)
        (ctx, argv), = self.calls("run")
        self.assertEqual(ctx, "mini")
        self.assertIn("--cidfile", argv)
        port, = self.run_ports()
        self.assertTrue(self.range[0] <= port <= self.range[1], port)
        self.assertEqual(argv[argv.index("-p") + 1], "127.0.0.1:%d:5432" % port)
        self.assertIn(port, self.forwards()["tcp4"])
        self.assertIn(port, self.forwards()["tcp6"])
        self.assertEqual(self.calls("rm"), [])
        self.assertEqual(os.listdir(os.path.join(self.state, "cid")), [])   # temp cidfile gone

    def test_c_concurrent_ephemeral_runs_get_distinct_ports(self):
        self.master_up()
        self.go()
        env = rdmods.child_env(self.home, self.bin, FAKE_DOCKER_FIXTURE=self.fixture,
                               FAKE_DOCKER_LOG=self.log)
        cmd = ["/usr/bin/python3", "-I", RDOCKER, "shim", "run", "-d", "-p", "127.0.0.1::5432",
               "postgres"]
        procs = [subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for _ in range(2)]
        for pr in procs:
            _, err = pr.communicate(timeout=60)
            self.assertEqual(pr.returncode, 0, err)
        ports = self.run_ports()
        self.assertEqual(len(ports), 2)
        self.assertNotEqual(ports[0], ports[1])

    def test_f_udp_publish_refused(self):
        self.go()
        res = self.shim("run", "-d", "-p", "5353:53/udp", "dns")
        self.assertEqual(res.returncode, 125)
        self.assertIn("UDP publishes are not mirrored to the laptop", res.stderr)
        self.assertEqual(self.calls("run"), [])

    def test_attached_and_long_forms_are_rewritten(self):
        self.master_up()
        self.go()
        res = self.shim("run", "-dp6379", "--publish=127.0.0.1::5432", "redis")
        self.assertEqual(res.returncode, 0, res.stderr)
        (_, argv), = self.calls("run")
        self.assertTrue(re.match(r"^-dp\d+:6379$", [a for a in argv if a.startswith("-dp")][0]))
        self.assertTrue(re.match(r"^--publish=127\.0\.0\.1:\d+:5432$",
                                 [a for a in argv if a.startswith("--publish=")][0]))

    def test_compose_busy_published_port_refuses(self):
        s, p = held_port()
        self.addCleanup(s.close)
        model = {"name": "proj", "services": {"db": {"image": "postgres", "ports": [
            {"mode": "ingress", "target": 5432, "published": str(p), "protocol": "tcp",
             "host_ip": "127.0.0.1"}]}}}
        self.go(compose_model=model)
        res = self.shim("compose", "up", "-d")
        self.assertEqual(res.returncode, 125, res.stderr)
        self.assertEqual([a for _, a in self.calls("compose") if "up" in a], [])


class AllocRetry(PortCase):
    def test_d_mini_allocated_removes_created_and_retries_once(self):
        self.master_up()
        self.go(mini={"containers": {}, "alloc_fail_once": True})
        res = self.shim("run", "-d", "-p", "127.0.0.1::5432", "postgres")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("port is already allocated", res.stderr)     # docker's stderr re-emitted
        seq = [a[0] for _, a in self.calls() if a[:1] in (["run"], ["rm"])]
        self.assertEqual(seq, ["run", "rm", "run"])
        self.assertEqual(self.calls("rm")[0][1], ["rm", "-f", "cid0001"])
        p1, p2 = self.run_ports()
        self.assertNotEqual(p1, p2)

    def test_fixed_port_allocated_on_mini_is_not_retried(self):
        self.master_up()
        self.go(mini={"containers": {}, "alloc_fail_once": True})
        res = self.shim("run", "-d", "-p", "127.0.0.1:%d:5432" % free_port(), "postgres")
        self.assertEqual(res.returncode, 125)
        self.assertEqual(len(self.calls("run")), 1)
        self.assertEqual(self.calls("rm"), [("mini", ["rm", "-f", "cid0001"])])


class PostCheck(PortCase):
    def test_e_mirror_conflict_removes_created_container(self):
        self.master_up()
        self.go()
        p = free_port()
        res = self.shim("run", "-d", "-p", "127.0.0.1:%d:5432" % p, "postgres",
                        env={"FAKE_SSH_BUSY": str(p)})
        self.assertEqual(res.returncode, 1, res.stderr)
        self.assertIn("port %d is not mirrored to the laptop" % p, res.stderr)
        self.assertEqual(self.calls("rm"), [("mini", ["rm", "-f", "cid0001"])])
        self.assertIn(p, self.forwards()["conflicts"])

    def test_no_master_means_no_mirror_and_cleanup(self):
        self.go()       # ssh stub fails: no ControlMaster
        res = self.shim("run", "-d", "-p", "127.0.0.1::80", "nginx")
        self.assertEqual(res.returncode, 1, res.stderr)
        self.assertEqual(self.calls("rm"), [("mini", ["rm", "-f", "cid0001"])])

    def test_publish_all_without_ports_is_fine(self):
        self.master_up()
        self.go()
        res = self.shim("run", "-d", "-P", "nginx")     # fake publishes nothing for -P
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.calls("rm"), [])

    def test_start_of_existing_container_is_left_running(self):
        self.master_up()
        p = free_port()
        self.go(mini={"containers": {"db": {"Id": "dbid", "Ports": {
            "5432/tcp": [{"HostIp": "127.0.0.1", "HostPort": str(p)}]}}}})
        res = self.shim("start", "db", env={"FAKE_SSH_BUSY": str(p)})
        self.assertEqual(res.returncode, 1, res.stderr)
        self.assertIn("left running", res.stderr)
        self.assertEqual(self.calls("rm"), [])

    def test_foreground_run_watcher_kills_on_conflict(self):
        self.master_up()
        self.go(mini={"containers": {}, "fg_seconds": 20})
        p = free_port()
        res = self.shim("run", "--rm", "-p", "127.0.0.1:%d:80" % p, "nginx",
                        env={"FAKE_SSH_BUSY": str(p)})
        self.assertEqual(res.returncode, 1, res.stderr)
        self.assertEqual(self.calls("rm"), [("mini", ["rm", "-f", "cid0001"])])

    def test_foreground_run_ok_mirrors(self):
        self.master_up()
        self.go(mini={"containers": {}, "fg_seconds": 3})
        res = self.shim("run", "--rm", "-p", "127.0.0.1::80", "nginx")
        self.assertEqual(res.returncode, 0, res.stderr)
        port, = self.run_ports()
        self.assertIn(port, self.forwards()["tcp4"])
        self.assertEqual(self.calls("rm"), [])


class LaptopFree(unittest.TestCase):
    def test_g_free_port(self):
        self.assertTrue(r.laptop_free(free_port()))

    def test_g_loopback_listener_is_busy(self):
        s, p = held_port("127.0.0.1")
        self.addCleanup(s.close)
        self.assertFalse(r.laptop_free(p))

    def test_g_wildcard_listener_is_busy(self):
        s, p = held_port("0.0.0.0")
        self.addCleanup(s.close)
        self.assertFalse(r.laptop_free(p))

    def test_g_ipv6_loopback_listener_is_busy(self):
        try:
            s = socket.socket(socket.AF_INET6)
            s.bind(("::1", 0))
        except OSError as e:
            if e.errno in (errno.EADDRNOTAVAIL, errno.EAFNOSUPPORT):
                self.skipTest("no IPv6 loopback")
            raise
        s.listen(4)
        self.addCleanup(s.close)
        self.assertFalse(r.laptop_free(s.getsockname()[1]))

    def test_reservation_blocks_second_reserver(self):
        cfg = dict(r.DEFAULTS, ephemeral_port_range=[free_port(), 0])
        cfg["ephemeral_port_range"][1] = cfg["ephemeral_port_range"][0]
        with unittest.mock.patch.object(rd_tunnel, "RESERVED_PATH", os.path.join(self.tmp, "res.json")), \
                unittest.mock.patch.object(rd_tunnel, "PORTS_LOCK", os.path.join(self.tmp, "ports.lock")), \
                unittest.mock.patch.object(rd_common, "FORWARDS_PATH", os.path.join(self.tmp, "fw.json")), \
                unittest.mock.patch.object(rd_common, "ensure_dirs", lambda: None):
            spec = r.parse_publish("127.0.0.1::5432")
            out, mine = r.reserve_ports(cfg, [spec])
            self.assertEqual(mine, [cfg["ephemeral_port_range"][0]])
            with self.assertRaises(r.PortRefuse):
                r.reserve_ports(cfg, [spec])
            r.release_ports(mine)
            self.assertEqual(r.reserve_ports(cfg, [spec])[1], mine)

    def test_reservation_outlives_a_long_pull_and_keeper_extends_only_live_ports(self):
        self.assertGreaterEqual(r.RESERVE_TTL, 900)          # was 120 s: lapsed mid-pull
        path = os.path.join(self.tmp, "res.json")
        with unittest.mock.patch.object(rd_tunnel, "RESERVED_PATH", path), \
                unittest.mock.patch.object(rd_tunnel, "PORTS_LOCK", os.path.join(self.tmp, "p.lock")):
            rd_common.save_json(path, {"20001": 1000.0 + 60, "20002": 1000.0 + 60})
            r.extend_ports([20001, 20003], now=1000.0)         # 20003 never reserved: not added
            res = rd_common.load_json(path, {})
            self.assertEqual(res, {"20001": 1000.0 + r.RESERVE_TTL, "20002": 1060.0})
            r.release_ports([20001])
            r.extend_ports([20001], now=1000.0)                # released: never resurrected
            self.assertNotIn("20001", rd_common.load_json(path, {}))
            calls = []
            with unittest.mock.patch.object(rd_tunnel, "extend_ports", lambda p: calls.append(p)):
                with r.hold_ports(lambda: [20002], every=0.05):
                    import time as _t
                    _t.sleep(0.3)
                n = len(calls)
                _t.sleep(0.15)
            self.assertGreaterEqual(n, 2)
            self.assertEqual(len(calls), n)                    # stopped with the block
            self.assertEqual(calls[0], [20002])

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdkp-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)


if __name__ == "__main__":
    unittest.main()
