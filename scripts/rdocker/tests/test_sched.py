"""rd_pool's finish-time scheduler (eta), vitest sharding across workers, hedged duplicates and
dynamic membership; plus rd_run's shard / hedge runners end to end against a two-worker fleet
(the fake ssh of tests/test_run.py gives each worker its own HOME)."""
import fcntl
import io
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
import test_pool  # noqa: E402  (helpers + fixtures; its TestCases are not re-collected here)
import test_run  # noqa: E402

import rd_pool  # noqa: E402

rd_run = rdmods.owner("rrun")
rd_common = rdmods.owner("RRUN_STATE")
worker, probe, write_fleet = test_pool.worker, test_pool.probe, test_pool.write_fleet


def ev(sig=(), kind=(0, None), pk=None, rows=(), all=(0, None)):
    """A probe's runs.log evidence (rd_pool PROBE "ev")."""
    return {"sig": list(sig), "kind": list(kind), "pk": pk or {}, "rows": [list(r) for r in rows], "all": list(all)}
VITEST = rd_pool.classify(["npx", "vitest", "run"])
TSC = rd_pool.classify(["npx", "tsc", "--noEmit"])
LINT = rd_pool.classify(["npm", "run", "lint"])


class Eta(unittest.TestCase):
    setUp = test_pool.PlanUnit.setUp
    plan = test_pool.PlanUnit.plan

    def names(self, p):
        return [h.name for h in p.hosts]

    def test_eta_is_setup_plus_queue_plus_run_plus_rtt_plus_risk(self):
        # no evidence anywhere: the class default at bench speed, the default warm setup + no mirror
        p, _ = self.plan([worker("a", 2.0), worker("b")], {"a": probe(warm_git=0, ncpu=8)}, job=VITEST)
        a = p.hosts[0]
        self.assertEqual((a.name, a.state, a.src), ("a", "free", "default"))
        self.assertAlmostEqual(a.setup_s, rd_pool.WARM_SETUP_S + rd_pool.COLD_GIT_S)
        self.assertAlmostEqual(a.run_s, 60.0 / 2.0)                     # vitest 60 s at speed 1
        self.assertAlmostEqual(a.p_infra, rd_pool.PRIOR_P)               # no runs yet: the prior
        # risk = p_infra x (setup + run/2 lost + a rerun on the best other: none here, so itself)
        base = a.setup_s + 30 + 0.01
        self.assertAlmostEqual(a.risk_s, rd_pool.PRIOR_P * (a.setup_s + 15 + base))
        self.assertAlmostEqual(a.eta, base + a.risk_s)
        p, _ = self.plan([worker("a", 2.0), worker("b")], {"a": probe(warm_deps=0, ncpu=8)}, job=LINT)
        self.assertAlmostEqual(p.hosts[0].setup_s, rd_pool.COLD_DEPS_S)
        cfg = dict(self.cfg, rr_job_cost_s={"light": 6})                # config overrides the default
        self.assertEqual(rd_pool.default_cost(cfg, "light"), 6.0)
        self.assertEqual(rd_pool.default_cost({}, "db"), 120.0)
        self.assertEqual(rd_pool.default_cost({}, "build"), 90.0)

    def test_memory_headroom_is_penalised_heavily(self):
        self.assertAlmostEqual(rd_pool.mem_factor(6 * 1024, 6), 0.1)
        self.assertEqual(rd_pool.mem_factor(9 * 1024, 6), 1.0)
        self.assertEqual(rd_pool.mem_factor(None, 6), 1.0)
        xs = [rd_pool.mem_factor(mb, 6) for mb in range(6144, 9300, 300)]
        self.assertEqual(xs, sorted(xs))
        # cpu: all the cores the job wants are idle -> 1; an oversubscribed box -> its slice
        self.assertEqual(rd_pool.cpu_share(0, 8, "normal"), 1.0)
        self.assertAlmostEqual(rd_pool.cpu_share(8, 4, "normal"), 1 / 3.0)

    def real_fleet(self):
        return [worker("nickmbp", 3.0, max_slots=8, heavy_slots=6, mem_gb=64),
                worker("hp", 1.19, max_slots=4, heavy_slots=1, mem_gb=8),
                worker("laptop", 0.45, max_slots=4, heavy_slots=1, mem_gb=8)]

    def test_tsc_queues_on_nickmbp_rather_than_swapping_on_hp(self):
        nick = probe(slots_cap=8, slots_busy=6, heavy_cap=6, heavy_busy=6, mem_mb=40000, ncpu=18)
        hp = probe(slots_cap=4, mem_mb=6600, ncpu=4)                     # 6.4 GB: barely above 6
        lap = probe(slots_cap=4, mem_mb=7000, ncpu=6)
        p, _ = self.plan(self.real_fleet(), {"nickmbp": dict(nick, ages=[5, 50, 50, 50, 50, 50]), "hp": hp,
                                        "laptop": lap}, job=TSC)
        self.assertEqual(self.names(p), ["nickmbp", "hp", "laptop"])
        n, h = p.hosts[0], p.hosts[1]
        self.assertIs(p.promoted, n)
        self.assertEqual(n.state, "busy")
        self.assertGreater(h.run_s, 10 * n.run_s)                         # hp would swap
        self.assertTrue(n.short)                                          # waits only while it pays
        self.assertAlmostEqual(n.cfg["rr_wait_min"] * 60, h.eta - (n.eta - n.queue_s), places=3)
        lines = rd_pool.where_report(self.cfg, TSC, p)
        self.assertRegex("\n".join(lines), r"worker .* eta +share")
        self.assertIn("pick: nickmbp (busy, but its eta beats every free worker", lines[-1])
        # promotion off: free first, as before
        self.cfg["rr_queue_promote_ratio"] = 0
        p, _ = self.plan(self.real_fleet(), {"nickmbp": nick, "hp": hp, "laptop": lap}, job=TSC)
        self.assertEqual(self.names(p)[:2], ["hp", "laptop"])
        self.assertIsNone(p.promoted)

    def test_quick_lint_spreads_to_the_idle_laptop(self):
        nick = probe(slots_cap=8, slots_busy=8, mem_mb=40000, ncpu=18, load=8)
        p, _ = self.plan(self.real_fleet(), {"nickmbp": dict(nick, ages=[1] * 8),
                                        "laptop": probe(slots_cap=4, mem_mb=7000, ncpu=6)}, job=LINT)
        self.assertEqual(self.names(p), ["laptop", "nickmbp", "hp"])     # free, busy, down
        self.assertIsNone(p.promoted)
        self.assertTrue(p.hosts[0].short)

    def test_evidence_sets_run_setup_and_risk(self):
        """2026-11-11 (owner: "true to how it would actually come out"): every number from runs.log."""
        # 1. own median of the exact command (>= 3 completed runs)
        p, _ = self.plan([worker("a", 1.0), worker("b", 1.0)],
                         {"a": dict(probe(), ev=ev(sig=[300, 310, 290])), "b": probe()}, job=TSC)
        a, b = sorted(p.hosts, key=lambda h: h.name)
        self.assertEqual((a.run_s, a.src), (300, "own"))
        # 2. b never ran it: the pool's median x b's ratio (bench-calibrated: same speed -> same)
        self.assertEqual((b.run_s, b.src), (300, "pool"))
        # a ratio LEARNED from paired commands beats the bench: b ran 4 commands a ran too, 3x slower
        pk_a = {"k%d" % i: [3, 10.0 * (i + 1)] for i in range(4)}
        pk_b = {"k%d" % i: [3, 30.0 * (i + 1)] for i in range(4)}
        p, _ = self.plan([worker("a", 1.0), worker("b", 5.0)],             # b's bench says FAST
                         {"a": dict(probe(), ev=ev(sig=[300] * 3, pk=pk_a)), "b": dict(probe(), ev=ev(pk=pk_b))},
                         job=TSC)
        a, b = sorted(p.hosts, key=lambda h: h.name)
        self.assertEqual(b.src, "pool")
        self.assertAlmostEqual(b.run_s, 900.0)                            # 300 x (1.5 / 0.5)
        self.assertEqual(self.names(p), ["a", "b"])
        # 3. nobody ran it: the kind's median there, else the pool's x ratio, else the default
        p, _ = self.plan([worker("a", 1.0), worker("b", 1.0)],
                         {"a": dict(probe(), ev=ev(kind=[5, 80.0])), "b": probe()}, job=TSC)
        a, b = sorted(p.hosts, key=lambda h: h.name)
        self.assertEqual(((a.run_s, a.src), (b.run_s, b.src)), ((80.0, "kind"), (80.0, "pool-kind")))
        # setup: the measured p75 of warm / cold prepares there
        rows = [["pass", 0.5, 0], ["pass", 0.7, 0], ["fail", 0.9, 0], ["pass", 400.0, 1], ["aband", 600.0, 1],
                ["warm", 500.0, 1], ["busy", None, None]]
        p, _ = self.plan([worker("a", 1.0)] * 1 + [worker("b", 1.0)],
                         {"a": dict(probe(), ev=ev(rows=rows)), "b": dict(probe(warm_deps=0), ev=ev(rows=rows))},
                         job=TSC)
        a, b = sorted(p.hosts + [h for h, _ in p.ineligible], key=lambda h: h.name)
        self.assertEqual(a.setup_s, 0.9)                                  # warm p75 of 0.5 / 0.7 / 0.9
        self.assertEqual(rd_pool.cold_p75(b), 600.0)                      # cold: abandoned ones count too
        # risk: an unreliable worker loses only when it costs; p_infra over fair starts, with a prior
        flaky = [["infra", 1.0, 0]] * 10 + [["pass", 1.0, 0]] * 10 + [["moved", None, None]] * 50
        h = rd_pool.Host("x", {}, {})
        h.probe = {"ev": ev(rows=flaky)}
        self.assertAlmostEqual(rd_pool.p_infra(h), (10 + 0.9) / (20 + 30))   # moved / busy never count
        p, _ = self.plan([worker("a", 1.0), worker("b", 1.0)],
                         {"a": dict(probe(), ev=ev(sig=[100] * 3, rows=flaky)), "b": dict(probe(), ev=ev(sig=[100] * 3))},
                         job=TSC)
        self.assertEqual(self.names(p), ["b", "a"])
        self.assertGreater(p.hosts[1].risk_s, 30)

    def test_measured_cold_setup_makes_a_worker_warm_only(self):
        """b2 (owner: "make the system dynamic"): no fleet cold_ok -> eligibility from the measured
        cold-setup p75 vs rr_cold_budget_s; cold_ok stays a manual override; never nowhere to go."""
        slow = [["pass", 400.0, 1]] * 4
        fast = [["pass", 20.0, 1]] * 4
        ans = {"mini": dict(probe(warm_deps=0), ev=ev(rows=slow)), "hp": dict(probe(warm_deps=0), ev=ev(rows=fast))}
        p, _ = self.plan([worker("mini", 2.0), worker("hp", 1.0)], ans, job=TSC)
        self.assertEqual(self.names(p), ["hp"])
        self.assertIn("measured cold setup is ~400s (p75; rr_cold_budget_s 60s): warm jobs only", p.ineligible[0][1])
        p, _ = self.plan([worker("mini", 2.0), worker("hp", 1.0)],
                         dict(ans, mini=dict(ans["mini"], warm_deps=1)), job=TSC)   # warm: takes it
        self.assertEqual(p.ineligible, [])
        self.cfg["rr_cold_budget_s"] = 500                               # a looser budget: cold is fine
        p, _ = self.plan([worker("mini", 2.0), worker("hp", 1.0)], ans, job=TSC)
        self.assertEqual(p.ineligible, [])
        self.cfg["rr_cold_budget_s"] = 60
        p, _ = self.plan([dict(worker("mini", 2.0), cold_ok=True), worker("hp", 1.0)], ans, job=TSC)
        self.assertEqual(p.ineligible, [])                                # manual override: yes
        # every worker slow cold: the fastest-measured one still takes it (never "nowhere to go")
        p, _ = self.plan([worker("mini", 2.0), worker("hp", 1.0)],
                         dict(ans, hp=dict(ans["hp"], ev=ev(rows=[["pass", 300.0, 1]] * 4))), job=TSC)
        self.assertEqual(self.names(p), ["hp"])
        self.assertEqual([h.name for h, _ in p.ineligible], ["mini"])

    def test_history_since_and_window_go_to_the_probe(self):
        reqs = {}

        def fake(host, req, timeout):
            reqs[host.name] = req
            return dict(probe()), 0.01
        write_fleet(self.fleet, [dict(worker("a", 1.0), history_since=1762800000), worker("b", 1.0)])
        with mock.patch.object(rd_pool, "probe_one", side_effect=fake):
            rd_pool.plan(self.cfg, TSC)
        self.assertEqual(reqs["a"]["since"], 1762800000)
        self.assertNotIn("since", reqs["b"])
        self.assertEqual((reqs["a"]["days"], reqs["a"]["rows"], reqs["a"]["kind"], reqs["a"]["sig"]),
                         (14, 300, "tsc", "npx tsc --noEmit"))
        self.assertEqual(reqs["a"]["kinds"], [list(k) for k in rd_pool.KINDS])

    def test_same_command_history_beats_the_class_median(self):
        """2026-11-11: a whole `npx vitest run` ran 66-80 min on the free, slow rd-mini-a (speed 0.42)
        because it was costed like the one-file vitest runs. The SAME command's evidence (here: the
        fast worker's one run) sets the cost on every worker, so the slow free worker loses to a
        faster busy one whose holder ends sooner (wait for it: promote when its eta <= 0.5x)."""
        fast = dict(probe(slots_cap=1, slots_busy=1, ncpu=8), ages=[100],
                    jobs=[{"cmd": "npx tsc --noEmit", "start": time.time() - 100}])
        p, _ = self.plan([worker("mini-a", 0.42), worker("fast", 2.0)],
                         {"mini-a": dict(probe(ncpu=4), ev=ev()), "fast": dict(fast, ev=ev(sig=[1200]))},
                         job=VITEST)
        a = next(h for h in p.hosts if h.name == "mini-a")
        f = next(h for h in p.hosts if h.name == "fast")
        self.assertAlmostEqual(f.pred_s, 1200)
        self.assertAlmostEqual(a.pred_s, 1200 * 2.0 / 0.42)                # bench-calibrated ratio
        self.assertEqual(self.names(p)[0], "fast")
        self.assertIs(p.promoted, f)
        self.assertLessEqual(f.eta, rd_pool.PROMOTE_RATIO * a.eta)
        # a one-file run still goes to the free worker: the busy one is not 2x better
        one = rd_pool.classify(["npx", "vitest", "run", "src/a.test.ts"])
        p, _ = self.plan([worker("mini-a", 0.42), worker("fast", 2.0)],
                         {"mini-a": dict(probe(ncpu=4), ev=ev(sig=[30] * 6)), "fast": dict(fast, ev=ev(sig=[30] * 6))},
                         job=one)
        self.assertEqual(self.names(p)[0], "mini-a")
        self.assertIsNone(p.promoted)
        self.assertEqual(rd_pool.run_sig(["env", "TOK=s", "npx", "-e", "x", "a\tb"]),
                         "env TOK=<redacted> npx -e <redacted> a b")

    def test_holder_with_known_command_sets_the_queue(self):
        """A busy worker's queue = when its holder's own command (slots/<i>.own) should end."""
        busy = dict(probe(slots_cap=1, slots_busy=1, ncpu=8), ages=[100], ev=ev(all=[8, 10.0]),
                    jobs=[{"cmd": "npx vitest run", "start": time.time() - 100, "med": 1000}])
        p, _ = self.plan([worker("a", 1.0), worker("b", 1.0)], {"a": busy}, job=LINT)
        a = next(h for h in p.hosts if h.name == "a")
        self.assertAlmostEqual(a.queue_s, 900, delta=5)

    def test_wait_lines_carry_position_and_eta(self):
        sess = rd_run.Session({"rr_wait_min": 30}, [], "0" * 32, rd_run.Timing(False))
        sess.host_name, sess.wait_eta_s = "hp", 300
        err = io.StringIO()
        with mock.patch.object(sys, "stderr", err):
            sess.on_status("WAIT holder=dentall.1 age=120 busy=4 slots=4 ahead=2 howner=billing")
            sess.wait_since -= 120
            sess.on_status("WAIT holder=dentall.1 age=240 busy=4 slots=4 ahead=0 gate=heavy")
        a, b = err.getvalue().splitlines()
        self.assertEqual(a, "rrun: waiting for a slot on hp: 4 of 4 slots busy; held longest by dentall.1 "
                            "(billing) for 120s; 2 other runs waiting ahead of this one; expected wait ~5 min; "
                            "tries elsewhere after 2 min")
        # later lines are short: no repeated banner (agent contract)
        self.assertEqual(b, "rrun: still waiting for a slot on hp (2 min so far; next in line; expected wait ~3 min)")

    def test_an_overloaded_worker_is_held_off_not_piled_on(self):
        """2026-11-10: the WSL laptop (8 threads, 4 slots) reached load1 19 while still taking jobs.
        load1 / ncpu >= 1.5 => busy (after every free worker), its run estimate x load/ncpu."""
        lap = probe(slots_cap=4, mem_mb=7000, ncpu=8, load=19.0)
        hp = probe(slots_cap=4, mem_mb=7000, ncpu=4, load=1.0)
        p, _ = self.plan([worker("laptop", 2.0), worker("hp", 0.5)], {"laptop": lap, "hp": hp}, job=VITEST)
        self.assertEqual(self.names(p), ["hp", "laptop"])
        a = p.hosts[1]
        self.assertTrue(a.overloaded)
        self.assertEqual((a.state, a.queue_s), ("busy", 0.0))
        base = 60.0 / (2.0 * rd_pool.cpu_share(19.0, 8, "normal"))
        self.assertAlmostEqual(a.run_s, base * 19.0 / 8)                 # compute grows with the overload
        self.assertIn("(overloaded: held off)", "\n".join(rd_pool.where_report(self.cfg, VITEST, p)))
        # just under the line: still free; the ratio is configurable, 0 = off
        p, _ = self.plan([worker("laptop", 2.0), worker("hp", 0.5)],
                         {"laptop": dict(lap, load1=11.9), "hp": hp}, job=VITEST)
        self.assertEqual((p.hosts[0].name, p.hosts[0].state, p.hosts[0].overloaded), ("laptop", "free", False))
        self.cfg["rr_overload_ratio"] = 0
        p, _ = self.plan([worker("laptop", 2.0), worker("hp", 0.5)], {"laptop": lap, "hp": hp}, job=VITEST)
        self.assertEqual(p.hosts[0].name, "laptop")
        # the only worker left: an overloaded one still takes the job (it queues there, never local)
        self.cfg["rr_overload_ratio"] = 1.5
        p, _ = self.plan([worker("laptop", 2.0), worker("hp", 0.5)], {"laptop": lap}, job=TSC)
        self.assertEqual((p.hosts[0].name, p.hosts[0].state), ("laptop", "busy"))

    def test_membership_is_fresh_every_plan(self):
        ms = [worker("a", 1.0), worker("b", 2.0)]
        p, _ = self.plan(ms, {"a": probe()})                              # b vanished (mid-probe)
        self.assertEqual([(h.name, h.state) for h in p.hosts], [("a", "free"), ("b", "down")])
        p, _ = self.plan(ms, {"a": probe(), "b": probe()})                # back: no memory of "down"
        self.assertEqual(self.names(p), ["b", "a"])
        p, _ = self.plan(ms + [worker("c", 4.0)], {"a": probe(), "b": probe(), "c": probe()})
        self.assertEqual(self.names(p), ["c", "b", "a"])                  # a new worker, used at once

        def flaky(host, req, timeout):
            if host.cfg["host"] == "b":                                  # timed out mid-probe
                return None, "no answer in %.1f s" % timeout
            return dict(probe()), 0.01
        write_fleet(self.fleet, ms)
        with mock.patch.object(rd_pool, "probe_one", side_effect=flaky):
            p = rd_pool.plan(self.cfg, VITEST)
        self.assertEqual([(h.name, h.state) for h in p.hosts], [("a", "free"), ("b", "down")])
        self.assertIn("no answer", p.hosts[1].why)


class ProbeExtras(unittest.TestCase):
    setUp, run_probe = test_pool.ProbeSnippet.setUp, test_pool.ProbeSnippet.run_probe

    def test_jobs_from_own_files_of_held_slots_only(self):
        fh = open(os.path.join(self.root, "slots", "1"), "a")
        fcntl.flock(fh, fcntl.LOCK_EX)
        self.addCleanup(fh.close)
        sl = os.path.join(self.root, "slots")
        test_run.wfile(os.path.join(sl, "1.who"), "app.1 100 4242 abcdef012345\n")
        test_run.wfile(os.path.join(sl, "1.own"), "id=session:s1\tname=win a\tclient=mac\tstart=100\tpid=4242\tcmd=npx tsc\n")
        test_run.wfile(os.path.join(sl, "0.who"), "app.1 100 7 abcdef012345\n")              # not held
        test_run.wfile(os.path.join(sl, "0.own"), "id=session:old\tstart=1\tpid=7\tcmd=x\n")
        o = self.run_probe({"slots": 2})
        self.assertEqual(o["jobs"], [{"id": "session:s1", "name": "win a", "client": "mac", "start": 100,
                                      "pid": "4242", "cmd": "npx tsc", "slot": 1}])
        test_run.wfile(os.path.join(sl, "1.who"), "app.1 100 5555 abcdef012345\n")           # a new holder
        self.assertEqual(self.run_probe({"slots": 2})["jobs"], [])

    def test_holder_ages(self):
        fh = open(os.path.join(self.root, "slots", "1"), "a")
        fcntl.flock(fh, fcntl.LOCK_EX)
        self.addCleanup(fh.close)
        test_run.wfile(os.path.join(self.root, "slots", "1.who"), "app.1 %d 123 abcdef012345\n" % (time.time() - 30))
        test_run.wfile(os.path.join(self.root, "slots", "0.who"), "app.1 1 1 abcdef012345\n")   # not held
        o = self.run_probe({"slots": 2})
        self.assertEqual(o["slots_busy"], 1)
        self.assertEqual(len(o["ages"]), 1)
        self.assertTrue(28 <= o["ages"][0] <= 40, o["ages"])
        self.assertNotIn("ev", o)                                         # no kinds asked: no evidence

    def evreq(self, **kw):
        return dict({"slots": 2, "sig": "npx tsc --noEmit", "kind": "tsc",
                     "kinds": [list(k) for k in rd_pool.KINDS], "now": NOW}, **kw)

    def test_runs_log_evidence(self):
        """The worker parses its own runs.log: offsets honoured, truthful labels, windows, kinds."""
        def line(t, out, prep, cmd, argv, tail=""):
            return "%s repo=a wt=b sha=c outcome=%s prepare_s=%s cmd_s=%s argv=%s%s\n" % (t, out, prep, cmd, argv, tail)
        # NOW = 2026-11-11T12:00:00Z; the same instant written in three time zones
        log = "junk\n" + "".join([
            line("2026-11-11T05:00:00-0700", "rc=0", "0.5", "100.0", "npx tsc --noEmit"),
            line("2026-11-11T04:00:00-0800", "rc=1", "0.7", "120.0", "npx tsc --noEmit [cpu_share=2 --maxWorkers]"),
            line("2026-11-11T12:00:00+0000", "rc=0", "20.0", "140.0", "npx tsc --noEmit",
                 "\trun=x owner=- cls=heavy wait_s=0 exit_reason=pass setup=warm pred_s=100 client=- pv=1"),
            line("2026-11-11T11:00:00+0000", "rc=2", "1.0", "5.0", "npx tsc --noEmit"),    # not timing: rc 2
            line("2026-11-11T11:00:00+0000", "lost", "999.0", "-", "npx tsc --noEmit"),    # old pre-GO label
            line("2026-11-11T11:00:00+0000", "lost rc=255", "1.0", "50.0", "x"),           # really lost
            line("2026-11-11T11:00:00+0000", "rc=0", "1.0", "30.0", "npx tsc -p server --noEmit"),
            line("2026-11-11T11:00:00+0000", "rc=0", "1.0", "9.0", "npm run lint"),
            line("2026-11-11T13:00:00+0000", "rc=0", "1.0", "1.0", "npx tsc --noEmit"),    # future: out
            line("2026-10-01T11:00:00+0000", "rc=0", "1.0", "1.0", "npx tsc --noEmit"),    # > 14 days: out
        ])
        test_run.wfile(os.path.join(self.root, "log", "runs.log"), log)
        e = self.run_probe(self.evreq())["ev"]
        self.assertEqual(e["sig"], [100, 120, 140])
        self.assertEqual([r[0] for r in e["rows"]], ["pass", "fail", "pass", "fail", "aband", "infra", "pass", "pass"])
        self.assertEqual(e["rows"][2], ["pass", 20, 0])                   # setup=warm beats the 15 s guess
        self.assertEqual(e["rows"][4], ["aband", 999, 1])
        self.assertEqual(e["kind"], [4, 110])                             # tsc kind: 100 120 140 30
        self.assertEqual(e["pk"][rd_pool.sig_key("npx tsc --noEmit")], [3, 120])
        self.assertNotIn(rd_pool.sig_key("npm run lint"), e["pk"])        # another kind
        self.assertEqual(e["all"], [5, 100])
        # history_since cuts the older rows; rows caps the rate window
        e = self.run_probe(self.evreq(since=NOW - 3600))["ev"]
        self.assertEqual(e["sig"], [100, 120, 140])
        e = self.run_probe(self.evreq(since=NOW - 1800, rows=2))["ev"]      # the 11:00Z rows: out
        self.assertEqual((e["sig"], len(e["rows"]), e["all"]), ([100, 120, 140], 2, [3, 120]))
        # a running job's own median (queue estimate)
        fh = open(os.path.join(self.root, "slots", "0"), "a")
        fcntl.flock(fh, fcntl.LOCK_EX)
        self.addCleanup(fh.close)
        test_run.wfile(os.path.join(self.root, "slots", "0.who"), "app.1 100 4242 abcdef012345\n")
        test_run.wfile(os.path.join(self.root, "slots", "0.own"), "id=s\tstart=100\tpid=4242\tcmd=npx tsc --noEmit\n")
        self.assertEqual(self.run_probe(self.evreq())["jobs"][0]["med"], 120)
        # never through a symlink
        os.unlink(os.path.join(self.root, "log", "runs.log"))
        os.symlink(os.path.join(self.d, "elsewhere"), os.path.join(self.root, "log", "runs.log"))
        self.assertEqual(self.run_probe(self.evreq())["ev"]["rows"], [])

    def test_pool_version(self):
        self.assertEqual(self.run_probe({"slots": 1})["pool_version"], 0)
        test_run.wfile(os.path.join(self.root, "pool_version"), "3\n")
        self.assertEqual(self.run_probe({"slots": 1})["pool_version"], 3)


NOW = 1794398400      # 2026-11-11T12:00:00Z


def fake_host(name, run, eta=None, setup=0.0, free=8, state="free"):
    h = rd_pool.Host(name, {"host": name}, {"speed": 1.0})
    h.probe = {"slots_cap": free, "slots_busy": 0}
    h.state, h.run_s, h.setup_s, h.rtt = state, run, setup, 0.01
    h.eta = run + setup if eta is None else eta
    return h


class Shards(unittest.TestCase):
    def test_shardable(self):
        d = tempfile.mkdtemp(dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, d, True)
        os.makedirs(os.path.join(d, "server"))
        table = [
            (["npx", "vitest", "run"], True),
            (["vitest", "run", "src/"], True),
            (["vitest", "run", "server"], True),                         # an existing dir
            (["vitest", "run", "src/**/*.test.ts"], True),
            (["vitest", "run", "--project", "server", "--reporter=dot"], True),
            (["vitest", "run", "a.test.ts"], False),                      # named files: small
            (["vitest", "run", "user"], False),                           # a name filter
            (["vitest", "run", "--watch"], False), (["vitest", "run", "-w"], False),
            (["vitest", "run", "--coverage"], False), (["vitest", "run", "--coverage.enabled=true"], False),
            (["vitest", "run", "--shard=1/2"], False), (["vitest", "run", "--reporter=json"], False),
            (["vitest", "run", "--reporter", "junit"], False), (["vitest", "run", "--outputFile=r.json"], False),
            (["vitest", "run", "--ui"], False), (["vitest"], False), (["npx", "vitest", "a.ts"], False),
            (["npm", "run", "test"], False),
        ]
        for argv, want in table:
            with self.subTest(argv=argv):
                self.assertEqual(rd_pool.shardable(argv, VITEST, d)[0], want)
        db = rd_pool.classify(["npx", "vitest", "run", "test:db"])
        self.assertEqual(rd_pool.shardable(["npx", "vitest", "run"], db)[0], False)
        self.assertTrue(rd_pool.shardable(["vitest", "run", "a.test.ts"], VITEST, forced=True)[0])
        self.assertFalse(rd_pool.shardable(["vitest", "run", "--watch"], VITEST, forced=True)[0])
        self.assertEqual(rd_run.shard_argv(["npx", "vitest", "run", "--", "x/"], 2, 5),
                         ["npx", "vitest", "run", "--shard=2/5", "--", "x/"])

    def test_mode(self):
        self.assertEqual(rd_pool.shard_mode({}, {}), "auto")
        self.assertEqual(rd_pool.shard_mode({}, {"RRUN_SHARD": "0"}), 0)
        self.assertEqual(rd_pool.shard_mode({}, {"RRUN_SHARD": "1"}), 0)
        self.assertEqual(rd_pool.shard_mode({}, {"RRUN_SHARD": "4"}), 4)
        self.assertEqual(rd_pool.shard_mode({"rr_shard": False}, {}), 0)

    def plan(self, *hosts):
        p = rd_pool.Plan(list(hosts), True)
        return p

    def test_shares_follow_the_predicted_rate(self):
        """2026-11-11: a laptop shard hit the 30-min cap - shares are by PREDICTED rate (the
        evidence's run time there), and a worker whose shard would take > 2x the fastest's gets none."""
        n, h, lap = fake_host("nickmbp", 40), fake_host("hp", 60), fake_host("laptop", 100)
        got = rd_pool.shard_assign({}, self.plan(n, h, lap), VITEST)
        self.assertEqual([x.name for x in got], ["nickmbp", "nickmbp", "hp"])   # laptop: 2.5x the fastest
        lap.run_s = 80                                                    # exactly 2x: takes one
        got = rd_pool.shard_assign({}, self.plan(n, h, lap), VITEST)
        self.assertEqual(sorted(x.name for x in got), ["hp", "laptop", "nickmbp", "nickmbp"])
        # a worker whose setup alone outlasts the best one's whole run is left out
        lap.setup_s = 120
        self.assertNotIn("laptop", [x.name for x in rd_pool.shard_assign({}, self.plan(n, h, lap), VITEST)])
        # never more shards on a worker than it has free slots; at most rr_shard_max in all
        fast, slow = fake_host("fast", 10), fake_host("slow", 15)
        fast.probe["slots_cap"] = 2
        self.assertEqual([x.name for x in rd_pool.shard_assign({}, self.plan(fast, slow), VITEST)],
                         ["fast", "fast", "slow"])
        hs = [fake_host(x, 10) for x in "abc"]
        self.assertEqual(len(rd_pool.shard_assign({}, self.plan(*hs), VITEST)), 3)
        self.assertEqual(len(rd_pool.shard_assign({"rr_shard_max": 2}, self.plan(*hs), VITEST)), 2)
        n = fake_host("nickmbp", 12)
        # one free worker (the rest busy / down): no auto shards; not a pool: never
        busy = fake_host("hp", 60, state="busy")
        self.assertIsNone(rd_pool.shard_assign({}, self.plan(n, busy), VITEST))
        self.assertIsNone(rd_pool.shard_assign({}, rd_pool.Plan([n, h], False), VITEST))

    def test_forced_n(self):
        n, h, lap = fake_host("nickmbp", 40), fake_host("hp", 60), fake_host("laptop", 140)
        self.assertEqual([x.name for x in rd_pool.shard_assign({}, self.plan(n, h, lap), VITEST, 2)],
                         ["nickmbp", "hp"])
        self.assertEqual(sorted(x.name for x in rd_pool.shard_assign({}, self.plan(n, h), VITEST, 4)),
                         ["hp", "nickmbp", "nickmbp", "nickmbp"])
        busy = fake_host("hp", 60, state="busy")
        self.assertEqual([x.name for x in rd_pool.shard_assign({}, self.plan(n, busy), VITEST, 3)],
                         ["nickmbp"] * 3)

    def test_shards_false_worker_never_gets_a_shard(self):
        n, h, mini = fake_host("nickmbp", 40), fake_host("hp", 60), fake_host("mini-a", 30)
        mini.entry = {"speed": 2.0, "shards": False}
        self.assertFalse(rd_pool.takes_shards(mini))
        self.assertTrue(rd_pool.takes_shards(n))                          # no field = takes shards
        got = rd_pool.shard_assign({}, self.plan(mini, n, h), VITEST)
        self.assertNotIn("mini-a", [x.name for x in got])
        self.assertNotIn("mini-a", [x.name for x in rd_pool.shard_assign({}, self.plan(mini, n, h), VITEST, 4)])
        # only the no-shards worker and one other free: no auto split; forced n stays off it
        self.assertIsNone(rd_pool.shard_assign({}, self.plan(mini, n), VITEST))
        self.assertEqual({x.name for x in rd_pool.shard_assign({}, self.plan(mini, n), VITEST, 2)}, {"nickmbp"})
        self.assertIsNone(rd_pool.shard_assign({}, self.plan(mini), VITEST, 2))

    def test_summary_merge(self):
        a = "x\n Test Files  2 passed (2)\n      Tests  4 passed | 1 skipped (5)\n   Duration  1s\n"
        b = ("\x1b[31m Test Files  \x1b[1m1 failed\x1b[22m | 1 passed (2)\x1b[39m\n"
             "      Tests  1 failed | 3 passed (4)\n")
        self.assertEqual(rd_pool.shard_summary([a, b, "no summary"]),
                         [" Test Files  1 failed | 3 passed (4)",
                          "      Tests  1 failed | 7 passed | 1 skipped (9)"])
        self.assertEqual(rd_pool.shard_summary(["nothing"]), [])


class SinkUnit(unittest.TestCase):
    def test_prefix_partial_lines_hold_release_tail(self):
        buf = io.BytesIO()
        s = rd_run.Sink(buf, "[shard 1/2 w1] ")
        s.write(b"ab")
        self.assertEqual(buf.getvalue(), b"")                             # half a line: held
        s.write(b"c\nde\nf")
        self.assertEqual(buf.getvalue(), b"[shard 1/2 w1] abc\n[shard 1/2 w1] de\n")
        s.close()
        self.assertTrue(buf.getvalue().endswith(b"[shard 1/2 w1] f\n"))
        self.assertEqual(s.tail, b"abc\nde\nf")
        buf = io.BytesIO()
        h = rd_run.Sink(buf, "", hold=True)
        h.write(b"one\n")
        h.write(b"two")
        self.assertEqual(buf.getvalue(), b"")
        h.release()
        self.assertEqual(buf.getvalue(), b"one\ntwo")


class HedgeUnit(unittest.TestCase):
    def ctx(self, job, pool=True, cfg=None):
        return rd_run.Ctx(cfg or {}, {"wt12": "0" * 12}, {}, rd_run.Timing(False), 0, job,
                          rd_pool.Plan([], pool), (), [])

    def test_only_idempotent_jobs_only_when_enabled(self):
        build = rd_pool.classify(["npm", "run", "build"], ["dist"])
        db = rd_pool.classify(["npm", "run", "test:db"])
        check = rd_pool.classify(["npm", "run", "check:x"])
        self.assertFalse(rd_run.hedge_on(self.ctx(TSC), {}))                    # default off
        self.assertTrue(rd_run.hedge_on(self.ctx(TSC, cfg={"rr_hedge": True}), {}))
        on = {"RRUN_HEDGE": "1"}
        for job, want in ((TSC, True), (LINT, True), (VITEST, True), (build, False), (db, False),
                          (check, False)):
            self.assertEqual(rd_run.hedge_on(self.ctx(job), on), want, job)
        self.assertFalse(rd_run.hedge_on(self.ctx(TSC, pool=False), on))     # one host: nothing to race
        self.assertFalse(rd_run.hedge_on(self.ctx(TSC, cfg={"rr_hedge": True}), {"RRUN_HEDGE": "0"}))

    def hedge(self):
        h = fake_host("slow", 100)
        out = rd_run.Sink(io.BytesIO(), "[shard 1/2 slow] ")
        err = rd_run.Sink(io.BytesIO(), "[shard 1/2 slow] ")
        return rd_run.Hedge(self.ctx(TSC), h, ["x"], rd_run.Lane(out, err), "", 0.5, out, err)

    def test_original_first_cancels_the_duplicate(self):
        hg = self.hedge()
        self.assertAlmostEqual(hg.expect, 50.0)                           # run_s x frac
        dup = rd_run.Lane()
        sess = mock.Mock()
        dup.bind(sess)
        hg.dup, hg.dup_lane = "fast", dup
        with mock.patch("sys.stderr", new_callable=io.StringIO) as e:
            self.assertIsNone(hg.finish())
        self.assertIn("slow finished first; stopped the duplicate on fast", e.getvalue())
        sess.abort.assert_called_once_with()
        self.assertFalse(dup.bind(mock.Mock()))                          # a late start never runs
        self.assertIsNone(self.hedge().finish())                         # no duplicate at all

    def test_duplicate_first_wins_and_its_output_follows_marked(self):
        hg = self.hedge()
        out = rd_run.Sink(hg.out_stream, "", hold=True)
        err = rd_run.Sink(hg.err_stream, "", hold=True)
        out.write(b"fast-done\n")
        hg.dup, hg.dup_lane, hg.decided, hg.rc = "fast", rd_run.Lane(out, err), True, 0
        with mock.patch("sys.stderr", new_callable=io.StringIO) as e:
            self.assertEqual(hg.finish(), 0)
        self.assertIn("the duplicate on fast finished first", e.getvalue())
        self.assertEqual(hg.out_stream.getvalue(), b"[shard 1/2 fast hedge] fast-done\n")


    def test_a_hedge_on_worktree_lane_1_uses_lane_1s_namespace(self):
        hg = self.hedge()
        seen = []

        def fake_attempt(h, wt, argv, *a):
            seen.append(a[-1].wt12)                                       # the duplicate's Lane
            return "busy", "x"
        with mock.patch.dict(rd_run.WT, {"held": {1: -1}}), mock.patch.object(rd_run, "attempt", fake_attempt):
            hg.run_dup(fake_host("fast", 10))
        want = rd_run.lane_mirror_id("0" * 12, 1, 0)                      # worktree lane 1, process lane 0
        self.assertEqual(seen, [want])
        self.assertNotEqual(want, "0" * 12)
        self.assertNotIn(want, [rd_run.lane_mirror_id("0" * 12, 0, n) for n in range(8)])   # never lane 0's


FAKE_VITEST = r'''#!/bin/sh
s=none
for a in "$@"; do case "$a" in --shard=*) s="${a#--shard=}";; esac; done
echo "fake vitest shard $s on ${HOME##*/}"
i="${s%%/*}"
if [ -n "$FAIL_SHARD" ] && [ "$i" = "$FAIL_SHARD" ]; then
  printf ' Test Files  1 failed | 1 passed (2)\n      Tests  1 failed | 3 passed (4)\n'; exit 1
fi
printf ' Test Files  2 passed (2)\n      Tests  4 passed (4)\n'
'''


class SchedE2E(test_run.RunBase):
    """Real rrun against w1 (speed 1.0) and w2 (speed 0.5), each with its own HOME."""
    set_fleet, target = test_pool.PoolE2E.set_fleet, test_pool.PoolE2E.target

    def env(self, **extra):
        homes = ",".join("%s=%s" % kv for kv in sorted(getattr(self, "whome", {}).items()))
        # RRUN_CACHE=0: these tests rerun identical commands to watch the scheduler (test_cache /
        # test_sharded_run_is_cached_as_one_unit cover the cache)
        base = {"FAKE_SSH_HOMES": homes, "RRUN_RECONNECT_WAIT": "0", "RRUN_CACHE": "0"}
        if getattr(self, "proc", None):
            base.update(RR_OS="linux", RR_PROC=self.proc)
        return test_run.RunBase.env(self, **dict(base, **extra))

    def setUp(self):
        test_run.RunBase.setUp(self)
        self.whome = {}
        for n in ("w1", "w2"):
            self.whome[n] = os.path.join(self.d, "home-" + n)
            os.makedirs(self.whome[n])
        self.fleet = os.path.join(self.d, "fleet.json")
        self.set_fleet()
        self.proc = os.path.join(self.d, "proc")
        test_run.wfile(os.path.join(self.proc, "meminfo"), "MemTotal: 32000000 kB\nMemAvailable: 24000000 kB\n")
        test_run.wfile(os.path.join(self.proc, "loadavg"), "0.10 0 0 1/1 1\n")
        test_run.wfile(os.path.join(self.proc, "cpuinfo"), "".join("processor\t: %d\n\n" % i for i in range(8)))
        test_run.wfile(os.path.join(self.bin, "vitest"), FAKE_VITEST, 0o755)
        # what the workers' runs.log say a whole `vitest run` takes (the fake one takes no time,
        # which would make sharding pointless): w1 600 s, w2 twice that
        self.seed("w1", 600)
        self.seed("w2", 1200)

    def mirrors(self, w):
        d = os.path.join(self.whome[w], "rr", "w2")
        return sorted(n for n in os.listdir(d) if not n.startswith(".")) if os.path.isdir(d) else []

    def test_vitest_run_is_sharded_across_the_free_workers(self):
        r = self.rrun("vitest", "run")
        self.assertEqual(r.returncode, 0, r.stderr)
        # w1 is twice w2's speed: two shards at once there (the second on its own lane mirror)
        self.assertIn("splitting `vitest run` into 3 shards: w1 2, w2 1", r.stderr)
        for i, w in ((1, "w1"), (2, "w1"), (3, "w2")):
            self.assertIn("[shard %d/3 %s] fake vitest shard %d/3 on home-%s\n" % (i, w, i, w), r.stdout)
        self.assertIn("[shard 3/3 w2]       Tests  4 passed (4)\n", r.stdout)
        self.assertTrue(r.stdout.endswith(" Test Files  6 passed (6)\n      Tests  12 passed (12)\n"), r.stdout)
        self.assertEqual(len(self.mirrors("w1")), 2, self.mirrors("w1"))
        self.assertEqual(len(self.mirrors("w2")), 1)
        # a failing shard fails the run; the merged summary counts it
        r = self.rrun("-e", "FAIL_SHARD=2", "vitest", "run")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("      Tests  1 failed | 11 passed (12)\n", r.stdout)
        self.assertIn("rrun: fail (exit 1", r.stderr)
        self.assertIn("rrun: 3 shards: 1/3 rc=0, 2/3 rc=1, 3/3 rc=0", r.stderr)
        r = self.rrun("--where", "vitest", "run")
        self.assertIn("shards: 3 (w1 2, w2 1)", r.stdout)
        r = self.rrun("--where", "vitest", "run", "a.test.ts")
        self.assertIn("shards: no (names files / filters (a.test.ts))", r.stdout)

    def test_off_forced_and_never(self):
        r = self.rrun("vitest", "run", RRUN_SHARD="0")
        self.assertEqual((r.returncode, r.stdout.splitlines()[0]), (0, "fake vitest shard none on home-w1"), r.stderr)
        self.assertNotIn("splitting", r.stderr)
        r = self.rrun("vitest", "run", RRUN_SHARD="4")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("into 4 shards: w1 3, w2 1", r.stderr)
        self.assertEqual(len(self.mirrors("w1")), 3, self.mirrors("w1"))
        self.assertIn("Tests  16 passed (16)", r.stdout)
        for argv in (["vitest", "run", "a.test.ts"], ["vitest", "run", "--coverage"],
                     ["vitest", "run", "test:db"], ["vitest", "run", "--watch"]):
            with self.subTest(argv=argv):
                r = self.rrun(*argv)
                self.assertNotIn("splitting", r.stderr)
                self.assertNotIn("[shard", r.stdout)
        r = self.rrun("--host", "w2", "vitest", "run")                   # a forced worker: one run
        self.assertEqual(r.stdout.splitlines()[0], "fake vitest shard none on home-w2", r.stderr)

    def seed(self, w, secs, argv="vitest run", n=9):
        d = os.path.join(self.whome[w], "rr", "log")
        os.makedirs(d, exist_ok=True)
        t = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(time.time() - 60))
        with open(os.path.join(d, "runs.log"), "a") as f:
            for _ in range(n):
                f.write("%s repo=a wt=b sha=c outcome=rc=0 prepare_s=0.2 cmd_s=%s argv=%s\n" % (t, secs, argv))

    def test_sharded_run_is_cached_as_one_unit(self):
        """Keyed on the unsharded command, saved once every shard ended on a worker; a repeat
        replays the shards' prefixed output and the merged summary, with the highest rc."""
        r1 = self.rrun("vitest", "run", RRUN_CACHE="1")
        self.assertEqual(r1.returncode, 0, r1.stderr)
        self.assertIn("splitting `vitest run` into 3 shards", r1.stderr)
        r2 = self.rrun("vitest", "run", RRUN_CACHE="1")
        self.assertEqual((r2.returncode, r2.stdout), (0, r1.stdout))
        self.assertNotIn("splitting", r2.stderr)
        self.assertRegex(r2.stderr, r"rrun: cached result \(same code \+ command, \d+s ago on w[12], w[12]\)")
        self.assertTrue(r2.stdout.endswith("      Tests  12 passed (12)\n"))
        r3 = self.rrun("-e", "FAIL_SHARD=2", "vitest", "run", RRUN_CACHE="1")
        r4 = self.rrun("-e", "FAIL_SHARD=2", "vitest", "run", RRUN_CACHE="1")
        self.assertEqual((r3.returncode, r4.returncode), (1, 1))
        self.assertIn("splitting", r3.stderr)
        self.assertIn("cached result", r4.stderr)
        # shards no worker took (they end 75 in a shared run, never run here): never saved
        test_run.wfile(os.path.join(self.wt, "new.txt"), "changed\n")
        for _ in range(2):
            r = self.rrun("vitest", "run", RRUN_CACHE="1", RRUN_SHARD="2", FAKE_SSH_RUNDOWN_HOSTS="w1,w2")
            self.assertEqual(r.returncode, 75, r.stderr)
            self.assertNotIn("cached result", r.stderr)

    def test_no_shards_worker_gets_whole_jobs_only(self):
        """fleet.json "shards": false: never a shard (nor a shard's failover), whole jobs still."""
        write_fleet(self.fleet, [worker("w1", 1.0, max_slots=2), dict(worker("w2", 3.0, max_slots=2), shards=False)])
        self.write_cfg(fleet_path=self.fleet)
        self.seed("w2", 1, n=40)                                           # its evidence: w2 is the fast one
        r = self.rrun("vitest", "run", RRUN_SHARD="2")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("into 2 shards: w1 2", r.stderr)
        self.assertNotIn("w2]", r.stdout)
        r = self.rrun("vitest", "run", RRUN_SHARD="2", FAKE_SSH_RUNDOWN_HOSTS="w1")
        self.assertNotIn("trying w2", r.stderr)                          # its failover skips w2 too
        self.assertNotIn("w2]", r.stdout)
        r = self.rrun("vitest", "run", RRUN_SHARD="0")                    # one whole run: the fast w2
        self.assertEqual(r.stdout.splitlines()[0], "fake vitest shard none on home-w2", r.stderr)

    def test_a_shard_whose_worker_is_gone_runs_elsewhere(self):
        r = self.rrun("vitest", "run", FAKE_SSH_RUNDOWN_HOSTS="w2")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("[shard 3/3] w2 unreachable", r.stderr)
        self.assertIn("- trying w1", r.stderr)
        self.assertIn("[shard 3/3 w1] fake vitest shard 3/3 on home-w1\n", r.stdout)
        self.assertIn("Tests  12 passed (12)", r.stdout)
        # every worker gone before GO: a run holding its worktree shared never runs a shard on this
        # machine (its hold never changes mid-run, Phase C1): the shards end infra 75, never run here
        r = self.rrun("vitest", "run", RRUN_SHARD="2", FAKE_SSH_RUNDOWN_HOSTS="w1,w2")
        self.assertEqual(r.returncode, 75, r.stderr)
        self.assertIn("a shard runs on this machine only in a run that holds the worktree alone", r.stderr)
        self.assertNotIn("running this shard on this machine", r.stderr)
        self.assertNotIn("on home\n", r.stdout)

    def test_hedge_duplicate_on_a_freed_fast_worker_wins(self):
        for w in ("w1", "w2"):                                            # no seeded vitest evidence here
            os.unlink(os.path.join(self.whome[w], "rr", "log", "runs.log"))
        write_fleet(self.fleet, [worker("w1", 1.0, max_slots=1), worker("w2", 0.04, max_slots=1)])
        self.write_cfg(fleet_path=self.fleet, rr_job_cost_s={"normal": 0.1}, rr_hedge_poll_s=0.2,
                       rr_queue_promote_ratio=0, rr_race_wait_min=0.05)
        for w in ("w1", "w2"):                                            # warm: no cold-start cost
            for _ in range(3):                                            # (3 prepares: a measured setup)
                self.assertEqual(self.rrun("--host", w, "true").returncode, 0)
        fh = open(os.path.join(self.whome["w1"], "rr", "slots", "0"), "a")
        fcntl.flock(fh, fcntl.LOCK_EX)                                    # w1 busy at plan time
        marker = os.path.join(self.d, "slow-finished")
        script = 'case "$HOME" in *home-w2) sleep 25; echo x > %s; echo slow-done;; *) echo fast-done;; esac' % marker
        t = time.monotonic()
        p = self.popen("/bin/sh", "-c", script, "vitest", RRUN_HEDGE="1")
        time.sleep(1.5)
        fh.close()                                                        # w1 frees up mid-run
        out, err = p.communicate(timeout=40)
        self.assertEqual(p.returncode, 0, err)
        self.assertLess(time.monotonic() - t, 22, err)
        self.assertIn("w2 has run", err)
        self.assertIn("starting a duplicate on w1", err)
        self.assertIn("the duplicate on w1 finished first (rc=0); stopped the run on w2", err)
        self.assertEqual(out, "fast-done\n")
        end = time.time() + 10                                            # the slow copy was killed
        while time.time() < end and subprocess.run(["pgrep", "-f", marker], capture_output=True).returncode == 0:
            time.sleep(0.2)
        self.assertNotEqual(subprocess.run(["pgrep", "-f", marker], capture_output=True).returncode, 0)
        self.assertFalse(os.path.exists(marker))


if __name__ == "__main__":
    unittest.main()
