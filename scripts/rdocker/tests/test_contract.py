"""The agent contract (2026-11-11, owner: "ensure it's agent oriented"): every rrun result is one
class - pass / fail / infra / needs-human - named by the first `rrun:` line after the command's
output, with a distinct exit code for "never ran" / "may have run" / config. Checked both ways:
every code in rd_run.EXIT_CODES is in the docs' table (commands/docker.md "Exit codes") and the
table has nothing else, and every documented code is really emitted by a run (one scenario each).

Also here: the field findings of 2026-11-11 (a vitest suite that needs a test DB is a db job; a
missing-DB run is infra, never a test failure; the silence line names the last test file), the
version guarantee (layer 2) and the background warm trigger.
"""
import fcntl
import json
import os
import re
import sys
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
import test_pool  # noqa: E402
import test_run  # noqa: E402

import rd_pool  # noqa: E402

rd_run = rdmods.owner("rrun")
rd_common = rdmods.owner("RRUN_STATE")
DOCS = os.path.join(os.path.expanduser("~"), ".claude-dotfiles", "commands", "docker.md")
DOCS = os.environ.get("RRUN_DOCS_MD") or (DOCS if os.path.isfile(DOCS) else
                                          os.path.join(rdmods.STAGE, "_docs_stage", "docker.md"))


def doc_codes():
    """-> {code: class} from the docs' exit-code table: rows `| 76 | infra | ... |`."""
    with open(DOCS) as f:
        text = f.read()
    sec = text.split("### Exit codes and result classes", 1)[1].split("\n## ", 1)[0]
    return {int(m.group(1)): m.group(2) for m in re.finditer(r"^\| (\d+) +\| (pass|fail|infra|needs-human) +\|",
                                                            sec, re.M)}


class Table(unittest.TestCase):
    def test_docs_table_matches_the_code_exactly(self):
        got = doc_codes()
        want = {c: k for c, (k, _) in rd_run.EXIT_CODES.items()}
        self.assertEqual(got, want, "docker.md 'Exit codes and result classes' vs rd_run.EXIT_CODES")
        import rd_cache
        self.assertTrue(set(want) <= set(rd_cache.INFRA_RC), "an rrun-made code must never be cached")

    def test_result_line(self):
        rd_run.RESULT.update(host="hp", secs=12.4)
        self.assertEqual(rd_run.result_line(0), "rrun: pass (exit 0 on hp, 12s)")
        self.assertEqual(rd_run.result_line(1), "rrun: fail (exit 1 on hp, 12s) - the command's own result: fix the code")
        self.assertEqual(rd_run.result_line(rd_run.infra(76, "lost it")),
                         "rrun: infra (exit 76 on hp, 12s; lost it) - rerun it; never debug it")
        self.assertTrue(rd_run.result_line(rd_run.Rc(77)).startswith("rrun: needs-human (exit 77"))

    def test_sharded_result_is_the_test_result_when_every_shard_ran(self):
        Rc, infra = rd_run.Rc, rd_run.infra
        self.assertEqual(rd_run.shards_rc([0, 0, 0]), 0)
        r = rd_run.shards_rc([0, 1, infra(76, "lost")])         # a real failure IS the result
        self.assertEqual((r, isinstance(r, Rc)), (1, False))
        r = rd_run.shards_rc([0, infra(75, "never ran"), 0])     # incomplete: no pass claimed
        self.assertEqual((int(r), r.klass), (75, "infra"))
        self.assertIn("1 of 3 shards gave no test result", r.why)
        r = rd_run.shards_rc([infra(75, "a"), infra(76, "b")])
        self.assertEqual(int(r), 76)                             # may-have-run outranks never-ran
        self.assertEqual(int(rd_run.shards_rc([0, None])), 76)   # a shard thread with no result


class Emitted(test_run.RunBase):
    """One scenario per documented code: the code is emitted and the class line names its class."""

    def check(self, r, code, klass):
        self.assertEqual(r.returncode, code, r.stderr)
        lines = [x for x in r.stderr.splitlines() if x.startswith("rrun: %s (exit %d" % (klass, code))]
        self.assertEqual(len(lines), 1, r.stderr)
        return lines[0]

    def hold(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.addCleanup(os.close, fd)

    def test_every_documented_code_is_emitted(self):
        seen = {}

        def scenario(code, klass, r):
            seen[code] = self.check(r, code, klass)
        # 69: the runner's own (the bare repo vanished between the push and the run - a race the
        # client cannot stage, because its push creates the repo): from the runner, as the worker
        # sends it; the client maps every runner code the same way (65 / 70 / 78 below, end to end)
        import test_runner
        rt = test_runner.RunnerTest("setUp")
        rt.setUp()
        self.addCleanup(rt.tearDown)
        self.assertEqual(rt.run_runner(["true"], repo_slug="nope").rc, 69)
        self.assertEqual(rd_run.Rc(69).klass, "infra")
        seen[69] = "runner"
        self.doCleanups()
        # 0 / 1: the command's own
        scenario(0, "pass", self.rrun("/bin/sh", "-c", "true"))
        scenario(1, "fail", self.rrun("/bin/sh", "-c", "exit 1"))
        # 72: this worktree's lock held past the wait
        self.write_cfg(rr_wt_wait_min=0.02)
        wt = rd_run.resolve_worktree(self.wt)
        self.hold(os.path.join(self.home, ".local", "state", "rdocker", "rrun-%s.lock" % wt["wt12"]))
        scenario(72, "infra", self.rrun("/bin/sh", "-c", "true"))
        self.doCleanups()
        # 73: every slot busy past rr_wait_min
        self.write_cfg(rr_slots=1, rr_slot_wait_s=1, rr_wait_min=0.03)
        self.hold(os.path.join(self.home, "rr", "slots", "0"))
        scenario(73, "infra", self.rrun("/bin/sh", "-c", "true", timeout=90))
        self.doCleanups()
        self.write_cfg()
        # 75: never ran (no worker, strict)
        scenario(75, "infra", self.rrun("/bin/sh", "-c", "true", FAKE_SSH_DOWN="1", RRUN_STRICT="1",
                                        RRUN_RECONNECT_WAIT="0"))
        # 76: started, then lost for good
        self.write_cfg(rr_reattach_backoff_s=[0, 0, 0])
        scenario(76, "infra", self.rrun("/bin/sh", "-c", "true", FAKE_SSH_DROP="1"))
        self.write_cfg()
        # 124: its wall-clock cap
        scenario(124, "infra", self.rrun("/bin/sh", "-c", "sleep 60", RRUN_TIMEOUT="0.02", timeout=60))
        # 65: the worker refuses an unsafe mirror dir (a symlink)
        w2 = os.path.join(self.home, "rr", "w2")
        if os.path.isdir(w2):
            os.rename(w2, w2 + ".real")
        os.symlink(self.d, w2)
        scenario(65, "needs-human", self.rrun("/bin/sh", "-c", "true"))
        os.unlink(w2)
        if os.path.isdir(w2 + ".real"):
            os.rename(w2 + ".real", w2)
        # 70: the runner itself fails (its tmp dir cannot be made)
        tmp = os.path.join(self.home, "rr", "tmp")
        if os.path.isdir(tmp):
            os.rename(tmp, tmp + ".old")
        test_run.wfile(tmp, "not a dir\n")
        scenario(70, "infra", self.rrun("/bin/sh", "-c", "true"))
        os.unlink(tmp)
        # 78: installing dependencies fails (npm ci exits 1 on the worker)
        test_run.wfile(os.path.join(self.wt, "package.json"), '{"name": "x", "version": "1.0.0"}\n')
        test_run.wfile(os.path.join(self.wt, "package-lock.json"), '{"lockfileVersion": 3}\n')
        self.git("-C", self.wt, "add", "-A")
        self.git("-C", self.wt, "commit", "-qm", "pkg")
        test_run.wfile(os.path.join(self.bin, "npm"), "#!/bin/sh\necho npm says no; i=0\n"
                       "while [ $i -lt 60 ]; do echo log line $i; i=$((i+1)); done\nexit 1\n", 0o755)
        r = self.rrun("/bin/sh", "-c", "true")
        scenario(78, "infra", r)
        self.assertIn("(npm log: last 25 of 61 lines)", r.stderr)      # the tail only, never the whole log
        self.assertNotIn("log line 10\n", r.stderr)
        os.unlink(os.path.join(self.bin, "npm"))
        # 77: no worker may take it (a pool whose classes leave none)
        fleet = os.path.join(self.d, "fleet.json")
        test_pool.write_fleet(fleet, [dict(test_pool.worker("w1"), classes=["light"]),
                                      dict(test_pool.worker("w2"), classes=["db"])])
        self.write_cfg(fleet_path=fleet)
        scenario(77, "needs-human", self.rrun("npx", "tsc", "--noEmit", RRUN_RECONNECT_WAIT="0"))
        self.assertEqual(set(doc_codes()) - set(seen), set(), "documented exit codes never emitted")


class NoTestDb(test_run.RunBase):
    """Field finding A (2026-11-11): ~2,500 of 2,868 "failures" were a missing test DB. Review round 1:
    the output's DB signature is ADVISORY only - the exit and class stay the command's (a real
    failure must never hide behind a DB message); placement (db class) is the fix."""

    def last_lines(self, r):
        return [x for x in r.stderr.splitlines() if x.startswith("rrun: ")]

    def test_missing_db_output_adds_a_hint_never_changes_the_result(self):
        r = self.rrun("/bin/sh", "-c", "echo 'PrismaClientInitializationError: Environment variable not found: "
                      "DATABASE_URL.'; echo 'Environment variable not found: DATABASE_URL'; echo ' FAIL  src/a.test.ts'; exit 1")
        self.assertEqual(r.returncode, 1, r.stderr)
        cls, hint = self.last_lines(r)[-2:]
        self.assertTrue(cls.startswith("rrun: fail (exit 1"), r.stderr)
        self.assertEqual(hint, "rrun: 2 failures mention DATABASE_URL - likely no test DB on mini; rerun with npm run test:db")
        # an immediate message with no newline before the end, on stdout, is still seen
        r = self.rrun("/bin/sh", "-c", "printf 'Error: connect ECONNREFUSED 127.0.0.1:5432'; exit 1")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("rrun: 1 failure mentions DATABASE_URL - likely no test DB on mini", r.stderr)
        # a passing run that prints the words: no hint
        r = self.rrun("/bin/sh", "-c", "echo 'DATABASE_URL not set (expected in this test)'; exit 0")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("mention", r.stderr)
        self.assertTrue(self.last_lines(r)[-1].startswith("rrun: pass (exit 0"))

    def test_scan_sees_stdout_before_started_and_the_unterminated_tail(self):
        sess = rd_run.Session({}, [], "0" * 32, rd_run.Timing(False))
        sess.scan(b"x\nEnvironment variable not found: DATABASE_URL")      # STARTED not seen yet
        self.assertEqual(sess.no_db_n, 0)                                     # (no newline yet)
        sess.scan(b"", "out", final=True)
        self.assertEqual(sess.no_db_n, 1)
        sess.scan(b"DATABASE_URL is not set\n", "err")                       # stderr before STARTED:
        self.assertEqual(sess.no_db_n, 1)                                     # the runner's own notes

    def test_silence_line_names_the_last_test_file(self):
        """Field finding B: a `npm run test:db` hung after one file until the cap, with no sign of where."""
        r = self.rrun("/bin/sh", "-c", "echo ' ✓ src/__tests__/a.db.test.ts (3 tests) 120ms'; sleep 3; echo done",
                      RRUN_SILENT_MIN="0.02")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stderr, r"rrun: no output for \d+ s \(worker mini, running \d+ s; last test file "
                                   r"src/__tests__/a\.db\.test\.ts, named \d+ s ago\)")


class DbSuite(unittest.TestCase):
    """Field finding A, classification: the run's suite needs a DB -> class db (never sharded)."""

    def pkg(self, scripts, files=(), setup=None):
        d = os.path.join(rdmods.TEST_HOME, "dbsuite-%d" % len(os.listdir(rdmods.TEST_HOME)))
        test_run.wfile(os.path.join(d, "package.json"), json.dumps({"scripts": scripts}))
        for f in files:
            test_run.wfile(os.path.join(d, f), "x\n")
        if setup is not None:
            test_run.wfile(os.path.join(d, "vitest.config.ts"),
                           "export default { test: { setupFiles: ['src/setup.ts'] } }\n")
            test_run.wfile(os.path.join(d, "src", "setup.ts"), setup)
        return d

    def test_db_markers_make_a_suite_a_db_job(self):
        vit = ["npx", "vitest", "run"]
        d = self.pkg({"test": "vitest run", "test:db": "node scripts/test-with-db.mjs"}, ["src/a.test.ts"])
        self.assertEqual(rd_pool.classify(vit, cwd=d)["cls"], "db")                # the repo's own marker
        self.assertEqual(rd_pool.classify(["npm", "test"], cwd=d)["cls"], "db")    # via its script
        self.assertEqual(rd_pool.classify(vit + ["src/a.test.ts"], cwd=d)["cls"], "normal")   # named file
        self.assertEqual(rd_pool.classify(vit + ["src/x.db.test.ts"], cwd=d)["cls"], "db")
        d = self.pkg({"test": "vitest run"}, ["src/a.test.ts", "src/deep/b.db.test.ts"])
        self.assertEqual(rd_pool.classify(vit + ["src"], cwd=d)["cls"], "db")      # a db test in scope
        d = self.pkg({"test": "vitest run"}, ["src/a.test.ts"],
                     setup="// DATABASE_URL in a comment\nconst u = process.env.DATABASE_URL;\n")
        self.assertEqual(rd_pool.classify(vit, cwd=d)["cls"], "db")                # setup reads it
        d = self.pkg({"test": "vitest run"}, ["src/a.test.ts"], setup="// only DATABASE_URL in a comment\n")
        self.assertEqual(rd_pool.classify(vit, cwd=d)["cls"], "normal")
        self.assertEqual(rd_pool.classify(vit)["cls"], "normal")                   # no cwd: argv only
        db = rd_pool.classify(vit, cwd=self.pkg({"test:db": "x"}))
        self.assertEqual(rd_pool.shardable(vit, db)[0], False)                      # never sharded


class Version(unittest.TestCase):
    """Layer 2 of the version guarantee, in the runner handshake, simplified by owner policy (agents are
    never blocked; layer 1 autopull keeps Macs current): ONE update + re-exec per invocation, only from
    the main attempt and only before anything started; otherwise it runs and says so at the end."""

    def setUp(self):
        self.saved = dict(rd_run.VERSION)
        self.addCleanup(lambda: (rd_run.VERSION.clear(), rd_run.VERSION.update(self.saved)))
        rd_run.VERSION.update(started=False, tried=False, behind=0, why=None, unknown=False)

    def test_a_newer_or_unknown_version_only_warns(self):
        # owner policy: never block or restart an agent's job; the 2-minute autopull updates the Mac
        newer = rd_common.POOL_VERSION + 1
        self.assertFalse(rd_run.version_seen(rd_common.POOL_VERSION))      # current: go on, no line
        self.assertEqual(rd_run.version_lines(), [])
        self.assertFalse(rd_run.version_seen(newer))                       # newer: go on, warn at the end
        self.assertFalse(rd_run.version_seen(newer + 1))
        self.assertEqual(rd_run.version_lines(), ["rrun: this Mac's pool code is behind (v%d < v%d); it updates "
                                                  "itself within 2 min" % (rd_common.POOL_VERSION, newer + 1)])
        self.assertFalse(rd_run.version_seen(None))                        # unknown: run, warn
        self.assertIn("rrun: a worker could not report its pool version; ran anyway", rd_run.version_lines())
        self.assertFalse(hasattr(rd_run, "try_update"))                    # no self-update path exists

    def run_base(self):
        t = test_run.RunBase("setUp")
        t.setUp()
        self.addCleanup(t.tearDown)
        return t

    def test_a_newer_worker_never_blocks_the_job(self):
        t = self.run_base()                                               # no fleet: one host, never probed
        test_run.wfile(os.path.join(t.home, "rr", "pool_version"), "%d\n" % (rd_common.POOL_VERSION + 5))
        marker = os.path.join(t.d, "ran")
        r = t.rrun("/bin/sh", "-c", "touch %s" % marker)                   # runs, then says the Mac is behind
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(marker))
        last = [x for x in r.stderr.splitlines() if x.startswith("rrun: ")][-2:]
        self.assertTrue(last[0].startswith("rrun: pass (exit 0"), r.stderr)
        self.assertEqual(last[1], "rrun: this Mac's pool code is behind (v%d < v%d); it updates itself within "
                                  "2 min" % (rd_common.POOL_VERSION, rd_common.POOL_VERSION + 5))
        with open(os.path.join(t.home, "rr", "pool_version")) as f:
            self.assertEqual(f.read().strip(), str(rd_common.POOL_VERSION + 5))   # never lowered

    def test_unknown_worker_version_fails_open(self):
        t = self.run_base()
        test_run.wfile(os.path.join(t.home, "rr", "pool_version"), "garbage\n")   # unreadable as a number
        r = t.rrun("/bin/sh", "-c", "true")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("rrun: a worker could not report its pool version; ran anyway", r.stderr)
        with open(os.path.join(t.home, "rr", "pool_version")) as f:
            self.assertEqual(f.read().strip(), "garbage")                  # never overwritten on a guess

    def test_a_symlinked_rr_root_still_reports_its_version(self):
        # nickmbp keeps Spotlight out with ~rd/rr -> rr.noindex: that must not make every job warn
        t = self.run_base()
        rr, real = os.path.join(t.home, "rr"), os.path.join(t.home, "rr.noindex")
        if os.path.isdir(rr) and not os.path.islink(rr):
            os.rename(rr, real)
        else:
            os.makedirs(real, exist_ok=True)
        os.symlink("rr.noindex", rr)
        r = t.rrun("/bin/sh", "-c", "true")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("could not report its pool version", r.stderr)
        with open(os.path.join(real, "pool_version")) as f:
            self.assertEqual(f.read().strip(), str(rd_common.POOL_VERSION))

    def test_pool_version_is_raised_under_a_lock_and_never_lowered(self):
        t = self.run_base()
        rr = os.path.join(t.home, "rr")
        os.makedirs(rr, exist_ok=True)
        lk = open(os.path.join(rr, "pool_version.lock"), "a")
        fcntl.flock(lk, fcntl.LOCK_EX)                                     # another writer holds it
        p = t.popen("/bin/sh", "-c", "true")
        time.sleep(2.0)
        self.assertIsNone(p.poll())                                        # waits for the lock
        test_run.wfile(os.path.join(rr, "pool_version"), "9\n")            # that writer raised it to 9
        lk.close()
        out, err = p.communicate(timeout=60)
        self.assertEqual(p.returncode, 0, err)
        self.assertIn("(v%d < v9)" % rd_common.POOL_VERSION, err)          # it read 9 under the lock
        with open(os.path.join(rr, "pool_version")) as f:
            self.assertEqual(f.read().strip(), "9")                        # our lower one never replaced it

    def test_runner_raises_the_workers_pool_version_and_logs_the_client(self):
        t = self.run_base()
        r = t.rrun("/bin/sh", "-c", "true")
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(t.home, "rr", "pool_version")) as f:
            self.assertEqual(f.read().strip(), str(rd_common.POOL_VERSION))
        with open(os.path.join(t.home, "rr", "log", "runs.log")) as f:
            log = f.read()
        self.assertRegex(log, r" pv=%d node=(\d+|-)\n" % rd_common.POOL_VERSION)
        self.assertRegex(log, r" setup=warm pred_s=\S+ client=\S+ pv=")
        route = os.path.join(t.home, ".local", "state", "rdocker", "route.log")
        with open(route) as f:
            last = f.read().strip().splitlines()[-1]
        self.assertRegex(last, r"\tcache_s=[\d.]+ plan_s=[\d.]+ push_s=[\d.]+ overlay_s=[\d.]+ remote_s=[\d.]+ "
                               r"start_s=[\d.]+ client=")
        import rd_warm
        self.assertEqual(os.path.realpath(rd_warm.parse_route([last.replace(last[:19], time.strftime(
            "%Y-%m-%d %H:%M:%S"))], 0)[0][1]), os.path.realpath(t.wt))   # the cwd, without the timings


class AfterGo(unittest.TestCase):
    """Review round 1: after GO only an authenticated EXIT is the command's verdict."""

    def test_runner_dying_after_go_without_exit_is_76_never_fail(self):
        class FakeSession:
            def __init__(self, *a, **k):
                self.go_sent, self.exit_rc, self.timed_out, self.first_sig, self.ints = True, None, False, 0, 0
                self.outdated = self.gone = self.unavail = None
                self.gave_up = self.used_docker = self.norun = False
                self.no_db_n = 0

            def run(self):
                return 70                    # e.g. a full disk while it made the spool, after GO
        h = rd_pool.Host("w", dict(rd_common.DEFAULTS, host="w"))
        wt = {"top": "/x", "relcwd": "", "wt12": "0" * 12, "sha": "0" * 40, "slug": "app.12345678"}
        job = rd_pool.classify(["npx", "vitest", "run"])
        with mock.patch.object(rd_run, "push", return_value=[]), \
                mock.patch.object(rd_run, "build_overlay", return_value=(b"", [], [], [])), \
                mock.patch.object(rd_run, "runner_frames", return_value=([], "0" * 32)), \
                mock.patch.object(rd_run, "record"), mock.patch.object(rd_run, "Session", FakeSession), \
                mock.patch.object(rd_run, "reattach", return_value=None) as ra:
            kind, rc = rd_run.attempt(h, wt, ["npx", "vitest", "run"], [], rd_run.Timing(False), time.monotonic(),
                                      job, True, deps=[])
        ra.assert_called_once()                                            # it tried to find the result
        self.assertEqual((kind, int(rc), rc.klass), ("done", 76, "infra"))
        self.assertIn("ended (exit 70) after the start without the command's result", rc.why)


class ColdFallback(test_pool.PlanUnit):
    """Review round 1: the cold-setup fallback counts workers that can take work, not ones that answered."""

    def test_an_off_worker_does_not_block_the_fallback(self):
        slow = {"ev": {"sig": [], "kind": [0, None], "pk": {}, "rows": [["pass", 400.0, 1]] * 4}}
        ans = {"a": dict(test_pool.probe(warm_deps=0), **slow), "b": test_pool.probe(share="off")}
        p, _ = self.plan([test_pool.worker("a"), test_pool.worker("b")], ans,
                         job=rd_pool.classify(["npx", "tsc", "--noEmit"]))
        self.assertEqual([h.name for h in p.hosts], ["a", "b"])            # a restored, off b last
        self.assertEqual(p.ineligible, [])


for _n in [n for n in vars(test_pool.PlanUnit) if n.startswith("test")]:
    setattr(ColdFallback, _n, None)


class WarmTrigger(unittest.TestCase):
    """Review round 1: the background warm waits for the foreground job's worktree lock (never skips
    its own repo), and the throttle starts only when a warm really starts."""

    def clear(self):
        d = rd_common.STATE_DIR
        for f in os.listdir(d) if os.path.isdir(d) else []:
            if f.startswith("warm-trigger-"):
                os.unlink(os.path.join(d, f))

    def test_spawns_one_waiting_warm_and_sets_no_throttle_itself(self):
        self.clear()
        cold, warm = rd_pool.Host("a", {"host": "a"}), rd_pool.Host("b", {"host": "b"})
        cold.probe, warm.probe = {"warm_deps": 0}, {"warm_deps": 1}
        plan = rd_pool.Plan([warm, cold], True)
        wt = {"slug": "app.1234abcd", "top": "/x"}
        job = rd_pool.classify(["npx", "tsc", "--noEmit"])
        with mock.patch.object(rd_run.subprocess, "Popen") as po:
            self.assertTrue(rd_run.trigger_warm({}, plan, wt, [["", "a" * 64]], job))
            self.assertFalse(rd_run.trigger_warm({}, plan, wt, [["", "a" * 64]], job))   # one already waits
            self.assertFalse(rd_run.trigger_warm({}, rd_pool.Plan([warm], True), wt, [["", "b" * 64]], job))
            self.assertFalse(rd_run.trigger_warm({"rr_warm_trigger": False}, plan, wt, [["", "c" * 64]], job))
        self.assertEqual(po.call_count, 1)
        argv = po.call_args[0][0]
        self.assertEqual(argv[-8:-4], ["warm", "--once", "--repo", os.getcwd()])
        self.assertEqual(argv[-4], "--after-lock")
        self.assertEqual(int(argv[-3]), 60 * 60 + 60)                     # the job's cap + a minute
        key = argv[-1]
        stamp, pending = rd_run.warm_trigger_paths(key)
        self.assertTrue(os.path.exists(pending))
        self.assertFalse(os.path.exists(stamp))                           # no throttle until it starts
        self.assertTrue(po.call_args[1]["start_new_session"])

    def repo(self):
        return {"slug": "app.1234abcd", "top": "/x", "wt12": "abcdef012345", "deps": [], "sha": "0" * 40}

    def test_waits_for_the_worktree_before_the_pass_lock_then_stamps_and_clears(self):
        import threading
        import rd_warm
        self.clear()
        stamp, pending = rd_run.warm_trigger_paths("k1")
        test_run.wfile(pending, "/x\n")
        repo = self.repo()
        rd_common.ensure_dirs()
        fd = os.open(rd_run.wt_lock_path(repo["wt12"]), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)                                    # the foreground job holds it
        free_meanwhile = []

        def probe_pass_lock():                                            # while the trigger waits...
            got = rd_warm.take_flock(rd_warm.PASS_LOCK)
            free_meanwhile.append(got is not None)
            if got is not None:
                os.close(got)
            os.close(fd)                                                  # ...then the job ends
        threading.Timer(1.0, probe_pass_lock).start()
        h = rd_pool.Host("a", {"host": "a"}, {})
        with mock.patch.object(rd_warm, "worker_hosts", return_value=[h]), \
                mock.patch.object(rd_warm, "repo_at", return_value=repo), \
                mock.patch.object(rd_warm, "warm_one", return_value="warm") as wo:
            rd_warm.run_pass({}, "/x", after_lock=20, trigger="k1")
        self.assertEqual(free_meanwhile, [True])                          # other repos could warm meanwhile
        wo.assert_called_once()
        self.assertTrue(os.path.exists(stamp))                            # the throttle starts now
        self.assertFalse(os.path.exists(pending))

    def test_a_busy_pass_lock_keeps_the_request_for_the_next_pass(self):
        import rd_warm
        self.clear()
        stamp, pending = rd_run.warm_trigger_paths("k2")
        test_run.wfile(pending, self.wt_dir() + "\n")
        repo = self.repo()
        h = rd_pool.Host("a", {"host": "a"}, {})
        lk = rd_warm.take_flock(rd_warm.PASS_LOCK)                        # a scheduled pass runs
        try:
            with mock.patch.object(rd_warm, "worker_hosts", return_value=[h]), \
                    mock.patch.object(rd_warm, "repo_at", return_value=repo), \
                    mock.patch.object(rd_warm, "warm_one", return_value="warm") as wo:
                rd_warm.run_pass({}, "/x", after_lock=5, trigger="k2")
            wo.assert_not_called()
            self.assertTrue(os.path.exists(pending))                      # still queued
            self.assertFalse(os.path.exists(stamp))
        finally:
            os.close(lk)
        # the next plain pass warms the queued repo first, then clears the request
        with mock.patch.object(rd_warm, "worker_hosts", return_value=[h]), \
                mock.patch.object(rd_warm, "discover", return_value=[]), \
                mock.patch.object(rd_warm, "warm_one", return_value="warm") as wo:
            rd_warm.run_pass({})
        self.assertEqual(wo.call_args[0][1]["top"], os.path.realpath(self.wt_dir()))
        self.assertFalse(os.path.exists(pending))
        self.assertTrue(os.path.exists(stamp))

    def wt_dir(self):
        """A real git worktree with a commit (rd_warm.queued resolves the marker's path)."""
        if not hasattr(self, "_wt"):
            t = test_run.RunBase("setUp")
            t.setUp()
            self.addCleanup(t.tearDown)
            self._wt = t.wt
        return self._wt


if __name__ == "__main__":
    unittest.main()
