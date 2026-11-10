"""rd_cache (rrun's result cache): what is cacheable, the content key, the store, and end to end
through the real rrun / runner / fake ssh of tests/test_run.py: a repeat replays, every change to
what rrun ships misses, and nothing unsafe (docker, changed-while-running, DB, unknown scripts) is
ever saved."""
import io
import json
import os
import sys
import tarfile
import shutil
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
import test_run  # noqa: E402

import rd_pool  # noqa: E402

rd_cache = rdmods.owner("CACHE_DIR")
rd_run = rdmods.owner("rrun")
wfile = test_run.wfile


def job(argv, outputs=None):
    return rd_pool.classify(argv, outputs)


def tar_of(files):
    """{name: (data, mode)} -> overlay-style tar bytes."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, (data, mode) in files.items():
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, int(time.time())
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


class Cacheable(unittest.TestCase):
    def test_static_rules(self):
        ok = [["tsc", "--noEmit"], ["npx", "tsc", "--noEmit", "-p", "server"], ["npx", "--yes", "eslint", "."],
              ["eslint", "src", "--max-warnings", "0"], ["vitest", "run"], ["npx", "vitest", "run", "src/"],
              ["node_modules/.bin/vitest", "--run"], ["jest", "--ci"], ["vue-tsc", "--noEmit"],
              ["node", "--max-old-space-size=8192", "node_modules/typescript/bin/tsc", "--noEmit"],
              ["node", "node_modules/vitest/vitest.mjs", "run"],
              ["npm", "test"], ["npm", "t"], ["npm", "run", "lint"], ["npm", "run", "typecheck:server"],
              ["npm", "--prefix", "server", "run", "test"], ["npm", "run", "test", "--", "-t", "x"],
              ["npm", "run", "-s", "lint"]]
        bad = [(["vitest"], "without `run`"), (["vitest", "run", "--watch"], "watch"), (["vitest", "run", "-u"], "snapshot"),
               (["jest", "--watchAll"], "watch"), (["eslint", "--fix", "."], "--fix"), (["tsc", "-w"], "watch"),
               (["npm", "run", "test:db"], "a DB job"), (["node", "scripts/test-with-db.mjs"], "a DB job"),
               (["npm", "run", "build"], "not a test"), (["npm", "run", "dev"], "not a test"), (["npm", "ci"], "npm ci"),
               (["npm", "-w", "server", "test"], "npm flag"), (["npm", "run"], "without a script"),
               (["node", "-e", "1"], "node with flags"), (["node", "scripts/check.mjs"], "not a known check"),
               (["npx", "prisma", "migrate"], "npx runs"), (["true"], "not tsc"), (["bash", "-c", "vitest run"], "not tsc"),
               (["make", "test"], "not tsc")]
        for argv in ok:
            with self.subTest(argv=argv):
                self.assertIsNone(rd_cache.why_not_static(argv, job(argv), [], {}))
        for argv, why in bad:
            with self.subTest(argv=argv):
                self.assertIn(why, rd_cache.why_not_static(argv, job(argv), [], {}) or "cacheable!")
        self.assertIn("a build", rd_cache.why_not_static(["npm", "run", "build"], job(["x"], ["dist"]), ["dist"], {}))
        for name in ("DATABASE_URL", "TEST_DB_URL", "PGHOST", "REDIS_URL", "SUPABASE_KEY", "my_db"):
            with self.subTest(env=name):
                self.assertIn("database setting", rd_cache.why_not_static(["vitest", "run"], job(["vitest"]),
                                                                          [], {name: "x"}))
        self.assertIsNone(rd_cache.why_not_static(["vitest", "run"], job(["vitest"]), [], {"CI": "1", "DEBUG": "x"}))

    def test_script_rules_read_the_shipped_package_json(self):
        def check(scripts, argv=("npm", "test"), relcwd="", files=None):
            files = files if files is not None else {"package.json": json.dumps({"scripts": scripts}).encode()}
            return rd_cache.why_not_script(list(argv), relcwd, lambda rel: files.get(rel))
        self.assertIsNone(check({"test": "vitest run"}))
        self.assertIsNone(check({"test": "tsc --noEmit && eslint 'src/**/*.ts' && vitest run"}))
        self.assertIsNone(check({"test": "npm run lint:a && vitest run", "lint:a": "eslint ."}))
        self.assertIsNone(check({"test": "vitest run", "pretest": "tsc --noEmit", "posttest": "eslint ."}))
        for scripts, why in (({"test": "DATABASE_URL=x vitest run"}, "sets env vars"),
                             ({"test": "cross-env A=1 vitest run"}, "sets env vars"),
                             ({"test": "node scripts/seed.js && vitest run"}, "not a known check"),
                             ({"test": "vitest run; rm -rf x"}, "shell syntax"),
                             ({"test": "vitest run | tee out"}, "shell syntax"),
                             ({"test": "vitest run $X"}, "shell syntax"),
                             ({"test": "vitest run & sleep 1"}, "shell syntax"),
                             ({"test": "vitest run", "pretest": "node seed.js"}, "pretest"),
                             ({"test": "npm run test"}, "too deep"),
                             ({"test": "npm run db:reset && vitest run"}, "not a test"),
                             ({"test": "npm --prefix x run lint"}, "npm --prefix"),
                             ({"lint": "eslint ."}, "no 'test' script"),
                             ({"test": "vitest"}, "without `run`")):
            with self.subTest(scripts=scripts):
                self.assertIn(why, check(scripts) or "cacheable!")
        self.assertIn("no readable package.json", check({}, files={}))
        self.assertIn("no readable package.json", check({}, files={"package.json": b"{nope"}))
        # cwd + --prefix pick the package.json; outside the repo is refused
        sub = {"server/package.json": json.dumps({"scripts": {"test": "vitest run"}}).encode()}
        self.assertIsNone(check(None, ("npm", "test"), "server", sub))
        self.assertIsNone(check(None, ("npm", "--prefix", "server", "test"), "", sub))
        self.assertIsNone(check(None, ("npm", "--prefix=../server", "test"), "client", sub))
        self.assertIn("outside the repo", check(None, ("npm", "--prefix", "../..", "test"), "client", sub))
        self.assertIsNone(rd_cache.why_not_script(["vitest", "run"], "", lambda rel: None))

    def test_env_files_that_set_a_database_are_refused(self):
        t = tar_of({".env": (b"A=1\nexport DATABASE_URL=postgres://x\n", 0o600), "x.ts": (b"DATABASE_URL=1", 0o600)})
        self.assertIn(".env sets a database variable (DATABASE_URL)", rd_cache.env_files_why(t, [".env"]))
        self.assertIsNone(rd_cache.env_files_why(t, []))                  # a source file is not an env file
        self.assertIsNone(rd_cache.env_files_why(tar_of({".env": (b"API=1\n# DB_URL=x\n", 0o600)}), [".env"]))


class Identity(unittest.TestCase):
    BASE = dict(sha="a" * 40, base_specs=["+%s:refs/remotes/origin/dev" % ("b" * 40)],
                tar=tar_of({"src/a.ts": (b"x", 0o600), "run.sh": (b"y", 0o700)}), env_files=[],
                deleted=["gone.ts"], env={"CI": "1"}, deps=["server"])

    def cid(self, **kw):
        a = dict(self.BASE, **kw)
        return rd_cache.content_id(a["sha"], a["base_specs"], a["tar"], a["env_files"], a["deleted"], a["env"], a["deps"])

    def test_content_id_changes_with_everything_shipped_and_nothing_else(self):
        ref = self.cid()
        self.assertEqual(ref, self.cid())
        # the tar's mtimes and member order are not content
        same = tar_of({"run.sh": (b"y", 0o700), "src/a.ts": (b"x", 0o644)})
        time.sleep(1.1)
        self.assertEqual(ref, self.cid(tar=same))
        changes = {"sha": dict(sha="c" * 40),
                   "base branch": dict(base_specs=["+%s:refs/remotes/origin/dev" % ("d" * 40)]),
                   "no base branch": dict(base_specs=[]),
                   "content": dict(tar=tar_of({"src/a.ts": (b"x2", 0o600), "run.sh": (b"y", 0o700)})),
                   "exec bit": dict(tar=tar_of({"src/a.ts": (b"x", 0o600), "run.sh": (b"y", 0o600)})),
                   "new file": dict(tar=tar_of({"src/a.ts": (b"x", 0o600), "run.sh": (b"y", 0o700), "n": (b"", 0o600)})),
                   "rename": dict(tar=tar_of({"src/b.ts": (b"x", 0o600), "run.sh": (b"y", 0o700)})),
                   "no overlay": dict(tar=b""),
                   "env file": dict(env_files=["run.sh"]),
                   "deleted": dict(deleted=[]),
                   "env value": dict(env={"CI": "2"}),
                   "env name": dict(env={"CI": "1", "DEBUG": ""}),
                   "deps": dict(deps=[])}
        seen = {ref}
        for what, kw in changes.items():
            with self.subTest(what=what):
                c = self.cid(**kw)
                self.assertNotIn(c, seen)
                seen.add(c)

    def test_key_adds_the_command(self):
        c = self.cid()
        k = rd_cache.key(c, ["vitest", "run"], "", "normal")
        self.assertRegex(k, r"^[0-9a-f]{64}$")
        self.assertEqual(k, rd_cache.key(c, ["vitest", "run"], "", "normal"))
        others = [(c, ["vitest", "run", "a"], "", "normal"), (c, ["vitest", "run"], "server", "normal"),
                  (c, ["vitest", "run"], "", "heavy"), (self.cid(sha="e" * 40), ["vitest", "run"], "", "normal")]
        for args in others:
            self.assertNotEqual(k, rd_cache.key(*args))


class Store(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(rd_cache.CACHE_DIR, True)
        self.addCleanup(shutil.rmtree, rd_cache.CACHE_DIR, True)
        self.k = "f" * 64

    def put(self, k, rc=0, ts=None, frames=((1, b"out\n"), (2, b"err\n"), (1, b"end\n"))):
        meta = {"v": rd_cache.FORMAT, "rc": rc, "ts": time.time() if ts is None else ts, "worker": "hp", "secs": 1.0,
                "argv": "vitest run"}
        self.assertTrue(rd_cache.store(k, meta, list(frames)))

    def test_round_trip_ttl_and_permissions(self):
        self.put(self.k)
        meta, frames = rd_cache.lookup(self.k)
        self.assertEqual((meta["rc"], meta["worker"]), (0, "hp"))
        self.assertEqual(frames, [(1, b"out\n"), (2, b"err\n"), (1, b"end\n")])
        self.assertEqual(os.stat(rd_cache.CACHE_DIR).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(os.path.join(rd_cache.CACHE_DIR, self.k + ".entry")).st_mode & 0o777, 0o600)
        now = time.time()
        self.assertIsNotNone(rd_cache.lookup(self.k, now + 23 * 3600))
        self.assertIsNone(rd_cache.lookup(self.k, now + 25 * 3600))       # a pass lives 24 h, then is removed
        self.assertFalse(os.path.exists(os.path.join(rd_cache.CACHE_DIR, self.k + ".entry")))
        self.put(self.k, rc=1)
        self.assertIsNotNone(rd_cache.lookup(self.k, now + 19 * 60))
        self.assertIsNone(rd_cache.lookup(self.k, now + 21 * 60))          # a failure (flake?) only 20 min
        self.put(self.k, ts=now + 3600)
        self.assertIsNone(rd_cache.lookup(self.k, now))                    # from the future: never trusted
        self.assertIsNone(rd_cache.lookup("../etc"))
        self.assertFalse(rd_cache.store("../x", {"v": 1}, []))

    def test_damaged_entries_are_misses(self):
        p = os.path.join(rd_cache.CACHE_DIR, self.k + ".entry")
        for raw in (b"", b"not json\n", b'{"v": 99, "rc": 0, "ts": 1}\n',
                    json.dumps({"v": rd_cache.FORMAT, "rc": 0, "ts": time.time()}).encode() + b"\n1 99\nshort",
                    json.dumps({"v": rd_cache.FORMAT, "rc": 0, "ts": time.time()}).encode() + b"\n3 1\nx"):
            with self.subTest(raw=raw[:40]):
                self.put(self.k)
                with open(p, "wb") as f:
                    f.write(raw)
                self.assertIsNone(rd_cache.lookup(self.k))
                self.assertFalse(os.path.exists(p))

    def test_prune_drops_expired_then_least_recently_used(self):
        old = time.time() - 2 * 86400
        self.put("1" * 64, ts=old)
        for i, k in enumerate(("2" * 64, "3" * 64, "4" * 64)):
            self.put(k, frames=[(1, b"x" * 1000)])
            os.utime(os.path.join(rd_cache.CACHE_DIR, k + ".entry"), (time.time() - 100 + i, time.time() - 100 + i))
        rd_cache.lookup("2" * 64)                                          # used now: most recent
        rd_cache.prune(cap=2500)
        left = sorted(n[0] for n in os.listdir(rd_cache.CACHE_DIR))
        self.assertEqual(left, ["2", "4"])

    def test_replay_order_and_hit_line(self):
        out, err = io.BytesIO(), io.BytesIO()
        rd_cache.replay([(1, b"a"), (2, b"b"), (1, b"c")], out, err)
        self.assertEqual((out.getvalue(), err.getvalue()), (b"ac", b"b"))
        line = rd_cache.hit_line({"ts": 1000.0, "worker": "hp"}, now=1000.0 + 3 * 60 + 5)
        self.assertEqual(line, "cached result (same code + command, 3m ago on hp); RRUN_CACHE=0 to run again")


class SaveGate(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(rd_cache.CACHE_DIR, True)
        self.addCleanup(shutil.rmtree, rd_cache.CACHE_DIR, True)

    def run_(self):
        r = rd_cache.Run("e" * 64, "cid")
        r.rec.add(1, b"ok\n")
        return r

    def test_only_a_clean_complete_run_is_saved(self):
        r = self.run_()
        r.shipped("cid")
        r.attempt_done("hp", 0)
        self.assertIsNone(r.why_not_save(0))
        self.assertTrue(r.save(0, 1.0, "vitest run"))
        self.assertEqual(rd_cache.lookup("e" * 64)[1], [(1, b"ok\n")])
        cases = {"the files changed while it ran": lambda r: r.shipped("other"),
                 "used docker": lambda r: r.attempt_done("hp", 0, docker=True),
                 "interrupted": lambda r: r.attempt_done("hp", 0, interrupted=True),
                 "not every part": lambda r: None,
                 "a hedged duplicate": lambda r: r.taint("a hedged duplicate ran")}
        for why, do in cases.items():
            with self.subTest(why=why):
                r = self.run_()
                do(r)
                if why != "not every part" and not r.finished:
                    r.attempt_done("hp", 0)
                self.assertIn(why, r.why_not_save(0) or "saved!")
        for rc in (75, 73, 78, 130, 255, -1):
            with self.subTest(rc=rc):
                r = self.run_()
                r.attempt_done("hp", rc)
                self.assertIn("not a test verdict", r.why_not_save(rc))
        r = self.run_()
        r.attempt_done("hp", 0)
        self.assertIn("did not come from the command", r.why_not_save(75))  # e.g. a copy-back failure
        r = self.run_()
        r.expect = 3
        for rc in (0, 1, 0):
            r.attempt_done("w", rc)
        self.assertIsNone(r.why_not_save(1))                                # shards: rc = the highest
        r = self.run_()
        r.attempt_done("hp", 0)
        r.rec.cap = 10
        r.rec.add(1, b"x" * 20)
        self.assertIn("output is over", r.why_not_save(0))

    def test_recorder_reset_keeps_order(self):
        rec = rd_cache.Recorder()
        rec.add(2, b"npm ci noise\n")
        rec.reset()
        rec.add(1, b"a")
        rec.add(1, b"b")
        rec.add(2, b"c")
        self.assertEqual(rec.frames, [(1, b"ab"), (2, b"c")])


# a fake vitest on the "worker": counts its runs, prints on both streams, can call docker and fail
FAKE_VITEST = r'''#!/bin/sh
echo run >> "%(count)s"
echo "vitest out 1"
echo "vitest err" >&2
echo "vitest out 2"
[ -n "$VITEST_DOCKER" ] && docker ps >/dev/null
exit ${VITEST_RC:-0}
'''
FAKE_NPM = '#!/bin/sh\n[ "$1" = test ] || [ "$2" = test ] || exit 9\nexec vitest run\n'
# a wrapper ssh: while git pushes (receive-pack), MUTATE_ON_PUSH's file is rewritten - so the files
# shipped differ from the ones the key was computed on
WRAP_SSH = r'''#!/usr/bin/python3 -I
import os, sys
p = os.environ.get("MUTATE_ON_PUSH")
if p and any("receive-pack" in a for a in sys.argv[1:]):
    with open(p, "w") as f:
        f.write("mutated\n")
os.execv(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ssh-real"), ["ssh"] + sys.argv[1:])
'''


class CacheE2E(test_run.RunBase):
    def setUp(self):
        test_run.RunBase.setUp(self)
        self.count = os.path.join(self.d, "count")
        wfile(os.path.join(self.bin, "vitest"), FAKE_VITEST % {"count": self.count}, 0o755)
        wfile(os.path.join(self.bin, "npm"), FAKE_NPM, 0o755)
        os.rename(os.path.join(self.bin, "ssh"), os.path.join(self.bin, "ssh-real"))
        wfile(os.path.join(self.bin, "ssh"), WRAP_SSH, 0o755)

    def runs(self):
        try:
            with open(self.count) as f:
                return len(f.read().split())
        except OSError:
            return 0

    def test_a_repeat_replays_output_and_exit_code(self):
        r1 = self.rrun("vitest", "run")
        self.assertEqual((r1.returncode, self.runs()), (0, 1), r1.stderr)
        self.assertNotIn("cached result", r1.stderr)
        self.assertIn("cache: hit - replays the result from", self.rrun("--where", "vitest", "run").stdout)
        r2 = self.rrun("vitest", "run")
        self.assertEqual((r2.returncode, self.runs()), (0, 1), r2.stderr)
        self.assertEqual(r2.stdout, r1.stdout)
        self.assertEqual(r2.stdout, "vitest out 1\nvitest out 2\n")
        self.assertRegex(r2.stderr, r"^vitest err\nrrun: cached result \(same code \+ command, \d+s ago on mini\); "
                                    r"RRUN_CACHE=0 to run again\n$")
        route = self.read(os.path.join(self.home, ".local", "state", "rdocker", "route.log"))
        self.assertRegex(route, r"cache +rrun +vitest run rc=0 ")
        # RRUN_CACHE=0 runs it (and the escape hatch never reaches the command's env)
        r3 = self.rrun("vitest", "run", RRUN_CACHE="0")
        self.assertEqual((r3.returncode, self.runs()), (0, 2), r3.stderr)
        self.assertNotIn("cached result", r3.stderr)
        self.assertIn("cache: off (RRUN_CACHE=0)", self.rrun("--where", "vitest", "run", RRUN_CACHE="0").stdout)
        # a failure is cached too (20 min), with its exit code
        r4 = self.rrun("vitest", "run", VITEST_RC="1")
        r5 = self.rrun("vitest", "run", VITEST_RC="1")
        self.assertEqual((r4.returncode, r5.returncode, self.runs()), (1, 1, 3))
        self.assertIn("cached result", r5.stderr)
        # signals / rrun's own codes are not verdicts: never replayed
        for rc in ("75", "130"):
            self.rrun("vitest", "run", VITEST_RC=rc)
        self.rrun("vitest", "run", VITEST_RC="75")
        self.assertEqual(self.runs(), 6)

    def test_every_change_to_what_rrun_ships_misses_and_nothing_else_does(self):
        def go(**env):
            before = self.runs()
            r = self.rrun(*env.pop("argv", ("vitest", "run")), cwd=env.pop("cwd", None), **env)
            self.assertEqual(r.returncode, 0, r.stderr)
            return "miss" if self.runs() > before else "hit"
        wt = self.wt
        self.assertEqual(go(), "miss")
        self.assertEqual(go(), "hit")
        steps = [
            ("tracked edit", lambda: wfile(os.path.join(wt, "a.txt"), "a2\n"), "miss"),
            ("edit undone: the first run's result again", lambda: wfile(os.path.join(wt, "a.txt"), "a\n"), "hit"),
            ("staged edit", lambda: (wfile(os.path.join(wt, "staged.txt"), "s1\n"),
                                     self.git("-C", wt, "add", "staged.txt")), "miss"),
            ("untracked file", lambda: wfile(os.path.join(wt, "new.txt"), "n\n"), "miss"),
            ("untracked content", lambda: wfile(os.path.join(wt, "new.txt"), "n2\n"), "miss"),
            ("exec bit", lambda: os.chmod(os.path.join(wt, "new.txt"), 0o755), "miss"),
            ("deleted file", lambda: os.unlink(os.path.join(wt, "del.txt")), "miss"),
            ("ignored file (never shipped)", lambda: wfile(os.path.join(wt, "ignored.txt"), "i\n"), "hit"),
            ("same bytes rewritten (mtime only)",
             lambda: (time.sleep(1.1), wfile(os.path.join(wt, "new.txt"), "n2\n")), "hit"),
            ("env file shipped", lambda: wfile(os.path.join(wt, ".env"), "A=1\n"), "miss"),
            ("env file content", lambda: wfile(os.path.join(wt, ".env"), "A=2\n"), "miss"),
            ("commit", lambda: (self.git("-C", wt, "add", "-A"), self.git("-C", wt, "commit", "-qm", "c2")), "miss"),
            ("base branch appears", lambda: self.git("-C", wt, "update-ref", "refs/remotes/origin/dev", "HEAD~1"), "miss"),
            ("base branch moves", lambda: self.git("-C", wt, "update-ref", "refs/remotes/origin/dev", "HEAD"), "miss"),
        ]
        for what, change, want in steps:
            with self.subTest(what=what):
                change()
                self.assertEqual(go(), want, what)
                self.assertEqual(go(), "hit", what + " (repeat)")
        for what, env, want in (("passed env value", {"VITEST_X": "1"}, "miss"), ("other value", {"VITEST_X": "2"}, "miss"),
                                ("-e pair", {"argv": ("-e", "FOO=1", "vitest", "run")}, "miss"),
                                ("argv", {"argv": ("vitest", "run", "sub")}, "miss"),
                                ("cwd", {"cwd": os.path.join(wt, "sub")}, "miss"),
                                ("env rrun does not pass", {"UNRELATED": "x"}, "hit")):
            with self.subTest(what=what):
                self.assertEqual(go(**dict(env)), want, what)
                self.assertEqual(go(**dict(env)), "hit", what + " (repeat)")

    def test_files_changed_between_key_and_send_are_never_saved(self):
        """The key is computed, then (during the push) a file changes, so the worker gets other
        bytes: that result must not be saved under the key of the files before."""
        a = os.path.join(self.wt, "a.txt")
        r = self.rrun("vitest", "run", MUTATE_ON_PUSH=a)
        self.assertEqual((r.returncode, self.runs()), (0, 1), r.stderr)
        self.assertEqual(self.read(a), "mutated\n")
        wfile(a, "a\n")                                   # back to the bytes the key was computed on
        r = self.rrun("vitest", "run")
        self.assertEqual((r.returncode, self.runs()), (0, 2), r.stderr)   # not a stale hit
        self.assertNotIn("cached result", r.stderr)
        self.assertIn("cached result", self.rrun("vitest", "run").stderr)  # this one was clean

    def test_unsafe_runs_are_never_cached(self):
        # the command called docker on the worker: the runner says so; never saved
        for _ in range(2):
            r = self.rrun("vitest", "run", VITEST_DOCKER="1")
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.runs(), 2)

        def where(*argv, **env):
            return [ln for ln in self.rrun("--where", *argv, **env).stdout.splitlines() if ln.startswith("cache:")][0]
        self.assertIn("not cached (a DB job)", where("npm", "run", "test:db"))
        self.assertIn("not cached (true is not tsc", where("true"))
        self.assertIn("database setting (TEST_DB_URL)", where("vitest", "run", TEST_DB_URL="x"))
        self.assertIn("database setting (DATABASE_URL)", where("-e", "DATABASE_URL=x", "vitest", "run"))
        wfile(os.path.join(self.wt, ".env"), "DATABASE_URL=postgres://x\n")
        self.assertIn(".env sets a database variable", where("vitest", "run"))
        os.unlink(os.path.join(self.wt, ".env"))
        self.assertIn("cache: not used with --host", where("--host", "mini", "vitest", "run"))
        r = self.rrun("--where", "vitest", "run", cwd=self.d)
        self.assertIn("cache: not cached (not in a git worktree)", r.stdout)

    def test_npm_scripts_are_judged_by_the_package_json_rrun_ships(self):
        wfile(os.path.join(self.wt, "package.json"), json.dumps({"scripts": {
            "test": "vitest run", "test:int": "DATABASE_URL=x vitest run", "lint": "node lint.js"}}))
        self.git("-C", self.wt, "add", "package.json")
        self.git("-C", self.wt, "commit", "-qm", "pkg")
        r = self.rrun("--where", "npm", "test")
        self.assertIn("cache: miss", r.stdout)
        self.assertIn("sets env vars", self.rrun("--where", "npm", "run", "test:int").stdout)
        self.assertIn("'lint' script: node runs lint.js", self.rrun("--where", "npm", "run", "lint").stdout)
        for _ in range(2):
            r = self.rrun("npm", "test")
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.runs(), 1)
        # an uncommitted edit to the script is what ships, so it is what is judged
        wfile(os.path.join(self.wt, "package.json"), json.dumps({"scripts": {"test": "node seed.js && vitest run"}}))
        self.assertIn("not a known check", self.rrun("--where", "npm", "test").stdout)


if __name__ == "__main__":
    unittest.main()
