"""rd_warm (`rdocker warm`): discovery from route.log, worker selection, politeness, the down->up
trigger, and an end-to-end warm through the real push + the real runner (fake ssh from
tests/test_run.py, one HOME per worker) that is idempotent: warm twice = no second push/install.
"""
import fcntl
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
import test_pool  # noqa: E402  (worker / write_fleet / probe helpers)

import rd_pool  # noqa: E402
import rd_warm  # noqa: E402

rd_run = rdmods.owner("rrun")
rd_common = rdmods.owner("RRUN_STATE")
ENTRY = os.path.join(rdmods.STAGE, "rdocker.py")
wfile = test_run.wfile


def git(*args, cwd=None):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
                          + list(args), cwd=cwd, check=True, capture_output=True, text=True).stdout


def make_repo(path, files):
    for n, c in files.items():
        wfile(os.path.join(path, n), c)
    git("init", "-q", path)
    git("-C", path, "add", "-A")
    git("-C", path, "commit", "-qm", "init")
    return os.path.realpath(path)


def route_line(ts, target, argv, cwd, rc=0, secs=1.0):
    return "%s %-5s %-8s %s rc=%s %.1fs | %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts)),
                                                  target, "rrun", argv, rc, secs, cwd)


class Discovery(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="warm-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        lock = '{"lockfileVersion": 3}'
        self.a = make_repo(os.path.join(self.d, "app"), {
            "package.json": "{}", "package-lock.json": lock, "server/package.json": "{}",
            "server/package-lock.json": lock, "client/package.json": "{}", "client/package-lock.json": lock,
            "server/src/x.ts": "x"})
        self.a2 = os.path.join(self.d, "app-wt2")        # a second worktree of the same repo
        git("-C", self.a, "worktree", "add", "-q", self.a2)
        self.a2 = os.path.realpath(self.a2)
        self.b = make_repo(os.path.join(self.d, "lib"), {"package.json": "{}", "package-lock.json": lock})
        self.c = make_repo(os.path.join(self.d, "old"), {"a": "a"})
        self.log = os.path.join(self.d, "route.log")

    def test_recent_repos_newest_first_one_per_slug(self):
        now = time.time()
        with open(self.log, "w") as f:
            f.write(route_line(now - 3600, "hp", "npx vitest run", os.path.join(self.a, "server", "src")))
            f.write(route_line(now - 1800, "laptop", "npm --prefix client test", self.a))
            f.write(route_line(now - 600, "nickmbp", "npx vitest run", self.a2))       # same slug, other top
            f.write(route_line(now - 7200, "hp", "npm test", self.b))
            f.write(route_line(now - 50 * 3600, "hp", "npm test", self.c))            # outside 48 h
            f.write(route_line(now - 60, "hp", "npm test", os.path.join(self.d, "gone")))  # no such dir
            f.write(route_line(now - 60, "hp", "bash -c 'cd admin-client && npx vitest run src/vie...",
                               self.b))                                                # truncated argv
            f.write("2026-11-09 20:00:00 mini  run      postgres:16 | %s\n" % self.c)  # not an rrun line
            f.write("garbage\n")
        repos = rd_warm.discover({}, now=now, paths=[self.log])
        self.assertEqual([r["top"] for r in repos], [self.b, self.a2])
        # app's newest line came from its second worktree, so that worktree is the one warmed
        a = repos[1]
        self.assertEqual(a["slug"], rd_run.resolve_worktree(self.a)["slug"])
        self.assertEqual((a["relcwd"], a["deps"]), ("", [""]))
        self.assertEqual(repos[0]["deps"], [""])
        self.assertRegex(repos[0]["sha"], r"^[0-9a-f]{40}$")

    def test_deps_dirs_unioned_over_the_repos_lines(self):
        now = time.time()
        with open(self.log, "w") as f:
            f.write(route_line(now - 3600, "hp", "npx vitest run", os.path.join(self.a, "server", "src")))
            f.write(route_line(now - 1800, "laptop", "npm --prefix client test", self.a))
        (a,) = rd_warm.discover({}, now=now, paths=[self.log])
        self.assertEqual((a["top"], a["deps"]), (self.a, ["", "client", "server"]))
        # the window is configurable; an older rotation (route.log.1) is read too
        old = self.log + ".1"
        with open(old, "w") as f:
            f.write(route_line(now - 10 * 3600, "hp", "npm test", self.b))
        self.assertEqual([r["top"] for r in rd_warm.discover({}, now=now, paths=[old, self.log])],
                         [self.a, self.b])
        self.assertEqual([r["top"] for r in rd_warm.discover({"rr_warm_window_h": 5}, now=now,
                                                             paths=[old, self.log])], [self.a])

    def test_repo_flag(self):
        r = rd_warm.repo_at(os.path.join(self.a, "server"))
        self.assertEqual((r["top"], r["relcwd"], r["deps"]), (self.a, "", ["server"]))
        with self.assertRaises(SystemExit):
            rd_warm.repo_at(self.d)


class Selection(unittest.TestCase):
    """run_pass() with canned probes: which workers get pushed / prepared, and which never."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="warm-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        self.repo = make_repo(os.path.join(self.d, "app"), {"package.json": "{}", "package-lock.json": "{}"})
        self.cfg = dict(rd_common.DEFAULTS)
        self.calls = []
        rd_warm._last_skip.clear()

    def run_pass(self, workers, answers, repo=None, mirror=None, lock_ok=True, discovered=None):
        def fake_probe(host, req, timeout):
            self.calls.append(("probe", host.name))
            a = answers.get(host.name)
            return (dict(a), 0.01) if a is not None else (None, "no answer")
        sha = rd_run.resolve_worktree(self.repo)["sha"]
        patches = [
            mock.patch.object(rd_pool, "load_workers", return_value=workers),
            mock.patch.object(rd_pool, "probe_one", side_effect=fake_probe),
            mock.patch.object(rd_warm, "mirror_sha", side_effect=lambda h, r: (mirror or {}).get(h.name, sha)),
            mock.patch.object(rd_warm, "remote_lock",
                              side_effect=lambda h, take: self.calls.append(("lock" if take else "unlock", h.name))
                              or (lock_ok if take else True)),
            mock.patch.object(rd_run, "push", side_effect=lambda cfg, wt: self.calls.append(("push", cfg["host"]))),
            mock.patch.object(rd_warm, "prepare",
                              side_effect=lambda h, r: self.calls.append(("prepare", h.name, r["slug"]))
                              or ("warmed", "")),
            mock.patch.object(rd_warm, "reachable", side_effect=lambda hs: {h.name: True for h in hs}),
            mock.patch.object(rd_warm, "wlog", side_effect=lambda m: self.calls.append(("log", m))),
        ]
        if discovered is not None:
            patches.append(mock.patch.object(rd_warm, "discover", return_value=discovered))
        for p in patches:
            p.start()
        try:
            return rd_warm.run_pass(self.cfg, None if discovered is not None else (repo or self.repo))
        finally:
            for p in patches:
                p.stop()

    def did(self, kind):
        return [c[1] for c in self.calls if c[0] == kind]

    def logs(self):
        return [c[1] for c in self.calls if c[0] == "log"]

    def test_down_off_busy_loaded_skipped_free_warmed(self):
        W = test_pool.worker
        workers = [W("free"), W("down"), dict(W("fleetoff"), share="off"), W("switchoff"), W("busy"),
                   W("loaded"), W("lowmem"), dict(W("nofield"))]
        P = test_pool.probe
        answers = {"free": P(warm_git=0, warm_deps=0), "fleetoff": P(warm_git=0, warm_deps=0),
                   "switchoff": P(share="off", warm_git=0), "busy": P(slots_busy=2, warm_git=0),
                   "loaded": P(load=2.8, ncpu=4, warm_git=0), "lowmem": P(mem_mb=500, warm_git=0),
                   "nofield": P(load=2.7, ncpu=4, warm_deps=0)}          # 0.675/cpu: just under 0.7
        up = self.run_pass(workers, answers)
        self.assertEqual(self.did("push"), ["free"])
        self.assertEqual(self.did("prepare"), ["free", "nofield"])
        self.assertNotIn("fleetoff", self.did("probe"))       # off in fleet.json: not even probed
        self.assertEqual(up, {"free": True, "down": False, "switchoff": True, "busy": True,
                              "loaded": True, "lowmem": True, "nofield": True})
        logs = "\n".join(self.logs())
        for name, why in (("down", "down (no answer)"), ("switchoff", "share off (owner's switch)"),
                          ("busy", "no free slot"), ("loaded", "load 0.70/cpu"), ("lowmem", "low-mem")):
            self.assertIn("skip %s " % name, logs)
            self.assertIn(why, logs)
        self.assertEqual(self.did("lock"), ["free", "nofield"])
        self.assertEqual(self.did("unlock"), ["free", "nofield"])     # always released

    def test_no_shards_worker_is_never_warmed(self):
        """fleet.json "shards": false (the slow minis): not probed, pushed, prepared or pinged."""
        W, P = test_pool.worker, test_pool.probe
        up = self.run_pass([W("fast"), dict(W("slow"), shards=False)],
                           {"fast": P(warm_git=0, warm_deps=0), "slow": P(warm_git=0, warm_deps=0)})
        self.assertEqual((self.did("probe"), self.did("prepare")), (["fast"], ["fast"]))
        self.assertNotIn("slow", up)
        h = rd_pool.host_for({}, dict(W("slow"), shards=False))
        self.assertFalse(rd_warm.warmable(h))
        self.assertTrue(rd_warm.warmable(rd_pool.host_for({}, W("fast"))))

    def test_behind_mirror_is_pushed_without_reinstall(self):
        self.run_pass([test_pool.worker("w")], {"w": test_pool.probe()}, mirror={"w": "0" * 40})
        self.assertEqual((self.did("push"), self.did("prepare")), (["w"], []))

    def test_warm_worker_gets_nothing_and_repeats_are_quiet(self):
        self.run_pass([test_pool.worker("w"), test_pool.worker("x")],
                      {"w": test_pool.probe(), "x": test_pool.probe(slots_busy=2)})
        self.assertEqual((self.did("push"), self.did("prepare"), self.did("lock")), ([], [], []))
        n = len(self.logs())
        self.assertEqual(n, 1)                                    # "skip x ...: no free slot"
        self.run_pass([test_pool.worker("w"), test_pool.worker("x")],
                      {"w": test_pool.probe(), "x": test_pool.probe(slots_busy=2)})
        self.assertEqual(len(self.logs()), n)                     # same reason: not logged again

    def test_another_client_warming_the_worker_is_skipped(self):
        self.run_pass([test_pool.worker("w")], {"w": test_pool.probe(warm_git=0, warm_deps=0)}, lock_ok=False)
        self.assertEqual((self.did("push"), self.did("prepare"), self.did("unlock")), ([], [], []))
        self.assertIn("another client is warming it", "\n".join(self.logs()))

    def test_at_most_two_repos_per_pass_newest_first(self):
        repos = []
        for n in ("r1", "r2", "r3"):
            top = make_repo(os.path.join(self.d, n), {"package.json": "{}", "package-lock.json": "{}"})
            repos.append(dict(rd_run.resolve_worktree(top), deps=[""], relcwd="", ts=0))
        self.run_pass([test_pool.worker("w")], {"w": test_pool.probe(warm_deps=0)}, discovered=repos)
        self.assertEqual([c[2] for c in self.calls if c[0] == "prepare"], [repos[0]["slug"], repos[1]["slug"]])
        self.calls = []
        self.cfg["rr_warm_max_repos"] = 1
        self.run_pass([test_pool.worker("w")], {"w": test_pool.probe(warm_deps=0)}, discovered=repos)
        self.assertEqual(len(self.did("prepare")), 1)

    def test_rrun_in_flight_from_the_worktree_skips_the_repo(self):
        wt12 = rd_run.resolve_worktree(self.repo)["wt12"]
        rd_common.ensure_dirs()
        with open(rd_run.wt_lock_path(wt12), "a") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            self.run_pass([test_pool.worker("w")], {"w": test_pool.probe(warm_git=0, warm_deps=0)})
        self.assertEqual((self.did("probe"), self.did("push")), ([], []))
        self.assertIn("is in flight", "\n".join(self.logs()))

    def test_one_pass_at_a_time_on_this_client(self):
        rd_common.ensure_dirs()
        with open(rd_warm.PASS_LOCK, "a") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            self.assertEqual(self.run_pass([test_pool.worker("w")], {"w": test_pool.probe(warm_git=0)}), {})
        self.assertEqual(self.did("push"), [])

    def test_no_fleet_does_nothing(self):
        self.assertEqual(self.run_pass(None, {}), {})
        self.assertEqual(self.calls, [])


class PrepareHeader(unittest.TestCase):
    """The prepare session: what the runner is asked to do, and that GO is never sent."""

    def test_header_never_releases_a_command_nor_starts_docker(self):
        d = tempfile.mkdtemp(prefix="warm-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, d, True)
        top = make_repo(os.path.join(d, "app"), {"package.json": "{}", "package-lock.json": "{}",
                                                 ".gitignore": ".env*\n"})
        wfile(os.path.join(top, ".env"), "SECRET=1\n")    # rrun would add it (rr_env_allow); a warm never
        wfile(os.path.join(top, "new.txt"), "untracked\n")                # the overlay still is
        repo = dict(rd_run.resolve_worktree(top), deps=[""], relcwd="")
        h = rd_pool.host_for(dict(rd_common.DEFAULTS), dict(test_pool.worker("w"), heavy_slots=1))
        seen = {}

        def fake_run(sess):
            seen["frames"], seen["go"] = sess.frames, sess.claim_go()
            sess.on_status("READY")
            seen["closed"] = sess.done.is_set()
            return 130
        with mock.patch.object(rd_warm.PrepareSession, "run", fake_run):
            self.assertEqual(rd_warm.prepare(h, repo), ("warmed", ""))
        hdr = json.loads(seen["frames"][3])
        self.assertEqual((hdr["argv"], hdr["wait_min"], hdr["cls"], hdr["env"], hdr["env_files"]),
                         (["true"], 0, "normal", {}, []))
        self.assertEqual((hdr["stamps"]["dirs"], hdr["relcwd"], hdr["sha"]), ([""], "", repo["sha"]))
        self.assertIn(b"new.txt", seen["frames"][4])
        self.assertNotIn(b"SECRET", seen["frames"][4])
        self.assertFalse(seen["go"])                    # GO is never claimable
        self.assertTrue(seen["closed"])                 # READY ends the writer = closes stdin
        for rc, want in ((73, "busy"), (255, "lost"), (78, "deps-failed"), (65, "error")):
            with mock.patch.object(rd_warm.PrepareSession, "run", lambda s, rc=rc: rc):
                self.assertEqual(rd_warm.prepare(h, repo)[0], want)


class Trigger(unittest.TestCase):
    """loop(): a pass every interval, sooner when a worker goes down -> up."""

    def drive(self, ups, first):
        t = [0.0]
        passes = []

        def fake_pass(cfg, repo):
            passes.append(t[0])
            return dict(first)
        it = iter(ups)
        with mock.patch.object(rd_warm, "run_pass", side_effect=fake_pass), \
                mock.patch.object(rd_warm, "worker_hosts", return_value=[]), \
                mock.patch.object(rd_warm, "reachable", side_effect=lambda hs: next(it)), \
                mock.patch.object(rd_warm, "wlog"), \
                mock.patch.object(rd_common, "load_cfg", return_value=dict(rd_common.DEFAULTS)):
            rc = rd_warm.loop(sleep=lambda s: t.__setitem__(0, t[0] + s), clock=lambda: t[0], max_passes=2)
        return rc, passes

    def test_worker_coming_online_starts_a_pass_at_once(self):
        rc, passes = self.drive([{"mbp": False, "hp": True}, {"mbp": True, "hp": True}],
                                {"mbp": False, "hp": True})
        self.assertEqual((rc, passes), (0, [0.0, 120.0]))           # second tick, not at 300 s

    def test_no_transition_waits_the_full_interval(self):
        rc, passes = self.drive([{"mbp": False, "hp": True}] * 10, {"mbp": False, "hp": True})
        self.assertEqual(passes, [0.0, 300.0])
        # a worker never seen before (no baseline) is not a "came online" event
        self.assertEqual(rd_warm.came_up({}, {"new": True}), [])
        self.assertEqual(rd_warm.came_up({"a": False, "b": True}, {"a": True, "b": True}), ["a"])

    def test_once_and_a_failing_pass(self):
        with mock.patch.object(rd_warm, "run_pass", side_effect=RuntimeError("boom")), \
                mock.patch.object(rd_warm, "wlog") as log, \
                mock.patch.object(rd_common, "load_cfg", return_value=dict(rd_common.DEFAULTS)):
            self.assertEqual(rd_warm.loop(once=True), 1)
        self.assertIn("pass error: RuntimeError: boom", log.call_args[0][0])


FAKE_NPM = """#!/bin/sh
printf '%%s\\n' "$(basename "$0") $*" >> '%s'
case "$(basename "$0") $1" in
  "npm ci") rm -rf node_modules && mkdir node_modules ;;
  "node -v") echo v20.0.0 ;;
esac
exit 0
"""


class WarmE2E(test_run.RunBase):
    """`rdocker warm --once` against two workers (own HOMEs): the real push, the real runner."""

    def setUp(self):
        super().setUp()
        lock = '{"name": "wt", "lockfileVersion": 3}'
        wfile(os.path.join(self.wt, "package.json"), '{"name": "wt"}')
        wfile(os.path.join(self.wt, "package-lock.json"), lock)
        self.git("-C", self.wt, "add", "-A")
        self.git("-C", self.wt, "commit", "-qm", "deps")
        self.npmlog = os.path.join(self.d, "npm.log")
        for n in ("npm", "node"):
            wfile(os.path.join(self.bin, n), FAKE_NPM % self.npmlog, 0o755)
        self.whome = {}
        for n in ("w1", "w2"):
            self.whome[n] = os.path.join(self.d, "home-" + n)
            os.makedirs(self.whome[n])
        self.fleet = os.path.join(self.d, "fleet.json")
        test_pool.write_fleet(self.fleet, [test_pool.worker("w1"), test_pool.worker("w2")])
        self.write_cfg(fleet_path=self.fleet)
        self.proc = os.path.join(self.d, "proc")
        os.makedirs(self.proc)
        wfile(os.path.join(self.proc, "meminfo"), "MemTotal: 32000000 kB\nMemAvailable: 24000000 kB\n")
        wfile(os.path.join(self.proc, "loadavg"), "0.10 0 0 1/1 1\n")
        wfile(os.path.join(self.proc, "cpuinfo"), "processor\t: 0\n\nprocessor\t: 1\n")
        self.state = os.path.join(self.home, ".local", "state", "rdocker")

    def env(self, **extra):
        homes = ",".join("%s=%s" % kv for kv in sorted(getattr(self, "whome", {}).items()))
        base = {"FAKE_SSH_HOMES": homes}
        if getattr(self, "proc", None):
            base.update(RR_OS="linux", RR_PROC=self.proc)
        return super().env(**dict(base, **extra))

    def warm(self, *args):
        return subprocess.run(["/usr/bin/python3", "-I", ENTRY, "warm", "--once"] + list(args), cwd=self.d,
                              env=self.env(), capture_output=True, text=True, timeout=120)

    def count(self, path, needle):
        return self.read(path).count(needle) if os.path.exists(path) else 0

    def test_warm_pushes_and_installs_once_then_nothing(self):
        r = self.warm("--repo", self.wt)
        self.assertEqual(r.returncode, 0, r.stderr)
        wt = rd_run.resolve_worktree(self.wt)
        for n in ("w1", "w2"):
            rr = os.path.join(self.whome[n], "rr")
            ref = subprocess.run(["git", "--git-dir", os.path.join(rr, "git", wt["slug"] + ".git"), "rev-parse",
                                  "refs/rrun/" + wt["wt12"]], capture_output=True, text=True).stdout.strip()
            self.assertEqual(ref, wt["sha"], n)
            stamp = os.path.join(rr, "w", "%s-%s" % (wt["slug"], wt["wt12"]), "node_modules", ".rr-deps-stamp")
            self.assertTrue(os.path.isfile(stamp), n)
            runs = self.read(os.path.join(rr, "log", "runs.log"))
            self.assertIn("outcome=lost prepare_s=", runs)     # stopped at READY...
            self.assertIn("cmd_s=- argv=true", runs)            # ...the command was never spawned
            self.assertFalse(os.path.exists(os.path.join(rr, "state", "warm.lock")), n)   # released
        self.assertEqual(self.count(self.npmlog, "npm ci"), 2)
        log = self.read(os.path.join(self.state, "warm.log"))
        for n in ("w1", "w2"):
            self.assertRegex(log, r"push %s %s [0-9a-f]{12} ok" % (n, wt["slug"]))
            self.assertRegex(log, r"prepare %s %s deps=\. warmed" % (n, wt["slug"]))
        self.assertEqual(self.count(os.path.join(self.state, "route.log"), " rrun "), 0)   # not usage
        pushes = self.count(self.sshlog, "receive-pack")
        self.assertEqual(pushes, 2)
        # second pass, this time from discovery (an rrun line for this worktree): nothing to do
        wfile(os.path.join(self.state, "route.log"), route_line(time.time() - 60, "w1", "npm test", self.wt))
        r = self.warm()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.count(self.sshlog, "receive-pack"), pushes)
        self.assertEqual(self.count(self.npmlog, "npm ci"), 2)
        self.assertEqual(self.read(os.path.join(self.state, "warm.log")), log)
        # a new commit: pushed again, the unchanged lockfile is not reinstalled
        wfile(os.path.join(self.wt, "a.txt"), "changed\n")
        self.git("-C", self.wt, "commit", "-qam", "change")
        r = self.warm()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.count(self.sshlog, "receive-pack"), pushes + 2)
        self.assertEqual(self.count(self.npmlog, "npm ci"), 2)

    def test_down_worker_skipped_busy_worker_not_queued(self):
        d = os.path.join(self.whome["w2"], "rr", "slots")
        os.makedirs(d)
        held = []
        for i in ("0", "1"):
            fh = open(os.path.join(d, i), "a")
            fcntl.flock(fh, fcntl.LOCK_EX)
            held.append(fh)
        self.addCleanup(lambda: [h.close() for h in held])
        t = time.monotonic()
        r = subprocess.run(["/usr/bin/python3", "-I", ENTRY, "warm", "--once", "--repo", self.wt], cwd=self.d,
                           env=self.env(FAKE_SSH_DOWN_HOSTS="w1"), capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(time.monotonic() - t, 60)
        log = self.read(os.path.join(self.state, "warm.log"))
        self.assertIn("skip w1 ", log)
        self.assertIn("skip w2 ", log)
        self.assertIn("no free slot", log)
        self.assertEqual(self.count(self.npmlog, "npm ci"), 0)
        self.assertEqual(self.count(self.sshlog, "receive-pack"), 0)


class InstallAgent(unittest.TestCase):
    def test_plist_from_the_units_template(self):
        rd_setup = rdmods.owner("install_warm")
        calls = []
        with mock.patch.object(rd_common, "IS_MAC", True), \
                mock.patch.object(rd_common, "run", side_effect=lambda cmd, **kw: calls.append(cmd) or (0, "", "")):
            self.assertTrue(rd_setup.install_warm())
        self.addCleanup(os.unlink, rd_common.WARM_PLIST_PATH)
        self.assertTrue(rd_common.WARM_PLIST_PATH.startswith(rdmods.TEST_HOME))
        with open(rd_common.WARM_PLIST_PATH) as f:
            text = f.read()
        self.assertIn("<string>com.rdocker.warm</string>", text)
        self.assertIn("<string>%s</string><string>warm</string>" % rd_common.ENTRY, text)
        self.assertIn("<string>%s</string>" % rd_common.WARM_LOG, text)
        self.assertNotIn("{", text)
        self.assertEqual([c[:2] for c in calls], [["launchctl", "bootout"], ["launchctl", "bootstrap"]])
        self.assertEqual(calls[1][-1], rd_common.WARM_PLIST_PATH)
        with mock.patch.object(rd_common, "IS_MAC", False):
            self.assertIsNone(rd_setup.install_warm())
        ns = rd_setup.build_parser().parse_args(["warm", "--once", "--repo", "/x"])
        self.assertEqual((ns.cmd, ns.once, ns.repo), ("warm", True, "/x"))


if __name__ == "__main__":
    unittest.main()
