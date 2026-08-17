#!/usr/bin/env python3
"""Does the regex WRITTEN IN THE PLAN compile to exactly the regex that was MEASURED?

A plan whose pasted pattern differs from the scored one documents a candidate that was never tested -
the same drift class as a scorer holding its own frozen copy of the hook. This closes it: extract
Edit A from the plan markdown, compile it, and compare against 09's INTERP_R6 character for
character.

Revision 5 has no Edit D (withdrawn, gated on pd:6), so this compares Edit A alone.
"""
import contextlib
import importlib.util
import io
import os
import re
import sys

D = os.path.dirname(os.path.abspath(__file__))
PLAN = os.path.expanduser(
    "~/.claude-dotfiles/tmp/ready-plans/2026-08-16-prod-classifier-residual-fix.md")

sys.argv = ["x"]
spec = importlib.util.spec_from_file_location("r6", os.path.join(D, "09-revision6-minimal-delta.py"))
r6 = importlib.util.module_from_spec(spec)
try:
    with contextlib.redirect_stdout(io.StringIO()):
        spec.loader.exec_module(r6)
except SystemExit:
    pass   # 09 exits with its own status; we only need its module namespace

md = open(PLAN).read()
blocks = re.findall(r"```python\n(.*?)```", md, re.S)
edit_a = next((b for b in blocks if "INTERP = re.compile(" in b), None)
if not edit_a:
    sys.exit("08: Edit A block not found in the plan")

ns = {"re": re}
exec(compile(edit_a, "<plan Edit A>", "exec"), ns)
plan_rx = ns["INTERP"]

ok = plan_rx.pattern == r6.INTERP_R6.pattern
print(f"plan pattern length     : {len(plan_rx.pattern)}")
print(f"measured pattern length : {len(r6.INTERP_R6.pattern)}")
print(f"\n{'MATCH - the plan documents exactly what was measured' if ok else 'MISMATCH'}")
if not ok:
    a, b = plan_rx.pattern, r6.INTERP_R6.pattern
    i = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
    print(f"first divergence at char {i}:\n  plan     ...{a[max(0, i - 60):i + 60]!r}\n"
          f"  measured ...{b[max(0, i - 60):i + 60]!r}")
sys.exit(0 if ok else 1)
