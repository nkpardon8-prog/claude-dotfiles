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
if os.environ.get("FAKE_SSH_DOWN"):
    sys.stderr.write("ssh: connect to host %s port 22: Operation timed out\n" % args[i])
    sys.exit(255)
if os.environ.get("FAKE_SSH_DROP") and "perl" in cmd:
    subprocess.run(["/bin/sh", "-c", cmd])
    sys.exit(255)
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
os.execv("/bin/sh", ["/bin/sh", "-c", cmd])
'''
FAKE_DOCKER = "#!/bin/sh\nexit 0\n"


def wfile(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


class RunTest(unittest.TestCase):
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
        self.git("init", "-q", self.wt)
        self.git("-C", self.wt, "add", "-A")
        self.git("-C", self.wt, "commit", "-qm", "init")

    def tearDown(self):
        shutil.rmtree(self.d, True)

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

    def mirror(self):
        w = os.path.join(self.home, "rr", "w")
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
        r = self.rrun("/bin/sh", "-c", "cd .. && find . -path ./.git -prune -o -type f -print | sort; "
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
        r = self.rrun("/bin/sh", "-c", 'echo "mode=$RDOCKER_MODE"; exit 4', FAKE_SSH_DOWN="1")
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertEqual(r.stdout, "mode=local\n")
        self.assertIn("running on the laptop instead", r.stderr)
        r = self.rrun("/bin/sh", "-c", "echo ran", FAKE_SSH_DOWN="1", RRUN_STRICT="1")
        self.assertEqual(r.returncode, 75)
        self.assertEqual(r.stdout, "")
        # a push to a missing repo (mini fine, push broken) is the same "before anything started"
        r = self.rrun("/bin/sh", "-c", "echo ran", RRUN_GIT_URL=os.path.join(self.d, "nope", "x.git"))
        self.assertEqual((r.returncode, r.stdout), (0, "ran\n"), r.stderr)
        self.assertIn("git push to the mini failed", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, "rr", "w")))

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

    def test_connection_lost_after_go_is_75_and_never_reruns(self):
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", "echo x >> %s" % marker, FAKE_SSH_CUT_AFTER_GO="1")
        self.assertEqual(r.returncode, 75, r.stderr)
        self.assertIn("not re-running on the laptop", r.stderr)
        self.assertFalse(os.path.exists(marker))              # GO never arrived: not run anywhere
        self.assertIn("command was not started", r.stderr)    # the runner gave up cleanly

    def test_255_after_started_is_75_and_never_reruns(self):
        marker = os.path.join(self.d, "ran")
        r = self.rrun("/bin/sh", "-c", "echo x >> %s" % marker, FAKE_SSH_DROP="1")
        self.assertEqual(r.returncode, 75, r.stderr)
        self.assertIn("lost the Mac mini mid-run - not re-running on the laptop", r.stderr)
        self.assertEqual(self.read(marker), "x\n")            # exactly one run (the remote one)

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
        cfgd = os.path.join(self.home, ".config", "rdocker")
        os.makedirs(cfgd, exist_ok=True)
        with open(os.path.join(cfgd, "config.json"), "w") as f:
            json.dump({"rr_slots": 1}, f)                    # one slot, so holding it makes rrun wait
        with open(os.path.join(slots, "0.who"), "w") as f:
            f.write("other.repo %d\n" % int(time.time() - 42))
        fd = os.open(os.path.join(slots, "0"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)                       # another run holds the only slot
        errf = os.path.join(self.d, "err")
        with open(errf, "w") as ef:
            p = subprocess.Popen([RRUN, "/bin/sh", "-c", "trap '' INT; touch %s; while :; do sleep 0.1; done"
                                  % ready], cwd=self.wt, env=self.env(), stdout=subprocess.DEVNULL, stderr=ef)
        end = time.time() + 30
        while "waiting for a Mac mini slot" not in self.read(errf):
            self.assertLess(time.time(), end, self.read(errf))
            time.sleep(0.05)
        self.assertIn("held by other.repo for 4", self.read(errf))
        os.close(fd)
        while not os.path.exists(ready):
            self.assertLess(time.time(), end, "remote command never started")
            time.sleep(0.05)
        p.send_signal(signal.SIGINT)                         # ignored by the command
        time.sleep(0.5)
        self.assertIsNone(p.poll())
        p.send_signal(signal.SIGINT)                         # second: stdin closed -> group TERM
        self.assertEqual(p.wait(30), 128 + signal.SIGTERM)
        self.assertEqual(self.read(errf).count("waiting for a Mac mini slot"), 1)

    def test_worktree_lock_serialises(self):
        rr = rd_run.resolve_worktree(self.wt)
        lock = os.path.join(self.home, ".local", "state", "rdocker", "rrun-%s.lock" % rr["wt12"])
        os.makedirs(os.path.dirname(lock), exist_ok=True)
        fd = os.open(lock, os.O_RDWR | os.O_CREAT)
        fcntl.flock(fd, fcntl.LOCK_EX)
        marker = os.path.join(self.d, "ran")
        errf = os.path.join(self.d, "err")
        with open(errf, "w") as ef:
            p = subprocess.Popen([RRUN, "/bin/sh", "-c", "touch %s" % marker], cwd=self.wt,
                                 env=self.env(), stdout=subprocess.DEVNULL, stderr=ef)
        end = time.time() + 30
        while "another rrun from this worktree is running" not in self.read(errf):
            self.assertLess(time.time(), end, "rrun never reported waiting for the worktree lock")
            time.sleep(0.05)
        time.sleep(0.5)
        self.assertFalse(os.path.exists(marker))
        self.assertIsNone(p.poll())
        os.close(fd)
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


if __name__ == "__main__":
    unittest.main()
