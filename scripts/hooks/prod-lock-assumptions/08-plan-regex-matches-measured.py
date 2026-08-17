#!/usr/bin/env python3
"""Does the regex WRITTEN IN THE PLAN compile to exactly the regex that was MEASURED?

A plan whose pasted pattern differs from the scored one documents a candidate that was never
tested - the same drift class as a scorer holding its own frozen copy. This closes it: extract
Edit A + Edit D from the plan markdown, splice them the way the implementer will, compile, and
compare against 07's INTERP_R5P character for character.
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
spec = importlib.util.spec_from_file_location("c", os.path.join(D, "07-revision5-candidate.py"))
cand = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(cand)

md = open(PLAN).read()
blocks = re.findall(r"```python\n(.*?)```", md, re.S)
edit_a = next((b for b in blocks if "INTERP = re.compile(" in b), None)
edit_d = next((b for b in blocks if b.lstrip().startswith('r"|(?:^|[\\n;|&(])')), None)
assert edit_a, "Edit A block not found in the plan"
assert edit_d, "Edit D block not found in the plan"

# The implementer splices Edit D in as the final alternative, before the closing flags line.
tail = "    re.IGNORECASE,\n)"
assert tail in edit_a, "Edit A does not end in the expected re.IGNORECASE close"
spliced = edit_a.replace(tail, edit_d.rstrip("\n") + "\n" + tail)

ns = {"re": re}
exec(compile(spliced, "<plan Edit A + Edit D>", "exec"), ns)
plan_rx = ns["INTERP"]

ok = plan_rx.pattern == cand.INTERP_R5P.pattern
print(f"plan pattern length     : {len(plan_rx.pattern)}")
print(f"measured pattern length : {len(cand.INTERP_R5P.pattern)}")
print(f"\n{'MATCH - the plan documents exactly what was measured' if ok else 'MISMATCH'}")
if not ok:
    a, b = plan_rx.pattern, cand.INTERP_R5P.pattern
    i = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
    print(f"first divergence at char {i}:\n  plan     ...{a[max(0,i-60):i+60]!r}\n"
          f"  measured ...{b[max(0,i-60):i+60]!r}")
sys.exit(0 if ok else 1)
