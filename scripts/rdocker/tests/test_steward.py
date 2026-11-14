"""share/rd-steward.py: the rules (what counts as a problem) and the hand-off cooldown."""
import importlib.util
import os
import sys
import time
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

    def test_optional_worker_unreachable_is_no_finding(self):
        mbp = {"name": "hp", "os": "mac", "optional": True}
        self.assertEqual(keys(res(reachable=False, err="ssh timeout"), mbp), [])
        self.assertEqual(keys(res(reachable=False, err="ssh timeout"), dict(mbp, optional=False)), ["hp:unreachable"])
        self.assertEqual(keys(res(doctor={"ts": NOW - 10, "disk_free_pct": 3}), mbp), ["hp:disk"])   # up: as before

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
        self.assertEqual(keys(res(outcomes={"rc=0": 30, "lost rc=255": 2, "rc=124": 2})), ["hp:infra"])
        self.assertEqual(keys(res(outcomes={"rc=0": 100, "rc=124": 5})), [])           # 5 % rate
        self.assertEqual(keys(res(outcomes={"rc=0": 2, "rc=124": 3})), [])             # only 3 infra

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
        self.assertEqual(keys(res(outcomes=dict(quiet, **{"lost rc=255": 4, "timeout rc=124": 2}))), ["hp:pool-failing"])
        self.assertEqual(keys(res(outcomes=dict(quiet, **{"rc=0": 30, "rc=137": 4, "timeout rc=124": 2}))), ["hp:infra"])
        for o in ("lost rc=255", "deps-failed", "timeout rc=124", "rc=134", "error rc=70"):
            self.assertTrue(st.INFRA.match(o), o)
        for o in ("lost", "abandoned-setup", "moved", "warm", "rc=1", "interrupted rc=130"):
            self.assertFalse(st.INFRA.match(o), o)

    def test_interrupted_and_test_failures_are_not_infra(self):
        self.assertEqual(keys(res(outcomes={"rc=0": 5, "rc=1": 30, "interrupted": 20})), [])


class PoolFailing(unittest.TestCase):
    """Owner (2026-11-13): "the worst thing is shit failing in the background and no one getting work
    done". A job the pool failed now runs locally (route.log `fallback-local`), so it is silent unless
    the steward counts it: >= 3 in the last hour, or > 20 % of >= 10 runs failed by the pool."""

    def test_worker_runs_log_pool_failures_name_the_top_reason(self):
        r = res(outcomes={"rc=0": 40, "lost rc=255": 2, "error rc=70": 1})
        found = dict(st.rules(r, LINUX))
        self.assertIn("hp:pool-failing", found)
        self.assertIn("hp pool failing (runs.log", found["hp:pool-failing"])
        self.assertIn("top reason: lost rc=255 x2", found["hp:pool-failing"])
        self.assertNotIn("hp:infra", found)              # one finding for one problem
        for o in ("lost rc=255", "error rc=69", "refused rc=69", "error rc=70", "rc=127", "rc=132"):
            self.assertTrue(st.POOL_FAIL.match(o), o)
        for o in ("lost", "rc=1", "refused rc=65", "error rc=71", "timeout rc=124", "abandoned-setup", "rc=1270"):
            self.assertFalse(st.POOL_FAIL.match(o), o)

    def test_worker_two_failures_are_quiet_but_a_high_rate_is_not(self):
        self.assertEqual(keys(res(outcomes={"rc=0": 40, "rc=127": 2})), [])
        # 3 of 12 = 25 % > 20 % over >= 10 runs (busy is infra, not a POOL_FAIL): fires on the rate alone
        self.assertEqual(keys(res(outcomes={"rc=0": 9, "busy": 2, "rc=132": 1})), ["hp:pool-failing"])
        # the same 25 % over only 8 runs: too few (and below the older infra rule's count)
        self.assertEqual(keys(res(outcomes={"rc=0": 6, "busy": 1, "rc=132": 1})), [])
        # left-before-start labels are not runs: they never dilute or inflate the rate
        self.assertEqual(keys(res(outcomes={"rc=0": 9, "busy": 2, "rc=132": 1, "abandoned-setup": 50})),
                         ["hp:pool-failing"])

    def route_line(self, ts, target, rc, extra=""):
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
        return f"{stamp} {target:<5} rrun     npx vitest run rc={rc} 3.1s | /w/repo" + (f"\t{extra}" if extra else "")

    def test_route_log_counts_fallbacks_and_infra_in_the_last_hour(self):
        now = time.time()
        lines = [self.route_line(now - 7200, "fallback-local", "exec", "why=old"),   # > 1 h ago: out
                 self.route_line(now - 60, "hp", "0", "lock_s=0.0"),
                 self.route_line(now - 50, "fallback-local", "exec", "lock_s=0.0 why=every_worker_unreachable"),
                 self.route_line(now - 40, "fallback-local", "exec", "why=every_worker_unreachable"),
                 self.route_line(now - 30, "fallback-local", "exec", "why=lost_hp_mid-run"),
                 self.route_line(now - 20, "none", "73"),
                 self.route_line(now - 10, "local", "exec"),
                 "2026-11-13 10:00:00 laptop rrun-hook something else",
                 "garbage"]
        s = st.route_stats(lines, now - 3600)
        self.assertEqual((s["runs"], s["fallback"], s["infra"]), (6, 3, 1))
        self.assertEqual(st.top_reason(s["reasons"]), "every worker unreachable x2")

    def test_route_rule_fires_on_three_fallbacks_and_names_this_mac(self):
        import tempfile
        from unittest import mock
        home = tempfile.mkdtemp(dir=rdmods.TEST_HOME)
        d = os.path.join(home, ".local", "state", "rdocker")
        os.makedirs(d)
        now = time.time()
        ok = [self.route_line(now - 100 + i, "hp", "0") for i in range(20)]
        two = [self.route_line(now - 50 + i, "fallback-local", "exec", "why=w2_unreachable") for i in range(2)]
        paths = [os.path.join(d, "route.log.1"), os.path.join(d, "route.log")]
        with mock.patch.object(st, "route_log_paths", lambda: paths), mock.patch.object(st, "self_name", lambda: "nick"):
            open(os.path.join(d, "route.log.1"), "w").write("\n".join(ok) + "\n")
            open(os.path.join(d, "route.log"), "w").write("\n".join(two) + "\n")
            s, found = st.route_rules(now)
            self.assertEqual((s["runs"], found), (22, []))                    # 2 of 22: quiet
            with open(os.path.join(d, "route.log"), "a") as f:
                f.write(self.route_line(now - 1, "fallback-local", "exec") + "\n")
            _, found = st.route_rules(now)
        self.assertEqual([k for k, _ in found], ["nick:pool-failing"])
        self.assertIn("nick pool failing (route.log, last hour): 3 fallback(s) to local", found[0][1])
        self.assertIn("top reason: w2 unreachable x2", found[0][1])

    def test_route_log_is_this_macs_rdocker_state(self):
        self.assertEqual([os.path.basename(p) for p in st.route_log_paths()], ["route.log.1", "route.log"])
        self.assertTrue(all(p.startswith(rdmods.TEST_HOME) for p in st.route_log_paths()))  # RDOCKER_HOME, as rd_common

    def test_route_rule_infra_rate_and_no_route_log(self):
        import tempfile
        from unittest import mock
        home = tempfile.mkdtemp(dir=rdmods.TEST_HOME)
        with mock.patch.object(st, "route_log_paths", lambda: [os.path.join(home, "route.log")]):
            self.assertEqual(st.route_rules(), ({"runs": 0, "fallback": 0, "infra": 0, "reasons": {}}, []))
        now = time.time()
        lines = [self.route_line(now - 10, "hp", "0")] * 7 + [self.route_line(now - 10, "none", "75")] * 3
        s = st.route_stats(lines, now - 3600)
        f = st.pool_failing("nick", s["fallback"], s["fallback"] + s["infra"], s["runs"],
                            st.top_reason(s["reasons"]), "route.log")
        self.assertIsNotNone(f)                                               # 3/10 = 30 %
        self.assertIn("top reason: rc=75 never ran (no worker) x3", f[1])


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


class Prediction(unittest.TestCase):
    def test_pred_error_median_ignores_tiny_jobs(self):
        self.assertIsNone(st.pred_error([]))
        self.assertIsNone(st.pred_error([(5, 1.0)]))                       # sub-2 s: noise, ignored
        e = st.pred_error([(10, 10), (12, 10), (30, 10)])                  # 0 %, 20 %, 200 %
        self.assertEqual(e, (20.0, 3))

    def test_drift_flagged_only_with_enough_jobs(self):
        bad = [(30.0, 10.0)] * st.PRED_MIN_N                               # 200 % off
        self.assertIn("hp:pred-drift", keys(res(pred=bad)))
        self.assertNotIn("hp:pred-drift", keys(res(pred=bad[:-1])))        # n below the minimum
        self.assertNotIn("hp:pred-drift", keys(res(pred=[(11.0, 10.0)] * 40)))   # 10 %: fine


class NodeMajor(unittest.TestCase):
    def test_a_different_major_names_the_worker_and_both_majors(self):
        self.assertEqual(st.rules(res(node={25: 40}), LINUX, 25), [])
        found = st.rules(res(node={24: 3, 25: 10}), LINUX, 25)
        self.assertEqual([k for k, _ in found], ["hp:node-mismatch"])
        self.assertIn("hp", found[0][1])
        self.assertIn("node 24 x3", found[0][1])
        self.assertIn("pool_node_major is 25", found[0][1])
        self.assertNotIn("node 25", found[0][1])                           # the matching jobs are not listed

    def test_no_pool_major_or_no_node_data_is_no_finding(self):
        self.assertEqual(keys(res(node={24: 3})), [])                       # fleet declares no pool_node_major
        self.assertEqual(st.rules(res(), LINUX, 25), [])                    # only old lines: no node= field

    def test_pool_node_major_from_fleet(self):
        self.assertEqual(st.pool_node_major({"pool_node_major": 25}), 25)
        for bad in ({}, {"pool_node_major": "25"}, {"pool_node_major": True}, {"pool_node_major": 25.5}):
            self.assertIsNone(st.pool_node_major(bad), bad)

    def test_remote_counts_node_majors_and_ignores_old_and_unknown_lines(self):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        r = answer([line(ts, "25"), line(ts, "25"), line(ts, "24"),
                    line(ts, "-"),                                          # unknown: skipped
                    line(ts, None),                                         # pre-2026-11-12 line: no field
                    line("2000-01-01T00:00:00+0000", "22"),                 # older than 24 h
                    line(ts, "1234")])                                      # not a node major
        self.assertEqual(r["node"], {25: 2, 24: 1})

    def test_argv_text_never_counts_as_a_field(self):
        """A job's argv is free text: `sh -c 'echo node=24'` (and outcome= / pred_s= / cmd_s= in it)
        must not become a NODE / OUT / PRED of its own."""
        ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        tricky = "sh -c echo node=24 outcome=busy pred_s=999 cmd_s=1 outcome=rc=0"
        r = answer([line(ts, "25", argv=tricky, outcome="rc=0", cmd="10.0", pred="11"),
                    line(ts, None, argv="sh -c echo node=24 outcome=busy")])
        self.assertEqual(r["node"], {25: 1})
        self.assertEqual(r["outcomes"], {"rc=0": 2})
        self.assertEqual(r["pred"], [(11.0, 10.0)])


def line(ts, node, argv="npm test", outcome="rc=0", cmd="1.0", pred="-"):
    """One runs.log line in the runner's format (node None = a line from before node=)."""
    tail = "\trun=- owner=- cls=- wait_s=0.0 exit_reason=pass setup=warm pred_s=%s client=- pv=-" % pred
    return ("%s repo=a wt=b sha=c outcome=%s prepare_s=0.1 cmd_s=%s argv=%s" % (ts, outcome, cmd, argv)
            + tail + ("" if node is None else " node=" + node))


def answer(lines):
    """Run the real REMOTE script against a temp HOME holding these runs.log lines -> probe()'s result."""
    import subprocess
    import tempfile
    from unittest import mock
    home = tempfile.mkdtemp(dir=rdmods.TEST_HOME)
    os.makedirs(os.path.join(home, "rr", "log"))
    with open(os.path.join(home, "rr", "log", "runs.log"), "w") as f:
        f.write("".join(l + "\n" for l in lines))
    out = subprocess.run(["sh", "-s"], input=st.REMOTE, capture_output=True, text=True,
                         env=dict(os.environ, HOME=home), timeout=60).stdout
    with mock.patch.object(st.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=out, stderr="")):
        return st.probe({"name": "hp", "alias": "rd-hp"})


class Malformed(unittest.TestCase):
    def test_hostile_numbers_are_unknown_never_a_crash(self):
        r = {"name": "hp", "outcomes": {}}
        st.parse_answer(r, "\n".join([
            "NOW " + "9" * 5000,                                            # int() would raise here
            "DOCTOR " + "[" * 100000 + "]" * 100000,                        # RecursionError, not ValueError
            "NODE " + "9" * 5000 + " 3", "NODE 25 " + "9" * 5000, "NODE 0x19 2", "NODE \u00b2 2",
            "PRED 1e999 5", "PRED 5 " + "9" * 400, "PRED nan 5",
            "OUT " + "9" * 5000 + " outcome=rc=0", "OUT 3 outcome=lost rc=" + "9" * 50,
            "NODE 24 3", "PRED 12 10", "OUT 2 outcome=rc=1"]))
        self.assertEqual(r["now"], 0)
        self.assertIsNone(r["doctor"])
        self.assertEqual(r["node"], {24: 3})
        self.assertEqual(r["pred"], [(12.0, 10.0)])
        self.assertEqual(r["outcomes"], {"rc=1": 2})
        self.assertEqual(st.rules(dict(res(), **{k: r[k] for k in ("node", "pred", "outcomes")}), LINUX, 25)[0][0],
                         "hp:node-mismatch")

    def test_a_doctor_that_is_not_an_object_is_no_doctor(self):
        r = {"name": "hp", "outcomes": {}}
        st.parse_answer(r, "DOCTOR [1, 2]")
        self.assertIsNone(r["doctor"])

    def test_one_workers_failure_never_stops_the_others(self):
        import json
        import tempfile
        from unittest import mock
        d = tempfile.mkdtemp(dir=rdmods.TEST_HOME)
        fleet = os.path.join(d, "fleet.json")
        json.dump({"pool_node_major": 25, "machines": [
            {"name": "bad", "alias": "rd-bad", "roles": ["worker"]},
            {"name": "hp", "alias": "rd-hp", "roles": ["worker"]}]}, open(fleet, "w"))
        seen = []

        def fake_probe(m):
            seen.append(m["name"])
            if m["name"] == "bad":
                raise RuntimeError("boom")
            return res(node={24: 2})
        with mock.patch.multiple(st, FLEET=fleet, STATE=d, AGENT=False, probe=fake_probe,
                                 self_rules=lambda: []):
            st.main()
        self.assertEqual(seen, ["bad", "hp"])
        found = json.load(open(os.path.join(d, "state.json")))["findings"]
        self.assertTrue(any("could not read bad" in f for f in found), found)
        self.assertTrue(any(f.startswith("hp ran jobs on a different node major") for f in found), found)


class Runbook(unittest.TestCase):
    def test_runbook_forbids_destructive_actions(self):
        for must in ("NEVER", "delete volumes", "git push", "passwords", "reboot", "Needs a human"):
            self.assertIn(must, st.RUNBOOK)


if __name__ == "__main__":
    unittest.main()
