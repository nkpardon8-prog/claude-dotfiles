"""The pool tier of rrun's result cache (rd_cache "pool tier"): ~/rr/rcache on the fleet's home worker,
looked up through the placement probe, stored after the result is printed, with singleflight leases.

Unit tests run the home-worker perl (rd_cache.RCACHE_OP / the PROBE) locally against a temp ~/rr;
end-to-end tests run the real `rrun` against a two-worker fleet (tests/test_pool.PoolE2E) whose w1 is
the home worker. A second agent Mac is a second client HOME using the same worktree path (the key is
the same; the worktree lock and this Mac's cache tier are per HOME).
"""
import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
import test_pool  # noqa: E402
import test_run  # noqa: E402

import rd_pool  # noqa: E402

rd_cache = rdmods.owner("RCACHE_OP")
KEY = "ab" * 32
TOKEN = "cd" * 12
SECRET = bytes(range(32))


def write_key(home, secret=SECRET):
    p = os.path.join(home, ".config", "rdocker", "pool-cache.key")
    test_run.wfile(p, secret.hex() + "\n")
    os.chmod(p, 0o600)
    return p


def jload(path):
    with open(path) as f:
        return json.load(f)


def entry(rc=0, ts=None, out=b"out\n", node="25", secret=SECRET, key=KEY, **meta):
    """Entry bytes as a client uploads them (signed with `secret` for `key`; secret None = unsigned)."""
    m = dict({"v": 1, "rc": rc, "ts": time.time() if ts is None else ts, "worker": "w1", "secs": 1.0,
              "argv": "vitest run", "node": node, "agent": "win (session:x)"}, **meta)
    frames = [(1, out), (2, b"err\n")]
    if secret is not None:
        m["mac"] = rd_cache.entry_mac(secret, key, m, frames)
    return rd_cache.entry_bytes(m, frames)


class HomeStore(unittest.TestCase):
    """RCACHE_OP (poll / touch / store) and the PROBE's rcache answer, run locally."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="rcache-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        self.root = os.path.join(self.d, "rr")
        os.makedirs(self.root)
        self.dir = os.path.join(self.root, "rcache")
        self.env = rdmods.child_env(self.d, RR_ROOT=self.root)

    def op(self, op, data):
        p = subprocess.run(["/usr/bin/perl", "-e", rd_cache.RCACHE_OP, op], input=data, env=self.env,
                           capture_output=True, timeout=30)
        return p

    def check(self, lease=None, stale=90, key=KEY):
        req = {"key": key, "max": rd_cache.SHARED_MAX, "stale": stale}
        if lease:
            req["lease"] = dict({"owner": "o", "host": "mac", "pid": 1, "ttl": 600}, **lease)
        p = self.op("check", json.dumps(req).encode())
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)

    def store(self, body, token="", key=KEY, max_=rd_cache.SHARED_MAX):
        return self.op("store", json.dumps({"key": key, "token": token, "max": max_}).encode() + b"\n" + body)

    def put(self, data, name=KEY + ".entry", age=0):
        os.makedirs(self.dir, exist_ok=True)
        p = os.path.join(self.dir, name)
        with open(p, "wb") as f:
            f.write(data)
        t = time.time() - age
        os.utime(p, (t, t))
        return p

    def lease_file(self, **kw):
        ls = dict({"owner": "a", "host": "m", "pid": 1, "token": TOKEN, "t": int(time.time()),
                   "exp": int(time.time()) + 600}, **kw)
        return self.put(json.dumps(ls).encode(), KEY + ".lease")

    def test_miss_takes_the_lease_and_a_second_identical_run_sees_it_in_flight(self):
        self.assertEqual(self.check(), {"st": "miss"})             # no lease asked: none taken
        self.assertFalse(os.path.exists(os.path.join(self.dir, KEY + ".lease")))
        self.assertEqual(self.check({"token": TOKEN}), {"st": "miss", "lease": 1})
        ls = jload(os.path.join(self.dir, KEY + ".lease"))
        self.assertEqual((ls["owner"], ls["token"], ls["exp"] - ls["t"]), ("o", TOKEN, 600))
        a = self.check({"token": "ef" * 12, "owner": "b"})
        self.assertEqual((a["st"], a["owner"], a["host"]), ("inflight", "o", "mac"))
        self.assertGreater(a["left"], 590)
        self.assertEqual(self.check({"token": TOKEN}), {"st": "miss", "lease": 1})   # our own lease
        self.assertEqual(oct(os.stat(self.dir).st_mode & 0o777), "0o700")

    def test_store_then_hit_drops_the_lease(self):
        self.check({"token": TOKEN})
        p = self.store(entry(out=b"hello\n"), TOKEN)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.dir, KEY + ".lease")))
        a = self.check({"token": "ef" * 12})
        self.assertEqual(a["st"], "hit")
        meta, frames = rd_cache.parse_entry(base64.b64decode(a["entry"]))
        self.assertEqual((meta["rc"], frames), (0, [(1, b"hello\n"), (2, b"err\n")]))
        self.assertFalse(os.path.exists(os.path.join(self.dir, KEY + ".lease")))     # a hit takes none

    def test_store_with_another_token_keeps_the_lease_and_release_only_drops_ours(self):
        self.lease_file()
        self.assertEqual(self.store(b"", "ef" * 12).returncode, 0)
        self.assertTrue(os.path.exists(os.path.join(self.dir, KEY + ".lease")))
        self.assertEqual(self.store(b"", TOKEN).returncode, 0)              # release: no entry
        self.assertFalse(os.path.exists(os.path.join(self.dir, KEY + ".lease")))
        self.assertFalse(os.path.exists(os.path.join(self.dir, KEY + ".entry")))

    def test_ttl_pass_24h_failure_20min(self):
        for rc, age, want in ((0, 23 * 3600, "hit"), (0, 25 * 3600, "miss"), (1, 19 * 60, "hit"),
                              (1, 21 * 60, "miss"), (2, 19 * 60, "hit")):
            with self.subTest(rc=rc, age=age):
                p = self.put(entry(rc=rc, ts=time.time() - age))
                self.assertEqual(self.check()["st"], want)
                self.assertEqual(os.path.exists(p), want == "hit")              # an expired one is gone

    def test_damaged_oversized_and_unsafe_entries_are_never_served_or_stored(self):
        self.put(b"not json\n1 3\nabc")
        self.assertEqual(self.check()["st"], "miss")
        big = entry(out=b"x" * (rd_cache.SHARED_MAX + 10))
        self.assertEqual(self.store(big).returncode, 3)
        self.assertEqual(self.store(b"garbage").returncode, 1)
        self.assertFalse(os.path.exists(os.path.join(self.dir, KEY + ".entry")))
        self.assertEqual(self.check(key="../x")["st"], "bad")
        self.assertEqual(self.op("store", b'{"key": "../../etc"}\n').returncode, 2)
        os.makedirs(self.dir, exist_ok=True)
        os.symlink(os.path.join(self.d, "elsewhere"), os.path.join(self.dir, KEY + ".entry"))
        self.assertEqual(self.check()["st"], "miss")                          # never followed
        self.assertFalse(os.path.exists(os.path.join(self.d, "elsewhere")))

    def test_expired_or_stale_lease_is_taken_over(self):
        self.lease_file(exp=int(time.time()) - 1)
        self.assertEqual(self.check({"token": "ef" * 12}), {"st": "miss", "lease": 1})
        p = self.lease_file()
        old = time.time() - 120
        os.utime(p, (old, old))                                             # its owner stopped refreshing
        self.assertEqual(self.check({"token": "ef" * 12}, stale=90), {"st": "miss", "lease": 1})
        self.assertEqual(jload(p)["token"], "ef" * 12)

    def test_touch_refreshes_only_our_own_lease(self):
        p = self.lease_file()
        old = time.time() - 60
        os.utime(p, (old, old))
        hdr = lambda tok: json.dumps({"key": KEY, "token": tok}).encode() + b"\n"   # noqa: E731
        self.assertEqual(self.op("touch", hdr("ef" * 12)).returncode, 1)
        self.assertLess(os.stat(p).st_mtime, time.time() - 50)
        self.assertEqual(self.op("touch", hdr(TOKEN)).returncode, 0)
        self.assertGreater(os.stat(p).st_mtime, time.time() - 5)

    def test_probe_carries_the_answer_and_the_node_major(self):
        proc = os.path.join(self.d, "proc")
        test_run.wfile(os.path.join(proc, "meminfo"), "MemTotal: 8000000 kB\nMemAvailable: 2000000 kB\n")
        test_run.wfile(os.path.join(proc, "loadavg"), "0.5 1 1 1/1 1\n")
        test_run.wfile(os.path.join(proc, "cpuinfo"), "processor\t: 0\n")
        env = dict(self.env, RR_OS="linux", RR_PROC=proc, RR_SYS=os.path.join(self.d, "sys"))

        def probe(req):
            p = subprocess.run(["/usr/bin/perl", "-e", rd_pool.PROBE], input=json.dumps(req), env=env,
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(p.returncode, 0, p.stderr)
            return json.loads(p.stdout)
        o = probe({"slots": 2})
        self.assertNotIn("rcache", o)
        self.put(entry())
        o = probe({"slots": 2, "rcache": {"key": KEY}})
        self.assertEqual(o["rcache"]["st"], "hit")
        self.assertNotIn("node", o)          # the node is declared in fleet.json, never guessed by the probe

    def test_client_answer(self):
        sh = rd_cache.Shared(KEY, "o", "mac", 1800, secret=SECRET)
        self.assertEqual(sh.ttl, 1800 + rd_cache.LEASE_MARGIN_S)
        self.assertEqual(rd_cache.Shared(KEY, "o", "mac", 0).ttl, rd_cache.LEASE_NOCAP_S)
        self.assertIsNone(sh.answer(None))
        self.assertEqual(sh.answer({"st": "miss"}), {"st": "miss"})
        self.assertFalse(sh.leased)
        sh.answer({"st": "miss", "lease": 1})
        self.assertTrue(sh.leased)
        hit = sh.answer({"st": "hit", "entry": base64.b64encode(entry(rc=1)).decode()})
        self.assertEqual((hit["st"], hit["meta"]["rc"], hit["frames"][0]), ("hit", 1, (1, b"out\n")))
        stale = sh.answer({"st": "hit", "entry": base64.b64encode(entry(rc=1, ts=time.time() - 1500)).decode()})
        self.assertEqual(stale, {"st": "miss"})                      # the client checks the TTL too
        self.assertEqual(sh.answer({"st": "hit", "entry": "%%%"}), {"st": "miss"})

    def test_a_malformed_mac_is_a_miss_never_a_crash(self):
        """A job on the home worker can write any meta: a MAC that is not exactly 64 lowercase hex
        characters is unsigned (a MISS), whatever its type - "é" made compare_digest raise (round 2)."""
        sh = rd_cache.Shared(KEY, "o", "mac", 1800, secret=SECRET)
        meta, frames = rd_cache.parse_entry(entry())
        good = meta["mac"]
        for what, mac in (("non-ASCII", "é"), ("non-ASCII, right length", "é" * 64), ("int", 1),
                          ("None", None), ("list", [good]), ("dict", {"x": 1}), ("bool", True),
                          ("63 chars", good[:63]), ("65 chars", good + "0"), ("uppercase", good.upper()),
                          ("not hex", "g" * 64), ("trailing newline", good + "\n"), ("empty", "")):
            with self.subTest(what):
                raw = rd_cache.entry_bytes(dict(meta, mac=mac), frames)
                self.assertFalse(sh.signed(*rd_cache.parse_entry(raw)))
                self.assertEqual(sh.answer({"st": "hit", "entry": base64.b64encode(raw).decode()}), {"st": "miss"})
        self.assertEqual(sh.answer({"st": "hit", "entry": base64.b64encode(entry()).decode()})["st"], "hit")

    def test_forged_entries_are_misses(self):
        """A job running as rd on the home worker can write any entry; only a MAC made with the agent
        Macs' secret, over this key, these meta fields and these bytes, is ever replayed."""
        sh = rd_cache.Shared(KEY, "o", "mac", 1800, secret=SECRET)
        b64 = lambda raw: {"st": "hit", "entry": base64.b64encode(raw).decode()}   # noqa: E731
        self.assertEqual(sh.answer(b64(entry()))["st"], "hit")
        good = entry(rc=1)
        meta, frames = rd_cache.parse_entry(good)
        forged = {
            "unsigned": entry(secret=None),
            "another secret": entry(secret=b"x" * 32),
            "signed for another key": entry(key="ef" * 32),
            "verdict flipped": rd_cache.entry_bytes(dict(meta, rc=0), frames),
            "node changed": rd_cache.entry_bytes(dict(meta, node="26"), frames),
            "time refreshed": rd_cache.entry_bytes(dict(meta, ts=meta["ts"] + 1), frames),
            "output changed": rd_cache.entry_bytes(meta, [(1, b"all tests passed\n"), frames[1]]),
            "mac not a string": rd_cache.entry_bytes(dict(meta, mac=1), frames),
        }
        for what, raw in forged.items():
            with self.subTest(what):
                self.assertEqual(sh.answer(b64(raw)), {"st": "miss"})
        self.assertEqual(rd_cache.Shared(KEY, "o", "mac", 1800).answer(b64(entry())), {"st": "miss"})  # no key
        # the uploader signs: what it sends verifies, and nothing is sent without a secret
        m = {"v": 1, "rc": 0, "ts": time.time(), "node": "25"}
        sh.ssh = ["/bin/sh", "-c", 'cat > "$0"', os.path.join(self.d, "sent")]
        sh.env_prefix = ""
        sh._argv = lambda op: sh.ssh                             # stand-in for the detached ssh
        self.assertTrue(sh.finish(m, [(1, b"ok\n")]))
        self.assertTrue(self.wait_sent())
        with open(os.path.join(self.d, "sent"), "rb") as f:
            _hdr, _nl, body = f.read().partition(b"\n")
        self.assertEqual(sh.answer(b64(body))["st"], "hit")
        unsigned = rd_cache.Shared(KEY, "o", "mac", 1800)
        self.assertFalse(unsigned.finish(m, [(1, b"ok\n")]))     # not leased, nothing signed: nothing to send

    def wait_sent(self):
        end = time.monotonic() + 10
        while time.monotonic() < end:
            p = os.path.join(self.d, "sent")
            if os.path.exists(p) and os.path.getsize(p) > 0:
                time.sleep(0.1)
                return True
            time.sleep(0.05)
        return False

    def test_key_file_rules_and_the_cli_never_prints_the_key(self):
        home = os.path.join(self.d, "mac")
        os.makedirs(home)
        p = write_key(home)
        self.assertEqual(rd_cache.load_key(p), SECRET)
        os.chmod(p, 0o644)
        self.assertIsNone(rd_cache.load_key(p))                  # readable by others: not a secret
        os.chmod(p, 0o600)
        test_run.wfile(p, "short\n")
        self.assertIsNone(rd_cache.load_key(p))
        os.unlink(p)
        os.symlink(os.path.join(self.d, "elsewhere"), p)
        self.assertIsNone(rd_cache.load_key(p))
        os.unlink(p)
        self.assertIsNone(rd_cache.load_key(p))

        def cli(*args):
            return subprocess.run([sys.executable, "-I", os.path.join(rdmods.STAGE, "rdocker.py"), "pool-cache-key"]
                                  + list(args), env=rdmods.child_env(home), capture_output=True, text=True, timeout=60)
        r = cli("show-fingerprint")
        self.assertEqual(r.returncode, 1)
        self.assertIn("own cache only", r.stdout + r.stderr)
        r = cli("init")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("created", r.stdout)
        self.assertEqual(oct(os.stat(p).st_mode & 0o777), "0o600")
        secret = rd_cache.load_key(p)
        fp = cli("show-fingerprint")
        self.assertEqual((fp.returncode, fp.stdout.strip()), (0, rd_cache.fingerprint(secret)))
        again = cli("init")
        self.assertIn("kept the existing key", again.stdout)
        self.assertEqual(rd_cache.load_key(p), secret)            # never replaced
        for out in (r.stdout + r.stderr, fp.stdout + fp.stderr, again.stdout + again.stderr):
            self.assertNotIn(secret.hex(), out)
            self.assertNotIn(secret.hex()[:16], out)

    def test_fleet_pool_node_major_is_a_validated_int(self):
        import rd_fleet
        base = {"version": 1, "client_keys": [], "machines": [test_pool.worker("w1")]}
        self.assertEqual(rd_fleet.problems(base), [])
        self.assertEqual(rd_fleet.problems(dict(base, pool_node_major=25)), [])
        for bad in ("25", 25.0, True, 0, -1, 1000, [25]):
            with self.subTest(bad=bad):
                self.assertIn("pool_node_major must be a whole number (the node major the pool runs, e.g. 25)",
                              rd_fleet.problems(dict(base, pool_node_major=bad)))
        path = os.path.join(self.d, "fleet.json")
        for doc, want in ((dict(base, pool_node_major=25), 25), (base, None), (dict(base, pool_node_major="x"), None)):
            with open(path, "w") as f:
                json.dump(doc, f)
            self.assertEqual(rd_fleet.pool_node_major({"fleet_path": path}), want)
        self.assertIsNone(rd_fleet.pool_node_major({"fleet_path": os.path.join(self.d, "missing.json")}))

    def test_rd_tune_prunes_expired_then_least_recently_used(self):
        tune = os.path.join(rdmods.STAGE, "server", "rd-tune.sh")
        old_pass = self.put(entry(ts=time.time() - 25 * 3600), "1" * 64 + ".entry")
        old_fail = self.put(entry(rc=1, ts=time.time() - 30 * 60), "2" * 64 + ".entry")
        lru = self.put(entry(out=b"x" * 700000), "3" * 64 + ".entry", age=7200)
        mru = self.put(entry(out=b"y" * 700000), "4" * 64 + ".entry", age=60)
        dead = self.put(json.dumps({"exp": int(time.time()) - 5}).encode(), "5" * 64 + ".lease")
        live = self.put(json.dumps({"exp": int(time.time()) + 600}).encode(), "6" * 64 + ".lease")
        tmp = self.put(b"x", "7" * 64 + ".entry.1.tmp", age=7200)
        p = subprocess.run(["/bin/bash", "-c", 'source "$0" --source; prune_rcache "$1"', tune, self.root],
                           env=dict(self.env, RCACHE_MAX_MB="1", RD_CONF="/nonexistent"),
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([os.path.exists(x) for x in (old_pass, old_fail, lru, mru, dead, live, tmp)],
                         [False, False, False, True, False, True, False])
        self.assertIn("prune rm pool-cache entry 333333333333", p.stdout)


FAKE_VITEST = r'''#!/bin/sh
echo run >> "%(count)s"
echo "vitest out"
echo "vitest err" >&2
while [ -e "%(hold)s" ]; do sleep 0.05; done
[ -n "$VITEST_DOCKER" ] && docker ps >/dev/null
exit ${VITEST_RC:-0}
'''
FAKE_NODE = '#!/bin/sh\n[ "$1" = -v ] && echo "${FAKE_NODE_V-v25.9.0}"\n'   # the node the runner really runs
# a wrapper ssh: SLOW_STORE=<s> holds the pool-cache store op that long before it runs
WRAP_SSH = r'''#!/usr/bin/python3 -I
import os, sys, time
slow = os.environ.get("SLOW_STORE")
if slow and sys.argv[-1].endswith(" store"):
    time.sleep(float(slow))
os.execv(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ssh-real"), ["ssh"] + sys.argv[1:])
'''


class PoolCacheE2E(test_run.RunBase):
    """Real rrun, two workers, each with its own HOME (as in test_pool.PoolE2E): w1 is the home worker
    (keeps ~/rr/rcache), w2 a plain one. Sharding off: one run per job, so runs() counts jobs."""

    def setUp(self):
        super().setUp()
        self.whome = {}
        for n in ("w1", "w2"):
            self.whome[n] = os.path.join(self.d, "home-" + n)
            os.makedirs(self.whome[n])
        self.proc = os.path.join(self.d, "proc")
        test_run.wfile(os.path.join(self.proc, "meminfo"), "MemTotal: 32000000 kB\nMemAvailable: 24000000 kB\n")
        test_run.wfile(os.path.join(self.proc, "loadavg"), "0.10 0 0 1/1 1\n")
        test_run.wfile(os.path.join(self.proc, "cpuinfo"), "processor\t: 0\n\nprocessor\t: 1\n")
        self.count = os.path.join(self.d, "count")
        self.hold = os.path.join(self.d, "hold")          # while it exists, the fake vitest keeps running
        test_run.wfile(os.path.join(self.bin, "vitest"), FAKE_VITEST % {"count": self.count, "hold": self.hold},
                       0o755)
        test_run.wfile(os.path.join(self.bin, "node"), FAKE_NODE, 0o755)
        os.rename(os.path.join(self.bin, "ssh"), os.path.join(self.bin, "ssh-real"))
        test_run.wfile(os.path.join(self.bin, "ssh"), WRAP_SSH, 0o755)
        self.rdir = os.path.join(self.whome["w1"], "rr", "rcache")
        self.home2 = os.path.join(self.d, "home2")          # a second agent Mac
        os.makedirs(self.home2)
        for h in (self.home, self.home2):                   # both hold the one pool-cache key
            write_key(h)
        self.fleet = os.path.join(self.d, "fleet.json")
        self.set_fleet()

    def set_fleet(self, pool_node_major=25, **cfg):
        w1 = test_pool.worker("w1", 1.0)
        w1["roles"] = ["home", "worker"]
        doc = {"version": 1, "client_keys": [], "machines": [w1, test_pool.worker("w2", 0.5)]}
        if pool_node_major is not None:
            doc["pool_node_major"] = pool_node_major          # the pool runs node 25 (the fake node's)
        with open(self.fleet, "w") as f:
            json.dump(doc, f)
        for home in (self.home, self.home2):
            saved, self.home = self.home, home
            self.write_cfg(fleet_path=self.fleet, rr_shard=False, **cfg)
            self.home = saved

    def env(self, **extra):
        homes = ",".join("%s=%s" % kv for kv in sorted(getattr(self, "whome", {}).items()))
        base = {"FAKE_SSH_HOMES": homes, "RRUN_RECONNECT_WAIT": "0"}
        if getattr(self, "proc", None):
            base.update(RR_OS="linux", RR_PROC=self.proc)
        return super().env(**dict(base, **extra))

    def runs(self):
        try:
            with open(self.count) as f:
                return len(f.read().split())
        except OSError:
            return 0

    def env2(self, **extra):
        saved, self.home = self.home, self.home2
        try:
            return self.env(**extra)
        finally:
            self.home = saved

    def rrun2(self, *argv, timeout=60, **env):
        return subprocess.run([test_run.RRUN] + list(argv), cwd=self.wt, env=self.env2(**env),
                              capture_output=True, text=True, timeout=timeout)

    def entries(self, ext=".entry"):
        try:
            return [n for n in os.listdir(self.rdir) if n.endswith(ext)]
        except OSError:
            return []

    def wait_for(self, cond, secs=20):
        end = time.monotonic() + secs
        while time.monotonic() < end:
            if cond():
                return True
            time.sleep(0.05)
        return False

    def test_a_result_made_on_one_mac_replays_on_another(self):
        r1 = self.rrun("vitest", "run")
        self.assertEqual((r1.returncode, self.runs()), (0, 1), r1.stderr)
        self.assertTrue(self.wait_for(lambda: len(self.entries()) == 1), "never uploaded")
        self.assertTrue(self.wait_for(lambda: not self.entries(".lease")), "lease left behind")
        with open(os.path.join(self.rdir, self.entries()[0]), "rb") as f:
            meta = rd_cache.parse_entry(f.read())[0]
        self.assertEqual((meta["node"], meta["worker"], meta["rc"]), ("25", "w1", 0))
        self.assertIn("pool cache (w1): hit - replays the result from", self.rrun2("--where", "vitest", "run").stdout)
        r2 = self.rrun2("vitest", "run")
        self.assertEqual((r2.returncode, self.runs()), (0, 1), r2.stderr)
        self.assertEqual(r2.stdout, r1.stdout)
        self.assertRegex(r2.stderr, r"^vitest err\nrrun: pass \(exit 0 from the pool cache, \d+s\)\n"
                                    r"rrun: cached result from the pool cache \(same code \+ command, \d+s ago on w1"
                                    r" by [^)]+\); RRUN_CACHE=0 to run again\n$")
        route = self.read(os.path.join(self.home2, ".local", "state", "rdocker", "route.log"))
        self.assertRegex(route, r"pcache +rrun +vitest run rc=0 .*pcache=hit")
        # ...and is NOT copied into that Mac's own tier (it has no node check): the next repeat
        # goes through the probe again
        local = os.path.join(self.home2, ".local", "state", "rdocker", "cache")
        self.assertEqual([n for n in os.listdir(local) if n.endswith(".entry")] if os.path.isdir(local) else [], [])
        r3 = self.rrun2("vitest", "run")
        self.assertIn("from the pool cache", r3.stderr)
        # a failure is shared too (20 min), with its exit code and class
        r4 = self.rrun("vitest", "run", VITEST_RC="1")
        self.assertEqual(r4.returncode, 1)
        self.assertTrue(self.wait_for(lambda: len(self.entries()) == 2))
        r5 = self.rrun2("vitest", "run", VITEST_RC="1")
        self.assertEqual((r5.returncode, self.runs()), (1, 2), r5.stderr)
        self.assertIn("rrun: fail (exit 1 from the pool cache", r5.stderr)

    def test_same_mac_local_entry_moved_aside_then_the_pool_serves_it(self):
        """The 2026-11-12 live check, exactly: one Mac runs a check (stored in both tiers), its local
        entry is moved aside, the same command again -> a pool hit (not a second run), and the local
        tier stays empty (pool hits are never promoted). The live miss that prompted this test was a
        runner change (810abba) between the two runs: the runner's hash is part of the key on purpose."""
        r1 = self.rrun("vitest", "run")
        self.assertEqual((r1.returncode, self.runs()), (0, 1), r1.stderr)
        self.assertTrue(self.wait_for(lambda: len(self.entries()) == 1), "never uploaded")
        local = os.path.join(self.home, ".local", "state", "rdocker", "cache")
        mine = [n for n in os.listdir(local) if n.endswith(".entry")]
        self.assertEqual(mine, self.entries())                 # the same key in both tiers
        aside = os.path.join(self.d, "aside.entry")
        os.rename(os.path.join(local, mine[0]), aside)
        r2 = self.rrun("vitest", "run")
        self.assertEqual((r2.returncode, self.runs()), (0, 1), r2.stderr)
        self.assertIn("rrun: pass (exit 0 from the pool cache", r2.stderr)
        self.assertEqual([n for n in os.listdir(local) if n.endswith(".entry")], [])

    def test_a_miss_costs_no_extra_round_trip(self):
        r = self.rrun("vitest", "run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.wait_for(lambda: len(self.entries()) == 1))
        self.assertEqual(self.ops(), ["store"])                   # no check, no touch: the probe did it

    def test_ineligible_and_untrusted_runs_are_never_shared(self):
        for argv, env in ((("/bin/sh", "-c", "echo hi"), {}), (("vitest", "run"), {"VITEST_DOCKER": "1"}),
                          (("vitest", "run"), {"VITEST_RC": "75"}), (("vitest", "run"), {"TEST_DB_URL": "x"})):
            with self.subTest(argv=argv, env=env):
                r = self.rrun(*argv, **env)
                self.assertNotIn("pool cache", r.stderr)
        self.assertTrue(self.wait_for(lambda: not self.entries(".lease")), "a lease was left behind")
        time.sleep(0.5)
        self.assertEqual(self.entries(), [])

    def test_home_unreachable_falls_back_to_this_macs_tier(self):
        t = time.monotonic()
        r1 = self.rrun("vitest", "run", FAKE_SSH_DOWN_HOSTS="w1")
        self.assertEqual((r1.returncode, self.runs()), (0, 1), r1.stderr)
        self.assertLess(time.monotonic() - t, 30)
        self.assertNotIn("in flight", r1.stderr)
        r2 = self.rrun("vitest", "run", FAKE_SSH_DOWN_HOSTS="w1")
        self.assertIn("rrun: cached result (same code + command", r2.stderr)
        self.assertEqual((self.runs(), self.entries()), (1, []))
        self.assertIn("pool cache (w1): did not answer", self.rrun2("--where", "vitest", "run",
                                                                     FAKE_SSH_DOWN_HOSTS="w1").stdout)

    def test_singleflight_the_second_run_waits_and_replays(self):
        open(self.hold, "w").close()
        a = subprocess.Popen([test_run.RRUN, "vitest", "run"], cwd=self.wt, env=self.env(),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(a.wait)
        self.assertTrue(self.wait_for(lambda: self.entries(".lease") and self.runs() == 1), "no lease taken")
        self.assertIn("in flight by", self.rrun2("--where", "vitest", "run").stdout)
        b = subprocess.Popen([test_run.RRUN, "vitest", "run"], cwd=self.wt, env=self.env2(),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertTrue(self.wait_for(lambda: "check" in self.ops()), "the second run never waited")
        os.unlink(self.hold)
        out_a, err_a = a.communicate(timeout=60)
        out_b, err_b = b.communicate(timeout=60)
        b = subprocess.CompletedProcess(b.args, b.returncode, out_b, err_b)
        self.assertEqual((a.returncode, b.returncode, self.runs()), (0, 0, 1), err_a + b.stderr)
        self.assertRegex(b.stderr, r"rrun: identical run in flight by .+ on \S+; waiting for its result\n")
        self.assertIn("rrun: pass (exit 0 from the pool cache", b.stderr)
        self.assertEqual(b.stdout, out_a)
        self.assertRegex(self.read(os.path.join(self.home2, ".local", "state", "rdocker", "route.log")),
                         r"pcache=waited-hit pwait_s=")

    def test_a_lease_that_expires_lets_the_waiter_run(self):
        self.set_fleet(rr_pool_cache_stale_s=600)
        r0 = self.rrun("--where", "vitest", "run")             # the key: plant a lease another Mac holds
        self.assertIn("pool cache (w1): miss", r0.stdout)
        key = self.key_of()
        os.makedirs(self.rdir, exist_ok=True)
        test_run.wfile(os.path.join(self.rdir, key + ".lease"), json.dumps(
            {"owner": "ghost", "host": "gone", "pid": 1, "token": TOKEN, "t": int(time.time()),
             "exp": int(time.time()) + 3}))
        t = time.monotonic()
        r = self.rrun2("vitest", "run")
        self.assertEqual((r.returncode, self.runs()), (0, 1), r.stderr)
        self.assertIn("identical run in flight by ghost on gone; waiting", r.stderr)
        self.assertIn("without a result to share; running it now", r.stderr)
        self.assertLess(time.monotonic() - t, 30)

    def test_an_owner_that_dies_frees_the_waiter(self):
        self.set_fleet(rr_pool_cache_stale_s=2, rr_pool_cache_refresh_s=0.5)
        open(self.hold, "w").close()
        a = subprocess.Popen([test_run.RRUN, "vitest", "run"], cwd=self.wt, env=self.env(),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(a.wait)
        self.addCleanup(lambda: os.killpg(a.pid, signal.SIGKILL) if a.poll() is None else None)
        self.assertTrue(self.wait_for(lambda: self.entries(".lease") and self.runs() == 1), "owner never started")
        time.sleep(1.5)                       # the owner refreshes its lease while alive
        b = subprocess.Popen([test_run.RRUN, "vitest", "run"], cwd=self.wt, env=self.env2(),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertTrue(self.wait_for(lambda: "check" in self.ops()), "the second run never waited")
        os.killpg(a.pid, signal.SIGKILL)      # the owner dies: nothing refreshes or releases its lease
        os.unlink(self.hold)
        _out, err = b.communicate(timeout=60)
        self.assertEqual((b.returncode, self.runs()), (0, 2), err)
        self.assertIn("identical run in flight by", err)
        self.assertIn("running it now", err)

    def test_a_cancelled_waiter_just_exits(self):
        key = self.key_of()
        os.makedirs(self.rdir, exist_ok=True)
        lease = os.path.join(self.rdir, key + ".lease")
        test_run.wfile(lease, json.dumps({"owner": "o", "host": "h", "pid": 1, "token": TOKEN,
                                          "t": int(time.time()), "exp": int(time.time()) + 600}))
        b = subprocess.Popen([test_run.RRUN, "vitest", "run"], cwd=self.wt, env=self.env2(),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertTrue(self.wait_for(lambda: "check" in self.ops()), "never waited")
        b.send_signal(signal.SIGINT)
        _out, err = b.communicate(timeout=30)
        self.assertEqual((b.returncode, self.runs()), (130, 0), err)
        self.assertIn("rrun: infra (exit 130", err)
        self.assertEqual(jload(lease)["token"], TOKEN)          # not ours: untouched

    def test_rrun_cache_0_bypasses_both_tiers(self):
        self.rrun("vitest", "run")
        self.assertTrue(self.wait_for(lambda: len(self.entries()) == 1))
        key = self.entries()[0][:-len(".entry")]
        lease = os.path.join(self.rdir, key + ".lease")
        test_run.wfile(lease, json.dumps({"owner": "o", "host": "h", "pid": 1, "token": TOKEN,
                                          "t": int(time.time()), "exp": int(time.time()) + 600}))
        r = self.rrun2("vitest", "run", RRUN_CACHE="0")
        self.assertEqual((r.returncode, self.runs()), (0, 2), r.stderr)
        self.assertNotIn("pool cache", r.stderr)
        self.assertNotIn("in flight", r.stderr)
        self.assertEqual(jload(lease)["token"], TOKEN)

    def test_the_upload_never_delays_the_result(self):
        t = time.monotonic()
        r = self.rrun("vitest", "run", SLOW_STORE="6")
        took = time.monotonic() - t
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(took, 6, "rrun waited on the upload")
        self.assertEqual(self.entries(), [])                     # still on its way
        self.assertTrue(self.wait_for(lambda: len(self.entries()) == 1, 30), "the detached upload never landed")

    def test_a_result_from_another_node_major_is_not_replayed(self):
        self.rrun("vitest", "run")
        self.assertTrue(self.wait_for(lambda: len(self.entries()) == 1))
        self.assertIn("pool cache (w1): hit", self.rrun2("--where", "vitest", "run").stdout)
        self.set_fleet(pool_node_major=26)                       # the owner bumped it: workers upgraded
        self.assertIn("a result made with node 25, but the pool runs node 26",
                      self.rrun2("--where", "vitest", "run").stdout)
        r = self.rrun2("vitest", "run", FAKE_NODE_V="v26.0.0")
        self.assertEqual((r.returncode, self.runs()), (0, 2), r.stderr)
        self.assertNotIn("from the pool cache", r.stderr)

    def test_a_worker_on_another_major_never_shares(self):
        r = self.rrun("vitest", "run", FAKE_NODE_V="v24.1.0")     # declared 25, the runner really ran 24
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.wait_for(lambda: not self.entries(".lease")), "lease left behind")
        time.sleep(0.5)
        self.assertEqual(self.entries(), [])
        r = self.rrun2("vitest", "run")
        self.assertEqual((r.returncode, self.runs()), (0, 2), r.stderr)

    def test_an_unknown_runtime_is_never_shared(self):
        r = self.rrun("vitest", "run", FAKE_NODE_V="")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.wait_for(lambda: not self.entries(".lease")), "lease left behind")
        time.sleep(0.5)
        self.assertEqual(self.entries(), [])

    def test_a_signed_entry_with_another_node_tag_is_not_replayed(self):
        """Signed by a real client, but tagged 24 (made before pool_node_major moved): never replayed."""
        key = self.key_of()
        os.makedirs(self.rdir, exist_ok=True)
        test_run.wfile(os.path.join(self.rdir, key + ".entry"), entry(out=b"OLD\n", node="24", key=key).decode())
        r = self.rrun2("vitest", "run")
        self.assertEqual((r.returncode, self.runs()), (0, 1), r.stderr)
        self.assertNotIn("OLD", r.stdout)

    def test_no_pool_node_major_means_no_pool_tier(self):
        self.set_fleet(pool_node_major=None)
        w = self.rrun2("--where", "vitest", "run").stdout
        self.assertIn("cache: miss", w)
        self.assertNotIn("pool cache", w)
        r = self.rrun("vitest", "run")
        self.assertEqual(r.returncode, 0, r.stderr)
        time.sleep(0.5)
        self.assertEqual((self.ops(), self.entries(), self.entries(".lease")), ([], [], []))

    def test_a_forged_entry_on_the_home_worker_is_never_replayed(self):
        key = self.key_of()
        os.makedirs(self.rdir, exist_ok=True)
        test_run.wfile(os.path.join(self.rdir, key + ".entry"),
                       entry(out=b"FORGED all green\n", secret=None, key=key).decode())
        r = self.rrun2("vitest", "run")
        self.assertEqual((r.returncode, self.runs()), (0, 1), r.stderr)
        self.assertNotIn("FORGED", r.stdout)
        self.assertNotIn("pool cache", r.stderr)
        self.assertTrue(self.wait_for(lambda: self.signed_entry(key)), "the real result never replaced it")

    def test_no_key_file_means_this_macs_tier_only(self):
        os.unlink(os.path.join(self.home2, ".config", "rdocker", "pool-cache.key"))
        w = self.rrun2("--where", "vitest", "run").stdout
        self.assertIn("cache: miss", w)
        self.assertNotIn("pool cache", w)
        r = self.rrun2("vitest", "run")
        self.assertEqual((r.returncode, self.runs()), (0, 1), r.stderr)
        time.sleep(0.5)
        self.assertEqual((self.ops(), self.entries(), self.entries(".lease")), ([], [], []))
        self.assertIn("rrun: cached result (same code + command", self.rrun2("vitest", "run").stderr)

    def test_a_waiter_never_waits_past_its_own_cap(self):
        self.set_fleet(rr_pool_cache_stale_s=600)
        key = self.key_of()
        os.makedirs(self.rdir, exist_ok=True)
        lease = os.path.join(self.rdir, key + ".lease")
        test_run.wfile(lease, json.dumps({"owner": "slowpoke", "host": "h", "pid": 1, "token": TOKEN,
                                          "t": int(time.time()), "exp": int(time.time()) + 86400}))
        t = time.monotonic()
        r = self.rrun2("vitest", "run", RRUN_TIMEOUT="0.05")     # a 3 s cap; the owner's lease runs a day
        took = time.monotonic() - t
        self.assertEqual((r.returncode, self.runs()), (0, 1), r.stderr)
        self.assertIn("identical run in flight by slowpoke", r.stderr)
        self.assertIn("(this job's cap) for the identical run; running it now", r.stderr)
        self.assertLess(took, 20)

    # -------------------------------------------------------------- helpers
    def key_of(self):
        """The cache key of `vitest run` in the worktree, as rrun computes it."""
        p = subprocess.run([sys.executable, "-I", "-c", KEY_SCRIPT, rdmods.STAGE], cwd=self.wt,
                           env=self.env2(), capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def signed_entry(self, key):
        p = os.path.join(self.rdir, key + ".entry")
        try:
            with open(p, "rb") as f:
                got = rd_cache.parse_entry(f.read())
        except OSError:
            return False
        return bool(got) and rd_cache.Shared(key, "o", "m", 60, secret=SECRET).signed(*got)

    def ops(self):
        """The pool-cache ops (check / touch / store) sent over ssh so far, in order (the PROBE,
        which carries the lookup, is not one of them)."""
        import ast
        out = []
        for ln in self.read(self.sshlog).splitlines() if os.path.exists(self.sshlog) else []:
            cmd = ast.literal_eval(ln)[-1]
            if "rc_lease" in cmd and "slots_busy" not in cmd:
                out.append(cmd.rsplit(" ", 1)[-1])
        return out


KEY_SCRIPT = r'''
import os, sys
sys.path.insert(0, sys.argv[1])
import rd_common, rd_pool, rd_run
cfg = rd_common.load_cfg()
wt = rd_run.resolve_worktree(os.getcwd())
argv = ["vitest", "run"]
job = rd_pool.classify(argv, [], os.getcwd())
deps = rd_run.deps_dirs(wt["top"], wt["relcwd"], argv)
crun, why = rd_run.cache_prepare(cfg, wt, argv, {}, deps, job, [])
print(crun.key)
'''


if __name__ == "__main__":
    unittest.main()
