"""Laptop janitor (rdocker.placed=laptop-throwaway stamp, `rdocker laptop-janitor-run`) and the
auto-restart of janitor-stopped containers. Same seams as test_janitor / test_shim_safety: temp HOME,
tests/fake_docker.py on PATH, subprocess runs of rdocker.py (one in-process test for the mid-pass pin).

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import json
import os
import subprocess
import time
import unittest
from unittest import mock

import rdmods
from rdmods import MODULES
from test_janitor import DAY, HOUR, INTERVAL, NOW, SYSTIME, JanitorCase, running, stopped, ts
from test_shim_safety import RDOCKER, ShimCase, wait_bg_sync

rd_common, rd_janitor, rd_tunnel, rd_setup = (
    next(m for m in MODULES if m.__name__ == n)
    for n in ("rd_common", "rd_janitor", "rd_tunnel", "rd_setup"))

PLACED = {"rdocker.placed": "laptop-throwaway"}
STAMP = ["--label", "rdocker.placed=laptop-throwaway"]


def stamped(**kw):
    labels = dict(PLACED, **kw.pop("Labels", {}))
    return dict(Labels=labels, **kw)


class Stamp(ShimCase):
    """Every throwaway-shaped run/create the shim sends to the laptop carries the stamp; nothing
    else does."""
    DOWN = {"reachable": False, "docker_ok": False, "rtt_ms": None}

    def run_argv(self):
        runs = [(c, a) for c, a in self.calls() if a[:1] in (["run"], ["create"])
                or a[:2] in (["container", "run"], ["container", "create"])]
        self.assertEqual(len(runs), 1, runs)
        return runs[0]

    def test_throwaway_laptop_creates_are_stamped(self):
        cases = (
            ("fallback", self.DOWN, None, ("run", "--rm", "alpine", "true")),
            ("mode=local", None, {"RDOCKER_MODE": "local"}, ("run", "-d", "alpine", "sleep", "9")),
            ("bind mount", None, None, ("run", "-d", "-v", "/tmp:/x", "alpine", "sleep", "9")),
            ("create", None, {"RDOCKER_MODE": "local"}, ("create", "alpine")),
            ("container run", None, {"RDOCKER_MODE": "local"}, ("container", "run", "--rm", "alpine")),
        )
        for i, (label, health, env, argv) in enumerate(cases):
            with self.subTest(label):
                if os.path.exists(self.log):
                    os.unlink(self.log)
                self.scenario(health=health, tunnel=False, laptop_up=i == 0)
                p = self.shim(*argv, env=env)
                self.assertEqual(p.returncode, 0, p.stderr)
                ctx, a = self.run_argv()
                self.assertEqual(ctx, "desktop-linux")
                n = 2 if a[0] == "container" else 1
                self.assertEqual(a[n:n + 2], STAMP, a)
                self.assertEqual(a[n + 2:], list(argv[n:]))

    def test_non_throwaway_and_mini_creates_are_not_stamped(self):
        cases = (
            ("named volume on laptop", {"RDOCKER_MODE": "local"},
             ("run", "-d", "-v", "data:/d", "postgres")),
            ("keep label on laptop", {"RDOCKER_MODE": "local"},
             ("run", "-d", "--label", "rdocker.keep=1", "postgres")),
            ("throwaway on the mini", None, ("run", "--rm", "alpine", "true")),
        )
        for i, (label, env, argv) in enumerate(cases):
            with self.subTest(label):
                if os.path.exists(self.log):
                    os.unlink(self.log)
                self.scenario(laptop_up=i == 0, tunnel=i == 0)
                p = self.shim(*argv, env=env)
                self.assertEqual(p.returncode, 0, p.stderr)
                _, a = self.run_argv()
                self.assertNotIn("rdocker.placed=laptop-throwaway", a)


class LaptopCase(JanitorCase):
    def setUp(self):
        super().setUp()
        self.lpath = os.path.join(self.state, "laptop_janitor.json")
        self.first = True

    def laptop(self, containers=None, mini=None, pins=None, **knobs):
        eng = {"containers": containers or {}, "system_time": SYSTIME}
        eng.update(knobs)
        meng = {"containers": mini or {}, "system_time": SYSTIME}
        self.scenario(mini=meng, laptop=eng, pins=pins, tunnel=False, laptop_up=self.first)
        self.first = False

    def lledger(self, data):
        with open(self.lpath, "w") as f:
            json.dump(data, f)

    def lstate(self):
        with open(self.lpath) as f:
            return json.load(f)

    def pass_(self):
        e = rdmods.child_env(self.home, self.bin, FAKE_DOCKER_FIXTURE=self.fixture,
                             FAKE_DOCKER_LOG=self.log)
        p = subprocess.run(["/usr/bin/python3", "-I", RDOCKER, "laptop-janitor-run"],
                           capture_output=True, text=True, env=e, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def idle(self, *cids, hours=3):
        return {"idle": {c: {"idle_s": hours * HOUR, "last_sample": NOW - INTERVAL,
                             "netio": "1kB / 1kB"} for c in cids}}


class LaptopJanitor(LaptopCase):
    def test_idle_stop_then_rm_after_24h(self):
        mounts = [{"Type": "volume", "Name": "anon1"}]
        self.laptop({"vit-db": stamped(**running("idv", netio="1kB / 1kB", Mounts=mounts))},
                    volumes={"anon1": {}})
        self.lledger(self.idle("idv"))
        self.pass_()
        self.assertIn(["stop", "idv"], self.argvs())
        st = self.lstate()
        self.assertNotIn("idv", st["idle"])
        self.assertEqual(st["stopped_by_janitor"]["idv"]["name"], "vit-db")
        self.assertEqual(st["stopped_by_janitor"]["idv"]["idle_h"], 3)
        # a day later it is still stopped -> removed with its anonymous volume
        os.unlink(self.log)
        self.laptop({"vit-db": stamped(**stopped("idv", hours_ago=25, Mounts=mounts))},
                    volumes={"anon1": {}})
        self.pass_()
        self.assertIn(["rm", "-v", "idv"], self.argvs())
        with open(os.path.join(self.state, "daemon.log")) as f:
            log = f.read()
        self.assertIn("laptop janitor: stop vit-db", log)
        self.assertIn("laptop janitor: rm vit-db", log)

    def test_ttl_honoured(self):
        self.laptop({"t": stamped(**running("idt", Labels={"rdocker.ttl": "2h"}))})
        self.pass_()
        self.assertIn(["rm", "-f", "idt"], self.argvs())

    def test_protected_containers_untouched(self):
        mounts = [{"Type": "volume", "Name": "kv"}]
        containers = {
            "unstamped": running("idu", netio="1kB / 1kB"),
            "pinned": stamped(**running("idp", netio="1kB / 1kB")),
            "kept": stamped(**running("idk", netio="1kB / 1kB", Labels={"rdocker.keep": "1"})),
            "keptvol": stamped(**running("idkv", netio="1kB / 1kB", Mounts=mounts)),
            "proj-db": stamped(**running("idc", netio="1kB / 1kB",
                                         Labels={"com.docker.compose.project": "proj"})),
            "old-pinned": stamped(**stopped("idop", hours_ago=48)),
            "victim": stamped(**running("idv", netio="1kB / 1kB")),
        }
        self.laptop(containers, volumes={"kv": {"Labels": {"rdocker.keep": "1"}}},
                    pins={"containers": ["pinned", "old-pinned"], "compose_projects": ["proj"]})
        self.lledger(self.idle("idu", "idp", "idk", "idkv", "idc", "idv", hours=10))
        self.pass_()
        d = self.destructive()
        self.assertEqual(d, [["stop", "idv"]], d)          # only the unprotected stamped one

    def test_pin_added_mid_pass_is_respected(self):
        """In-process: the pin lands after the selection (during `docker stats`); the fresh re-check
        right before `stop` must see it."""
        self.laptop({"vit-db": stamped(**running("idv", netio="1kB / 1kB"))})
        cfg_path, state_path = rd_common.CFG_PATH, rd_common.LAPTOP_JANITOR_PATH
        for p in (cfg_path, state_path):
            if os.path.exists(p):
                os.unlink(p)
        self.addCleanup(lambda: [os.unlink(p) for p in (cfg_path, state_path)
                                 if os.path.exists(p)])
        rd_common.save_cfg(rd_common.merge_cfg({}))
        rd_common.save_json(state_path, self.idle("idv", hours=10))
        real_dk = rd_common.dk

        def dk(ctx, *args, **kw):
            if args[:1] == ("stats",):
                rd_common.update_cfg(lambda c: dict(c, pins=dict(c["pins"], containers=["vit-db"])))
            return real_dk(ctx, *args, **kw)
        env = {"FAKE_DOCKER_FIXTURE": self.fixture, "FAKE_DOCKER_LOG": self.log,
               "PATH": rdmods.safe_path(self.bin)}         # merged into os.environ by patch.dict
        with mock.patch.dict("os.environ", env), \
                mock.patch.object(rd_common, "dk", dk), \
                mock.patch.object(rd_tunnel, "local_engine_up", lambda c: True):
            acts = rd_janitor.laptop_janitor(rd_common.load_cfg())
        self.assertNotIn(["stop", "idv"], self.argvs())
        self.assertFalse([a for a in acts if a.startswith("stop")], acts)

    def test_never_calls_the_mini(self):
        self.laptop({"a": stamped(**running("ida", netio="1kB / 1kB")),
                     "b": stamped(**stopped("idb", hours_ago=30))},
                    mini={"a": running("ida", netio="1kB / 1kB")})
        self.lledger(self.idle("ida"))
        self.pass_()
        ctxs = {c for c, _ in self.calls()}
        self.assertEqual(ctxs, {"desktop-linux"}, self.calls())
        self.assertIn(["exec", "ida", "cat", "/proc/net/tcp", "/proc/net/tcp6"], self.argvs())

    def test_desktop_down_means_no_docker_call(self):
        self.laptop({"a": stamped(**running("ida"))})
        for s in self.socks:
            s.close()
        os.unlink(self.local_sock)
        self.pass_()
        self.assertEqual(self.calls(), [])

    def test_mini_and_laptop_idle_state_do_not_clobber(self):
        self.laptop({"l": stamped(**running("idl", netio="1kB / 1kB"))},
                    mini={"m": running("idm", netio="1kB / 1kB")})
        mini_idle = {"idm": {"idle_s": 60.0, "last_sample": NOW - INTERVAL, "netio": "1kB / 1kB"}}
        self.ledger({"idle": mini_idle})
        self.lledger({"idle": {"idl": {"idle_s": 30.0, "last_sample": NOW - INTERVAL,
                                       "netio": "1kB / 1kB"}}})
        self.pass_()
        self.assertEqual(self.jstate()["idle"], mini_idle)             # mini state untouched
        self.assertEqual(self.lstate()["idle"]["idl"]["idle_s"], 30.0 + INTERVAL)
        self.clean()                                                    # a mini pass
        self.assertEqual(self.lstate()["idle"]["idl"]["idle_s"], 30.0 + INTERVAL)
        self.assertEqual(self.jstate()["idle"]["idm"]["idle_s"], 60.0 + INTERVAL)
        self.assertNotIn("idl", self.jstate()["idle"])

    def test_pass_seeing_a_container_running_drops_its_record(self):
        self.laptop({"a": stamped(**running("ida", netio="1kB / 1kB"))})
        self.lledger({"stopped_by_janitor": {"ida": {"name": "a", "ts": time.time() - HOUR,
                                                     "idle_h": 3}}})
        self.pass_()
        self.assertEqual(self.lstate()["stopped_by_janitor"], {})

    def test_failure_sets_own_attention_key(self):
        self.laptop({"a": stamped(**running("ida", netio="1kB / 1kB"))}, fail=["stop"])
        self.lledger(self.idle("ida", hours=4))
        self.pass_()
        self.assertIn("laptop-janitor-error", self.attention())
        self.assertNotIn("janitor-error", self.attention())


class MiniStopRecord(JanitorCase):
    def test_mini_janitor_records_idle_stops(self):
        self.mini({"db": running("iddb", netio="1kB / 1kB")})
        self.ledger({"idle": {"iddb": {"idle_s": 3 * HOUR, "last_sample": NOW - INTERVAL,
                                       "netio": "1kB / 1kB"}}})
        self.clean()
        rec = self.jstate()["stopped_by_janitor"]["iddb"]
        self.assertEqual((rec["name"], rec["idle_h"]), ("db", 3))


class AutoRestart(ShimCase):
    """A targeted command at a container the janitor idle-stopped starts it first, once."""
    # last started 5 h ago, i.e. before the record's ts (now): it has not run since the janitor stop
    STOPPED_BEFORE = {"Id": "iddb", "running": False, "StartedAt": ts(time.time() - 5 * HOUR)}

    def test_user_started_after_janitor_stop_then_killed_is_not_restarted(self):
        # review 2026-10-14: janitor stops X, user starts X, X stops another way, next exec restarted it
        self.scenario(mini={"containers": {"db": self.STOPPED_BEFORE}})
        path = self.record("mini", "iddb", "db", ts=time.time() - HOUR)
        # the user's own start, then a stop that is not a routed stop/rm (here: --context kill)
        self.assertEqual(self.shim("--context", "mini", "start", "db").returncode, 0)
        self.assertEqual(self.shim("--context", "mini", "kill", "db").returncode, 0)
        p = self.shim("exec", "db", "psql")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("start"), [("mini", ["start", "db"])])   # only the user's
        self.assertNotIn("restarted", p.stderr)
        self.assertEqual(self.calls("exec"), [("mini", ["exec", "db", "psql"])])
        self.assertEqual(self.recorded(path), {})                       # stale record dropped

    def test_did_not_come_up_says_so_and_still_runs_the_command(self):
        self.scenario(mini={"containers": {"db": dict(self.STOPPED_BEFORE, no_start=True)}})
        self.record("mini", "iddb", "db")
        p = self.shim("exec", "db", "psql")
        self.assertIn("rdocker: tried to restart db but it did not come up", p.stderr)
        self.assertNotIn("restarted db", p.stderr)
        self.assertEqual(self.calls("exec"), [("mini", ["exec", "db", "psql"])])

    def test_short_name_never_matches_by_id_prefix(self):
        stops = {"abcdef0123456789": {"name": "other", "ts": 1},
                 "99990000aaaabbbb": {"name": "abcd", "ts": 1}}
        self.assertEqual(rd_common.find_janitor_stop(stops, "abcd")[0], "99990000aaaabbbb")
        self.assertIsNone(rd_common.find_janitor_stop(stops, "abcdef01"))
        self.assertEqual(rd_common.find_janitor_stop(stops, "abcdef012345")[0], "abcdef0123456789")
        self.assertIsNone(rd_common.find_janitor_stop({"abcdef0123456789": {"name": "x"}}, "abcd"))

    def record(self, target, cid, name, idle_h=3, ts=None):
        path = os.path.join(self.state, "janitor.json" if target == "mini" else "laptop_janitor.json")
        with open(path, "w") as f:
            json.dump({"stopped_by_janitor": {cid: {"name": name, "ts": ts or time.time(),
                                                    "idle_h": idle_h}}}, f)
        return path

    def recorded(self, path):
        with open(path) as f:
            return json.load(f).get("stopped_by_janitor", {})

    def test_exec_restarts_janitor_stopped_then_runs_once(self):
        self.scenario(mini={"containers": {"db": self.STOPPED_BEFORE}})
        path = self.record("mini", "iddb", "db")
        p = self.shim("exec", "db", "psql")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("rdocker: restarted db (the janitor stopped it after 3 h idle)", p.stderr)
        self.assertEqual(self.calls("start"), [("mini", ["start", "iddb"])])
        self.assertEqual(self.calls("exec"), [("mini", ["exec", "db", "psql"])])
        verbs = [a[0] for _, a in self.calls() if a[0] in ("start", "exec")]
        self.assertEqual(verbs, ["start", "exec"])                        # start comes first
        self.assertEqual(self.recorded(path), {})

    def test_user_stopped_container_is_never_started(self):
        self.scenario(mini={"containers": {"db": {"Id": "iddb", "running": False}}})
        p = self.shim("exec", "db", "psql")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("start"), [])
        self.assertNotIn("restarted", p.stderr)

    def test_user_stop_clears_the_record(self):
        self.scenario(mini={"containers": {"db": {"Id": "iddb", "running": True}}})
        path = self.record("mini", "iddb", "db")
        self.addCleanup(wait_bg_sync)
        self.assertEqual(self.shim("stop", "db").returncode, 0)
        self.assertEqual(self.recorded(path), {})
        p = self.shim("exec", "db", "psql")
        self.assertEqual(self.calls("start"), [])
        self.assertNotIn("restarted", p.stderr)

    def test_user_rm_clears_the_record(self):
        self.scenario(laptop={"containers": {"vit": {"Id": "idvit", "running": False}}},
                      pins={"containers": ["vit"]})
        path = self.record("local", "idvit", "vit")
        self.assertEqual(self.shim("rm", "vit").returncode, 0)
        self.assertEqual(self.recorded(path), {})

    def test_logs_follow_restarts_plain_logs_does_not(self):
        self.scenario(mini={"containers": {"db": self.STOPPED_BEFORE}})
        path = self.record("mini", "iddb", "db")
        self.shim("logs", "db")
        self.assertEqual(self.calls("start"), [])
        self.assertEqual(len(self.recorded(path)), 1)
        p = self.shim("logs", "-f", "db")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("start"), [("mini", ["start", "iddb"])])

    def test_laptop_record_restarts_on_the_laptop(self):
        self.scenario(laptop={"containers": {"vit": {"Id": "idvit", "running": False,
                                                     "StartedAt": ts(time.time() - 5 * HOUR)}}},
                      pins={"containers": ["vit"]})
        self.record("local", "idvit", "vit", idle_h=3)
        p = self.shim("cp", "vit:/tmp/x", "/tmp/y")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.calls("start"), [("desktop-linux", ["start", "idvit"])])
        self.assertIn("restarted vit", p.stderr)

    def test_already_running_is_not_started(self):
        self.scenario(mini={"containers": {"db": {"Id": "iddb", "running": True}}})
        path = self.record("mini", "iddb", "db")
        self.shim("exec", "db", "true")
        self.assertEqual(self.calls("start"), [])
        self.assertEqual(self.recorded(path), {})


class StatusRow(unittest.TestCase):
    def test_lists_janitor_stops_of_the_last_24h(self):
        paths = (rd_common.JANITOR_PATH, rd_common.LAPTOP_JANITOR_PATH)
        for p in paths:
            if os.path.exists(p):
                os.unlink(p)
        self.addCleanup(lambda: [os.unlink(p) for p in paths if os.path.exists(p)])
        now = time.time()
        rd_common.record_janitor_stops(rd_common.JANITOR_PATH, {
            "id1": {"name": "wlpg", "ts": now - 2 * HOUR, "idle_h": 3},
            "id2": {"name": "ancient", "ts": now - 2 * DAY, "idle_h": 3}}, now=now)
        rd_common.record_janitor_stops(rd_common.LAPTOP_JANITOR_PATH, {
            "id3": {"name": "vit-db", "ts": now - HOUR, "idle_h": 3}}, now=now)
        ok, label, detail = rd_setup.janitor_stopped_row(now)
        self.assertIn("janitor-stopped", label)
        self.assertEqual(detail, "vit-db (laptop, 1h ago), wlpg (mini, 2h ago)")
        for p in paths:
            os.unlink(p)
        self.assertEqual(rd_setup.janitor_stopped_row(now)[2], "none")


if __name__ == "__main__":
    unittest.main()
