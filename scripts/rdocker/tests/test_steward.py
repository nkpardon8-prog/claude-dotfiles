"""share/rd-steward.py: the rules (what counts as a problem) and the hand-off cooldown."""
import importlib.util
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402,F401  (hermetic test home before anything else)

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rd_steward", os.path.join(HERE, "..", "share", "rd-steward.py"))
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)

LINUX = {"name": "hp", "os": "linux"}
NOW = 1_800_000_000


def res(**kw):
    r = {"name": "hp", "reachable": True, "now": NOW, "err": "", "outcomes": {},
         "doctor": {"ts": NOW - 10, "drained": False, "drain_since": None, "disk_free_pct": 50, "mem_free_pct": 50}}
    r.update(kw)
    return r


def keys(r, m=LINUX):
    return [k for k, _ in st.rules(r, m)]


class Rules(unittest.TestCase):
    def test_healthy_worker_has_no_findings(self):
        self.assertEqual(keys(res(outcomes={"rc=0": 50, "rc=1": 20, "lost": 1})), [])

    def test_unreachable_is_the_only_finding(self):
        self.assertEqual(keys(res(reachable=False, err="timeout")), ["hp:unreachable"])

    def test_missing_doctor_only_flagged_on_linux(self):
        self.assertEqual(keys(res(doctor=None)), ["hp:no-doctor"])
        self.assertEqual(keys(res(doctor=None), {"name": "hp", "os": "mac"}), [])

    def test_stale_doctor(self):
        r = res()
        r["doctor"]["ts"] = NOW - 600
        self.assertEqual(keys(r), ["hp:doctor-stale"])

    def test_long_drain_disk_and_memory(self):
        r = res()
        r["doctor"].update(drained=True, drain_since=NOW - 3600, disk_free_pct=5, mem_free_pct=3)
        self.assertEqual(keys(r), ["hp:drained", "hp:disk", "hp:mem"])
        r["doctor"]["drain_since"] = NOW - 60
        self.assertNotIn("hp:drained", keys(r))

    def test_infra_rate_needs_both_rate_and_count(self):
        self.assertEqual(keys(res(outcomes={"rc=0": 10, "lost rc=255": 3, "rc=124": 2})), ["hp:infra"])
        self.assertEqual(keys(res(outcomes={"rc=0": 100, "lost rc=255": 5})), [])      # 5 % rate
        self.assertEqual(keys(res(outcomes={"rc=0": 2, "lost rc=255": 3})), [])        # only 3 jobs

    def test_remote_outcome_tokens_keep_the_rc(self):
        import subprocess
        from unittest import mock
        log = "".join("2026-11-11T10:00:00+0000 repo=a wt=b sha=c outcome=%s prepare_s=1 cmd_s=- argv=x\n" % o
                      for o in ("lost rc=255", "lost rc=255", "abandoned-setup", "rc=0", "timeout rc=124"))
        cmd = [x for x in st.REMOTE.splitlines() if "uniq -c" in x][0]
        cmd = "cat | " + cmd.split("|", 2)[2]                # the grep | sort | uniq part, on our sample
        out = subprocess.run(["sh", "-c", cmd], input=log, capture_output=True, text=True).stdout
        fake = mock.Mock(returncode=0, stdout="NOW 1\n" + out, stderr="")
        with mock.patch.object(st.subprocess, "run", return_value=fake):
            r = st.probe({"name": "hp", "alias": "rd-hp"})
        self.assertEqual(r["outcomes"], {"lost rc=255": 2, "abandoned-setup": 1, "rc=0": 1, "timeout rc=124": 1})

    def test_truthful_labels_never_count_against_a_worker(self):
        """2026-11-11: pre-start departures (abandoned-setup / moved / warm, and the bare "lost" older
        runners wrote for them) are not worker faults; a started run lost for good is."""
        quiet = {"rc=0": 5, "abandoned-setup": 20, "moved": 10, "warm": 5, "lost": 20, "interrupted": 3}
        self.assertEqual(keys(res(outcomes=quiet)), [])
        self.assertEqual(keys(res(outcomes=dict(quiet, **{"lost rc=255": 4, "timeout rc=124": 2}))), ["hp:infra"])
        for o in ("lost rc=255", "deps-failed", "timeout rc=124", "rc=134", "error rc=70"):
            self.assertTrue(st.INFRA.match(o), o)
        for o in ("lost", "abandoned-setup", "moved", "warm", "rc=1", "interrupted rc=130"):
            self.assertFalse(st.INFRA.match(o), o)

    def test_interrupted_and_test_failures_are_not_infra(self):
        self.assertEqual(keys(res(outcomes={"rc=0": 5, "rc=1": 30, "interrupted": 20})), [])


class Cooldown(unittest.TestCase):
    def test_first_handoff_immediate_then_doubles_to_a_day(self):
        base = st.COOLDOWN_S
        self.assertEqual(st.cooldown(0), 0)
        self.assertEqual(st.cooldown(1), base)
        self.assertEqual(st.cooldown(2), 2 * base)
        self.assertEqual(st.cooldown(20), 86400)


class Remote(unittest.TestCase):
    def test_hour_cutoff_uses_worker_local_time_like_runs_log(self):
        line = [l for l in st.REMOTE.splitlines() if l.startswith("since=")][0]
        self.assertNotIn("date -u", line)


class Drift(unittest.TestCase):
    def test_outdated_server_script_is_a_finding(self):
        want = st.REPO_SHA["rd-doctor"]
        self.assertEqual(keys(res(sha={"rd-doctor": want})), [])
        self.assertEqual(keys(res(sha={"rd-doctor": "0" * 16})), ["hp:outdated-rd-doctor"])

    def test_self_autopull_rules(self):
        import json, tempfile
        d = tempfile.mkdtemp()
        st.AUTOPULL = os.path.join(d, "a.json")
        self.assertEqual([k for k, _ in st.self_rules(NOW)], ["self:no-autopull"])
        def put(**kw):
            json.dump(dict({"ts": NOW - 60, "behind": 0, "state": "current", "why": ""}, **kw), open(st.AUTOPULL, "w"))
        put()
        self.assertEqual(st.self_rules(NOW), [])
        put(ts=NOW - 3600)
        self.assertEqual([k for k, _ in st.self_rules(NOW)], ["self:autopull-stale"])
        put(state="skipped", behind=3, why="ff blocked")
        self.assertEqual([k for k, _ in st.self_rules(NOW)], ["self:behind"])


class Runbook(unittest.TestCase):
    def test_runbook_forbids_destructive_actions(self):
        for must in ("NEVER", "delete volumes", "git push", "passwords", "reboot", "Needs a human"):
            self.assertIn(must, st.RUNBOOK)


if __name__ == "__main__":
    unittest.main()
