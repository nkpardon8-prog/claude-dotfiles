"""Janitor safety tests: run `rdocker.py clean ...` as a subprocess against tests/fake_docker.py.

Same seams as test_shim_safety (temp HOME, fake docker on PATH); `ssh` is a stub that prints
$HOME/ssh.out, which stands in for the mini's VMDISK/HOSTFREE report and grants the mini lock.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import json
import os
import subprocess
import unittest

import rdmods
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

    def clean(self, *argv, rc=0):
        e = rdmods.child_env(self.home, self.bin, FAKE_DOCKER_FIXTURE=self.fixture,
                             FAKE_DOCKER_LOG=self.log)
        p = subprocess.run(["/usr/bin/python3", "-I", RDOCKER, "clean"] + list(argv),
                           capture_output=True, text=True, env=e, timeout=60)
        self.assertEqual(p.returncode, rc, p.stderr)
        return p

    def attention(self):
        try:
            with open(os.path.join(self.state, "attention.json")) as f:
                return {i["key"]: i["msg"] for i in json.load(f)}
        except OSError:
            return {}

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
        # a container whose data volume is keep-labelled is kept whole (compose DBs label the volume)
        self.assertFalse([a for a in d if "iduser" in a], d)
        self.assertIn(["rm", "-v", "idother"], d)

    def test_kept_volume_blocks_idle_stop(self):
        self.mini({"t-db": running("iddb", Mounts=[{"Type": "volume", "Name": "dbdata"}])},
                  volumes={"dbdata": {"Labels": {"rdocker.keep": "1"}}})
        self.ledger({"containers": {"iddb": {"idle_s": 13 * HOUR, "last_sample": NOW - 60}}})
        self.clean("--only", "t-")
        self.assertFalse([a for a in self.destructive() if "iddb" in a], self.destructive())

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

    def test_ttl_label_replaces_idle_rule(self):
        """A quiet DB with rdocker.ttl=2d is not idle-stopped at 3 h; it lives until its TTL."""
        self.mini({"a": running("ida", netio="1kB / 1kB", Labels={"rdocker.ttl": "2d"})})
        self.ledger({"idle": {"ida": {"idle_s": 13 * HOUR, "last_sample": NOW - INTERVAL,
                                      "netio": "1kB / 1kB"}}})
        self.clean()
        self.assertNotIn(["stop", "ida"], self.argvs())
        self.assertNotIn("ida", self.jstate()["idle"])

    def test_idle_past_limit_stops(self):
        self.mini({"a": running("ida", netio="1kB / 1kB")})
        self.ledger({"idle": {"ida": {"idle_s": 12 * HOUR, "last_sample": NOW - INTERVAL,
                                      "netio": "1kB / 1kB"}}})
        self.clean()
        self.assertIn(["stop", "ida"], self.argvs())
        self.assertNotIn("ida", self.jstate()["idle"])

    def test_idle_just_past_3h_default_stops(self):
        self.mini({"a": running("ida", netio="1kB / 1kB")})
        self.ledger({"idle": {"ida": {"idle_s": 3 * HOUR - INTERVAL + 1,
                                      "last_sample": NOW - INTERVAL, "netio": "1kB / 1kB"}}})
        self.clean()
        self.assertIn(["stop", "ida"], self.argvs())

    def test_idle_under_3h_keeps_running(self):
        self.mini({"a": running("ida", netio="1kB / 1kB")})
        self.ledger({"idle": {"ida": {"idle_s": 2 * HOUR, "last_sample": NOW - INTERVAL,
                                      "netio": "1kB / 1kB"}}})
        self.clean()
        self.assertNotIn(["stop", "ida"], self.argvs())

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


class ImageGCByTag(JanitorCase):
    """An image tagged in several repositories cannot be removed by id without -f: the janitor
    removes each tag (the image goes with the last) and treats docker's refusals as skips."""
    OLD = NOW - 30 * DAY

    def test_multi_tag_image_removed_tag_by_tag_without_error(self):
        self.mini({}, images={"sha256:multi": {"RepoTags": ["a/x:1", "b/x:1"]}})
        self.ledger({"image_last_used": {"sha256:multi": self.OLD}})
        self.clean()
        rms = [a[2] for a in self.argvs() if a[:2] == ["image", "rm"]]
        self.assertEqual(rms, ["a/x:1", "b/x:1"])          # never `image rm <id>`, never -f
        st = self.jstate()
        self.assertNotIn("sha256:multi", st["image_last_used"])
        self.assertNotIn("last_error", st)
        self.assertNotIn("janitor-error", self.attention())

    def test_untagged_remainder_removed_by_id(self):
        self.mini({}, images={"sha256:u": {}})
        self.ledger({"image_last_used": {"sha256:u": self.OLD}})
        self.clean()
        self.assertIn(["image", "rm", "sha256:u"], self.argvs())

    def test_docker_refusals_are_skips_not_errors(self):
        for err in ("Error response from daemon: conflict: unable to delete abc (cannot be forced) "
                    "- image has dependent child images",
                    "Error response from daemon: conflict: unable to remove repository reference "
                    "\"a/x:1\" (must force) - container 123 is using its referenced image abc",
                    "Error: image is being used by running container 123"):
            self.setUp()
            self.mini({}, images={"sha256:p": {"RepoTags": ["a/x:1"], "rm_err": err}})
            self.ledger({"image_last_used": {"sha256:p": self.OLD}})
            self.clean()
            st = self.jstate()
            self.assertNotIn("last_error", st, err)
            self.assertIn("sha256:p", st["image_last_used"])   # still there, retried next pass

    def test_real_failure_recorded_then_cleared_by_clean_pass(self):
        self.mini({}, images={"sha256:f": {"RepoTags": ["a/x:1"], "rm_err": "Error: disk on fire"}})
        self.ledger({"image_last_used": {"sha256:f": self.OLD}})
        self.clean()
        self.assertIn("disk on fire", self.jstate()["last_error"]["err"])
        self.assertIn("janitor-error", self.attention())
        self.mini({}, images={})
        self.clean()
        self.assertNotIn("last_error", self.jstate())
        self.assertNotIn("janitor-error", self.attention())

    def test_only_scoped_pass_keeps_last_error(self):
        self.mini({})
        self.ledger({"last_error": {"ts": NOW, "action": "x", "err": "y"}})
        self.clean("--only", "zz-")
        self.assertIn("last_error", self.jstate())


class CleanExitCodes(JanitorCase):
    def test_mini_engine_down_but_ssh_ok_exits_1(self):
        self.mini({}, down=True)          # ssh stub grants the lock; docker on the mini fails
        p = self.clean(rc=1)
        self.assertIn("clean not run: mini docker engine not answering", p.stderr)
        self.assertEqual(p.stdout, "")

    def test_dry_run_with_mini_unreachable_exits_1(self):
        self.mini({}, down=True)
        p = self.clean("--dry-run", rc=1)
        self.assertIn("clean not run", p.stderr)
        self.assertFalse(self.destructive())

    def test_daemon_janitor_pass_skips_quietly_when_engine_down(self):
        self.mini({}, down=True)
        e = rdmods.child_env(self.home, self.bin, FAKE_DOCKER_FIXTURE=self.fixture,
                             FAKE_DOCKER_LOG=self.log)
        p = subprocess.run(["/usr/bin/python3", "-I", RDOCKER, "janitor-run"],
                           capture_output=True, text=True, env=e, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)


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
