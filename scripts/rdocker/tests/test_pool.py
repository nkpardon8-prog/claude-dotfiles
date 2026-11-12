"""rd_pool (per-job placement on the worker pool) + rd_run's host loop, failover and flags.

Unit tests drive rd_pool.plan() with canned probe answers; end-to-end tests run the real `rrun`
against a two-worker fleet.json where the fake ssh (tests/test_run.py) gives each worker its own
HOME (FAKE_SSH_HOMES), so each has its own ~/rr, slots and mirrors.
"""
import fcntl
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
import test_run  # noqa: E402  (fixture base + fake ssh; its RunTest is not re-collected here)

import rd_pool  # noqa: E402

rd_common = rdmods.owner("RRUN_STATE")


def worker(name, speed=1.0, max_slots=2, heavy_slots=1, enabled=True, mem_gb=16):
    return {"name": name, "alias": name, "ip": "100.64.0.%d" % (len(name) + ord(name[-1]) % 50),
            "port": 22, "user": "rd", "os": "linux", "roles": ["worker"], "speed": speed,
            "max_slots": max_slots, "heavy_slots": heavy_slots, "mem_gb": mem_gb, "enabled": enabled}


def write_fleet(path, machines):
    with open(path, "w") as f:
        json.dump({"version": 1, "client_keys": [], "machines": machines}, f)


def probe(slots_cap=2, slots_busy=0, heavy_cap=1, heavy_busy=0, mem_mb=16000, load=0.0, ncpu=4,
          warm_git=1, warm_deps=1, speed=None, share="max"):
    p = {"slots_cap": slots_cap, "slots_busy": slots_busy, "heavy_cap": heavy_cap,
         "heavy_busy": heavy_busy, "mem_avail_mb": mem_mb, "load1": load, "ncpu": ncpu,
         "warm_git": warm_git, "warm_deps": warm_deps, "share": share}
    if speed is not None:
        p["speed"] = speed
    return p


class Classify(unittest.TestCase):
    def test_job_classes(self):
        table = [
            (["npm", "run", "test:db"], "db", False, False, True),
            (["npm", "run", "test:db:migrated", "--", "--testTimeout=1"], "db", False, False, True),   # 2026-11-11
            (["npm", "--prefix", "server", "run", "test:db:rls"], "db", False, False, True),
            (["sh", "-c", "cd server && npm run test:db:x.y-z"], "db", False, False, True),
            (["npm", "run", "test:dbx"], "normal", False, False, False),
            (["node", "scripts/test-with-db.mjs", "a.ts"], "db", False, False, True),
            (["npx", "tsc", "--noEmit", "-p", "tsconfig.json"], "heavy", True, False, True),
            (["npm", "run", "check:server-test-typecheck"], "heavy", True, False, True),
            (["npm", "run", "typecheck"], "heavy", True, False, True),
            (["node", "--max-old-space-size=6144", "x.mjs"], "heavy", False, False, True),
            (["npm", "run", "lint"], "light", True, True, False),
            (["npx", "eslint", "."], "light", True, True, False),
            (["npm", "run", "check:enqueue-trace"], "light", False, True, False),
            (["npx", "vitest", "run"], "normal", True, False, False),
            (["npm", "run", "test:unit"], "normal", False, False, False),
            (["/bin/sh", "-c", "true"], "normal", False, False, False),
        ]
        for argv, cls, retry, local, never in table:
            with self.subTest(argv=argv):
                j = rd_pool.classify(argv)
                self.assertEqual((j["cls"], j["retry_ok"], j["local_ok"], j["never_local"]),
                                 (cls, retry, local, never))
        b = rd_pool.classify(["npm", "run", "build"], ["server/dist"])
        self.assertEqual((b["cls"], b["retry_ok"], b["local_ok"]), ("build", True, False))
        self.assertEqual(rd_pool.classify(["npx", "tsc", "--noEmit"])["need_gb"], 6)

    def test_build_shape_and_outputs_map(self):
        for argv, want in ((["npm", "run", "build"], True), (["npm", "--prefix", "server", "run", "build"], True),
                           (["pnpm", "run", "build"], True), (["npm", "run", "build:prod"], False),
                           (["npm", "run", "dev"], False), (["docker", "build", "."], False),
                           (["npx", "tsc", "-p", "tsconfig.json"], False)):
            with self.subTest(argv=argv):
                self.assertEqual(rd_pool.is_build(argv), want)
        self.assertEqual(rd_pool.build_pkg_dir("server", ["npm", "run", "build"]), "server")
        self.assertEqual(rd_pool.build_pkg_dir("", ["npm", "--prefix", "client", "run", "build"]), "client")
        self.assertEqual(rd_pool.build_pkg_dir("server", ["npm", "--prefix=../admin-client", "run", "build"]),
                         "admin-client")
        self.assertIsNone(rd_pool.build_pkg_dir("", ["npm", "--prefix", "../x", "run", "build"]))
        cfg = {}
        self.assertEqual(rd_pool.outputs_for(cfg, "dentall.ab12cd34", "server"), ["server/dist"])
        self.assertEqual(rd_pool.outputs_for(cfg, "dentall.ab12cd34", "admin-client"), ["admin-client/dist"])
        self.assertEqual(rd_pool.outputs_for(cfg, "dentall.ab12cd34", ""), [])
        self.assertEqual(rd_pool.outputs_for(cfg, "other.ab12cd34", "server"), [])
        cfg = {"rr_outputs": {"wt.1234abcd": {"": ["dist", "../x", ".git/y"]}}}
        self.assertEqual(rd_pool.outputs_for(cfg, "wt.1234abcd", ""), ["dist"])   # unsafe paths dropped


class PlanUnit(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="pool-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        self.fleet = os.path.join(self.d, "fleet.json")
        self.cfg = dict(rd_common.DEFAULTS, fleet_path=self.fleet)

    def plan(self, machines, answers, job=None, **kw):
        write_fleet(self.fleet, machines)

        def fake(host, req, timeout):
            a = answers.get(host.cfg["host"])
            return (dict(a), 0.01) if a is not None else (None, "down")
        with mock.patch.object(rd_pool, "probe_one", side_effect=fake) as m:
            p = rd_pool.plan(self.cfg, job or rd_pool.classify(["npx", "vitest", "run"]), **kw)
        return p, m

    def names(self, p):
        return [h.name for h in p.hosts]

    def test_fastest_free_first_ties_and_race_wait(self):
        p, _ = self.plan([worker("fast", 1.0), worker("slow", 0.5)],
                         {"fast": probe(), "slow": probe()})
        self.assertEqual(self.names(p), ["fast", "slow"])
        self.assertTrue(p.pool)
        self.assertTrue(p.hosts[0].short)                         # a lost race moves on quickly
        self.assertEqual(p.hosts[0].cfg["rr_wait_min"], rd_pool.RACE_WAIT_MIN)
        self.assertFalse(p.hosts[1].short)                        # the last one waits fully
        self.assertEqual(p.hosts[1].cfg["rr_wait_min"], self.cfg["rr_wait_min"])
        self.assertEqual(p.hosts[0].cfg["host"], "fast")
        self.assertEqual(p.hosts[0].cfg["rr_slots"], 2)            # fleet max_slots
        # load counts: a loaded fast worker loses to an idle slow one
        p, _ = self.plan([worker("fast", 1.0), worker("slow", 0.5)],
                         {"fast": probe(load=8, ncpu=4), "slow": probe()})
        self.assertEqual(self.names(p), ["slow", "fast"])
        # live speed (~/rr/speed) beats the fleet entry's
        p, _ = self.plan([worker("a", 1.0), worker("b", 0.5)], {"a": probe(), "b": probe(speed=2.0)})
        self.assertEqual(self.names(p), ["b", "a"])

    def test_warm_slower_worker_beats_cold_faster_one(self):
        p, _ = self.plan([worker("fast", 1.0), worker("slow", 0.7)],
                         {"fast": probe(warm_git=0, warm_deps=0), "slow": probe()})
        self.assertEqual(self.names(p), ["slow", "fast"])          # 1.0*0.3 < 0.7
        p, _ = self.plan([worker("fast", 1.0), worker("slow", 0.7)],
                         {"fast": probe(warm_deps=0), "slow": probe(warm_deps=0)})
        self.assertEqual(self.names(p), ["fast", "slow"])

    def test_heavy_needs_memory_and_a_heavy_slot(self):
        heavy = rd_pool.classify(["npx", "tsc", "--noEmit"])
        p, _ = self.plan([worker("a", 1.0), worker("b", 0.5), worker("c", 0.4)],
                         {"a": probe(mem_mb=4000), "b": probe(heavy_busy=1), "c": probe()}, job=heavy)
        self.assertEqual(self.names(p)[0], "c")
        st = {h.name: h.state for h in p.hosts}
        self.assertEqual(st, {"a": "low-mem", "b": "busy", "c": "free"})
        self.assertTrue(p.hosts[0].short)                          # c is not last: a lost race moves on
        # ... yet the same small-memory host takes a light job
        p, _ = self.plan([worker("a", 1.0), worker("b", 0.5)], {"a": probe(mem_mb=4000), "b": probe()},
                         job=rd_pool.classify(["npm", "run", "lint"]))
        self.assertEqual(self.names(p), ["a", "b"])

    def test_all_busy_waits_on_the_biggest_and_light_jobs_may_go_local(self):
        busy = {"a": probe(slots_cap=1, slots_busy=1), "b": probe(slots_cap=4, slots_busy=4)}
        ms = [worker("a", 1.0, max_slots=1), worker("b", 0.5, max_slots=4)]
        with mock.patch.object(rd_pool, "local_free_gb", return_value=10.0):
            p, _ = self.plan(ms, busy)                           # normal: queue, never local
            # wait host = the soonest finish: a (1 slot, T 60 s: ~30 s queue + 60) beats b (4 slots
            # at speed 0.5, T 120 s: ~24 s queue + 120)
            self.assertEqual(self.names(p), ["a", "b"])
            # the holders' ages count: a's holder just started (59 s left), b's is nearly done
            same = [worker("a", 1.0, max_slots=1), worker("b", 1.0, max_slots=1)]
            one = probe(slots_cap=1, slots_busy=1)
            p, _ = self.plan(same, {"a": dict(one, ages=[1]), "b": dict(one, ages=[55])})
            self.assertEqual(self.names(p), ["b", "a"])
            self.assertEqual([h.state for h in p.hosts], ["busy", "busy"])
            self.assertAlmostEqual(p.hosts[0].queue_s, 12.0)          # floor: 0.2 x 60 s
            self.assertIsNone(p.local_after_s)
            self.assertFalse(any(h.short for h in p.hosts))
            p, _ = self.plan(ms, busy, job=rd_pool.classify(["npm", "run", "lint"]))
            self.assertEqual(p.local_after_s, rd_pool.LOCAL_AFTER_S)
            p, _ = self.plan(ms, busy, job=rd_pool.classify(["npx", "tsc", "--noEmit"]))
            self.assertIsNone(p.local_after_s)
        with mock.patch.object(rd_pool, "local_free_gb", return_value=3.0):
            p, _ = self.plan(ms, busy, job=rd_pool.classify(["npm", "run", "lint"]))
            self.assertIsNone(p.local_after_s)                      # the laptop is short on memory

    def test_dead_workers_go_last(self):
        p, _ = self.plan([worker("a", 1.0), worker("b", 0.2)], {"b": probe()})
        self.assertEqual(self.names(p), ["b", "a"])
        self.assertEqual(p.hosts[1].state, "down")
        lines = rd_pool.where_report(self.cfg, rd_pool.classify(["npx", "vitest", "run"]), p)
        self.assertIn("pick: b", lines[-1])

    def test_one_worker_or_no_fleet_is_the_old_single_host(self):
        p, m = self.plan([worker("only", 0.3, max_slots=3), worker("off", enabled=False)], {})
        self.assertEqual(m.call_count, 0)                         # nothing probed
        self.assertEqual(self.names(p), ["only"])
        self.assertFalse(p.pool)
        self.assertEqual(p.hosts[0].cfg["host"], "only")
        self.assertEqual(p.hosts[0].cfg["rr_wait_min"], self.cfg["rr_wait_min"])
        os.unlink(self.fleet)
        p = rd_pool.plan(self.cfg, rd_pool.classify(["true"]))
        self.assertEqual([(h.name, h.cfg["host"]) for h in p.hosts], [("mini", self.cfg["host"])])
        with open(self.fleet, "w") as f:
            f.write("{broken")
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            p = rd_pool.plan(self.cfg, rd_pool.classify(["true"]))  # unusable fleet: noted, cfg host
        self.assertEqual(self.names(p), ["mini"])
        self.assertIn("fleet.json unusable", err.getvalue())

    def test_share_off_worker_is_off_and_tried_last(self):
        p, _ = self.plan([worker("big", 3.0, max_slots=8), worker("a", 1.0), worker("b", 0.5)],
                         {"big": probe(slots_cap=8, share="off"), "a": probe(slots_cap=1, slots_busy=1)})
        self.assertEqual(self.names(p), ["a", "b", "big"])            # busy, down, then off
        self.assertEqual({h.name: h.state for h in p.hosts}, {"big": "off", "a": "busy", "b": "down"})
        self.assertIsNone(p.hosts[2].eta)
        lines = rd_pool.where_report(self.cfg, rd_pool.classify(["npx", "vitest", "run"]), p)
        self.assertRegex("\n".join(lines), r"\nbig +big +off .* off\n")
        p, _ = self.plan([worker("big", 3.0, max_slots=8), worker("a", 1.0)],
                         {"big": probe(slots_cap=8), "a": probe()})
        self.assertEqual(self.names(p), ["big", "a"])                 # sharing again: first
        p, _ = self.plan([worker("big"), worker("a")], {"big": probe(share="off"), "a": probe(share="off")})
        lines = rd_pool.where_report(self.cfg, rd_pool.classify(["true"]), p)
        self.assertIn("owner turned sharing off", lines[-1])

    def test_force_host(self):
        p, m = self.plan([worker("a"), worker("b")], {}, force="b")
        self.assertEqual((self.names(p), m.call_count, p.pool), (["b"], 0, False))
        with self.assertRaises(ValueError):
            self.plan([worker("a"), worker("b")], {}, force="zz")


class ProbeSnippet(unittest.TestCase):
    """The PROBE perl, run locally against a fake ~/rr (RR_OS=linux + RR_PROC/RR_SYS fixtures)."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="probe-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        self.root = os.path.join(self.d, "rr")
        proc, sysd = os.path.join(self.d, "proc"), os.path.join(self.d, "sys", "class", "thermal")
        for p in (proc, os.path.join(sysd, "thermal_zone0"), os.path.join(sysd, "thermal_zone1"),
                  os.path.join(self.root, "slots")):
            os.makedirs(p)
        test_run.wfile(os.path.join(proc, "meminfo"), "MemTotal: 8000000 kB\nMemAvailable: 2000000 kB\n")
        test_run.wfile(os.path.join(proc, "loadavg"), "3.50 1 1 1/1 1\n")
        test_run.wfile(os.path.join(proc, "cpuinfo"), "processor\t: 0\n\nprocessor\t: 1\n")
        test_run.wfile(os.path.join(sysd, "thermal_zone0", "temp"), "41000\n")
        test_run.wfile(os.path.join(sysd, "thermal_zone1", "temp"), "63500\n")
        self.env = rdmods.child_env(self.d, RR_ROOT=self.root, RR_OS="linux", RR_PROC=proc,
                                    RR_SYS=os.path.join(self.d, "sys"))

    def run_probe(self, req):
        p = subprocess.run(["/usr/bin/perl", "-e", rd_pool.PROBE], input=json.dumps(req), env=self.env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)

    def test_readings_slots_cap_speed_and_warmth(self):
        held = []
        for name in ("0", "heavy-0"):
            fh = open(os.path.join(self.root, "slots", name), "a")
            fcntl.flock(fh, fcntl.LOCK_EX)
            held.append(fh)
        self.addCleanup(lambda: [h.close() for h in held])
        repo = os.path.join(self.d, "repo")
        os.makedirs(os.path.join(repo, "server"))
        test_run.wfile(os.path.join(repo, "server", "package.json"), "{}")
        test_run.wfile(os.path.join(repo, "server", "package-lock.json"), "{\"v\": 1}")
        shas = rd_pool.deps_shas(repo, ["server", "nolock"])
        self.assertEqual([s[0] for s in shas], ["server"])
        req = {"slots": 4, "heavy_slots": 2, "slug": "app.1234abcd", "deps": shas}
        o = self.run_probe(req)
        self.assertEqual((float(o["load1"]), int(o["ncpu"]), o["mem_free_pct"], o["mem_avail_mb"]),
                         (3.5, 2, 25, 1953))
        self.assertEqual(o["temp"], 63.5)
        self.assertEqual((int(o["slots_cap"]), o["slots_busy"], int(o["heavy_cap"]), o["heavy_busy"]),
                         (4, 1, 2, 1))
        self.assertEqual((o["warm_git"], o["warm_deps"]), (0, 0))
        self.assertNotIn("speed", o)
        # rd-tune's cap, a benchmarked speed, the bare repo and a store entry with this lockfile
        test_run.wfile(os.path.join(self.root, "slots.cap"), "1\n")
        test_run.wfile(os.path.join(self.root, "speed"), "0.75\n")
        os.makedirs(os.path.join(self.root, "git", "app.1234abcd.git"))
        nm = os.path.join(self.root, "deps", "k1", "node_modules")
        os.makedirs(nm)
        test_run.wfile(os.path.join(nm, ".rr-deps-stamp"), "%s v22.0.0 ci --no-audit" % shas[0][1])
        o = self.run_probe(req)
        self.assertEqual((int(o["slots_cap"]), o["slots_busy"], o["speed"]), (1, 1, 0.75))
        self.assertEqual((o["warm_git"], o["warm_deps"]), (1, 1))
        # a mirror of the same repo with these packages also counts as warm
        shutil.rmtree(os.path.join(self.root, "deps"))
        mnm = os.path.join(self.root, "w", "app.1234abcd-0123456789ab", "server", "node_modules")
        os.makedirs(mnm)
        test_run.wfile(os.path.join(mnm, ".rr-deps-stamp"), "%s v22" % shas[0][1])
        self.assertEqual(self.run_probe(req)["warm_deps"], 1)
        self.assertEqual(self.run_probe(dict(req, slug="../x"))["warm_git"], 0)   # never a path


class ProbeShareSwitch(unittest.TestCase):
    """The PROBE's share switch: RR_SHARE_FILE / ~/rr/share; Colima stop on a Mac worker."""
    setUp, run_probe = ProbeSnippet.setUp, ProbeSnippet.run_probe     # same fake ~/rr + /proc

    def test_levels_halve_slots_and_missing_file_is_max(self):
        req = {"slots": 8, "heavy_slots": 6, "slug": "", "deps": []}
        o = self.run_probe(req)
        self.assertEqual((o["share"], int(o["slots_cap"]), int(o["heavy_cap"])), ("max", 8, 6))
        share = os.path.join(self.d, "share-file")
        self.env["RR_SHARE_FILE"] = share
        for text, want in (("some\n", ("some", 4, 3)), ("max", ("max", 8, 6)), ("off\n", ("off", 8, 6)),
                           ("bogus", ("off", 8, 6))):
            test_run.wfile(share, text)
            o = self.run_probe(req)
            self.assertEqual((o["share"], int(o["slots_cap"]), int(o["heavy_cap"])), want, text)
        test_run.wfile(share, "some")
        o = self.run_probe({"slots": 1, "heavy_slots": 1})
        self.assertEqual((int(o["slots_cap"]), int(o["heavy_cap"])), (1, 1))         # floor, min 1
        # no RR_SHARE_FILE on Linux: ~/rr/share
        del self.env["RR_SHARE_FILE"]
        test_run.wfile(os.path.join(self.root, "share"), "off")
        self.assertEqual(self.run_probe(req)["share"], "off")

    def fake_colima(self):
        log = os.path.join(self.d, "colima.log")
        c = os.path.join(self.d, "fakecolima")
        test_run.wfile(c, '#!/bin/sh\necho "colima $*" >> %s\n' % log)
        os.chmod(c, 0o755)
        os.makedirs(os.path.join(self.root, "state"))
        test_run.wfile(os.path.join(self.root, "state", "colima.started"), "")
        self.env.update(RR_COLIMA=c, RR_SHARE_FILE=os.path.join(self.d, "share-file"),
                        RR_COLIMA_SOCK=os.path.join(self.d, "no-sock"))
        test_run.wfile(self.env["RR_SHARE_FILE"], "off")
        return log

    def wait_gone(self, path):
        end = time.time() + 10
        while os.path.exists(path) and time.time() < end:
            time.sleep(0.05)
        self.assertFalse(os.path.exists(path), path)

    def test_share_off_idle_mac_stops_colima_in_the_background(self):
        log = self.fake_colima()
        mark = os.path.join(self.root, "state", "colima.started")
        self.run_probe({"slots": 2})                                   # RR_OS=linux: never
        time.sleep(0.3)
        self.assertFalse(os.path.exists(log))
        self.env["RR_OS"] = "darwin"
        held = open(os.path.join(self.root, "slots", "5"), "a")        # any held slot counts
        fcntl.flock(held, fcntl.LOCK_EX)
        self.run_probe({"slots": 2})
        time.sleep(0.3)
        self.assertFalse(os.path.exists(log))
        held.close()
        test_run.wfile(self.env["RR_SHARE_FILE"], "some")
        self.run_probe({"slots": 2})                                   # sharing: keep it
        time.sleep(0.3)
        self.assertFalse(os.path.exists(log))
        test_run.wfile(self.env["RR_SHARE_FILE"], "off")
        o = self.run_probe({"slots": 2})
        self.assertEqual(o.get("docker"), "stopping")
        self.wait_gone(mark)
        self.wait_gone(os.path.join(self.root, "colima.lock"))
        with open(log) as f:
            self.assertEqual(f.read(), "colima stop\n")
        o = self.run_probe({"slots": 2})                               # stopped: nothing more to do
        self.assertNotIn("docker", o)


class PoolE2E(test_run.RunBase):
    """Real rrun against two workers (w1 fast, w2 slow), each with its own HOME."""

    def setUp(self):
        super().setUp()
        self.whome = {}
        for n in ("w1", "w2"):
            self.whome[n] = os.path.join(self.d, "home-" + n)
            os.makedirs(self.whome[n])
        self.fleet = os.path.join(self.d, "fleet.json")
        self.set_fleet()
        # fixed worker readings (the probe and the runner's memory gate read these, not this Mac)
        self.proc = os.path.join(self.d, "proc")
        os.makedirs(self.proc)
        test_run.wfile(os.path.join(self.proc, "meminfo"), "MemTotal: 32000000 kB\nMemAvailable: 24000000 kB\n")
        test_run.wfile(os.path.join(self.proc, "loadavg"), "0.10 0 0 1/1 1\n")
        test_run.wfile(os.path.join(self.proc, "cpuinfo"), "processor\t: 0\n\nprocessor\t: 1\n")

    def set_fleet(self, w1_slots=2, w2_slots=2, **cfg):
        write_fleet(self.fleet, [worker("w1", 1.0, max_slots=w1_slots), worker("w2", 0.5, max_slots=w2_slots)])
        self.write_cfg(fleet_path=self.fleet, **cfg)

    def env(self, **extra):
        homes = ",".join("%s=%s" % kv for kv in sorted(getattr(self, "whome", {}).items()))
        base = {"FAKE_SSH_HOMES": homes, "RRUN_RECONNECT_WAIT": "0"}
        if getattr(self, "proc", None):
            base.update(RR_OS="linux", RR_PROC=self.proc)
        return super().env(**dict(base, **extra))

    def target(self):
        st = json.loads(self.read(rd_common.RRUN_STATE.replace(rdmods.TEST_HOME, self.home)))
        return st["last"]["target"]

    def hold_slot(self, worker, name="0"):
        d = os.path.join(self.whome[worker], "rr", "slots")
        os.makedirs(d, exist_ok=True)
        fh = open(os.path.join(d, name), "a")
        fcntl.flock(fh, fcntl.LOCK_EX)
        self.addCleanup(fh.close)

    def test_runs_on_the_fastest_free_worker(self):
        r = self.rrun("/bin/sh", "-c", "echo hi")
        self.assertEqual((r.returncode, r.stdout), (0, "hi\n"), r.stderr)
        self.assertEqual(self.target(), "w1")
        self.assertTrue(os.path.isdir(os.path.join(self.whome["w1"], "rr", "w2")))
        self.assertFalse(os.path.exists(os.path.join(self.whome["w2"], "rr", "w2")))
        self.assertIn("slots_busy", self.read(self.sshlog))     # probed

    def test_unreachable_before_go_moves_to_the_next_worker(self):
        r = self.rrun("/bin/sh", "-c", "echo hi", FAKE_SSH_RUNDOWN_HOSTS="w1")
        self.assertEqual((r.returncode, r.stdout), (0, "hi\n"), r.stderr)
        self.assertIn("w1 unreachable", r.stderr)
        self.assertIn("- trying w2", r.stderr)
        self.assertEqual(self.target(), "w2")

    def test_lost_race_for_a_slot_moves_on(self):
        """The probe saw w1 free (another client then took the slot): 73 after a short wait -> w2."""
        self.set_fleet(w1_slots=1, w2_slots=1, rr_race_wait_min=0.02)
        self.hold_slot("w1")
        empty = os.path.join(self.d, "probe-home")
        os.makedirs(empty)
        r = self.rrun("/bin/sh", "-c", "echo hi", FAKE_SSH_PROBE_HOMES="w1=" + empty)
        self.assertEqual((r.returncode, r.stdout), (0, "hi\n"), r.stderr)
        self.assertRegex(r.stderr, r"w1 had no free slot after \d+ s - trying w2")
        self.assertEqual(self.target(), "w2")

    def test_lost_after_go_repeatable_job_runs_once_more_elsewhere(self):
        self.set_fleet(rr_reattach_backoff_s=[0, 0, 0])     # every reattach to w1 drops too
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", "echo x >> %s" % marker, "vitest", FAKE_SSH_DROP_HOSTS="w1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("rrun: w1 went away mid-run (lost connection); re-running once on w2", r.stderr)
        self.assertEqual(self.read(marker), "x\nx\n")
        self.assertEqual(self.target(), "w2")

    def test_db_job_reruns_once_only_when_the_worker_went_away(self):
        """Each rrun DB job gets its own throwaway database on the worker, so a lost connection (the
        exit code never arrived) re-runs it once elsewhere; a real exit code never re-runs."""
        self.set_fleet(rr_reattach_backoff_s=[0, 0, 0])     # every reattach drops too
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", "echo x >> %s" % marker, "test:db", FAKE_SSH_DROP_HOSTS="w1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("rrun: w1 went away mid-run (lost connection); re-running once on w2", r.stderr)
        self.assertEqual(self.read(marker), "x\nx\n")
        self.assertEqual(self.target(), "w2")
        # a failing DB test is a failure, not a retry
        os.unlink(marker)
        r = self.rrun("/bin/sh", "-c", "echo x >> %s; exit 3" % marker, "test:db")
        self.assertEqual((r.returncode, self.read(marker)), (3, "x\n"), r.stderr)
        self.assertNotIn("re-running", r.stderr)
        # ... also when the link drops right after the exit code got through (during cleanup)
        os.unlink(marker)
        r = self.rrun("/bin/sh", "-c", "echo x >> %s; exit 3" % marker, "test:db",
                      FAKE_SSH_DROP_HOSTS="w1", FAKE_SSH_KEEP_EXIT="1")
        self.assertEqual((r.returncode, self.read(marker)), (3, "x\n"), r.stderr)
        self.assertIn("dropped after the command finished there (exit 3)", r.stderr)
        # lost twice: once more only, then 75
        os.unlink(marker)
        r = self.rrun("/bin/sh", "-c", "echo x >> %s" % marker, "test:db", FAKE_SSH_DROP_HOSTS="w1,w2")
        self.assertEqual((r.returncode, self.read(marker)), (75, "x\nx\n"), r.stderr)
        self.assertIn("not re-running", r.stderr)
        # a job not known to be repeatable (an arbitrary script) still never re-runs
        os.unlink(marker)
        r = self.rrun("/bin/sh", "-c", "echo x >> %s" % marker, FAKE_SSH_DROP_HOSTS="w1")
        self.assertEqual((r.returncode, self.read(marker)), (75, "x\n"), r.stderr)

    def test_heavy_and_db_jobs_never_fall_back_to_this_machine_in_a_pool(self):
        marker = os.path.join(self.d, "ran")
        for name in ("tsc", "test:db"):
            with self.subTest(job=name):
                r = self.rrun("/bin/sh", "-c", "echo x >> %s" % marker, name, FAKE_SSH_DOWN_HOSTS="w1,w2")
                self.assertEqual(r.returncode, 75, r.stderr)
                self.assertIn("not running a", r.stderr)
                self.assertFalse(os.path.exists(marker))
        r = self.rrun("/bin/sh", "-c", 'echo "mode=$RDOCKER_MODE"', FAKE_SSH_DOWN_HOSTS="w1,w2")
        self.assertEqual((r.returncode, r.stdout), (0, "mode=local\n"), r.stderr)   # normal job: local

    def test_light_job_runs_here_when_every_worker_stays_busy(self):
        self.set_fleet(w1_slots=1, w2_slots=1, rr_local_after_s=1, rr_local_min_free_gb=0)
        self.hold_slot("w1")
        self.hold_slot("w2")
        r = self.rrun("/bin/sh", "-c", 'echo "mode=$RDOCKER_MODE"', "lint")
        self.assertEqual((r.returncode, r.stdout), (0, "mode=local\n"), r.stderr)
        self.assertIn("every worker stayed busy for 1 s", r.stderr)
        self.assertEqual(self.target(), "local")

    def test_where_host_and_single_worker(self):
        r = self.rrun("--where", "npx", "tsc", "--noEmit")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("job class: heavy", r.stdout)
        self.assertRegex(r.stdout, r"\nw1 +w1 +free")
        self.assertIn("pick: w1", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.whome["w1"], "rr", "git")))   # nothing sent
        os.unlink(self.sshlog)
        r = self.rrun("--host", "w2", "/bin/sh", "-c", "echo hi")
        self.assertEqual((r.returncode, r.stdout), (0, "hi\n"), r.stderr)
        self.assertEqual(self.target(), "w2")
        self.assertNotIn("slots_busy", self.read(self.sshlog))   # forced: no probe
        r = self.rrun("--host=nope", "true")
        self.assertEqual(r.returncode, 2)
        self.assertIn("no worker named 'nope'", r.stderr)
        # one enabled worker: no probe, its own name, the classic flow
        write_fleet(self.fleet, [worker("w1"), worker("w2", enabled=False)])
        os.unlink(self.sshlog)
        r = self.rrun("/bin/sh", "-c", "echo hi")
        self.assertEqual((r.returncode, r.stdout), (0, "hi\n"), r.stderr)
        self.assertEqual(self.target(), "w1")
        self.assertNotIn("slots_busy", self.read(self.sshlog))

    def test_share_off_worker_is_skipped_and_a_forced_one_says_why(self):
        os.makedirs(os.path.join(self.whome["w1"], "rr"))
        test_run.wfile(os.path.join(self.whome["w1"], "rr", "share"), "off\n")
        kw = {"RR_SHARE_FILE": ""}                                      # Linux default: ~/rr/share
        r = self.rrun("/bin/sh", "-c", "echo hi", **kw)
        self.assertEqual((r.returncode, r.stdout), (0, "hi\n"), r.stderr)
        self.assertEqual(self.target(), "w2")
        r = self.rrun("--where", "true", **kw)
        self.assertRegex(r.stdout, r"\nw1 +w1 +off ")
        r = self.rrun("--host", "w1", "/bin/sh", "-c", "echo hi", **kw)
        self.assertEqual((r.returncode, r.stdout), (73, ""), r.stderr)
        self.assertIn("w1 is not taking jobs (its owner turned sharing off)", r.stderr)
        # the probe saw w1 sharing, then the owner switched off: its runner refuses, the job moves on
        empty = os.path.join(self.d, "probe-home")
        os.makedirs(empty)
        r = self.rrun("/bin/sh", "-c", "echo hi", FAKE_SSH_PROBE_HOMES="w1=" + empty, **kw)
        self.assertEqual((r.returncode, r.stdout), (0, "hi\n"), r.stderr)
        self.assertIn("w1 is not taking jobs (its owner turned sharing off) - trying w2", r.stderr)

    def test_bench_writes_speed_on_each_worker(self):
        self.set_fleet(rr_bench_iters=2000)
        for n in self.whome:
            os.makedirs(os.path.join(self.whome[n], "rr"))
        r = self.rrun("--bench")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout, r"w1 +[0-9.]+s  speed [0-9.]+\nw2 ")
        for n in self.whome:
            self.assertRegex(self.read(os.path.join(self.whome[n], "rr", "speed")), r"^[0-9.]+\n$")
        # a fresh worker (a new Mac) has no ~/rr yet: the bench makes it (private) and stores the speed
        shutil.rmtree(os.path.join(self.whome["w2"], "rr"))
        self.assertEqual(self.rrun("--bench", "--host", "w2").returncode, 0)
        self.assertRegex(self.read(os.path.join(self.whome["w2"], "rr", "speed")), r"^[0-9.]+\n$")
        self.assertEqual(os.stat(os.path.join(self.whome["w2"], "rr")).st_mode & 0o777, 0o700)
        r = self.rrun("--bench", FAKE_SSH_DOWN_HOSTS="w2")
        self.assertEqual(r.returncode, 1)
        self.assertIn("w2         unreachable", r.stdout)



class Eligibility(PlanUnit):
    """Phase B (2026-11-11): fleet.json classes / max_cost_s / cold_ok are hard - an ineligible
    worker is no candidate at all (not ranked, not a wait host, no shard, no hedge, no warm)."""

    def hist(self, cmd_s, argv, n=3):
        return [[cmd_s, argv]] * n

    def test_class_not_taken_is_never_a_candidate_not_even_the_wait_host(self):
        tsc = rd_pool.classify(["npx", "tsc", "--noEmit"])
        lap = dict(worker("lap", 0.45), classes=["light", "normal", "db"])
        # lap is the only free worker, hp is full: a heavy job still never goes to lap
        p, _ = self.plan([lap, worker("hp", 1.5)], {"lap": probe(), "hp": probe(slots_busy=2)}, job=tsc)
        self.assertEqual(self.names(p), ["hp"])
        self.assertEqual([(h.name, why) for h, why in p.ineligible],
                         [("lap", "takes only light/normal/db jobs (this is heavy)")])
        # ... while a normal job may go there
        p, _ = self.plan([lap, worker("hp", 1.5)], {"lap": probe(), "hp": probe(slots_busy=2)})
        self.assertEqual(self.names(p)[0], "lap")
        self.assertEqual(p.ineligible, [])
        # a down worker is still judged on its class (it is not even "down, try last")
        p, _ = self.plan([lap, worker("hp", 1.5)], {"hp": probe()}, job=tsc)
        self.assertEqual(self.names(p), ["hp"])

    def test_max_cost_uses_the_commands_own_history_at_the_workers_speed(self):
        full = rd_pool.classify(["npx", "vitest", "run"])
        named = rd_pool.classify(["npx", "vitest", "run", "src/a.test.ts"])
        mini = dict(worker("mini", 0.42), max_cost_s=120)
        hist = self.hist(1500.0, "npx vitest run") + self.hist(20.0, "npx vitest run src/a.test.ts")
        ans = {"mini": dict(probe(), hist=hist), "hp": dict(probe(slots_busy=2), hist=hist)}
        p, _ = self.plan([mini, worker("hp", 1.5)], ans, job=full)
        self.assertEqual(self.names(p), ["hp"])
        (h, why), = p.ineligible
        self.assertEqual(h.name, "mini")
        self.assertRegex(why, r"^expected ~\d+m there, over its max_cost_s 120s$")
        p, _ = self.plan([mini, worker("hp", 1.5)], ans, job=named)
        self.assertEqual(self.names(p)[0], "mini")                 # 20 s there: fine

    def test_cold_ok_false_refuses_a_job_whose_packages_are_not_there(self):
        mini = dict(worker("mini", 0.42), cold_ok=False)
        p, _ = self.plan([mini, worker("hp", 1.5)], {"mini": probe(warm_deps=0), "hp": probe(slots_busy=2)})
        self.assertEqual(self.names(p), ["hp"])
        self.assertIn("cold_ok: false", p.ineligible[0][1])
        p, _ = self.plan([mini, worker("hp", 1.5)], {"mini": probe(warm_deps=1), "hp": probe(slots_busy=2)})
        self.assertEqual(self.names(p)[0], "mini")

    def test_no_eligible_worker_at_all_says_why(self):
        tsc = rd_pool.classify(["npx", "tsc", "--noEmit"])
        ms = [dict(worker("a", 1.0), classes=["light"]), dict(worker("b", 0.5), classes=["db", "normal"])]
        p, _ = self.plan(ms, {"a": probe(), "b": probe()}, job=tsc)
        self.assertEqual(p.hosts, [])
        msg = rd_pool.no_eligible_msg(tsc, p.ineligible)
        self.assertIn("no eligible worker for this job (class heavy, expected ~", msg)
        self.assertIn("a takes only light jobs (this is heavy); b takes only db/normal jobs", msg)
        lines = rd_pool.where_report(self.cfg, tsc, p)
        self.assertTrue(lines[-1].startswith("pick: none - no eligible worker"), lines)
        self.assertIn("never", "\n".join(lines))
        # unprobed (--host / one worker): the class rule still holds
        p, m = self.plan(ms, {"a": probe(), "b": probe()}, job=tsc, force="a")
        self.assertEqual((p.hosts, m.call_count), ([], 0))

    def test_no_shard_or_hedge_candidate_is_ever_ineligible(self):
        ms = [worker("w1", 1.0), worker("w2", 1.0), dict(worker("w3", 1.0), classes=["light"])]
        ans = {n: probe() for n in ("w1", "w2", "w3")}
        p, _ = self.plan(ms, ans)
        assign = rd_pool.shard_assign(self.cfg, p, rd_pool.classify(["npx", "vitest", "run"]))
        self.assertTrue(assign)
        self.assertNotIn("w3", [h.name for h in assign])
        self.assertNotIn("w3", self.names(p))

    def test_fleet_fields_validated(self):
        import rd_fleet
        self.assertEqual(set(rd_fleet.JOB_CLASSES), set(rd_pool.NEED_GB))
        good = dict(worker("w", 1.0), classes=["light", "normal"], max_cost_s=120, cold_ok=False)
        doc = {"version": 1, "client_keys": [], "machines": [good]}
        self.assertEqual(rd_fleet.problems(doc), [])
        for bad, want in (({"classes": []}, "classes must be"), ({"classes": ["fast"]}, "classes must be"),
                          ({"classes": ["light", "light"]}, "classes must be"), ({"classes": [1]}, "classes must be"),
                          ({"classes": "light"}, "wrong type"), ({"max_cost_s": 0}, "max_cost_s must be"),
                          ({"max_cost_s": "120"}, "wrong type"), ({"cold_ok": "no"}, "wrong type")):
            with self.subTest(bad=bad):
                doc = {"version": 1, "client_keys": [], "machines": [dict(worker("w", 1.0), **bad)]}
                self.assertTrue([x for x in rd_fleet.problems(doc) if want in x], rd_fleet.problems(doc))

    def test_warm_never_visits_a_cold_ok_false_worker(self):
        import rd_warm
        hs = [rd_pool.host_for(self.cfg, dict(worker("a", 1.0), cold_ok=False)),
              rd_pool.host_for(self.cfg, worker("b", 1.0))]
        self.assertEqual([h.name for h in hs if rd_warm.warmable(h)], ["b"])


class EligibilityE2E(test_run.RunBase):
    def test_no_eligible_worker_exits_75_at_once_and_runs_nothing(self):
        fleet = os.path.join(self.d, "fleet.json")
        write_fleet(fleet, [dict(worker("w1", 1.0), classes=["light"]), dict(worker("w2", 0.5), classes=["db"])])
        self.write_cfg(fleet_path=fleet)
        marker = os.path.join(self.d, "ran")
        t0 = time.time()
        r = self.rrun("/bin/sh", "-c", "echo x > %s; tsc" % marker, RRUN_RECONNECT_WAIT="0")
        self.assertEqual(r.returncode, 75, r.stderr)
        self.assertLess(time.time() - t0, 30)
        self.assertIn("no eligible worker for this job (class heavy", r.stderr)
        self.assertIn("w1 takes only light jobs (this is heavy); w2 takes only db jobs", r.stderr)
        self.assertIn("not running it (exit 75)", r.stderr)
        self.assertFalse(os.path.exists(marker))
        self.assertNotIn("rrun-runner", self.read(self.sshlog))      # probes only, no runner session


for _n in [n for n in vars(PlanUnit) if n.startswith("test")]:
    setattr(Eligibility, _n, None)    # PlanUnit's fixture, not its tests


if __name__ == "__main__":
    unittest.main()
