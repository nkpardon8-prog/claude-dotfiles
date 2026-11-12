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
PG1 = "a" * 64          # a full container id (cleanup forwards only full ids)
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
case "$(basename "$0") $1" in "npm test"|"npm run"|"npm -s"|"npm --prefix")
  echo "cpu-env=${VITEST_MAX_WORKERS-}/${VITEST_MAX_THREADS-}/${VITEST_MAX_FORKS-}" ;; esac
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
        self.mirror = os.path.join(self.root, "w2", "%s-%s" % (SLUG, WT))

    def tearDown(self):
        shutil.rmtree(self.d, True)

    def env(self, **extra):
        kw = dict(RR_ROOT=self.root, RR_PATH=rdmods.safe_path(self.bin),
                  RR_REAL_DOCKER=os.path.join(self.bin, "docker"))
        kw.update(extra)
        return rdmods.child_env(self.home, self.bin, **kw)

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

    def run_runner(self, argv, tar=b"", action=None, timeout=30, go=True, env_extra=None, **kw):
        """Feed header + tar like the laptop; when `go`, answer "<nonce> READY" with "GO\\n" (the
        exactly-once handshake). `action(p)` runs after the frames are written."""
        h = self.header(argv, tar_len=len(tar), **kw)
        self.nonce = h["nonce"]
        js = json.dumps(h).encode()
        p = subprocess.Popen(["/usr/bin/perl", RUNNER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=self.env(**(env_extra or {})))
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
        self.assertEqual(own, [self.nonce + " READY", self.nonce + " STARTED", self.nonce + " EXIT 3"])
        self.assertNotIn(self.nonce, r.out)

    def test_bad_header_fields_rejected(self):
        for kw in ({"repo_slug": "../x"}, {"wt12": ".."}, {"sha": "abc"}, {"nonce": "zz"},
                   {"argv": []}, {"argv": ["a\0b"]}, {"env": {"A B": "1"}}):
            argv = kw.pop("argv", ["true"])
            self.assertEqual(self.run_runner(argv, **kw).rc, 65, kw)
        self.assertFalse(os.path.exists(os.path.join(self.root, "w2")))

    def test_missing_bare_repo_is_a_clear_error(self):
        r = self.run_runner(["true"], repo_slug="nope")
        self.assertEqual(r.rc, 69)
        self.assertIn("bare repo", r.err)

    # ------------------------------------------------------------------------ heartbeat
    @unittest.skipUnless(sys.platform == "darwin", "the rrun runner runs on the macOS mini only (on Linux "
                         "the killed grandchild lingers as a zombie when PID 1 does not reap)")
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
        wfile(os.path.join(self.d, "ps.out"), "%s\n" % PG1)

        def act(p):
            self.wait_for(ready)
            p.stdin.write(b"..INT\n")
            p.stdin.flush()
        r = self.run_runner(["/bin/sh", "-c", script], action=act)
        self.assertEqual(r.rc, 9)
        self.assertIn("GOT-INT", r.out)
        self.assertIn("docker rm -f -v " + PG1, self.calls())   # interrupted => removed

    # -------------------------------------------------------------------------- overlay
    def test_overlay_written_env_files_0600_then_deleted(self):
        tar = tar_of([(".env", b"A=1\n"), ("apps", None), ("apps/.env.local", b"B=2\n"),
                      ("new dir/untracked [id].txt", b"u"), ("keep.txt", b"dirty")])
        r = self.run_runner(["/bin/sh", "-c", "python3 -c 'import os; [print(oct(os.stat(p).st_mode & 0o777)[2:]) for p in (\".env\", \"apps/.env.local\")]'; cat keep.txt "
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
        self.assertFalse(os.path.exists(os.path.join(self.root, "w2", "escape.txt")))
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

    @unittest.skipUnless(sys.platform == "darwin", "APFS cp -c is macOS only")
    def test_shared_store_clones_packages_into_a_new_mirror(self):
        """A second laptop worktree with the same lockfile gets node_modules as an APFS clone of the
        store entry the first install published - no npm ci, no prisma generate; a tampered entry is
        ignored (normal npm ci)."""
        npm_ci = lambda: [c for c in self.calls() if c.startswith("npm ci")]          # noqa: E731
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        self.assertEqual(len(npm_ci()), 1)
        store = os.path.join(self.root, "deps")
        entries = [e for e in os.listdir(store) if not e.startswith(".")]
        self.assertEqual(len(entries), 1, os.listdir(store))
        nm = os.path.join(store, entries[0], "node_modules")
        self.assertTrue(os.path.isfile(os.path.join(nm, ".rr-deps-stamp")))
        self.assertTrue(os.path.isfile(os.path.join(nm, ".rr-schema-stamp")))   # saved after generate
        installs = lambda: [c for c in self.calls() if c.startswith(("npm", "npx"))]  # noqa: E731
        calls0 = len(installs())
        r = self.run_runner(["/bin/sh", "-c", "test -f node_modules/.rr-schema-stamp && echo cloned"],
                            wt12="fedcba987654")
        self.assertEqual((r.rc, r.out), (0, "cloned\n"), r.err)
        self.assertIn("reused from the mini's shared store (no npm ci)", r.err)
        self.assertEqual(len(installs()), calls0)                       # neither npm ci nor generate
        with open(os.path.join(nm, ".rr-deps-stamp"), "w") as f:      # tampered / foreign entry
            f.write("bogus")
        r = self.run_runner(["true"], wt12="00000000beef")
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(len(npm_ci()), 2)
        self.assertNotIn("shared store", r.err)
        self.assertFalse([e for e in os.listdir(store) if e.startswith(".tmp-")])

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
        self.assertRegex(lines[0], r" WAIT holder=other-repo age=4[2-4] busy=1 slots=1 ahead=0$")
        self.assertEqual(lines[1], self.nonce + " BUSY")
        self.assertEqual(self.calls(), [])                          # nothing ran
        self.assertEqual(self.run_runner(["true"]).rc, 0)           # lock released => runs

    @unittest.skipUnless(sys.platform == "darwin", "mini memory sysctls are macOS only")
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

    def test_spare_slot_linux_proc_readings(self):
        """Linux server: free level = MemAvailable/MemTotal*100, load from loadavg, ncpu from cpuinfo
        (fake /proc via RR_PROC; RR_OS=linux selects the branch on any host)."""
        proc = os.path.join(self.d, "proc")
        os.makedirs(proc)
        wfile(os.path.join(proc, "meminfo"), "MemTotal:       16000000 kB\nMemFree: 1 kB\nMemAvailable:   8000000 kB\n")
        wfile(os.path.join(proc, "loadavg"), "2.00 1.00 1.00 1/100 1\n")
        wfile(os.path.join(proc, "cpuinfo"), "processor\t: 0\nmodel: x\n\nprocessor\t: 1\nmodel: x\n")
        os.makedirs(os.path.join(self.root, "slots"))
        with open(os.path.join(self.root, "slots", "0.who"), "w") as f:
            f.write("other-repo %d\n" % time.time())
        with open(os.path.join(self.root, "slots", "0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            kw = dict(RR_OS="linux", RR_PROC=proc)
            # free 50%, load 2.0/2 cpu = 1.0
            r = self.run_runner(["true"], wait_min=0.02, slots=2, slots_base=1,
                                spare_min_free_pct=51, spare_max_load=1.5, env_extra=kw)
            self.assertEqual(r.rc, 73, r.err)
            r = self.run_runner(["true"], wait_min=0.02, slots=2, slots_base=1,
                                spare_min_free_pct=50, spare_max_load=0.9, env_extra=kw)
            self.assertEqual(r.rc, 73, r.err)
            r = self.run_runner(["true"], wait_min=0.02, slots=2, slots_base=1,
                                spare_min_free_pct=50, spare_max_load=1.0, env_extra=kw)
            self.assertEqual(r.rc, 0, r.err)

    def test_slots_cap_file_lowers_the_slot_count(self):
        """~/rr/slots.cap (rd-tune) caps `slots`; 0 drains the worker (wait, then 73)."""
        os.makedirs(os.path.join(self.root, "slots"))
        with open(os.path.join(self.root, "slots", "0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            self.assertEqual(self.run_runner(["true"], slots=2).rc, 0)        # slot 1 is free
            wfile(os.path.join(self.root, "slots.cap"), "1\n")
            r = self.run_runner(["true"], slots=2, wait_min=0.02)
            self.assertEqual(r.rc, 73, r.err)
        wfile(os.path.join(self.root, "slots.cap"), "0\n")
        self.assertEqual(self.run_runner(["true"], wait_min=0.02).rc, 73)
        os.unlink(os.path.join(self.root, "slots.cap"))
        os.symlink(os.path.join(self.d, "nowhere"), os.path.join(self.root, "slots.cap"))
        self.assertEqual(self.run_runner(["true"]).rc, 0)                     # a planted link: ignored

    def test_heavy_jobs_hold_a_heavy_slot_too(self):
        os.makedirs(os.path.join(self.root, "slots"))
        with open(os.path.join(self.root, "slots", "heavy-0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            r = self.run_runner(["true"], slots=2, heavy_slots=1, cls="heavy", wait_min=0.02)
            self.assertEqual(r.rc, 73, r.err)
            self.assertEqual(self.run_runner(["true"], slots=2, heavy_slots=1, cls="normal").rc, 0)
            self.assertEqual(self.run_runner(["true"], slots=2, heavy_slots=2, cls="heavy").rc, 0)
        self.assertEqual(self.run_runner(["true"], heavy_slots=1, cls="heavy").rc, 0)
        self.assertEqual(self.run_runner(["true"], heavy_slots="x").rc, 65)

    def test_need_gb_is_rechecked_before_the_slot(self):
        """The client's probe can race another client: the runner re-checks free memory."""
        proc = os.path.join(self.d, "proc")
        os.makedirs(proc)
        wfile(os.path.join(proc, "meminfo"), "MemTotal: 8000000 kB\nMemAvailable: 3000000 kB\n")
        kw = dict(RR_OS="linux", RR_PROC=proc)
        r = self.run_runner(["true"], need_gb=6, wait_min=0.02, env_extra=kw)
        self.assertEqual(r.rc, 73, r.err)
        self.assertEqual(self.run_runner(["true"], need_gb=2, env_extra=kw).rc, 0)

    def test_node_heap_follows_worker_ram_unless_set(self):
        """V8's ~2 GB default on an 8 GB worker OOMs `tsc -p server`: the runner sizes the heap (70% of
        RAM, 2-6 GB) and never overrides a caller's own --max-old-space-size."""
        proc = os.path.join(self.d, "proc")
        os.makedirs(proc)
        show = ["/bin/sh", "-c", 'printf "%s" "$NODE_OPTIONS"']
        for total_kb, want in ((8000000, "--max-old-space-size=5468"), (32000000, "--max-old-space-size=6144"),
                               (2000000, "--max-old-space-size=2048")):
            wfile(os.path.join(proc, "meminfo"), "MemTotal: %d kB\nMemAvailable: %d kB\n" % (total_kb, total_kb // 2))
            r = self.run_runner(show, env_extra=dict(RR_OS="linux", RR_PROC=proc))
            self.assertEqual(r.out, want, r.err)
        r = self.run_runner(show, env={"NODE_OPTIONS": "--max-old-space-size=1024 --trace-warnings"},
                            env_extra=dict(RR_OS="linux", RR_PROC=proc))
        self.assertEqual(r.out, "--max-old-space-size=1024 --trace-warnings")
        r = self.run_runner(show, env={"NODE_OPTIONS": "--trace-warnings"}, env_extra=dict(RR_OS="linux", RR_PROC=proc))
        self.assertEqual(r.out, "--trace-warnings --max-old-space-size=2048")

    # ------------------------------------------------------------------------ cpu share
    def cpus(self, n):
        """A fake Linux /proc with n logical CPUs (RR_OS=linux reads it on any host)."""
        proc = os.path.join(self.d, "proc")
        os.makedirs(proc, exist_ok=True)
        wfile(os.path.join(proc, "cpuinfo"), "".join("processor\t: %d\nmodel: x\n\n" % i for i in range(n)))
        wfile(os.path.join(proc, "meminfo"), "MemTotal: 16000000 kB\nMemAvailable: 8000000 kB\n")
        return dict(RR_OS="linux", RR_PROC=proc)

    def ran(self, argv, threads=16, files=None, **kw):
        """Run argv on a `threads`-CPU worker (overlay `files`) -> (the argv the fake npx/npm got,
        the stdout, the runs.log line)."""
        tar = tar_of([(n, c.encode()) for n, c in (files or {}).items()])
        open(self.log, "w").close()
        r = self.run_runner(argv, tar=tar, env_extra=self.cpus(threads), **kw)
        self.assertEqual(r.rc, 0, r.err)
        tool = os.path.basename(argv[0])
        got = [c for c in self.calls() if c.startswith(tool + " ") and not re.match(r"(npm (ci|install)|npx prisma)\b", c)]
        return got[-1] if got else None, r.out, self.runs_log()[-1].split("\t")[0]   # v1 part

    def test_cpu_share_is_threads_over_effective_slots(self):
        """share = max(1, floor(threads / min(header slots, slots.cap))); one slot (share = all
        threads) leaves the command alone."""
        for threads, slots, cap, want in ((18, 8, None, 2), (18, 8, 3, 6), (8, 8, None, 1), (8, 20, None, 1),
                                          (18, 8, 0, 2), (18, 1, None, None), (18, 4, 1, None)):
            if cap is None:
                if os.path.exists(os.path.join(self.root, "slots.cap")):
                    os.unlink(os.path.join(self.root, "slots.cap"))
            else:
                wfile(os.path.join(self.root, "slots.cap"), "%d\n" % cap)
            if cap == 0:      # drained: the job never runs (covered by the slots.cap test); only the math
                continue
            cmd, _, line = self.ran(["npx", "vitest", "run"], threads=threads, slots=slots)
            self.assertEqual(cmd, "npx vitest run" + (" --maxWorkers=%d" % want if want else ""),
                             (threads, slots, cap))
            self.assertEqual(line.endswith(" [cpu_share=%s --maxWorkers]" % want), bool(want), line)

    def test_vitest_gets_max_workers_after_run_unless_the_caller_chose(self):
        cmd, _, line = self.ran(["npx", "vitest", "run", "src", "--bail", "--", "x"], slots=8)
        self.assertEqual(cmd, "npx vitest run --maxWorkers=2 src --bail -- x")
        self.assertIn(" argv=npx vitest run src --bail -- x [cpu_share=2 --maxWorkers]", line)  # requested argv
        for own in (["--maxWorkers=4"], ["--max-workers", "4"], ["--minWorkers=1"],
                    ["--poolOptions.threads.maxThreads=2"], ["--no-file-parallelism"],
                    ["--fileParallelism=false"], ["--pool=forks"], ["--pool", "threads"],
                    ["--inspect-brk"], ["--browser.enabled"]):
            cmd, _, line = self.ran(["npx", "vitest", "run"] + own, slots=8)
            self.assertEqual(cmd, " ".join(["npx", "vitest", "run"] + own), own)
            self.assertNotIn("cpu_share", line)
        cmd, _, _ = self.ran(["npx", "vitest", "run"], slots=8, env={"VITEST_MAX_WORKERS": "3"})
        self.assertEqual(cmd, "npx vitest run")
        cmd, _, _ = self.ran(["npx", "vitest"], slots=8)              # not `vitest run`: untouched
        self.assertEqual(cmd, "npx vitest")
        cmd, _, _ = self.ran(["npx", "--", "vitest", "run"], slots=8)  # after a `--`: not ours to edit
        self.assertEqual(cmd, "npx -- vitest run")

    def test_a_config_limit_wins_over_the_cap(self):
        """The CLI value would override a deliberate config limit (sequential DB tests), so a config
        that names one - in the cwd, or via --config / --root - means no cap."""
        seq = "export default { test: { fileParallelism: false } }\n"
        for files, extra in (({"vitest.config.ts": seq}, []), ({"vite.config.mts": "test:{maxWorkers:1}"}, []),
                             ({"vitest.workspace.ts": "export default ['a']"}, []),
                             ({"cfg/x.ts": "poolOptions:{threads:{singleThread:true}}"}, ["--config", "cfg/x.ts"]),
                             ({"cfg/x.ts": "maxWorkers: 1"}, ["-c=cfg/x.ts"]),
                             ({"sub/vitest.config.js": seq}, ["--root", "sub"])):
            cmd, _, _ = self.ran(["npx", "vitest", "run"] + extra, slots=8, files=files)
            self.assertEqual(cmd, " ".join(["npx", "vitest", "run"] + extra), files)
        cmd, _, _ = self.ran(["npx", "vitest", "run"], slots=8,
                             files={"vitest.config.ts": "export default { test: { environment: 'node' } }"})
        self.assertEqual(cmd, "npx vitest run --maxWorkers=2")       # a config with no limit: capped

    def test_jest_gets_max_workers_unless_set(self):
        cmd, _, line = self.ran(["npx", "jest", "--ci"], slots=8)
        self.assertEqual(cmd, "npx jest --maxWorkers=2 --ci")
        self.assertTrue(line.endswith(" [cpu_share=2 --maxWorkers]"), line)
        for own in (["-i"], ["--runInBand"], ["-w", "4"], ["-w4"], ["--maxWorkers=50%"], ["--max-workers=3"]):
            cmd, _, _ = self.ran(["npx", "jest"] + own, slots=8)
            self.assertEqual(cmd, " ".join(["npx", "jest"] + own), own)
        cmd, _, _ = self.ran(["npx", "jest"], slots=8, files={"jest.config.js": "module.exports={maxWorkers:1}"})
        self.assertEqual(cmd, "npx jest")
        pj = json.dumps({"dependencies": {"@prisma/client": "5"}, "jest": {"maxWorkers": 2}})
        cmd, _, _ = self.ran(["npx", "jest"], slots=8, files={"package.json": pj})
        self.assertEqual(cmd, "npx jest")

    def test_npm_script_running_plain_vitest_gets_the_env_knobs(self):
        """argv injection cannot reach inside `npm test`: a script that is one plain vitest command
        gets VITEST_MAX_WORKERS (vitest 4+) and VITEST_MAX_THREADS / _FORKS (vitest 3) instead."""
        scripts = {"test": "vitest run", "test:int": 'A=1 DB="postgresql://x?y=5" vitest run src/it/',
                   "test:seq": "vitest run --no-file-parallelism", "test:chain": "vitest run && echo ok",
                   "test:jest": "jest", "lint": "eslint ."}
        pj = json.dumps({"dependencies": {"@prisma/client": "5"}, "scripts": scripts})
        for argv, want in ((["npm", "test"], "2/2/2"), (["npm", "-s", "run", "test:int"], "2/2/2"),
                           (["npm", "run", "test:seq"], "//"), (["npm", "run", "test:chain"], "//"),
                           (["npm", "run", "test:jest"], "//"), (["npm", "run", "lint"], "//"),
                           (["npm", "test", "--", "--maxWorkers=1"], "//"),
                           (["npm", "--prefix", "x", "test"], "//")):
            cmd, out, line = self.ran(argv, slots=8, files={"package.json": pj})
            self.assertEqual(cmd, " ".join(argv))                    # the argv itself never changes
            self.assertIn("cpu-env=%s\n" % want, out, argv)
            self.assertEqual(line.endswith(" [cpu_share=2 env]"), want != "//", line)
        _, out, _ = self.ran(["npm", "test"], slots=8,
                             files={"package.json": pj, "vitest.config.ts": "fileParallelism: false"})
        self.assertIn("cpu-env=//\n", out)

    def test_non_test_commands_are_untouched(self):
        for argv in (["npx", "tsc", "--noEmit"], ["npx", "eslint", "."], ["npm", "run", "build"]):
            cmd, out, line = self.ran(argv, slots=8)
            self.assertEqual(cmd, " ".join(argv))
            self.assertNotIn("cpu_share", line)
        r = self.run_runner(["/bin/sh", "-c", 'printf "%s" "${VITEST_MAX_WORKERS-unset}"'],
                            slots=8, env_extra=self.cpus(16))
        self.assertEqual(r.out, "unset")

    def test_each_shard_gets_the_same_per_job_cap(self):
        """A sharded run sends vitest run --shard=i/n to each worker (rd_run.shard_argv): every shard
        is capped by its own worker's share, after `run` like the shard flag."""
        import rd_run
        for i in (1, 2, 3):
            sargv = rd_run.shard_argv(["npx", "vitest", "run", "src"], i, 3)
            cmd, _, _ = self.ran(sargv, slots=8)
            self.assertEqual(cmd, "npx vitest run --maxWorkers=2 --shard=%d/3 src" % i)

    def test_declared_outputs_are_removed_from_the_mirror_first(self):
        wfile(os.path.join(self.src, ".gitignore"), "node_modules\n.env*\ndist\n")
        self.git("-C", self.src, "commit", "-qam", "ignore dist")
        sha = self.git("-C", self.src, "rev-parse", "HEAD").strip()
        self.git("-C", self.src, "push", "-q", os.path.join(self.root, "git", SLUG + ".git"), "HEAD:refs/heads/x")
        r = self.run_runner(["/bin/sh", "-c", "mkdir -p dist/a && touch dist/a/old"], sha=sha)
        self.assertEqual(r.rc, 0, r.err)
        r = self.run_runner(["/bin/sh", "-c", "test -e dist/a/old"], sha=sha)
        self.assertEqual(r.rc, 0, r.err)                      # ignored: git clean keeps it
        r = self.run_runner(["/bin/sh", "-c", "test ! -e dist"], sha=sha, outputs=["dist"])
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(self.run_runner(["true"], outputs=["../x"]).rc, 65)

    def test_deps_stamp_digest_matches_the_pool_probe(self):
        """rd_pool.deps_shas() must equal the sha the runner puts first in .rr-deps-stamp, or the
        probe never sees a worker as warm."""
        import rd_pool
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        with open(os.path.join(self.mirror, "node_modules", ".rr-deps-stamp")) as f:
            stamp = f.read()
        self.assertEqual(stamp.split(" ")[0], rd_pool.deps_shas(self.src, [""])[0][1])

    def test_linux_store_clone_uses_reflink_cp(self):
        """RR_OS=linux -> `cp -a --reflink=auto`: reused on a real Linux host; on BSD cp the flag is
        rejected, which must fall back quietly to npm ci (the mac path is untouched)."""
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        r = self.run_runner(["true"], wt12="fedcba987654", env_extra={"RR_OS": "linux"})
        self.assertEqual(r.rc, 0, r.err)
        if sys.platform.startswith("linux"):
            self.assertIn("reused from the mini's shared store (no npm ci)", r.err)
        else:
            self.assertNotIn("shared store", r.err)

    # ------------------------------------------------------------------------ containers
    def test_containers_removed_on_success_kept_on_failure(self):
        wfile(os.path.join(self.d, "ps.out"), "%s\n" % PG1)
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        ps = [c for c in self.calls() if c.startswith("docker ps -a --no-trunc --filter label=rdocker.rrun=")]
        self.assertRegex(ps[0], r"^docker ps -a --no-trunc --filter label=rdocker\.rrun=[0-9a-f]{32} "
                                r"--format \{\{\.ID\}\}\t\{\{\.Label \"rdocker\.keep\"\}\}$")
        self.assertNotIn(self.nonce, ps[0])                         # label token != status nonce
        self.assertIn("docker rm -f -v " + PG1, self.calls())
        os.remove(self.log)
        r = self.run_runner(["/bin/sh", "-c", "exit 7"])
        self.assertEqual(r.rc, 7)
        self.assertFalse([c for c in self.calls() if c.startswith("docker rm")])
        self.assertIn("%s KEPT %s" % (self.nonce, PG1[:12]), r.err)

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
        calls = [c for c in self.calls() if c.startswith("docker ") and " --filter label=rdocker.rrun=" not in c]
        lab = "--label " + calls[0].split()[3]
        self.assertRegex(lab, r"^--label rdocker\.rrun=[0-9a-f]{32}$")
        self.assertNotIn(self.nonce, lab)
        self.assertEqual(calls, ["docker run %s img a" % lab, "docker --context x run %s -d img" % lab,
                                 "docker --context x port cid123", "docker container create %s img" % lab,
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
        self.assertRegex(r.out, r"\$LABEL = 'rdocker\.rrun=[0-9a-f]{32}'")

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

    # ------------------------------------------------- 2026-11-11: hung jobs, owners, queue lines
    def alive(self, pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def test_main_exit_returns_promptly_despite_a_leftover_holding_stdout(self):
        """The command's main process exits while a child it left behind keeps stdout open: the run
        ends after exit_grace (the group is TERMed), with the main's rc, the slot released."""
        pidf = os.path.join(self.d, "leftover")
        t0 = time.time()
        r = self.run_runner(["/bin/sh", "-c", "(sleep 60; echo late) & echo $! > %s; echo main-done; exit 4"
                             % pidf], exit_grace=1, timeout=30)
        self.assertEqual(r.rc, 4, r.err)
        self.assertLess(time.time() - t0, 10)
        self.assertIn("main-done", r.out)
        self.assertNotIn("late", r.out)
        self.assertIn("%s EXIT 4" % self.nonce, r.err)
        with open(pidf) as f:
            pid = int(f.read())
        end = time.time() + 5
        while self.alive(pid) and time.time() < end:
            time.sleep(0.05)
        self.assertFalse(self.alive(pid), "the leftover child was not killed")
        self.assertFalse(os.path.exists(os.path.join(self.root, "slots", "0.who")))
        with open(os.path.join(self.root, "slots", "0"), "a") as lk:     # the slot lock is free
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_a_leftover_that_left_the_group_cannot_hold_the_session(self):
        """A child that setsid()s out of the group (no group kill reaches it) still only holds our
        relay pipe: we stop reading it a few seconds after the grace, and exit."""
        pidf = os.path.join(self.d, "escaped")
        script = ("/usr/bin/python3 -c 'import os,time,sys; os.setsid(); open(sys.argv[1],\"w\").write(str(os.getpid())); "
                  "time.sleep(60)' %s & sleep 0.5; echo done" % pidf)
        t0 = time.time()
        r = self.run_runner(["/bin/sh", "-c", script], exit_grace=1, timeout=30)
        took = time.time() - t0
        try:
            self.assertEqual(r.rc, 0, r.err)
            self.assertIn("done", r.out)
            self.assertLess(took, 20)                                   # grace 1 + TERM, KILL 10 s later
        finally:
            with open(pidf) as f:
                os.kill(int(f.read()), 9)

    def test_no_grace_wait_when_nothing_is_left(self):
        t0 = time.time()
        r = self.run_runner(["/bin/sh", "-c", "echo hi"], exit_grace=30)
        self.assertEqual((r.rc, r.out), (0, "hi\n"))
        self.assertLess(time.time() - t0, 10)

    def test_wall_clock_cap_kills_the_group_and_exits_124(self):
        pidf = os.path.join(self.d, "child")
        t0 = time.time()
        r = self.run_runner(["/bin/sh", "-c", "sleep 60 & echo $! > %s; echo started; sleep 60" % pidf],
                            timeout_s=1, timeout=30)
        self.assertEqual(r.rc, 124, r.err)
        self.assertLess(time.time() - t0, 15)
        own = [ln for ln in r.err.splitlines() if ln.startswith(self.nonce + " ")]
        self.assertIn(self.nonce + " TIMEOUT 1", own)
        self.assertEqual(own[-1], self.nonce + " EXIT 124")
        with open(pidf) as f:
            pid = int(f.read())
        end = time.time() + 5
        while self.alive(pid) and time.time() < end:
            time.sleep(0.05)
        self.assertFalse(self.alive(pid))
        self.assertIn("outcome=timeout rc=124", self.runs_log()[-1])
        self.assertEqual(self.run_runner(["true"], timeout_s=0).rc, 0)       # 0 = no cap

    def test_owner_tag_in_own_file_title_and_env(self):
        own = os.path.join(self.root, "slots", "0.own")
        seen = {}

        def act(p):
            self.wait_for(own)
            with open(own) as f:
                seen["own"] = f.read()
            with open(os.path.join(self.root, "slots", "0.who")) as f:
                seen["who"] = f.read()
            seen["ps"] = subprocess.run(["ps", "-o", "command=", "-p", str(p.pid)],
                                        capture_output=True, text=True).stdout
        owner = {"id": "session:abc-123", "name": "billing; rm -rf / $(x)", "client": "macbook"}
        r = self.run_runner(["/bin/sh", "-c", 'echo "o=$RRUN_OWNER"; sleep 2'], action=act, owner=owner)
        self.assertEqual(r.rc, 0, r.err)
        self.assertIn("o=session:abc-123\n", r.out)
        f = dict(x.split("=", 1) for x in seen["own"].rstrip("\n").split("\t"))
        self.assertEqual((f["id"], f["name"], f["client"]), ("session:abc-123", "billing rm -rf / x", "macbook"))
        self.assertEqual(f["pid"], seen["who"].split()[2])
        self.assertTrue(f["cmd"].startswith("/bin/sh -c echo"))
        self.assertRegex(seen["who"], r"^%s \d+ \d+ %s\n$" % (re.escape(SLUG), WT))   # .who keeps 4 fields
        # the title is cut to the runner's original argv length here (`perl rr_runner.pl`; the real
        # loader's `perl -e <loader>` leaves plenty of room)
        self.assertIn("rrun-runner owner=session:abc-123 window=billing_rm_-rf_/_x", seen["ps"])
        self.assertFalse(os.path.exists(own))                                # removed with the slot

    def test_slot_wait_repeats_with_position_and_holder_owner(self):
        slots = os.path.join(self.root, "slots")
        os.makedirs(slots)
        wfile(os.path.join(slots, "0.who"), "other-repo %d 1 aaaaaaaaaaaa\n" % (time.time() - 42))
        wfile(os.path.join(slots, "0.own"), "id=session:x\tname=ops window\tclient=m\tstart=1\tpid=1\tcmd=x\n")
        os.makedirs(os.path.join(self.root, "wait"))
        wfile(os.path.join(self.root, "wait", str(os.getpid())), "%.3f\n" % (time.time() - 5))   # ahead of us
        wfile(os.path.join(self.root, "wait", "999999"), "1.0\n")                              # dead: dropped
        with open(os.path.join(slots, "0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            r = self.run_runner(["true"], wait_min=0.04, wait_every=0.5)
        self.assertEqual(r.rc, 73)
        waits = [ln for ln in r.err.splitlines() if ln.startswith(self.nonce + " WAIT")]
        self.assertGreaterEqual(len(waits), 3, r.err)
        self.assertRegex(waits[0], r" WAIT holder=other-repo age=4\d busy=1 slots=1 ahead=1 howner=ops_window$")
        self.assertFalse(os.path.exists(os.path.join(self.root, "wait", "999999")))
        self.assertEqual(sorted(os.listdir(os.path.join(self.root, "wait"))), [str(os.getpid())])   # ours gone

    def test_run_log_one_line_per_run_no_secrets(self):
        r = self.run_runner(["/bin/sh", "-c", "exit 3", "-e", "PGPASSWORD=hunter2", "--env=TOK=sek",
                             "-eK=v2", "SECRET=s3", "--db-password=pw"], env={"API_KEY": "envsek"})
        self.assertEqual(r.rc, 3, r.err)
        os.unlink(os.path.join(self.mirror, "node_modules", ".rr-deps-stamp"))   # force npm ci
        shutil.rmtree(os.path.join(self.root, "deps"))                          # (not the store)
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
        self.assertIn("outcome=abandoned-setup", lines[3])     # the client left before GO (was "lost")
        st = os.stat(os.path.join(self.root, "log"))
        self.assertEqual(st.st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(os.path.join(self.root, "log", "runs.log")).st_mode & 0o777, 0o600)
        # long argv is cut at 120 chars
        self.run_runner(["true", "x" * 500])
        self.assertLess(len(self.runs_log()[-1].split("\t")[0].split(" argv=", 1)[1]), 130)

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
        os.makedirs(os.path.join(self.root, "w2"))
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


    # ------------------------------------------------------------------ share switch (rented workers)
    def share(self, level):
        """Point RR_SHARE_FILE at a file in the test dir with `level` (None = no file) -> env_extra."""
        f = os.path.join(self.d, "share")
        if level is None:
            if os.path.exists(f):
                os.unlink(f)
        else:
            wfile(f, level + "\n")
        return {"RR_SHARE_FILE": f}

    def test_share_switch_off_refuses_at_once_some_halves_slots_max_or_none_full(self):
        os.makedirs(os.path.join(self.root, "slots"))
        kw = self.share("off")
        t0 = time.time()
        r = self.run_runner(["true"], wait_min=1, env_extra=kw)
        self.assertEqual(r.rc, 73, r.err)
        self.assertLess(time.time() - t0, 10)                       # no slot wait
        self.assertIn("%s UNAVAIL share=off" % self.nonce, r.err)
        self.assertEqual(self.calls(), [])                          # nothing prepared or run
        self.assertFalse(os.path.exists(os.path.join(self.root, "w2")))
        for junk in ("maybe", ""):                                  # a file that says nothing clear = off
            self.assertEqual(self.run_runner(["true"], env_extra=self.share(junk)).rc, 73, junk)
        with open(os.path.join(self.root, "slots", "0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            for level, rc in ((None, 0), ("max", 0), (" MAX ", 73), ("some", 73)):
                r = self.run_runner(["true"], slots=2, wait_min=0.02, env_extra=self.share(level))
                self.assertEqual(r.rc, rc, (level, r.err))          # some: 2 slots -> 1 (held)
            r = self.run_runner(["true"], slots=4, wait_min=0.02, env_extra=self.share("some"))
            self.assertEqual(r.rc, 0, r.err)                        # 4 -> 2: slot 1 is free
        with open(os.path.join(self.root, "slots", "heavy-0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            hv = dict(slots=4, heavy_slots=2, cls="heavy", wait_min=0.02)
            self.assertEqual(self.run_runner(["true"], env_extra=self.share("max"), **hv).rc, 0)
            r = self.run_runner(["true"], env_extra=self.share("some"), **hv)
            self.assertEqual(r.rc, 73, r.err)                       # heavy 2 -> 1 (held)
            hv["heavy_slots"] = 1
            self.assertEqual(self.run_runner(["true"], env_extra=self.share("some"), **hv).rc, 73)   # min 1, held

    def test_share_switched_off_while_waiting_for_a_slot_moves_on(self):
        os.makedirs(os.path.join(self.root, "slots"))
        kw = self.share("max")

        def act(p):
            end = time.time() + 10
            while b" WAIT " not in b"".join(self.err_so_far) and time.time() < end:
                time.sleep(0.05)
            self.share("off")
        with open(os.path.join(self.root, "slots", "0"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            t0 = time.time()
            r = self.run_runner(["true"], wait_min=5, action=act, env_extra=kw)
        self.assertEqual(r.rc, 73, r.err)
        self.assertLess(time.time() - t0, 20)
        self.assertIn("%s UNAVAIL share=off" % self.nonce, r.err)

    def mac_docker(self):
        """Fake Mac worker: docker `info` answers only while $d/engine-up exists; colima start creates
        it (unless $d/colima-fail; sleeps $d/colima-sleep s first), colima stop removes it."""
        log = os.path.join(self.d, "mac.log")
        docker, colima = os.path.join(self.bin, "macdocker"), os.path.join(self.bin, "fakecolima")
        wfile(docker, '#!/bin/sh\necho "docker $*" >> %s\ncase "$1" in info) [ -f %s/engine-up ] || exit 1 ;; esac\nexit 0\n'
              % (log, self.d))
        wfile(colima, '#!/bin/sh\necho "colima $*" >> {l}\ncase "$1" in\n'
              '  start) [ -f {d}/colima-sleep ] && sleep "$(cat {d}/colima-sleep)"\n'
              '         [ -f {d}/colima-fail ] && {{ echo "boom: rosetta" >&2; exit 1; }}\n'
              '         touch {d}/engine-up ;;\n'
              '  stop) rm -f {d}/engine-up ;;\nesac\nexit 0\n'.format(l=log, d=self.d))
        os.chmod(docker, 0o755)
        os.chmod(colima, 0o755)
        self.maclog = log
        return dict(RR_OS="darwin", RR_REAL_DOCKER=docker, RR_COLIMA=colima,
                    RR_COLIMA_SOCK=os.path.join(self.d, "no-sock"))

    def mac_calls(self, prefix):
        if not os.path.exists(self.maclog):
            return []
        with open(self.maclog) as f:
            return [ln for ln in f.read().splitlines() if ln.startswith(prefix)]

    def test_mac_db_job_starts_colima_sized_by_the_share_level(self):
        kw = dict(self.mac_docker(), **self.share("some"))
        marker = os.path.join(self.d, "ran")
        r = self.run_runner(["/bin/sh", "-c", "touch %s" % marker], cls="db", env_extra=kw)
        self.assertEqual(r.rc, 0, r.err)
        self.assertTrue(os.path.exists(marker))
        self.assertEqual(self.mac_calls("colima"),
                         ["colima start --cpu 6 --memory 12 --disk 120 --vm-type vz --vz-rosetta"])
        self.assertIn("starting Colima (6 CPU, 12 GB", r.err)
        self.assertTrue(os.path.exists(os.path.join(self.root, "state", "colima.started")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "colima.lock")))
        # already running (also: started by hand): nothing to do
        r = self.run_runner(["true"], cls="db", env_extra=dict(kw, **self.share("max")))
        self.assertEqual((r.rc, len(self.mac_calls("colima"))), (0, 1), r.err)
        os.unlink(os.path.join(self.d, "engine-up"))
        r = self.run_runner(["true"], cls="db", env_extra=dict(kw, **self.share(None)))
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(self.mac_calls("colima")[-1],
                         "colima start --cpu 12 --memory 24 --disk 120 --vm-type vz --vz-rosetta")

    def test_mac_colima_failure_or_timeout_is_73_before_anything_runs(self):
        kw = self.mac_docker()
        marker = os.path.join(self.d, "ran")
        wfile(os.path.join(self.d, "colima-fail"), "")
        r = self.run_runner(["/bin/sh", "-c", "touch %s" % marker], cls="db", env_extra=kw)
        self.assertEqual(r.rc, 73, r.err)
        self.assertIn("%s UNAVAIL docker" % self.nonce, r.err)
        self.assertIn("colima start failed", r.err)
        self.assertNotIn("%s READY" % self.nonce, r.err)
        self.assertFalse(os.path.exists(marker))
        os.unlink(os.path.join(self.d, "colima-fail"))
        wfile(os.path.join(self.d, "colima-sleep"), "4")
        t0 = time.time()
        r = self.run_runner(["true"], cls="db", env_extra=dict(kw, RR_COLIMA_TIMEOUT="1"))
        self.assertEqual(r.rc, 73, r.err)
        self.assertLess(time.time() - t0, 4)                        # gave up; the start carries on
        self.assertIn("did not come up within 1 s", r.err)
        self.wait_for(os.path.join(self.d, "engine-up"))            # ... and finished in its own session
        self.assertEqual(self.run_runner(["true"], cls="db", env_extra=kw).rc, 0)

    def test_colima_only_on_a_mac_and_lazily_through_the_shim(self):
        kw = self.mac_docker()
        r = self.run_runner(["true"], cls="db", env_extra=dict(kw, RR_OS="linux"))
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(self.mac_calls("colima"), [])              # Linux worker: never
        r = self.run_runner(["true"], cls="db", env_extra=dict(kw, RR_COLIMA=os.path.join(self.d, "none")))
        self.assertEqual((r.rc, self.mac_calls("colima")), (0, []))  # no colima installed: as before
        r = self.run_runner(["true"], env_extra=kw)                 # normal job, no docker use
        self.assertEqual((r.rc, self.mac_calls("colima")), (0, []), r.err)
        r = self.run_runner(["/bin/sh", "-c", "docker ps; docker ps"], env_extra=kw)
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(len(self.mac_calls("colima start")), 1)    # first docker call started it
        self.assertEqual([c for c in self.mac_calls("docker ps") if c == "docker ps"], ["docker ps", "docker ps"])

    def test_share_off_and_idle_stops_colima_at_job_end(self):
        kw = self.mac_docker()
        os.makedirs(os.path.join(self.root, "state"))
        wfile(os.path.join(self.root, "state", "colima.started"), "")
        wfile(os.path.join(self.d, "engine-up"), "")
        r = self.run_runner(["true"], env_extra=dict(kw, **self.share("max")))
        self.assertEqual((r.rc, self.mac_calls("colima")), (0, []), r.err)   # sharing: keep it
        os.makedirs(os.path.join(self.root, "slots"), exist_ok=True)
        with open(os.path.join(self.root, "slots", "3"), "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            self.assertEqual(self.run_runner(["true"], env_extra=dict(kw, **self.share("off"))).rc, 73)
            time.sleep(0.5)
            self.assertEqual(self.mac_calls("colima"), [])           # a slot is busy: not now
        self.assertEqual(self.run_runner(["true"], env_extra=dict(kw, **self.share("off"))).rc, 73)
        end = time.time() + 10
        while os.path.exists(os.path.join(self.root, "state", "colima.started")) and time.time() < end:
            time.sleep(0.05)
        self.assertEqual(self.mac_calls("colima"), ["colima stop"])
        self.assertFalse(os.path.exists(os.path.join(self.d, "engine-up")))
        self.wait_for_gone(os.path.join(self.root, "colima.lock"))

    def wait_for_gone(self, path, secs=10):
        end = time.time() + secs
        while os.path.exists(path):
            self.assertLess(time.time(), end, "timed out waiting for removal of " + path)
            time.sleep(0.05)


FAKE_D = r"""#!/bin/sh
printf '%%s\n' "docker $*" >> '%(log)s'
[ "$1" = compose ] && printf 'COMPOSE=%%s\n' "$COMPOSE_PROJECT_NAME" >> '%(log)s'
last=""; for a do last=$a; done
for a do
  if [ "$a" = inspect ]; then
    [ "$last" = flaky ] && { echo "Error response from daemon: i/o timeout" >&2; exit 1; }
    [ -f '%(objs)s'/"$last" ] || { echo "Error: No such object: $last" >&2; exit 1; }
    cat '%(objs)s'/"$last"; exit 0
  fi
done
[ "$1" = rm ] && [ $# -eq 1 ] && { echo '"docker rm" requires at least 1 argument.' >&2; exit 1; }
[ "$1" = stop ] && kill -TERM $$
case "$*" in
  "ps "*"label=rdocker.rrun="*) cat '%(dir)s/ps.out' 2>/dev/null ;;
  "ps "*"label=com.docker.compose.project="*) cat '%(dir)s/ps-compose.out' 2>/dev/null ;;
  "network ls "*"label=rdocker.rrun="*) printf '%(net)s\t\n' ;;
esac
exit 0
"""

ID_MINE, ID_OTHER, ID_CM, ID_V, ID_C1, ID_CK, ID_CC = ("%x" % k * 64 for k in range(1, 8))

SCOPE_SCRIPT = r'''
O=%(objs)s
echo "%(mine)s|${RRUN_DOCKER_LABEL#*=}|" > $O/mine
echo "%(other)s|0123456789abcdef0123456789abcdef|" > $O/other
echo "%(cm)s||$COMPOSE_PROJECT_NAME" > $O/cmine
echo "%(v)s||victim" > $O/victim
echo "abc123||$COMPOSE_PROJECT_NAME" > $O/shortid
printf '%(cc)s\t\n' > %(dir)s/ps-compose.out
docker rm -f mine other; echo "rc1=$?"
docker container remove -f -v other; echo "rc2=$?"
docker stop -t 5 gone; echo "rc3=$?"
docker rm -f gone; echo "rc4=$?"
docker rm -f flaky mine; echo "rc5=$?"
docker container prune -f; echo "rc6=$?"
docker container prune -f --filter "label=$RRUN_DOCKER_LABEL"; echo "rc7=$?"
docker system prune -af; echo "rc8=$?"
docker compose up -d; echo "rc9=$?"
docker compose -p victim down -v; echo "rc10=$?"
docker compose --workdir / -p victim down -v; echo "rc11=$?"
docker compose --project-name=x up; echo "rc12=$?"
docker compose -p=x up; echo "rc13=$?"
docker compose -vpvictim down -v; echo "rc13b=$?"
docker network create n1; echo "rc14=$?"
docker volume remove other; echo "rc15=$?"
docker kill cmine victim; echo "rc16=$?"
docker rm -f shortid; echo "rc17=$?"
docker rm; echo "rc18=$?"
docker stop mine; echo "rc19=$?"
echo "proj=$COMPOSE_PROJECT_NAME"
'''

class DetachedRuns(RunnerTest):
    """Phase B (2026-11-11): a header run_id makes the run survive a lost link - a keeper owns the
    command and spools its output, a follower relays it, a later session reattaches."""

    def sp(self, rid, ext):
        return os.path.join(self.root, "spool", "%s.%s" % (rid, ext))

    def start(self, argv, go=True, **kw):
        rid = str(uuid.uuid4())
        h = self.header(argv, tar_len=0, run_id=rid, **kw)
        self.nonce = h["nonce"]
        js = json.dumps(h).encode()
        p = subprocess.Popen(["/usr/bin/perl", RUNNER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=self.env())
        st = {"out": b"", "err": b"", "go": False}
        lock = threading.Lock()

        def rd(name, f):
            while True:
                b = os.read(f.fileno(), 65536)
                if not b:
                    break
                st[name] += b
                if go and not st["go"] and (self.nonce + " READY\n").encode() in st["err"]:
                    st["go"] = True
                    try:
                        with lock:
                            p.stdin.write(b"GO\n")
                            p.stdin.flush()
                    except (OSError, ValueError):
                        pass
        with lock:
            p.stdin.write(b"%d\n" % len(js) + js)
            p.stdin.flush()
        ts = [threading.Thread(target=rd, args=(n, f), daemon=True) for n, f in (("out", p.stdout), ("err", p.stderr))]
        for t in ts:
            t.start()
        self.addCleanup(lambda: p.poll() is None and p.kill())
        return p, rid, st, ts

    def attach(self, rid, out_off=0, err_off=0, nonce=None):
        js = json.dumps({"nonce": nonce or self.nonce, "attach": rid, "out_off": out_off,
                         "err_off": err_off}).encode()
        r = subprocess.run(["/usr/bin/perl", RUNNER], input=b"%d\n" % len(js) + js, capture_output=True,
                           env=self.env(), timeout=60)
        return Result(r.returncode, r.stdout.decode(), r.stderr.decode())

    def until(self, cond, secs=15, what="condition"):
        end = time.time() + secs
        while not cond():
            self.assertLess(time.time(), end, "timed out waiting for " + what)
            time.sleep(0.05)

    def started_err(self, st):
        """The command's stderr as a client counts it: after our STARTED line, minus status lines."""
        tag = (self.nonce + " STARTED\n").encode()
        rest = st["err"].split(tag, 1)[1] if tag in st["err"] else b""
        return b"".join(ln for ln in rest.splitlines(True) if not ln.startswith(self.nonce.encode()))

    def test_mirrors_live_in_w2_and_never_touch_an_old_runners_w(self):
        """An old client's runner uses ~/rr/w and knows no mirror lock: new runners keep out of it."""
        old = os.path.join(self.root, "w", "%s-%s" % (SLUG, WT))
        os.makedirs(old)
        wfile(os.path.join(old, "untouched"), "x")
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        self.assertTrue(os.path.isdir(os.path.join(self.mirror, ".git")) or os.path.isfile(os.path.join(self.mirror, ".git")))
        self.assertTrue(self.mirror.startswith(os.path.join(self.root, "w2") + os.sep))
        self.assertEqual(os.listdir(old), ["untouched"])
        self.assertTrue(os.path.exists(os.path.join(self.root, "w2", ".%s-%s.lock" % (SLUG, WT))))

    def test_lost_link_keeper_runs_on_and_a_reattach_gets_the_rest_and_the_rc(self):
        ready, go2 = os.path.join(self.d, "ready"), os.path.join(self.d, "go2")
        script = ("printf part1; echo e1 >&2; touch %s; while [ ! -e %s ]; do sleep 0.05; done; "
                  "printf part2; echo e2 >&2; exit 5" % (ready, go2))
        p, rid, st, ts = self.start(["/bin/sh", "-c", script])
        self.until(lambda: st["out"] == b"part1" and self.started_err(st) == b"e1\n", what="part1")
        p.kill()                                   # the link is gone: only the follower dies with it
        p.wait()
        self.assertTrue(os.path.exists(self.sp(rid, "lock")))
        # the slot names its live holder (the keeper), never the dead follower: the janitor, rd-doctor
        # and the probe trust a held slot's .who / .own only while that pid lives
        with open(os.path.join(self.root, "slots", "0.who")) as f:
            kpid = int(f.read().split()[2])
        with open(os.path.join(self.root, "slots", "0.own")) as f:
            self.assertIn("\tpid=%d\t" % kpid, f.read())
        self.assertNotEqual(kpid, p.pid)
        self.assertTrue(self.alive(kpid))
        open(go2, "w").close()
        r = self.attach(rid, out_off=len(st["out"]), err_off=len(self.started_err(st)))
        self.assertEqual(r.rc, 5, r.err)
        self.assertEqual(st["out"].decode() + r.out, "part1part2")              # every byte, once
        self.assertEqual([ln for ln in r.err.splitlines() if not ln.startswith(self.nonce)], ["e2"])
        own = [ln for ln in r.err.splitlines() if ln.startswith(self.nonce)]
        self.assertEqual(own, [self.nonce + " ATTACHED", self.nonce + " EXIT 5"])
        line = self.runs_log()[-1]
        self.assertRegex(line, r"outcome=rc=5 .*\trun=%s owner=- cls=- wait_s=\d+\.\d exit_reason=fail setup=\S+ pred_s=\S+ client=\S+ pv=\S+$" % rid)
        with open(os.path.join(self.root, "slots", "0")) as lk:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)                      # slot released
        # the same run again after its end (another reattach): the rest from those offsets, then EXIT
        r2 = self.attach(rid, out_off=5, err_off=3)
        self.assertEqual((r2.rc, r2.out), (5, "part2"))

    def test_keeper_tolerates_detach_hb_s_without_a_client_then_cancels(self):
        pidf = os.path.join(self.d, "pid")
        p, rid, st, ts = self.start(["/bin/sh", "-c", "echo $$ > %s; exec sleep 60" % pidf], detach_hb_s=2)
        self.wait_for(pidf)
        time.sleep(0.2)
        with open(pidf) as f:
            pid = int(f.read())
        p.kill()
        p.wait()
        # a follower relaying heartbeats (here: the .hb mtime it touches) keeps it going past 2 s
        end = time.time() + 4
        while time.time() < end:
            os.utime(self.sp(rid, "hb"))
            time.sleep(0.3)
        self.assertTrue(self.alive(pid), "cancelled while heartbeats still came")
        t0 = time.time()                            # now nobody: cancelled after ~2 s, not before
        time.sleep(1.0)
        self.assertTrue(self.alive(pid), "cancelled before detach_hb_s")
        self.until(lambda: not self.alive(pid), 20, "the cancel")
        self.assertGreater(time.time() - t0, 1.5)
        self.until(lambda: os.path.exists(self.sp(rid, "end")), 20, "the keeper's end")
        self.until(lambda: "outcome=lost rc=" in (self.runs_log() or [""])[-1], 10, "the run log")
        self.assertIn("exit_reason=lost setup=", self.runs_log()[-1])

    def test_kill_line_cancels_at_once_as_interrupted(self):
        ready = os.path.join(self.d, "ready")
        p, rid, st, ts = self.start(["/bin/sh", "-c", "touch %s; exec sleep 60" % ready])
        self.wait_for(ready)
        t0 = time.time()
        p.stdin.write(b"..KILL\n")
        p.stdin.flush()
        p.stdin.close()                             # a deliberate stop also closes stdin
        self.assertEqual(p.wait(30), 143)
        for t in ts:
            t.join(5)
        self.assertLess(time.time() - t0, 20)
        self.assertIn((self.nonce + " EXIT 143").encode(), st["err"])
        self.until(lambda: "outcome=interrupted rc=143" in (self.runs_log() or [""])[-1], 10, "the run log")

    def test_reattach_before_go_stops_the_runner_and_says_norun(self):
        marker = os.path.join(self.d, "ran")
        p, rid, st, ts = self.start(["/bin/sh", "-c", "touch %s" % marker], go=False)
        self.until(lambda: (self.nonce + " READY").encode() in st["err"], what="READY")
        r = self.attach(rid)
        self.assertEqual(r.rc, 0, r.err)
        self.assertIn(self.nonce + " NORUN", r.err)
        self.assertEqual(p.wait(20), 130)
        self.assertFalse(os.path.exists(marker))                 # never started
        self.assertFalse(os.path.exists(self.sp(rid, "lock")))   # nothing left to follow
        self.assertTrue(os.path.exists(self.sp(rid, "norun")))      # the runner's own signed record
        self.assertEqual(self.attach("not-a-uuid").rc, 65)

    def test_a_forged_result_file_is_ignored(self):
        ready, go2 = os.path.join(self.d, "ready"), os.path.join(self.d, "go2")
        script = "touch %s; while [ ! -e %s ]; do sleep 0.05; done; exit 3" % (ready, go2)
        p, rid, st, ts = self.start(["/bin/sh", "-c", script])
        self.wait_for(ready)
        wfile(self.sp(rid, "rc"), "rc=0 timeout=0 docker=0 mac=%s\n" % ("0" * 64))   # the command could
        time.sleep(0.6)
        self.assertIsNone(p.poll())                               # not taken for a result
        open(go2, "w").close()
        self.assertEqual(p.wait(20), 3)
        for t in ts:
            t.join(5)
        self.assertIn((self.nonce + " EXIT 3").encode(), st["err"])
        self.assertNotIn((self.nonce + " EXIT 0").encode(), st["err"])

    def test_spool_is_swept_10_min_after_the_end_or_1_h_untouched_never_a_live_one(self):
        d = os.path.join(self.root, "spool")
        os.makedirs(d)
        now = time.time()
        ids = {k: str(uuid.uuid4()) for k in ("old", "ended", "fresh", "live")}
        for k, rid in ids.items():
            for ext in ("out", "err", "hb", "ctl", "lock") + (("rc",) if k in ("ended", "fresh") else ()):
                path = os.path.join(d, "%s.%s" % (rid, ext))
                wfile(path, "")
                age = {"old": 7200, "ended": 900, "fresh": 60, "live": 7200}[k]
                os.utime(path, (now - age, now - age))
        lk = open(os.path.join(d, ids["live"] + ".lock"))
        fcntl.flock(lk, fcntl.LOCK_EX)              # a keeper still holds it
        self.addCleanup(lk.close)
        p, rid, st, ts = self.start(["true"])
        self.assertEqual(p.wait(30), 0)
        self.until(lambda: not os.path.exists(os.path.join(d, ids["old"] + ".out")), 10, "the sweep")
        left = set(n.split(".")[0] for n in os.listdir(d))
        self.assertEqual(left, {ids["fresh"], ids["live"], rid})

    def test_docker_scope_only_this_runs_objects(self):
        objs = os.path.join(self.d, "objs")
        os.makedirs(objs)
        docker = os.path.join(self.d, "dbin", "docker")
        os.makedirs(os.path.dirname(docker))
        net = "e" * 64
        wfile(docker, FAKE_D % {"log": self.log, "objs": objs, "dir": self.d, "net": net})
        os.chmod(docker, 0o755)
        wfile(os.path.join(self.d, "ps.out"), "%s\t\n%s\t1\nshort\t\n" % (ID_C1, ID_CK))
        script = SCOPE_SCRIPT % {"objs": objs, "dir": self.d, "mine": ID_MINE, "other": ID_OTHER,
                                 "cm": ID_CM, "v": ID_V, "cc": ID_CC}
        r = self.run_runner(["/bin/sh", "-c", script], env={"COMPOSE_PROJECT_NAME": "Mine"},
                            env_extra={"RR_REAL_DOCKER": docker})
        self.assertEqual(r.rc, 0, r.err)
        rcs = dict(ln.split("=", 1) for ln in r.out.splitlines() if ln.startswith("rc"))
        self.assertEqual(rcs, {"rc1": "1", "rc2": "1", "rc3": "1", "rc4": "0", "rc5": "1", "rc6": "1",
                               "rc7": "0", "rc8": "1", "rc9": "1", "rc10": "1", "rc11": "1", "rc12": "1",
                               "rc13": "1", "rc13b": "1", "rc14": "0", "rc15": "1", "rc16": "1", "rc17": "1", "rc18": "1",
                               "rc19": "143"}, r.err)
        proj = re.search(r"proj=(rr[0-9a-f]{12}-default)\n", r.out).group(1)   # the job's "Mine" dropped
        log = self.calls()
        calls = [c for c in log if " inspect " not in c and not c.startswith(("docker ps", "COMPOSE="))
                 and " ls " not in c]
        lab = re.search(r"rdocker\.rrun=[0-9a-f]{32}", "\n".join(log)).group(0)
        # only full ids of its own objects ever reach docker
        self.assertIn("docker rm -f " + ID_MINE, calls)
        self.assertEqual([c for c in calls if ID_MINE in c], ["docker rm -f " + ID_MINE, "docker stop " + ID_MINE])
        for never in ("other", ID_OTHER, ID_V, "gone", "flaky", "abc123", "shortid", "victim", "-p", "project-name"):
            self.assertFalse([c for c in calls if c.startswith("docker ") and never in c], (never, calls))   # temp paths are random
        self.assertIn("docker rm", calls)                         # no targets at all: docker's own usage error
        self.assertIn('"docker rm" requires at least 1 argument.', r.err)
        self.assertNotIn("docker container prune -f", calls)
        self.assertIn("docker container prune -f --filter label=%s" % lab, calls)
        self.assertFalse([c for c in calls if "system prune" in c])
        # compose: not available in pool jobs at all (argv checks were dodgeable: -p=, --workdir, -vpX)
        self.assertFalse([c for c in calls if c.startswith("docker compose")], calls)
        self.assertEqual([c for c in log if c.startswith("COMPOSE=")], [])
        self.assertEqual(r.err.count("rrun: docker compose is not available in rrun pool jobs"), 6)
        self.assertIn("docker network create --label %s n1" % lab, calls)
        self.assertIn("docker kill " + ID_CM, calls)              # its compose project's container
        for what in ("container other is not this run's", "could not check container flaky",
                     "could not check container shortid", "a container prune", "a system prune",
                     "volume other is not", "container victim is not", "No such container: gone"):
            self.assertIn(what, r.err)
        self.assertNotIn(".shim-err", "\n".join(os.listdir(self.root)))   # no temp file to plant a link at
        # end of run: full ids of its labelled containers (never an rdocker.keep one, never a short
        # id) and its networks; no compose listing, since compose never ran
        rm = [c for c in calls if c.startswith("docker rm -f -v ")]
        self.assertEqual(rm, ["docker rm -f -v %s" % ID_C1], calls)
        self.assertIn("docker network rm " + net, calls)
        self.assertFalse([l for l in log if "--filter label=com.docker.compose.project=" in l], log)

    def test_runs_log_v2_fields_and_every_parser_still_reads_it(self):
        p, rid, st, ts = self.start(["/bin/sh", "-c", "exit 0"], job_cls="heavy", waited_s=2.5,
                                    owner={"id": "session:abc-1", "name": "w", "client": "c"})
        self.assertEqual(p.wait(30), 0)
        self.until(lambda: self.runs_log() and rid in self.runs_log()[-1], 10, "the run log")
        line = self.runs_log()[-1]
        self.assertRegex(line, r"^\S+ repo=\S+ wt=\S+ sha=\S+ outcome=rc=0 prepare_s=\S+ cmd_s=\S+ "
                               r"argv=/bin/sh -c exit 0\trun=%s owner=session:abc-1 cls=heavy "
                               r"wait_s=(\d+\.\d) exit_reason=pass setup=(warm|cold) pred_s=- client=- pv=-$" % rid)
        self.assertGreaterEqual(float(re.search(r"wait_s=(\S+)", line).group(1)), 2.5)
        # rd_pool's probe (perl, as on a worker): the command's evidence without the v2 fields
        import rd_pool
        req = {"sig": "/bin/sh -c exit 0", "kind": "other", "kinds": [list(k) for k in rd_pool.KINDS]}
        pr = subprocess.run(["/usr/bin/perl", "-e", rd_pool.PROBE], input=json.dumps(req).encode(),
                            capture_output=True, env=self.env(), timeout=30)
        ev = json.loads(pr.stdout.decode().strip().splitlines()[-1])["ev"]
        self.assertEqual(len(ev["sig"]), 1)
        self.assertEqual(ev["rows"][-1][0], "pass")
        # the dashboard reporter's own parseRunsLog (node; the reporter itself is not changed)
        node = shutil.which("node")
        if node:
            js = ("import {parseRunsLog} from %s; import fs from 'fs';"
                  "process.stdout.write(JSON.stringify(parseRunsLog(fs.readFileSync(0, 'utf8'))))"
                  % json.dumps("file://" + os.path.join(rdmods.STAGE, "reporter", "rd-reporter.mjs")))
            rr = subprocess.run([node, "--input-type=module", "-e", js], input=(line + "\n").encode(),
                                capture_output=True, timeout=60,
                                env=rdmods.child_env(self.home, os.path.dirname(node)))
            self.assertEqual(rr.returncode, 0, rr.stderr)
            runs = json.loads(rr.stdout)
            self.assertEqual(len(runs), 1)
            self.assertEqual(runs[0]["outcome"], "rc=0")
            self.assertTrue(runs[0]["argv"].startswith("/bin/sh -c exit 0"), runs[0])

    def test_norun_only_from_the_runners_signed_record_else_gone(self):
        # no record of the run at all (never here, or its spool was swept): it may have run -> GONE
        self.nonce = uuid.uuid4().hex
        r = self.attach(str(uuid.uuid4()))
        self.assertEqual(r.rc, 70, r.err)
        self.assertIn(self.nonce + " GONE no record of this run here", r.err)
        self.assertNotIn("NORUN", r.err)
        # a .norun the command could have planted (no valid signature) proves nothing
        rid = str(uuid.uuid4())
        os.makedirs(os.path.join(self.root, "spool"), exist_ok=True)
        wfile(self.sp(rid, "norun"), "norun mac=%s\n" % ("0" * 64))
        self.assertIn(" GONE ", self.attach(rid).err)
        # a run that finished and whose spool was then deleted: GONE, never NORUN
        p, rid, st, ts = self.start(["/bin/sh", "-c", "exit 0"])
        self.assertEqual(p.wait(30), 0)
        self.until(lambda: not os.path.exists(self.sp(rid, "lock")) or not self.keeper_holds(rid), 20, "the end")
        for n in os.listdir(os.path.join(self.root, "spool")):
            if n.startswith(rid):
                os.unlink(os.path.join(self.root, "spool", n))
        r = self.attach(rid)
        self.assertIn(" GONE ", r.err)
        self.assertNotIn("NORUN", r.err)

    def keeper_holds(self, rid):
        try:
            with open(self.sp(rid, "lock")) as f:
                fcntl.flock(f, fcntl.LOCK_SH | fcntl.LOCK_NB)
                return False
        except OSError:
            return True

    def test_a_kept_mirror_waits_for_its_detached_run_then_busy(self):
        """A lost link: the keeper still runs in the worktree's mirror; the client's next run of the
        same worktree must not check out under it - it waits (its slot-wait budget), then 73."""
        pidf, go2 = os.path.join(self.d, "pid"), os.path.join(self.d, "go2")
        p, rid, st, ts = self.start(["/bin/sh", "-c", "echo $$ > %s; while [ ! -e %s ]; do sleep 0.05; done"
                                     % (pidf, go2)], slots=2)
        self.wait_for(pidf)
        p.kill()
        p.wait()
        t0 = time.time()
        r = self.run_runner(["true"], slots=2, wait_min=0.03)          # ~2 s budget
        self.assertEqual(r.rc, 73, r.err)
        self.assertIn("an earlier run of this worktree still runs here", r.err)
        self.assertGreater(time.time() - t0, 1.5)
        open(go2, "w").close()                                          # the detached run ends
        self.until(lambda: not self.keeper_holds(rid), 20, "the keeper's end")
        self.assertEqual(self.run_runner(["true"], slots=2).rc, 0)       # the mirror is free again

for _n in [n for n in vars(RunnerTest) if n.startswith("test")]:
    setattr(DetachedRuns, _n, None)    # it reuses RunnerTest's fixture, not its tests


if __name__ == "__main__":
    unittest.main()
