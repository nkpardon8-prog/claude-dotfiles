import os, sys, tempfile, unittest
from unittest import mock
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402,F401  (hermetic home + stubs before any rd_* import)
import rd_pool  # noqa: E402


W = [{"name": "laptop", "alias": "odwin-docker", "ip": "100.1.1.1"},
     {"name": "hp", "alias": "rd-hp", "ip": "100.1.1.2"}]


class SelfHeal(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.p = os.path.join(self.d, "rdocker")

    def write(self, text):
        with open(self.p, "w") as f:
            f.write(text)

    def test_all_present_no_rewrite(self):
        self.write("Host odwin-docker\n  Port 2222\nHost rd-hp\n  Port 22\nHost macmini-docker\n")
        with mock.patch("rd_fleet.ssh_blocks") as sb:
            self.assertFalse(rd_pool.ensure_ssh_blocks([], W, {}, self.p))
            sb.assert_not_called()

    def test_missing_alias_rewrites_once(self):
        self.write("Host macmini-docker\n  Port 2222\n")
        with mock.patch("rd_fleet.ssh_blocks", return_value=True) as sb:
            self.assertTrue(rd_pool.ensure_ssh_blocks(["F"], W, {}, self.p))
            sb.assert_called_once_with(["F"], None, self.p)

    def test_missing_file_rewrites(self):
        with mock.patch("rd_fleet.ssh_blocks", return_value=True) as sb:
            self.assertTrue(rd_pool.ensure_ssh_blocks([], W, {}, self.p))
            sb.assert_called_once()

    def test_entries_without_ip_ignored(self):
        self.write("Host odwin-docker\n")
        with mock.patch("rd_fleet.ssh_blocks") as sb:
            self.assertFalse(rd_pool.ensure_ssh_blocks([], [W[0], {"name": "x", "alias": "rd-x", "ip": ""}], {}, self.p))
            sb.assert_not_called()

    def test_writer_error_never_raises(self):
        with mock.patch("rd_fleet.ssh_blocks", side_effect=OSError("ro")):
            self.assertFalse(rd_pool.ensure_ssh_blocks([], W, {}, self.p))


class OnlyTheInstalledCopy(unittest.TestCase):
    """A stage / scratch copy (its own fleet.json) never rewrites the real ssh blocks (2026-11-14)."""
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.bin = os.path.join(self.d, "bin")
        os.makedirs(self.bin)
        self.fleet = os.path.join(self.d, "fleet.json")
        with open(self.fleet, "w") as f:
            f.write("{}")

    def check(self, target):
        link = os.path.join(self.bin, "rrun")
        if target:
            os.symlink(target, link)
        with mock.patch.object(rd_pool.rd_common, "BIN_DIR", self.bin), \
                mock.patch.object(rd_pool.rd_common, "FLEET_PATH", self.fleet), \
                mock.patch("rd_fleet.load", return_value=["F"]), \
                mock.patch("rd_fleet.workers", return_value=W), \
                mock.patch.object(rd_pool, "ensure_ssh_blocks") as eb:
            self.assertEqual(rd_pool.load_workers({"fleet_path": self.fleet}), W)
        return eb.called

    def test_the_installed_copy_self_heals(self):
        self.assertTrue(self.check(os.path.join(rd_pool.rd_common.HERE, "rrun")))

    def test_another_copy_never_does(self):
        self.assertFalse(self.check(os.path.join(self.d, "elsewhere", "rrun")))
        os.unlink(os.path.join(self.bin, "rrun"))
        self.assertFalse(self.check(None))                         # no rrun installed at all


if __name__ == "__main__":
    unittest.main()
