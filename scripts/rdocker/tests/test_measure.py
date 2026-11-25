"""share/rd-measure.py and rd_logcache (2026-11-24): the online rule (started / warm rows only, a refusal
is no capacity), UTC and local runs.log stamps, the interrupted-runs and worker-contention sections, and
the persistent log cache (merge never loses a line; an unreachable machine is read from the copy)."""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402

import rd_logcache  # noqa: E402

_spec = importlib.util.spec_from_file_location("rd_measure", os.path.join(rdmods.STAGE, "share", "rd-measure.py"))
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)

T0 = dt.datetime(2026, 11, 24, 10, 0).timestamp()


def stamp(t, utc=False):
    d = dt.datetime.fromtimestamp(t, dt.timezone.utc if utc else None)
    return d.strftime("%Y-%m-%dT%H:%M:%S+0000") if utc else d.astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def line(end, out="rc=0", prep=1.0, cmd=10.0, argv="npx tsc --noEmit", repo="dentall.1", run="r1", owner="session:a",
         cls="normal", slot=0.0, utc=False):
    return "%s repo=%s wt=w1 sha=s1 outcome=%s prepare_s=%s cmd_s=%s argv=%s\trun=%s owner=%s cls=%s slot_s=%s lock_s=0\n" % (
        stamp(end, utc), repo, out, prep, cmd, argv, run, owner, cls, slot)


def rows(text, w="hp"):
    return m.parse_runs(text, w)


class Parse(unittest.TestCase):
    def test_utc_and_local_stamps_are_the_same_instant(self):
        a, b = rows(line(T0, utc=True)), rows(line(T0))
        self.assertEqual(a[0]["end"], b[0]["end"])
        self.assertEqual((a[0]["run"], a[0]["owner"]), ("r1", "session:a"))


class Online(unittest.TestCase):
    def test_refusals_are_never_capacity(self):
        refusing = rows(line(T0 - 600, out="busy", prep="-", cmd="-") + line(T0 - 60, out="refused rc=69"), "x")
        self.assertFalse(m.online(m.online_index(refusing), T0))

    def test_started_row_makes_it_online_until_a_later_refusal(self):
        rs = rows(line(T0 - 1200) + line(T0 - 300, out="busy", prep="-", cmd="-"), "x")
        idx = m.online_index(rs)
        self.assertTrue(m.online(idx, T0 - 600))          # after the run, before the refusal
        self.assertFalse(m.online(idx, T0))               # its latest word is a refusal
        self.assertTrue(m.online(m.online_index(rows(line(T0 - 600, out="warm", cmd="-"), "x")), T0))
        self.assertFalse(m.online(m.online_index(rs), T0 - 1200 - m.ONLINE_S - 400))   # never on later rows alone

    def test_only_taking_work_again_clears_a_refusal(self):
        rs = rows(line(T0 - 1200) + line(T0 - 600, out="busy", prep="-", cmd="-")
                  + line(T0 - 300, out="moved", prep="-", cmd="-"), "x")
        self.assertFalse(m.online(m.online_index(rs), T0))          # a later moved row says nothing
        rs += rows(line(T0 - 100, cmd=5.0, run="again"), "x")
        self.assertTrue(m.online(m.online_index(rs), T0))

    def test_replay_never_places_on_a_refusing_worker(self):
        fleet = {"machines": [{"name": "hp", "roles": ["worker"], "max_slots": 1, "speed": 1.0},
                              {"name": "x", "roles": ["worker"], "max_slots": 4, "speed": 4.0}]}
        hp = rows(line(T0, cmd=300.0, slot=600.0, run="h1"), "hp")
        refusing = rows("".join(line(T0 - k * 300, out="busy", prep="-", cmd="-", run="b%d" % k) for k in range(1, 4)), "x")
        _, res = m.replay(hp + refusing, fleet, T0 - 3600, T0 + 60, 20.0, False)
        self.assertEqual(res, [])
        working = rows(line(T0 - 1000, cmd=5.0, run="x1") + line(T0 - 990, cmd=5.0, run="x2") + line(T0 - 980, cmd=5.0, run="x3"), "x")
        _, res = m.replay(hp + working, fleet, T0 - 3600, T0 + 60, 20.0, False)
        self.assertEqual([r["w"] for r in res], ["x"])
        tl = m.timeline(refusing, fleet, T0 - 900, T0)
        self.assertEqual(tl["util_p50"], None)            # no minute had any capacity online
        self.assertEqual(m.replay(hp, {"machines": fleet["machines"][1:]}, T0 - 3600, T0 + 60, 20.0, False), ([], []))


class Interrupted(unittest.TestCase):
    def test_kinds_hours_and_identical_successors(self):
        txt = (line(T0, out="lost rc=143", prep=0.0, cmd=3600.0, run="a", owner="session:s1")
               + line(T0 + 400, run="a2", owner="session:s1", cmd=100.0)            # same session, 5 min later
               + line(T0 + 5, out="lost rc=143", prep=0.0, cmd=60.0, argv="npm run z", run="p", owner="-")
               + line(T0 + 30, argv="npm run z", run="p2", owner="-", cmd=10.0)      # owner "-" is no session
               + line(T0 + 1000, out="interrupted rc=130", prep=0.0, cmd=1800.0, argv="npm run test:db", run="b")
               + line(T0 + 1300, argv="npm run test:db", run="b2", owner="session:other", cmd=10.0)  # other session
               + line(T0 + 2000, out="rc=143", prep=0.0, cmd=360.0, argv="npm run x", run="c")
               + line(T0 + 2000 + 700, argv="npm run x", run="c2", cmd=10.0)          # too late (> 10 min)
               + line(T0 + 3000, out="lost rc=143", prep=0.0, cmd=360.0, argv="npm run y", run="d")
               + line(T0 + 3010, out="rc=0", argv="npm run y", run="d", cmd=1.0)      # same run id: a retry, not a rerun
               + line(T0 + 4000, out="timeout rc=124", prep=0.0, cmd=7200.0, argv="npm run e", run="e"))
        route = [{"rc": 143, "wall": 500.0, "slot": 50.0, "lock": 0.0, "start": 100.0, "host": "hp"},   # start_s holds slot
                 {"rc": 130, "wall": 10.0, "slot": 20.0, "lock": 0.0, "start": None, "host": "ethanair"},
                 {"rc": 0, "wall": 10.0, "slot": 0.0, "lock": 0.0, "start": 0.0, "host": "hp"}]
        v = m.interrupted(rows(txt), route, T0 - 1, T0 + 5000)
        self.assertEqual(v["runs"], 5)
        self.assertEqual(set(v["by_kind"]), {"lost rc=143", "interrupted rc=130", "rc=143"})
        self.assertAlmostEqual(v["job_h"], 1.0 + 0.5 + 0.1 + 0.1 + 60 / 3600.0)
        self.assertEqual((v["successor_same_session"], v["successor_any_session"]), (1, 3))
        self.assertAlmostEqual(v["successor_any_session_job_h"], 1.5 + 60 / 3600.0)
        self.assertAlmostEqual(v["join_saves_same_session_job_h"], (100 + 1) / 3600.0)   # min(lost, rerun)
        self.assertAlmostEqual(v["join_saves_any_session_job_h"], (100 + 1 + 11 + 11) / 3600.0)
        self.assertEqual((v["cap_kills"], v["cap_kills_job_h"]), (1, 2.0))
        cs = v["client_side"]
        self.assertEqual((cs["runs"], sorted(cs["by_host"])), (2, ["ethanair", "hp"]))
        self.assertAlmostEqual(cs["job_h"], 400.0 / 3600)


class Contention(unittest.TestCase):
    def test_same_command_slower_when_the_worker_is_full(self):
        txt, k = "", 0
        for i in range(4):                                # alone: 60 s each
            txt += line(T0 + i * 1000, cmd=60.0, prep=0.0, run="lo%d" % i)
        for i in range(4):                                # beside 7 long fillers: 120 s each
            t = T0 + 10000 + i * 1000
            txt += line(t, cmd=120.0, prep=0.0, run="hi%d" % i)
            for _ in range(7):
                k += 1
                txt += line(t + 10, cmd=200.0, prep=0.0, argv="sleep 1", run="f%d" % k)
        c = m.contention(rows(txt), T0 - 100, T0 + 20000)
        g = c["hp"]["groups"]["dentall | npx tsc --noEmit"]
        self.assertEqual({b: x["n"] for b, x in g["buckets"].items()}, {"<=3": 4, "7+": 4})
        self.assertAlmostEqual(g["slow_top"], 2.0)
        self.assertAlmostEqual(c["hp"]["slow_top_med"], 2.0)


class Cache(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="logcache-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)

    def test_merge_dedupes_records_and_never_loses_a_line(self):
        a = "2026-11-24 10:00:00 hp rrun bash -c 'x\n}\n' rc=0 1.0s | /w\n2026-11-24 10:01:00 hp rrun y rc=0 1.0s | /w\n"
        b = "2026-11-24 10:01:00 hp rrun y rc=0 1.0s | /w\n2026-11-24 10:02:00 hp rrun bash -c 'z\n}\n' rc=0 1.0s | /w"
        self.assertEqual(rd_logcache.merge(self.d, "route.c", a), 2)
        self.assertEqual(rd_logcache.merge(self.d, "route.c", b), 1)       # the shared "}" line is kept twice
        self.assertEqual(rd_logcache.merge(self.d, "route.c", a + b.split("\n", 1)[1]), 0)   # the whole log again
        text, newest = rd_logcache.read(self.d, "route.c")
        self.assertEqual(text, a + b.split("\n", 1)[1] + "\n")
        self.assertEqual(newest, dt.datetime(2026, 11, 24, 10, 2).timestamp())
        self.assertEqual(rd_logcache.read(self.d, "nope"), (None, None))

    def test_identical_lines_in_one_log_are_all_kept(self):
        a = "2026-11-24 10:00:00 mini ps ok | /w\n" * 3 + "2026-11-24 10:00:01 mini ps ok | /w\n"
        self.assertEqual(rd_logcache.merge(self.d, "route.c", a), 4)
        self.assertEqual(rd_logcache.merge(self.d, "route.c", a), 0)
        self.assertEqual(rd_logcache.merge(self.d, "route.c", a[a.index("\n") + 1:] + "2026-11-24 10:00:02 x\n"), 1)
        self.assertEqual(rd_logcache.read(self.d, "route.c")[0], a + "2026-11-24 10:00:02 x\n")

    def main_out(self, fetched):
        fleet = os.path.join(self.d, "fleet.json")
        with open(fleet, "w") as f:
            json.dump({"machines": [{"name": "hp", "alias": "rd-hp", "roles": ["worker"], "max_slots": 2},
                                    {"name": "mbp", "alias": "rd-mbp", "roles": ["worker"], "max_slots": 2}]}, f)
        argv = ["rd-measure", "--fleet", fleet, "--cache", os.path.join(self.d, "c"), "--json",
                "--since", dt.datetime.fromtimestamp(T0 - 7200).strftime("%Y-%m-%d %H:%M"),
                "--until", dt.datetime.fromtimestamp(T0 + 3600).strftime("%Y-%m-%d %H:%M")]
        buf = io.StringIO()
        with mock.patch.object(sys, "argv", argv), mock.patch.object(m, "fetch", side_effect=lambda alias, p: fetched.get(alias)), \
                contextlib.redirect_stdout(buf):
            m.main()
        return json.loads(buf.getvalue())

    def test_an_unreachable_worker_is_read_from_the_cache(self):
        first = self.main_out({"rd-hp": line(T0), "rd-mbp": line(T0 - 60, run="m1")})
        self.assertEqual((first["classes"]["all"]["jobs"], first["cache_only_age_s"]), (2, {}))
        out = self.main_out({"rd-hp": line(T0 + 60, run="h2")})          # mbp offline now
        self.assertEqual(out["classes"]["all"]["per_worker"], {"hp": 2, "mbp": 1})   # hp: the cache adds the old line
        self.assertEqual(sorted(out["cache_only_age_s"]), ["runs.mbp"])
        self.assertIn("route.this-mac", out["missing"])
        out = self.main_out({"rd-hp": line(T0 + 60, run="h2"), "rd-mbp": ""})   # answered, but no log read
        self.assertEqual(sorted(out["cache_only_age_s"]), ["runs.mbp"])


if __name__ == "__main__":
    unittest.main()
