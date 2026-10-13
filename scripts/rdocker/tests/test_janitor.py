"""Janitor safety tests: run `rdocker.py clean ...` as a subprocess against tests/fake_docker.py.

Same seams as test_shim_safety (temp HOME, fake docker on PATH); `ssh` is a stub that prints
$HOME/ssh.out, which stands in for the mini's VMDISK/HOSTFREE report and grants the mini lock.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import json
import os
import subprocess
import unittest

from test_shim_safety import RDOCKER, ShimCase, r

SYSTIME = "2026-10-13T14:00:00.123456789+02:00"
NOW = r.parse_ts(SYSTIME)
HOUR, DAY = 3600, 86400
INTERVAL = 600     # default janitor_interval_min = 10


def ts(epoch):
    return r.time.strftime("%Y-%m-%dT%H:%M:%S.5Z", r.time.gmtime(epoch))


class JanitorCase(ShimCase):
    def setUp(self):
        super().setUp()
        with open(os.path.join(self.bin, "ssh"), "w") as f:
            f.write('#!/bin/sh\ncat "$HOME/ssh.out" 2>/dev/null\nexit 0\n')
        self.disk(50)
        self.jpath = os.path.join(self.state, "janitor.json")

    def disk(self, pct, free=100):
        with open(os.path.join(self.home, "ssh.out"), "w") as f:
            # RDLOCK ok: the same stub answers the mini-lock acquire/heartbeat/release scripts
            f.write("RDLOCK ok\nVMDISK %d%%\nHOSTFREE %d\n" % (pct, free))

    def mini(self, containers=None, **knobs):
        eng = {"containers": containers or {}, "system_time": SYSTIME}
        eng.update(knobs)
        self.scenario(mini=eng, tunnel=False, laptop_up=False)

    def ledger(self, data):
        with open(self.jpath, "w") as f:
            json.dump(data, f)

    def jstate(self):
        with open(self.jpath) as f:
            return json.load(f)

    def clean(self, *argv):
        e = {k: v for k, v in os.environ.items() if not k.startswith("RDOCKER_")}
        e.update(HOME=self.home, PATH=self.bin + ":/usr/bin:/bin",
                 FAKE_DOCKER_FIXTURE=self.fixture, FAKE_DOCKER_LOG=self.log)
        p = subprocess.run(["/usr/bin/python3", "-I", RDOCKER, "clean"] + list(argv),
                           capture_output=True, text=True, env=e, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def argvs(self):
        return [rest for _, rest in self.calls()]

    def destructive(self):
        return [a for a in self.argvs()
                if a[:1] in (["rm"], ["stop"]) or a[:2] in (["volume", "rm"], ["image", "rm"])
                or "prune" in a[:2]]


def stopped(cid, hours_ago=1, **kw):
    return dict(Id=cid, running=False, FinishedAt=ts(NOW - hours_ago * HOUR), **kw)


def running(cid, **kw):
    return dict(Id=cid, running=True, StartedAt=ts(NOW - DAY), **kw)


class KeepProtection(JanitorCase):
    def test_keep_container_and_its_volume_survive_force_critical(self):
        self.mini({"t-keep": stopped("idkeep", Labels={"rdocker.keep": "1"},
                                     Mounts=[{"Type": "volume", "Name": "anon1"}]),
                   "t-junk": stopped("idjunk")},
                  volumes={"anon1": {}})
        self.clean("--only", "t-", "--force-critical")
        d = self.destructive()
        self.assertIn(["rm", "idjunk"], d)
        self.assertFalse([a for a in d if "idkeep" in a], d)
        self.assertFalse([a for a in d if a[:2] == ["volume", "prune"]], d)   # global: skipped
        self.assertFalse([a for a in d if a[:2] == ["container", "prune"]], d)

    def test_kept_volume_blocks_rm_v(self):
        self.mini({"t-user": stopped("iduser", hours_ago=48,
                                     Mounts=[{"Type": "volume", "Name": "data"}]),
                   "t-other": stopped("idother", hours_ago=48,
                                      Mounts=[{"Type": "volume", "Name": "scratch"}])},
                  volumes={"data": {"Labels": {"rdocker.keep": "yes"}}, "scratch": {}})
        self.clean("--only", "t-")
        d = self.destructive()
        self.assertIn(["rm", "iduser"], d)
        self.assertIn(["rm", "-v", "idother"], d)
        self.assertNotIn(["rm", "-v", "iduser"], d)

    def test_keep_value_semantics(self):
        self.assertTrue(r.keep_label({"rdocker.keep": ""}))
        self.assertTrue(r.keep_label({"rdocker.keep": "TRUE"}))
        for off in ("0", "false", "No"):
            self.assertFalse(r.keep_label({"rdocker.keep": off}))
        self.assertFalse(r.keep_label({}))

    def test_critical_disk_never_unfiltered_prune(self):
        self.disk(95)
        self.mini({"keep": stopped("idkeep", Labels={"rdocker.keep": "1"}),
                   "junk": stopped("idjunk")}, images={"sha256:a": {}})
        self.clean()
        argvs = self.argvs()
        prunes = [a for a in argvs if a[:2] == ["volume", "prune"]]
        self.assertTrue(prunes)
        for a in prunes:
            self.assertIn("label!=rdocker.keep", a)
        self.assertFalse([a for a in argvs if a[:2] == ["container", "prune"]])
        self.assertFalse([a for a in argvs if a[:2] == ["image", "prune"] and "-af" in a])
        self.assertIn(["rm", "idjunk"], argvs)
        self.assertFalse([a for a in self.destructive() if "idkeep" in a])


class PartialInspect(JanitorCase):
    IDLE = {"ida": {"idle_s": 50.0, "last_sample": NOW - INTERVAL, "netio": "1kB / 1kB"},
            "idghost": {"idle_s": 70.0, "last_sample": NOW - INTERVAL, "netio": "1kB / 1kB"},
            "idgone": {"idle_s": 90.0, "last_sample": NOW - INTERVAL, "netio": "1kB / 1kB"}}

    def test_partial_keeps_unseen_clocks(self):
        self.mini({"a": running("ida", netio="1kB / 1kB")}, ghosts=["idghost"])
        self.ledger({"idle": self.IDLE})
        self.clean()
        idle = self.jstate()["idle"]
        self.assertEqual(idle["idghost"], self.IDLE["idghost"])
        self.assertEqual(idle["idgone"], self.IDLE["idgone"])
        self.assertEqual(idle["ida"]["idle_s"], 50.0 + INTERVAL)

    def test_full_inspect_drops_unseen(self):
        self.mini({"a": running("ida", netio="1kB / 1kB")})
        self.ledger({"idle": self.IDLE})
        self.clean()
        self.assertEqual(sorted(self.jstate()["idle"]), ["ida"])

    def test_unparsable_skips_container_phase(self):
        self.mini({"a": stopped("ida", hours_ago=100), "b": running("idb")},
                  inspect_garbage=True, images={"sha256:x": {}})
        self.ledger({"idle": self.IDLE, "image_last_used": {"sha256:x": NOW - 100 * DAY}})
        self.clean()
        st = self.jstate()
        self.assertEqual(st["idle"], self.IDLE)
        d = self.destructive()
        self.assertFalse([a for a in d if a[:1] in (["rm"], ["stop"]) or a[:2] == ["image", "rm"]], d)


class IdleClock(JanitorCase):
    def run_with(self, entry, **ctr):
        self.mini({"a": running("ida", **ctr)})
        self.ledger({"idle": {"ida": entry}})
        self.clean()
        return self.jstate()["idle"].get("ida")

    def test_long_gap_capped_at_two_intervals(self):
        e = self.run_with({"idle_s": 100.0, "last_sample": NOW - 9 * HOUR, "netio": "1kB / 1kB"},
                          netio="1kB / 1kB")
        self.assertEqual(e["idle_s"], 100.0 + 2 * INTERVAL)
        self.assertEqual(e["last_sample"], NOW)

    def test_clock_step_back_adds_nothing(self):
        e = self.run_with({"idle_s": 100.0, "last_sample": NOW + HOUR, "netio": "1kB / 1kB"},
                          netio="1kB / 1kB")
        self.assertEqual(e["idle_s"], 100.0)

    def test_netio_change_resets(self):
        e = self.run_with({"idle_s": 5000.0, "last_sample": NOW - INTERVAL, "netio": "1kB / 1kB"},
                          netio="2kB / 1kB")
        self.assertEqual(e["idle_s"], 0)
        self.assertEqual(e["netio"], "2kB / 1kB")

    def test_established_resets(self):
        e = self.run_with({"idle_s": 5000.0, "last_sample": NOW - INTERVAL, "netio": "1kB / 1kB"},
                          netio="1kB / 1kB", established=True)
        self.assertEqual(e["idle_s"], 0)

    def test_idle_past_limit_stops(self):
        self.mini({"a": running("ida", netio="1kB / 1kB")})
        self.ledger({"idle": {"ida": {"idle_s": 12 * HOUR, "last_sample": NOW - INTERVAL,
                                      "netio": "1kB / 1kB"}}})
        self.clean()
        self.assertIn(["stop", "ida"], self.argvs())
        self.assertNotIn("ida", self.jstate()["idle"])

    def test_failed_stop_keeps_clock_and_records_error(self):
        self.mini({"a": running("ida", netio="1kB / 1kB")}, fail=["stop"])
        start = 12 * HOUR + 10
        self.ledger({"idle": {"ida": {"idle_s": start, "last_sample": NOW - INTERVAL,
                                      "netio": "1kB / 1kB"}}})
        self.clean()
        self.assertIn(["stop", "ida"], self.argvs())
        st = self.jstate()
        self.assertGreaterEqual(st["idle"]["ida"]["idle_s"], start)
        self.assertIn("stop", st["last_error"]["action"])
        self.assertIn("boom", st["last_error"]["err"])


class ImageGC(JanitorCase):
    IMAGES = {"sha256:recent": {}, "sha256:old": {}, "sha256:used": {}}

    def setup_images(self):
        self.mini({"t-old": stopped("idold", Image="sha256:used")}, images=self.IMAGES)
        self.ledger({"image_last_used": {"sha256:recent": NOW - DAY, "sha256:old": NOW - 15 * DAY,
                                         "sha256:used": NOW - 100 * DAY}})

    def test_ledger_age_decides(self):
        self.setup_images()
        self.clean()
        imgrm = [a for a in self.argvs() if a[:2] == ["image", "rm"]]
        self.assertEqual(imgrm, [["image", "rm", "sha256:old"]])
        self.assertFalse([a for a in self.argvs() if a[:2] == ["image", "prune"] and "-a" in
                          " ".join(a)])
        ledger = self.jstate()["image_last_used"]
        self.assertNotIn("sha256:old", ledger)
        self.assertEqual(ledger["sha256:used"], NOW)
        self.assertEqual(ledger["sha256:recent"], NOW - DAY)

    def test_first_seen_is_now(self):
        self.mini({}, images={"sha256:new": {}})
        self.clean()
        self.assertEqual(self.jstate()["image_last_used"], {"sha256:new": NOW})
        self.assertFalse([a for a in self.argvs() if a[:2] == ["image", "rm"]])

    def test_disk_high_never_removes_in_use(self):
        self.disk(85)
        self.setup_images()
        self.clean()
        imgrm = [a[2] for a in self.argvs() if a[:2] == ["image", "rm"]]
        self.assertEqual(imgrm, ["sha256:old", "sha256:recent"])   # oldest-use first
        self.assertNotIn(["rm", "idold"], self.argvs())

    def test_kept_image_survives(self):
        self.mini({}, images={"sha256:k": {"Labels": {"rdocker.keep": "1"}}})
        self.ledger({"image_last_used": {"sha256:k": NOW - 90 * DAY}})
        self.clean()
        self.assertFalse([a for a in self.argvs() if a[:2] == ["image", "rm"]])


class Misc(JanitorCase):
    def test_builder_cap_falls_back_to_keep_storage(self):
        self.mini({}, old_buildx=True)
        self.clean()
        caps = [a for a in self.argvs() if a[:2] == ["builder", "prune"] and "5gb" in a]
        self.assertEqual([a[3] for a in caps], ["--max-used-space", "--keep-storage"])
        self.assertNotIn("last_error", self.jstate())

    def test_system_time_offset_parsed(self):
        self.assertEqual(r.parse_ts("2026-10-13T14:00:00+02:00"), r.parse_ts("2026-10-13T12:00:00Z"))
        self.assertEqual(r.parse_ts("garbage"), 0)


class TtlAndTimestamps(unittest.TestCase):
    def test_ttl_and_timestamps(self):
        self.assertEqual(r.parse_ttl("30m"), 1800)
        self.assertEqual(r.parse_ttl("2h"), 7200)
        self.assertEqual(r.parse_ttl("1d"), 86400)
        self.assertEqual(r.parse_ttl("45"), 45)
        self.assertIsNone(r.parse_ttl("soon"))
        self.assertEqual(r.parse_ts("0001-01-01T00:00:00Z"), 0)
        self.assertEqual(r.parse_ts("2026-10-13T00:00:00.123456789Z"), 1791849600.0)


if __name__ == "__main__":
    unittest.main()
