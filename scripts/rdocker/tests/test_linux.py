"""Linux client branches run under patched platform flags on either host OS."""
import contextlib
import io
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import rdmods
from rdmods import MODULES

rd_common, rd_tunnel, rd_daemon, rd_setup = (
    next(m for m in MODULES if m.__name__ == n)
    for n in ("rd_common", "rd_tunnel", "rd_daemon", "rd_setup"))


def env(**kv):
    """In-process environment for one block (the hermetic guard forbids patching via dict())."""
    return mock.patch.object(os, "environ", {**os.environ, **kv})


class LinuxClient(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="rdk-linux-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.flags = mock.patch.multiple(rd_common, IS_LINUX=True, IS_MAC=False)
        self.flags.start()
        self.addCleanup(self.flags.stop)

    def test_local_defaults_rootless_then_system_socket(self):
        runtime = os.path.join(self.home, "run")
        os.makedirs(runtime)
        with env(XDG_RUNTIME_DIR=runtime):
            cfg = rd_common.merge_cfg({})
            self.assertEqual((cfg["local_context"], cfg["local_socket"]),
                             ("default", "/var/run/docker.sock"))
            sock = os.path.join(runtime, "docker.sock")
            open(sock, "w").close()
            self.assertEqual(rd_common.merge_cfg({})["local_socket"], sock)

    def test_systemd_unit_and_calls(self):
        unit = os.path.join(self.home, "rdocker-forwarder.service")
        calls = []

        def run(cmd, **kw):
            calls.append(cmd)
            return 0, "active\n", ""

        with mock.patch.object(rd_common, "SYSTEMD_PATH", unit), mock.patch.object(rd_common, "run", run):
            self.assertTrue(rd_setup.install_daemon())
            self.assertTrue(rd_setup.daemon_loaded())
        with open(unit) as f:
            data = f.read()
        self.assertIn("ExecStart=/usr/bin/python3 -I %s daemon" % rd_common.ENTRY, data)
        self.assertIn("StandardOutput=append:%s" % rd_common.LOG_PATH, data)
        self.assertIn("Restart=always\nRestartSec=5", data)
        self.assertIn("%s/.local/bin" % rd_common.HOME, data)
        self.assertIn("/usr/local/bin:/usr/bin", data)
        self.assertEqual(calls, [["systemctl", "--user", "is-active", rd_common.SYSTEMD_UNIT],
                                 ["systemctl", "--user", "daemon-reload"],
                                 ["systemctl", "--user", "enable", "--now", rd_common.SYSTEMD_UNIT],
                                 ["systemctl", "--user", "restart", rd_common.SYSTEMD_UNIT],
                                 ["systemctl", "--user", "is-active", rd_common.SYSTEMD_UNIT]])

    def test_local_engine_is_never_started_or_stopped(self):
        cfg = rd_common.merge_cfg({})
        cfg["local_autostart"] = True
        with env(RDOCKER_LOCAL_START="1"), \
                mock.patch.object(rd_tunnel, "local_engine_ready", return_value=False), \
                mock.patch.object(rd_common, "run") as run, \
                mock.patch.object(rd_common, "say") as say:
            self.assertFalse(rd_tunnel.local_start_allowed(cfg))
            self.assertFalse(rd_tunnel.ensure_local_running(cfg))
            self.assertIn("sudo systemctl start docker", say.call_args[0][0])
            self.assertFalse(rd_daemon.idle_step(cfg, "mini", {"idle_since": None}, 900, 900))
            run.assert_not_called()

    def test_tailscale_path_and_no_privileged_start(self):
        seen = []
        with mock.patch.object(rd_daemon.shutil, "which", return_value="/stub/tailscale"), \
                mock.patch.object(rd_common, "run", side_effect=lambda cmd, **kw: (seen.append(cmd) or
                    (0, '{"BackendState":"Running"}', ""))):
            self.assertTrue(rd_daemon.tailscale_running())
            self.assertFalse(rd_daemon.tailscale_up())
        self.assertEqual(seen, [["/stub/tailscale", "status", "--json"]])
        with mock.patch.object(rd_daemon.shutil, "which", return_value=None), \
                mock.patch.object(rd_common, "run", side_effect=lambda cmd, **kw: (seen.append(cmd) or
                    (1, "", ""))):
            self.assertFalse(rd_daemon.tailscale_running())
        self.assertEqual(seen[-1][0], "/usr/bin/tailscale")

    def test_real_docker_lookup_and_missing_message(self):
        bin_dir = os.path.join(self.home, "bin")
        os.makedirs(bin_dir)
        docker = os.path.join(bin_dir, "docker")
        with open(docker, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(docker, 0o755)
        with env(PATH=bin_dir), mock.patch.object(rd_common, "BIN_DIR", self.home):
            self.assertEqual(rd_common.real_docker(), docker)
        with env(PATH=self.home), \
                mock.patch.object(rd_common.os.path, "isfile", return_value=False):
            with self.assertRaisesRegex(SystemExit, "sudo apt install docker.io"):
                rd_common.real_docker()

    def test_ssh_bootstrap_preserves_key_block_and_config(self):
        calls = []
        ssh_dir = os.path.join(self.home, ".ssh")
        os.makedirs(ssh_dir)
        config = os.path.join(ssh_dir, "config")
        with open(config, "w") as f:
            f.write("Host old\n  HostName old.example\n")

        def run(cmd, **kw):
            calls.append(cmd)
            key = cmd[-1]
            with open(key, "w") as f:
                f.write("private")
            with open(key + ".pub", "w") as f:
                f.write("ssh-ed25519 YWJj laptop\n")
            return 0, "", ""

        cfg = rd_common.merge_cfg({})
        with mock.patch.object(rd_common, "HOME", self.home), mock.patch.object(rd_common, "run", run):
            pub = rd_setup.ssh_bootstrap(cfg)
            with open(os.path.join(ssh_dir, "config.d", "rdocker")) as f:
                block = f.read()
            with open(config) as f:
                first = f.read()
            self.assertEqual(first.splitlines()[0], "Include ~/.ssh/config.d/*")
            self.assertIn("HostName 100.112.247.23", block)
            self.assertIn("User nicholaspardon", block)
            self.assertIn("HostKeyAlias macmini-docker", block)
            self.assertEqual(os.stat(pub[:-4]).st_mode & 0o777, 0o600)
            with open(config + ".bak-rdocker") as f:
                self.assertEqual(f.read(), "Host old\n  HostName old.example\n")
            with open(os.path.join(ssh_dir, "config.d", "rdocker"), "w") as f:
                f.write("custom block\n")
            rd_setup.ssh_bootstrap(cfg)
            with open(config) as f:
                self.assertEqual(f.read(), first)
            with open(os.path.join(ssh_dir, "config.d", "rdocker")) as f:
                self.assertEqual(f.read(), "custom block\n")
        self.assertEqual(len(calls), 1)

    def test_install_stops_after_unapproved_key(self):
        pub = os.path.join(self.home, "key.pub")
        with open(pub, "w") as f:
            f.write("ssh-ed25519 YWJj laptop\n")
        out = io.StringIO()
        with mock.patch.object(rd_setup, "ssh_bootstrap", return_value=pub), \
                mock.patch.object(rd_common, "run", return_value=(255, "", "omidsmacmini@macminim4: Permission denied (publickey).")), \
                mock.patch.object(rd_common, "real_docker") as docker, \
                contextlib.redirect_stdout(out):
            with self.assertRaises(SystemExit) as e:
                rd_setup.install(rd_common.merge_cfg({}))
        self.assertEqual(e.exception.code, 2)
        self.assertIn("rdocker authorize-client 'ssh-ed25519 YWJj laptop'", out.getvalue())
        docker.assert_not_called()

    def test_authorize_validation_and_idempotent_append(self):
        good = "ssh-ed25519 YWJj laptop"
        self.assertEqual(rd_setup.build_parser().parse_args(["authorize-client", good]).public_key, good)
        for line in (good, "ssh-rsa YWJj", "ecdsa-sha2-nistp256 YWJj comment"):
            self.assertEqual(rd_setup.validate_public_key(line), line)
        for line in ("command=evil " + good, good + "\n" + good, "junk", "ssh-ed25519 !!!"):
            with self.assertRaises(ValueError):
                rd_setup.validate_public_key(line)
        with mock.patch.object(rd_common, "run") as rejected_run, \
                mock.patch.object(rd_common, "say"):
            self.assertEqual(rd_setup.authorize_client({"host": "mini"}, "command=evil " + good), 2)
            rejected_run.assert_not_called()
        calls = []
        ssh_dir = os.path.join(self.home, ".ssh")
        os.makedirs(ssh_dir)
        auth = os.path.join(ssh_dir, "authorized_keys")
        with open(auth, "w") as f:
            f.write("ssh-rsa YWJj old")   # append must separate a last line without a newline

        def run(cmd, **kw):
            calls.append(cmd)
            env = rdmods.child_env(self.home)
            p = subprocess.run(shlex.split(cmd[-1]), input=kw["input_"], capture_output=True,
                               text=True, env=env)
            return p.returncode, p.stdout, p.stderr

        with mock.patch.object(rd_common, "run", run), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(rd_setup.authorize_client({"host": "mini"}, good), 0)
            self.assertEqual(rd_setup.authorize_client({"host": "mini"}, good), 0)
        with open(auth) as f:
            self.assertEqual(f.read(), "ssh-rsa YWJj old\n" + good + "\n")
        self.assertEqual(len(calls), 2)
        self.assertEqual(os.stat(auth).st_mode & 0o777, 0o600)

    def test_status_uses_linux_rows_and_systemctl(self):
        calls = []
        cfg = rd_common.merge_cfg({})

        def run(cmd, **kw):
            calls.append(cmd)
            return 0, "active\n", ""

        out = io.StringIO()
        with mock.patch.object(rd_common, "real_docker", return_value="/stub/docker"), \
                mock.patch.object(rd_common, "run", run), \
                mock.patch.object(rd_daemon, "tailscale_running", return_value=False), \
                mock.patch.object(rd_tunnel, "refresh_health", return_value={"reachable": True, "docker_ok": True,
                    "server_version": "28", "rtt_ms": 5}), \
                mock.patch.object(rd_tunnel, "resolve_target", return_value=("mini", "ok")), \
                mock.patch.object(rd_tunnel, "local_engine_up", return_value=False), \
                contextlib.redirect_stdout(out):
            rd_setup.status(cfg)
        self.assertIn("tailscale on laptop: stopped - run: sudo tailscale up", out.getvalue())
        self.assertIn("background forwarder (systemd user rdocker-forwarder.service)", out.getvalue())
        self.assertIn("local docker engine: stopped (rdocker never starts it)", out.getvalue())
        self.assertFalse(any(c[0] in ("launchctl", "osascript", "open") for c in calls))
        self.assertIn(["systemctl", "--user", "is-active", rd_common.SYSTEMD_UNIT], calls)


if __name__ == "__main__":
    unittest.main()
