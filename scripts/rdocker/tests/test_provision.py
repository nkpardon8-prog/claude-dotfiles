"""server/provision-linux.sh + rd-tune.sh: syntax, shellcheck (when installed), recipe static checks, and
rd-tune's slot cap / prune / bench run for real against fake /proc, hwmon and node (never provisions anything)."""
import os
import shutil
import subprocess
import tempfile
import time
import unittest

import rdmods
from rdmods import STAGE

SERVER = os.path.join(STAGE, "server")
PROV = os.path.join(SERVER, "provision-linux.sh")
TUNE = os.path.join(SERVER, "rd-tune.sh")


def read(p):
    with open(p) as f:
        return f.read()


class Static(unittest.TestCase):
    def test_bash_syntax(self):
        for p in (PROV, TUNE, RESIL, NETCHECK, VERIFY, HARDEN, DOCKER_USER):
            r = subprocess.run(["/bin/bash", "-n", p], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_shellcheck_when_available(self):
        sc = shutil.which("shellcheck", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin")
        if not sc:
            self.skipTest("shellcheck not installed")
        r = subprocess.run([sc, "-S", "warning", PROV, TUNE, RESIL, NETCHECK, VERIFY, HARDEN, DOCKER_USER], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_recipe_is_all_there(self):
        s = read(PROV)
        for needle in ('"ip": "127.0.0.1"', '"containerd-snapshotter": false', '"max-size": "10m"',
                       '"max-file": "3"', '"defaultKeepStorage": "1GB"', "SystemMaxUse=50M", "makestep 0.05 -1",
                       "ListenAddress $TS_IP", "ListenAddress 127.0.0.1", "RequiresMountsFor=/var/lib/docker",
                       "ext4 loop,defaults,nofail", "set-default multi-user.target", "vm.swappiness = 10",
                       "node@25 pnpm@9", "visudo -cf", "start docker", "restart docker", "--vacuum-size=*",
                       "fstrim", "NOPASSWD", "PermitRootLogin no", "ssh.socket", "rd-tune.timer"):
            self.assertIn(needle, s)

    def test_wsl_isolation_cuts_windows_drive_and_interop(self):
        # B8: on the OpenDental laptop C: holds patient data, and interop gives `wsl.exe -u root`.
        s = read(PROV)
        i = s.index('if [ "$IS_WSL" = 1 ]; then\n  say "wsl isolation')
        block = s[i:s.index("\nfi\n", i)]
        for need in ('("automount", "enabled", "false")', '("interop", "enabled", "false")',
                     "umount", "WSLInterop"):
            self.assertIn(need, block)
        self.assertLess(i, s.index("# 1. packages"))

    def test_idempotent_and_non_destructive(self):
        s = read(PROV)
        self.assertIn("set -euo pipefail", s)
        self.assertIn("cmp -s", s)                       # files are rewritten only when different
        self.assertNotRegex(s, r"rm -rf /(\s|$)")
        self.assertLess(s.index("blkid"), s.index("mkfs.ext4"))
        self.assertLess(s.index("# 4. capped Docker data disk"), s.index("# 5. docker-ce"))   # disk before docker
        self.assertNotIn("rm -rf /var/lib/docker", s)    # old data is kept, never deleted

    def test_bad_args_fail_before_touching_anything(self):
        for args in ([], ["--ts-ip", "not-an-ip"], ["--ts-ip", "100.1.2.3", "--user", "Bad User"],
                     ["--ts-ip", "100.1.2.3", "--port", "99999"], ["--ts-ip", "100.1.2.3", "--bogus"]):
            r = subprocess.run(["/bin/bash", PROV, "--dry-run"] + args, capture_output=True, text=True,
                               env=rdmods.child_env(rdmods.TEST_HOME))
            self.assertEqual(r.returncode, 1, args)
            self.assertIn("provision:", r.stderr)


HARDEN = os.path.join(SERVER, "rd-harden.sh")
DOCKER_USER = os.path.join(SERVER, "rd-docker-user.sh")
RESIL = os.path.join(SERVER, "rd-resilience.sh")
NETCHECK = os.path.join(SERVER, "rd-netcheck.sh")
VERIFY = os.path.join(SERVER, "rd-verify.sh")


class Resilience(unittest.TestCase):
    """rd-resilience.sh --root: each generated piece is checked in the file it produces."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-resil-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.root)

    def apply(self, *args, product="OptiPlex 7040", src=SERVER):
        r = subprocess.run(["/bin/bash", RESIL, "--root", self.root, "--src", src, "--codename", "noble"] + list(args),
                           capture_output=True, text=True, timeout=60,
                           env=rdmods.child_env(self.tmp, RD_DMI_PRODUCT=product))
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def f(self, rel):
        return read(os.path.join(self.root, rel.lstrip("/")))

    def test_sleep_masked_and_lid_idle_ignored(self):
        self.apply()
        log = self.f("systemctl.log")
        self.assertIn("systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target", log)
        conf = self.f("/etc/systemd/logind.conf.d/50-rdocker.conf")
        for k in ("HandleLidSwitch=ignore", "IdleAction=ignore", "HandleLidSwitchExternalPower=ignore"):
            self.assertIn(k, conf)

    def test_boot_enable_and_restart_forever(self):
        self.apply()
        self.assertIn("systemctl enable ssh tailscaled docker chrony rd-tune.timer rd-netcheck.timer", self.f("systemctl.log"))
        for u in ("ssh", "tailscaled", "docker", "chrony"):
            d = self.f("/etc/systemd/system/%s.service.d/10-rdocker-restart.conf" % u)
            for k in ("Restart=always", "RestartSec=5", "StartLimitIntervalSec=0"):
                self.assertIn(k, d)
            self.assertLess(d.index("[Unit]"), d.index("StartLimitIntervalSec"))     # StartLimit* belong to [Unit]
            self.assertLess(d.index("StartLimitIntervalSec"), d.index("[Service]"))

    def test_reporter_user_unit_restart_and_enable_when_shipped(self):
        src = os.path.join(self.tmp, "src")
        shutil.copytree(SERVER, src)
        os.makedirs(os.path.join(src, "reporter", "units"))
        with open(os.path.join(src, "reporter", "units", "rd-reporter.service"), "w") as f:
            f.write("[Service]\nExecStart=/bin/true\n")
        with open(os.path.join(src, "reporter", "rd-reporter.mjs"), "w") as f:
            f.write("// reporter\n")
        self.apply(src=src)
        self.assertEqual(self.f("/home/rd/.local/share/rdocker/reporter/rd-reporter.mjs"), "// reporter\n")  # the unit's ExecStart
        d = self.f("/home/rd/.config/systemd/user/rd-reporter.service.d/10-rdocker-restart.conf")
        self.assertIn("Restart=always", d)
        self.assertIn("systemctl --user enable rd-reporter.service", self.f("systemctl.log"))
        w = os.path.join(self.root, "home/rd/.config/systemd/user/default.target.wants/rd-reporter.service")
        self.assertEqual(os.readlink(w), "../rd-reporter.service")   # enabled offline too, no running manager needed

    def test_power_sampler_installed_and_enabled_not_on_wsl(self):
        self.apply()
        self.assertIn("ExecStart=/usr/local/bin/rd-power", self.f("/etc/systemd/system/rd-power.service"))
        self.assertTrue(os.access(os.path.join(self.root, "usr/local/bin/rd-power"), os.X_OK))
        self.assertIn("enable rd-power.service", self.f("systemctl.log"))

    def test_power_sampler_publishes_coarse_watts(self):
        d = tempfile.mkdtemp()
        cap = os.path.join(d, "rapl"); os.makedirs(cap)
        with open(os.path.join(cap, "max_energy_range_uj"), "w") as f: f.write("262143328850\n")
        with open(os.path.join(cap, "energy_uj"), "w") as f: f.write("1000000\n")
        out = os.path.join(d, "run", "power")
        env = rdmods.child_env(rdmods.TEST_HOME, RD_POWERCAP=cap, RD_POWER_OUT=out, RD_POWER_INTERVAL="1", RD_POWER_ONCE="1")
        p = subprocess.Popen(["/bin/bash", os.path.join(SERVER, "rd-power.sh")], env=env)
        time.sleep(0.3)
        with open(os.path.join(cap, "energy_uj"), "w") as f: f.write("31000000\n")   # +30 J
        self.assertEqual(p.wait(timeout=10), 0)
        w, ts = open(out).read().split()
        self.assertTrue(15 <= float(w) <= 40, w)                                   # ~30 J over ~1 s
        self.assertLess(abs(int(ts) - time.time()), 5)
        self.assertEqual(oct(os.stat(out).st_mode & 0o777), "0o644")
        shutil.rmtree(d)

    def test_archive_timer_only_on_home(self):
        self.apply()
        self.assertFalse(os.path.exists(os.path.join(self.root, "etc/systemd/system/rd-archive.timer")))
        shutil.rmtree(self.root); os.makedirs(self.root)
        self.apply("--home")
        self.assertIn("OnCalendar=*-*-* 00:20:00 UTC", self.f("/etc/systemd/system/rd-archive.timer"))
        self.assertIn("User=rd", self.f("/etc/systemd/system/rd-archive.service"))
        self.assertIn("enable rd-archive.timer", self.f("systemctl.log"))

    def test_archive_fetches_missing_days_and_skips_saved_ones(self):
        d = tempfile.mkdtemp()
        cfg = os.path.join(d, "cfg"); os.makedirs(cfg)
        with open(os.path.join(cfg, "archive-token"), "w") as f: f.write("tok\n")
        with open(os.path.join(cfg, "reporter.json"), "w") as f: f.write('{"url": "wss://fleet.example.dev/ingest"}')
        calls = os.path.join(d, "calls")
        fake = os.path.join(d, "curl")
        with open(fake, "w") as f:
            f.write('#!/bin/sh\nfor a; do last=$a; done\necho "$last" >> %s\nprintf \'{"day":"x","buckets":[{"ts":1}]}\'\n' % calls)
        os.chmod(fake, 0o755)
        out = os.path.join(d, "arch")
        env = rdmods.child_env(rdmods.TEST_HOME, RD_ARCHIVE_CFG=cfg, RD_ARCHIVE_DIR=out, RD_ARCHIVE_CURL=fake, RD_ARCHIVE_DAYS="3")
        script = os.path.join(SERVER, "rd-archive.sh")
        r = subprocess.run(["/bin/bash", script], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        urls = open(calls).read().split()
        self.assertEqual(len(urls), 3)
        self.assertTrue(all(u.startswith("https://fleet.example.dev/api/archive?day=") for u in urls), urls)
        files = [os.path.join(dp, n) for dp, _, ns in os.walk(out) for n in ns]
        self.assertEqual(len(files), 3)
        self.assertTrue(all(f.endswith(".json.gz") for f in files))
        subprocess.run(["/bin/bash", script], env=env, capture_output=True, timeout=30)   # second run: all saved
        self.assertEqual(len(open(calls).read().split()), 3)
        # an empty day (pruned before it was fetched) is retried, not frozen
        import gzip
        with gzip.open(files[0], "wt") as g: g.write('{"day":"x","buckets":[]}')
        subprocess.run(["/bin/bash", script], env=env, capture_output=True, timeout=30)
        self.assertEqual(len(open(calls).read().split()), 4)
        shutil.rmtree(d)

    def test_archive_without_token_is_a_quiet_noop(self):
        d = tempfile.mkdtemp()
        env = rdmods.child_env(rdmods.TEST_HOME, RD_ARCHIVE_CFG=d, RD_ARCHIVE_DIR=os.path.join(d, "a"))
        r = subprocess.run(["/bin/bash", os.path.join(SERVER, "rd-archive.sh")], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        self.assertIn("no ", r.stdout)
        shutil.rmtree(d)

    def test_power_sampler_exits_quietly_without_rapl(self):
        env = rdmods.child_env(rdmods.TEST_HOME, RD_POWERCAP="/nonexistent/rapl")
        r = subprocess.run(["/bin/bash", os.path.join(SERVER, "rd-power.sh")], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0)
        self.assertIn("no RAPL", r.stdout)

    def test_watchdog_and_panic(self):
        self.apply()
        w = self.f("/etc/systemd/system.conf.d/50-rdocker-watchdog.conf")
        self.assertIn("RuntimeWatchdogSec=30s", w)
        self.assertIn("RebootWatchdogSec=2min", w)
        p = self.f("/etc/sysctl.d/91-rdocker-panic.conf")
        self.assertIn("kernel.panic = 10", p)
        self.assertIn("kernel.panic_on_oops = 1", p)

    def test_macmini_gets_setpci_unit_other_hardware_gets_a_note(self):
        out = self.apply(product="Macmini5,1")
        u = self.f("/etc/systemd/system/rd-ac-poweron.service")
        self.assertIn("ExecStart=/usr/bin/setpci -s 00:1f.0 0xa4.b=0:1", u)
        self.assertIn("Type=oneshot", u)
        self.assertIn("enable rd-ac-poweron.service", self.f("systemctl.log"))
        self.assertNotIn("After Power Loss", out)
        shutil.rmtree(self.root)
        os.makedirs(self.root)
        out = self.apply(product="HP ProDesk 600 G2 SFF")
        self.assertFalse(os.path.exists(os.path.join(self.root, "etc/systemd/system/rd-ac-poweron.service")))
        self.assertIn("After Power Loss = On", out)
        self.assertIn("F10 -> Advanced -> Power-On Options", out)

    def test_macmini_2012_gets_setpci_unit_too(self):
        self.apply(product="Macmini6,1")
        u = self.f("/etc/systemd/system/rd-ac-poweron.service")
        self.assertIn("ExecStart=/usr/bin/setpci -s 00:1f.0 0xa4.b=0:1", u)
        self.assertIn("enable rd-ac-poweron.service", self.f("systemctl.log"))

    def test_unattended_security_only_with_0430_reboot(self):
        self.apply()
        u = self.f("/etc/apt/apt.conf.d/52rdocker-unattended")
        self.assertIn("#clear Unattended-Upgrade::Allowed-Origins;", u)
        self.assertIn('"Ubuntu:noble-security"', u)
        self.assertNotIn("-updates", u)
        self.assertIn('Automatic-Reboot "true"', u)
        self.assertIn('Automatic-Reboot-Time "04:30"', u)
        self.assertIn('Unattended-Upgrade "1"', self.f("/etc/apt/apt.conf.d/20auto-upgrades"))

    def test_debian_origin(self):
        self.apply("--distro", "debian", "--codename", "bookworm")
        self.assertIn("codename=bookworm-security", self.f("/etc/apt/apt.conf.d/52rdocker-unattended"))

    def test_wsl_skips_hardware_pieces(self):
        self.apply("--wsl", "1")
        for rel in ("etc/systemd/system.conf.d/50-rdocker-watchdog.conf", "etc/sysctl.d/91-rdocker-panic.conf",
                    "etc/apt/apt.conf.d/52rdocker-unattended", "etc/systemd/system/rd-power.service"):
            self.assertFalse(os.path.exists(os.path.join(self.root, rel)), rel)
        self.assertIn("mask sleep.target", self.f("systemctl.log"))      # sleep is still masked

    def test_idempotent(self):
        self.apply()
        snap = {os.path.join(d, n): read(os.path.join(d, n)) for d, _, ns_ in os.walk(self.root) for n in ns_
                if n != "systemctl.log" and not os.path.islink(os.path.join(d, n))}
        self.apply()
        again = {k: read(k) for k in snap}
        self.assertEqual(snap, again)

    def test_docker_live_restore_only_on_home(self):
        s = read(PROV)
        self.assertIn('"live-restore": true', s)
        self.assertIn('[ "$IS_HOME" = 1 ] && LIVE_RESTORE', s)
        self.assertIn("rd-resilience.sh", s)
        self.assertIn("/usr/local/bin/rd-verify", s)


KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMfsnnvUSjDFvrdiCqyxmCSA6eS7V5W+PMm162+cmLKW test@x"


class Harden(unittest.TestCase):
    """rd-harden.sh --root: sshd lock-down (with lock-out guard + rollback), ufw, docker socket, services, secret."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-hard-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = os.path.join(self.tmp, "root")
        self.keys = os.path.join(self.tmp, "keys")
        with open(self.keys, "w") as f:
            f.write(KEY + "\n")

    def authorize(self, user, key=KEY):
        d = os.path.join(self.root, "home", user, ".ssh")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "authorized_keys"), "w") as f:
            f.write(key + "\n")

    def harden(self, *args, rc=0, **env):
        r = subprocess.run(["/bin/bash", HARDEN, "--root", self.root, "--keys", self.keys, "--user", "rd",
                            "--admin-user", "omid"] + list(args), capture_output=True, text=True, timeout=60,
                           env=rdmods.child_env(self.tmp, **env))
        self.assertEqual(r.returncode, rc, r.stderr)
        return r

    def f(self, rel):
        return read(os.path.join(self.root, rel))

    CONF = "etc/ssh/sshd_config.d/05-rdocker-hardening.conf"

    def test_sshd_global_key_only(self):
        self.authorize("rd")
        self.authorize("omid")
        self.harden()
        c = self.f(self.CONF)
        for line in ("PasswordAuthentication no", "KbdInteractiveAuthentication no", "PermitRootLogin no",
                     "AuthenticationMethods publickey", "MaxAuthTries 3", "LoginGraceTime 20", "X11Forwarding no",
                     "AllowAgentForwarding no", "AllowUsers rd omid"):
            self.assertIn(line + "\n", c)
        self.assertNotIn("Match", c)                           # global, not just `Match User rd`
        self.assertIn("systemctl reload ssh", self.f("cmds.log"))

    def test_no_lockout_when_admin_has_no_client_key(self):
        self.authorize("rd")
        self.authorize("omid", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKey0000000 other")
        r = self.harden()
        self.assertFalse(os.path.exists(os.path.join(self.root, self.CONF)))
        self.assertIn("lock us out", r.stderr.replace("would lock us out", "lock us out"))
        self.assertNotIn("systemctl reload ssh", self.f("cmds.log"))

    def test_sshd_t_failure_rolls_back_and_never_reloads(self):
        self.authorize("rd")
        self.authorize("omid")
        bad = os.path.join(self.tmp, "sshd-bad")
        with open(bad, "w") as f:
            f.write("#!/bin/sh\nexit 1\n")
        os.chmod(bad, 0o755)
        r = self.harden(rc=1, RD_SSHD=bad)
        self.assertIn("rolled back", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.root, self.CONF)))
        self.assertNotIn("reload ssh", self.f("cmds.log") if os.path.exists(os.path.join(self.root, "cmds.log")) else "")
        # a previous good config comes back
        os.makedirs(os.path.dirname(os.path.join(self.root, self.CONF)), exist_ok=True)
        with open(os.path.join(self.root, self.CONF), "w") as f:
            f.write("PasswordAuthentication no\n")
        self.harden(rc=1, RD_SSHD=bad)
        self.assertEqual(self.f(self.CONF), "PasswordAuthentication no\n")

    def test_idempotent_reloads_once(self):
        self.authorize("rd")
        self.authorize("omid")
        self.harden()
        self.harden()
        self.assertEqual(self.f("cmds.log").count("systemctl reload ssh"), 1)

    def test_ufw_rules(self):
        self.authorize("rd")
        self.authorize("omid")
        self.harden("--port", "2222")
        cmds = self.f("cmds.log").splitlines()
        want = ["ufw default deny incoming", "ufw default allow outgoing",
                "ufw allow in on tailscale0 to any port 2222 proto tcp",
                "ufw allow in on tailscale0 to any port 22 proto tcp", "ufw allow 41641/udp", "ufw --force enable"]
        idx = [cmds.index(w) for w in want]
        self.assertEqual(idx, sorted(idx))
        self.assertEqual([c for c in cmds if c.startswith("ufw allow") and "tailscale0" not in c], ["ufw allow 41641/udp"])

    def test_wsl_skips_ufw_only(self):
        self.authorize("rd")
        self.authorize("omid")
        r = self.harden("--wsl", "1")
        self.assertNotIn("ufw", self.f("cmds.log"))
        self.assertIn("Hyper-V", r.stdout)
        self.assertIn("gpasswd -M rd docker", self.f("cmds.log"))

    def test_docker_socket_group_and_dropin(self):
        self.harden()
        self.assertIn("gpasswd -M rd docker", self.f("cmds.log"))
        d = self.f("etc/systemd/system/docker.socket.d/10-rdocker.conf")
        self.assertIn("SocketMode=0660", d)
        self.assertIn("SocketGroup=docker", d)

    def test_unneeded_services_disabled(self):
        self.harden()
        log = self.f("cmds.log")
        for u in ("avahi-daemon.socket", "avahi-daemon.service", "cups.service", "cups-browsed.service", "rpcbind.service", "rpcbind.socket"):
            self.assertIn("systemctl disable --now " + u, log)

    def test_reporter_secret_gets_0600(self):
        p = os.path.join(self.root, "home", "rd", ".config", "rdocker")
        os.makedirs(p)
        with open(os.path.join(p, "reporter.json"), "w") as f:
            f.write("{}")
        os.chmod(os.path.join(p, "reporter.json"), 0o644)
        self.harden()
        self.assertEqual(os.stat(os.path.join(p, "reporter.json")).st_mode & 0o777, 0o600)

    def test_docker_user_chain_order_and_rebuild(self):
        log = os.path.join(self.tmp, "ipt.log")
        ipt = os.path.join(self.tmp, "iptables")
        with open(ipt, "w") as f:
            f.write('#!/bin/sh\necho "$*" >> "%s"\n' % log)
        os.chmod(ipt, 0o755)
        for _ in range(2):
            subprocess.run(["/bin/bash", DOCKER_USER], check=True, env=rdmods.child_env(self.tmp, RD_IPTABLES=ipt))
        rules = read(log).splitlines()
        one = rules[:len(rules) // 2]
        self.assertEqual(rules, one * 2)                                   # same result every run
        self.assertEqual(one[1], "-F DOCKER-USER")
        self.assertIn("-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN", one)
        for i in ("lo", "tailscale0", "docker+", "br-+"):
            self.assertIn("-A DOCKER-USER -i %s -j RETURN" % i, one)
        self.assertEqual(one[-1], "-A DOCKER-USER -j DROP")                # DROP last: LAN/physical never gets in
        self.assertIn("ExecStart=/usr/local/bin/rd-docker-user", read(os.path.join(SERVER, "rd-docker-user.service")))

    def test_provision_wires_harden_after_keys_and_never_enables_tcp_docker(self):
        s = read(PROV)
        self.assertLess(s.index("authorize_keys \"$RD_USER\""), s.index("rd-harden.sh"))
        self.assertIn('authorize_keys "$ADMIN_USER"', s)
        self.assertIn("$SSHD -T", s)
        self.assertIn('"ip": "127.0.0.1"', s)
        self.assertNotIn("tcp://", s)


class VerifyLockdown(unittest.TestCase):
    """rd-verify's lock-down rows, fed fixtures through its test hooks."""

    GOOD_SSHD = ("passwordauthentication no\nkbdinteractiveauthentication no\npermitrootlogin no\n"
                 "authenticationmethods publickey\nmaxauthtries 3\nlogingracetime 20\nx11forwarding no\n"
                 "allowagentforwarding no\nallowusers rd omid\n")
    GOOD_UFW = ("Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n\n"
                "To                         Action      From\n22/tcp on tailscale0         ALLOW IN    Anywhere\n"
                "41641/udp                  ALLOW IN    Anywhere\n")
    GOOD_SS = ("tcp LISTEN 0 128 127.0.0.1:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))\n"
               "tcp LISTEN 0 128 100.64.1.2:2222 0.0.0.0:* users:((\"sshd\",pid=1,fd=4))\n"
               "udp UNCONN 0 0 0.0.0.0:41641 0.0.0.0:* users:((\"tailscaled\",pid=2,fd=9))\n"
               "tcp LISTEN 0 4096 [::1]:631 [::]:*\n")

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-vl-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def verify(self, **files):
        env = {}
        for name, text in files.items():
            p = os.path.join(self.tmp, name)
            with open(p, "w") as f:
                f.write(text)
            env[{"sshd": "RD_SSHD_T_FILE", "ufw": "RD_UFW_FILE", "ss": "RD_SS_FILE", "rs": "RD_REPORTER_FILE"}[name]] = p
        r = subprocess.run(["/bin/bash", VERIFY], capture_output=True, text=True, timeout=60,
                           env=rdmods.child_env(self.tmp, **env))
        return {ln.split()[1]: ln.split()[0] for ln in r.stdout.splitlines() if ln.strip()}

    def test_good_sshd_ufw_and_listeners_pass(self):
        out = self.verify(sshd=self.GOOD_SSHD, ufw=self.GOOD_UFW, ss=self.GOOD_SS)
        for k in ("ssh-key-only", "ssh-allowusers", "ufw-active", "ufw-default-deny", "ufw-tailscale-udp",
                  "ufw-only-tailscale", "no-exposed-listeners"):
            self.assertEqual(out[k], "PASS", k)

    def test_password_auth_possible_fails(self):
        out = self.verify(sshd=self.GOOD_SSHD.replace("passwordauthentication no", "passwordauthentication yes"))
        self.assertEqual(out["ssh-key-only"], "FAIL")
        self.assertEqual(self.verify(sshd=self.GOOD_SSHD.replace("rd omid", "omid"))["ssh-allowusers"], "FAIL")

    def test_ufw_inactive_or_open_rule_fails(self):
        self.assertEqual(self.verify(ufw="Status: inactive\n")["ufw-active"], "FAIL")
        lan = self.GOOD_UFW + "22/tcp                     ALLOW IN    192.168.1.0/24\n"
        self.assertEqual(self.verify(ufw=lan)["ufw-only-tailscale"], "FAIL")

    def test_exposed_listener_fails(self):
        out = self.verify(ss=self.GOOD_SS + "tcp LISTEN 0 128 0.0.0.0:631 0.0.0.0:* users:((\"cupsd\",pid=5,fd=6))\n")
        self.assertEqual(out["no-exposed-listeners"], "FAIL")
        out = self.verify(ss=self.GOOD_SS + "tcp LISTEN 0 128 *:5353 *:*\n")
        self.assertEqual(out["no-exposed-listeners"], "FAIL")

    def test_reporter_secret_perms_checked(self):
        self.assertEqual(self.verify(rs="x")["reporter-secret-0600"], "FAIL")    # missing owner/mode on this box

    def test_every_lockdown_piece_has_a_row(self):
        s = read(VERIFY)
        for name in ("ssh-key-only", "ssh-allowusers", "ufw-active", "ufw-default-deny", "ufw-only-tailscale",
                     "docker-user-chain", "docker-no-tcp", "docker-socket-660", "docker-group-only-rd", "services-off",
                     "no-exposed-listeners", "reporter-secret-0600", "unattended-timer"):
            self.assertIn(name, s)


class Netcheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-net-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.state = os.path.join(self.tmp, "count")
        self.log = os.path.join(self.tmp, "calls")
        self.stub("logger", "exit 0")
        self.stub("systemctl", 'echo "systemctl $*" >> "%s"' % self.log)

    def stub(self, name, body):
        p = os.path.join(self.bin, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\n" + body + "\n")
        os.chmod(p, 0o755)

    def run_check(self, ts_ok):
        self.stub("tailscale", "exit %d" % (0 if ts_ok else 1))
        self.stub("timeout", 'shift; exec "$@"')
        return subprocess.run(["/bin/bash", NETCHECK], capture_output=True, text=True, timeout=30,
                              env=rdmods.child_env(self.tmp, self.bin, RD_NETCHECK_STATE=self.state)).returncode

    def restarts(self):
        return read(self.log).count("restart tailscaled") if os.path.exists(self.log) else 0

    def test_restarts_only_after_three_failures_in_a_row(self):
        for _ in range(2):
            self.assertEqual(self.run_check(False), 0)
        self.assertEqual(self.restarts(), 0)
        self.run_check(False)
        self.assertEqual(self.restarts(), 1)
        self.assertEqual(read(self.state).strip(), "0")          # counter resets after the restart

    def test_a_success_resets_the_streak(self):
        self.run_check(False)
        self.run_check(False)
        self.run_check(True)
        self.run_check(False)
        self.run_check(False)
        self.assertEqual(self.restarts(), 0)

    def test_units_run_every_2_min(self):
        t = read(os.path.join(SERVER, "rd-netcheck.timer"))
        self.assertIn("OnUnitActiveSec=2min", t)
        self.assertIn("ExecStart=/usr/local/bin/rd-netcheck", read(os.path.join(SERVER, "rd-netcheck.service")))


class Verify(unittest.TestCase):
    def test_every_resilience_piece_has_a_check(self):
        s = read(VERIFY)
        for name in ("mask-$t", "logind-ignore-lid-idle", "boot-$u", "restart-$u", "timer-$t", "watchdog",
                     "panic-sysctl", "ac-power", "unattended-upgrades", "tailscale-auto-update", "docker-live-restore",
                     "reporter-boot", "power-sampler", "archive-timer"):
            self.assertIn(name, s)

    def test_prints_only_status_lines_and_fails_loudly_without_systemd(self):
        r = subprocess.run(["/bin/bash", VERIFY], capture_output=True, text=True, timeout=60,
                           env=rdmods.child_env(rdmods.TEST_HOME))
        self.assertEqual(r.returncode, 1)                      # nothing is set up on this machine
        lines = [ln for ln in r.stdout.splitlines() if ln]
        self.assertTrue(lines and all(ln.split()[0] in ("PASS", "FAIL", "SKIP") for ln in lines), r.stdout)
        self.assertTrue(any(ln.startswith("FAIL mask-sleep") for ln in lines))


class Tune(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-tune-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.rr = os.path.join(self.tmp, "rr")
        for d in ("w", "deps", "slots"):
            os.makedirs(os.path.join(self.rr, d))
        self.cap = os.path.join(self.rr, "slots.cap")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)

    def meminfo(self, total_kb, avail_kb):
        p = os.path.join(self.tmp, "meminfo")
        with open(p, "w") as f:
            f.write("MemTotal:       %d kB\nMemAvailable:   %d kB\n" % (total_kb, avail_kb))
        return p

    def conf(self, **kv):
        p = os.path.join(self.tmp, "tune.conf")
        with open(p, "w") as f:
            f.write("".join("%s=%s\n" % kv_ for kv_ in sorted({"RD_USER": "nobody", "MAX_SLOTS": 4,
                                                                "IS_HOME": 0, **kv}.items())))
        return p

    def tune(self, *args, mem=(1000, 900), temp=None, conf=None, **extra):
        files = []
        if temp is not None:
            t = os.path.join(self.tmp, "temp1_input")
            with open(t, "w") as f:
                f.write(str(temp * 1000))
            files = [t]
        env = rdmods.child_env(self.tmp, self.bin, RD_CONF=self.conf(**(conf or {})), RD_MEMINFO=self.meminfo(*mem),
                               RD_CAP_FILE=self.cap, RD_RR_ROOT=self.rr, RD_STATE_DIR=os.path.join(self.tmp, "st"),
                               RD_NO_SERVICES="1", RD_TEMP_FILES=" ".join(files) or "/nonexistent", **extra)
        return subprocess.run(["/bin/bash", TUNE] + list(args), capture_output=True, text=True, env=env, timeout=60)

    def test_cap_follows_memory_and_temperature(self):
        for mem, temp, want in (((1000, 900), 40, "4"), ((1000, 200), 40, "2"), ((1000, 100), 40, "1"),
                                ((1000, 900), 82, "2"), ((1000, 900), 95, "1"), ((0, 0), 40, "1")):
            r = self.tune(mem=mem, temp=temp)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(read(self.cap).strip(), want, (mem, temp))
            self.assertIn("cap=" + want, r.stdout)

    # --- ~/rr prune. Mirrors are <slug>-<wt12>, store entries 32 hex chars (the runner's names).
    WT = ("a" * 12, "b" * 12, "c" * 12, "d" * 12, "e" * 12)

    def fake_df(self, base_gb, total_gb=100, mirror_gb=10, dep_gb=5):
        """RD_DF_CMD: free space follows what is left in w/ and deps/, so eviction moves it."""
        p = os.path.join(self.bin, "fake-df")
        with open(p, "w") as f:
            f.write("#!/bin/sh\nn=$(/bin/ls \"$1/w\" | /usr/bin/wc -l); d=$(/bin/ls \"$1/deps\" | /usr/bin/wc -l)\n"
                    "t=$(( %d * 1048576 )); u=$(( (%d + n * %d + d * %d) * 1048576 ))\n"
                    "echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'\n"
                    "echo \"fake $t $u $(( t - u )) 0%% /\"\n" % (total_gb, base_gb, mirror_gb, dep_gb))
        os.chmod(p, 0o755)
        return p

    def entry(self, kind, name, age_s):
        p = os.path.join(self.rr, kind, name)
        os.makedirs(os.path.join(p, "node_modules"))
        t = time.time() - age_s
        os.utime(p, (t, t))
        return p

    def mirror(self, i, age_s, slug="repo"):
        return self.entry("w", "%s-%s" % (slug, self.WT[i]), age_s)

    def dep(self, i, age_s):
        return self.entry("deps", ("%x" % i) * 32, age_s)

    def who(self, slot, pid, wt="", slug="repo"):
        lock = os.path.join(self.rr, "slots", str(slot))
        open(lock, "a").close()
        with open(lock + ".who", "w") as f:
            f.write("%s %d %d%s\n" % (slug, time.time(), pid, (" " + wt) if wt else ""))
        return lock

    def sleeper(self):
        p = subprocess.Popen(["/bin/sleep", "30"])
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        return p.pid

    def hold(self, lock):
        """Hold the slot flock like the runner (perl flock(2): no util-linux flock on macOS) -> pid."""
        ready = lock + ".ready"
        p = subprocess.Popen(["/usr/bin/perl", "-e", 'use Fcntl ":flock"; open(my $f, "+<", $ARGV[0]) or die;'
                              ' flock($f, LOCK_EX) or die; open(my $r, ">", $ARGV[1]); close $r; sleep 30',
                              lock, ready])
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        for _ in range(100):
            if os.path.exists(ready):
                break
            time.sleep(0.05)
        os.utime(lock)   # the runner bumps the lock, then writes .who (not older than the lock)
        return p.pid

    def prune(self, base_gb=0, conf=None, **extra):
        r = self.tune(RD_DF_CMD=self.fake_df(base_gb), conf=conf, **extra)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def exists(self, *paths):
        return tuple(os.path.exists(p) for p in paths)

    def test_prune_removes_only_old_mirrors_and_deps(self):
        old, new = self.mirror(0, 4 * 86400), self.mirror(1, 0)
        dold, dnew = self.dep(1, 4 * 86400), self.dep(2, 0)
        r = self.prune()
        self.assertEqual(self.exists(old, new, dold, dnew), (False, True, False, True))
        self.assertIn("rd-tune: prune rm mirror repo-%s (unused 2d" % self.WT[0], r.stdout)
        self.assertIn("rd-tune: prune rm store entry %s (unused 2d" % ("1" * 32), r.stdout)
        self.assertEqual(os.listdir(os.path.join(self.rr, ".trash")), [])

    def test_age_rule_runs_every_30_min_only(self):
        self.prune()
        old = self.mirror(0, 4 * 86400)
        self.prune()                       # cooldown: not again within 30 min, and the disk is fine
        self.assertTrue(os.path.exists(old))

    def test_busy_slot_no_longer_blocks_age_pruning_but_its_mirror_is_kept(self):
        used, idle = self.mirror(0, 4 * 86400), self.mirror(1, 4 * 86400)
        dold = self.dep(1, 4 * 86400)
        lock = os.path.join(self.rr, "slots", "0")
        open(lock, "a").close()
        pid = self.hold(lock)
        self.who(0, pid, self.WT[0])
        self.prune()
        self.assertEqual(self.exists(used, idle, dold), (True, False, False))

    def test_live_pid_protects_its_mirror_even_on_a_free_slot(self):
        used, idle = self.mirror(0, 4 * 86400), self.mirror(1, 4 * 86400)
        self.who(3, self.sleeper(), self.WT[0])
        self.prune(base_gb=75)             # disk pressure too: still never the used one
        self.assertEqual(self.exists(used, idle), (True, False))

    def test_old_format_who_protects_the_whole_repo(self):
        a, b, other = self.mirror(0, 4 * 86400), self.mirror(1, 4 * 86400), self.mirror(2, 4 * 86400, slug="x")
        self.who(0, self.sleeper())
        self.prune()
        self.assertEqual(self.exists(a, b, other), (True, True, False))

    def test_held_slot_with_garbled_who_protects_every_mirror(self):
        a = self.mirror(0, 4 * 86400)
        lock = os.path.join(self.rr, "slots", "0")
        open(lock, "a").close()
        self.hold(lock)
        with open(lock + ".who", "w") as f:
            f.write("garbage\n")
        self.prune(base_gb=85)
        self.assertTrue(os.path.exists(a))

    def test_stale_who_with_dead_pid_does_not_protect(self):
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        m = self.mirror(0, 4 * 86400)
        self.who(0, dead.pid, self.WT[0])
        self.prune()
        self.assertFalse(os.path.exists(m))

    def test_recent_guard_keeps_entries_used_in_the_last_30_min(self):
        recent, d_recent = self.mirror(0, 10 * 60), self.dep(1, 10 * 60)
        saving = self.entry("deps", ".tmp-%s.123" % ("2" * 32), 40 * 60)        # a store save: 1 h
        stale_save = self.entry("deps", ".tmp-%s.124" % ("3" * 32), 2 * 3600)
        r = self.prune(base_gb=70)        # 5 GB free: everything eligible would go
        self.assertEqual(self.exists(recent, d_recent, saving, stale_save), (True, True, True, False), r.stdout)

    def test_disk_pressure_removes_lru_mirrors_until_target(self):
        # 100 GB disk, 30 base + 5 mirrors x 10 + 2 deps x 5 = 90 used: 10% free. The target (25% and
        # 30 GB) is reached after the two least recently used mirrors; the rest and the store stay.
        ms = [self.mirror(i, (i + 1) * 3600) for i in range(5)]      # ms[4] = least recently used
        ds = [self.dep(i + 1, 10 * 3600) for i in range(2)]
        r = self.prune(base_gb=30)
        self.assertEqual(self.exists(*ms), (True, True, True, False, False), r.stdout)
        self.assertEqual(self.exists(*ds), (True, True))
        self.assertIn("rd-tune: prune rm mirror repo-%s (disk low: 10%% / 10 GB free" % self.WT[4], r.stdout)

    def test_disk_pressure_also_when_only_gb_is_low(self):
        # 80 GB (80%) free: low only by the GB rule here; one mirror (the older) brings it to 90 GB
        ms = [self.mirror(i, (i + 1) * 3600) for i in range(2)]
        r = self.prune(base_gb=0, PRUNE_MIN_FREE_PCT="1", PRUNE_TARGET_FREE_PCT="1",
                       PRUNE_MIN_FREE_GB="81", PRUNE_TARGET_FREE_GB="85")   # 80 GB free < 81 GB
        self.assertEqual(self.exists(*ms), (True, False), r.stdout)

    def test_disk_pressure_prunes_deps_after_mirrors(self):
        # 45 base + 3 mirrors + 4 deps = 95 used. The active and the recent mirror stay; the old one
        # goes first, then store entries LRU until 30 GB / 30% are free (the newest entry survives).
        active, recent, old = self.mirror(0, 9 * 3600), self.mirror(1, 60), self.mirror(2, 5 * 3600)
        self.who(0, self.sleeper(), self.WT[0])
        ds = [self.dep(i + 1, (i + 1) * 3600) for i in range(4)]
        r = self.prune(base_gb=45)
        self.assertEqual(self.exists(active, recent, old), (True, True, False), r.stdout)
        self.assertEqual(self.exists(*ds), (True, False, False, False), r.stdout)
        lines = [ln for ln in r.stdout.splitlines() if ln.startswith("rd-tune: prune rm")]
        self.assertEqual([ln.split()[3] for ln in lines], ["mirror", "store", "store", "store"])
        self.assertEqual(lines[1].split()[5], "4" * 32)

    def test_disk_fine_leaves_young_entries_alone(self):
        ms = [self.mirror(i, 3600) for i in range(2)]
        self.prune(base_gb=0)
        self.assertEqual(self.exists(*ms), (True, True))

    def test_real_worktree_mirror_last_use_and_git_cleanup(self):
        """A real mirror: last use includes its worktree index (the runner's checkout rewrites it), and
        an evicted one leaves no worktree record and no refs/rrun/<wt12> behind."""
        git = ["/usr/bin/git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main"]
        src, bare = os.path.join(self.tmp, "src"), os.path.join(self.rr, "git", "repo.git")
        subprocess.run(git + ["init", "-q", src], check=True)
        subprocess.run(git + ["-C", src, "commit", "-q", "--allow-empty", "-m", "x"], check=True)
        subprocess.run(git + ["clone", "-q", "--bare", src, bare], check=True)
        names = ["repo-" + self.WT[i] for i in (0, 1)]
        for i, n in enumerate(names):
            subprocess.run(git + ["-C", bare, "update-ref", "refs/rrun/" + self.WT[i], "HEAD"], check=True)
            subprocess.run(git + ["-C", bare, "worktree", "add", "-q", "--detach", os.path.join(self.rr, "w", n)],
                           check=True)
        past = time.time() - 4 * 86400
        for n in names:
            os.utime(os.path.join(self.rr, "w", n), (past, past))
        for root, dirs, files in os.walk(os.path.join(bare, "worktrees", names[0])):
            for f in files:                      # mirror 0: dir and worktree files all old = unused
                os.utime(os.path.join(root, f), (past, past))
        self.prune()
        self.assertEqual(self.exists(*[os.path.join(self.rr, "w", n) for n in names]), (False, True))
        wl = subprocess.run(git + ["-C", bare, "worktree", "list"], capture_output=True, text=True).stdout
        refs = subprocess.run(git + ["-C", bare, "for-each-ref", "refs/rrun"], capture_output=True, text=True).stdout
        self.assertNotIn(names[0], wl)
        self.assertIn(names[1], wl)
        self.assertEqual((self.WT[0] in refs, self.WT[1] in refs), (False, True))

    def test_tune_conf_sets_the_thresholds(self):
        m = self.mirror(0, 3600)
        r = self.prune(base_gb=0, conf={"PRUNE_MIN_FREE_GB": 95, "PRUNE_TARGET_FREE_GB": 95})   # 90 GB free = low
        self.assertFalse(os.path.exists(m), r.stdout)

    def test_bench_writes_speed_relative_to_reference(self):
        node = os.path.join(self.bin, "node")
        with open(node, "w") as f:
            f.write("#!/bin/sh\necho '2.0 1200000'\n")        # 1.2M steps in 2 s = 0.6M/s, ref 1.2M/s
        os.chmod(node, 0o755)
        r = self.tune("bench", RD_BENCH_REF="1200000")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "0.50"), r.stderr)
        self.assertEqual(read(os.path.join(self.tmp, "rr", "speed")).strip(), "0.50")

    def test_bench_piped_over_ssh_finds_mise_node_and_keeps_rr_private(self):
        """A Mac worker: `ssh <alias> /bin/bash -s bench < rd-tune.sh` (rd_fleet.bench_cmd), no getent,
        node only via `mise which node`. The fake node drains stdin first: had it inherited the piped
        script, the rest of rd-tune.sh would vanish and nothing would be written."""
        tools = os.path.join(self.tmp, "mise-node")
        os.makedirs(tools)
        node = os.path.join(tools, "node")
        with open(node, "w") as f:
            f.write("#!/bin/sh\ncat >/dev/null\necho '1.0 1200000'\n")
        mise = os.path.join(self.bin, "mise")
        with open(mise, "w") as f:
            f.write("#!/bin/sh\n[ \"$1 $2\" = 'which node' ] && echo %s\n" % node)
        for p in (node, mise):
            os.chmod(p, 0o755)
        home = os.path.join(self.tmp, "mac-rd-home")        # a fresh worker: no ~/rr yet
        os.makedirs(home)
        env = rdmods.child_env(home, self.bin, RD_BENCH_REF="1200000", RD_CONF="/nonexistent", RD_MISE=mise)
        with open(TUNE) as f:
            r = subprocess.run(["/bin/bash", "-s", "bench"], stdin=f, capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "1.00"), r.stderr)
        self.assertNotIn("getent", r.stderr)
        self.assertEqual(read(os.path.join(home, "rr", "speed")).strip(), "1.00")
        self.assertEqual(os.stat(os.path.join(home, "rr")).st_mode & 0o777, 0o700)

    def test_bench_without_node_fails_loudly(self):
        r = self.tune("bench", RD_MISE="/nonexistent")       # never this Mac's own mise
        self.assertEqual(r.returncode, 1)
        self.assertIn("node not found", r.stderr)

    def test_units_exist_and_timer_is_30s(self):
        self.assertIn("OnUnitActiveSec=30", read(os.path.join(SERVER, "rd-tune.timer")))
        self.assertIn("ExecStart=/usr/local/bin/rd-tune", read(os.path.join(SERVER, "rd-tune.service")))


if __name__ == "__main__":
    unittest.main()
