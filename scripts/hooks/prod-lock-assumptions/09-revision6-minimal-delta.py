#!/usr/bin/env python3
"""Revision 6 - MINIMAL DELTA from shipped. The round-4 pivot, and the scorer for it.

WHY THIS EXISTS. Four plan revisions each added branches to the classifier, and each collapsed the
moment a review lane that did not write the regex contributed rows:
    rev1 17/28 | rev2 56/94 | rev3 92/94 on my rows but 2/28 on other lanes' | rev4 26 regressions.
Three independent lanes converged on a DESIGN diagnosis, not a tuning one: shipped's alt-3
`\\s-[a-z]*[ce]\\s+['\"]` is NAME-AGNOSTIC, and that is exactly why it never regresses. Replacing it
with a closed interpreter list means every unnamed interpreter, every quoted executable name and
every redirect-before-the-flag silently loses protection shipped already has.

THE CHANGE. Keep all five shipped branches EXACTLY. Make ONE subtraction: gate alt-3 behind a
clause-anchored deny-list so a demonstrable search/stream tool cannot trigger it.

DIRECTION IS THE POINT. Subtract false positives AS OBSERVED - they leave traces. Never narrow
detection speculatively - false negatives leave nothing, so no evidence channel for them exists.

The deny-list is anchored at CLAUSE START rather than at the token before the flag, because the
command word and the flag are usually separated (`psql "$PROD_URL" -c`). The lazy scan uses a single
negated class that cannot cross a clause boundary, so it has no second alternative to be ambiguous
WITH - which is what made all three earlier backtracking families possible.

Run with no argv. Exits non-zero if revision 6 is not a strict subset or breaks the time budget.
"""
import contextlib
import importlib.util
import io
import os
import re
import sys
import time

D = os.path.dirname(os.path.abspath(__file__))
BUDGET = 0.01

sys.argv = ["x"]
_spec = importlib.util.spec_from_file_location("c", os.path.join(D, "07-revision5-candidate.py"))
c = importlib.util.module_from_spec(_spec)
with contextlib.redirect_stdout(io.StringIO()):
    _spec.loader.exec_module(c)
m, gate, ledger = c.m, c.gate, c.ledger
DEP, ROLE = c.DEPLOY, c.ROLE

# Rows contributed by the round-4 lanes. Provenance is the point: none of these are mine.
LANE_ROWS = [
    (f"Rscript -e 'system(\"{DEP}\")'", 1, 1, "cx/pr Rscript -e"),
    (f"lua -e 'os.execute(\"{DEP}\")'", 1, 1, "cx lua -e"),
    (f"julia -e 'run(Cmd([\"sh\",\"-c\",\"{DEP}\"]))'", 1, 1, "pr julia -e"),
    (f"\"/bin/bash\" -c '{DEP}'", 1, 1, "cx QUOTED executable name"),
    (f"bash 2>/tmp/bash.err -c '{DEP}'", 1, 1, "cx REDIRECT before -c"),
    (f"find . -maxdepth 0 -exec \"/bin/bash\" -c '{DEP}' \\;", 1, 1, "cx find -exec sh"),
    (f"docker exec deploybox \"/bin/bash\" -c '{DEP}'", 1, 1, "cx docker quoted sh"),
    (f"nohup \"/bin/bash\" -c '{DEP}' >/tmp/d.log 2>&1 &", 1, 1, "cx nohup quoted sh"),
    (f"bash --init-file \"$HOME/x\" -c '{DEP}'", 1, 1, "pr QUOTED option value"),
    (f"bash -s <<< '{DEP}'", 1, 1, "pr herestring"),
    (f"git commit -m \"runbook: /usr/bin/psql --command '{ROLE}' is banned\"", 0, 0, "crit R4"),
    (f'rg -n "{DEP}|/bin/sh" scripts/hooks/', 0, 0, "pr S1 alternation names a shell"),
    (f'git commit -m "gate: bash -o pipefail -c now reaches branch 3, so {DEP} is caught"',
     0, 0, "pr S2 commit msg"),
    (f"git commit -m \"gate: aim the bail-out\n\n/usr/bin/ssh box '{DEP}' was filed\"",
     0, 0, "pr S3 MULTI-LINE commit msg"),
    (f'grep -niE "{DEP}|bash" docs/', 0, 0, "pr S5 outage sibling, one char apart"),
    (f"find docs -type f -exec grep -H -e '{DEP}' {{}} +", 0, 0, "cx S06 find -exec grep"),
    (f"sed -n 's/{DEP}/X/p' docs/ops.md", 0, 0, "pr S9 sed -n"),
]
ALL = list(m.CORPUS) + list(c.HOLDOUT) + LANE_ROWS

# Only names whose removal fixes a REAL false positive are admitted. Measured, not argued:
# adding `git` changed nothing (identical score, identical residual), so git is NOT here.
DENY = ["grep", "egrep", "fgrep", "rg", "ag", "ack", "sed", "awk"]

SHIPPED_BRANCHES = (r"(?:^|[\s|;&(])(?:eval|xargs|ssh)\b"
                    r"|sh\s+-[a-z]*c\b"
                    r"|{ALT3}"
                    r"|--(?:command|eval)="
                    r"|\|\s*(?:ba|z|da|k)?sh\b")
ALT3_REV6 = (r"(?:^|[\n;|&(])[ \t]*(?!(?:" + "|".join(DENY) + r")\b)"
             r"[^\n;|&]*?\s-[a-z]*[ce]\s+['\"]")
INTERP_R6 = re.compile(SHIPPED_BRANCHES.replace("{ALT3}", ALT3_REV6), re.IGNORECASE)


def errset(fn):
    out = set()
    for i, (cmd, wg, wl, why) in enumerate(ALL):
        for hn, ns, want in (("gate", gate, wg), ("ledger", ledger, wl)):
            if m.classify(cmd, fn, ns) is not bool(want):
                out.add((i, hn, why))
    return out


base = errset(m.mk_current)
print(f"rows {len(ALL)}   checks {len(ALL) * 2}   shipped errors {len(base)}\n")

rc = 0
for name, fn in (("closed-world (retired plan rev 4)", m.probe_form(c.INTERP_R5P)),
                 ("revision 6 (minimal delta)", m.probe_form(INTERP_R6))):
    e = errset(fn)
    new = e - base
    verdict = "STRICT SUBSET" if not new else f"NOT a subset ({len(new)} regressions)"
    print(f"{name}: {len(ALL) * 2 - len(e)}/{len(ALL) * 2} | fixed {len(base - e)} | {verdict}")
    for _, hn, why in sorted(new, key=lambda x: x[2]):
        print(f"    REGRESSION [{hn:6}] {why}")

# The observed rows are the whole objective - assert them by name, not by aggregate.
print("\nOBSERVED outage rows (the reason this part exists):")
for cmd, why in ((f'grep -niE "{DEP}|gcloud run services"', "the 4.3h search"),
                 (f"cat > tmp/briefs/x.md <<'EOF'\nWe discussed bash -c and {DEP} here.\nEOF",
                  "the 2.7d brief-write")):
    g = m.classify(cmd, m.probe_form(INTERP_R6), gate)
    l = m.classify(cmd, m.probe_form(INTERP_R6), ledger)
    ok = not g and not l
    rc |= 0 if ok else 1
    print(f"    {why:22} gate={'PROD' if g else 'SAFE'} ledger={'PROD' if l else 'SAFE'} "
          f"{'FIXED' if ok else '<== STILL MISFILED'}")

print("\nTime budget - the three families that broke earlier revisions, at many times their width:")
for label, cmd in (("PREFIX env assignments", "\n" + "A=a=b=c=d " * 40 + "echo hi"),
                   ("OPT6 repeated options", "bash " + "--rcfile /tmp/x " * 40 + "--flag value"),
                   ("GAP quoted tokens", "psql " + '"x" ' * 2000 + "--zzz"),
                   ("long single clause", "psql " + "x " * 5000 + "-c 'y'")):
    t0 = time.time()
    INTERP_R6.search(cmd)
    el = time.time() - t0
    over = el > BUDGET
    rc |= 1 if over else 0
    print(f"    {label:24} len={len(cmd):6} {el:8.4f}s{'  <== OVER BUDGET' if over else ''}")

if errset(m.probe_form(INTERP_R6)) - base:
    rc |= 1
sys.exit(rc)
