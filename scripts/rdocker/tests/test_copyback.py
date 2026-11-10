"""Build copy-back: rd_run.extract_outputs (staged, swapped into the worktree) and the end-to-end
path (`rrun --outputs` / rr_outputs-mapped `npm run build` -> second ssh tar -> worktree)."""
import io
import json
import os
import sys
import tarfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
import test_run  # noqa: E402

rd_run = rdmods.owner("rrun")
rd_common = rdmods.owner("RRUN_STATE")
wfile = test_run.wfile

FAKE_NPM = """#!/bin/sh
# fake npm: `npm run build` writes dist/ (where it runs) and says where that was
if [ "$1 $2" = "run build" ]; then mkdir -p dist/sub && echo "built $RDOCKER_MODE" > dist/out.txt && echo b > dist/sub/b.js; echo "build in $PWD"; exit 0; fi
echo "npm $*"
"""


def tar_bytes(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in members:
            ti = tarfile.TarInfo(name)
            if data is None:
                ti.type, ti.mode = tarfile.DIRTYPE, 0o755
                t.addfile(ti)
            elif isinstance(data, tuple):
                ti.type, ti.linkname = tarfile.SYMTYPE, data[1]
                t.addfile(ti)
            else:
                ti.size, ti.mode = len(data), 0o644
                t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


class Extract(test_run.RunBase):
    def listing(self, d):
        out = []
        for root, dirs, files in os.walk(d):
            out += [os.path.relpath(os.path.join(root, f), d) for f in files]
        return sorted(out)

    def test_swaps_outputs_in_and_drops_the_old_ones(self):
        wfile(os.path.join(self.wt, "server", "dist", "stale.js"), "old")
        wfile(os.path.join(self.wt, "server", "src.ts"), "keep")
        data = tar_bytes([("server/dist", None), ("server/dist/a.js", b"new"),
                          ("server/dist/lib/b.js", b"b"), ("client/dist/c.js", b"c")])
        n = rd_run.extract_outputs(self.wt, data, ["server/dist", "client/dist"])
        self.assertEqual(n, 3)
        self.assertEqual(self.listing(os.path.join(self.wt, "server")), ["dist/a.js", "dist/lib/b.js", "src.ts"])
        self.assertEqual(self.read(os.path.join(self.wt, "client", "dist", "c.js")), "c")
        self.assertEqual([x for x in os.listdir(self.wt) if x.startswith(".rrun-out-")], [])   # no staging left

    def test_refuses_anything_odd_and_leaves_the_worktree_alone(self):
        wfile(os.path.join(self.wt, "dist", "keep.js"), "old")
        for members in ([("dist/a.js", b"x"), ("dist/link", ("sym", "/etc/passwd"))],
                        [("dist/a.js", b"x"), ("other/b.js", b"y")],
                        [("dist/../escape.js", b"x")],
                        [("/abs/dist/a.js", b"x")],
                        [("dist/.git/config", b"x")]):
            with self.subTest(members=[m[0] for m in members]):
                with self.assertRaises(rd_run.RunError):
                    rd_run.extract_outputs(self.wt, tar_bytes(members), ["dist"])
                self.assertEqual(self.listing(os.path.join(self.wt, "dist")), ["keep.js"])
                self.assertEqual([x for x in os.listdir(self.wt) if x.startswith(".rrun-out-")], [])
        os.symlink(self.d, os.path.join(self.wt, "out"))           # an output whose parent escapes
        with self.assertRaises(rd_run.RunError):
            rd_run.extract_outputs(self.wt, tar_bytes([("out/x/a.js", b"x")]), ["out/x"])


class CopyBackE2E(test_run.RunBase):
    def setUp(self):
        super().setUp()
        wfile(os.path.join(self.bin, "npm"), FAKE_NPM, 0o755)

    def test_outputs_flag_copies_back_and_replaces(self):
        # dist is ignored (as builds are): `git clean` on the worker keeps it, the runner must not
        with open(os.path.join(self.wt, ".gitignore"), "a") as f:
            f.write("dist\n")
        self.git("-C", self.wt, "commit", "-qam", "ignore dist")
        wfile(os.path.join(self.wt, "dist", "stale.txt"), "stale")
        r = self.rrun("--outputs", "dist", "/bin/sh", "-c",
                      "test ! -e dist/stale.txt && mkdir -p dist/sub && echo new > dist/a.txt && echo b > dist/sub/b.js")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("copied back dist (2 files)", r.stderr)
        self.assertEqual(sorted(os.listdir(os.path.join(self.wt, "dist"))), ["a.txt", "sub"])
        self.assertEqual(self.read(os.path.join(self.wt, "dist", "a.txt")), "new\n")
        # a stale output in the worker's mirror (dist is untracked there) never comes back
        r = self.rrun("--outputs=dist", "/bin/sh", "-c", "test ! -e dist/a.txt && mkdir -p dist && echo 2 > dist/c.txt")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.listdir(os.path.join(self.wt, "dist")), ["c.txt"])

    def test_failed_build_copies_nothing(self):
        wfile(os.path.join(self.wt, "dist", "keep.txt"), "keep")
        r = self.rrun("--outputs", "dist", "/bin/sh", "-c", "mkdir -p dist && echo half > dist/x.txt; exit 2")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertNotIn("copied back", r.stderr)
        self.assertEqual(os.listdir(os.path.join(self.wt, "dist")), ["keep.txt"])
        r = self.rrun("--outputs", "../x", "true")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("is not a path inside this worktree", r.stderr)

    def test_copy_back_lost_is_75(self):
        r = self.rrun("--outputs", "dist", "/bin/sh", "-c", "mkdir -p dist && echo x > dist/a.txt")
        self.assertEqual(r.returncode, 0, r.stderr)                     # baseline: works
        # the second ssh (tar) fails: the build ran, its outputs are not here -> 75, never a rerun
        fake = os.path.join(self.bin, "ssh")
        real = self.read(fake)
        wfile(fake, real.replace('cmd = " ".join(args[i + 1:])',
                                 'cmd = " ".join(args[i + 1:])\nif "tar -cf" in cmd:\n    sys.exit(255)'), 0o755)
        r = self.rrun("--outputs", "dist", "/bin/sh", "-c", "mkdir -p dist && echo y > dist/a.txt")
        self.assertEqual(r.returncode, 75, r.stderr)
        self.assertIn("outputs could not be copied back", r.stderr)
        self.assertEqual(self.read(os.path.join(self.wt, "dist", "a.txt")), "x\n")

    def test_mapped_npm_build_goes_remote_unmapped_stays_here(self):
        wfile(os.path.join(self.wt, "server", "package.json"), "{}")
        self.write_cfg(rr_outputs={"wt": {"server": ["dist"]}})
        r = self.rrun("npm", "run", "build", cwd=os.path.join(self.wt, "server"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("build in %s" % os.path.join(os.path.realpath(self.mirror()), "server"), r.stdout)
        self.assertEqual(self.read(os.path.join(self.wt, "server", "dist", "out.txt")), "built \n")
        os.unlink(self.sshlog)
        wfile(os.path.join(self.wt, "client", "package.json"), "{}")
        r = self.rrun("npm", "run", "build", cwd=os.path.join(self.wt, "client"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")                                    # silently local
        self.assertEqual(self.read(os.path.join(self.wt, "client", "dist", "out.txt")), "built local\n")
        self.assertFalse(os.path.exists(self.sshlog))
        st = json.loads(self.read(rd_common.RRUN_STATE.replace(rdmods.TEST_HOME, self.home)))
        self.assertEqual(st["last"]["target"], "mini")                    # the remote build


if __name__ == "__main__":
    unittest.main()
