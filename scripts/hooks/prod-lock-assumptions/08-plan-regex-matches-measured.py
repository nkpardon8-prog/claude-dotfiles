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
edit_b = next((b for b in blocks if "def _strip_inert_data" in b), None)
if not edit_a:
    sys.exit("08: Edit A block not found in the plan")
if not edit_b:
    sys.exit("08: Edit B block not found in the plan")

rc = 0

# --- Edit A: the pattern the plan prints must be the pattern that was scored -----------------
ns = {"re": re}
exec(compile(edit_a, "<plan Edit A>", "exec"), ns)
plan_rx = ns["INTERP"]
ok_a = plan_rx.pattern == r6.INTERP_R7.pattern
print(f"Edit A  plan {len(plan_rx.pattern)} chars vs measured {len(r6.INTERP_R7.pattern)} chars"
      f"  ->  {'MATCH' if ok_a else 'MISMATCH'}")
if not ok_a:
    a, b = plan_rx.pattern, r6.INTERP_R7.pattern
    i = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
    print(f"  first divergence at char {i}:\n    plan     ...{a[max(0, i - 70):i + 70]!r}\n"
          f"    measured ...{b[max(0, i - 70):i + 70]!r}")
rc |= 0 if ok_a else 1

# --- Edit B: previously compared BY EYE. This plan's history is that eyeballed equivalences fail.
# Execute the plan's own function and require identical output to the scored form on every row.
m = r6.m
nsb = {"re": re, "INTERP": plan_rx, "QUOTED": m.QUOTED, "SUBST": m.SUBST,
       "_strip_heredocs": m.strip_heredocs}
exec(compile(edit_b, "<plan Edit B>", "exec"), nsb)
plan_strip = nsb["_strip_inert_data"]
scored_strip = m.probe_form(r6.INTERP_R7)
diff = [why for cmd, _, _, why in r6.ALL if plan_strip(cmd) != scored_strip(cmd)]
print(f"Edit B  identical output on {len(r6.ALL) - len(diff)}/{len(r6.ALL)} rows"
      f"  ->  {'MATCH' if not diff else 'MISMATCH'}")
for why in diff[:10]:
    print(f"    DIFFERS on: {why}")
rc |= 0 if not diff else 1

print(f"\n{'the plan documents exactly what was measured' if rc == 0 else 'PLAN AND MEASUREMENT DISAGREE'}")
sys.exit(rc)
