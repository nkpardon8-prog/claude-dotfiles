"""token-usage-report.py: fixture tests for the per-agent-type, wait-step, checkpoint and
high-context sections, run against a tiny fake ~/.claude/projects tree.

Weights: cache-read 0.1, output 5. Step costs below are read*0.1 + output*5.

Run: /usr/bin/python3 -m unittest discover -s ~/.claude-dotfiles/scripts/tests -p 'test_token*.py' -v
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "token-usage-report.py"
_spec = importlib.util.spec_from_file_location("token_usage_report", SCRIPT)
tur = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tur)

T0 = time.time() - 3600


def ts(i):
    return datetime.fromtimestamp(T0 + i * 60, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def asst(i, mid, ctx, out, content=None):
    return {
        "type": "assistant",
        "timestamp": ts(i),
        "message": {
            "id": mid,
            "model": "claude-opus-5-5",
            "usage": {"input_tokens": 0, "cache_read_input_tokens": ctx,
                      "cache_creation_input_tokens": 0, "output_tokens": out},
            "content": content or [{"type": "text", "text": "ok"}],
        },
    }


def typed(i, text):
    return {"type": "user", "timestamp": ts(i), "promptSource": "typed",
            "message": {"role": "user", "content": text}}


def injected(i, text):  # no metadata: must be caught by the text markers
    return {"type": "user", "timestamp": ts(i), "message": {"role": "user", "content": text}}


def result(i):
    return {"type": "user", "timestamp": ts(i), "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t", "content": "done"}]}}


def bash(cmd):
    return [{"type": "tool_use", "id": "b", "name": "Bash", "input": {"command": cmd}}]


def wake(**inp):
    return [{"type": "tool_use", "id": "w", "name": "ScheduleWakeup", "input": inp}]


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


def build(home):
    proj = home / ".claude" / "projects" / "-proj-a"
    write_jsonl(proj / "s1.jsonl", [
        typed(0, "hello"),
        asst(1, "m1", 100_000, 1000),  # 15000
        # second streamed block of the same message.id: counted once, still tagged
        asst(1, "m1", 100_000, 1000, bash(
            "until grep -q done /Users/x/logs/safe-push.log; do sleep 30; done")),
        result(2),
        asst(3, "m2", 200_000, 1000),  # 25000
        result(4),
        asst(5, "m3", 100_000, 1000),  # 15000 - checkpoint: 100k < 60% of 200k
        injected(6, "<task-notification> <task-id>x</task-id> finished"),
        asst(7, "m4", 450_000, 1000, wake(reason="waiting for the codex review", delaySeconds=600)),
        result(8),
        asst(9, "m5", 420_000, 1000, bash("cat /Users/x/safe.txt")),  # 47000, not a loop
    ])
    write_jsonl(proj / "s2.jsonl", [
        typed(10, "go"),
        asst(11, "m6", 410_000, 1000, wake(stop=True, reason="codex")),  # 46000, ignored wake-up
        result(12),
        asst(13, "m7", 300_000, 1000, bash(  # 35000; path words must not classify it
            "while true; do sleep 5; cat /Users/x/build/safe.txt; done")),
    ])
    sub = proj / "s1" / "subagents"
    # a compact_boundary row between two steps = one compaction for that run (compacted column 1/1)
    write_jsonl(sub / "agent-a.jsonl", [asst(2, "m8", 10_000, 100),
                                        {"type": "system", "subtype": "compact_boundary"},
                                        asst(3, "m9", 30_000, 200)])
    (sub / "agent-a.meta.json").write_text(json.dumps({"agentType": "implementer", "finished": True}))
    write_jsonl(sub / "agent-b.jsonl", [asst(4, "m10", 20_000, 100), asst(4, "m10", 20_000, 100)])
    (sub / "agent-b.meta.json").write_text(json.dumps({"agentType": "implementer"}))
    return proj


def run(home, *args):
    env = dict(os.environ, HOME=str(home))
    p = subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True,
                       text=True, check=True)
    return p.stdout


def section(out, title):
    body = out.split("\n== " + title, 1)[1]
    return body.split("\n== ", 1)[0]


class TokenUsageReport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.home = Path(cls.tmp.name)
        cls.proj = build(cls.home)
        cls.out = run(cls.home, "--all-projects", "--days", "1")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_dedup_counts_each_message_once(self):
        # 7 main + 3 subagent calls; m1 and m10 each appear twice in their logs
        self.assertIn("API calls (deduped): 10  weighted spend: 241.0k", self.out)

    def test_per_agent_type(self):
        s = section(self.out, "Per agent type")
        rows = {ln.split()[0]: ln.split()[1:] for ln in s.strip().splitlines()[1:]}
        # main: avg ctx 1980k/7, peaks 450k (s1) and 410k (s2)
        self.assertEqual(rows["main"],
                         ["2", "7", "282.9k", "430.0k", "450.0k", "233.0k", "96.7%", "-", "-", "0/0"])
        # implementer: finished run a = 5.5k; run b has no finished flag -> unfinished
        self.assertEqual(rows["implementer"],
                         ["2", "3", "20.0k", "25.0k", "30.0k", "8.0k", "3.3%", "5.5k", "1", "1/1"])

    def test_wait_steps(self):
        s = section(self.out, "Wait steps")
        self.assertIn("all wait steps: 3  41.5% of spend", s)
        self.assertRegex(s, r"wake-up: Codex\s+1\s+20\.7%")
        self.assertRegex(s, r"check loop: push gate\s+1\s+6\.2%")
        self.assertRegex(s, r"check loop: other\s+1\s+14\.5%")
        self.assertNotIn("tests/typecheck/build", s)  # "/build/" is a directory, stripped

    def test_checkpoints(self):
        s = section(self.out, "Main-window checkpoints")
        self.assertIn("count: 1", s)
        self.assertIn("context before: median 200.0k  min 200.0k  max 200.0k   after: median 100.0k", s)

    def test_high_context_prompts(self):
        s = section(self.out, "Main steps at >= 400k")
        self.assertIn("steps >= 400k: 3", s)
        self.assertIn("with no human-typed prompt since the previous step: 2", s)
        self.assertIn("after an injected prompt (wake-up, notification, hook text): 1", s)
        self.assertIn("mid-turn (only tool results since the previous step): 1", s)
        self.assertIn("after a human-typed prompt: 1", s)
        self.assertIn("2  typed 1  injected 1", s)
        self.assertIn("climbs past 400k: 2  with a prompt boundary between 400k and 500k: 2", s)

    def test_single_project_mode_matches(self):
        out = run(self.home, "--project-dir", str(self.proj), "--days", "1")
        self.assertIn("API calls (deduped): 10  weighted spend: 241.0k", out)

    def test_wait_cause_ignores_path_directories(self):
        self.assertEqual(tur.wait_cause("cat /Users/x/safe.txt"), "other")
        self.assertEqual(tur.wait_cause("ls ~/Users/build/"), "other")
        self.assertEqual(tur.wait_cause("tail /tmp/safe-push.log"), "push gate")
        self.assertEqual(tur.wait_cause("npm run safe-push"), "push gate")
        self.assertEqual(tur.wait_cause("rrun npm test"), "tests/typecheck/build")
        self.assertEqual(tur.wait_cause("wait for the user to reply"), "other")

    def test_prompt_kind_metadata_and_markers(self):
        self.assertEqual(tur.prompt_kind(typed(0, "<command-name>/mission</command-name>")), "human")
        self.assertEqual(tur.prompt_kind(injected(0, "# Autonomous loop tick")), "injected")
        self.assertEqual(tur.prompt_kind(injected(0, "please continue")), "human")
        self.assertIsNone(tur.prompt_kind(result(0)))


if __name__ == "__main__":
    unittest.main()
