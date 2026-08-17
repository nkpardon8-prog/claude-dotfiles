#!/usr/bin/env python3
# Does the candidate break any of the EXISTING 40 fixture cases (gate side)?
# Patches the gate module's _strip_inert_data/INTERP in memory and calls the REAL is_prod.
# Nothing on disk is modified; the gate's main() is never reached.
import os, re, sys

H = os.path.expanduser("~/.claude-dotfiles/scripts/hooks")
GATE = os.path.join(H, "prod-coordination-gate.py")
FIX = os.path.join(H, "test-prod-classifier-fixtures.py")

src = open(GATE).read()
ns = {"__name__": "gate_probe"}
exec(compile(src[:src.find("\ntry:\n    main()")], GATE, "exec"), ns)

# fixture CASES: truncate before its main() invocation the same way
fsrc = open(FIX).read()
fcut = fsrc.find("\ndef main()")
fns = {"__name__": "fix_probe", "__file__": FIX}
exec(compile(fsrc[:fcut], FIX, "exec"), fns)
CASES = fns["CASES"]
PRODC, SAFEC = fns["PROD"], fns["SAFE"]

NAMES = r"python[0-9.]*|perl|ruby|node|deno|psql|mysql|mariadb|osascript|fish|pwsh"
SHELL = r"(?:ba|z|da|k|a)?sh"
LEAD = r"(?:^|[\s|;&(/\"'])"
GAP = r"(?:\s+[^\s|;&<>\n]+)*?"
CMDPOS = r"(?:^|[\n;|&(])\s*"
INTERP_AD = re.compile(
    LEAD + r"(?:eval|xargs|ssh|su|runuser|doas)\b"
    + r"|" + LEAD + SHELL + r"\b(?:\s+--?[A-Za-z-]+)*\s+-[A-Za-z]*c\b"
    + r"|" + LEAD + r"(?:" + NAMES + r")\b" + GAP + r"\s+-[A-Za-z]*[ce]\s+['\"]"
    + r"|--(?:command|eval)="
    + r"|\|\s*(?:\S*/)?" + SHELL + r"\b"
    + r"|" + CMDPOS + r"(?:\S*/)?" + SHELL + r"\b(?:\s+-[A-Za-z]+)*\s*<<",
    re.IGNORECASE,
)

QUOTED, SUBST, strip_heredocs = ns["QUOTED"], ns["SUBST"], ns["_strip_heredocs"]


def candidate_strip(cmd):
    if INTERP_AD.search(strip_heredocs(cmd)):
        return cmd
    c = strip_heredocs(cmd)
    return QUOTED.sub(lambda m: m.group(0) if SUBST.search(m.group(0)) else " ", c)


bad = 0
for name, cmd, gate_exp, ledger_exp in CASES:
    base = ns["is_prod"](cmd)                    # shipped behavior
    ns["_strip_inert_data"] = candidate_strip
    cand = ns["is_prod"](cmd)
    ns["_strip_inert_data"] = ns["__builtins__"] and None  # restore below
    exec(compile(src[:src.find("\ntry:\n    main()")], GATE, "exec"), ns)  # reset module state
    want_prod = (gate_exp == PRODC)
    # the gate has no `git push` pattern, so a push-only case is SAFE for the gate regardless
    tag = ""
    if cand is not want_prod:
        tag = "  <== CANDIDATE WRONG"
        bad += 1
    if base is not cand or tag:
        print(f"{'PROD' if want_prod else 'SAFE':4} want | shipped={str(base):5} cand={str(cand):5} | {name}{tag}")

print(f"\ncandidate disagrees with fixture expectation on {bad} of {len(CASES)} gate cases")
