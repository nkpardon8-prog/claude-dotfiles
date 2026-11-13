"""rd_run (the laptop side of rrun), end to end on this machine.

A fake `ssh` (first on PATH) runs the remote command with /bin/sh locally, so the real loader,
the real rr_runner.pl (sent over stdin like on the mini), real git push/receive-pack into a bare
repo under the temp HOME's ~/rr, and the real stdin framing/heartbeat/signals are all exercised.
FAKE_SSH_DOWN=1 makes it fail like an unreachable host (255); FAKE_SSH_DROP=1 runs the remote
command and then reports a dropped connection (255) like a mid-run network loss.
"""
import fcntl
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402

rd_run = rdmods.owner("rrun")
rd_common = rdmods.owner("RRUN_STATE")
ENTRY = os.path.join(rdmods.STAGE, "rdocker.py")
RRUN = os.path.join(rdmods.STAGE, "rrun")

FAKE_SSH = r'''#!/usr/bin/python3 -I
import os, subprocess, sys
args = sys.argv[1:]
with open(os.environ["FAKE_SSH_LOG"], "a") as f:
    f.write(repr(args) + "\n")
i = 0
while i < len(args) and args[i].startswith("-"):
    i += 2 if len(args[i]) == 2 and args[i][1] in "bcDEeFIiJLlmOopQRSWw" else 1
cmd = " ".join(args[i + 1:])
host = args[i]
# per-host fakes (pool tests): FAKE_SSH_HOMES="w1=/a,w2=/b" gives each worker its own HOME;
# FAKE_SSH_PROBE_HOMES overrides it for the pool probe only; *_HOSTS lists name affected workers
def hosts(name):
    return [h for h in os.environ.get(name, "").split(",") if h]
def run_then_drop(cmd):
    # the remote command runs, then the link dies BEFORE the runner's "<nonce> EXIT <rc>" status
    # gets through (a real mid-run loss: the laptop never learns the result); FAKE_SSH_KEEP_EXIT=1
    # lets it through first (the link died during cleanup: the result is known)
    import re
    p = subprocess.Popen(["/bin/sh", "-c", cmd], stderr=subprocess.PIPE)
    for line in iter(p.stderr.readline, b""):
        if os.environ.get("FAKE_SSH_KEEP_EXIT") or not re.match(rb"^[0-9a-f]{32} EXIT ", line):
            os.write(2, line)
    p.wait()
    sys.exit(255)
homes = dict(x.split("=", 1) for x in os.environ.get("FAKE_SSH_HOMES", "").split(",") if "=" in x)
is_probe = "slots_busy" in cmd
if is_probe:
    homes.update(x.split("=", 1) for x in os.environ.get("FAKE_SSH_PROBE_HOMES", "").split(",") if "=" in x)
if host in homes:
    os.environ["HOME"] = homes[host]
if host in hosts("FAKE_SSH_DOWN_HOSTS") or (host in hosts("FAKE_SSH_RUNDOWN_HOSTS") and not is_probe):
    sys.stderr.write("ssh: connect to host %s port 22: Operation timed out\n" % host)
    sys.exit(255)
if host in hosts("FAKE_SSH_DROP_HOSTS") and "rrun-runner" in cmd:
    run_then_drop(cmd)
if os.environ.get("FAKE_SSH_DOWN") or os.path.exists(os.environ.get("FAKE_SSH_DOWN_FILE") or "/nonexistent"):
    sys.stderr.write("ssh: connect to host %s port 22: Operation timed out\n" % args[i])
    sys.exit(255)
if os.environ.get("FAKE_SSH_DROP") and "perl" in cmd:
    run_then_drop(cmd)
if os.environ.get("FAKE_SSH_HANG_DIR") and "perl" in cmd:
    import time
    d = os.environ["FAKE_SSH_HANG_DIR"]
    os.read(0, 4096)                       # pushed; the mini is "preparing" (e.g. waiting for a slot)
    open(os.path.join(d, "up"), "w").close()
    while not os.path.exists(os.path.join(d, "drop")):
        time.sleep(0.05)
    sys.exit(255)                          # then the link dies
if os.environ.get("FAKE_SSH_EARLY_DROP") and "perl" in cmd:
    os.read(0, 4096)                       # the push worked; the session dies before READY
    sys.exit(255)
if os.environ.get("FAKE_SSH_CUT_AFTER_GO") and "perl" in cmd:
    # relay both ways, but when the laptop answers READY with GO, drop the link instead of
    # delivering it: the runner sees EOF, the laptop sees 255 after having written GO
    import threading
    p = subprocess.Popen(["/bin/sh", "-c", cmd], stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    ready = threading.Event()
    def err():
        seen = b""
        while True:
            b = os.read(p.stderr.fileno(), 65536)
            if not b:
                break
            seen = (seen + b)[-200:]
            os.write(2, b)
            if b" READY\n" in seen:
                ready.set()
    threading.Thread(target=err, daemon=True).start()
    while True:
        b = os.read(0, 65536)
        if not b:
            break
        if ready.is_set() and b"GO\n" in b:
            break                          # GO lost in transit
        p.stdin.write(b)
        p.stdin.flush()
    p.stdin.close()
    p.wait()
    sys.exit(255)
once = os.environ.get("FAKE_SSH_DROP_ONCE_AT")
if once and "perl" in cmd and not os.path.exists(os.environ["FAKE_SSH_DROP_FLAG"]):
    # relay both ways until the command's stdout shows FAKE_SSH_DROP_ONCE_AT, then the link dies
    # (we exit 255; the remote side is left running with broken pipes, like sshd after a lost link).
    # Only once: the reconnect after it goes through.
    import threading
    open(os.environ["FAKE_SSH_DROP_FLAG"], "w").close()
    p = subprocess.Popen(["/bin/sh", "-c", cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    def pump(src, dst):
        while True:
            b = os.read(src, 65536)
            if not b:
                break
            os.write(dst, b)
    threading.Thread(target=pump, args=(p.stderr.fileno(), 2), daemon=True).start()
    def feed():
        try:
            pump(0, p.stdin.fileno())
        except OSError:
            pass
    threading.Thread(target=feed, daemon=True).start()
    seen = b""
    while True:
        b = os.read(p.stdout.fileno(), 65536)
        if not b:
            break
        seen += b
        k = seen.find(once.encode())
        if k >= 0:
            os.write(1, b[:len(b) - (len(seen) - k - len(once))])   # up to the marker, then gone
            wipe = os.environ.get("FAKE_SSH_WIPE")        # ...and the worker's spool with it
            for n in (os.listdir(wipe) if wipe and os.path.isdir(wipe) else []):
                os.unlink(os.path.join(wipe, n))
            os._exit(255)
        os.write(1, b)
    sys.exit(p.wait())
os.execv("/bin/sh", ["/bin/sh", "-c", cmd])
'''
FAKE_DOCKER = "#!/bin/sh\nexit 0\n"


def wfile(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


class RunBase(unittest.TestCase):
    """Fixture: a temp HOME, a git worktree, fake ssh/docker; no tests of its own."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="rrun-", dir=rdmods.TEST_HOME)
        self.home = os.path.join(self.d, "home")
        self.bin = os.path.join(self.d, "bin")
        os.makedirs(self.home)
        wfile(os.path.join(self.bin, "ssh"), FAKE_SSH, 0o755)
        wfile(os.path.join(self.bin, "docker"), FAKE_DOCKER, 0o755)
        self.sshlog = os.path.join(self.d, "ssh.log")
        self.wt = os.path.join(self.d, "wt")
        files = {".gitignore": "node_modules\n.env*\nignored.txt\n", "a.txt": "a\n",
                 "mod.txt": "old\n", "del.txt": "bye\n", "staged.txt": "s0\n", "sub/keep.txt": "k\n"}
        for n, c in files.items():
            wfile(os.path.join(self.wt, n), c)
        self.write_cfg()                    # no fleet: the single configured host (pool tests: test_pool)
        self.git("init", "-q", self.wt)
        self.git("-C", self.wt, "add", "-A")
        self.git("-C", self.wt, "commit", "-qm", "init")

    def tearDown(self):
        # a test that fails mid-run must not leave its rrun / fake runner / command looping (one
        # did, for 10 h, on 2026-10-15): every process of ours names self.d on its command line
        subprocess.run(["pkill", "-KILL", "-f", self.d], capture_output=True)
        shutil.rmtree(self.d, True)

    def write_cfg(self, **kw):
        cfgd = os.path.join(self.home, ".config", "rdocker")
        os.makedirs(cfgd, exist_ok=True)
        with open(os.path.join(cfgd, "config.json"), "w") as f:
            # rr_warm_trigger off: a job never starts a background `rdocker warm` in these tests
            json.dump(dict({"fleet_path": os.path.join(self.d, "no-fleet.json"), "rr_warm_trigger": False}, **kw), f)

    @staticmethod
    def read(path):
        with open(path) as f:
            return f.read()

    def env(self, **extra):
        return rdmods.child_env(self.home, self.bin, FAKE_SSH_LOG=self.sshlog,
                                RR_PATH=rdmods.safe_path(self.bin),
                                RR_REAL_DOCKER=os.path.join(self.bin, "docker"), **extra)

    def git(self, *args):
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c",
                               "commit.gpgsign=false"] + list(args), env=self.env(), check=True,
                              capture_output=True, text=True).stdout

    def rrun(self, *argv, cwd=None, timeout=60, **env):
        return subprocess.run([RRUN] + list(argv), cwd=cwd or self.wt, env=self.env(**env),
                              capture_output=True, text=True, timeout=timeout)

    def popen(self, *argv, **env):
        return subprocess.Popen([RRUN] + list(argv), cwd=self.wt, env=self.env(**env),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def hold_lanes(self, n=3):
        """flock every worktree lane (3 = fleet.json wt_lanes' default; no fleet here) -> the fds."""
        rr = rd_run.resolve_worktree(self.wt)
        st = os.path.join(self.home, ".local", "state", "rdocker")
        os.makedirs(st, exist_ok=True)
        fds = []
        for k in range(n):
            fd = os.open(os.path.join(st, "rrun-%s%s.lock" % (rr["wt12"], ".%d" % k if k else "")),
                         os.O_RDWR | os.O_CREAT)
            fcntl.flock(fd, fcntl.LOCK_EX)
            fds.append(fd)
        return fds

    @staticmethod
    def drop(fds):
        for fd in fds:
            os.close(fd)

    def mirror(self):
        w = os.path.join(self.home, "rr", "w2")
        names = [n for n in os.listdir(w) if not n.startswith(".")]
        self.assertEqual(len(names), 1, names)
        return os.path.join(w, names[0])

    def dirty(self):
        """modified, staged, deleted, untracked, ignored, env (incl. symlinks), node_modules."""
        wt = self.wt
        wfile(os.path.join(wt, "mod.txt"), "new\n")
        wfile(os.path.join(wt, "staged.txt"), "s1\n")
        self.git("-C", wt, "add", "staged.txt")
        os.unlink(os.path.join(wt, "del.txt"))
        wfile(os.path.join(wt, "new.txt"), "untracked\n")
        wfile(os.path.join(wt, "run.sh"), "#!/bin/sh\necho hi\n", 0o755)
        wfile(os.path.join(wt, "ignored.txt"), "ignored\n")
        wfile(os.path.join(wt, ".env"), "SECRET=1\n")
        wfile(os.path.join(wt, "sub", ".env.test.local"), "T=1\n")
        wfile(os.path.join(wt, "sub", ".env.production"), "NOT_ALLOWED=1\n")
        wfile(os.path.join(wt, "node_modules", ".env"), "NM=1\n")
        wfile(os.path.join(wt, "node_modules", "x.js"), "x\n")
        wfile(os.path.join(self.d, "real-env"), "LINKED=1\n")
        os.symlink(os.path.join(self.d, "real-env"), os.path.join(wt, "sub", ".env.local"))
        os.symlink(self.d, os.path.join(wt, ".env.local"))          # -> a dir: never followed
        os.symlink("../a.txt", os.path.join(wt, "sub", ".env.test.inside"))   # inside: followed
        wfile(os.path.join(wt, "deep", "x", ".env"), "DEEP=1\n")     # not a root/cwd/deps dir
        os.symlink("a.txt", os.path.join(wt, "link.txt"))            # plain symlink: never sent


class RunTest(RunBase):
    # ---------------------------------------------------------------------------- end to end
    def test_happy_path_rc_and_argv(self):
        r = self.rrun("/bin/sh", "-c", "echo out; echo err >&2; exit 7")
        self.assertEqual(r.returncode, 7, r.stderr)
        self.assertEqual(r.stdout, "out\n")
        self.assertIn("err\n", r.stderr)
        self.assertNotIn("STARTED", r.stderr)
        r = self.rrun("--", "/bin/sh", "-c", "exit 0")
        self.assertEqual(r.returncode, 0, r.stderr)
        args = ["a b", "q'\"", "$(echo x)", "`id`", "*", "", "line1\nline2"]
        r = self.rrun("printf", "[%s]\\n", *args)
        self.assertEqual(r.stdout, "".join("[%s]\n" % a for a in args), r.stderr)
        r = self.rrun("-e", "FOO=x y 'q'", "-e", "BAR=", "/bin/sh", "-c", 'printf "%s|%s|%s" "$FOO" "$BAR" "$RRUN_REMOTE"')
        self.assertEqual(r.stdout, "x y 'q'||1", r.stderr)
        # -e NAME forwards our own value (the hook's `FOO=v rrun -e FOO ...` keeps it out of argv)
        r = self.rrun("-e", "SECRETV", "-e", "UNSETV", "/bin/sh", "-c", 'printf "%s|%s" "$SECRETV" "${UNSETV-unset}"',
                      SECRETV="s3 cr$t")
        self.assertEqual(r.stdout, "s3 cr$t|unset", r.stderr)
        self.assertIn("-e UNSETV: not set here, not passed", r.stderr)
        self.assertNotIn("s3 cr$t", self.read(self.sshlog))     # never in an ssh argv
        # the push went over our own master, through the ~ URL, with hooks off
        log = self.read(self.sshlog)
        self.assertIn("ControlPath=~/.ssh/rr-%C", log)
        self.assertIn("git -c core.hooksPath=/dev/null receive-pack", log)
        bare = [n for n in os.listdir(os.path.join(self.home, "rr", "git"))]
        self.assertEqual(len(bare), 1)
        self.assertRegex(bare[0], r"^wt\.[0-9a-f]{8}\.git$")
        cfg = subprocess.run(["git", "-C", os.path.join(self.home, "rr", "git", bare[0]), "config",
                              "receive.fsckObjects"], capture_output=True, text=True).stdout
        self.assertEqual(cfg.strip(), "true")
        st = json.loads(self.read(rd_common.RRUN_STATE.replace(rdmods.TEST_HOME, self.home)))
        self.assertEqual(st["last"]["target"], "mini")
        route = self.read(os.path.join(self.home, ".local", "state", "rdocker", "route.log"))
        self.assertRegex(route, r"mini  rrun     /bin/sh -c 'echo out.*rc=7 [0-9.]+s")

    def test_relcwd_and_prefix_deps(self):
        r = self.rrun("/bin/pwd", cwd=os.path.join(self.wt, "sub"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), os.path.join(os.path.realpath(self.mirror()), "sub"))
        top = self.wt
        for d in ("", "server", "server/src/x"):
            os.makedirs(os.path.join(top, d), exist_ok=True)
        wfile(os.path.join(top, "package-lock.json"), "{}")
        wfile(os.path.join(top, "server", "package-lock.json"), "{}")
        wfile(os.path.join(top, "client", "package-lock.json"), "{}")
        self.assertEqual(rd_run.deps_dirs(top, "server/src/x", ["npm", "test"]), ["server"])
        self.assertEqual(rd_run.deps_dirs(top, "docs", ["npm", "test"]), [""])
        # repo root: also every first-level subproject installed on the laptop (node_modules present)
        os.makedirs(os.path.join(top, "server", "node_modules"))
        self.assertEqual(rd_run.deps_dirs(top, "", ["npm", "run", "x"]), ["server", ""])
        self.assertEqual(rd_run.deps_dirs(top, "client", ["npm", "test"]), ["client"])
        self.assertEqual(rd_run.deps_dirs(top, "", ["npm", "--prefix", "client", "run", "t"]), ["server", "", "client"])
        self.assertEqual(rd_run.deps_dirs(top, "server", ["npm", "--prefix=../client", "--prefix", "/etc"]),
                         ["server", "client"])

    def test_overlay_and_deleted(self):
        self.dirty()
        cfg = dict(rd_common.DEFAULTS)
        tar, files, envs, deleted = rd_run.build_overlay(cfg, self.wt, ["", "sub"])
        self.assertEqual(sorted(files), ["mod.txt", "new.txt", "run.sh", "staged.txt"])
        # sub/.env.local -> a file outside the worktree: skipped; deep/.env: not a root/cwd/deps
        # dir; sub/.env.inside -> a worktree file: fine
        self.assertEqual(envs, [".env", "sub/.env.test.inside", "sub/.env.test.local"])
        self.assertEqual(deleted, ["del.txt"])
        with tarfile.open(fileobj=io.BytesIO(tar)) as t:
            mem = {m.name: m for m in t.getmembers()}
            self.assertTrue(all(m.isreg() for m in mem.values()))
            self.assertEqual(t.extractfile(mem["sub/.env.test.inside"]).read(), b"a\n")
            self.assertEqual(mem[".env"].mode, 0o600)
            self.assertEqual(mem["run.sh"].mode, 0o700)
        self.assertEqual(rd_run.build_overlay(cfg, self.wt)[2], [".env"])     # root only
        # ... and on the "mini": the mirror has them, deleted/ignored/node_modules/symlinks do not
        r = self.rrun("/bin/sh", "-c", "cd .. && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort; "
                      "cat mod.txt staged.txt", cwd=os.path.join(self.wt, "sub"))   # cwd sub => sub/.env*
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not copying sub/.env.local: it resolves outside this worktree", r.stderr)
        listed = [x for x in r.stdout.splitlines() if x.startswith("./")]
        self.assertEqual(listed, ["./.env", "./.gitignore", "./a.txt", "./mod.txt", "./new.txt", "./run.sh",
                                  "./staged.txt", "./sub/.env.test.inside", "./sub/.env.test.local",
                                  "./sub/keep.txt"])
        self.assertTrue(r.stdout.endswith("new\ns1\n"), r.stdout)
        # env files are gone from the mirror after the run
        m = self.mirror()
        self.assertFalse(os.path.exists(os.path.join(m, ".env")))
        self.assertFalse(os.path.exists(os.path.join(m, "sub", ".env.test.local")))

    def test_spoofed_status_lines_pass_through(self):
        fake = "f" * 32
        r = self.rrun("/bin/sh", "-c", 'echo "%s STARTED" >&2; echo "%s KEPT x" >&2; exit 3' % (fake, fake))
        self.assertEqual(r.returncode, 3)
        self.assertIn(fake + " STARTED\n", r.stderr)          # relayed, not swallowed
        self.assertNotIn("containers stay", r.stderr)          # a forged KEPT triggers nothing
        seen = []
        out = io.BytesIO()
        f = rd_run.StatusFilter("a" * 32, out, seen.append)
        for chunk in (b"pro", b"gress 10%\n", b"aaaa", b"a" * 28 + b" STA", b"RTED\nx", b"\n",
                      b"b" * 32 + b" STARTED\n", b"aa", b"x\n"):
            f.feed(chunk)
        f.close()
        self.assertEqual(seen, ["STARTED"])
        self.assertEqual(out.getvalue(), b"progress 10%\nx\n" + b"b" * 32 + b" STARTED\naax\n")
        # a status line glued to stderr that had no trailing newline is still ours, never leaked
        seen, out = [], io.BytesIO()
        f = rd_run.StatusFilter("a" * 32, out, seen.append)
        for chunk in (b"50% done", b"a" * 32 + b" KEPT pg1\n", b"tail", b"a" * 10, b"a" * 22 + b" READY\n"):
            f.feed(chunk)
        f.close()
        self.assertEqual(seen, ["KEPT pg1", "READY"])
        self.assertEqual(out.getvalue(), b"50% done\ntail\n")

    # ---------------------------------------------------------------------------- fallback
    def test_unreachable_falls_back_locally_or_75_strict(self):
        r = self.rrun("/bin/sh", "-c", 'echo "mode=$RDOCKER_MODE"; exit 4', FAKE_SSH_DOWN="1",
                      RRUN_RECONNECT_WAIT="0")
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertEqual(r.stdout, "mode=local\n")
        self.assertIn("running on the laptop instead", r.stderr)
        r = self.rrun("/bin/sh", "-c", "echo ran", FAKE_SSH_DOWN="1", RRUN_STRICT="1",
                      RRUN_RECONNECT_WAIT="0")
        self.assertEqual(r.returncode, 75)
        self.assertEqual(r.stdout, "")
        # a push to a missing repo (mini fine, push broken) is the same "before anything started"
        r = self.rrun("/bin/sh", "-c", "echo ran", RRUN_GIT_URL=os.path.join(self.d, "nope", "x.git"))
        self.assertEqual((r.returncode, r.stdout), (0, "ran\n"), r.stderr)
        self.assertIn("git push to the mini failed", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, "rr", "w2")))

    def test_unreachable_waits_for_the_mini_then_runs_there(self):
        """A short outage before the command started: rrun waits and runs it on the mini, not here."""
        down = os.path.join(self.d, "down")
        open(down, "w").close()
        p = subprocess.Popen([RRUN, "/bin/sh", "-c", 'echo "mode=$RDOCKER_MODE"'], cwd=self.wt,
                             env=self.env(FAKE_SSH_DOWN_FILE=down, RRUN_RECONNECT_WAIT="30",
                                          RRUN_RECONNECT_POLL="0.2"),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(1.5)
        os.unlink(down)                                        # the mini comes back
        out, err = p.communicate(timeout=60)
        self.assertEqual((p.returncode, out), (0, "mode=\n"), err)    # ran remotely, not local
        self.assertIn("waiting up to 30 s for it to come back", err)
        self.assertIn("the Mac mini is back - trying there again", err)
        self.assertNotIn("running on the laptop", err)

    def test_unreachable_too_long_falls_back_after_the_wait(self):
        t0 = time.time()
        r = self.rrun("/bin/sh", "-c", 'echo "mode=$RDOCKER_MODE"', FAKE_SSH_DOWN="1",
                      RRUN_RECONNECT_WAIT="1", RRUN_RECONNECT_POLL="0.2")
        self.assertEqual((r.returncode, r.stdout), (0, "mode=local\n"), r.stderr)
        self.assertGreaterEqual(time.time() - t0, 1.0)
        self.assertIn("did not come back within 1 s - running on the laptop instead", r.stderr)

    def test_stopped_while_waiting_for_the_mini_runs_nowhere(self):
        marker = os.path.join(self.d, "ran")
        p = subprocess.Popen([RRUN, "/bin/sh", "-c", "echo x >> %s" % marker], cwd=self.wt,
                             env=self.env(FAKE_SSH_DOWN="1", RRUN_RECONNECT_WAIT="60",
                                          RRUN_RECONNECT_POLL="0.2"),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(2.5)
        p.send_signal(signal.SIGTERM)
        _, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 128 + signal.SIGTERM, err)
        self.assertIn(b"waiting up to 60 s", err)
        self.assertIn(b"not running it anywhere", err)
        self.assertFalse(os.path.exists(marker))

    def test_255_before_ready_falls_back_once(self):
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", 'echo "$RDOCKER_MODE" >> %s' % marker, FAKE_SSH_EARLY_DROP="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("lost the Mac mini before the command started - running on the laptop", r.stderr)
        self.assertEqual(self.read(marker), "local\n")        # exactly one run, on the laptop
        ok, _, detail = rd_run.status_row(time.time())
        st = json.loads(self.read(rd_common.RRUN_STATE.replace(rdmods.TEST_HOME, self.home)))
        self.assertEqual(st["active"], {})                     # no stale "mini slot busy"
        self.assertEqual(st["last"]["target"], "local")

    def test_origin_base_branches_reach_the_mini(self):
        """`origin/dev` resolves inside rrun (guards diff against it); a missing base is skipped."""
        sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.wt, capture_output=True,
                             text=True, env=self.env()).stdout.strip()
        subprocess.run(["git", "update-ref", "refs/remotes/origin/dev", sha], cwd=self.wt, check=True,
                       env=self.env())
        r = self.rrun("git", "rev-parse", "origin/dev")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), sha)
        r = self.rrun("git", "rev-parse", "-q", "--verify", "origin/main")
        self.assertEqual(r.returncode, 1)                       # not present locally: not invented

    def test_stopped_before_ready_never_falls_back(self):
        """A tool timeout TERMs rrun while the mini is still preparing; the link then drops.
        That must end the run, not start it on the laptop."""
        marker = os.path.join(self.d, "ran")
        hang = os.path.join(self.d, "hang")
        os.makedirs(hang)
        e = self.env(FAKE_SSH_HANG_DIR=hang)
        p = subprocess.Popen([RRUN, "/bin/sh", "-c", "echo x >> %s" % marker], cwd=self.wt, env=e,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        end = time.time() + 30
        while not os.path.exists(os.path.join(hang, "up")):
            self.assertLess(time.time(), end, "fake ssh never came up")
            time.sleep(0.05)
        p.send_signal(signal.SIGTERM)
        time.sleep(0.3)
        open(os.path.join(hang, "drop"), "w").close()
        _, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 128 + signal.SIGTERM, err)
        self.assertIn(b"not running it anywhere", err)
        self.assertFalse(os.path.exists(marker))              # not run on the laptop either

    def test_connection_lost_after_go_but_go_never_arrived_is_known_and_safe(self):
        """GO was written, then the link died before it arrived. The reconnect finds the run never
        started there (NORUN), so it is a loss BEFORE the start: today's rule for that (here: one
        retry, then the laptop) applies - exactly one run in all, never a guess. (Before
        2026-11-11 this was exit 75: the laptop could not know.)"""
        self.write_cfg(rr_reattach_backoff_s=[0, 0, 0])
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", 'echo "$RDOCKER_MODE" >> %s' % marker, FAKE_SSH_CUT_AFTER_GO="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("command was not started", r.stderr)    # the runner gave up cleanly
        self.assertIn("reconnecting (1 of 3)", r.stderr)
        self.assertIn("before the command started (it never ran there)", r.stderr)
        self.assertEqual(self.read(marker), "local\n")        # exactly one run, on the laptop

    def test_a_command_exiting_255_itself_is_its_result_not_a_lost_link(self):
        r = self.rrun("/bin/sh", "-c", "echo out; exit 255")
        self.assertEqual((r.returncode, r.stdout), (255, "out\n"), r.stderr)
        self.assertNotIn("lost", r.stderr)
        r = self.rrun("/bin/sh", "-c", "exit 4", FAKE_SSH_DROP="1", FAKE_SSH_KEEP_EXIT="1")
        self.assertEqual(r.returncode, 4, r.stderr)                 # the link died during cleanup
        self.assertIn("dropped after the command finished there (exit 4)", r.stderr)

    def test_drop_detection_keepalives(self):
        o = rd_run.ssh_opts()
        self.assertIn("ServerAliveInterval=5", o)
        self.assertIn("ServerAliveCountMax=3", o)
        self.assertIn("ConnectTimeout=6", o)

    def test_255_after_started_is_76_and_never_reruns(self):
        """The link drops after the start and every reconnect drops too: may have run (76), no rerun."""
        self.write_cfg(rr_reattach_backoff_s=[0, 0, 0])
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", "echo x >> %s" % marker, FAKE_SSH_DROP="1")
        self.assertEqual(r.returncode, 76, r.stderr)
        self.assertIn("rrun: infra (exit 76", r.stderr)
        self.assertIn("lost mini mid-run and could not reconnect; it may have run there", r.stderr)
        self.assertIn("reconnecting (3 of 3)", r.stderr)      # tried to reattach first
        self.assertEqual(self.read(marker), "x\n")            # exactly one run (the remote one)

    def test_lost_link_mid_run_reattaches_and_returns_the_real_result(self):
        """2026-11-11 (Phase B): the link dies mid-run; the worker's keeper runs on and spools the
        output; rrun reconnects with a fresh ssh (no shared master), resumes the output exactly where
        it broke off and returns the command's own exit code. The command ran once."""
        self.write_cfg(rr_reattach_backoff_s=[0, 0, 0])
        marker = os.path.join(self.d, "ran")
        flag = os.path.join(self.d, "dropped")
        r = self.rrun("/bin/sh", "-c", "echo x >> %s; printf part1; echo e1 >&2; sleep 1; printf part2; "
                      "echo e2 >&2; exit 6" % marker, FAKE_SSH_DROP_ONCE_AT="part1", FAKE_SSH_DROP_FLAG=flag)
        self.assertEqual((r.returncode, r.stdout), (6, "part1part2"), r.stderr)
        self.assertTrue(os.path.exists(flag))
        self.assertEqual(self.read(marker), "x\n")                      # once
        self.assertIn("reconnecting (1 of 3)", r.stderr)
        self.assertIn("reconnected to the Mac mini", r.stderr)
        self.assertEqual(r.stderr.count("e2\n"), 1, r.stderr)           # nothing twice
        self.assertNotIn("lost the Mac mini mid-run", r.stderr)
        att = [ln for ln in self.read(self.sshlog).splitlines() if "ControlPath=none" in ln]
        self.assertEqual(len(att), 1)                                   # the reattach: its own connection
        self.assertIn("ControlMaster=no", att[0])
        runs = self.read(os.path.join(self.home, "rr", "log", "runs.log")).splitlines()
        self.assertRegex(runs[-1], r"outcome=rc=6 .*\trun=[0-9a-f-]{36} owner=\S+ cls=normal "
                                   r"wait_s=\d+\.\d exit_reason=fail setup=\S+ pred_s=\S+ client=\S+ pv=\S+ node=\S+ lock_s=[\d.]+ slot_s=[\d.]+$")

    def test_runner_header_carries_a_uuid4_run_id_and_the_180s_tolerance(self):
        class H:
            cfg = dict(rd_common.DEFAULTS, host="x")
            entry = None
        wt = {"slug": "s", "wt12": "w", "sha": "0" * 40, "relcwd": ""}
        job = {"cls": "normal", "need_gb": 2}
        hs = []
        for _ in range(2):
            frames, nonce = rd_run.runner_frames(H, wt, ["true"], {}, [], b"", [], [], job, False)
            hs.append(json.loads(frames[3]))
        for h in hs:
            self.assertRegex(h["run_id"], r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
            self.assertEqual((h["detach_hb_s"], h["job_cls"]), (180, "normal"))
        self.assertNotEqual(hs[0]["run_id"], hs[1]["run_id"])
        self.assertIn("ControlMaster=no", rd_run.ssh_opts(mux=False))
        self.assertNotIn("ControlMaster=auto", rd_run.ssh_opts(mux=False))

    def test_shallow_clone_push_refused_says_why(self):
        shallow = os.path.join(self.d, "shallow")
        self.git("clone", "-q", "--depth", "1", "file://" + self.wt, shallow)
        wfile(os.path.join(self.wt, "b.txt"), "b\n")
        self.git("-C", self.wt, "add", "b.txt")
        self.git("-C", self.wt, "commit", "-qm", "b")
        r = self.rrun("/bin/sh", "-c", "echo ran", cwd=shallow)
        self.assertEqual((r.returncode, r.stdout), (0, "ran\n"), r.stderr)
        self.assertIn("cannot send this repo to the Mac mini: this clone is shallow", r.stderr)
        self.assertIn("running on the laptop instead", r.stderr)

    # ---------------------------------------------------------------------------- signals / locks
    def test_sigint_is_forwarded_to_the_command(self):
        ready = os.path.join(self.d, "ready")
        p = self.popen("/bin/sh", "-c", 'trap "echo GOTINT; exit 9" INT; touch %s; '
                       'while :; do sleep 0.1; done' % ready)
        end = time.time() + 30
        while not os.path.exists(ready):
            self.assertLess(time.time(), end, "remote command never started")
            time.sleep(0.05)
        p.send_signal(signal.SIGINT)
        out, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 9, err)
        self.assertIn("GOTINT", out)

    def test_second_ctrl_c_kills_and_slot_wait_is_reported(self):
        ready = os.path.join(self.d, "ready")
        slots = os.path.join(self.home, "rr", "slots")
        os.makedirs(slots)
        self.write_cfg(rr_slots=1)                           # one slot, so holding it makes rrun wait
        with open(os.path.join(slots, "0.who"), "w") as f:
            f.write("other.repo %d\n" % int(time.time() - 42))
        fd = os.open(os.path.join(slots, "0"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)                       # another run holds the only slot
        errf = os.path.join(self.d, "err")
        with open(errf, "w") as ef:
            p = subprocess.Popen([RRUN, "/bin/sh", "-c", "trap '' INT; touch %s; while :; do sleep 0.1; done"
                                  % ready], cwd=self.wt, env=self.env(), stdout=subprocess.DEVNULL, stderr=ef)
        end = time.time() + 30
        while "waiting for a slot on the Mac mini" not in self.read(errf):
            self.assertLess(time.time(), end, self.read(errf))
            time.sleep(0.05)
        self.assertIn("held longest by other.repo for 4", self.read(errf))
        os.close(fd)
        while not os.path.exists(ready):
            self.assertLess(time.time(), end, "remote command never started")
            time.sleep(0.05)
        p.send_signal(signal.SIGINT)                         # ignored by the command
        time.sleep(0.5)
        self.assertIsNone(p.poll())
        p.send_signal(signal.SIGINT)                         # second: stdin closed -> group TERM
        self.assertEqual(p.wait(30), 128 + signal.SIGTERM)
        self.assertEqual(self.read(errf).count("waiting for a slot on the Mac mini"), 1)

    def test_worktree_lock_serialises(self):
        fds = self.hold_lanes()                              # every lane busy: it waits
        marker = os.path.join(self.d, "ran")
        errf = os.path.join(self.d, "err")
        with open(errf, "w") as ef:
            p = subprocess.Popen([RRUN, "/bin/sh", "-c", "touch %s" % marker], cwd=self.wt,
                                 env=self.env(), stdout=subprocess.DEVNULL, stderr=ef)
        end = time.time() + 30
        while "waiting for this worktree" not in self.read(errf):
            self.assertLess(time.time(), end, "rrun never reported waiting for the worktree lock")
            time.sleep(0.05)
        time.sleep(0.5)
        self.assertFalse(os.path.exists(marker))
        self.assertIsNone(p.poll())
        self.drop(fds)
        self.assertEqual(p.wait(30), 0)
        self.assertTrue(os.path.exists(marker))

    def test_timing_flag(self):
        r = self.rrun("true", RRUN_TIMING="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        line = [ln for ln in r.stderr.splitlines() if ln.startswith("rrun: timing:")]
        self.assertEqual(len(line), 1, r.stderr)
        for stage in ("resolve", "push", "overlay", "remote prepare", "command", "total"):
            self.assertIn(stage, line[0])
        self.assertNotIn("timing", self.rrun("true").stderr)

    def test_status_row_and_usage(self):
        ok, label, detail = rd_run.status_row(time.time())
        self.assertEqual(label, "rrun")
        r = self.rrun()
        self.assertEqual(r.returncode, 2)
        self.assertIn("usage: rrun", r.stderr)
        r = self.rrun("-e", "1BAD=x", "true")
        self.assertNotEqual(r.returncode, 0)
        r = self.rrun("/bin/sh", "-c", 'echo "$RDOCKER_MODE"', RRUN="0")
        self.assertEqual(r.stdout, "local\n")
        self.assertFalse(os.path.exists(self.sshlog))


class HangsAndOwners(RunBase):
    """2026-11-11: a finished test:db held its worktree lock ~4 h; an eslint sat 1 h 38 m silent; an
    agent killed another session's job it could not tell apart from its own."""

    def wt_lock_free(self):
        rr = rd_run.resolve_worktree(self.wt)
        lock = os.path.join(self.home, ".local", "state", "rdocker", "rrun-%s.lock" % rr["wt12"])
        fd = os.open(lock, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False
        finally:
            os.close(fd)

    def test_leftover_child_does_not_keep_rrun_or_the_lock(self):
        self.write_cfg(rr_exit_grace_s=1)
        t0 = time.time()
        r = self.rrun("/bin/sh", "-c", "(sleep 60; echo late) & echo main-done; exit 3", timeout=40)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertLess(time.time() - t0, 20)
        self.assertEqual(r.stdout, "main-done\n")
        self.assertTrue(self.wt_lock_free())

    def test_silent_job_gets_a_watchdog_line(self):
        r = self.rrun("/bin/sh", "-c", "sleep 3; echo done", RRUN_SILENT_MIN="0.02")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stderr, r"rrun: no output for \d+ s \(worker mini, running \d+ s\)")
        r = self.rrun("/bin/sh", "-c", "sleep 2; echo done", RRUN_SILENT_MIN="0")
        self.assertNotIn("no output", r.stderr)

    def test_wall_clock_cap_exits_124_and_frees_the_lock(self):
        t0 = time.time()
        r = self.rrun("/bin/sh", "-c", "echo started; sleep 60", RRUN_TIMEOUT="0.02", timeout=40)
        self.assertEqual(r.returncode, 124, r.stderr)
        self.assertLess(time.time() - t0, 25)
        self.assertIn("wall-clock cap", r.stderr)
        self.assertIn("RRUN_TIMEOUT", r.stderr)
        self.assertTrue(self.wt_lock_free())
        self.assertEqual(rd_run.timeout_s({}, "db", {}), 90 * 60)
        self.assertEqual(rd_run.timeout_s({}, "light", {}), 30 * 60)
        self.assertEqual(rd_run.timeout_s({}, "heavy", {"RRUN_TIMEOUT": "0"}), 0)
        self.assertEqual(rd_run.timeout_s({"rr_timeout_min": {"build": 5}}, "build", {}), 300)

    def test_owner_tag_status_and_mine(self):
        os.makedirs(os.path.join(self.home, ".claude", "session-status"))
        wfile(os.path.join(self.home, ".claude", "session-status", "sess-1.txt"), "billing window\nx\n")
        ready = os.path.join(self.d, "ready")
        p = self.popen("/bin/sh", "-c", "touch %s; sleep 4" % ready, CLAUDE_CODE_SESSION_ID="sess-1")
        end = time.time() + 30
        while not os.path.exists(ready):
            self.assertLess(time.time(), end, "never started")
            time.sleep(0.05)
        mine = self.rrun("--mine", CLAUDE_CODE_SESSION_ID="sess-1")
        self.assertEqual(mine.returncode, 0, mine.stderr)
        self.assertIn("billing window (session:sess-1) = you", mine.stdout)
        self.assertRegex(mine.stdout, r"mini +\d\d:\d\d +\d+ s ")
        self.assertIn("/bin/sh -c touch", mine.stdout)
        other = self.rrun("--mine", CLAUDE_CODE_SESSION_ID="sess-2")
        self.assertIn("no of your rrun jobs running", other.stdout)
        every = self.rrun("--jobs", CLAUDE_CODE_SESSION_ID="sess-2")
        self.assertIn("billing window (session:sess-1)", every.stdout)
        self.assertNotIn("= you", every.stdout)
        st = json.loads(self.read(rd_common.RRUN_STATE.replace(rdmods.TEST_HOME, self.home)))
        (a,) = st["active"].values()
        self.assertEqual((a["owner"], a["name"], a["host"]), ("session:sess-1", "billing window", "mini"))
        self.assertEqual(a["cap_s"], 30 * 60)
        p.communicate(timeout=30)
        self.assertEqual(p.returncode, 0)
        o = rd_run.owner_info({})
        self.assertRegex(o["id"], r"^pid:\d+$")                     # no session: the parent pid

    def test_worktree_lock_wait_is_bounded_exit_72(self):
        self.write_cfg(rr_wt_wait_min=0.03, rr_status_every_s=0.5)
        rr = rd_run.resolve_worktree(self.wt)
        lock = os.path.join(self.home, ".local", "state", "rdocker", "rrun-%s.lock" % rr["wt12"])
        fds = self.hold_lanes()
        try:
            t0 = time.time()
            r = self.rrun("/bin/sh", "-c", "echo ran")
            self.assertEqual(r.returncode, 72, r.stderr)
            self.assertLess(time.time() - t0, 20)
            self.assertNotIn("ran", r.stdout)
            self.assertIn("other rruns from this worktree kept all 3 of its lanes after 2 s", r.stderr)
            self.assertIn("exit 72", r.stderr)
            self.assertTrue(os.path.exists(lock))                     # never unlinked
            self.assertRegex(self.read(os.path.join(self.home, ".local", "state", "rdocker", "route.log")),
                             r"none +rrun .* rc=72 .*\tlock_s=[\d.]+")   # the lane wait is in route.log
        finally:
            self.drop(fds)
        self.assertEqual(rd_run.wt_wait_s({}, {"cls": "db"}, {}), 90 * 60)  # default: the job's own cap

    def test_busy_worker_re_plans_instead_of_sitting_30_min(self):
        self.write_cfg(rr_slots=1, rr_slot_wait_s=1, rr_wait_min=0.1)
        slots = os.path.join(self.home, "rr", "slots")
        os.makedirs(slots)
        fd = os.open(os.path.join(slots, "0"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            t0 = time.time()
            r = self.rrun("/bin/sh", "-c", "echo ran", timeout=90)
            self.assertEqual(r.returncode, 73, r.stderr)
            self.assertLess(time.time() - t0, 60)
            self.assertIn("re-planning", r.stderr)
            self.assertIn("rrun: infra (exit 73", r.stderr)
            self.assertIn("no worker had a free slot for 6 s; never ran", r.stderr)
            # freed while it re-plans: it runs
            threading_timer = __import__("threading").Timer(2.5, lambda: os.close(fd))
            threading_timer.start()
            r = self.rrun("/bin/sh", "-c", "echo ran", timeout=90)
            threading_timer.join()
            fd = None
            self.assertEqual((r.returncode, r.stdout), (0, "ran\n"), r.stderr)
        finally:
            if fd is not None:
                os.close(fd)

    def test_push_has_a_timeout(self):
        wt = rd_run.resolve_worktree(self.wt)
        from unittest import mock
        with mock.patch.object(rd_run.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired(["git"], 300)):
            with self.assertRaises(rd_run.RunError) as cm:
                rd_run.push({"host": "mini", "rr_push_timeout_s": 300}, wt)
        self.assertIn("did not finish in 300 s", str(cm.exception))

    def test_worktree_lock_wait_repeats_with_the_holder(self):
        self.write_cfg(rr_status_every_s=0.5)
        fds = self.hold_lanes()
        errf = os.path.join(self.d, "err")
        with open(errf, "w") as ef:
            p = subprocess.Popen([RRUN, "true"], cwd=self.wt, env=self.env(), stdout=subprocess.DEVNULL, stderr=ef)
        end = time.time() + 30
        while "still waiting for this worktree" not in self.read(errf):
            self.assertLess(time.time(), end, self.read(errf))
            time.sleep(0.05)
        self.drop(fds)
        self.assertEqual(p.wait(30), 0)


class ReattachStates(RunBase):
    """Phase B round 2 (2026-11-11): what a reattach may conclude, and what it may never do."""

    def test_result_gone_is_76_and_never_re_run(self):
        """The link drops and the worker's spool is gone when we reconnect: the run may have happened,
        so it is exit 76 - not NORUN, not a re-run (the command here is `vitest`-like: safe to repeat)."""
        self.write_cfg(rr_reattach_backoff_s=[0, 0, 0])
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", "echo x >> %s; printf part1; sleep 1; exit 0; vitest" % marker,
                      FAKE_SSH_DROP_ONCE_AT="part1", FAKE_SSH_DROP_FLAG=os.path.join(self.d, "dropped"),
                      FAKE_SSH_WIPE=os.path.join(self.home, "rr", "spool"))
        self.assertEqual(r.returncode, 76, r.stderr)
        self.assertIn("the run's result is lost there", r.stderr)
        self.assertIn("so it is not re-run automatically", r.stderr)
        self.assertNotIn("never ran", r.stderr)
        time.sleep(1.5)
        self.assertEqual(self.read(marker), "x\n")                     # once, never again

    def session(self, run_id="r"):
        s = rd_run.Session({"host": "x"}, [], "ab" * 16, rd_run.Timing(False))
        s.run_id = run_id
        return s

    def test_stderr_cursor_counts_command_bytes_only(self):
        nonce = "ab" * 16
        counted, out = [], io.BytesIO()
        f = rd_run.StatusFilter(nonce, out, lambda line: None, on_bytes=counted.append)
        f.resumable = True
        f.feed(b"abc" + (nonce + " EX").encode())       # a status line cut by the lost link
        f.close()
        self.assertEqual((out.getvalue(), sum(counted)), (b"abc", 3))
        counted[:], out = [], io.BytesIO()
        f = rd_run.StatusFilter(nonce, out, lambda line: None, on_bytes=counted.append)
        f.resumable = True
        f.feed(b"abc" + nonce[:3].encode())              # could be output or a cut tag: the spool has it
        f.close()
        self.assertEqual((out.getvalue(), sum(counted)), (b"abc", 3))
        counted[:], out = [], io.BytesIO()
        f = rd_run.StatusFilter(nonce, out, lambda line: None, on_bytes=counted.append)
        f.feed(b"abc" + nonce[:3].encode())              # not resumable (attached run): shown as before
        f.close()
        self.assertEqual(out.getvalue(), b"abc" + nonce[:3].encode())

    def test_attached_marks_the_run_started(self):
        s = self.session()
        s.on_status("ATTACHED")                          # the first link died before STARTED arrived
        self.assertIsNotNone(s.started)
        s.count_err(5)
        self.assertEqual(s.err_off, 5)

    def test_a_cancel_while_reattached_is_a_stop_never_a_retry(self):
        from unittest import mock
        sess = self.session("0f0f0f0f-0000-4000-8000-000000000000")
        sess.go_sent = True

        class H:
            name = "w"
            cfg = dict(rd_common.DEFAULTS, host="x", rr_reattach_backoff_s=[0, 0, 0])

        def cancelled(self):
            self.first_sig = signal.SIGINT
            return 255
        with mock.patch.object(rd_run.Session, "run", cancelled):
            self.assertIsNone(rd_run.reattach(H, sess))
        self.assertTrue(sess.reattach_stopped)
        self.assertEqual(sess.first_sig, signal.SIGINT)

    def test_a_cancel_beats_a_norun_answer(self):
        """GO was lost, the reconnect stopped the runner before the start (NORUN) - and the user
        cancelled meanwhile: a stop, never another attempt."""
        from unittest import mock
        sess = self.session("0f0f0f0f-0000-4000-8000-000000000000")
        sess.go_sent = True

        class H:
            name = "w"
            cfg = dict(rd_common.DEFAULTS, host="x", rr_reattach_backoff_s=[0, 0, 0])

        def cancelled_norun(self):
            self.first_sig, self.norun = signal.SIGTERM, True
            return 0
        with mock.patch.object(rd_run.Session, "run", cancelled_norun):
            self.assertIsNone(rd_run.reattach(H, sess))
        self.assertTrue(sess.reattach_stopped)
        self.assertEqual(sess.first_sig, signal.SIGTERM)

    def test_an_empty_replan_is_75_never_the_stale_hosts(self):
        from unittest import mock
        rd_pool = rd_run.rd_pool

        class H:
            name = "w"
            cfg = {"host": "w"}
        job = rd_pool.classify(["npx", "tsc", "--noEmit"])
        ctx = rd_run.Ctx(dict(rd_common.DEFAULTS, rr_wait_min=5), {"slug": "s", "top": self.wt, "wt12": "w"},
                         {}, rd_run.Timing(False), time.monotonic(), job, rd_pool.Plan([H], True), [], [])
        h = H()
        empty = rd_pool.Plan([], True, ineligible=[(h, "takes only light jobs (this is heavy)")])
        tried = []

        def busy(ctx_, host, *a, **k):
            tried.append(host)
            return "busy", "w had no free slot after 2 min"
        with mock.patch.object(rd_run, "attempt_on", busy), mock.patch.object(rd_pool, "plan", return_value=empty), \
                mock.patch.object(rd_run.time, "sleep"):
            kind, val = rd_run.host_loop(ctx, [H], ["npx", "tsc", "--noEmit"])
        self.assertEqual((kind, val), ("done", 77))                     # needs-human: fleet.json
        self.assertEqual(val.klass, "needs-human")
        self.assertEqual(len(tried), 1)                                 # never the stale list again


LANE_HOLDER = r"""
import os, sys, time
sys.path.insert(0, %r)
import rdmods
rd_run = rdmods.owner("rrun")
wt12, mode, wait, out, release, fleet = sys.argv[1:7]
cfg = {"rr_status_every_s": 0.3, "fleet_path": fleet}
try:
    got = rd_run.take_wt_lanes(wt12, float(wait), cfg, exclusive=mode in ("ex", "shard-ex"))
except rd_run.WorktreeBusy as e:
    open(out, "w").write("busy %%s" %% e)
    os._exit(72)
if mode in ("shard-sh", "shard-ex"):     # a sharded run's local shard: its marker command, under the run's gate
    job = {"cls": "normal", "never_local": False}
    ctx = rd_run.Ctx(cfg, {"wt12": wt12}, {}, rd_run.Timing(False), time.monotonic(), job,
                     rd_run.rd_pool.Plan([], True), (), [])
    t = time.time()
    sink = rd_run.Sink(rd_run.std_stream("stdout"))
    rc = rd_run.run_local_shard(ctx, ["/bin/sh", "-c", "touch %%s.ran; while [ ! -e %%s ]; do sleep 0.05; done"
                                      %% (out, release)], sink, sink, "no worker took it")
    open(out + ".span", "w").write("%%f %%f" %% (t, time.time()))
    open(out, "w").write("got %%s rc=%%d mode=%%s" %% (got, int(rc), rd_run.WT["mode"]))
    while not os.path.exists(release + ".end"):
        time.sleep(0.05)
    os._exit(0)
open(out, "w").write("got %%s" %% got)
while not os.path.exists(release):
    time.sleep(0.05)
os._exit(0)          # skip rdmods' atexit checks: they judge this child's temp HOME, not the suite
""" % os.path.dirname(os.path.abspath(__file__))


class WorktreeLanes(RunBase):
    """Phase C1 (2026-11-13): up to fleet.json wt_lanes (3) rruns of one worktree run at once, each with
    its own worker mirror and push ref; a 4th waits and says why; a run that writes into the worktree
    holds the gate exclusive; nothing shared is corrupted."""

    def setUp(self):
        super().setUp()
        # 6 slots on the fake worker: only the worktree lanes limit these runs
        self.write_cfg(rr_slots=6, rr_slots_base=6, rr_status_every_s=0.5)
        self.git("-C", self.wt, "update-ref", "refs/remotes/origin/main", "HEAD")   # a shared base ref
        self.wt12 = rd_run.resolve_worktree(self.wt)["wt12"]

    def wait_for(self, cond, what, secs=40):
        end = time.time() + secs
        while not cond():
            self.assertLess(time.time(), end, what)
            time.sleep(0.05)

    def job(self, i, errf):
        """An rrun that marks its start, drops a file in its checkout, waits for `go`, then lists the
        marks its checkout holds (a shared checkout would show another job's) and the overlay file."""
        cmd = ("touch %(d)s/start-%(i)s; echo %(i)s > mark-%(i)s; while [ ! -e %(d)s/go ]; do sleep 0.05; done; "
               "echo marks: $(ls mark-* | tr '\\n' ' '); echo overlay: $(cat new.txt)" % {"d": self.d, "i": i})
        with open(errf, "w") as ef:
            return subprocess.Popen([RRUN, "/bin/sh", "-c", cmd], cwd=self.wt, env=self.env(),
                                    stdout=subprocess.PIPE, stderr=ef, text=True)

    def started(self, i):
        return os.path.exists(os.path.join(self.d, "start-%s" % i))

    def test_three_run_at_once_a_fourth_waits_and_says_why_nothing_shared_breaks(self):
        wfile(os.path.join(self.wt, "new.txt"), "untracked-v1\n")           # shipped by every overlay
        errs = [os.path.join(self.d, "err-%d" % i) for i in range(4)]
        ps = [self.job(i, errs[i]) for i in range(3)]
        self.wait_for(lambda: all(self.started(i) for i in range(3)), "3 jobs never ran at once")
        p4 = self.job(3, errs[3])
        self.wait_for(lambda: "waiting for this worktree" in self.read(errs[3]),
                      "the 4th never said it waits")
        time.sleep(1.0)
        self.assertFalse(self.started(3))                                   # it really waits
        err4 = self.read(errs[3])
        self.assertIn("this worktree runs at most 3 rrun jobs at once (fleet.json wt_lanes); 3 running", err4)
        self.assertRegex(err4, r"; waited \d+ s \(/bin/sh -c 'touch")      # how long + names the holders
        self.assertIn("on mini, running", err4)
        self.assertIn("gives up after", err4)
        open(os.path.join(self.d, "go"), "w").close()
        outs = []
        for i, p in enumerate(ps + [p4]):
            out, _ = p.communicate(timeout=60)
            self.assertEqual(p.returncode, 0, self.read(errs[i]))
            self.assertIn("rrun: pass (exit 0 on mini", self.read(errs[i]))   # never a local fallback
            self.assertNotIn("git push", self.read(errs[i]))                  # no push failed (ref locks)
            outs.append(out)
        for i in range(3):                                                  # own checkout each: own mark only
            self.assertIn("marks: mark-%d\n" % i, outs[i])
            self.assertIn("overlay: untracked-v1\n", outs[i])
        # the 4th ran on a freed lane: its checkout is one of the three, cleaned for it (git clean)
        self.assertIn("marks: mark-3\n", outs[3])
        # three mirrors, three refs: lane 0 = the worktree's own, lanes 1-2 their own ids
        ids = [rd_run.lane_mirror_id(self.wt12, k) for k in range(3)]
        self.assertEqual(ids[0], self.wt12)
        self.assertEqual(len(set(ids)), 3)
        w2 = os.path.join(self.home, "rr", "w2")
        slug = rd_run.resolve_worktree(self.wt)["slug"]
        self.assertEqual(sorted(n for n in os.listdir(w2) if not n.startswith(".")),
                         sorted("%s-%s" % (slug, x) for x in ids))
        bare = os.path.join(self.home, "rr", "git", slug + ".git")
        head = self.git("-C", self.wt, "rev-parse", "HEAD").strip()
        refs = self.git("-C", bare, "for-each-ref", "--format=%(refname) %(objectname)", "refs/").split("\n")
        for x in ids:
            self.assertIn("refs/rrun/%s %s" % (x, head), refs)
        self.assertIn("refs/remotes/origin/main %s" % head, refs)           # the shared base ref, intact
        self.assertEqual(self.git("-C", bare, "fsck", "--no-progress"), "")
        # both waits, apart: route.log lock_s / slot_s (client), runs.log lock_s / slot_s (worker)
        route = self.read(os.path.join(self.home, ".local", "state", "rdocker", "route.log"))
        locks = [float(x) for x in __import__("re").findall(r"\tlock_s=([\d.]+)", route)]
        self.assertEqual(len(locks), 4, route)
        self.assertGreaterEqual(max(locks), 1.0)                            # the 4th's lane wait
        self.assertEqual(len(__import__("re").findall(r" slot_s=[\d.]+", route)), 4, route)
        runs = self.read(os.path.join(self.home, "rr", "log", "runs.log"))
        self.assertEqual(len(__import__("re").findall(r" node=\S+ lock_s=[\d.]+ slot_s=[\d.]+\n", runs)), 4, runs)

    def holder(self, mode="one", wait=30, tag="h", fleet="/nonexistent"):
        out, release = os.path.join(self.d, "out-" + tag), os.path.join(self.d, "rel-" + tag)
        p = subprocess.Popen([sys.executable, "-c", LANE_HOLDER, self.wt12, mode, str(wait), out, release, fleet],
                             env=self.env(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        return p, out, release

    def got(self, out):
        return os.path.exists(out) and self.read(out).startswith("got")

    def test_gate_a_writer_waits_for_running_jobs_and_jobs_wait_for_a_writer(self):
        j, j_out, j_rel = self.holder("one", tag="j")                       # a pool job runs
        self.wait_for(lambda: self.got(j_out), "job never started")
        w, w_out, w_rel = self.holder("ex", tag="w")                        # a writer comes
        time.sleep(1.5)
        self.assertFalse(os.path.exists(w_out))                             # waits for the job
        open(j_rel, "w").close()
        self.wait_for(lambda: self.got(w_out), "the writer never got the worktree")
        self.assertEqual(self.read(w_out), "got [0]")
        k, k_out, k_rel = self.holder("one", tag="k")                       # lanes 1-2 free, but a writer runs
        time.sleep(1.5)
        self.assertFalse(os.path.exists(k_out))
        self.assertIn("another rrun is writing into this worktree",       # says why it waits
                      self.read_err_until(k, "another rrun is writing into this worktree"))
        open(w_rel, "w").close()
        self.wait_for(lambda: self.got(k_out), "the job never ran after the writer")
        open(k_rel, "w").close()
        for p in (j, w, k):
            self.assertEqual(p.wait(10), 0)
        # a writer that never gets in: exit 72 path (WorktreeBusy), bounded
        j, j_out, j_rel = self.holder("one", tag="j2")
        self.wait_for(lambda: self.got(j_out), "job never started")
        w, w_out, _ = self.holder("ex", wait=1.5, tag="w2")
        self.assertEqual(w.wait(20), 72)
        self.assertIn("other rruns from this worktree kept running after 2 s", self.read(w_out))
        open(j_rel, "w").close()

    def read_err_until(self, p, text, secs=10):
        buf, end = "", time.time() + secs
        os.set_blocking(p.stderr.fileno(), False)
        while text not in buf and time.time() < end:
            chunk = p.stderr.read()
            buf += chunk or ""
            time.sleep(0.1)
        return buf

    def test_a_wt_lanes_change_while_running_never_breaks_exclusivity(self):
        three = os.path.join(self.d, "fleet3.json")
        one = os.path.join(self.d, "fleet1.json")
        with open(os.path.join(rdmods.STAGE, "fleet.json")) as f:
            doc = json.load(f)
        for path, n in ((three, 3), (one, 1)):
            with open(path, "w") as f:
                json.dump(dict(doc, wt_lanes=n), f)
        hs = [self.holder("one", tag="l%d" % i, fleet=three) for i in range(3)]
        for _p, out, _r in hs:
            self.wait_for(lambda out=out: self.got(out), "a lane holder never started")
        lane2 = next(h for h in hs if self.read(h[1]) == "got [2]")
        for h in hs:
            if h is not lane2:
                open(h[2], "w").close()                                       # only lane 2 still runs
        # fleet.json now says 1 lane: a writer still waits for the run on lane 2 (the gate, not lane count)
        w, w_out, w_rel = self.holder("ex", tag="w", fleet=one)
        time.sleep(1.5)
        self.assertFalse(os.path.exists(w_out))
        # ...and a 1-lane job may run on lane 0 meanwhile (lane 2 is outside its range, not a conflict)
        j, j_out, j_rel = self.holder("one", tag="j", fleet=one)
        self.wait_for(lambda: self.got(j_out), "a 1-lane job never ran")
        self.assertEqual(self.read(j_out), "got [0]")
        open(lane2[2], "w").close()
        open(j_rel, "w").close()
        self.wait_for(lambda: self.got(w_out), "the writer never got in")
        open(w_rel, "w").close()
        # raised back to 3 while a writer runs: a 3-lane job still waits for it
        w, w_out, w_rel = self.holder("ex", tag="w3", fleet=one)
        self.wait_for(lambda: self.got(w_out), "writer never started")
        j, j_out, j_rel = self.holder("one", tag="j3", fleet=three)
        time.sleep(1.5)
        self.assertFalse(os.path.exists(j_out))
        open(w_rel, "w").close()
        self.wait_for(lambda: self.got(j_out), "the job never ran after the writer")
        open(j_rel, "w").close()

    def gate_free_for_sh(self):
        st = os.path.join(self.home, ".local", "state", "rdocker", "rrun-%s.gate" % self.wt12)
        fd = os.open(st, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            return True
        except OSError:
            return False
        finally:
            os.close(fd)

    def test_a_shared_sharded_run_never_runs_a_shard_locally(self):
        p, out, rel = self.holder("shard-sh", tag="s")
        self.wait_for(lambda: os.path.exists(out), "the shard never ended")
        self.assertRegex(self.read(out), r"^got \[0\] rc=75 mode=sh$")      # infra, and the gate never moved
        self.assertFalse(os.path.exists(out + ".ran"))                      # the command never ran here
        open(rel + ".end", "w").close()
        self.assertEqual(p.wait(10), 0)

    def test_an_exclusive_sharded_run_keeps_ex_through_its_local_shard_and_after(self):
        p, out, rel = self.holder("shard-ex", tag="x")
        self.wait_for(lambda: os.path.exists(out + ".ran"), "the local shard never ran")
        self.assertFalse(self.gate_free_for_sh())                           # EX while the shard runs
        open(rel, "w").close()
        self.wait_for(lambda: os.path.exists(out), "the shard never ended")
        self.assertEqual(self.read(out), "got [0] rc=0 mode=ex")
        self.assertFalse(self.gate_free_for_sh())                           # still EX after it: copy-back next
        open(rel + ".end", "w").close()
        self.assertEqual(p.wait(10), 0)
        self.assertTrue(self.gate_free_for_sh())

    def test_two_exclusive_runs_local_shards_never_overlap(self):
        a, a_out, a_rel = self.holder("shard-ex", tag="sa")
        b, b_out, b_rel = self.holder("shard-ex", tag="sb")
        self.wait_for(lambda: os.path.exists(a_out + ".ran") or os.path.exists(b_out + ".ran"), "no shard ran")
        time.sleep(1.5)
        first, second = ((a_out, a_rel), (b_out, b_rel)) if os.path.exists(a_out + ".ran") else \
            ((b_out, b_rel), (a_out, a_rel))
        self.assertFalse(os.path.exists(second[0] + ".ran"))                # the other waits for the gate
        open(first[1], "w").close()
        open(first[1] + ".end", "w").close()
        self.wait_for(lambda: os.path.exists(second[0] + ".ran"), "the second local shard never ran")
        open(second[1], "w").close()
        open(second[1] + ".end", "w").close()
        self.assertEqual((a.wait(10), b.wait(10)), (0, 0))
        s1 = [float(x) for x in self.read(first[0] + ".span").split()]
        s2 = [float(x) for x in self.read(second[0] + ".span").split()]
        self.assertLessEqual(s1[1], s2[0])                                  # one after the other

    def test_no_path_changes_the_gate_mode_mid_run(self):
        """The mode is set once per run (take_wt_lanes) and cleared only on release: a held gate cannot be
        taken again, and no other code assigns the mode or converts a gate flock."""
        import re
        src = open(os.path.join(rdmods.STAGE, "rd_run.py")).read()
        body = {}
        for m in re.finditer(r"^def (\w+)\(.*?(?=^def |^class |\Z)", src, re.S | re.M):
            body[m.group(1)] = m.group(0)
        setters = sorted(n for n, b in body.items() if re.search(r'WT\["mode"\]\s*=(?!=)|WT\.update\(.*\bmode=', b))
        self.assertEqual(setters, ["release_wt_lanes", "take_wt_lanes"])
        gate_flocks = sorted(n for n, b in body.items() if re.search(r"flock\((gate|WT\[\"gate\"\])", b))
        self.assertEqual(gate_flocks, [])                                   # only via _flock_nb, in take_wt_lanes
        self.assertEqual(sorted(n for n, b in body.items() if "_flock_nb(gate" in b), ["take_wt_lanes"])
        p, out, rel = self.holder("one", tag="t")
        self.wait_for(lambda: self.got(out), "holder never started")
        open(rel, "w").close()
        p.wait(10)
        code = ("import sys; sys.path.insert(0, %r); import rdmods, os; r = rdmods.owner('rrun')\n"
                "c = {'fleet_path': '/nonexistent'}; r.take_wt_lanes('%s', 5, c)\n"
                "try:\n    r.take_wt_lanes('%s', 5, c, exclusive=True); print('converted', flush=True)\n"
                "except RuntimeError as e:\n    print('refused', r.WT['mode'], flush=True)\nos._exit(0)\n"
                % (os.path.dirname(os.path.abspath(__file__)), self.wt12, self.wt12))
        r = subprocess.run([sys.executable, "-c", code], env=self.env(), capture_output=True, text=True, timeout=30)
        self.assertEqual(r.stdout.strip(), "refused sh", r.stderr)

    def test_build_with_outputs_and_local_fallback_hold_the_worktree_alone(self):
        h, h_out, h_rel = self.holder("one", tag="d")                       # another rrun on lane 0
        self.wait_for(lambda: os.path.exists(h_out), "holder never started")
        # a run whose push fails falls back to this machine, in the worktree: it must wait for lane 0
        errf = os.path.join(self.d, "err-local")
        marker = os.path.join(self.d, "ran-local")
        with open(errf, "w") as ef:
            p = subprocess.Popen([RRUN, "/bin/sh", "-c", 'touch %s; echo "mode=$RDOCKER_MODE"' % marker],
                                 cwd=self.wt, env=self.env(RRUN_GIT_URL=os.path.join(self.d, "nope", "x.git")),
                                 stdout=subprocess.PIPE, stderr=ef, text=True)
        self.wait_for(lambda: "this run writes into the worktree" in self.read(errf), "the local run never waited")
        time.sleep(0.5)
        self.assertFalse(os.path.exists(marker))
        open(h_rel, "w").close()
        out, _ = p.communicate(timeout=60)
        self.assertEqual((p.returncode, out), (0, "mode=local\n"), self.read(errf))
        self.assertEqual(h.wait(10), 0)
        # a build that copies outputs back (--outputs) runs alone from the start
        h, h_out, h_rel = self.holder("one", tag="e")
        self.wait_for(lambda: os.path.exists(h_out), "holder never started")
        errf = os.path.join(self.d, "err-build")
        with open(errf, "w") as ef:
            p = subprocess.Popen([RRUN, "--outputs", "dist", "/bin/sh", "-c", "mkdir -p dist && echo b > dist/a.txt"],
                                 cwd=self.wt, env=self.env(), stdout=subprocess.PIPE, stderr=ef, text=True)
        self.wait_for(lambda: "this run writes into the worktree" in self.read(errf), "the build never waited")
        self.assertFalse(os.path.exists(os.path.join(self.wt, "dist")))
        open(h_rel, "w").close()
        p.communicate(timeout=60)
        self.assertEqual(p.returncode, 0, self.read(errf))
        self.assertEqual(self.read(os.path.join(self.wt, "dist", "a.txt")), "b\n")

    def test_a_slot_wait_is_logged_as_slot_s_not_lock_s(self):
        import re
        import threading
        self.write_cfg(rr_slots=1, rr_slots_base=1, rr_status_every_s=0.5)
        slots = os.path.join(self.home, "rr", "slots")
        os.makedirs(slots)
        fd = os.open(os.path.join(slots, "0"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)                                      # another job holds the slot
        t = threading.Timer(2.5, os.close, [fd])
        t.start()
        r = self.rrun("/bin/sh", "-c", "echo ran")
        t.join()
        self.assertEqual((r.returncode, r.stdout), (0, "ran\n"), r.stderr)
        route = self.read(os.path.join(self.home, ".local", "state", "rdocker", "route.log"))
        # the slot was held 2.5 s from launch; the runner's wait starts after the push + overlay
        self.assertGreaterEqual(float(re.search(r" slot_s=([\d.]+)", route).group(1)), 1.0, route)
        self.assertLess(float(re.search(r"\tlock_s=([\d.]+)", route).group(1)), 1.0, route)
        runs = self.read(os.path.join(self.home, "rr", "log", "runs.log"))
        m = re.search(r" wait_s=([\d.]+) .* lock_s=([\d.]+) slot_s=([\d.]+)\n", runs)
        self.assertGreaterEqual(float(m.group(3)), 1.0, runs)
        self.assertLess(float(m.group(2)), 1.0, runs)
        self.assertGreaterEqual(float(m.group(1)), float(m.group(3)))      # wait_s keeps its meaning (both)

    def test_a_push_lock_timeout_fails_the_attempt_and_never_pushes(self):
        from unittest import mock
        wt = rd_run.resolve_worktree(self.wt)
        cfg = {"host": "mini", "rr_root": "rr", "rr_push_timeout_s": 1, "rr_base_branches": []}
        lk = rd_run.push_lock("mini", 30).__enter__()                       # another push holds it
        real = subprocess.run
        calls = []

        def spy(args, *a, **kw):
            calls.append(list(args))
            return real(args, *a, **kw)
        try:
            with mock.patch.object(rd_run.subprocess, "run", spy):
                with self.assertRaises(rd_run.RunError) as cm:
                    rd_run.push(cfg, wt)
        finally:
            lk.__exit__(None, None, None)
        self.assertIn("another push to mini from this Mac did not finish in 1 s", str(cm.exception))
        self.assertFalse([c for c in calls if "push" in c])                 # git push never ran

    def test_lane_ids_never_collide(self):
        ids = [rd_run.lane_mirror_id(self.wt12, k, n) for k in range(8) for n in range(8)]
        self.assertEqual(len(set(ids)), 64)
        self.assertTrue(all(__import__("re").match(r"^[0-9a-f]{12}$", x) for x in ids))
        self.assertEqual(rd_run.lane_mirror_id(self.wt12, 0, 2), rd_run.short_hash("%s:lane2" % self.wt12, 12))

    def test_a_push_waits_for_another_processes_push_to_that_worker(self):
        """push_lock is cross-process: while another process pushes to this worker, ours waits."""
        st = os.path.join(self.home, ".local", "state", "rdocker")
        os.makedirs(st, exist_ok=True)
        name = os.path.basename(rd_run.push_lock(rd_common.DEFAULTS["host"]).path)   # push-<host>.lock
        fd = os.open(os.path.join(st, name), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)                                      # "another rrun is pushing"
        p = self.popen("/bin/sh", "-c", "echo ran")
        time.sleep(2.0)
        log = self.read(self.sshlog) if os.path.exists(self.sshlog) else ""
        self.assertNotIn("receive-pack", log)                               # it has not pushed
        self.assertIsNone(p.poll())
        os.close(fd)
        out, err = p.communicate(timeout=60)
        self.assertEqual((p.returncode, out), (0, "ran\n"), err)
        self.assertIn("receive-pack", self.read(self.sshlog))


if __name__ == "__main__":
    unittest.main()
