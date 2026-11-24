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
        # no evidence: the eta (the finish) ranks on the pessimistic run, the default x UNCERTAIN_X 2
        self.assertAlmostEqual(a.rank_s, 30.0 * rd_pool.UNCERTAIN_X["default"])
        # risk = p_infra x (setup + run/2 lost + a rerun on the best other: none here, so itself)
        base = a.setup_s + a.rank_s + 0.01
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
        self.assertEqual(self.names(p), ["nickmbp", "hp", "laptop"])     # by finish: the queue pays
        n, h = p.hosts[0], p.hosts[1]
        self.assertEqual(n.state, "busy")
        self.assertGreater(h.run_s, 10 * n.run_s)                         # hp would swap
        self.assertLess(n.eta, h.eta)
        lines = rd_pool.where_report(self.cfg, TSC, p)
        self.assertRegex("\n".join(lines), r"worker .* queue .* finish +share")
        self.assertIn("pick: nickmbp (earliest finish ~", lines[-1])
        self.assertIn("queues there about", lines[-1])

    def test_quick_lint_goes_where_it_finishes_first(self):
        """By finish time, not "free first": a lint behind a short queue on nickmbp (3x faster) beats
        the idle laptop; behind a long queue (holders that just started a 10-min command) it does not."""
        nick = probe(slots_cap=8, slots_busy=8, mem_mb=40000, ncpu=18, load=8)
        lap = probe(slots_cap=4, mem_mb=7000, ncpu=6)
        p, _ = self.plan(self.real_fleet(), {"nickmbp": dict(nick, ages=[1] * 8), "laptop": lap}, job=LINT)
        self.assertEqual(self.names(p), ["nickmbp", "laptop", "hp"])     # a ~19 s queue: still first
        now = time.time()
        long_ = [{"cmd": "npx tsc --noEmit", "start": now - 5, "med": 600} for _ in range(8)]
        p, _ = self.plan(self.real_fleet(), {"nickmbp": dict(nick, ages=[5] * 8, jobs=long_), "laptop": lap},
                         job=LINT)
        self.assertEqual(self.names(p), ["laptop", "nickmbp", "hp"])     # free, queued, down
        self.assertAlmostEqual(p.hosts[1].queue_s, 600 * rd_pool.QUEUE_OVERRUN_X - 5, delta=3)   # 775

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

    def queued(self, q, **kw):
        """A worker probe with its one slot held by a job that ends in ~q seconds (queue_wait)."""
        now = time.time()
        return dict(probe(slots_cap=1, slots_busy=1, heavy_busy=1, ncpu=8, **kw), ages=[5],
                    jobs=[{"cmd": "npx tsc --noEmit", "start": now - 5, "med": (q + 5) / rd_pool.QUEUE_OVERRUN_X}])

    def test_a_cold_worker_competes_on_net_time(self):
        """2026-11-21 (plan "use idle workers"): no measured cold budget any more. A cold laptop whose
        cold setup p75 is 184 s beats hp when hp's queue is 13 min, and loses when hp is free; the
        manual cold_ok: false still keeps it warm-only."""
        cold = [["pass", 184.0, 1]] * 4
        lap = dict(probe(warm_deps=0, ncpu=8), ev=ev(sig=[100] * 3, rows=cold))
        hp = ev(sig=[60] * 3)
        p, _ = self.plan([worker("laptop", 0.45), worker("hp", 1.5)],
                         {"laptop": lap, "hp": dict(self.queued(780), ev=hp)}, job=TSC)
        self.assertEqual(self.names(p), ["laptop", "hp"])
        self.assertEqual(p.ineligible, [])
        self.assertAlmostEqual(p.hosts[0].setup_s, 184.0)                  # the cold p75, priced in
        self.assertAlmostEqual(p.hosts[1].queue_s, 780, delta=3)
        p, _ = self.plan([worker("laptop", 0.45), worker("hp", 1.5)],
                         {"laptop": lap, "hp": dict(probe(ncpu=8), ev=hp)}, job=TSC)
        self.assertEqual(self.names(p), ["hp", "laptop"])                  # hp free: its 60 s wins
        p, _ = self.plan([dict(worker("laptop", 0.45), cold_ok=False), worker("hp", 1.5)],
                         {"laptop": lap, "hp": dict(self.queued(780), ev=hp)}, job=TSC)
        self.assertEqual(self.names(p), ["hp"])                            # manual override: warm only
        self.assertIn("(cold_ok: false)", p.ineligible[0][1])
        self.assertFalse(hasattr(rd_pool, "COLD_BUDGET_S") or hasattr(rd_pool, "COLD_WHY"))
        self.assertNotIn("rr_cold_budget_s", rd_common.DEFAULTS)

    def test_a_cold_only_pool_still_places(self):
        """With no fallback left in plan(): every worker cold and slow to install - both are ranked by
        their finish, never "nowhere to go"."""
        ans = {"mini": dict(probe(warm_deps=0), ev=ev(sig=[50] * 3, rows=[["pass", 400.0, 1]] * 4)),
               "hp": dict(probe(warm_deps=0), ev=ev(sig=[50] * 3, rows=[["pass", 300.0, 1]] * 4))}
        p, _ = self.plan([worker("mini", 2.0), worker("hp", 1.0)], ans, job=TSC)
        self.assertEqual(self.names(p), ["hp", "mini"])
        self.assertEqual(p.ineligible, [])
        self.assertEqual([h.setup_s for h in p.hosts], [300.0, 400.0])

    def test_mini_margin_only_over_its_max_cost_s(self):
        """The 25 % + 15 s margin applies only when the predicted run is over the worker's max_cost_s
        (slow_why). Under it a cold mini pays only its cold setup: it wins on a plain eta race."""
        DB = rd_pool.classify(["npm", "run", "test:db"])
        mini = lambda: dict(worker("mini-a", 0.42), classes=["light", "normal", "db"], max_cost_s=120)  # noqa: E731
        hp = lambda q: dict(self.queued(q), ev=ev(sig=[50] * 3))  # noqa: E731
        # under the cap: run 60 s + cold setup 30 s = ~90 s vs hp's 60 s queue + 50 s run = ~112 s
        m = dict(probe(warm_deps=0), ev=ev(sig=[60] * 3, rows=[["pass", 30.0, 1]] * 4))
        p, _ = self.plan([mini(), worker("hp", 1.5)], {"mini-a": m, "hp": hp(60)}, job=DB)
        self.assertEqual(self.names(p), ["mini-a", "hp"])
        self.assertIsNone(p.hosts[0].slow)
        self.assertGreater(p.hosts[0].eta, p.hosts[1].eta - (0.25 * p.hosts[1].eta + 15))   # the margin would lose
        # over the cap (run 200 s > 120 s): it must win by the margin
        m = dict(probe(), ev=ev(sig=[200] * 3))
        p, _ = self.plan([mini(), worker("hp", 1.5)], {"mini-a": m, "hp": hp(180)}, job=DB)
        self.assertEqual(self.names(p), ["hp", "mini-a"])                  # ~202 vs ~232: not by 25 % + 15 s
        self.assertIn("over its max_cost_s", p.hosts[1].slow)
        self.assertLess(p.hosts[1].eta, p.hosts[0].eta)                     # sooner, but not by enough
        p, _ = self.plan([mini(), worker("hp", 1.5)], {"mini-a": m, "hp": hp(400)}, job=DB)
        self.assertEqual(self.names(p), ["mini-a", "hp"])                  # ~202 vs ~452: wins by it

    def test_cold_setup_overrun_feeds_the_next_estimate(self):
        """A cold placement whose install overran its estimate (runs.log prepare_s vs spred_s, probe
        ev.sover) lifts that worker's next cold estimate, capped; this repo's own cold prepares there
        (ev.scold) are a floor. The logged reference (setup_base) stays uncorrected, so the factor
        never feeds on itself; a warm estimate is untouched."""
        def h(warm=0, **e):
            x = rd_pool.Host("w", {}, {})
            x.probe = dict(probe(warm_deps=warm), ev=ev(rows=[["pass", 60.0, 1]] * 4 + [["pass", 1.0, 0]] * 4))
            x.probe["ev"].update(e)
            return x
        self.assertEqual((rd_pool.setup_s(h()), rd_pool.setup_base(h())), (60.0, 60.0))
        self.assertEqual(rd_pool.setup_s(h(sover=[3.0, 2.5, 3.5])), 180.0)            # median 3x
        self.assertEqual(rd_pool.setup_base(h(sover=[3.0, 2.5, 3.5])), 60.0)          # spred_s: uncorrected
        self.assertEqual(rd_pool.setup_s(h(sover=[40.0])), 60.0 * rd_pool.SETUP_OVER_MAX)  # capped
        self.assertEqual(rd_pool.setup_s(h(sover=[0.5, 0.4])), 60.0)                  # faster: no discount
        self.assertEqual(rd_pool.setup_s(h(scold=[400.0])), 400.0)                    # this repo's own floor
        # 2026-11-21 review: one 400 s install right after a 60 s estimate, then nine cheaper cold
        # prepares in the same repo and ordinary ratios: the floor is the slowest, not a p75 they outvote
        self.assertEqual(rd_pool.setup_s(h(scold=[400.0] + [50.0] * 9, sover=[400 / 60.0] + [1.0] * 4)), 400.0)
        self.assertEqual(rd_pool.setup_s(h(scold=[50.0] * 10, sover=[1.0] * 5)), 60.0)  # aged out: back down
        self.assertEqual(rd_pool.setup_s(h(warm=1, sover=[3.0], scold=[400.0])), 1.0)  # warm: untouched
        # in a plan: the laptop's 60 s cold estimate beat hp's 3 min queue; after a 5x overrun it does not
        lap = lambda **e: dict(probe(warm_deps=0, ncpu=8),  # noqa: E731
                               ev=dict(ev(sig=[100] * 3, rows=[["pass", 60.0, 1]] * 4), **e))
        hp = dict(self.queued(180), ev=ev(sig=[60] * 3))
        p, _ = self.plan([worker("laptop", 0.45), worker("hp", 1.5)], {"laptop": lap(), "hp": hp}, job=TSC)
        self.assertEqual(self.names(p), ["laptop", "hp"])
        self.assertEqual(p.hosts[0].setup_base, 60.0)
        self.assertIsNone(p.hosts[1].setup_base)        # a warm placement logs no spred_s: never a cold ratio
        p, _ = self.plan([worker("laptop", 0.45), worker("hp", 1.5)], {"laptop": lap(sover=[5.0]), "hp": hp}, job=TSC)
        self.assertEqual(self.names(p), ["hp", "laptop"])
        self.assertEqual((p.hosts[1].setup_s, p.hosts[1].setup_base), (240.0, 60.0))

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
        self.assertLess(f.eta, a.eta)
        # a one-file run still goes to the free worker: the busy one's queue costs more than it saves
        one = rd_pool.classify(["npx", "vitest", "run", "src/a.test.ts"])
        p, _ = self.plan([worker("mini-a", 0.42), worker("fast", 2.0)],
                         {"mini-a": dict(probe(ncpu=4), ev=ev(sig=[30] * 6)), "fast": dict(fast, ev=ev(sig=[30] * 6))},
                         job=one)
        self.assertEqual(self.names(p)[0], "mini-a")
        self.assertEqual(rd_pool.run_sig(["env", "TOK=s", "npx", "-e", "x", "a\tb"]),
                         "env TOK=<redacted> npx -e <redacted> a b")

    def test_holder_with_known_command_sets_the_queue(self):
        """A busy worker's queue = when its holder's own command (slots/<i>.own) should end: its median
        x QUEUE_OVERRUN_X (the measured overrun on a full worker), less how long it has held the slot."""
        busy = dict(probe(slots_cap=1, slots_busy=1, ncpu=8), ages=[100], ev=ev(all=[8, 10.0]),
                    jobs=[{"cmd": "npx vitest run", "start": time.time() - 100, "med": 1000}])
        p, _ = self.plan([worker("a", 1.0), worker("b", 1.0)], {"a": busy}, job=LINT)
        a = next(h for h in p.hosts if h.name == "a")
        self.assertAlmostEqual(a.queue_s, 1000 * rd_pool.QUEUE_OVERRUN_X - 100, delta=5)   # 1200

    def test_wait_lines_carry_position_and_eta(self):
        sess = rd_run.Session({"rr_wait_min": 30}, [], "0" * 32, rd_run.Timing(False))
        sess.host_name, sess.wait_eta_s = "hp", 300
        err = io.StringIO()
        with mock.patch.object(sys, "stderr", err):
            sess.on_status("WAIT holder=dentall.1 age=120 busy=4 slots=4 ahead=2 howner=billing")
            sess.wait_since -= 120
            sess.on_status("WAIT holder=dentall.1 age=240 busy=4 slots=4 ahead=0 gate=heavy")
        a, b = err.getvalue().splitlines()
        self.assertEqual(a, "rrun: queued on hp: about 5 min (2 ahead); 4 of 4 slots busy; held longest by dentall.1 "
                            "(billing) for 120s; waits here up to 30 min")
        self.assertEqual(sess.ahead, 0)                                   # the latest WAIT's position
        # later lines are short: no repeated banner (agent contract)
        self.assertEqual(b, "rrun: still queued on hp: about 3 min (next in line); waited 2 min")
        sess = rd_run.Session({"rr_wait_min": 12}, [], "0" * 32, rd_run.Timing(False))
        sess.host_name, sess.may_move = "hp", True
        err = io.StringIO()
        with mock.patch.object(sys, "stderr", err):
            sess.on_status("WAIT holder=? age=0 busy=1 slots=1 ahead=0")
        self.assertEqual(err.getvalue(), "rrun: queued on hp: a slot should free soon (it looked free when planned) "
                                         "(next in line); 1 of 1 slots busy; waits here up to 12 min, moving once "
                                         "if another worker becomes clearly faster\n")

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


class QueueEstimate(unittest.TestCase):
    """2026-11-23 (routing review, "accurate, tune it with data"): the queue estimate uses the slots the
    runner really hands out now and the whole line ahead. Tonight ethanair (share medium: 3 of 7 slots)
    had 18 runs waiting while mini-a sat idle, and the placement read it as free."""
    setUp = test_pool.PlanUnit.setUp
    plan = test_pool.PlanUnit.plan

    def names(self, p):
        return [h.name for h in p.hosts]

    def machines(self):
        return [dict(worker("ethanair", 4.0, max_slots=7, heavy_slots=4), optional=True),
                worker("mini-a", 0.42, max_slots=2)]

    def ethanair(self, busy, waiting, **kw):
        now = time.time()
        return dict(probe(slots_cap=3, slots_busy=busy, heavy_cap=2, ncpu=8, mem_mb=20000, share="medium", **kw),
                    ages=[60] * busy, waiting=waiting, ev=ev(sig=[20] * 5, all=[50, 200.0]),
                    jobs=[{"cmd": "npx tsc --noEmit", "start": now - 60, "med": 300} for _ in range(busy)])

    def test_share_reduced_worker_with_a_long_line_loses_to_an_idle_slower_one(self):
        mini = dict(probe(slots_cap=2, ncpu=4), ev=ev(sig=[60] * 5))
        # share medium: 3 slots, all held, 18 runs waiting (each a typical hold): far behind the idle mini
        p, _ = self.plan(self.machines(), {"ethanair": self.ethanair(3, 18), "mini-a": mini}, job=VITEST)
        self.assertEqual(self.names(p), ["mini-a", "ethanair"])
        e = p.hosts[1]
        self.assertEqual((e.state, e.ahead), ("busy", 18))
        # 3 holders free at 300 x 1.3 - 60 = 330 s, then 18 waiters x (200 x 1.3) over 3 slots: 6 rounds
        self.assertAlmostEqual(e.queue_s, 330 + 6 * 260, delta=2)
        # the old blind spot: a free slot of the 3 with 18 runs waiting is not free (they take it first)
        p, _ = self.plan(self.machines(), {"ethanair": self.ethanair(2, 18), "mini-a": mini}, job=VITEST)
        self.assertEqual(self.names(p), ["mini-a", "ethanair"])
        self.assertEqual(p.hosts[1].state, "busy")
        self.assertGreater(p.hosts[1].queue_s, 1000)

    def test_an_idle_worker_still_wins_normally(self):
        mini = dict(probe(slots_cap=2, ncpu=4), ev=ev(sig=[60] * 5))
        p, _ = self.plan(self.machines(), {"ethanair": self.ethanair(0, 0), "mini-a": mini}, job=VITEST)
        self.assertEqual(self.names(p), ["ethanair", "mini-a"])
        self.assertEqual((p.hosts[0].state, p.hosts[0].queue_s), ("free", 0.0))
        # a free slot with fewer runs waiting than free slots is still free
        p, _ = self.plan(self.machines(), {"ethanair": self.ethanair(1, 1), "mini-a": mini}, job=VITEST)
        self.assertEqual(self.names(p)[0], "ethanair")
        self.assertEqual((p.hosts[0].state, p.hosts[0].queue_s), ("free", 0.0))

    def test_without_spare_room_only_the_base_slots_count(self):
        """rr_slots_base (2) always, the rest of the cap only while the worker has room (the runner's
        spare_room: free memory >= 25 %, load per CPU <= 1.5). hp holding 5 of 8 with no room is full."""
        ms = [worker("hp", 1.5, max_slots=8, heavy_slots=4), worker("laptop", 0.45, max_slots=3)]
        now = time.time()
        hp = dict(probe(slots_cap=8, slots_busy=5, heavy_cap=4, ncpu=8, load=14.0), mem_free_pct=40, ages=[30] * 5,
                  ev=ev(sig=[60] * 5, all=[50, 100.0]),
                  jobs=[{"cmd": "x", "start": now - 30, "med": 100} for _ in range(5)])
        lap = dict(probe(slots_cap=3, ncpu=8), ev=ev(sig=[150] * 5))
        p, _ = self.plan(ms, {"hp": hp, "laptop": lap}, job=VITEST)
        h = next(x for x in p.hosts if x.name == "hp")
        self.assertEqual(rd_pool.open_slots(h), 2)
        self.assertEqual(h.state, "busy")
        self.assertAlmostEqual(h.queue_s, 100 * rd_pool.QUEUE_OVERRUN_X - 30, delta=2)
        # room again (load 4 on 8 CPUs, 40 % free): the whole cap is open, 3 slots free
        p, _ = self.plan(ms, {"hp": dict(hp, load1=4.0), "laptop": lap}, job=VITEST)
        h = next(x for x in p.hosts if x.name == "hp")
        self.assertEqual((rd_pool.open_slots(h), h.state, h.queue_s), (8, "free", 0.0))
        self.assertEqual(self.names(p)[0], "hp")
        # low memory closes it too, and so does a missing reading (the runner fails safe the same way)
        h.probe = dict(hp, load1=4.0, mem_free_pct=10)
        self.assertEqual(rd_pool.open_slots(h), 2)
        h.probe = {k: v for k, v in hp.items() if k != "mem_free_pct"}
        self.assertEqual(rd_pool.open_slots(h), 2)

    def test_only_holders_of_open_slots_count(self):
        """probe `held` = [slot, age]: without spare room the runner tries slots 0-1 only. Free base slots
        with spare slots 2-4 held: a slot now. Both base slots held: only their ends open one (a spare
        holder that ends first opens nothing while the room is shut)."""
        now = time.time()
        h = rd_pool.Host("hp", {"rr_slots_base": 2}, {"speed": 1.0})
        nolo = dict(probe(slots_cap=8, slots_busy=3, ncpu=8, load=14.0), ev=ev(all=[50, 100.0]))
        h.probe = dict(nolo, held=[[2, 10], [3, 10], [4, 10]])
        self.assertEqual(rd_pool.slot_releases(h, VITEST, now=now)[0], 2)
        h.probe = dict(nolo, slots_busy=3, held=[[0, 10], [1, 20], [2, 290]],
                       jobs=[{"slot": 0, "cmd": "x", "start": now - 10, "med": 300}])
        free, rel = rd_pool.slot_releases(h, VITEST, now=now)
        self.assertEqual(free, 0)
        # slot 0: its own 300 x 1.3 - 10; slot 1: the typical 100 x 1.3 - 20; slot 2 (290 s into a spare) left out
        self.assertEqual([round(r) for r in rel], [110, 380])
        self.assertAlmostEqual(rd_pool.queue_wait(h, VITEST, now=now), 110, delta=1)
        # a holder whose command has no median here keeps its age (the typical hold from its age)
        h.probe = dict(nolo, held=[[0, 10], [1, 20]], jobs=[{"slot": 0, "cmd": "new", "start": now - 10}])
        self.assertEqual([round(r) for r in rd_pool.slot_releases(h, VITEST, now=now)[1]], [110, 120])
        # the heavy lock held by a spare-slot job (a tsc 300 x 1.3 long): a heavy job waits on that holder,
        # not on a base one that ends sooner (the heavy holders are taken as the longest, open slot or not)
        h.probe = dict(nolo, heavy_cap=1, heavy_busy=1, held=[[0, 10], [2, 10]],
                       jobs=[{"slot": 2, "cmd": "npx tsc", "start": now - 10, "med": 300}])
        free, rel = rd_pool.slot_releases(h, TSC, now=now)
        self.assertEqual((free, [round(r) for r in rel]), (0, [380]))

    def test_route_log_pairs_the_predicted_wait_with_the_measured_one(self):
        """qpred_s is added only beside slot_s (the runner's SLOT), so retries and shards sum alike."""
        rd_run.STAGES.clear()
        self.addCleanup(rd_run.STAGES.clear)
        sess = rd_run.Session({"rr_wait_min": 30}, [], "0" * 32, rd_run.Timing(False))
        sess.qpred_s = 40.0
        sess.on_status("SLOT 55.5")
        self.assertEqual((rd_run.STAGES["slot_s"], rd_run.STAGES["qpred_s"]), (55.5, 40.0))
        moved = rd_run.Session({"rr_wait_min": 30}, [], "0" * 32, rd_run.Timing(False))
        moved.qpred_s = 300.0                                   # never got SLOT: neither side counts
        self.assertEqual(rd_run.STAGES["qpred_s"], 40.0)

    def test_hold_median_and_a_holder_past_its_estimate(self):
        """A holder is priced on its command's median HOLD (hmed: prepare + command) when the probe has it;
        one already past its estimate has at least QUEUE_AGE_K x its age left, not a sliver."""
        now = time.time()
        h = rd_pool.Host("w", {}, {"speed": 1.0})
        h.probe = dict(probe(slots_cap=1, slots_busy=1), ages=[400], ev=ev(all=[10, 50.0]),
                       jobs=[{"cmd": "x", "start": now - 400, "med": 100, "hmed": 200}])
        self.assertAlmostEqual(rd_pool.queue_wait(h, VITEST, now=now), 400 * rd_pool.QUEUE_AGE_K)
        h.probe["jobs"][0]["start"] = now - 10
        self.assertAlmostEqual(rd_pool.queue_wait(h, VITEST, now=now), 200 * rd_pool.QUEUE_OVERRUN_X - 10)
        h.probe["ev"]["hold"] = [10, 80.0]                      # typical hold for the waiters: ev.hold over ev.all
        h.probe["waiting"] = 2
        self.assertAlmostEqual(rd_pool.queue_wait(h, VITEST, now=now),
                               200 * rd_pool.QUEUE_OVERRUN_X - 10 + 2 * 80 * rd_pool.QUEUE_OVERRUN_X)


class FinishPlacement(unittest.TestCase):
    """2026-11-13 (pool-speed study): placement by predicted FINISH; max_cost_s soft with a margin;
    wild misses corrected; evidence keyed on repo + argv."""
    setUp = test_pool.PlanUnit.setUp
    plan = test_pool.PlanUnit.plan

    def names(self, p):
        return [h.name for h in p.hosts]

    def busy(self, secs_left, slots=4, cap=4, **kw):
        now = time.time()
        return dict(probe(slots_cap=cap, slots_busy=slots, ncpu=8, **kw), ages=[10] * slots,
                    jobs=[{"cmd": "x", "start": now - 10, "med": (secs_left + 10) / rd_pool.QUEUE_OVERRUN_X}
                          for _ in range(slots)])

    DB = rd_pool.classify(["npm", "run", "test:db"])

    def test_picks_the_minimum_finish_and_where_prints_each(self):
        """hp (fast, DB 48 s) is full but its next slot frees in ~30 s; the laptop is free but DB takes
        109 s there: hp wins (30 + 48 < 109). With hp's queue at 5 min the laptop wins."""
        hp = dict(self.busy(30), ev=ev(sig=[48] * 5))
        lap = dict(probe(slots_cap=3, ncpu=8), ev=ev(sig=[109] * 5))
        ms = [worker("hp", 1.5, max_slots=4), worker("laptop", 0.45, max_slots=3)]
        p, _ = self.plan(ms, {"hp": hp, "laptop": lap}, job=self.DB)
        self.assertEqual(self.names(p), ["hp", "laptop"])
        h, l = p.hosts
        self.assertEqual((h.state, l.state), ("busy", "free"))
        self.assertAlmostEqual(h.queue_s, 30, delta=2)
        self.assertAlmostEqual(h.eta, h.queue_s + h.setup_s + 48 + h.risk_s, delta=1)   # well known: median
        lines = "\n".join(rd_pool.where_report(self.cfg, self.DB, p))
        self.assertRegex(lines, r"\nhp +hp +busy +0/4 .* +30s +48s +\(own\) .* +\d+s +max\n")
        self.assertRegex(lines, r"\nlaptop +laptop +free +3/3 .* +0s +109s +\(own\) .* +\d+s +max\n")
        self.assertIn("pick: hp (earliest finish ~", lines)
        p, _ = self.plan(ms, {"hp": dict(self.busy(300), ev=ev(sig=[48] * 5)), "laptop": lap}, job=self.DB)
        self.assertEqual(self.names(p), ["laptop", "hp"])
        # runs already waiting there count: 4 holders freeing at ~30 s and 6 queued (48 s each) ahead
        p, _ = self.plan(ms, {"hp": dict(hp, waiting=6), "laptop": lap}, job=self.DB)
        hp_ = next(x for x in p.hosts if x.name == "hp")
        self.assertEqual(hp_.ahead, 6)
        self.assertGreater(hp_.queue_s, 60)
        self.assertEqual(self.names(p)[0], "laptop")

    def test_a_slow_worker_only_when_it_wins_by_the_margin(self):
        """mini-a (max_cost_s 120) predicted over it: not excluded (the owner: "if they're just waiting
        it wouldn't hurt to use the Mac Mini"), but it goes first only when its PESSIMISTIC finish beats
        the best other's by 25 % + 15 s."""
        mini = dict(worker("mini", 0.42, max_slots=2), max_cost_s=120)
        hpw = worker("hp", 1.5, max_slots=4)
        mini_ev = ev(sig=[140, 143, 150, 160, 200])                       # median 150, p90 200
        hp_ev = ev(sig=[50] * 5)
        # hp's queue is 10 min: the mini (p90 200 s) finishes far sooner -> first
        p, _ = self.plan([mini, hpw], {"mini": dict(probe(), ev=mini_ev), "hp": dict(self.busy(600), ev=hp_ev)},
                         job=VITEST)
        self.assertEqual(self.names(p), ["mini", "hp"])
        m = p.hosts[0]
        self.assertIn("over its max_cost_s 120s", m.slow)
        self.assertAlmostEqual(m.rank_s, 200, delta=1)                    # ranked on its p90, not 150
        self.assertIn("(slow: expected ~", "\n".join(rd_pool.where_report(self.cfg, VITEST, p)))
        # hp's queue ~ 2.5 min: hp ~ 150 + 50 = 200 s; mini 200 s at p90 is not 25 % + 15 s better
        p, _ = self.plan([mini, hpw], {"mini": dict(probe(), ev=mini_ev), "hp": dict(self.busy(150), ev=hp_ev)},
                         job=VITEST)
        self.assertEqual(self.names(p), ["hp", "mini"])
        h, m = p.hosts
        self.assertLess(m.eta - m.rank_s + m.run_s, h.eta)               # on its median the mini looked faster...
        self.assertFalse(rd_pool.slow_wins(m, h.eta, self.cfg))          # ...but not by the margin
        # the margin is config: 0 + 0 -> plain finish order
        cfg = dict(self.cfg, rr_slow_gain_ratio=0, rr_slow_gain_s=0)
        self.assertEqual(rd_pool.slow_wins(m, m.eta + 1, cfg), True)
        # only slow workers left (hp down): the mini takes it, no exit 77
        p, _ = self.plan([mini, hpw], {"mini": dict(probe(), ev=mini_ev)}, job=VITEST)
        self.assertEqual(self.names(p)[0], "mini")
        self.assertEqual(p.ineligible, [])

    def test_wild_miss_lifts_the_next_prediction(self):
        """`npm run test` predicted 5.2 s took 1,807 s (route.log 2026-11-13 12:30). A run over 5x its
        pred_s (ev.miss, any outcome) lifts the estimate until the command has OWN_MIN runs there."""
        job = rd_pool.classify(["npm", "run", "test"])
        e = dict(ev(sig=[5.2]), miss=[1, 1807.0])
        p, _ = self.plan([worker("hp", 1.0), worker("b", 1.0)], {"hp": dict(probe(), ev=e), "b": probe()}, job=job)
        hp = next(h for h in p.hosts if h.name == "hp")
        self.assertTrue(hp.src.endswith("+miss"), hp.src)
        self.assertAlmostEqual(hp.pred_s, 1807.0)
        b = next(h for h in p.hosts if h.name == "b")                     # the other worker learns it too
        self.assertTrue(b.src.endswith("+miss"), b.src)
        self.assertGreater(b.pred_s, 1000)
        # with OWN_MIN real runs the median rules (one hang does not poison it)
        e = dict(ev(sig=[6, 5, 7]), miss=[1, 1807.0])
        p, _ = self.plan([worker("hp", 1.0), worker("b", 1.0)], {"hp": dict(probe(), ev=e), "b": probe()}, job=job)
        hp = next(h for h in p.hosts if h.name == "hp")
        self.assertEqual((hp.src, hp.pred_s), ("own", 6))

    def test_another_repos_script_is_not_this_ones(self):
        """Evidence is keyed on repo + argv: a 5 s `npm run test` in another repo only gives the weak
        kind-any hint, never below the class default, and its slack doubles in the ranking."""
        job = rd_pool.classify(["npm", "run", "test"])
        p, _ = self.plan([worker("hp", 1.0), worker("b", 1.0)],
                         {"hp": dict(probe(), ev=dict(ev(), kany=[20, 5.0])), "b": probe()}, job=job)
        hp = next(h for h in p.hosts if h.name == "hp")
        self.assertEqual(hp.src, "kind-any")
        self.assertEqual(hp.pred_s, rd_pool.default_cost(self.cfg, "normal"))
        self.assertAlmostEqual(hp.rank_s, hp.run_s * rd_pool.UNCERTAIN_X["kind-any"])

    def test_probe_reports_wild_misses_for_this_repo_and_command(self):
        rt = test_pool.ProbeSnippet("setUp")
        rt.setUp()
        self.addCleanup(rt.doCleanups)

        def line(repo, out, cmd, argv, pred):
            return ("2026-11-11T11:00:00+0000 repo=%s wt=b sha=c outcome=%s prepare_s=0.1 cmd_s=%s argv=%s"
                    "\trun=x owner=- cls=normal wait_s=0 exit_reason=x setup=warm pred_s=%s client=- pv=1\n"
                    % (repo, out, cmd, argv, pred))
        log = "".join([line("a", "rc=0", "1807.0", "npm run test", "5.2"),             # a wild miss
                       line("a", "timeout rc=124", "1800.0", "npm run test", "5.2"),   # a cap kill: one too
                       line("a", "rc=0", "20.0", "npm run test", "5.2"),               # 3.8x: not wild
                       line("a", "rc=0", "30.0", "npm run test", "1"),                 # < pred + 30 s
                       line("other", "rc=0", "999.0", "npm run test", "5"),            # another repo
                       line("a", "rc=0", "999.0", "npm run lint", "5")])               # another command
        test_run.wfile(os.path.join(rt.root, "log", "runs.log"), log)
        e = rt.run_probe({"slots": 1, "slug": "a", "sig": "npm run test", "kind": "npm-test",
                          "kinds": [list(k) for k in rd_pool.KINDS], "now": NOW})["ev"]
        self.assertEqual(e["miss"], [2, 1807])
        self.assertEqual(e["sig"], [1807, 20, 30])                        # repo a only
        self.assertEqual(e["kind"], [3, 30])
        self.assertEqual(e["kany"], [4, 514.5])                           # the kind in every repo (rc 0/1)

    def test_waiting_runs_and_holder_repo_in_the_probe(self):
        rt = test_pool.ProbeSnippet("setUp")
        rt.setUp()
        self.addCleanup(rt.doCleanups)
        w = os.path.join(rt.root, "wait")
        os.makedirs(w)
        test_run.wfile(os.path.join(w, str(os.getpid())), "1.0\n")           # alive
        test_run.wfile(os.path.join(w, "999999"), "1.0\n")                   # gone
        self.assertEqual(rt.run_probe({"slots": 1})["waiting"], 1)


class MoverUnit(unittest.TestCase):
    def test_a_refused_move_changes_nothing_and_says_nothing(self):
        """The session got its slot between the re-plan and the request: no move, ctx.plan untouched,
        no "moving to" line (host_loop prints it only when the move happened)."""
        plan0, fresh = object(), object()
        ctx = mock.Mock(plan=plan0, cfg={"rr_move_poll_s": 0.01})
        sess = rd_run.Session({"rr_wait_min": 5}, [], "0" * 32, rd_run.Timing(False))
        sess.wait_since = time.monotonic()
        sess.got_slot = False
        lane = mock.Mock(session=sess)
        mv = rd_run.Mover(ctx, mock.Mock(name="hp"), lane)
        c = mock.Mock(eta=10.0)
        c.name = "w2"

        def candidate(s):
            s.got_slot = True                       # the slot arrived meanwhile
            return c, 300.0, fresh
        err = io.StringIO()
        with mock.patch.object(mv, "candidate", side_effect=candidate), mock.patch.object(sys, "stderr", err):
            mv.watch()
        self.assertIs(ctx.plan, plan0)
        self.assertIsNone(sess.move_to)
        self.assertEqual(err.getvalue(), "")
        # accepted: the session carries (host, plan, note) and still nothing is printed by the Mover
        sess.got_slot = False
        with mock.patch.object(mv, "candidate", return_value=(c, 300.0, fresh)), \
                mock.patch.object(sys, "stderr", err):
            mv.watch()
        self.assertEqual(sess.move_to[:2], (c, fresh))
        self.assertIn("moving to w2", sess.move_to[2])
        self.assertIs(ctx.plan, plan0)
        self.assertEqual(err.getvalue(), "")


    def test_a_free_own_worker_that_is_not_better_does_not_hide_a_better_one(self):
        """rank() puts this Mac's own worker first while free, not by finish: a move candidate scan that
        meets it and finds it not clearly better looks on to the next worker (rd_pool.is_own)."""
        sess = rd_run.Session({"rr_wait_min": 5}, [], "0" * 32, rd_run.Timing(False))
        sess.wait_since = time.monotonic()
        ctx = mock.Mock(cfg={}, job={"cls": "normal"}, wt={"slug": "s", "top": "/x"}, deps=[], force=None)
        here = mock.Mock(probe=None, queue_s=300.0, setup_s=0.0, rank_s=0.0, run_s=0.0)
        here.name = "hp"
        mv = rd_run.Mover(ctx, here, mock.Mock(session=sess))

        def host(name, eta, own):
            h = mock.Mock(eta=eta, state="free", entry={"_self": "high"} if own else {})
            h.name = name
            return h
        own, fast = host("air", 290.0, True), host("mini", 20.0, False)
        plan = mock.Mock(hosts=[own, fast])
        with mock.patch.object(rd_pool, "plan", return_value=plan), mock.patch.object(rd_pool, "deps_shas", return_value=""):
            c, _, _ = mv.candidate(sess)
        self.assertIs(c, fast)
        plan.hosts = [host("lap", 290.0, False), fast]        # a regular worker first: the scan stops, as before
        with mock.patch.object(rd_pool, "plan", return_value=plan), mock.patch.object(rd_pool, "deps_shas", return_value=""):
            c, _, _ = mv.candidate(sess)
        self.assertIsNone(c)


class Retry(unittest.TestCase):
    def test_push_s_is_the_push_alone_after_an_earlier_attempt(self):
        rd_run.STAGES.clear()
        self.addCleanup(rd_run.STAGES.clear)
        t = rd_run.Timing(False)
        t.mark("plan", "plan_s")
        t.attempt(False)
        t.mark("push", "push_s")
        time.sleep(0.3)                     # the first attempt's slot wait, then it moved on
        t.attempt(True)
        t.mark("push", "push_s")
        self.assertGreaterEqual(rd_run.STAGES["retry_s"], 0.3)
        self.assertLess(rd_run.STAGES["push_s"], 0.1)


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
                                      "pid": "4242", "cmd": "npx tsc", "slot": 1, "repo": "app.1"}])
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
        return dict({"slots": 2, "slug": "a", "sig": "npx tsc --noEmit", "kind": "tsc",
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
        self.assertEqual(e["kany"], [4, 110])                             # (every row here is repo a)
        self.assertEqual(e["pk"][rd_pool.sig_key("npx tsc --noEmit", "a")], [3, 120])
        self.assertNotIn(rd_pool.sig_key("npm run lint", "a"), e["pk"])   # another kind
        self.assertNotIn("miss", e)                                       # no run over 5x its pred_s
        self.assertEqual(e["all"], [5, 100])
        self.assertEqual(e["hold"], [5, 100.5])                           # prepare + command: 10 31 100.5 120.7 160
        # history_since cuts the older rows; rows caps the rate window
        e = self.run_probe(self.evreq(since=NOW - 3600))["ev"]
        self.assertEqual(e["sig"], [100, 120, 140])
        e = self.run_probe(self.evreq(since=NOW - 1800, rows=2))["ev"]      # the 11:00Z rows: out
        self.assertEqual((e["sig"], len(e["rows"]), e["all"]), ([100, 120, 140], 2, [3, 120]))
        # a running job's own median (queue estimate)
        fh = open(os.path.join(self.root, "slots", "0"), "a")
        fcntl.flock(fh, fcntl.LOCK_EX)
        self.addCleanup(fh.close)
        test_run.wfile(os.path.join(self.root, "slots", "0.who"), "a 100 4242 abcdef012345\n")
        test_run.wfile(os.path.join(self.root, "slots", "0.own"), "id=s\tstart=100\tpid=4242\tcmd=npx tsc --noEmit\n")
        o = self.run_probe(self.evreq())
        j = o["jobs"][0]
        self.assertEqual((j["med"], j["hmed"], j["slot"]), (120, 120.7, 0))   # its slot hold: 100.5 120.7 160
        self.assertEqual([x[0] for x in o["held"]], [0])                    # [slot, age] per held slot
        test_run.wfile(os.path.join(self.root, "slots", "0.who"), "other.2 100 4242 abcdef012345\n")
        self.assertNotIn("med", self.run_probe(self.evreq())["jobs"][0])  # the same argv in another repo
        # never through a symlink
        os.unlink(os.path.join(self.root, "log", "runs.log"))
        os.symlink(os.path.join(self.d, "elsewhere"), os.path.join(self.root, "log", "runs.log"))
        self.assertEqual(self.run_probe(self.evreq())["ev"]["rows"], [])

    def test_cold_setup_evidence(self):
        """ev.scold: this repo's cold prepares (setup=cold, or > 15 s on old rows); ev.sover: actual /
        spred_s of cold prepares that logged it (any repo, the last 5), never of warm ones."""
        def line(repo, prep, setup, spred=None):
            return ("2026-11-11T11:00:00+0000 repo=%s wt=b sha=c outcome=rc=0 prepare_s=%s cmd_s=10.0 argv=npx tsc --noEmit"
                    "\trun=x owner=- cls=heavy wait_s=0 exit_reason=pass setup=%s pred_s=10 client=- pv=1 node=20 "
                    "lock_s=0.0 slot_s=0.0%s\n" % (repo, prep, setup, "" if spred is None else " spred_s=%s" % spred))
        log = "".join([line("a", "300.0", "cold", "60.0"), line("a", "2.0", "warm", "1.0"),
                       line("other", "120.0", "cold", "60.0"), line("a", "90.0", "cold"),
                       line("a", "50.0", "cold", "-")])
        test_run.wfile(os.path.join(self.root, "log", "runs.log"), log)
        e = self.run_probe(self.evreq())["ev"]
        self.assertEqual(e["scold"], [300, 90, 50])
        self.assertEqual(e["sover"], [5, 2])
        test_run.wfile(os.path.join(self.root, "log", "runs.log"), "".join(line("a", "1.0", "warm", "1") for _ in range(3)))
        e = self.run_probe(self.evreq())["ev"]
        self.assertNotIn("scold", e)
        self.assertNotIn("sover", e)

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
        """runs.log evidence of `argv` in this test's repo (evidence is keyed on repo + argv)."""
        d = os.path.join(self.whome[w], "rr", "log")
        os.makedirs(d, exist_ok=True)
        t = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(time.time() - 60))
        slug = rd_run.resolve_worktree(self.wt)["slug"]
        with open(os.path.join(d, "runs.log"), "a") as f:
            for _ in range(n):
                f.write("%s repo=%s wt=b sha=c outcome=rc=0 prepare_s=0.2 cmd_s=%s argv=%s\n" % (t, slug, secs, argv))

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
        self.write_cfg(fleet_path=self.fleet, rr_job_cost_s={"normal": 0.1}, rr_hedge_poll_s=0.2, rr_move_max=0)
        for w in ("w1", "w2"):                                            # warm: no cold-start cost
            for _ in range(3):                                            # (3 prepares: a measured setup)
                self.assertEqual(self.rrun("--host", w, "true").returncode, 0)
        # w1 busy at plan time, with a holder whose command takes 5 min there: w2 finishes first
        self.seed("w1", 300, argv="long-holder", n=3)
        sl = os.path.join(self.whome["w1"], "rr", "slots")
        fh = open(os.path.join(sl, "0"), "a")
        fcntl.flock(fh, fcntl.LOCK_EX)
        slug, now = rd_run.resolve_worktree(self.wt)["slug"], int(time.time())
        test_run.wfile(os.path.join(sl, "0.who"), "%s %d %d abcdef012345\n" % (slug, now, os.getpid()))
        test_run.wfile(os.path.join(sl, "0.own"), "id=t\tstart=%d\tpid=%d\tcmd=long-holder\n" % (now, os.getpid()))
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
