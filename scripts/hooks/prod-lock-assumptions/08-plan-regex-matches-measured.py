#!/usr/bin/env python3
"""Three-way agreement: the PLAN, the SCORER, and the FILES ON DISK.

A plan whose pasted pattern differs from the scored one documents a candidate that was never tested -
the same drift class as a scorer holding its own frozen copy of the hook. And a scorer that agrees
with the plan while the LIVE HOOKS run something else is worse still, because both artefacts read
green about code that is not running. So this file closes all three edges:

  A1  the plan's Edit A compiles to exactly 09's INTERP_R7 - pattern AND flags. Flags were never
      compared before; `re.IGNORECASE` is the root cause of the original 4.3h outage, so a pattern
      match under a different flag set is not agreement.
  A2  the plan's Edit A equals the `INTERP` actually in prod-coordination-gate.py AND in
      prod-ledger.py. Nothing anywhere compared the scorer to the shipped file - the whole point of
      relocating the scorer was auditability, and this was the missing edge. Expected RED before the
      apply step and GREEN after; it is the check that says which side of the apply you are on.
  B1  the plan's Edit B (`_strip_heredocs` + `_strip_inert_data`) produces byte-identical output to
      the form 09 scored, on every row 09 scores. Previously compared by eye, and this plan's
      history is that eyeballed equivalences fail.
  B2  the plan's `_strip_heredocs` equals the one on disk in both hooks - the same shipped-file edge
      as A2, for the half of the change that is code rather than a regex.

Revision 7 has no Edit D (withdrawn, gated on pd:6).
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
if "def _strip_heredocs" not in edit_b:
    sys.exit("08: Edit B block does not carry _strip_heredocs - the splice guard is undocumented")

m = r6.m
rc = 0

# --- A1: the pattern the plan prints must be the pattern that was scored, flags included ---------
ns = {"re": re}
exec(compile(edit_a, "<plan Edit A>", "exec"), ns)
plan_rx = ns["INTERP"]
ok_pat = plan_rx.pattern == r6.INTERP_R7.pattern
ok_flg = plan_rx.flags == r6.INTERP_R7.flags
print(f"A1 Edit A vs scorer   plan {len(plan_rx.pattern)} chars / flags {plan_rx.flags} "
      f"vs measured {len(r6.INTERP_R7.pattern)} chars / flags {r6.INTERP_R7.flags}"
      f"  ->  {'MATCH' if ok_pat and ok_flg else 'MISMATCH'}")
if not ok_pat:
    a, b = plan_rx.pattern, r6.INTERP_R7.pattern
    i = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
    print(f"   first divergence at char {i}:\n     plan     ...{a[max(0, i - 70):i + 70]!r}\n"
          f"     measured ...{b[max(0, i - 70):i + 70]!r}")
if not ok_flg:
    print("   FLAGS DIFFER - IGNORECASE is the root cause of the 4.3h outage; a pattern match "
          "under a different flag set is not agreement")
rc |= 0 if ok_pat and ok_flg else 1

# --- A2: ...and the pattern the LIVE HOOKS are running ------------------------------------------
for hookname, hns in (("gate", m.gate), ("ledger", m.ledger)):
    disk = hns["INTERP"]
    ok = disk.pattern == plan_rx.pattern and disk.flags == plan_rx.flags
    rc |= 0 if ok else 1
    state = ("MATCH" if ok else
             "MISMATCH - NOT APPLIED" if disk.pattern == m.INTERP_CUR.pattern else
             "MISMATCH - a THIRD form")
    print(f"A2 Edit A vs {hookname:6} on disk  ->  {state}")

# --- B1: Edit B, executed rather than eyeballed --------------------------------------------------
nsb = {"re": re, "INTERP": plan_rx, "QUOTED": m.QUOTED, "SUBST": m.SUBST,
       "HEREDOC_OPEN": m.gate["HEREDOC_OPEN"]}
exec(compile(edit_b, "<plan Edit B>", "exec"), nsb)
plan_strip_h, plan_strip = nsb["_strip_heredocs"], nsb["_strip_inert_data"]
scored_strip = r6.probe_form(r6.INTERP_R7, r6.STRIP_CAND)
rows = [c for c, _, _, _ in r6.ALL] + [c for c, _ in r6.OBSERVED]
diff = [why for (cmd, _, _, why) in r6.ALL if plan_strip(cmd) != scored_strip(cmd)]
print(f"B1 Edit B vs scorer   identical output on {len(r6.ALL) - len(diff)}/{len(r6.ALL)} rows"
      f"  ->  {'MATCH' if not diff else 'MISMATCH'}")
for why in diff[:10]:
    print(f"     DIFFERS on: {why}")
rc |= 0 if not diff else 1

hd = [c for c in rows if plan_strip_h(c) != r6.STRIP_CAND(c)]
print(f"B1 _strip_heredocs vs scorer   identical on {len(rows) - len(hd)}/{len(rows)} rows"
      f"  ->  {'MATCH' if not hd else 'MISMATCH'}")
rc |= 0 if not hd else 1

# --- B2: ...and the _strip_heredocs the LIVE HOOKS are running -----------------------------------
for hookname, hns in (("gate", m.gate), ("ledger", m.ledger)):
    disk_h = hns["_strip_heredocs"]
    bad = [c for c in rows if disk_h(c) != plan_strip_h(c)]
    rc |= 0 if not bad else 1
    print(f"B2 _strip_heredocs vs {hookname:6} on disk  ->  "
          f"{'MATCH' if not bad else f'MISMATCH on {len(bad)}/{len(rows)} rows - NOT APPLIED'}")

print(f"\n{'plan == scorer == both hooks on disk' if rc == 0 else 'PLAN, MEASUREMENT AND DISK DISAGREE - see above'}")
sys.exit(rc)
