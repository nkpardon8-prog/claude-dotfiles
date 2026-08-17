#!/usr/bin/env python3
"""Round-3 FIX scorer: build the plan-revision-4 candidate (regex INTERP_R5) and MEASURE it.

Standing rule 3: score before writing a claim into the plan. Every number the plan quotes for
revision 4 is produced by this file.

Standing rule 2: the adversarial rows below are tagged with the LANE that authored them. The rows
in the HOLDOUT block were written by lanes that did NOT write this regex (criticer, plan-reviewer,
Codex). Rows I authored live in the corpus imported from 05 and are marked as such there.

Reads the shared 47-row corpus + candidates from 05-classifier-candidates.py, then adds:
  - the 11 out-of-corpus regressions found in round 3 (the frozen independent holdout)
  - a linear-time budget assertion (the round-3 ReDoS was 8s at 23 tokens)
"""
import contextlib
import importlib.util
import io
import os
import re
import sys
import time

D = os.path.dirname(os.path.abspath(__file__))


def _load_05():
    saved = sys.argv
    sys.argv = ["x"]
    spec = importlib.util.spec_from_file_location("sc", os.path.join(D, "05-classifier-candidates.py"))
    m = importlib.util.module_from_spec(spec)
    try:
        # 05 scores on import; swallow its report so only THIS file's numbers are printed.
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(m)
    except SystemExit:
        pass
    finally:
        sys.argv = saved
    return m


m = _load_05()
gate, ledger = m.gate, m.ledger
DEPLOY, ROLE = m.DEPLOY, m.ROLEFLIP

# ------------------------------------------------------------------ revision 5
# Fix list, each item traceable to a measured round-3 finding:
#  1  ReDoS: the generic token also admitted quote chars, so a quoted token matched BOTH
#     alternatives. Making them DISJOINT removes the exponential backtracking.
#  2  (?-i:[ce]) DROPPED: measured redundant once branch 3 requires an interpreter NAME
#     (`grep` can never reach that branch), and it costs a real detection (`perl -E`).
#  3  FIX B: extend the interpreter name list; the closed world was incomplete on day zero.
#  5  the gap separator accepts a backslash line-continuation.
#  6  the sh -c branch allows one non-flag VALUE per flag (`sh -o pipefail -c`).
#  4  a command-position path-prefixed branch for the absolute-path interpreter form.
TOK = r"[^\s|;&<>\n\"']+"                       # 1: DISJOINT from the quoted alternatives
SEP = r"(?:[ \t]|\\\n)+"                        # 5: backslash line-continuation
NAMES5 = (r"python[0-9.]*|perl|ruby|node|deno|ts-node|tsx|bun|psql|mysql|mariadb"
          r"|sqlite3|mongosh|cockroach|clickhouse-client|duckdb|redis-cli"
          r"|osascript|fish|pwsh|tclsh")        # 3: FIX B
SHELL = m.SHELL
LEAD = r"(?:^|[\s|;&(])"
PATHPFX = m.PATHPFX
PREFIX = m.PREFIX
CMDPOS = m.CMDPOS3
GAP5 = r"(?:" + SEP + r"(?:\"[^\"\n]*\"|'[^'\n]*'|[0-9]*[<>]&?[0-9]*|" + TOK + r"))*?"
FLAG5 = SEP + r"--?[A-Za-z]*(?:[ce]|command|eval)" + SEP + r"['\"]"   # 2: no (?-i:)
OPT6 = r"(?:" + SEP + r"--?[A-Za-z-]+(?:" + SEP + r"(?![-<>|;&])" + TOK + r")?)*"  # 6
NAMED = r"(?:eval|xargs|ssh|su|runuser|doas)"

INTERP_R5 = re.compile(
    LEAD + NAMED + r"\b"
    + r"|" + CMDPOS + PATHPFX + NAMED + r"\b"                       # 4: absolute-path, cmd position
    + r"|" + LEAD + PATHPFX + SHELL + r"\b" + OPT6 + SEP + r"-[A-Za-z]*c\b"
    + r"|" + LEAD + r"(?:" + NAMES5 + r")\b" + GAP5 + FLAG5
    + r"|--(?:command|eval)="
    + r"|\|\s*" + PREFIX + PATHPFX + SHELL + r"\b"
    + r"|" + CMDPOS + PREFIX + PATHPFX + SHELL + r"\b(?:" + SEP + TOK + r")*?[ \t]*<<",
    re.IGNORECASE,
)

# ------------------------------------------------------- the frozen independent holdout
# EVERY row here was authored by a lane that did not write the regex. Provenance is the point.
BS = "\\\n  "
HOLDOUT = [
    (f"tsx -e 'require(\"child_process\").execSync(\"{DEPLOY}\")'", 1, 1, "criticer"),
    (f"cockroach sql --url $PROD_URL -e '{ROLE}'", 1, 1, "criticer"),
    (f'psql "$PROD_URL"{BS}-c \'{ROLE}\'', 1, 1, "plan-reviewer"),
    (f"node{BS}-e 'exec(\"{DEPLOY}\")'", 1, 1, "plan-reviewer"),
    (f"sh -o pipefail -c '{DEPLOY}'", 1, 1, "plan-reviewer"),
    (f"bash --rcfile /tmp/x -c '{DEPLOY}'", 1, 1, "plan-reviewer"),
    (f"perl -E 'system(\"{DEPLOY}\")'", 1, 1, "plan-reviewer"),
    (f"/usr/bin/psql -c '{ROLE}'", 1, 1, "Codex"),
    (f"/usr/bin/ssh box '{DEPLOY}'", 1, 1, "Codex + plan-reviewer (P6)"),
    # --- the FP side of the holdout: these must stay SAFE ---
    (f"rg -n 'we deploy via ssh then {DEPLOY}' docs/", 0, 0, "plan-reviewer R6"),
    (f'grep -rn ssh docs/ && grep -rn "{DEPLOY}" docs/', 0, 0, "plan-reviewer R6"),
    (f'git ls-files | xargs grep -niE "{DEPLOY}"', 0, 0, "plan-reviewer R7 (outage neighbour)"),
    (f'git commit -m "gate: /bin/bash -c \'{DEPLOY}\' takes the lock"', 0, 0, "plan-reviewer R10"),
    (f"git commit -m \"runbook: '/usr/bin/ssh box {DEPLOY}' is banned\"", 0, 0, "Codex F2"),
]

# Variant: does the SAME path-prefix technique that closed the absolute-ssh residual also close
# `/usr/bin/psql -c` on the NAME branch, and at what false-positive cost? The lead class excludes
# quote characters, so `rg '/usr/bin/psql -c "x"'` cannot reach it - the same reason branch 4 is safe.
INTERP_R5P = re.compile(
    INTERP_R5.pattern.replace(LEAD + r"(?:" + NAMES5 + r")\b",
                              LEAD + PATHPFX + r"(?:" + NAMES5 + r")\b"),
    re.IGNORECASE,
)
assert INTERP_R5P.pattern != INTERP_R5.pattern, "variant did not apply"

CANDS = [("current (shipped)", m.mk_current),
         ("revision 4 (plan rev 3 as written)", m.probe_form(m.INTERP_R4)),
         ("revision 5 (plan rev 4, this)", m.probe_form(INTERP_R5)),
         ("revision 5p (+ path prefix on the NAME branch)", m.probe_form(INTERP_R5P))]


def score(rows, fn):
    wrong = []
    for cmd, wg, wl, why in rows:
        for hookname, ns, want in (("gate", gate, wg), ("ledger", ledger, wl)):
            if m.classify(cmd, fn, ns) is not bool(want):
                wrong.append((("FALSE-NEG" if want else "FALSE-POS"), hookname, why))
    return wrong


for label, rows in (("CORPUS (47 rows, mine)", m.CORPUS),
                    ("HOLDOUT (14 rows, other lanes only)", HOLDOUT)):
    print(f"########## {label} ##########")
    for name, fn in CANDS:
        w = score(rows, fn)
        print(f"=== {name}: {len(rows)*2-len(w)}/{len(rows)*2} ===")
        for kind, hook, why in w:
            print(f"    {kind:9} [{hook:6}] {why}")
    print()

# --------------------------------------------- MECHANICAL strict-subset check (not by eye)
# "zero regressions" was over-claimed twice by eyeballing a score DIFFERENCE. A lower error count
# does not imply a subset: a candidate can fix 5 and break 3 and still score higher. Assert the
# actual set relation, over corpus + holdout together, and print the qualifier with the number.
ALL = list(m.CORPUS) + list(HOLDOUT)


def errset(fn):
    out = set()
    for i, (cmd, wg, wl, why) in enumerate(ALL):
        for hookname, ns, want in (("gate", gate, wg), ("ledger", ledger, wl)):
            if m.classify(cmd, fn, ns) is not bool(want):
                out.add((i, hookname, why))
    return out


print("########## STRICT-SUBSET CHECK (corpus + holdout, both hooks) ##########")
base = errset(m.mk_current)
for name, fn in CANDS[1:]:
    e = errset(fn)
    new = e - base
    print(f"{name}: {len(ALL)*2-len(e)}/{len(ALL)*2} on the {len(ALL)} measured rows | "
          f"fixed {len(base - e)} | NEW errors (regressions) {len(new)} "
          f"| {'STRICT SUBSET of shipped' if not new else 'NOT a subset'}")
    for _, hook, why in sorted(new, key=lambda x: x[2]):
        print(f"    REGRESSION [{hook:6}] {why}")
print()

# ------------------------------------------------------------- linear-time budget
print("########## LINEAR-TIME BUDGET (round-3 ReDoS was 8.06s at 23 tokens) ##########")
print(f"{'tokens':>7} {'rev4':>12} {'rev5':>12}")
worst = 0.0
for n in (10, 15, 18, 20, 22, 23, 30):
    cmd = "python3 " + " ".join(['"x"'] * n) + " --zzz value"
    row = f"{n:7}"
    for rx in (m.INTERP_R4, INTERP_R5):
        if rx is m.INTERP_R4 and n >= 23:
            row += f"{'(skipped)':>12}"   # measured 8.06s at 23; do not re-burn it every run
            continue
        t0 = time.time()
        try:
            rx.search(cmd)
            el = time.time() - t0
            if rx is INTERP_R5:
                worst = max(worst, el)
            row += f"{el:11.4f}s"
        except Exception as e:  # pragma: no cover
            row += f"   ERR {e}"
    print(row)
print(f"\nrevision 5 worst observed: {worst:.4f}s  "
      f"{'PASS (<0.01s budget)' if worst < 0.01 else 'FAIL'}")
