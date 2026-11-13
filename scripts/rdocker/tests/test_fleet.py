"""rd_fleet: validation, frozen API, ssh block rendering (config.d/rdocker ownership), add-server assembly."""
import copy
import json
import os
import shutil
import tempfile
import types
import unittest
from unittest import mock

import rdmods  # noqa: F401  (hermetic RDOCKER_HOME + stubs)
import rd_common
import rd_fleet
import rd_setup

# A frozen snapshot of the planned fleet (before any machine joined): the live fleet.json changes on
# every `add-server`, so shape tests pin this fixture; test_live_registry_is_valid checks the real one.
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "fleet.json")
with open(FIXTURE) as _f:
    REAL = json.load(_f)


def ns(**kw):
    d = dict(name="hp", ip="100.1.2.3", role="home,worker", user="rd", admin_user="admin", port=22, alias=None,
             speed=None, max_slots=None, heavy_slots=None, no_push=True, dry_run=False)
    d.update(kw)
    return types.SimpleNamespace(**d)


class Fleet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-fleet-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.doc = copy.deepcopy(REAL)
        p = mock.patch.object(rd_common, "FLEET_PATH", FIXTURE)
        p.start()
        self.addCleanup(p.stop)

    def test_live_registry_is_valid(self):
        with open(os.path.join(rd_common.HERE, "fleet.json")) as f:
            self.assertEqual(rd_fleet.problems(json.load(f)), [])

    def test_live_mac_worker_renders_a_working_host_block(self):
        with open(os.path.join(rd_common.HERE, "fleet.json")) as f:
            fl = [rd_fleet.entry(m) for m in json.load(f)["machines"]]
        nick = rd_fleet.get(fl, "nickmbp")
        self.assertEqual((nick["os"], nick["roles"], nick["enabled"], nick["user"]), ("mac", ["worker"], True, "rd"))
        self.assertIn("nickmbp", [m["name"] for m in rd_fleet.workers(fl)])
        text = rd_fleet.render_ssh_blocks(fl, rd_common.merge_cfg({}))
        block = text[text.index("Host rd-nickmbp\n"):].split("\n\n")[0]
        for line in ("HostName 100.125.118.77", "Port 2222", "User rd", "HostKeyAlias rd-nickmbp",
                     "ControlPath ~/.ssh/rr-%C", "IdentityFile ~/.ssh/rdocker_ed25519"):
            self.assertIn("  " + line + "\n", block)

    def test_a_mac_may_be_a_worker_but_never_the_home(self):
        mac = {"name": "mbp", "alias": "rd-mbp", "ip": "100.1.1.9", "port": 2222, "user": "rd", "os": "mac",
               "roles": ["worker"], "max_slots": 8, "heavy_slots": 6, "enabled": True}
        d = copy.deepcopy(self.doc)
        d["machines"].append(mac)
        self.assertEqual(rd_fleet.problems(d), [])
        self.bad(lambda d: d["machines"].append(dict(mac, roles=["home", "worker"])) or
                 [d["machines"][0].update(roles=["worker"])], "home machine must be linux")
        self.bad(lambda d: d["machines"].append(dict(mac, os="windows")), "os must be one of")

    def test_bench_worker_linux_runs_rd_tune_mac_gets_it_piped(self):
        lin = rd_fleet.entry({"name": "hp", "alias": "rd-hp", "os": "linux", "roles": ["worker"], "enabled": True})
        self.assertEqual(rd_fleet.bench_cmd(lin), (["ssh", "-o", "BatchMode=yes", "rd-hp", "/usr/local/bin/rd-tune bench"], None))
        mac = dict(lin, name="mbp", alias="rd-mbp", os="mac")
        cmd, stdin = rd_fleet.bench_cmd(mac)
        self.assertEqual(cmd, ["ssh", "-o", "BatchMode=yes", "rd-mbp", "/bin/bash -s bench"])
        self.assertIn("bench() {", stdin)
        fleet = os.path.join(self.tmp, "fleet.json")
        d = copy.deepcopy(self.doc)
        d["machines"].append({"name": "mbp", "alias": "rd-mbp", "ip": "100.1.1.9", "port": 2222, "user": "rd",
                              "os": "mac", "roles": ["worker"], "max_slots": 8, "heavy_slots": 6, "enabled": True})
        with open(fleet, "w") as f:
            json.dump(d, f)
        seen = []
        with mock.patch.object(rd_common, "run", side_effect=lambda c, timeout=30, input_=None:
                               seen.append((c, input_)) or (0, "2.71\n", "")), \
                mock.patch("sys.stdout") as out:
            self.assertEqual(rd_fleet.bench_worker({"fleet_path": fleet}, "mbp"), 0)
        self.assertEqual(seen[0][0][-1], "/bin/bash -s bench")
        self.assertIn("speed 2.71", "".join(c.args[0] for c in out.write.call_args_list))
        with mock.patch.object(rd_common, "run", return_value=(255, "", "ssh: connect refused")), \
                mock.patch.object(rd_common, "say") as say:
            self.assertEqual(rd_fleet.bench_worker({"fleet_path": fleet}, "mbp"), 1)
        self.assertIn("connect refused", say.call_args[0][0])
        self.assertEqual(rd_fleet.bench_worker({"fleet_path": fleet}, "nick"), 2)     # an agent: not a worker

    def test_shipped_fleet_is_valid_and_matches_the_plan(self):
        self.assertEqual(rd_fleet.problems(REAL), [])
        fl = rd_fleet.load()
        self.assertEqual([m["name"] for m in fl], ["laptop", "hp", "mini-a", "mini-b", "nick", "air"])
        lap = rd_fleet.get(fl, "laptop")
        self.assertEqual((lap["alias"], lap["port"], lap["ip"], lap["wsl"]), ("odwin-docker", 2222, "100.108.78.60", True))
        self.assertEqual(rd_fleet.home(fl)["name"], "laptop")
        self.assertEqual([m["name"] for m in rd_fleet.workers(fl)], ["laptop"])
        self.assertTrue(all(not m["enabled"] for m in fl if m["name"] in ("hp", "mini-a", "mini-b")))
        self.assertEqual({m["name"]: m["roles"] for m in fl if m["name"] in ("nick", "air")},
                         {"nick": ["agent"], "air": ["agent"]})
        for k in ("name", "alias", "ip", "port", "user", "os", "roles", "speed", "max_slots", "heavy_slots",
                  "mem_gb", "enabled", "wsl"):
            self.assertIn(k, lap)
        self.assertEqual(len(rd_fleet.CLIENT_KEYS), 2)

    def bad(self, mutate, needle):
        d = copy.deepcopy(self.doc)
        mutate(d)
        self.assertTrue(any(needle in p for p in rd_fleet.problems(d)), rd_fleet.problems(d))

    def test_validation_rejects(self):
        self.bad(lambda d: d["machines"][1].update(roles=["boss"]), "roles")
        self.bad(lambda d: d["machines"][1].update(name="laptop"), "duplicate name")
        self.bad(lambda d: d["machines"][1].update(alias="odwin-docker"), "duplicate alias")
        self.bad(lambda d: d["machines"][1].update(ip="999.1.1.1"), "not an IPv4")
        self.bad(lambda d: d["machines"][1].update(enabled=True), "needs an ip")
        self.bad(lambda d: d["machines"][1].update(roles=["home", "worker"]), "more than one home")
        self.bad(lambda d: d["machines"][1].update(heavy_slots=9), "heavy_slots")
        self.bad(lambda d: d["machines"][1].update(api_token="x"), "no secrets")
        self.bad(lambda d: d["machines"][1].update(port="22"), "wrong type")
        self.bad(lambda d: d["machines"][1].update(shards="no"), "wrong type")
        self.bad(lambda d: d["machines"][4].update(roles=["agent", "worker"]), "agent cannot")
        self.bad(lambda d: d.update(client_keys=["not a key"]), "client_keys")

    def test_shards_flag_is_an_optional_bool(self):
        d = copy.deepcopy(self.doc)
        d["machines"][1]["shards"] = False
        self.assertEqual(rd_fleet.problems(d), [])
        self.assertIn("shards", rd_fleet.FIELDS)

    def test_optional_flag_is_a_bool(self):
        d = copy.deepcopy(self.doc)
        d["machines"][1]["optional"] = True
        self.assertEqual(rd_fleet.problems(d), [])
        self.bad(lambda d: d["machines"][1].update(optional="yes"), "wrong type")
        self.bad(lambda d: d["machines"][1].update(optional=1), "wrong type")

    def test_wt_lanes_is_an_optional_small_int_default_3(self):
        for bad in (0, 9, "3", True, 2.5):
            self.bad(lambda d, v=bad: d.update(wt_lanes=v), "wt_lanes")
        path = os.path.join(self.tmp, "f.json")
        d = copy.deepcopy(self.doc)
        d["wt_lanes"] = 5
        with open(path, "w") as f:
            json.dump(d, f)
        self.assertEqual(rd_fleet.problems(d), [])
        self.assertEqual(rd_fleet.wt_lanes({"fleet_path": path}), 5)
        self.assertEqual(rd_fleet.wt_lanes({"fleet_path": os.path.join(self.tmp, "nope.json")}), 3)
        with open(os.path.join(rd_common.HERE, "fleet.json")) as f:
            self.assertEqual(json.load(f).get("wt_lanes"), 3)                 # the shipped value, explicit

    def test_load_missing_or_broken_raises(self):
        with self.assertRaises(rd_fleet.FleetError):
            rd_fleet.load({"fleet_path": os.path.join(self.tmp, "nope.json")})

    def test_upsert_moves_home_and_is_pure(self):
        before = copy.deepcopy(self.doc)
        out = rd_fleet.upsert(self.doc, {"name": "hp", "ip": "100.1.2.3", "roles": ["home", "worker"], "enabled": True})
        self.assertEqual(self.doc, before)
        names = {m["name"]: m["roles"] for m in out["machines"]}
        self.assertEqual(names["hp"], ["home", "worker"])
        self.assertEqual(names["laptop"], ["worker"])

    def test_ssh_blocks_own_config_d_rdocker_with_home_alias(self):
        cfg = rd_common.merge_cfg({})
        text = rd_fleet.render_ssh_blocks(rd_fleet.load(), cfg)
        self.assertIn("Host odwin-docker\n  HostName 100.108.78.60\n  Port 2222", text)
        self.assertIn("Host rd-mini-a\n  HostName 100.78.43.6", text)        # disabled but has an ip
        self.assertNotIn("Host rd-hp\n", text)                              # placeholder: no ip
        self.assertNotIn("Host nick", text)                                 # agents are not ssh targets
        mac = text[text.index("Host macmini-docker"):]
        self.assertIn("HostKeyAlias odwin-docker", mac)                     # the home entry's alias
        self.assertIn("ControlPath ~/.ssh/rdocker-%C", mac)
        self.assertEqual(text.count("Host macmini-docker"), 1)
        self.assertIn("ControlPath ~/.ssh/rr-%C", text)

    def test_ssh_blocks_without_home_keeps_cfg_host(self):
        fl = [m for m in rd_fleet.load() if m["name"] != "laptop"]
        cfg = rd_common.merge_cfg({"ssh_hostname": "100.9.9.9", "ssh_port": 22})
        text = rd_fleet.render_ssh_blocks(fl, cfg)
        self.assertIn("HostName 100.9.9.9", text[text.index("Host macmini-docker"):])

    def test_ssh_blocks_backs_up_and_is_idempotent(self):
        path = os.path.join(self.tmp, ".ssh", "config.d", "rdocker")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as f:
            f.write("Host macmini-docker\n  HostName old\n")
        cfg = rd_common.merge_cfg({})
        with mock.patch.object(rd_common, "HOME", self.tmp):
            self.assertTrue(rd_fleet.ssh_blocks(rd_fleet.load(), cfg, path))
            self.assertFalse(rd_fleet.ssh_blocks(rd_fleet.load(), cfg, path))
        bk = os.path.join(self.tmp, ".ssh", "rdocker-backups")
        with open(os.path.join(bk, os.listdir(bk)[0])) as f:
            self.assertEqual(f.read(), "Host macmini-docker\n  HostName old\n")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        with open(path) as f:
            self.assertEqual(f.read().count("Host macmini-docker"), 1)      # the old block did not survive

    def test_bootstrap_and_fleet_share_one_block_writer(self):
        self.assertIn("HostKeyAlias macmini-docker", rd_fleet.host_block("macmini-docker", "1.2.3.4", 22, "rd"))


class AddServer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-addsrv-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.fleet = os.path.join(self.tmp, "fleet.json")
        shutil.copy(FIXTURE, self.fleet)       # frozen: the live registry changes with every add-server
        self.cmds, self.inter = [], []
        patches = [mock.patch.object(rd_common, "FLEET_PATH", self.fleet),
                   mock.patch.object(rd_common, "FLEET_SSH_PATH", os.path.join(self.tmp, "ssh-rdocker")),
                   mock.patch.object(rd_common, "HOME", self.tmp),
                   mock.patch.object(rd_common, "run", self.run_),
                   mock.patch.object(rd_fleet, "interactive", self.interactive),
                   mock.patch.object(rd_common, "update_cfg", lambda fn: fn(rd_common.merge_cfg({})))]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.cfg = rd_common.merge_cfg({})

    def run_(self, cmd, timeout=30, input_=None):
        self.cmds.append(cmd)
        if cmd[0] == "ssh" and cmd[-1].endswith("rd-tune bench"):
            return 0, "0.93\n", ""
        if cmd[0] == "ssh" and "rd-verify" in cmd[-1]:
            return 0, self.verify_out, ""
        if cmd[0] == "ssh" and cmd[-1] == "tailscale status --json":
            return 0, json.dumps({"Self": {"KeyExpiry": self.expiry}}), ""
        return 0, "", ""

    verify_out = "PASS boot-ssh\nSKIP ac-power set BIOS\n"
    expiry = "0001-01-01T00:00:00Z"

    def interactive(self, cmd):
        self.inter.append(cmd)
        return 0

    def test_dry_run_prints_and_changes_nothing(self):
        before = open(self.fleet).read()
        self.assertEqual(rd_fleet.add_server(self.cfg, ns(dry_run=True)), 0)
        self.assertEqual(open(self.fleet).read(), before)
        self.assertEqual((self.cmds, self.inter), ([], []))

    def test_full_flow_command_assembly_and_fleet_result(self):
        with mock.patch.object(rd_fleet, "stage_dir", return_value="/stage/rdocker-provision"):
            rc = rd_fleet.add_server(self.cfg, ns())
        self.assertEqual(rc, 0)
        (prov,) = self.inter
        self.assertEqual(prov[:2], ["ssh", "-t"])
        self.assertIn("admin@100.1.2.3", prov)
        i = prov.index("sudo")
        self.assertEqual(prov[i + 1:i + 3], ["bash", "/tmp/rdocker-provision-hp/provision-linux.sh"])
        tail = prov[i + 3:]
        for a, v in (("--ts-ip", "100.1.2.3"), ("--user", "rd"), ("--port", "22"), ("--max-slots", "4"), ("--heavy-slots", "2")):
            self.assertEqual(tail[tail.index(a) + 1], v)
        self.assertIn("--home", tail)
        self.assertEqual(tail[tail.index("--keys") + 1], "/tmp/rdocker-provision-hp/client_keys")
        scp = next(c for c in self.cmds if c[0] == "scp")
        self.assertEqual(scp[-1], "admin@100.1.2.3:/tmp/rdocker-provision-hp")
        flat = [" ".join(c) for c in self.cmds]
        self.assertTrue(any("ssh-keygen -R rd-hp" == c for c in flat))
        self.assertTrue(any("ssh-keygen -R odwin-docker" == c for c in flat))           # old home
        self.assertTrue(any("ssh-keygen -R macmini-docker" == c for c in flat))
        self.assertTrue(any(c.endswith("rd-tune bench") and "rd-hp" in c for c in flat))
        sec = next(c for c in flat if "reporter.json" in c and "secrets.token_hex" in c)
        self.assertIn("old.get('key') or old.get('secret')", sec.replace("'\"'\"'", "'"))  # never rotates an existing key
        self.assertIn("0o600", sec)
        self.assertTrue(any(c[0] == "git" and "commit" in c for c in self.cmds))
        self.assertFalse(any(c[0] == "git" and "push" in c for c in self.cmds))        # --no-push
        fl = rd_fleet.load()
        hp = rd_fleet.get(fl, "hp")
        self.assertEqual((hp["enabled"], hp["speed"], hp["roles"], hp["ip"]), (True, 0.93, ["home", "worker"], "100.1.2.3"))
        self.assertEqual(rd_fleet.home(fl)["name"], "hp")
        self.assertEqual(rd_fleet.get(fl, "laptop")["roles"], ["worker"])
        self.assertEqual(hp["ts_key_expiry"], "none")
        self.assertTrue(any(c[-1] == "/usr/local/bin/rd-verify --home" for c in self.cmds))
        self.assertTrue(any("systemctl --user restart rd-reporter" in c[-1] for c in self.cmds))
        with open(rd_common.FLEET_SSH_PATH) as f:
            blocks = f.read()
        self.assertIn("Host rd-hp\n  HostName 100.1.2.3", blocks)
        self.assertIn("HostKeyAlias rd-hp", blocks[blocks.index("Host macmini-docker"):])
        self.assertNotIn("secret", open(self.fleet).read().replace("no secrets", ""))

    def test_verify_fail_and_expiring_key_give_rc1_but_stay_enabled(self):
        self.verify_out = "PASS boot-ssh\nFAIL watchdog\n"
        self.expiry = "2027-01-05T10:00:00Z"
        with mock.patch.object(rd_fleet, "stage_dir", return_value="/s"):
            self.assertEqual(rd_fleet.add_server(self.cfg, ns(role="worker")), 1)
        hp = rd_fleet.get(rd_fleet.load(), "hp")
        self.assertEqual((hp["enabled"], hp["ts_key_expiry"]), (True, "2027-01-05"))

    def test_no_verify_output_is_a_failure(self):
        self.verify_out = ""
        with mock.patch.object(rd_fleet, "stage_dir", return_value="/s"):
            self.assertEqual(rd_fleet.add_server(self.cfg, ns(role="worker")), 1)

    def test_parse_verify_and_table(self):
        rows = rd_fleet.parse_verify("junk\nPASS a ok\nFAIL b why not\nSKIP c\n")
        self.assertEqual(rows, [("PASS", "a", "ok"), ("FAIL", "b", "why not"), ("SKIP", "c", "")])
        self.assertIn("FAIL  b", rd_fleet.verify_table(rows))
        self.assertEqual(rd_fleet.parse_key_expiry('{"Self": {"KeyExpiry": null}}'), "none")
        self.assertIsNone(rd_fleet.parse_key_expiry("not json"))

    def test_failed_provision_leaves_fleet_unchanged(self):
        before = open(self.fleet).read()
        with mock.patch.object(rd_fleet, "stage_dir", return_value="/s"), \
                mock.patch.object(rd_fleet, "interactive", return_value=1):
            self.assertEqual(rd_fleet.add_server(self.cfg, ns()), 1)
        self.assertEqual(open(self.fleet).read(), before)

    def test_failed_verify_stays_disabled_and_not_home(self):
        def run_(cmd, timeout=30, input_=None):
            return (255, "", "denied") if cmd[:3] == ["ssh", "-o", "BatchMode=yes"] else (0, "", "")
        with mock.patch.object(rd_fleet, "stage_dir", return_value="/s"), mock.patch.object(rd_common, "run", run_):
            self.assertEqual(rd_fleet.add_server(self.cfg, ns()), 1)
        fl = rd_fleet.load()
        self.assertFalse(rd_fleet.get(fl, "hp")["enabled"])
        self.assertEqual(rd_fleet.home(fl)["name"], "laptop")

    def test_invalid_args_exit_2(self):
        self.assertEqual(rd_fleet.add_server(self.cfg, ns(ip="nope")), 2)
        self.assertEqual(rd_fleet.add_server(self.cfg, ns(role="boss")), 2)

    def test_secret_hint_never_contains_a_secret(self):
        h = rd_fleet.secret_put_hint("mini-a", "rd-mini-a")
        self.assertTrue(h.endswith("| wrangler secret put MACHINE_KEY_MINI_A"))
        self.assertTrue(h.startswith("ssh rd-mini-a "))

    def test_repoint_home_updates_cfg_and_known_hosts(self):
        seen = {}
        with mock.patch.object(rd_common, "update_cfg", lambda fn: seen.update(fn(self.cfg))):
            rd_fleet.repoint_home(self.cfg, {"alias": "rd-hp", "ip": "100.1.2.3", "port": 22, "user": "rd"},
                                  {"alias": "odwin-docker"})
        self.assertEqual((seen["host_ip"], seen["ssh_hostname"], seen["ssh_port"], seen["remote_socket"]),
                         ("100.1.2.3", "100.1.2.3", 22, "/var/run/docker.sock"))
        self.assertIn(["ssh-keygen", "-R", "odwin-docker"], self.cmds)

    def test_sync_fleet_and_status_row(self):
        with mock.patch.object(rd_common, "load_cfg", return_value=self.cfg):
            self.assertEqual(rd_fleet.sync(self.cfg), 0)
        self.assertTrue(os.path.isfile(rd_common.FLEET_SSH_PATH))
        ok, label, detail = rd_setup.fleet_row()
        self.assertTrue(ok)
        self.assertIn("home=laptop", detail)

    def test_cli_registers_subcommands(self):
        a = rd_setup.build_parser().parse_args(["add-server", "hp", "100.1.2.3", "--role", "home,worker", "--dry-run"])
        self.assertEqual((a.cmd, a.name, a.role, a.user, a.dry_run), ("add-server", "hp", "home,worker", "rd", True))
        self.assertEqual(rd_setup.build_parser().parse_args(["sync-fleet", "--pull"]).pull, True)


if __name__ == "__main__":
    unittest.main()
