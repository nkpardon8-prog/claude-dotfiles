"""Unit tests for rdocker's routing decisions (no docker / network needed).

Run: /usr/bin/python3 -m unittest discover -s ~/.claude-dotfiles/scripts/rdocker/tests -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import rdocker as r  # noqa: E402


class RunRouting(unittest.TestCase):
    def needs(self, cmd):
        return r.run_needs_local(cmd.split())

    def test_named_volume_and_ports_stay_remote(self):
        self.assertIsNone(self.needs("-d --name x -e A=1 -p 127.0.0.1::5432 -v pgdata:/var/lib/postgresql/data postgres:17"))

    def test_bind_mounts_go_local(self):
        self.assertTrue(self.needs("--rm -v /tmp/x:/w alpine true"))
        self.assertTrue(self.needs("--rm -v ./init.sql:/docker-entrypoint-initdb.d/i.sql postgres:17"))
        self.assertTrue(self.needs("--rm --volume=/Users/me/p:/p alpine ls"))
        self.assertTrue(self.needs("--rm --mount type=bind,src=/tmp,dst=/t alpine ls"))

    def test_host_network_goes_local(self):
        self.assertTrue(self.needs("--rm --network host postgres:17 pg_dump x"))
        self.assertTrue(self.needs("--rm --net=host alpine true"))

    def test_docker_socket_mount_is_not_a_laptop_bind(self):
        self.assertIsNone(self.needs("--rm -v /var/run/docker.sock:/var/run/docker.sock alpine true"))

    def test_flags_after_image_belong_to_the_container(self):
        # psql's -v must not be read as a docker volume; --network after the image is psql's arg
        self.assertIsNone(self.needs("--rm postgres:17 psql -v /x:/y --network host"))

    def test_combined_short_flags(self):
        self.assertIsNone(self.needs("-dit --rm -p5432:5432 postgres:17"))
        self.assertTrue(self.needs("-it --rm -v/tmp:/t alpine sh"))


class Parsing(unittest.TestCase):
    def test_split_global(self):
        self.assertEqual(r.split_global(["--context", "x", "ps", "-a"]), (["--context", "x"], ["ps", "-a"]))
        self.assertEqual(r.split_global(["-D", "run", "img"]), (["-D"], ["run", "img"]))

    def test_container_targets(self):
        self.assertEqual(r.container_targets("exec", ["-i", "-e", "A=1", "db", "psql"]), ["db"])
        self.assertEqual(r.container_targets("rm", ["-f", "a", "b"]), ["a", "b"])
        self.assertEqual(r.container_targets("cp", ["db:/x.sql", "./x.sql"]), ["db"])
        self.assertEqual(r.container_targets("logs", ["--tail", "5", "db"]), ["db"])

    def test_compose_split(self):
        self.assertEqual(r.compose_split(["-f", "a.yml", "-p", "p", "up", "-d"]),
                         (["-f", "a.yml", "-p", "p"], "up", ["-d"]))

    def test_port_regex(self):
        line = "127.0.0.1:5715->5432/tcp, 0.0.0.0:80->80/tcp, [::]:80->80/tcp, 10.0.0.5:9->9/tcp, 5432/tcp"
        got = sorted({int(a) for ip, a, b in r.PORT_RE.findall(line)
                      if not ip or ip in ("127.0.0.1", "0.0.0.0", "::", "[::]")})
        self.assertEqual(got, [80, 5715])

    def test_port_range(self):
        self.assertEqual(r.PORT_RE.findall("127.0.0.1:8000-8002->8000-8002/tcp"), [("127.0.0.1", "8000", "8002")])

    def test_ttl_and_timestamps(self):
        self.assertEqual(r.parse_ttl("30m"), 1800)
        self.assertEqual(r.parse_ttl("2h"), 7200)
        self.assertEqual(r.parse_ttl("1d"), 86400)
        self.assertEqual(r.parse_ttl("45"), 45)
        self.assertIsNone(r.parse_ttl("soon"))
        self.assertEqual(r.parse_ts("0001-01-01T00:00:00Z"), 0)
        self.assertEqual(r.parse_ts("2026-10-13T00:00:00.123456789Z"), 1791849600.0)

    def test_bind_source(self):
        for s in ("/abs", "./rel", "~/h", "$PWD"):
            self.assertTrue(r.is_bind_source(s))
        for s in ("pgdata", "/var/run/docker.sock"):
            self.assertFalse(r.is_bind_source(s))


if __name__ == "__main__":
    unittest.main()
