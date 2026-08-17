#!/usr/bin/env python3
"""Revision 6 - MINIMAL DELTA from shipped, and the scorer that gates it.

WHY THIS SHAPE. Revisions 1-4 replaced shipped's third branch with a closed interpreter-name list
plus extra branches. Each collapsed the moment a review lane that had not written the regex
contributed rows (rev4: declared a mechanically verified strict subset, then measured 26 regressions
and two catastrophic-backtracking families). The converged diagnosis is a DESIGN one: shipped's
alt-3 `\\s-[a-z]*[ce]\\s+['\"]` is NAME-AGNOSTIC, and that is exactly why it never regresses.

So all five shipped branches stay EXACTLY as they are and the only change is a SUBTRACTION: a
demonstrable search tool cannot trigger alt-3.

WHAT THIS FILE GATES (it exits non-zero on any failure):
  1. strict subset of shipped's error set, computed mechanically, over every row any lane wrote
  2. both OBSERVED incident rows asserted BY NAME, not folded into an aggregate
  3. the 40 pinned fixtures still preserved - checked BEFORE any file is edited
  4. two mutation checks, as CODE, each with a sentinel that must flip
  5. the heredoc lemma that "strict subset" silently depends on
  6. a linear-time budget over every construct that has ever backtracked here

Round-5 review corrections folded in, each measured, none assumed:
  CR1  `awk` REMOVED from the deny-list - gawk takes program text via -e and awk shells out via
       system(); denying it silently removed detection shipped has.
  PRR1 the blanks moved INSIDE the lookahead. A standalone `[ \\t]*` BACKTRACKS, so the lookahead
       was re-evaluated at a whitespace position where no denied name can match - the deny-list
       only worked when the tool name was the literal FIRST BYTE.
  PRR1 the lookahead is PREFIX-AWARE (wrapper words, env assignments, path segments), so a tool
       reached through `sudo`, `git`, `env X=1`, `/usr/bin/` or `./` is also seen.
  F2   a BACKTICK is in the anchor class AND in the lazy-scan class. Without it, a real execution
       inside `...` had no anchor but ^, where the lookahead blocked it - a suppressed detection.
       Adding it to the anchor class ALONE is QUADRATIC, because the scan must exclude the
       character it anchors on. Both, or neither.
  F5   `xargs` removed from the wrapper set - branch 1 matches xargs independently, so it was
       unreachable. Measured identical without it.
"""
import contextlib
import importlib.util
import io
import os
import re
import sys
import time

D = os.path.dirname(os.path.abspath(__file__))
H = os.path.dirname(D)
BUDGET = 0.01

sys.argv = ["x"]
_spec = importlib.util.spec_from_file_location("sc", os.path.join(D, "05-classifier-candidates.py"))
m = importlib.util.module_from_spec(_spec)
with contextlib.redirect_stdout(io.StringIO()):      # 05 scores on import; we want only its data
    _spec.loader.exec_module(m)
gate, ledger = m.gate, m.ledger
DEP, ROLE = m.DEPLOY, m.ROLEFLIP

# ----------------------------------------------------------------- the candidate
DENY = ["grep", "egrep", "fgrep", "rg", "ag", "ack", "sed"]
WRAP = (r"(?:(?:sudo|env|command|time|nohup|git)[ \t]+"
        r"|[A-Za-z_][A-Za-z0-9_]*=[^\s]*[ \t]+)*")
PATHP = r"(?:[A-Za-z0-9_.~$-]*/)*"
ANCHOR = r"[\n;|&(`]"
# `(` must be excluded from SCAN for the same reason the backtick is: a character that is an ANCHOR
# but not excluded from the SCAN class makes every occurrence a start position whose lazy scan can
# run over all the remaining ones - quadratic. Round 6 measured 0.0593s on a 4000-paren run and
# 0.0591s on a ROUTINE ~17KB `git commit -m` message containing parenthetical asides, versus 0.0005s
# shipped. Both round-6 lanes found this independently, and it is this plan's own stated lemma
# ("both, or neither") applied to the backtick and not to the paren.
SCAN = r"[^\n;|&`(]"
SHIPPED_BRANCHES = (r"(?:^|[\s|;&(])(?:eval|xargs|ssh)\b"
                    r"|sh\s+-[a-z]*c\b"
                    r"|{ALT3}"
                    r"|--(?:command|eval)="
                    r"|\|\s*(?:ba|z|da|k)?sh\b")


def alt3(deny=DENY, wrap=WRAP, path=PATHP, anchor=ANCHOR, scan=SCAN, blanks_inside=True):
    """Shipped's alt-3, gated by a clause-anchored deny-list. Parameterised so the mutation
    checks below can perturb exactly one construct at a time."""
    lead = r"(?:^|" + anchor + r")"
    look = (r"(?![ \t]*" + wrap + path + r"(?:" + "|".join(deny) + r")\b)" if blanks_inside
            else r"[ \t]*(?!" + wrap + path + r"(?:" + "|".join(deny) + r")\b)")
    return lead + look + scan + r"*?\s-[a-z]*[ce]\s+['\"]"


def compile_with(a3):
    return re.compile(SHIPPED_BRANCHES.replace("{ALT3}", a3), re.IGNORECASE)


INTERP_R7 = compile_with(alt3())

# ----------------------------------------------------------------- the rows
# Provenance is the point. Rows authored by a lane that did NOT write the regex are tagged with
# that lane; rows I wrote are tagged [mine]. A claim is only ever as wide as the rows it ran over.
BS = "\\\n  "
BT = "`"
HOLDOUT = [   # round-3 lanes
    (f"tsx -e 'require(\"child_process\").execSync(\"{DEP}\")'", 1, 1, "criticer tsx -e"),
    (f"cockroach sql --url $PROD_URL -e '{ROLE}'", 1, 1, "criticer cockroach -e"),
    (f'psql "$PROD_URL"{BS}-c \'{ROLE}\'', 1, 1, "plan-reviewer continuation"),
    (f"node{BS}-e 'exec(\"{DEP}\")'", 1, 1, "plan-reviewer continuation node"),
    (f"sh -o pipefail -c '{DEP}'", 1, 1, "plan-reviewer value-taking opt"),
    (f"bash --rcfile /tmp/x -c '{DEP}'", 1, 1, "plan-reviewer long opt w/ value"),
    (f"perl -E 'system(\"{DEP}\")'", 1, 1, "plan-reviewer perl -E"),
    (f"/usr/bin/psql -c '{ROLE}'", 1, 1, "codex abs-path psql"),
    (f"/usr/bin/ssh box '{DEP}'", 1, 1, "codex abs-path ssh"),
    (f"rg -n 'we deploy via ssh then {DEP}' docs/", 0, 0, "plan-reviewer quoted ssh"),
    (f'grep -rn ssh docs/ && grep -rn "{DEP}" docs/', 0, 0, "plan-reviewer two searches"),
    (f'git ls-files | xargs grep -niE "{DEP}"', 0, 0, "plan-reviewer xargs outage sibling"),
    (f'git commit -m "gate: /bin/bash -c \'{DEP}\' takes the lock"', 0, 0, "plan-reviewer prose"),
    (f"git commit -m \"runbook: '/usr/bin/ssh box {DEP}' is banned\"", 0, 0, "codex prose"),
]
ROUND4 = [
    (f"Rscript -e 'system(\"{DEP}\")'", 1, 1, "codex/pr Rscript -e"),
    (f"lua -e 'os.execute(\"{DEP}\")'", 1, 1, "codex lua -e"),
    (f"julia -e 'run(Cmd([\"sh\",\"-c\",\"{DEP}\"]))'", 1, 1, "plan-reviewer julia -e"),
    (f"\"/bin/bash\" -c '{DEP}'", 1, 1, "codex QUOTED executable name"),
    (f"bash 2>/tmp/bash.err -c '{DEP}'", 1, 1, "codex REDIRECT before -c"),
    (f"find . -maxdepth 0 -exec \"/bin/bash\" -c '{DEP}' \\;", 1, 1, "codex find -exec sh"),
    (f"docker exec deploybox \"/bin/bash\" -c '{DEP}'", 1, 1, "codex docker quoted sh"),
    (f"nohup \"/bin/bash\" -c '{DEP}' >/tmp/d.log 2>&1 &", 1, 1, "codex nohup quoted sh"),
    (f"bash --init-file \"$HOME/x\" -c '{DEP}'", 1, 1, "plan-reviewer QUOTED opt value"),
    (f"bash -s <<< '{DEP}'", 1, 1, "plan-reviewer herestring"),
    (f"git commit -m \"runbook: /usr/bin/psql --command '{ROLE}' is banned\"", 0, 0, "criticer R4"),
    (f'rg -n "{DEP}|/bin/sh" scripts/hooks/', 0, 0, "plan-reviewer alternation names a shell"),
    (f'git commit -m "gate: bash -o pipefail -c reaches branch 3, so {DEP} is caught"',
     0, 0, "plan-reviewer commit msg"),
    (f"git commit -m \"gate: aim the bail-out\n\n/usr/bin/ssh box '{DEP}' was filed\"",
     0, 0, "plan-reviewer MULTI-LINE commit"),
    (f'grep -niE "{DEP}|bash" docs/', 0, 0, "plan-reviewer outage sibling"),
    (f"find docs -type f -exec grep -H -e '{DEP}' {{}} +", 0, 0, "codex find -exec grep"),
    (f"sed -n 's/{DEP}/X/p' docs/ops.md", 0, 0, "plan-reviewer sed -n"),
]
ROUND5 = [
    (f"awk -e 'BEGIN{{system(\"{DEP}\")}}'", 1, 1, "criticer awk -e EXECUTES"),
    (f"grep -rn foo docs/ {BT}psql \"$U\" -c '{ROLE}'{BT}", 1, 1, "lane3 BACKTICK psql EXECUTES"),
    (f"grep -rn foo docs/ $(psql \"$U\" -c '{ROLE}')", 1, 1, "lane3 $( ) twin"),
    (f"sed -e '1e {DEP}' /etc/hosts", 1, 1, "plan-reviewer GNU sed e EXECUTES [pd:7 accepted loss]"),
    (f"sudo psql \"$P\" -c '{ROLE}'", 1, 1, "control sudo psql REAL"),
    (f"env FOO=1 psql \"$P\" -c '{ROLE}'", 1, 1, "control env psql REAL"),
    (f"./deploy.sh -c '{ROLE}'", 1, 1, "control relative-path REAL"),
    (f'  grep -niE "{DEP}" docs/', 0, 0, "plan-reviewer leading blanks"),
    (f'cd docs && grep -niE "{DEP}" .', 0, 0, "plan-reviewer && anchor"),
    (f'git log | grep -niE "{DEP}"', 0, 0, "plan-reviewer pipe anchor"),
    ('cd r\n  grep -c "prisma migrate deploy" x.md', 0, 0, "plan-reviewer indented line"),
    (f'git grep -niE "{DEP}" -- docs/', 0, 0, "plan-reviewer git grep"),
    (f'LC_ALL=C grep -niE "{DEP}" docs/', 0, 0, "plan-reviewer env-prefixed grep"),
    (f'sudo grep -niE "{DEP}" /var/log/x', 0, 0, "plan-reviewer sudo grep"),
    (f'/usr/bin/grep -niE "{DEP}" docs/', 0, 0, "plan-reviewer abs-path grep"),
    (f'./grep -niE "{DEP}" docs/', 0, 0, "lane3 ./grep"),
    (f'bin/grep -niE "{DEP}" docs/', 0, 0, "lane3 relative-path grep"),
    (f'~/bin/rg -e "{DEP}" docs/', 0, 0, "lane3 tilde-path rg"),
    (f"rg --engine=auto -e '{DEP}' docs/", 0, 0, "plan-reviewer rg -e"),
    (f"sed -i.bak -e 's/{DEP}/x/' f", 0, 0, "plan-reviewer sed -e"),
]
ALL = list(m.CORPUS) + HOLDOUT + ROUND4 + ROUND5

# The two rows this whole part exists for. OBSERVED, not invented.
OBSERVED = [
    (f'grep -niE "{DEP}|gcloud run services"', "the 4.3h search"),
    (f"cat > tmp/briefs/x.md <<'EOF'\nWe discussed bash -c and {DEP} here.\nEOF",
     "the 2.7d brief-write"),
]


def errset(fn, rows=None):
    out = set()
    for i, (cmd, wg, wl, why) in enumerate(rows or ALL):
        for hn, ns, want in (("gate", gate, wg), ("ledger", ledger, wl)):
            if m.classify(cmd, fn, ns) is not bool(want):
                out.add((i, hn, why))
    return out


# A detection this change KNOWINGLY gives up, tied to the open decision that owns it. Declaring it
# here is the point: the gate must not pass silently over a real loss, and must not fail opaquely
# either. Anything NOT in this set is an undeclared regression and fails the run.
ACCEPTED_LOSSES = {
    "plan-reviewer GNU sed e EXECUTES [pd:7 accepted loss]":
        "pd:7-sed-deny-tradeoff - denying `sed` fixes the ubiquitous `sed -e 's/x/y/'` false "
        "positive (4 checks) but gives up GNU sed's exotic executing form `sed -e '1e <cmd>'`. "
        "Default taken pending a human answer; reversing it is one name in DENY.",
}

rc = 0
base = errset(m.mk_current)
cand = errset(m.probe_form(INTERP_R7))
new = cand - base
undeclared = {r for r in new if r[2] not in ACCEPTED_LOSSES}
declared = new - undeclared
print(f"rows {len(ALL)}   checks {len(ALL) * 2}   shipped errors {len(base)}\n")
print(f"revision 6: {len(ALL) * 2 - len(cand)}/{len(ALL) * 2} | fixed {len(base - cand)} | "
      f"{'strict subset APART FROM the declared losses below' if not undeclared else f'NOT a subset ({len(undeclared)} UNDECLARED regressions)'}")
for _, hn, why in sorted(undeclared, key=lambda x: x[2]):
    print(f"    UNDECLARED REGRESSION [{hn:6}] {why}")
for _, hn, why in sorted(declared, key=lambda x: x[2]):
    print(f"    declared loss [{hn:6}] {why}")
for why in sorted({w for _, _, w in declared}):
    print(f"        -> {ACCEPTED_LOSSES[why]}")
rc |= 1 if undeclared else 0
print("  (the number is a property of these rows, not of the classifier)")

print("\n1. OBSERVED incident rows, asserted by name:")
for cmd, why in OBSERVED:
    g = m.classify(cmd, m.probe_form(INTERP_R7), gate)
    l = m.classify(cmd, m.probe_form(INTERP_R7), ledger)
    ok = not g and not l
    rc |= 0 if ok else 1
    print(f"    {why:22} gate={'PROD' if g else 'SAFE'} ledger={'PROD' if l else 'SAFE'} "
          f"{'FIXED' if ok else '<== STILL MISFILED'}")

print("\n2. pinned-fixture preservation (gates PRE-edit, so a flip is caught before the hook moves):")
_f = os.path.join(H, "test-prod-classifier-fixtures.py")
_src = open(_f).read()
_ns = {"__name__": "fix_probe", "__file__": _f}
exec(compile(_src[:_src.find("\ndef main()")], _f, "exec"), _ns)
CASES, PRODC = _ns["CASES"], _ns["PROD"]
broke = [(hn, cn) for cn, cmd, ge, le in CASES
         for hn, ns, exp in (("gate", gate, ge), ("ledger", ledger, le))
         if m.classify(cmd, m.probe_form(INTERP_R7), ns) is not (exp == PRODC)]
rc |= 1 if broke else 0
print(f"    {len(CASES) * 2 - len(broke)}/{len(CASES) * 2}")
for hn, cn in broke:
    print(f"    BREAKS [{hn}] {cn}")

print("\n3. mutation checks - each must FLIP its sentinel (a test never watched failing is not a test):")
MUTATIONS = [
    ("M1 remove the deny-list entirely",
     compile_with(r"(?:^|" + ANCHOR + r")" + SCAN + r"*?\s-[a-z]*[ce]\s+['\"]"),
     f'grep -niE "{DEP}" docs/', 0),
    ("M2 anchor the deny-list at the token before the flag, not clause start",
     compile_with(r"(?:^|" + ANCHOR + r")(?![ \t]*" + WRAP + PATHP
                  + r"(?:" + "|".join(DENY) + r")\b)\s*\S*\s-[a-z]*[ce]\s+['\"]"),
     f'psql "$PROD_URL" -c \'{ROLE}\'', 1),
    ("M3 blanks back OUTSIDE the lookahead (the PRR1 defect)",
     compile_with(alt3(blanks_inside=False)), f'  grep -niE "{DEP}" docs/', 0),
    ("M4 drop the backtick from the anchor class (the F2 defect)",
     compile_with(alt3(anchor=r"[\n;|&(]", scan=r"[^\n;|&]")),
     f"grep -rn foo docs/ {BT}psql \"$U\" -c '{ROLE}'{BT}", 1),
]
for label, rx, sentinel, want in MUTATIONS:
    got = m.classify(sentinel, m.probe_form(rx), gate)
    red = got is not bool(want)
    rc |= 0 if red else 1
    print(f"    {label:62} {'flips -> RED' if red else 'STILL PASSES -> USELESS'}")

print("\n4. heredoc lemma - 'strict subset' silently depends on this and nothing tested it:")
print("   stripping a heredoc body must never CREATE a shipped match spanning the splice.")
viol = [why for cmd, _, _, why in ALL
        if m.INTERP_CUR.search(m.strip_heredocs(cmd)) and not m.INTERP_CUR.search(cmd)]
rc |= 1 if viol else 0
print(f"    {'holds over all ' + str(len(ALL)) + ' rows' if not viol else 'VIOLATIONS: ' + str(viol)}")

print("\n5. time budget - every construct that has ever backtracked in this work:")
for label, mk in (("blank run", lambda n: ";" + " " * n + "-x"),
                  ("backtick run", lambda n: BT * n + " -x"),
                  ("wrapper run", lambda n: ";" + "sudo " * n + "-x"),
                  ("env-assignment run", lambda n: ";" + "A=a=b=c " * n + "-x"),
                  ("path run", lambda n: ";" + "a/" * n + " -x"),
                  ("quoted tokens", lambda n: "psql " + '"x" ' * n + "--zzz"),
                  ("repeated options", lambda n: "bash " + "--rcfile /tmp/x " * n + "-z v"),
                  ("one long clause", lambda n: "psql " + "x " * n + "-c 'y'")):
    row, worst = f"    {label:20}", 0.0
    for n in (400, 1600, 6400):
        t0 = time.time()
        INTERP_R7.search(mk(n))
        el = time.time() - t0
        worst = max(worst, el)
        row += f" n={n}:{el:7.4f}s"
    over = worst > BUDGET
    rc |= 1 if over else 0
    print(row + ("  <== OVER BUDGET" if over else ""))

print(f"\n{'ALL GATES PASS' if rc == 0 else 'FAILED - see above'}")
sys.exit(rc)
