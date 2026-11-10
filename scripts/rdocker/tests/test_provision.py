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
        self.apply(src=src)
        d = self.f("/home/rd/.config/systemd/user/rd-reporter.service.d/10-rdocker-restart.conf")
        self.assertIn("Restart=always", d)
        self.assertIn("systemctl --user enable rd-reporter.service", self.f("systemctl.log"))

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
        self.assertIn("ExecStart=/usr/bin/setpci -s 00:1f.0 0xa4.b=0", u)
        self.assertIn("Type=oneshot", u)
        self.assertIn("enable rd-ac-poweron.service", self.f("systemctl.log"))
        self.assertNotIn("After Power Loss", out)
        shutil.rmtree(self.root)
        os.makedirs(self.root)
        out = self.apply(product="HP ProDesk 600 G2 SFF")
        self.assertFalse(os.path.exists(os.path.join(self.root, "etc/systemd/system/rd-ac-poweron.service")))
        self.assertIn("After Power Loss = On", out)
        self.assertIn("F10 -> Advanced -> Power-On Options", out)

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
                    "etc/apt/apt.conf.d/52rdocker-unattended"):
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
                     "panic-sysctl", "ac-power", "unattended-upgrades", "tailscale-auto-update", "docker-live-restore"):
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

    def tune(self, *args, mem=(1000, 900), temp=None, **extra):
        files = []
        if temp is not None:
            t = os.path.join(self.tmp, "temp1_input")
            with open(t, "w") as f:
                f.write(str(temp * 1000))
            files = [t]
        env = rdmods.child_env(self.tmp, self.bin, RD_CONF=self.conf(), RD_MEMINFO=self.meminfo(*mem),
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

    def test_prune_removes_only_old_mirrors_and_deps_when_idle(self):
        old, new = os.path.join(self.rr, "w", "old"), os.path.join(self.rr, "w", "new")
        dold, dnew = os.path.join(self.rr, "deps", "a"), os.path.join(self.rr, "deps", "b")
        for d in (old, new, dold, dnew):
            os.makedirs(d)
        past = time.time() - 4 * 86400
        for d in (old, dold):
            os.utime(d, (past, past))
        self.tune()
        self.assertEqual((os.path.exists(old), os.path.exists(new), os.path.exists(dold), os.path.exists(dnew)),
                         (False, True, False, True))

    def test_prune_skips_while_a_slot_is_held(self):
        old = os.path.join(self.rr, "w", "old")
        os.makedirs(old)
        past = time.time() - 4 * 86400
        os.utime(old, (past, past))
        slot = os.path.join(self.rr, "slots", "0")
        open(slot, "w").close()
        flock = shutil.which("flock")
        if not flock:
            self.skipTest("flock (util-linux) not installed")
        holder = subprocess.Popen([flock, slot, "sleep", "20"])
        self.addCleanup(holder.kill)
        time.sleep(0.5)
        self.tune()
        self.assertTrue(os.path.exists(old))

    def test_bench_writes_speed_relative_to_reference(self):
        node = os.path.join(self.bin, "node")
        with open(node, "w") as f:
            f.write("#!/bin/sh\necho '2.0 1200000'\n")        # 1.2M steps in 2 s = 0.6M/s, ref 1.2M/s
        os.chmod(node, 0o755)
        r = self.tune("bench", RD_BENCH_REF="1200000")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "0.50"), r.stderr)
        self.assertEqual(read(os.path.join(self.tmp, "rr", "speed")).strip(), "0.50")

    def test_bench_without_node_fails_loudly(self):
        r = self.tune("bench")
        self.assertEqual(r.returncode, 1)
        self.assertIn("node not found", r.stderr)

    def test_units_exist_and_timer_is_30s(self):
        self.assertIn("OnUnitActiveSec=30", read(os.path.join(SERVER, "rd-tune.timer")))
        self.assertIn("ExecStart=/usr/local/bin/rd-tune", read(os.path.join(SERVER, "rd-tune.service")))


if __name__ == "__main__":
    unittest.main()
