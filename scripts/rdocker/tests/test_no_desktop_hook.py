"""no-docker-desktop.py: agents may not launch laptop Docker Desktop by hand (RDOCKER_LOCAL_START=1 opts in)."""
import json
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rdmods import STAGE  # noqa: E402

HOOK = next((p for p in (os.path.join(STAGE, "_hooks_stage", "no-docker-desktop.py"),
                         os.path.join(os.path.dirname(STAGE), "hooks", "no-docker-desktop.py"))
             if os.path.isfile(p)), "no-docker-desktop.py not found")

BLOCK = ["open -a Docker", "open -ga Docker", "open -a 'Docker Desktop'", "open /Applications/Docker.app",
         "docker info >/dev/null 2>&1 || { open -a Docker; sleep 3; }",
         "osascript -e 'tell application \"Docker\" to activate'", "docker desktop start"]
ALLOW = ["RDOCKER_LOCAL_START=1 open -a Docker", "open -a Safari", "open README.md", "docker ps",
         'grep -n "open -a Docker" notes.md', "osascript -e 'quit app \"Docker\"'", "rdocker doctor"]


class NoDockerDesktop(unittest.TestCase):
    def rc(self, cmd, tool="Bash"):
        p = subprocess.run(["/usr/bin/python3", "-I", HOOK],
                           input=json.dumps({"tool_name": tool, "tool_input": {"command": cmd}}),
                           capture_output=True, text=True, timeout=30)
        return p.returncode, p.stderr

    def test_launches_blocked(self):
        for c in BLOCK:
            with self.subTest(c=c):
                rc, err = self.rc(c)
                self.assertEqual(rc, 2)
                self.assertIn("rdocker doctor", err)

    def test_everything_else_allowed(self):
        for c in ALLOW:
            with self.subTest(c=c):
                self.assertEqual(self.rc(c)[0], 0)

    def test_fails_open(self):
        p = subprocess.run(["/usr/bin/python3", "-I", HOOK], input="not json", capture_output=True,
                           text=True, timeout=30)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(self.rc("open -a Docker", tool="Read")[0], 0)


if __name__ == "__main__":
    unittest.main()
