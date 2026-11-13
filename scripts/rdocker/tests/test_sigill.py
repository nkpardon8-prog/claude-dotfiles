"""SIGILL (exit 132) is a worker incapability, never a code failure (2026-11-13: the dashboard's
vitest died with an illegal instruction on the AVX-only Mac minis, x86-64-v2, and ran on hp, v3).

The run is infra; a job safe to repeat re-runs once on another worker whose CPU is not known to be
as old; runs.log keeps outcome=rc=132, and the probe turns it into ev.isa for this repo, so the
next plan skips that worker (and every worker with no newer CPU) for rr_isa_days.
"""
import os
import sys
import unittest
import unittest.mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
import test_pool  # noqa: E402  (fixtures; its TestCases are not re-collected here)
import test_run  # noqa: E402
import test_sched  # noqa: E402

import rd_pool  # noqa: E402

rd_run = rdmods.owner("rrun")
worker, probe = test_pool.worker, test_pool.probe
NOW = test_sched.NOW
V2 = "fpu sse sse2 cx16 pni ssse3 sse4_1 sse4_2 lahf_lm popcnt avx f16c"    # i5-3210M: AVX, no AVX2
V3 = V2 + " avx2 bmi1 bmi2 fma movbe abm"                                   # i7-6700K


def isa(n=1, x86=None):
    """A probe answer whose runs.log holds n SIGILL runs of this repo (and its CPU level)."""
    p = dict(probe(), ev={"sig": [], "kind": [0, None], "pk": {}, "rows": [], "isa": [n, NOW]})
    if x86:
        p["x86"] = x86
    return p


class ProbeIsa(test_sched.ProbeExtras):
    """The worker's own runs.log -> ev.isa (this repo only, last isa_days) and its CPU's x86 level."""

    def test_sigill_rows_of_this_repo_and_the_cpu_level(self):
        def line(t, repo, out):
            return "%s repo=%s wt=b sha=c outcome=%s prepare_s=1.0 cmd_s=20.0 argv=npx vitest run a.test.ts\n" % (
                t, repo, out)
        test_run.wfile(os.path.join(self.root, "log", "runs.log"), "".join([
            line("2026-11-11T04:00:00-0700", "dash.1", "rc=132"),          # this repo (11:00Z): counts
            line("2026-11-11T11:00:00+0000", "dash.1", "rc=132"),
            line("2026-11-11T11:00:00+0000", "other.2", "rc=132"),         # another repo: not this one's
            line("2026-11-02T11:00:00+0000", "dash.1", "rc=132"),          # 9 days ago: past isa_days 7
            line("2026-11-11T11:00:00+0000", "dash.1", "rc=1"),            # a test failure: still fail
        ]))
        req = dict(test_sched.ProbeExtras.evreq(self), slug="dash.1", sig="npx vitest run a.test.ts",
                   kind="vitest-files")
        e = self.run_probe(req)["ev"]
        self.assertEqual(e["isa"], [2, NOW - 3600])
        self.assertEqual([r[0] for r in e["rows"]], ["isa", "isa", "isa", "isa", "fail"])
        self.assertNotIn("isa", self.run_probe(dict(req, slug="clean.3"))["ev"])
        self.assertEqual(self.run_probe(dict(req, isa_days=10))["ev"]["isa"][0], 3)
        self.assertNotIn("isa", self.run_probe(dict(req, since=NOW - 600))["ev"])   # history_since forgets it
        # p_infra never counts it: a worker that cannot run one repo is not unreliable for the others
        h = rd_pool.Host("m", {}, None)
        h.probe = {"ev": e}
        self.assertEqual(rd_pool.p_infra(h), (0 + 0.03 * 30) / (1 + 30))
        # the CPU level, from the flags (none without them: unknown, never guessed)
        self.assertNotIn("x86", self.run_probe({"slots": 1}))
        cpuinfo = os.path.join(self.d, "proc", "cpuinfo")
        for flags, lv in ((V2, 2), (V3, 3), ("fpu sse sse2", 1), (V2.replace(" lahf_lm", ""), 1),
                          (V3.replace(" abm", ""), 2)):
            test_run.wfile(cpuinfo, "processor\t: 0\nflags\t\t: %s\n\nprocessor\t: 1\nflags\t\t: %s\n" % (flags, flags))
            self.assertEqual(self.run_probe({"slots": 1})["x86"], lv, flags)


class PlanIsa(test_pool.PlanUnit):
    ms = [worker("mini-a", 2.0), worker("mini-b", 2.0), worker("hp", 1.0)]

    def skipped(self, answers):
        p, _ = self.plan(self.ms, answers)
        return [h.name for h, _w in p.ineligible], p

    def test_a_crash_below_a_newer_tier_skips_that_tier(self):
        sk, p = self.skipped({"mini-a": isa(2, x86=2), "mini-b": dict(probe(), x86=2), "hp": dict(probe(), x86=3)})
        self.assertEqual((sk, self.names(p)), (["mini-a", "mini-b"], ["hp"]))
        self.assertEqual([w for _h, w in p.ineligible], [
            "this repo crashed there with SIGILL (exit 132, illegal instruction) 2 times in the last 7 days: its "
            "CPU (x86-64-v2) lacks an instruction this repo's code needs",
            "its CPU (x86-64-v2) is no newer than mini-a's (v2), where this repo crashed with SIGILL (exit 132)"])
        # a tier that is not known: only the worker that crashed
        sk, p = self.skipped({"mini-a": isa(1), "mini-b": probe(), "hp": probe()})
        self.assertEqual((sk, self.names(p)), (["mini-a"], ["mini-b", "hp"]))
        self.assertIn("SIGILL (exit 132, illegal instruction) once in the last 7 days: its CPU lacks",
                      p.ineligible[0][1])

    def test_a_crash_on_a_higher_tier_too_or_on_the_top_tier_alone_skips_nobody(self):
        # the review's lock-out: a SIGILL from the code itself crashes hp too - never exit 77 for 7 days
        sk, p = self.skipped({"mini-a": isa(x86=2), "mini-b": dict(probe(), x86=2), "hp": isa(x86=3)})
        self.assertEqual((sk, sorted(self.names(p))), ([], ["hp", "mini-a", "mini-b"]))
        # the top known tier crashed alone: says nothing about the older CPUs (nor about itself)
        sk, _ = self.skipped({"mini-a": dict(probe(), x86=2), "mini-b": dict(probe(), x86=2), "hp": isa(x86=3)})
        self.assertEqual(sk, [])
        # unknown tiers that all crashed: never every worker
        sk, _ = self.skipped({"mini-a": isa(), "mini-b": isa(), "hp": isa()})
        self.assertEqual(sk, [])

    def test_the_window_is_rr_isa_days_capped_at_the_history_window(self):
        a = {"mini-a": isa(1), "mini-b": probe(), "hp": probe()}
        self.cfg["rr_isa_days"] = 3
        p, m = self.plan(self.ms, a)
        self.assertIn("once in the last 3 days", p.ineligible[0][1])
        self.assertEqual(m.call_args[0][1]["isa_days"], 3)
        self.cfg.update(rr_isa_days=30, rr_history_days=14)
        p, m = self.plan(self.ms, a)
        self.assertIn("once in the last 14 days", p.ineligible[0][1])
        self.assertEqual(m.call_args[0][1]["isa_days"], 14)


class PoolIsa(test_pool.PoolE2E):
    """Real rrun on two workers; the command dies of SIGILL on w1 only (its HOME says which)."""

    CRASH = 'case "$HOME" in *home-w1*) kill -ILL $$;; esac; echo ran-on-ok'

    def runs_log(self, w):
        return self.read(os.path.join(self.whome[w], "rr", "log", "runs.log"))

    def test_sigill_is_infra_reruns_elsewhere_then_placement_skips_that_worker(self):
        r = self.rrun("/bin/sh", "-c", self.CRASH, "vitest")
        self.assertEqual((r.returncode, r.stdout), (0, "ran-on-ok\n"), r.stderr)
        self.assertIn("rrun: w1 crashed with SIGILL (exit 132, illegal instruction): its CPU lacks an instruction "
                      "this repo's code uses; re-running once on w2", r.stderr)
        self.assertIn("rrun: pass (exit 0 on w2", r.stderr)
        self.assertEqual(self.target(), "w2")
        self.assertIn("outcome=rc=132 ", self.runs_log("w1"))
        # the next run: w1 is no candidate for this repo (it never starts there)
        n1 = self.runs_log("w1").count("\n")
        r = self.rrun("/bin/sh", "-c", self.CRASH, "vitest")
        self.assertEqual((r.returncode, r.stdout), (0, "ran-on-ok\n"), r.stderr)
        self.assertNotIn("SIGILL", r.stderr)
        self.assertEqual((self.target(), self.runs_log("w1").count("\n")), ("w2", n1))
        w = self.rrun("--where", "/bin/sh", "-c", self.CRASH, "vitest")
        self.assertIn("this repo crashed there with SIGILL", w.stdout + w.stderr)

    def test_a_job_not_safe_to_repeat_is_infra_and_not_rerun(self):
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", "echo x >> %s; %s" % (marker, self.CRASH))
        self.assertEqual(r.returncode, 132, r.stderr)
        self.assertEqual(self.read(marker), "x\n")
        self.assertNotIn("re-running", r.stderr)
        line = [x for x in r.stderr.splitlines() if x.startswith("rrun: infra (exit 132 on w1")]
        self.assertEqual(len(line), 1, r.stderr)
        self.assertIn("rerun it; placement sends this repo to a newer CPU when the pool has one", line[0])

    def test_a_sigill_on_the_rerun_too_is_the_codes_fail_and_restricts_nothing(self):
        r = self.rrun("/bin/sh", "-c", "kill -ILL $$", "vitest")
        self.assertEqual(r.returncode, 132, r.stderr)
        self.assertIn("re-running once on w2", r.stderr)
        line = [x for x in r.stderr.splitlines() if x.startswith("rrun: fail (exit 132 on w2")]
        self.assertEqual(len(line), 1, r.stderr)
        self.assertIn("crashed with SIGILL on every CPU tier tried (w1, w2): a bug in the code, not the worker",
                      line[0])
        self.assertIn("the command's own result: fix the code", line[0])
        # the next run is not restricted: both runs.log hold a 132, so the evidence skips nobody
        w = self.rrun("--where", "/bin/sh", "-c", "true", "vitest")
        self.assertNotIn("SIGILL", w.stdout + w.stderr)
        r = self.rrun("/bin/sh", "-c", "echo fine", "vitest")
        self.assertEqual((r.returncode, r.stdout, self.target()), (0, "fine\n", "w1"), r.stderr)

    def test_a_normal_nonzero_exit_is_still_fail_and_never_rerun(self):
        r = self.rrun("/bin/sh", "-c", "echo once; exit 3", "vitest")
        self.assertEqual((r.returncode, r.stdout), (3, "once\n"), r.stderr)
        self.assertIn("rrun: fail (exit 3 on w1", r.stderr)
        self.assertNotIn("re-running", r.stderr)
        self.assertNotIn("SIGILL", self.rrun("--where", "/bin/sh", "-c", "true", "vitest").stdout)


class HostLoopIsa(unittest.TestCase):
    """2026-11-13 live run: the rerun's worker (hp) had no free slot, and the plain "next host" step
    then sent the job to mini-b - the same CPU as the mini-a that had just crashed. A SIGILL drops
    the worker and its CPU generation from the job's list for every later try, not only the rerun."""

    def host(self, name, x86):
        h = rd_pool.Host(name, {"host": name}, None)
        h.probe = {"x86": x86}
        return h

    def test_after_a_sigill_no_later_try_lands_on_the_same_cpu_generation(self):
        from types import SimpleNamespace
        a, hp, b = self.host("mini-a", 2), self.host("hp", 3), self.host("mini-b", 2)
        tried = []

        def fake(ctx, h, argv, *rest, **kw):
            tried.append(h.name)
            return {"mini-a": ("isa", "mini-a crashed with SIGILL"),
                    "hp": ("busy", "hp had no free slot after 2 min")}[h.name]
        ctx = SimpleNamespace(job=rd_pool.classify(["npx", "vitest", "run"]), t0=0.0, cache=None,
                              cfg={"rr_wait_min": 0}, plan=SimpleNamespace(pool=True), moves=0)
        with unittest.mock.patch.object(rd_run, "attempt_on", side_effect=fake), \
                unittest.mock.patch.object(rd_run, "note"):
            kind, rc = rd_run.host_loop(ctx, [a, hp, b], ["npx", "vitest", "run"])
        self.assertEqual(tried, ["mini-a", "hp"])                          # never mini-b
        self.assertEqual((kind, int(rc), rc.klass), ("done", rd_run.EXIT_BUSY, "infra"))
        # unknown CPU levels: only the crashed worker leaves; the next one is the rerun (and a SIGILL
        # there too is the code's, as it is not known to be the same CPU)
        tried.clear()
        a.probe, b.probe = {}, {}

        def fake2(ctx, h, argv, *rest, **kw):
            tried.append(h.name)
            return ("isa", "%s crashed with SIGILL" % h.name) if h.name.startswith("mini") else ("done", 0)
        with unittest.mock.patch.object(rd_run, "attempt_on", side_effect=fake2), \
                unittest.mock.patch.object(rd_run, "note"):
            kind, rc = rd_run.host_loop(ctx, [a, b, hp], ["npx", "vitest", "run"])
        self.assertEqual((tried, kind, int(rc), rc.klass), (["mini-a", "mini-b"], "done", 132, "fail"))
        # known tiers: v2 crashed, the rerun on v3 crashed too -> the code's own fail, named per tier
        tried.clear()
        a.probe, b.probe = {"x86": 2}, {"x86": 2}
        with unittest.mock.patch.object(rd_run, "attempt_on", side_effect=lambda c, h, *r, **k: (
                tried.append(h.name) or ("isa", "%s crashed with SIGILL" % h.name))), \
                unittest.mock.patch.object(rd_run, "note"):
            kind, rc = rd_run.host_loop(ctx, [a, b, hp], ["npx", "vitest", "run"])
        self.assertEqual((tried, int(rc), rc.klass), (["mini-a", "hp"], 132, "fail"))
        self.assertEqual(rc.why, "crashed with SIGILL on every CPU tier tried (mini-a x86-64-v2, hp x86-64-v3): "
                                 "a bug in the code, not the worker")


for _cls, _base in ((ProbeIsa, test_sched.ProbeExtras), (PlanIsa, test_pool.PlanUnit), (PoolIsa, test_pool.PoolE2E)):
    for _n in [n for n in vars(_base) if n.startswith("test")]:
        setattr(_cls, _n, None)       # the base's fixture, not its tests
del _cls, _base                       # module-level TestCase names are collected: leave none behind


if __name__ == "__main__":
    unittest.main()
