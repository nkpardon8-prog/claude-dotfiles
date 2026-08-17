#!/usr/bin/env python3
"""Do the two hook files on disk agree with the 40 pinned fixture cases - on BOTH sides?

Round-3 finding P2/P3: the previous version of this file hardcoded a FROZEN COPY of plan
revision 2's regex, evaluated the GATE ONLY (it unpacked `ledger_exp` and never used it), and
printed at most 40 of the 80 possible checks. A "80/80 agree" figure was reported from an inline
scratch script and is NOT reproducible from this file. That is the exact unauditability the
scorer relocation was supposed to fix, reintroduced.

This version holds NO regex. It loads whatever is on disk and calls each hook's REAL `is_prod`,
so it measures the files rather than a third undrifted copy of them.

    ./06-fixture-agreement.py [GATE_PATH] [LEDGER_PATH]

With no argv it checks the LIVE hooks (pre-edit: expect the known failures; post-edit: expect
80/80). Point it at `.mut` copies to check a mutation without ever reverting the live gate -
every other window on this machine runs the live one.
"""
import os
import sys

H = os.path.expanduser("~/.claude-dotfiles/scripts/hooks")
GATE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(H, "prod-coordination-gate.py")
LEDGER = sys.argv[2] if len(sys.argv) > 2 else os.path.join(H, "prod-ledger.py")
FIX = os.path.join(H, "test-prod-classifier-fixtures.py")

MARKER = "\ntry:\n    main()"


def load(path, name):
    """Load a hook's module namespace WITHOUT executing its main()."""
    src = open(path).read()
    cut = src.find(MARKER)
    if cut == -1:
        sys.exit(f"06: {path} has no `{MARKER.strip()}` marker - cannot load without running it")
    ns = {"__name__": name, "__file__": path}
    exec(compile(src[:cut], path, "exec"), ns)
    for need in ("is_prod", "PROD"):
        if need not in ns:
            sys.exit(f"06: {path} defines no {need}()")
    return ns


gate, ledger = load(GATE, "gate_probe"), load(LEDGER, "ledger_probe")

fsrc = open(FIX).read()
fns = {"__name__": "fix_probe", "__file__": FIX}
exec(compile(fsrc[:fsrc.find("\ndef main()")], FIX, "exec"), fns)
CASES, PRODC = fns["CASES"], fns["PROD"]

print(f"gate   : {GATE}")
print(f"ledger : {LEDGER}")
print(f"cases  : {len(CASES)}  ->  {len(CASES) * 2} checks (both hooks, as the fixtures expect)\n")

bad = 0
for name, cmd, gate_exp, ledger_exp in CASES:
    for hookname, ns, exp in (("gate", gate, gate_exp), ("ledger", ledger, ledger_exp)):
        want = (exp == PRODC)
        got = ns["is_prod"](cmd)
        if got is not want:
            bad += 1
            print(f"    {'FALSE-NEG' if want else 'FALSE-POS':9} [{hookname:6}] {name}")

total = len(CASES) * 2
print(f"\n{total - bad}/{total} agree with the pinned fixture expectations "
      f"({bad} disagreement{'' if bad == 1 else 's'})")
sys.exit(1 if bad else 0)
