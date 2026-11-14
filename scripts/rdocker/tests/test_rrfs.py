"""server/rd-rrfs.sh: the reflink ~/rr volume. Sizing, the copy rules (store dedupe made exact by checksum,
store-covered mirror node_modules left out, reinstalled ones recopied), the idle-only cutover under the slot
locks, rollback and drop-old - all against temp dirs, with a fake loop volume (mount/umount move one
directory in and out of place) and fake findmnt/mountpoint/losetup/mkfs.xfs. Never touches a real ~/rr."""
import fcntl
import hashlib
import os
import pwd
import shutil
import subprocess
import tempfile
import unittest

import rdmods
from rdmods import STAGE

RRFS = os.path.join(STAGE, "server", "rd-rrfs.sh")
PROV = os.path.join(STAGE, "server", "provision-linux.sh")
NPM_MTIME = 499162500   # 1985-10-26T08:15:00Z: npm's fixed mtime for every package file

# The fake volume: $FS/vol is the volume's content while unmounted; mount moves it onto the (empty) dir.
FAKES = {
    "mountpoint": '[ "$1" = -q ] && shift; grep -qxF -- "$1" "$FS/mounted" 2>/dev/null\n',
    "findmnt": ('for a; do p=$a; done\nwhile IFS= read -r m; do case "$p/" in "$m"/*) echo xfs; exit 0 ;; esac; done '
                '< "$FS/mounted" 2>/dev/null\necho ext4\n'),
    "losetup": ('case "$1" in -j) cat "$FS/loop" 2>/dev/null ;; *) echo /dev/loop9 > "$FS/loop"; echo /dev/loop9 ;; esac\n'),
    "mount": ('for a; do d=$a; done\n[ -d "$FS/vol" ] || { echo "fake mount: no volume" >&2; exit 32; }\n'
              'rmdir "$d" || exit 32\nmv "$FS/vol" "$d" && echo "$d" >> "$FS/mounted"\n'),
    "umount": ('grep -qxF -- "$1" "$FS/mounted" || exit 32\nmv "$1" "$FS/vol" && mkdir "$1"\n'
               'grep -vxF -- "$1" "$FS/mounted" > "$FS/m.tmp"; mv "$FS/m.tmp" "$FS/mounted"\n'),
    "chattr": "exit 0\n",
    "blkid": '[ -f "$FS/formatted" ] && echo xfs\n',
    "mkfs.xfs": 'touch "$FS/formatted"; mkdir -p "$FS/vol"; echo "$*" > "$FS/mkfs.args"\n',
    "truncate": 'perl -e \'open my $f, ">>", $ARGV[1] or die; truncate $f, $ARGV[0] =~ /^(\\d+)G$/ ? $1 << 30 : $ARGV[0]\' "$2" "$3"\n',
    "pgrep": 'cat "$FS/pids" 2>/dev/null\n',
}


def tree(root):
    """{relative path: content} of every file under root (symlinks as 'L:<target>')."""
    out = {}
    for d, dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            rel = os.path.relpath(p, root)
            out[rel] = ("L:" + os.readlink(p)) if os.path.islink(p) else open(p, "rb").read()
    return out


def deps_key(slug, rel, stamp):   # rr_runner.pl deps_key
    return hashlib.sha256(("%s\0%s\0%s" % (slug, rel, stamp)).encode()).hexdigest()[:32]


class RrfsBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rdk-rrfs-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.rr, self.stage, self.fs = (os.path.join(self.tmp, d) for d in ("home/rr", "stage", "fs"))
        self.img = os.path.join(self.tmp, "img", "rr.xfs")
        self.bin = os.path.join(self.tmp, "bin")
        for d in (self.rr, self.fs, self.bin, os.path.dirname(self.img)):
            os.makedirs(d)
        open(os.path.join(self.fs, "mounted"), "w").close()
        for name, body in FAKES.items():
            p = os.path.join(self.bin, name)
            with open(p, "w") as f:
                f.write("#!/bin/sh\n" + body)
            os.chmod(p, 0o755)
        self.user = pwd.getpwuid(os.getuid()).pw_name
        with open(os.path.join(self.tmp, "tune.conf"), "w") as f:
            f.write("RD_USER=%s\n" % self.user)
        self.df_avail_gb = 500

    def run_rrfs(self, *args, **extra):
        df = os.path.join(self.bin, "fake-df")
        with open(df, "w") as f:
            f.write("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\n"
                    "echo \"/dev/x 1000000000 1 %d 1%% $1\"\n" % (self.df_avail_gb * 1048576))
        os.chmod(df, 0o755)
        env = rdmods.child_env(self.tmp, self.bin, **{
            "FS": self.fs, "RD_CONF": os.path.join(self.tmp, "tune.conf"), "RD_RRFS_ROOT": self.rr,
            "RD_RRFS_IMG": self.img, "RD_RRFS_STAGE": self.stage, "RD_RRFS_UNIT_DIR": os.path.join(self.tmp, "units"),
            "RD_RRFS_CLONE": "cp -a", "RD_RRFS_OTHER_IMGS": os.path.join(self.tmp, "no-other.img"), "RD_DF_CMD": df,
            "RD_NO_SERVICES": "1", "RD_RRFS_SELF": "/usr/local/bin/rd-rrfs",
            "RD_RRFS_LOCK": os.path.join(self.tmp, "rrfs.lock"), **extra})
        return subprocess.run(["/bin/bash", RRFS] + list(args), capture_output=True, text=True, env=env, timeout=120)

    def write(self, rel, content, mtime=None, root=None):
        p = os.path.join(root or self.rr, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(content)
        if mtime is not None:
            os.utime(p, (mtime, mtime))
        return p

    def store_entry(self, key, name, stamp, files, mtime=None):
        nm = "deps/%s/node_modules" % key
        self.write(nm + "/.package-lock.json", '{\n  "name": "%s",\n  "lockfileVersion": 3\n}\n' % name)
        self.write(nm + "/.rr-deps-stamp", stamp)
        for rel, body in files.items():
            self.write(nm + "/" + rel, body, NPM_MTIME)
        if mtime is not None:
            os.utime(os.path.join(self.rr, "deps", key), (mtime, mtime))

    MIRROR = "w2/app.1234-aaaaaaaaaaaa"

    def mirror_with_store(self):
        m = self.MIRROR
        self.store_entry(deps_key("app.1234", "", "S1"), "app", "S1", {"pkg/index.js": "AAAA"})
        self.write(m + "/src/main.ts", "code\n")
        self.write(m + "/node_modules/.rr-deps-stamp", "S1")
        self.write(m + "/node_modules/.package-lock.json", '{\n  "name": "app",\n  "lockfileVersion": 3\n}\n')
        self.write(m + "/node_modules/pkg/index.js", "AAAA", NPM_MTIME)
        self.write(m + "/node_modules/.prisma/client/index.js", "generated by a run\n")   # not in the store
        self.write(m + "/tools/node_modules/.rr-deps-stamp", "S9")         # no store entry: copied whole
        self.write(m + "/tools/node_modules/t/index.js", "TTTT", NPM_MTIME)
        return m

    def make_image(self):
        r = self.run_rrfs("create", "--gb", "20")
        self.assertEqual(r.returncode, 0, r.stderr)

    def basic_rr(self):
        os.makedirs(os.path.join(self.rr, "slots"))
        for n in ("0", "1", "heavy-0"):
            open(os.path.join(self.rr, "slots", n), "w").close()
        self.write("git/app.1234.git/HEAD", "ref: refs/heads/main\n")
        self.write("log/runs.log", "one\n")
        os.symlink("HEAD", os.path.join(self.rr, "git/app.1234.git/link"))


class Static(unittest.TestCase):
    def test_bash_syntax_and_shellcheck(self):
        subprocess.run(["/bin/bash", "-n", RRFS], check=True)
        sc = shutil.which("shellcheck")
        if sc:
            r = subprocess.run([sc, "-S", "warning", RRFS], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout)

    def test_unit_orders_the_mount_before_everything_that_writes_rr(self):
        with open(RRFS) as f:
            src = f.read()
        for want in ("Before=ssh.service sshd.service docker.service rd-tune.service rd-doctor.service "
                     "systemd-user-sessions.service", "ExecStart=$SELF mount", "--direct-io=on",
                     "mkfs.xfs -q -m reflink=1"):
            self.assertIn(want, src)

    def test_provision_installs_and_wires_it(self):
        with open(PROV) as f:
            prov = f.read()
        self.assertIn('put_file /usr/local/bin/rd-rrfs 755 < "$SRC/rd-rrfs.sh"', prov)
        self.assertIn("rd-rrfs create --gb", prov)
        # the volume must be in place before rd-tune / the reporter / resilience start writing ~/rr
        self.assertLess(prov.index("say rr-volume"), prov.index("say rd-tune"))


class Sizing(RrfsBase):
    def test_max_gb_counts_rr_moving_in_and_other_sparse_images(self):
        other = os.path.join(self.tmp, "docker.img")
        with open(other, "wb") as f:
            f.truncate(10 << 30)                       # 10 GB logical, nothing allocated yet
        du = os.path.join(self.bin, "fake-du")
        with open(du, "w") as f:
            f.write("#!/bin/sh\nprintf '%%d\\t%%s\\n' %d \"$2\"\n" % (30 * 1048576))
        os.chmod(du, 0o755)
        self.df_avail_gb = 40
        r = self.run_rrfs("max-gb", RD_RRFS_OTHER_IMGS=other, RD_DU_CMD=du)
        self.assertEqual(r.stdout.strip(), str(40 + 30 - 10 - 15), r.stderr)   # avail + rr - other - reserve

    def test_create_refuses_an_image_that_could_overfill_the_disk(self):
        self.df_avail_gb = 20
        r = self.run_rrfs("create", "--gb", "50")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("could overfill", r.stderr)
        self.assertFalse(os.path.exists(self.img))

    def test_create_formats_writes_the_unit_and_is_idempotent(self):
        r = self.run_rrfs("create", "--gb", "20")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.path.getsize(self.img), 20 << 30)
        self.assertIn("-m reflink=1", open(os.path.join(self.fs, "mkfs.args")).read())
        unit = open(os.path.join(self.tmp, "units", "rd-rrfs.service")).read()
        self.assertIn("ExecStart=/usr/local/bin/rd-rrfs mount", unit)
        self.assertIn("ConditionPathExists=%s" % self.img, unit)
        r2 = self.run_rrfs("create", "--gb", "20")
        self.assertEqual((r2.returncode, r2.stdout), (0, ""), r2.stderr)

    def test_create_needs_a_size(self):
        self.assertNotEqual(self.run_rrfs("create", "--gb", "x").returncode, 0)


class Copy(RrfsBase):
    def setUp(self):
        super().setUp()
        self.basic_rr()
        self.make_image()

    def test_store_entries_dedupe_on_a_base_but_end_up_exact(self):
        # k1 (newer) is copied first and becomes k2's base; k2's index.js has the same size and npm's fixed
        # mtime but other bytes - only a checksum pass can tell, and k1-only files must not leak into k2
        self.store_entry("k1", "app", "S1", {"pkg/index.js": "AAAA", "only-k1.js": "x"}, mtime=2000000000)
        self.store_entry("k2", "app", "S2", {"pkg/index.js": "BBBB", "only-k2.js": "y"}, mtime=1900000000)
        r = self.run_rrfs("presync")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("store: 2 new of 2 entries", r.stdout)
        for k in ("k1", "k2"):
            self.assertEqual(tree(os.path.join(self.stage, "deps", k)), tree(os.path.join(self.rr, "deps", k)))
        self.assertEqual(tree(os.path.join(self.stage, "git")), tree(os.path.join(self.rr, "git")))
        # a later pass copies only new entries and drops vanished ones
        shutil.rmtree(os.path.join(self.rr, "deps", "k1"))
        self.store_entry("k3", "app", "S3", {"pkg/index.js": "CCCC"})
        r = self.run_rrfs("presync")
        self.assertIn("store: 1 new of 2 entries", r.stdout)
        self.assertEqual(sorted(os.listdir(os.path.join(self.stage, "deps"))), ["k2", "k3"])
        self.assertEqual(tree(os.path.join(self.stage, "deps", "k3")), tree(os.path.join(self.rr, "deps", "k3")))

    def test_mirrors_are_exact_store_covered_node_modules_reflinked_first(self):
        m = self.mirror_with_store()
        r = self.run_rrfs("presync")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("mirrors: 1 copied, 1 node_modules reflinked from the store first", r.stdout)
        self.assertEqual(tree(os.path.join(self.stage, m)), tree(os.path.join(self.rr, m)))   # all of it
        # reinstalled between passes: same size, npm's mtime, new stamp -> copied whole again, so exact
        self.write(m + "/tools/node_modules/.rr-deps-stamp", "S10")
        self.write(m + "/tools/node_modules/t/index.js", "UUUU", NPM_MTIME)
        self.assertEqual(self.run_rrfs("presync").returncode, 0)
        self.assertEqual(tree(os.path.join(self.stage, m)), tree(os.path.join(self.rr, m)))
        # a mirror the janitor removed is removed from the stage too
        shutil.rmtree(os.path.join(self.rr, m))
        self.assertEqual(self.run_rrfs("presync").returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.stage, m)))

    def test_vanished_files_are_not_a_failure_and_trash_is_never_copied(self):
        self.write(".trash/w-old.1/f.js", "being deleted")
        fake = os.path.join(self.bin, "rsync-vanish")
        with open(fake, "w") as f:      # a real copy, then the exit code of files that vanished meanwhile
            f.write('#!/bin/sh\n/usr/bin/rsync "$@"; rc=$?; [ $rc = 0 ] || exit $rc\n'
                    'echo \'file has vanished: "/x"\' >&2; exit 24\n')
        os.chmod(fake, 0o755)
        r = self.run_rrfs("presync", RD_RRFS_RSYNC=fake)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("has vanished", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.stage, ".trash")))
        self.assertTrue(os.path.exists(os.path.join(self.stage, "git/app.1234.git/HEAD")))

    def test_a_second_copy_refuses_while_one_runs_and_a_dead_lock_is_taken_over(self):
        lock = os.path.join(self.tmp, "rrfs.lock")
        os.makedirs(lock)
        sleeper = subprocess.Popen(["/bin/sleep", "30"])
        self.addCleanup(sleeper.kill)
        with open(os.path.join(lock, "pid"), "w") as f:
            f.write(str(sleeper.pid))
        r = self.run_rrfs("presync")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("busy: another rd-rrfs (pid %d)" % sleeper.pid, r.stderr)
        sleeper.kill()
        sleeper.wait()
        r = self.run_rrfs("presync")                                   # the holder died: taken over
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(lock))                         # released on exit

    def test_copy_stops_when_the_disk_under_the_image_runs_low(self):
        self.store_entry("k1", "app", "S1", {"a.js": "x"})
        self.df_avail_gb = 10                                          # < the 15 GB reserve
        r = self.run_rrfs("presync")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("< 15 GB", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.stage, "deps", "k1")))


class Cutover(RrfsBase):
    def setUp(self):
        super().setUp()
        self.basic_rr()
        self.store_entry("k1", "app", "S1", {"a.js": "x"})
        self.make_image()
        r = self.run_rrfs("presync")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.old = self.rr + ".pre-xfs"

    def test_refuses_while_a_slot_is_held(self):
        with open(os.path.join(self.rr, "slots", "1"), "r+") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = self.run_rrfs("cutover")
        self.assertEqual(r.returncode, 75, r.stderr)
        self.assertIn("busy: slot 1 is held", r.stderr)
        self.assertFalse(os.path.exists(self.old))

    def test_runners_waiting_for_a_slot_do_not_block(self):
        with open(os.path.join(self.fs, "pids"), "w") as f:
            f.write("4242\n4243\n")
        r = self.run_rrfs("cutover")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("all slots free; 2 runner(s) waiting for a slot", r.stdout)
        self.assertTrue(os.path.exists(self.old))

    def test_cutover_final_pass_then_rollback_then_drop_old(self):
        before = tree(self.rr)
        self.write("log/after-presync.log", "late\n")                   # the final pass must carry it
        r = self.run_rrfs("cutover")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("cutover done", r.stdout)
        self.assertIn(self.rr, open(os.path.join(self.fs, "mounted")).read().split())
        self.assertEqual(open(os.path.join(self.rr, "log/after-presync.log")).read(), "late\n")
        self.assertEqual(tree(os.path.join(self.rr, "deps")), tree(os.path.join(self.old, "deps")))
        self.assertTrue(os.path.islink(os.path.join(self.rr, "git/app.1234.git/link")))
        self.assertEqual(tree(self.old), {**before, "log/after-presync.log": b"late\n"})
        st = self.run_rrfs("status").stdout
        self.assertIn("fs=xfs reflink=1", st)
        self.assertIn("staged=0 old=1", st)
        self.assertEqual(self.run_rrfs("cutover").returncode, 0)        # again: a no-op
        # rollback puts the old tree back
        r = self.run_rrfs("rollback")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.old))
        self.assertEqual(open(os.path.join(self.rr, "log/after-presync.log")).read(), "late\n")
        self.assertNotIn(self.rr, open(os.path.join(self.fs, "mounted")).read().split())

    def test_dirs_the_copy_makes_keep_rr_modes(self):
        """deps/ w/ w2/ are made by the script (root on a worker): they must take ~/rr's owner and mode."""
        self.write("w2/app.1234-aaaaaaaaaaaa/src.ts", "x")
        for d in ("deps", "w2"):
            os.chmod(os.path.join(self.rr, d), 0o711)
        r = self.run_rrfs("presync")
        self.assertEqual(r.returncode, 0, r.stderr)
        for d in ("deps", "w2"):
            self.assertEqual(os.stat(os.path.join(self.stage, d)).st_mode & 0o7777, 0o711, d)

    def test_a_tree_the_rd_user_cannot_write_rolls_back(self):
        os.makedirs(os.path.join(self.rr, "state"))
        os.chmod(os.path.join(self.rr, "state"), 0o500)                 # copied as it is: unwritable
        self.addCleanup(os.chmod, os.path.join(self.rr, "state"), 0o700)
        self.assertEqual(self.run_rrfs("presync").returncode, 0)
        r = self.run_rrfs("cutover")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("cannot write: state", r.stderr)
        self.assertIn("rolling back", r.stderr)
        self.assertFalse(os.path.exists(self.old))
        self.assertNotIn(self.rr, open(os.path.join(self.fs, "mounted")).read().split())
        self.assertEqual(open(os.path.join(self.rr, "log/runs.log")).read(), "one\n")
        os.chmod(os.path.join(self.fs, "vol", "state"), 0o700)           # let tearDown remove the volume

    def test_restore_nm_puts_back_what_an_older_cutover_left_out(self):
        m = self.mirror_with_store()
        self.assertEqual(self.run_rrfs("presync").returncode, 0)
        self.assertEqual(self.run_rrfs("cutover").returncode, 0)
        shutil.rmtree(os.path.join(self.rr, m, "node_modules"))          # what rd-rrfs before 2026-11-14 did
        lock = os.path.join(self.rr, "w2", ".app.1234-aaaaaaaaaaaa.lock")
        with open(lock, "w") as fh:                                     # a run holds the mirror: skipped
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = self.run_rrfs("restore-nm")
        self.assertIn("0 node_modules put back, 1 skipped (mirror in use)", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.rr, m, "node_modules")))
        r = self.run_rrfs("restore-nm")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1 node_modules put back, 0 skipped", r.stdout)
        self.assertEqual(tree(os.path.join(self.rr, m, "node_modules")), tree(os.path.join(self.old, m, "node_modules")))
        self.assertIn("0 node_modules put back", self.run_rrfs("restore-nm").stdout)   # idempotent

    def test_drop_old_only_once_rr_is_the_volume(self):
        r = self.run_rrfs("drop-old")
        self.assertNotEqual(r.returncode, 0)                           # before cutover: refuses
        self.assertEqual(self.run_rrfs("cutover").returncode, 0)
        r = self.run_rrfs("drop-old")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.old))
        self.assertTrue(os.path.isdir(os.path.join(self.rr, "deps", "k1")))

    def test_boot_mount_refuses_a_non_empty_rr(self):
        r = self.run_rrfs("mount")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("is not empty", r.stderr)


if __name__ == "__main__":
    unittest.main()
