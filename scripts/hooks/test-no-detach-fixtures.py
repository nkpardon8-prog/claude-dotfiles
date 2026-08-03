#!/usr/bin/env python3
"""
Fixture suite for no-detach-gate.py (the PreToolUse Bash gate that blocks a
shell-detach wrapping a codex launch).

Reads the shared case table `fixtures/no-detach-cases.tsv` (resolved relative to
THIS file's location), and for each row runs the REAL gate as a subprocess fed
the exact PreToolUse stdin JSON payload `{"tool_input":{"command":"..."}}`.

Asserts the gate's exit code matches the row's expectation:
  * block -> exit 2
  * allow -> exit 0

Prints `PASS: N/N` on full success (exit 0); otherwise lists each failure and
exits 1. Mirrors the style of test-prod-classifier-fixtures.py.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "no-detach-gate.py")
FIXTURES = os.path.join(HERE, "fixtures", "no-detach-cases.tsv")

EXPECT_EXIT = {"block": 2, "allow": 0}


def load_cases(path):
    cases = []
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise RuntimeError(f"{path}:{lineno}: row needs at least command<TAB>expect")
            command = parts[0]
            expect = parts[1].strip()
            note = parts[2] if len(parts) > 2 else ""
            if expect not in EXPECT_EXIT:
                raise RuntimeError(f"{path}:{lineno}: expect must be 'block' or 'allow', got {expect!r}")
            cases.append((command, expect, note))
    return cases


def run_gate(command):
    payload = json.dumps({"tool_input": {"command": command}})
    r = subprocess.run(
        [sys.executable, GATE],
        input=payload,
        capture_output=True, text=True, timeout=30,
    )
    return r.returncode, r.stderr


def main():
    cases = load_cases(FIXTURES)
    failures = []
    for command, expect, note in cases:
        want = EXPECT_EXIT[expect]
        rc, stderr = run_gate(command)
        if rc != want:
            failures.append((command, expect, want, rc, note, stderr.strip()))

    total = len(cases)
    if failures:
        print(f"FAIL: {total - len(failures)}/{total} passed, {len(failures)} failed")
        for command, expect, want, rc, note, stderr in failures:
            print(f"  FAIL expect={expect}(exit {want}) got exit {rc}")
            print(f"       cmd={command!r}")
            if note:
                print(f"       note={note}")
            if stderr:
                print(f"       stderr={stderr!r}")
        return 1

    print(f"PASS: {total}/{total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
