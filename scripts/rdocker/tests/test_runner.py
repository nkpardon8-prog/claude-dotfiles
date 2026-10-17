"""rr_runner.pl (the mini side of rrun), run locally with /usr/bin/perl against a temp RR_ROOT.

Real git on a local bare repo; fake npm/npx/node/docker on RR_PATH that log their argv; the
JSON header + overlay tar + heartbeat are fed through stdin exactly as the laptop sends them.
"""
import fcntl
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402

RUNNER = os.path.join(rdmods.STAGE, "rr_runner.pl")
SLUG = "demo-repo.ab12"
WT = "0123456789ab"

FAKE = r"""#!/bin/sh
printf '%%s\n' "$(basename "$0") $*" >> '%(log)s'
case "$(basename "$0") $1" in "npm ci"|"npx prisma") [ -n "$FAKE_NPM_FAIL" ] && { echo "npm ERR! boom" >&2; exit 3; } ;; esac
case "$(basename "$0") $1" in
  "npm ci")
    if [ -n "$FAKE_EUSAGE" ]; then
      echo "npm error code EUSAGE" >&2
      echo "npm error \`npm ci\` can only install packages when your package.json and package-lock.json or npm-shrinkwrap.json are in sync." >&2
      exit 1
    fi
    if [ -n "$FAKE_ERESOLVE" ]; then
      case " $* " in *" --legacy-peer-deps "*) ;; *) echo "npm ERR! code ERESOLVE" >&2; exit 1 ;; esac
    fi
    rm -rf node_modules && mkdir node_modules ;;
  "npm install") rm -rf node_modules && mkdir node_modules ;;
  "node -v") echo v20.0.0 ;;
  "docker ps") cat '%(dir)s/ps.out' 2>/dev/null ;;
  "docker port") cat '%(dir)s/port.out' 2>/dev/null ;;
esac
case "$(basename "$0") $*" in "docker "*" run "*" -d "*) echo cid123 ;; esac
exit 0
"""


def tar_of(members):
    """members: list of (name, bytes | None for a dir | ("sym", target) | ("hard", target))."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data in members:
            ti = tarfile.TarInfo(name)
            if data is None:
                ti.type, ti.mode = tarfile.DIRTYPE, 0o755
                t.addfile(ti)
            elif isinstance(data, tuple):
                ti.type = tarfile.SYMTYPE if data[0] == "sym" else tarfile.LNKTYPE
                ti.linkname = data[1]
                t.addfile(ti)
            else:
                ti.size, ti.mode = len(data), 0o644
                t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def wfile(path, text):
    with open(path, "w") as f:
        f.write(text)


class Result:
    def __init__(self, rc, out, err):
        self.rc, self.out, self.err = rc, out, err


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="rr-", dir=rdmods.TEST_HOME)
        self.home = os.path.join(self.d, "home")
        self.root = os.path.join(self.d, "rr")
        self.bin = os.path.join(self.d, "bin")
        self.log = os.path.join(self.d, "calls.log")
        for p in (self.home, self.bin):
            os.makedirs(p)
        for name in ("npm", "npx", "node", "docker", "tmutil"):
            p = os.path.join(self.bin, name)
            with open(p, "w") as f:
                f.write(FAKE % {"log": self.log, "dir": self.d})
            os.chmod(p, 0o755)
        # a source repo -> bare repo under RR_ROOT/git (what the laptop's push produces)
        self.src = os.path.join(self.d, "src")
        os.makedirs(os.path.join(self.src, "prisma"))
        files = {".gitignore": "node_modules\n.env*\n", "package.json":
                 json.dumps({"dependencies": {"@prisma/client": "5"}}), "package-lock.json": "{}",
                 "prisma/schema.prisma": "model A {}", "del.txt": "x", "keep.txt": "k"}
        for n, c in files.items():
            with open(os.path.join(self.src, n), "w") as f:
                f.write(c)
        self.git("init", "-q", self.src)
        self.git("-C", self.src, "add", "-A")
        self.git("-C", self.src, "commit", "-qm", "init")
        self.sha = self.git("-C", self.src, "rev-parse", "HEAD").strip()
        os.makedirs(os.path.join(self.root, "git"))
        self.git("clone", "-q", "--bare", self.src, os.path.join(self.root, "git", SLUG + ".git"))
        self.mirror = os.path.join(self.root, "w", "%s-%s" % (SLUG, WT))

    def tearDown(self):
        shutil.rmtree(self.d, True)

    def env(self, **extra):
        return rdmods.child_env(self.home, self.bin, RR_ROOT=self.root,
                                RR_PATH=rdmods.safe_path(self.bin),
                                RR_REAL_DOCKER=os.path.join(self.bin, "docker"), **extra)

    def git(self, *args):
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t",
                               "-c", "commit.gpgsign=false"] + list(args), env=self.env(),
                              check=True, capture_output=True, text=True).stdout

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def header(self, argv, **kw):
        h = {"nonce": uuid.uuid4().hex, "repo_slug": SLUG, "wt12": WT, "sha": self.sha,
             "relcwd": "", "argv": argv, "env": {}, "deleted": [], "stamps": {"dirs": [""]},
             "slots": 1, "wait_min": 1, "keep_containers_on_fail": True}
        h.update(kw)
        return h

    def run_runner(self, argv, tar=b"", action=None, timeout=30, go=True, **kw):
        """Feed header + tar like the laptop; when `go`, answer "<nonce> READY" with "GO\\n" (the
        exactly-once handshake). `action(p)` runs after the frames are written."""
        h = self.header(argv, tar_len=len(tar), **kw)
        self.nonce = h["nonce"]
        js = json.dumps(h).encode()
        p = subprocess.Popen(["/usr/bin/perl", RUNNER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=self.env())
        outs, err = {}, []
        self.err_so_far = err
        ready = threading.Event()
        lock = threading.Lock()

        def read_err():
            tag = (self.nonce + " READY\n").encode()
            while True:
                b = os.read(p.stderr.fileno(), 65536)
                if not b:
                    break
                err.append(b)
                if tag in b"".join(err):
                    ready.set()
            ready.set()

        def answer_go():
            ready.wait()
            if go and p.poll() is None:
                try:
                    with lock:
                        p.stdin.write(b"GO\n")
                        p.stdin.flush()
                except (BrokenPipeError, ValueError, OSError):
                    pass
        readers = [threading.Thread(target=lambda: outs.__setitem__("out", p.stdout.read())),
                   threading.Thread(target=read_err), threading.Thread(target=answer_go)]
        try:
            with lock:
                p.stdin.write(b"%d\n" % len(js) + js + tar)
                p.stdin.flush()
        except BrokenPipeError:
            pass
        for t in readers:
            t.start()
        try:
            if action:
                action(p)
        except BrokenPipeError:
            pass
        rc = p.wait(timeout)
        for t in readers:
            t.join()
        p.stdout.close()
        p.stderr.close()
        try:
            p.stdin.close()
        except BrokenPipeError:
            pass
        return Result(rc, outs["out"].decode(), b"".join(err).decode())

    def wait_for(self, path, secs=10):
        end = time.time() + secs
        while not os.path.exists(path):
            self.assertLess(time.time(), end, "timed out waiting for " + path)
            time.sleep(0.05)

    # -------------------------------------------------------------------------------- basics
    def test_happy_path_argv_and_env_round_trip(self):
        args = ["a b", "q'\"", "line1\nline2", "$(echo hi)", "`id`", "*", ""]
        r = self.run_runner(["printf", "[%s]\\n"] + args)
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(r.out, "".join("[%s]\n" % a for a in args))
        self.assertEqual(r.err.count("%s STARTED" % self.nonce), 1)
        r = self.run_runner(["/bin/sh", "-c", 'printf "%s|%s|%s" "$FOO" "$RRUN_REMOTE" "$PWD"'],
                            env={"FOO": "x y $(z) 'q'"})
        self.assertEqual(r.out, "x y $(z) 'q'|1|" + os.path.realpath(self.mirror))

    def test_rc_passes_through_and_relcwd(self):
        os.makedirs(os.path.join(self.src, "sub"))
        r = self.run_runner(["/bin/sh", "-c", "exit 7"])
        self.assertEqual(r.rc, 7)
        r = self.run_runner(["/bin/pwd"], relcwd="prisma")
        self.assertEqual(r.out.strip(), os.path.realpath(os.path.join(self.mirror, "prisma")))
        for bad in ("../x", "/etc", "a/../../b"):
            self.assertEqual(self.run_runner(["true"], relcwd=bad).rc, 65, bad)

    def test_spoofed_status_is_distinguishable(self):
        fake = uuid.uuid4().hex
        r = self.run_runner(["/bin/sh", "-c", 'echo "%s STARTED"; echo "%s STARTED" >&2; '
                             'echo "RRUN rc=0"; exit 3' % (fake, fake)])
        self.assertEqual(r.rc, 3)
        own = [ln for ln in r.err.splitlines() if ln.startswith(self.nonce + " ")]
        self.assertEqual(own, [self.nonce + " READY", self.nonce + " STARTED"])
        self.assertNotIn(self.nonce, r.out)

    def test_bad_header_fields_rejected(self):
        for kw in ({"repo_slug": "../x"}, {"wt12": ".."}, {"sha": "abc"}, {"nonce": "zz"},
                   {"argv": []}, {"argv": ["a\0b"]}, {"env": {"A B": "1"}}):
            argv = kw.pop("argv", ["true"])
            self.assertEqual(self.run_runner(argv, **kw).rc, 65, kw)
        self.assertFalse(os.path.exists(os.path.join(self.root, "w")))

    def test_missing_bare_repo_is_a_clear_error(self):
        r = self.run_runner(["true"], repo_slug="nope")
        self.assertEqual(r.rc, 69)
        self.assertIn("bare repo", r.err)

    # ------------------------------------------------------------------------ heartbeat
    def test_stdin_eof_kills_child_and_grandchild(self):
        pids = os.path.join(self.d, "pids")
        script = 'sleep 60 & echo $! > %s.g; echo $$ > %s.c; sleep 60' % (pids, pids)
        tar = tar_of([(".env", b"SECRET=1\n")])

        def act(p):
            self.wait_for(pids + ".c")
            self.wait_for(pids + ".g")
            p.stdin.close()
        t0 = time.time()
        r = self.run_runner(["/bin/sh", "-c", script], tar=tar, action=act)
        self.assertLess(time.time() - t0, 15)
        self.assertEqual(r.rc, 128 + 15)
        for suffix in (".c", ".g"):
            with open(pids + suffix) as f:
                pid = int(f.read())
            deadline = time.time() + 5
            while time.time() < deadline:
                try:
                    os.kill(pid, 0)
                    time.sleep(0.05)
                except ProcessLookupError:
                    break
            else:
                self.fail("pid %d (%s) survived" % (pid, suffix))
        self.assertFalse(os.path.exists(os.path.join(self.mirror, ".env")))

    def test_heartbeat_timeout_kills(self):
        r = self.run_runner(["sleep", "30"], hb_timeout=1, timeout=15)
        self.assertEqual(r.rc, 128 + 15)

    def test_int_line_forwards_sigint(self):
        ready = os.path.join(self.d, "ready")
        script = "trap 'echo GOT-INT; exit 9' INT; touch %s; sleep 30" % ready
        wfile(os.path.join(self.d, "ps.out"), "pg1\n")

        def act(p):
            self.wait_for(ready)
            p.stdin.write(b"..INT\n")
            p.stdin.flush()
        r = self.run_runner(["/bin/sh", "-c", script], action=act)
        self.assertEqual(r.rc, 9)
        self.assertIn("GOT-INT", r.out)
        self.assertIn("docker rm -f -v pg1", self.calls())   # interrupted => removed

    # -------------------------------------------------------------------------- overlay
    def test_overlay_written_env_files_0600_then_deleted(self):
        tar = tar_of([(".env", b"A=1\n"), ("apps", None), ("apps/.env.local", b"B=2\n"),
                      ("new dir/untracked [id].txt", b"u"), ("keep.txt", b"dirty")])
        r = self.run_runner(["/bin/sh", "-c", "stat -f %Lp .env apps/.env.local; cat keep.txt "
                             "'new dir/untracked [id].txt'"], tar=tar)
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(r.out, "600\n600\ndirtyu")
        self.assertFalse(os.path.exists(os.path.join(self.mirror, ".env")))
        self.assertFalse(os.path.exists(os.path.join(self.mirror, "apps/.env.local")))
        r = self.run_runner(["cat", "keep.txt"])   # checkout -f restores the tracked file
        self.assertEqual(r.out, "k")

    def test_overlay_symlink_dotdot_absolute_rejected(self):
        self.assertEqual(self.run_runner(["true"]).rc, 0)   # mirror exists
        outside = os.path.join(self.d, "outside-%s" % uuid.uuid4().hex)
        for bad in [("link", ("sym", "/etc/passwd")), ("hl", ("hard", "keep.txt")),
                    ("../escape.txt", b"x"), ("a/../../escape.txt", b"x"), (outside, b"x"),
                    (".git", b"gitdir: /tmp\n")]:
            r = self.run_runner(["true"], tar=tar_of([("good.txt", b"g"), bad]))
            self.assertEqual(r.rc, 65, (bad, r.err))
            self.assertFalse(os.path.lexists(os.path.join(self.mirror, "good.txt")), bad)
            self.assertFalse(os.path.lexists(os.path.join(self.mirror, "link")))
        self.assertFalse(os.path.exists(outside))
        self.assertFalse(os.path.exists(os.path.join(self.root, "w", "escape.txt")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "escape.txt")))

    def test_overlay_through_symlinked_dir_refused(self):
        os.symlink(self.d, os.path.join(self.src, "out"))
        self.git("-C", self.src, "add", "out")
        self.git("-C", self.src, "commit", "-qm", "link")
        self.git("-C", self.src, "push", "-q", os.path.join(self.root, "git", SLUG + ".git"), "HEAD:refs/heads/x")
        self.sha = self.git("-C", self.src, "rev-parse", "HEAD").strip()
        r = self.run_runner(["true"], tar=tar_of([("out/pwned.txt", b"x")]))
        self.assertEqual(r.rc, 65, r.err)
        self.assertFalse(os.path.exists(os.path.join(self.d, "pwned.txt")))
        open(os.path.join(self.d, "sentinel"), "w").close()
        r = self.run_runner(["true"], deleted=["out/sentinel"])
        self.assertEqual(r.rc, 65, r.err)
        self.assertTrue(os.path.exists(os.path.join(self.d, "sentinel")))   # not unlinked via the link

    def test_deleted_removed_and_validated(self):
        r = self.run_runner(["/bin/sh", "-c", "test -e del.txt; echo $?; test -e keep.txt; echo $?"],
                            deleted=["del.txt"])
        self.assertEqual(r.out, "1\n0\n")
        self.assertEqual(self.run_runner(["true"], deleted=["../keep.txt"]).rc, 65)
        self.assertEqual(self.run_runner(["true"], deleted=[".git"]).rc, 65)

    def test_git_clean_keeps_node_modules(self):
        r = self.run_runner(["/bin/sh", "-c", "mkdir -p node_modules/x && touch node_modules/x/f untracked.txt"])
        self.assertEqual(r.rc, 0, r.err)
        r = self.run_runner(["/bin/sh", "-c", "ls node_modules/x; test -e untracked.txt || echo gone"])
        self.assertEqual(r.out, "f\ngone\n")

    # ----------------------------------------------------------------------------- deps
    def test_deps_stamps(self):
        npm_ci = lambda: [c for c in self.calls() if c.startswith("npm ci")]          # noqa: E731
        gen = lambda: [c for c in self.calls() if c == "npx prisma generate"]        # noqa: E731
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        self.assertEqual((len(npm_ci()), len(gen())), (1, 1))
        self.assertEqual(npm_ci()[0], "npm ci --no-audit --no-fund")
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        self.assertEqual((len(npm_ci()), len(gen())), (1, 1))          # warm: nothing runs
        self.run_runner(["true"], tar=tar_of([("prisma/schema.prisma", b"model B {}")]))
        self.assertEqual((len(npm_ci()), len(gen())), (1, 2))          # schema only => generate
        self.run_runner(["true"], tar=tar_of([("package-lock.json", b'{"v":2}')]))
        self.assertEqual(len(npm_ci()), 2)                              # lockfile => npm ci

    def test_monorepo_postinstall_generate_and_no_schema_skip(self):
        """dentall layout: server/ has its own lockfile and a postinstall that runs
        `prisma generate --schema ../prisma/schema.prisma`; there is no server/prisma."""
        post = lambda: [c for c in self.calls() if c == "npm run postinstall"]           # noqa: E731
        gen = lambda: [c for c in self.calls() if c == "npx prisma generate"]           # noqa: E731
        pkg = json.dumps({"dependencies": {"@prisma/client": "5"}, "scripts": {
            "postinstall": "prisma generate --schema ../prisma/schema.prisma --generator client"}}).encode()
        srv = [("server/package.json", pkg), ("server/package-lock.json", b"{}")]
        kw = {"relcwd": "server", "stamps": {"dirs": ["server"]}}
        r = self.run_runner(["true"], tar=tar_of(srv), **kw)
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual((post(), gen()), ([], []))      # npm ci just ran postinstall itself
        self.assertEqual(self.run_runner(["true"], tar=tar_of(srv), **kw).rc, 0)
        self.assertEqual((post(), gen()), ([], []))      # warm
        self.run_runner(["true"], tar=tar_of(srv + [("prisma/schema.prisma", b"model C {}")]), **kw)
        self.assertEqual((len(post()), gen()), (1, []))  # schema change -> the package's own generate
        # a prisma package with no schema anywhere it can find: nothing to generate, not a failure
        bare = [("server/package.json", json.dumps({"dependencies": {"@prisma/client": "5"}}).encode()),
                ("server/package-lock.json", b'{"v":3}')]
        r = self.run_runner(["true"], tar=tar_of(bare), **kw)
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(gen(), [])

    def test_out_of_sync_lockfile_falls_back_to_npm_install(self):
        r = self.run_runner(["true"], env={"FAKE_EUSAGE": "1"})
        self.assertEqual(r.rc, 0, r.err)
        self.assertIn("out of sync", r.err)
        npm = [c for c in self.calls() if c.startswith(("npm ci", "npm install"))]
        self.assertEqual(npm, ["npm ci --no-audit --no-fund", "npm install --no-audit --no-fund"])
        self.assertEqual(self.run_runner(["true"], env={"FAKE_EUSAGE": "1"}).rc, 0)
        self.assertEqual(len([c for c in self.calls() if c.startswith("npm ")]), 2)   # warm: no reinstall

    def test_eresolve_retries_with_legacy_peer_deps_and_remembers(self):
        r = self.run_runner(["true"], env={"FAKE_ERESOLVE": "1"})
        self.assertEqual(r.rc, 0, r.err)
        ci = [c for c in self.calls() if c.startswith("npm ci")]
        self.assertEqual(ci, ["npm ci --no-audit --no-fund", "npm ci --no-audit --no-fund --legacy-peer-deps"])
        self.assertTrue(os.path.exists(os.path.join(self.root, "state", SLUG + ".legacy-peer-deps")))
        self.run_runner(["true"], env={"FAKE_ERESOLVE": "1"}, tar=tar_of([("package-lock.json", b"[]")]))
        ci = [c for c in self.calls() if c.startswith("npm ci")]
        self.assertEqual(ci[2:], ["npm ci --no-audit --no-fund --legacy-peer-deps"])

    # ----------------------------------------------------------------------------- slot
    def test_slot_busy_waits_then_73(self):
        os.makedirs(os.path.join(self.root, "slots"))
        with open(os.path.join(self.root, "slots", "0.who"), "w") as f:
            f.write("other-repo %d\n" % (time.time() - 42))
        with open(os.path.join(self.root, "slots", "0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            t0 = time.time()
            r = self.run_runner(["true"], wait_min=0.02)
        self.assertEqual(r.rc, 73)
        self.assertGreaterEqual(time.time() - t0, 1.0)
        lines = [ln for ln in r.err.splitlines() if ln.startswith(self.nonce)]
        self.assertEqual(len(lines), 2, r.err)
        self.assertRegex(lines[0], r" WAIT holder=other-repo age=4[2-4]$")
        self.assertEqual(lines[1], self.nonce + " BUSY")
        self.assertEqual(self.calls(), [])                          # nothing ran
        self.assertEqual(self.run_runner(["true"]).rc, 0)           # lock released => runs

    def test_spare_slot_only_when_the_mini_has_room(self):
        """slots_base always; the extra slots only while memory/load allow (here: forced via limits)."""
        os.makedirs(os.path.join(self.root, "slots"))
        with open(os.path.join(self.root, "slots", "0.who"), "w") as f:
            f.write("other-repo %d\n" % time.time())
        with open(os.path.join(self.root, "slots", "0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            r = self.run_runner(["true"], wait_min=0.02, slots=2, slots_base=1,
                                spare_min_free_pct=101)                 # never "room"
            self.assertEqual(r.rc, 73, r.err)
            r = self.run_runner(["true"], wait_min=0.02, slots=2, slots_base=1,
                                spare_min_free_pct=0, spare_max_load=1000)
            self.assertEqual(r.rc, 0, r.err)        # slot 0 is held: it ran in spare slot 1

    # ------------------------------------------------------------------------ containers
    def test_containers_removed_on_success_kept_on_failure(self):
        wfile(os.path.join(self.d, "ps.out"), "pg1\n")
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        ps = [c for c in self.calls() if c.startswith("docker ps -a --filter label=rdocker.rrun=")]
        self.assertRegex(ps[0], r"^docker ps -a --filter label=rdocker\.rrun=[0-9a-f]{32} --format \{\{\.Names\}\}$")
        self.assertNotIn(self.nonce, ps[0])                         # label token != status nonce
        self.assertIn("docker rm -f -v pg1", self.calls())
        os.remove(self.log)
        r = self.run_runner(["/bin/sh", "-c", "exit 7"])
        self.assertEqual(r.rc, 7)
        self.assertFalse([c for c in self.calls() if c.startswith("docker rm")])
        self.assertIn("%s KEPT pg1" % self.nonce, r.err)

    def test_docker_shim_labels_and_passes_through(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(5)
        port = srv.getsockname()[1]
        wfile(os.path.join(self.d, "port.out"), "5432/tcp -> 0.0.0.0:%d\n" % port)
        script = ("docker run img a; docker --context x run -d img; docker container create img; "
                  "docker ps -a; docker exec c ls '-l a'; command -v docker")
        t0 = time.time()
        r = self.run_runner(["/bin/sh", "-c", script])
        srv.close()
        self.assertEqual(r.rc, 0, r.err)
        self.assertLess(time.time() - t0, 10)
        calls = [c for c in self.calls() if c.startswith("docker ") and " ps -a --filter" not in c]
        lab = "--label " + calls[0].split()[3]
        self.assertRegex(lab, r"^--label rdocker\.rrun=[0-9a-f]{32}$")
        self.assertNotIn(self.nonce, lab)
        self.assertEqual(calls, ["docker run %s img a" % lab, "docker --context x run %s -d img" % lab,
                                 "docker port cid123", "docker container create %s img" % lab,
                                 "docker ps -a", "docker exec c ls -l a"])
        self.assertIn("cid123", r.out)
        shim = r.out.strip().splitlines()[-1]
        self.assertTrue(shim.startswith(os.path.join(self.root, "tmp")), shim)
        self.assertFalse(os.path.exists(shim))                     # per-run dir removed


    # ---------------------------------------------------------------- exactly-once handshake
    def test_no_go_eof_means_no_spawn_and_cleanup(self):
        marker = os.path.join(self.d, "ran")
        tar = tar_of([(".env", b"SECRET=1\n")])

        def act(p):
            end = time.time() + 20
            while (self.nonce + " READY").encode() not in b"".join(self.err_so_far):
                self.assertLess(time.time(), end)
                time.sleep(0.05)
            self.assertTrue(os.path.exists(os.path.join(self.mirror, ".env")))
            time.sleep(0.3)
            p.stdin.close()                                  # laptop gone after READY, before GO
        r = self.run_runner(["/bin/sh", "-c", "touch %s" % marker], tar=tar, action=act, go=False)
        self.assertEqual(r.rc, 130, r.err)
        self.assertFalse(os.path.exists(marker))             # never spawned
        self.assertIn(self.nonce + " READY", r.err)
        self.assertNotIn(self.nonce + " STARTED", r.err)
        self.assertIn("command was not started", r.err)
        self.assertFalse(os.path.exists(os.path.join(self.mirror, ".env")))   # env file deleted
        self.assertFalse(os.path.exists(os.path.join(self.root, "slots", "0.who")))
        self.assertEqual(os.listdir(os.path.join(self.root, "tmp")), [])     # shim dir removed
        with open(os.path.join(self.root, "slots", "0")) as lk:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)  # slot released

    def test_int_before_go_or_heartbeats_only_never_spawn(self):
        marker = os.path.join(self.d, "ran")

        def int_first(p):
            p.stdin.write(b"..INT\n")
            p.stdin.flush()
        r = self.run_runner(["/bin/sh", "-c", "touch %s" % marker], action=int_first, go=False)
        self.assertEqual(r.rc, 130, r.err)
        self.assertFalse(os.path.exists(marker))
        # heartbeats alone keep it waiting; the heartbeat timeout then gives up without spawning
        r = self.run_runner(["/bin/sh", "-c", "touch %s" % marker], go=False, hb_timeout=1, timeout=20)
        self.assertEqual(r.rc, 130, r.err)
        self.assertFalse(os.path.exists(marker))
        # GO between heartbeat dots is recognised
        def dotted_go(p):
            self.wait_for(os.path.join(self.root, "slots", "0.who"))
            p.stdin.write(b"...GO\n.")
            p.stdin.flush()
        r = self.run_runner(["/bin/sh", "-c", "touch %s" % marker], action=dotted_go, go=False)
        self.assertEqual(r.rc, 0, r.err)
        self.assertTrue(os.path.exists(marker))

    def test_nonce_invisible_to_the_command(self):
        r = self.run_runner(["/bin/sh", "-c", "env; cat \"$(command -v docker)\""])
        self.assertEqual(r.rc, 0, r.err)
        self.assertNotIn(self.nonce, r.out)
        self.assertRegex(r.out, r"LABEL='rdocker\.rrun=[0-9a-f]{32}'")

    def test_deps_failure_is_78_and_command_not_started(self):
        marker = os.path.join(self.d, "ran")
        r = self.run_runner(["/bin/sh", "-c", "touch %s" % marker], env={"FAKE_NPM_FAIL": "1"})
        self.assertEqual(r.rc, 78, r.err)
        self.assertIn("npm ci --no-audit --no-fund failed in ./ on the Mac mini (exit 3)", r.err)
        self.assertIn("npm ERR! boom", r.err)
        self.assertNotIn(self.nonce + " READY", r.err)
        self.assertFalse(os.path.exists(marker))

    # ------------------------------------------------------------------------ run log
    def runs_log(self):
        with open(os.path.join(self.root, "log", "runs.log")) as f:
            return f.read().splitlines()

    def test_run_log_one_line_per_run_no_secrets(self):
        r = self.run_runner(["/bin/sh", "-c", "exit 3", "-e", "PGPASSWORD=hunter2", "--env=TOK=sek",
                             "-eK=v2", "SECRET=s3", "--db-password=pw"], env={"API_KEY": "envsek"})
        self.assertEqual(r.rc, 3, r.err)
        os.unlink(os.path.join(self.mirror, "node_modules", ".rr-deps-stamp"))   # force npm ci
        self.run_runner(["true"], env={"FAKE_NPM_FAIL": "1"})
        self.run_runner(["true"], repo_slug="nope")
        self.run_runner(["true"], go=False, hb_timeout=1, timeout=20)
        lines = self.runs_log()
        self.assertEqual(len(lines), 4, lines)
        self.assertRegex(lines[0], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4} repo=%s wt=%s "
                         r"sha=%s outcome=rc=3 prepare_s=\d+\.\d cmd_s=\d+\.\d argv=/bin/sh -c exit 3 "
                         % (SLUG.replace(".", r"\."), WT, self.sha[:12]))
        for secret in ("hunter2", "sek", "v2", "s3", "pw", "envsek", "API_KEY"):
            self.assertNotIn(secret, "\n".join(lines))
        self.assertIn("-e <redacted> --env=<redacted> -e<redacted> SECRET=<redacted> "
                      "--db-password=<redacted>", lines[0])
        self.assertIn("outcome=deps-failed", lines[1])
        self.assertIn("cmd_s=-", lines[1])
        self.assertIn("outcome=refused rc=69", lines[2])
        self.assertIn("outcome=lost", lines[3])
        st = os.stat(os.path.join(self.root, "log"))
        self.assertEqual(st.st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(os.path.join(self.root, "log", "runs.log")).st_mode & 0o777, 0o600)
        # long argv is cut at 120 chars
        self.run_runner(["true", "x" * 500])
        self.assertLess(len(self.runs_log()[-1].split(" argv=", 1)[1]), 130)

    def test_run_log_rotates_and_never_writes_through_links(self):
        logdir = os.path.join(self.root, "log")
        os.makedirs(logdir)
        big = os.path.join(logdir, "runs.log")
        with open(big, "w") as f:
            f.write("old\n" * 1_300_000)               # > 5 MB
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        with open(big + ".1") as f:
            self.assertTrue(f.read().startswith("old\n"))
        self.assertEqual(len(self.runs_log()), 1)
        victim = os.path.join(self.d, "victim")
        wfile(victim, "precious\n")
        os.unlink(big)
        os.symlink(victim, big)
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        os.unlink(big)
        os.link(victim, big)
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        with open(victim) as f:
            self.assertEqual(f.read(), "precious\n")
        self.assertEqual(len(self.runs_log()), 1)
        # an unwritable log never fails the run
        shutil.rmtree(logdir)
        wfile(logdir, "not a dir")
        self.assertEqual(self.run_runner(["true"]).rc, 0)

    # ------------------------------------------------------------------ ~/rr hardening
    def test_root_excluded_from_time_machine_once_and_spotlight(self):
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        tm = [c for c in self.calls() if c.startswith("tmutil")]
        self.assertEqual(tm, ["tmutil addexclusion " + self.root])   # sticky: once, via marker
        self.assertTrue(os.path.isfile(os.path.join(self.root, ".metadata_never_index")))
        # a failing tmutil is not retried every run either
        os.remove(os.path.join(self.root, ".rr-tm-excluded"))
        wfile(os.path.join(self.bin, "tmutil"), "#!/bin/sh\necho t >> '%s'\nexit 1\n" % self.log)
        self.run_runner(["true"])
        self.run_runner(["true"])
        self.assertEqual(self.calls().count("t"), 1)

    def test_symlinked_mirror_or_deps_dir_refused(self):
        outside = os.path.join(self.d, "outside")
        os.makedirs(outside)
        os.makedirs(os.path.join(self.root, "w"))
        os.symlink(outside, self.mirror)
        r = self.run_runner(["true"])
        self.assertEqual(r.rc, 65, r.err)
        self.assertIn("is a symlink", r.err)
        self.assertEqual(os.listdir(outside), [])
        os.unlink(self.mirror)
        # a tracked symlinked dir used as a deps dir must not send npm ci outside the mirror
        wfile(os.path.join(outside, "package.json"), "{}")
        wfile(os.path.join(outside, "package-lock.json"), "{}")
        os.symlink(outside, os.path.join(self.src, "dep"))
        self.git("-C", self.src, "add", "dep")
        self.git("-C", self.src, "commit", "-qm", "dep link")
        self.git("-C", self.src, "push", "-q", os.path.join(self.root, "git", SLUG + ".git"), "HEAD:refs/heads/y")
        self.sha = self.git("-C", self.src, "rev-parse", "HEAD").strip()
        marker = os.path.join(self.d, "ran")
        r = self.run_runner(["/bin/sh", "-c", "touch %s" % marker], stamps={"dirs": ["", "dep"]})
        self.assertEqual(r.rc, 65, r.err)
        self.assertIn("resolves outside the mirror", r.err)
        self.assertFalse(os.path.exists(os.path.join(outside, "node_modules")))
        self.assertFalse(os.path.exists(marker))

    def test_who_rewritten_right_after_flock_with_pid(self):
        os.makedirs(os.path.join(self.root, "slots"))
        wfile(os.path.join(self.root, "slots", "0.who"), "stale.repo 1 1\n")   # left by a -9'd run
        old = time.time() - 3600
        wfile(os.path.join(self.root, "slots", "0"), "")
        os.utime(os.path.join(self.root, "slots", "0"), (old, old))
        seen = {}

        def act(p):
            self.wait_for(os.path.join(self.root, "slots", "0.who"))
            end = time.time() + 10
            while True:
                with open(os.path.join(self.root, "slots", "0.who")) as f:
                    seen["who"] = f.read()
                if not seen["who"].startswith("stale") or time.time() > end:
                    break
                time.sleep(0.02)
            seen["lock"] = os.stat(os.path.join(self.root, "slots", "0")).st_mtime
            seen["who_m"] = os.stat(os.path.join(self.root, "slots", "0.who")).st_mtime
            p.stdin.close()
        self.run_runner(["true"], action=act, go=False)
        # 4th field = the mirror's wt12: the janitor protects that mirror only (rd_janitor ~/rr)
        self.assertRegex(seen["who"], r"^%s \d+ \d+ %s\n$" % (re.escape(SLUG), WT))
        self.assertGreater(seen["lock"], old + 60)           # lock mtime bumped
        self.assertGreaterEqual(int(seen["who_m"]), int(seen["lock"]))


if __name__ == "__main__":
    unittest.main()
