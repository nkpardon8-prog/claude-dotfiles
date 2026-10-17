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
            f.write('#!/bin/sh\necho "$*" >> "$HOME/ssh.args"\ncat "$HOME/ssh.out" 2>/dev/null\nexit 0\n')
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

    def test_keep_containers_get_restart_unless_stopped(self):
        # a mini/Colima reboot left every kept DB down (restart=no): the janitor upgrades the policy
        self.mini({"t-keep": running("idkeep", Labels={"rdocker.keep": "1"}),
                   "t-kept2": stopped("idk2", Labels={"rdocker.keep": "1"}, RestartPolicy=""),
                   "t-already": running("idal", Labels={"rdocker.keep": "1"},
                                        RestartPolicy="always"),
                   "t-rm": running("idrm", Labels={"rdocker.keep": "1"}, AutoRemove=True),
                   "t-plain": running("idplain"),
                   "t-off": running("idoff", Labels={"rdocker.keep": "0"})})
        self.clean("--only", "t-")
        ups = [a for a in self.argvs() if a[:1] == ["update"]]
        self.assertEqual(sorted(ups), [["update", "--restart", "unless-stopped", "idk2"],
                                       ["update", "--restart", "unless-stopped", "idkeep"]])
        self.assertEqual(self.destructive(), [])
        with open(os.path.join(self.state, "daemon.log")) as f:
            self.assertIn("restart unless-stopped t-keep", f.read())

    def test_keep_restart_dry_run_changes_nothing(self):
        self.mini({"t-keep": running("idkeep", Labels={"rdocker.keep": "1"})})
        p = self.clean("--only", "t-", "--dry-run")
        self.assertFalse([a for a in self.argvs() if a[:1] == ["update"]])
        self.assertIn("restart unless-stopped t-keep", p.stdout)

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
    def ssh_args(self):
        try:
            with open(os.path.join(self.home, "ssh.args")) as f:
                return f.read().splitlines()
        except OSError:
            return []

    def test_mini_engine_down_but_ssh_ok_exits_1(self):
        # engine down, ssh fine (2026-10-17: the mini disk filled and killed colima): the disk check
        # and the rrun mirror housekeeping still run - they need only ssh + perl - and the
        # container/volume/image steps are reported as not run
        self.mini({}, down=True)          # ssh stub grants the lock; docker on the mini fails
        self.disk(50, free=3)
        p = self.clean(rc=1)
        self.assertIn("container/volume/image steps not run: mini docker engine not answering",
                      p.stderr)
        self.assertIn("mini disk 3GB free", p.stdout)
        self.assertTrue(any("/usr/bin/perl" in a for a in self.ssh_args()), self.ssh_args())
        self.assertFalse(any("colima ssh" in a for a in self.ssh_args()), self.ssh_args())
        self.assertFalse(self.destructive())
        self.assertEqual(self.jstate().get("mini_free_gb"), 3)

    def test_dry_run_with_mini_engine_down_exits_1(self):
        self.mini({}, down=True)
        p = self.clean("--dry-run", rc=1)
        self.assertIn("not run", p.stderr)
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


class RrHousekeeping(unittest.TestCase):
    """~/rr housekeeping: the real perl script runs locally (HOME = a temp dir) against a real bare
    repo + git worktree mirrors, through the rr_housekeeping runner seam (no ssh)."""
    SLUG = "app.0123abcd"
    OLD, FRESH = "a" * 12, "b" * 12

    def setUp(self):
        import shutil
        import tempfile
        self.home = tempfile.mkdtemp(prefix="rdk-rr-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.R = os.path.join(self.home, "rr")
        for d in ("w", "git", "slots"):
            os.makedirs(os.path.join(self.R, d))
        src = os.path.join(self.home, "src")
        self.git("init", "-q", src)
        with open(os.path.join(src, "a"), "w") as f:
            f.write("a\n")
        self.git("-C", src, "add", "a")
        self.git("-C", src, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "a")
        self.bare = os.path.join(self.R, "git", self.SLUG + ".git")
        self.git("init", "-q", "--bare", self.bare)
        for wt in (self.OLD, self.FRESH):
            self.git("-C", src, "push", "-q", self.bare, "HEAD:refs/rrun/" + wt)
            self.git("-C", self.bare, "worktree", "add", "-q", "-f", "--detach",
                     self.mirror(wt), "refs/rrun/" + wt)
        self.age(self.OLD, 8)
        self.age(self.FRESH, 2)
        self.cfg = dict(r.DEFAULTS)

    def git(self, *a):
        subprocess.run(["git"] + list(a), check=True, capture_output=True, env=self.env())

    def env(self):
        return rdmods.child_env(self.home, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")

    def mirror(self, wt):
        return os.path.join(self.R, "w", "%s-%s" % (self.SLUG, wt))

    def age(self, wt, days):
        t = r.time.time() - days * DAY
        with open(os.path.join(self.mirror(wt), ".git")) as f:
            admin = f.read().split("gitdir: ", 1)[1].strip()
        for p in (self.mirror(wt), os.path.join(admin, "index"), os.path.join(admin, "HEAD")):
            os.utime(p, (t, t))

    def runner(self, args, script):
        p = subprocess.run(["/usr/bin/perl", "-"] + args, input=script, capture_output=True,
                           text=True, timeout=60, env=self.env())
        return p.returncode, p.stdout, p.stderr

    def run_hk(self, free=100, dry=False):
        J = r.JanitorRun(self.cfg, dry)
        r.rr_housekeeping(self.cfg, J, free, runner=self.runner)
        return J

    def refs(self):
        out = subprocess.run(["git", "-C", self.bare, "for-each-ref", "--format=%(refname)"],
                             capture_output=True, text=True, check=True).stdout
        return sorted(out.split())

    def hold_slot(self, i, who):
        import fcntl
        p = os.path.join(self.R, "slots", str(i))
        fh = open(p, "a+")
        self.addCleanup(fh.close)
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with open(p + ".who", "w") as f:
            f.write(who)

    def test_unused_7d_mirror_removed_with_its_ref_fresh_one_kept(self):
        open(os.path.join(self.R, "w", ".%s-%s.envlist" % (self.SLUG, self.OLD)), "w").close()
        J = self.run_hk()
        self.assertFalse(os.path.exists(self.mirror(self.OLD)))
        self.assertTrue(os.path.isdir(self.mirror(self.FRESH)))
        self.assertEqual(self.refs(), ["refs/rrun/" + self.FRESH])
        self.assertFalse(os.path.exists(os.path.join(self.R, "w", ".%s-%s.envlist"
                                                     % (self.SLUG, self.OLD))))
        self.assertEqual(os.listdir(os.path.join(self.bare, "worktrees")),
                         [os.path.basename(self.mirror(self.FRESH))])
        self.assertTrue(any(a.startswith("rm rrun mirror %s-%s (unused 7d" % (self.SLUG, self.OLD))
                            for a in J.acts), J.acts)
        self.assertIsNone(J.last_error)

    def test_recent_checkout_counts_as_use(self):
        # the mirror dir itself is old, but the runner's checkout rewrote the admin index today
        with open(os.path.join(self.mirror(self.OLD), ".git")) as f:
            admin = f.read().split("gitdir: ", 1)[1].strip()
        os.utime(os.path.join(admin, "index"), None)
        self.run_hk()
        self.assertTrue(os.path.isdir(self.mirror(self.OLD)))

    def test_dry_run_reports_without_removing(self):
        J = self.run_hk(dry=True)
        self.assertTrue(os.path.isdir(self.mirror(self.OLD)))
        self.assertEqual(len(self.refs()), 2)
        self.assertEqual(sum(a.startswith("rm rrun mirror") for a in J.acts), 1, J.acts)

    def test_low_disk_removes_every_free_mirror(self):
        J = self.run_hk(free=2)          # < host_min_free_gb (8)
        self.assertEqual(os.listdir(os.path.join(self.R, "w")), [])
        self.assertEqual(self.refs(), [])
        self.assertTrue(any("disk low: 2GB free < 8GB" in a for a in J.acts), J.acts)

    def test_locked_slot_protects_that_repos_mirrors_only(self):
        other = os.path.join(self.R, "w", "other.11111111-" + "c" * 12)
        os.makedirs(other)
        t = r.time.time() - 30 * DAY
        os.utime(other, (t, t))
        self.hold_slot(0, "%s %d %d\n" % (self.SLUG, r.time.time(), os.getpid()))
        J = self.run_hk(free=2)
        self.assertTrue(os.path.isdir(self.mirror(self.OLD)))
        self.assertTrue(os.path.isdir(self.mirror(self.FRESH)))
        self.assertFalse(os.path.exists(other))
        self.assertIn("rrun run in progress (%s): its mirrors kept" % self.SLUG, J.acts)

    def test_stale_who_on_a_held_slot_protects_everything(self):
        # the slot is held, but .who is a leftover of a run killed -9 (the new holder has not
        # rewritten it yet): its pid is gone, or it is older than the lock file
        for case in ("dead-pid", "older-than-lock", "no-pid"):
            with self.subTest(case=case):
                dead = subprocess.run(["/bin/sh", "-c", "echo $$"], capture_output=True, text=True).stdout.strip()
                who = {"dead-pid": "other.1 1 %s\n" % dead, "no-pid": "other.1 1\n",
                       "older-than-lock": "other.1 1 %d\n" % os.getpid()}[case]
                import fcntl
                with open(os.path.join(self.R, "slots", "0"), "a+") as fh:
                    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    with open(os.path.join(self.R, "slots", "0.who"), "w") as f:
                        f.write(who)
                    if case == "older-than-lock":
                        t = r.time.time() - 60
                        os.utime(os.path.join(self.R, "slots", "0.who"), (t, t))
                    self.run_hk(free=2)
                self.assertEqual(len(os.listdir(os.path.join(self.R, "w"))), 2, case)

    def test_locked_slot_with_unreadable_owner_protects_everything(self):
        for who in ("garbage", "%s %d %d %s extra\n" % (self.SLUG, 1, os.getpid(), self.OLD),
                    "%s %d %d ../%s\n" % (self.SLUG, 1, os.getpid(), self.OLD)):
            with self.subTest(who=who):
                import fcntl
                with open(os.path.join(self.R, "slots", "0"), "a+") as fh:
                    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    with open(os.path.join(self.R, "slots", "0.who"), "w") as f:
                        f.write(who)
                    self.run_hk(free=2)
                self.assertEqual(len(os.listdir(os.path.join(self.R, "w"))), 2, who)

    def test_held_slot_naming_its_mirror_protects_only_that_mirror(self):
        # 2026-10-17: many worktrees of one repo -> some run always holds a slot; a slug-wide
        # protection meant nothing was ever evicted while the disk filled. A .who that names the
        # mirror (new format: "<slug> <epoch> <pid> <wt12>") protects that mirror alone.
        self.hold_slot(0, "%s %d %d %s\n" % (self.SLUG, r.time.time(), os.getpid(), self.OLD))
        J = self.run_hk(free=2)
        self.assertTrue(os.path.isdir(self.mirror(self.OLD)))
        self.assertFalse(os.path.exists(self.mirror(self.FRESH)))
        self.assertEqual(self.refs(), ["refs/rrun/" + self.OLD])
        self.assertIn("rrun mirror %s-%s in use: kept" % (self.SLUG, self.OLD), J.acts)

    def test_stale_new_format_who_protects_everything(self):
        dead = subprocess.run(["/bin/sh", "-c", "echo $$"], capture_output=True, text=True).stdout.strip()
        self.hold_slot(0, "%s 1 %s %s\n" % (self.SLUG, dead, self.OLD))
        self.run_hk(free=2)
        self.assertEqual(len(os.listdir(os.path.join(self.R, "w"))), 2)

    def test_low_disk_still_spares_a_mirror_used_minutes_ago(self):
        # safety floor: a run between `checkout` and its slot write (or an old runner) has no .who
        # naming it yet; a mirror whose index/HEAD changed < RR_PRESSURE_FLOOR_S ago is never evicted
        self.assertEqual(r.RR_PRESSURE_FLOOR_S, 600)
        self.age(self.FRESH, 2 / 1440.0)            # 2 minutes
        J = self.run_hk(free=2)
        self.assertTrue(os.path.isdir(self.mirror(self.FRESH)))
        self.assertFalse(os.path.exists(self.mirror(self.OLD)))
        self.age(self.FRESH, 11 / 1440.0)           # 11 minutes: past the floor
        self.run_hk(free=2)
        self.assertFalse(os.path.exists(self.mirror(self.FRESH)))

    def test_free_slot_is_taken_and_released(self):
        open(os.path.join(self.R, "slots", "0"), "w").close()
        self.run_hk()
        self.assertFalse(os.path.exists(self.mirror(self.OLD)))
        import fcntl
        with open(os.path.join(self.R, "slots", "0")) as fh:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)    # not left held

    def test_foreign_entries_and_symlinks_untouched(self):
        target = os.path.join(self.home, "precious")
        os.makedirs(target)
        names = ("notamirror", "x-" + "d" * 12 + "-extra", "link-" + "e" * 12)
        for n in names[:2]:
            os.makedirs(os.path.join(self.R, "w", n))
        os.symlink(target, os.path.join(self.R, "w", names[2]))
        t = r.time.time() - 30 * DAY
        for n in names:
            os.utime(os.path.join(self.R, "w", n), (t, t), follow_symlinks=False)
        self.run_hk(free=2)
        self.assertEqual(sorted(os.listdir(os.path.join(self.R, "w"))), sorted(names))
        self.assertTrue(os.path.isdir(target))

    def test_no_rr_tree_and_bad_root(self):
        import shutil
        shutil.rmtree(self.R)
        J = self.run_hk()
        self.assertIsNone(J.last_error)
        self.cfg["rr_root"] = "../etc"
        J = self.run_hk()
        self.assertTrue(any("rr housekeeping skipped" in a for a in J.acts), J.acts)

    def test_unreachable_mini_is_logged_not_an_error(self):
        J = r.JanitorRun(self.cfg, False)
        r.rr_housekeeping(self.cfg, J, 100, runner=lambda a, s: (255, "", "ssh: connect failed"))
        self.assertIsNone(J.last_error)


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
