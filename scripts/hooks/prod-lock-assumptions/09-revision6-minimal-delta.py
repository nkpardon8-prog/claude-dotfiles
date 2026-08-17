#!/usr/bin/env python3
"""Revision 7 - MINIMAL DELTA from shipped, and the scorer that gates it.

WHY THIS SHAPE. Revisions 1-4 replaced shipped's third branch with a closed interpreter-name list
plus extra branches. Each collapsed the moment a review lane that had not written the regex
contributed rows (rev4: declared a mechanically verified strict subset, then measured 26 regressions
and two catastrophic-backtracking families). The converged diagnosis is a DESIGN one: shipped's
alt-3 `\\s-[a-z]*[ce]\\s+['\"]` is NAME-AGNOSTIC, and that is exactly why it never regresses.

So all five shipped branches stay EXACTLY as they are and there are exactly TWO changes:
  EDIT A  a SUBTRACTION on alt-3: a demonstrable search tool cannot trigger it.
  EDIT B  `_strip_inert_data` decides on the heredoc-STRIPPED text, and `_strip_heredocs` writes a
          `#` between the opener line and the terminator tag so the deletion cannot SPLICE.

WHAT THIS FILE GATES (it exits non-zero on any failure):
  1. strict subset of shipped's error set, computed mechanically, over every row any lane wrote,
     with false POSITIVES and false NEGATIVES reported separately (they are not the same harm)
  2. both OBSERVED incident rows asserted BY NAME, not folded into an aggregate
  3. the 40 pinned fixtures (80 checks) still preserved - checked BEFORE any file is edited
  4. five mutation checks, as CODE, each with a sentinel that must flip
  5. the heredoc lemma that "strict subset" silently depends on
  6. a linear-time budget over every construct that has ever backtracked here

Round-7 resolutions (the three items that PARKED revision 6):

  P1  THE DENIED NAME'S EXEC CHANNEL, resolved by name rather than declared once and understated.
      Every name on the deny-list is now classified by whether it has a channel that EXECUTES
      another program:
        grep / egrep / fgrep  - NO exec channel. Safe to deny outright.
        rg / sed              - HAVE one (`rg --pre`, `sed -e '1e cmd'` / `s///e`) and are each
                                MEASURED to fix a real false positive, so the owner's ruling on
                                `sed` applies to both: keep the name, take the loss, DECLARE it.
        ag / ack              - HAVE one (`--pager`) and are measured to fix NOTHING (removing them
                                changes the score by zero). Both tests agree, so they are REMOVED.
                                That closes the `ack --pager='psql -c "..."'` false negative.
      The residual is now one named class with an enumerated membership, not a prose aside.

  P2  THE HEREDOC LEMMA WAS FALSE. `cat <<'SH' |` / body / `SH` / `wc -l`: deleting the body
      spliced the opener line's trailing `|` onto the `SH` terminator, so shipped's branch 5
      (`\\|\\s*(?:ba|z|da|k)?sh\\b`) matched the STRIPPED text and not the original - falsifying the
      lemma AND creating a NEW false positive on a note-write, the exact harm this work removes.
      Fixed by writing a `#` at the splice. `#` is monotone-SAFE: it appears in no lead class, no
      anchor class and no literal in any branch, so no branch can REQUIRE it - insertion can only
      ever destroy a match, never create one. It is also the right thing semantically: what is left
      of the heredoc now reads as a shell comment.

  P3  ACCEPTED_LOSSES KEYED ON FREE TEXT - a per-row allowlist wearing a per-class label. It was
      simultaneously too tight (`sudo sed -i -e '1e cmd'`, in-class, read as UNDECLARED) and too
      loose (any future row reusing the label string is forgiven silently, on BOTH hooks). Now
      keyed on exact COMMAND TEXT, grouped under a class id, with three integrity assertions:
      every declared command matches EXACTLY one row, no command is declared twice, and no
      declared command is stale (declared but not actually a regression).

Round-5 review corrections, still in force, each measured, none assumed:
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

# ----------------------------------------------------------------- EDIT A, the candidate pattern
# Deny-list membership is decided by TWO tests, and a name must pass BOTH to stay:
#   (justified)   removing it is MEASURED to fix a real false positive - rule 6 of the plan;
#   (no exec)     OR, if it does have an execution channel, the loss that denying it takes is
#                 enumerated in ACCEPTED_LOSSES below.
# grep/egrep/fgrep: no execution channel of any kind, so denying them cannot create a false
# negative. egrep/fgrep are measured-INERT on this corpus (removing them changes nothing) and are
# retained as grep aliases on the mechanical argument, not an evidential one - recorded, not hidden.
# rg/sed: justified AND have an exec channel -> kept, loss declared.
# ag/ack: NOT justified AND have an exec channel (`--pager=CMD`) -> removed.
DENY = ["grep", "egrep", "fgrep", "rg", "sed"]
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
    # The deny name is terminated with (?=[ \t]|$), NOT \b. `\b` is satisfied by `=`, so WRAP could
    # match ZERO assignments and the deny alternation would match an ENVIRONMENT VARIABLE NAME -
    # `GREP=1 psql -c '<role flip>'` exempted the whole clause, a SILENT FALSE NEGATIVE that shipped
    # catches. That refuted the claim that this deny-list's incompleteness is always benign.
    end = r"(?=[ \t]|$)"
    look = (r"(?![ \t]*" + wrap + path + r"(?:" + "|".join(deny) + r")" + end + r")" if blanks_inside
            else r"[ \t]*(?!" + wrap + path + r"(?:" + "|".join(deny) + r")" + end + r")")
    return lead + look + scan + r"*?\s-[a-z]*[ce]\s+['\"]"


def compile_with(a3):
    return re.compile(SHIPPED_BRANCHES.replace("{ALT3}", a3), re.IGNORECASE)


INTERP_R7 = compile_with(alt3())


# ------------------------------------------------------- EDIT B, the splice-safe heredoc stripper
# Parameterised on the FILLER so the mutation check can revert exactly this one construct, and so
# this file holds no undrifted private copy of the hook: `disk_filler()` below proves the version on
# disk is one of these two and says which.
def mk_strip_heredocs(filler):
    SUBST, HEREDOC_OPEN = gate["SUBST"], gate["HEREDOC_OPEN"]

    def strip(cmd):
        out, pos = [], 0
        while True:
            mo = HEREDOC_OPEN.search(cmd, pos)
            if not mo:
                out.append(cmd[pos:])
                return "".join(out)
            nl = cmd.find("\n", mo.end())
            if nl == -1:                                  # no body on this call
                out.append(cmd[pos:])
                return "".join(out)
            end = re.compile(r"^[ \t]*" + re.escape(mo.group(2)) + r"[ \t]*$",
                             re.M).search(cmd, nl + 1)
            if not end:                                   # unterminated => fail closed
                out.append(cmd[pos:])
                return "".join(out)
            if SUBST.search(cmd[nl + 1:end.start()]):     # substitutions execute => keep
                out.append(cmd[pos:end.end()])
            else:
                out.append(cmd[pos:nl + 1])
                out.append(filler)
                out.append(cmd[end.start():end.end()])
            pos = end.end()

    return strip


STRIP_SHIPPED = mk_strip_heredocs("")     # what shipped does today
STRIP_CAND = mk_strip_heredocs("#")       # what this change ships


def probe_form(rx, strip):
    """The candidate `_strip_inert_data`: decide on the STRIPPED text, return the ORIGINAL when an
    interpreter fires (a body it may consume must stay scannable)."""
    def f(cmd):
        h = strip(cmd)
        return cmd if rx.search(h) else m.quoted_sub(h)
    return f


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
    (f"sed -e '1e {DEP}' /etc/hosts", 1, 1, "plan-reviewer GNU sed e EXECUTES [exec-channel class]"),
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
ROUND6 = [
    # the env-var-name class: without the (?=[ \t]|$) terminator these were SILENT false negatives
    (f"GREP=1 psql -c '{ROLE}'", 1, 1, "lane2 env-var NAME is a denied word"),
    (f"env GREP=1 /usr/bin/psql -c '{ROLE}'", 1, 1, "lane2 env GREP=1 then psql"),
    (f"RG=1 psql -c '{ROLE}'", 1, 1, "lane2 RG=1 psql"),
    (f"GREPX=1 psql -c '{ROLE}'", 1, 1, "lane2 control: GREPX not denied"),
    # the `(` class: quadratic before the SCAN fix, and two false positives
    (f'(grep -niE "{DEP}|gcloud run services" docs/)', 0, 0, "plan-reviewer subshell grep"),
    (f'n=$(grep -niE "{DEP}" docs/)', 0, 0, "plan-reviewer VAR=$(grep"),
    # the three rows that PARKED revision 6, all resolved in round 7
    (f"sudo sed -i -e '1e {DEP}' /etc/hosts", 1, 1, "plan-reviewer sudo sed EXEC channel"),
    (f"ack --pager='psql -c \"{ROLE}\"' foo", 1, 1, "plan-reviewer ack --pager EXECUTES"),
    (f"cat <<'SH' |\n{DEP}\nSH\nwc -l", 0, 0, "plan-reviewer heredoc |SH LEMMA COUNTEREXAMPLE"),
]
ROUND7 = [
    # the exec-channel class, completed. `ag`/`ack` leave DENY (unjustified AND executing), so these
    # two must PASS. `rg`/`sed` stay (each measured to fix a real FP) and their channel is DECLARED.
    (f"ag --pager='psql -c \"{ROLE}\"' foo", 1, 1, "round7 ag --pager EXECUTES"),
    (f"rg --pre='psql -c \"{ROLE}\"' foo .", 1, 1, "round7 rg --pre EXECUTES [exec-channel class]"),
    (f"fgrep -e '{DEP}' docs/notes.md", 0, 0, "round7 fgrep is a search, no exec channel"),
    # the splice class generalised beyond the SH tag that found it
    (f"cat <<'BASH' |\n{DEP}\nBASH\nwc -l", 0, 0, "round7 splice, (ba)sh tag"),
    (f"cat <<'ZSH' |\n{DEP}\nZSH\nsort", 0, 0, "round7 splice, zsh tag"),
    (f"cat > notes.md <<'EOF'\n{DEP}\nEOF", 0, 0, "round7 splice control: no trailing pipe"),
]
ALL = list(m.CORPUS) + HOLDOUT + ROUND4 + ROUND5 + ROUND6 + ROUND7

# The two rows this whole part exists for. OBSERVED, not invented.
OBSERVED = [
    (f'grep -niE "{DEP}|gcloud run services"', "the 4.3h search"),
    (f"cat > tmp/briefs/x.md <<'EOF'\nWe discussed bash -c and {DEP} here.\nEOF",
     "the 2.7d brief-write"),
]


def errset(fn, rows=None):
    """(row index, command, hook, why, kind). `kind` is restored because a false POSITIVE and a
    false NEGATIVE are not the same harm: 100% of the measured damage in this work is false
    positives (a lock taken for a search), and there is no recorded false-negative incident at all.
    Folding them into one count made the gate unable to say which direction it was refusing."""
    out = set()
    for i, (cmd, wg, wl, why) in enumerate(rows or ALL):
        for hn, ns, want in (("gate", gate, wg), ("ledger", ledger, wl)):
            got = m.classify(cmd, fn, ns)
            if got is not bool(want):
                out.add((i, cmd, hn, why, "FALSE-NEG" if want else "FALSE-POS"))
    return out


# Detections this change KNOWINGLY gives up. Keyed on the exact COMMAND TEXT, grouped under a class
# id - NOT on the free-text `why` label, which made this a per-row allowlist wearing a per-class
# name: too tight (an in-class row with a different label read as UNDECLARED) and too loose (any
# future unrelated row reusing the label was forgiven silently, on BOTH hooks). Three integrity
# assertions below stop it drifting back: each declared command must match EXACTLY one corpus row,
# no command may be declared twice, and a declared command that is not actually a regression is
# STALE and fails the run.
ACCEPTED_LOSSES = {
    "pd:7-denied-name-exec-channel": {
        "rationale":
            "A deny-list name that itself has a channel for EXECUTING another program. `rg` and "
            "`sed` are each MEASURED to fix a real false positive, so both stay denied and the "
            "channel is given up - the owner's ruling on `sed` (keep the name, take the loss, "
            "declare it openly) applied to the whole class rather than to one form of one name. "
            "`ag`/`ack` had the same channel and fixed NOTHING, so they were REMOVED from DENY "
            "instead. Reversing any of this is one name in DENY. Members enumerated below; the "
            "class is CLOSED over the deny-list, since a name with no exec channel cannot join it.",
        "commands": [
            f"sed -e '1e {DEP}' /etc/hosts",
            f"sudo sed -i -e '1e {DEP}' /etc/hosts",
            f"rg --pre='psql -c \"{ROLE}\"' foo .",
        ],
    },
}

rc = 0

# --- ACCEPTED_LOSSES integrity, asserted BEFORE it is allowed to forgive anything ---------------
declared_cmds, dup, unmatched, ambiguous = {}, [], [], []
for cls, spec in ACCEPTED_LOSSES.items():
    for c in spec["commands"]:
        if c in declared_cmds:
            dup.append((cls, c))
        declared_cmds[c] = cls
        n = sum(1 for cmd, _, _, _ in ALL if cmd == c)
        if n == 0:
            unmatched.append((cls, c))
        elif n > 1:
            ambiguous.append((cls, c, n))

base = errset(m.mk_current)
cand = errset(probe_form(INTERP_R7, STRIP_CAND))
new = cand - base
undeclared = {r for r in new if r[1] not in declared_cmds}
declared = new - undeclared
stale = sorted(set(declared_cmds) - {r[1] for r in new})

print(f"rows {len(ALL)}   checks {len(ALL) * 2}   shipped errors {len(base)}\n")
print("0. ACCEPTED_LOSSES integrity (keyed on COMMAND TEXT, not a label):")
for cls, c in dup:
    print(f"    DECLARED TWICE   [{cls}] {c!r}")
for cls, c in unmatched:
    print(f"    MATCHES NO ROW   [{cls}] {c!r}")
for cls, c, n in ambiguous:
    print(f"    MATCHES {n} ROWS  [{cls}] {c!r}")
for c in stale:
    print(f"    STALE (declared, not a regression) [{declared_cmds[c]}] {c!r}")
bad_decl = bool(dup or unmatched or ambiguous or stale)
rc |= 1 if bad_decl else 0
print(f"    {len(declared_cmds)} declared command(s) in {len(ACCEPTED_LOSSES)} class(es); "
      f"{'OK - each matches exactly one row and each is a real regression' if not bad_decl else 'BROKEN - see above'}")

fp = sum(1 for r in cand if r[4] == "FALSE-POS")
fn = len(cand) - fp
bfp = sum(1 for r in base if r[4] == "FALSE-POS")
print(f"\nrevision 7: {len(ALL) * 2 - len(cand)}/{len(ALL) * 2} | fixed {len(base - cand)} | "
      f"{'strict subset APART FROM the declared losses below' if not undeclared else f'NOT a subset ({len(undeclared)} UNDECLARED regressions)'}")
print(f"    errors by direction: shipped {bfp} FALSE-POS / {len(base) - bfp} FALSE-NEG"
      f"  ->  candidate {fp} FALSE-POS / {fn} FALSE-NEG")
for _, _, hn, why, kind in sorted(undeclared, key=lambda x: x[3]):
    print(f"    UNDECLARED REGRESSION [{hn:6}] {kind} {why}")
for _, c, hn, why, kind in sorted(declared, key=lambda x: x[3]):
    print(f"    declared loss [{hn:6}] {kind} {why}  ({declared_cmds[c]})")
for cls in sorted({declared_cmds[c] for _, c, _, _, _ in declared}):
    print(f"        -> {cls}: {ACCEPTED_LOSSES[cls]['rationale']}")
rc |= 1 if undeclared else 0
print("  (the number is a property of these rows, not of the classifier)")

print("\n1. OBSERVED incident rows, asserted by name:")
for cmd, why in OBSERVED:
    fn_ = probe_form(INTERP_R7, STRIP_CAND)
    g = m.classify(cmd, fn_, gate)
    l = m.classify(cmd, fn_, ledger)
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
         if m.classify(cmd, probe_form(INTERP_R7, STRIP_CAND), ns) is not (exp == PRODC)]
rc |= 1 if broke else 0
print(f"    {len(CASES) * 2 - len(broke)}/{len(CASES) * 2}")
for hn, cn in broke:
    print(f"    BREAKS [{hn}] {cn}")

print("\n3. mutation checks - each must FLIP its sentinel (a test never watched failing is not a test):")
MUTATIONS = [
    ("M1 remove the deny-list entirely",
     compile_with(r"(?:^|" + ANCHOR + r")" + SCAN + r"*?\s-[a-z]*[ce]\s+['\"]"), STRIP_CAND,
     f'grep -niE "{DEP}" docs/', 0),
    ("M2 anchor the deny-list at the token before the flag, not clause start",
     compile_with(r"(?:^|" + ANCHOR + r")(?![ \t]*" + WRAP + PATHP
                  + r"(?:" + "|".join(DENY) + r")\b)\s*\S*\s-[a-z]*[ce]\s+['\"]"), STRIP_CAND,
     f'psql "$PROD_URL" -c \'{ROLE}\'', 1),
    ("M3 blanks back OUTSIDE the lookahead (the PRR1 defect)",
     compile_with(alt3(blanks_inside=False)), STRIP_CAND, f'  grep -niE "{DEP}" docs/', 0),
    ("M4 drop the backtick from the anchor class (the F2 defect)",
     compile_with(alt3(anchor=r"[\n;|&(]", scan=r"[^\n;|&]")), STRIP_CAND,
     f"grep -rn foo docs/ {BT}psql \"$U\" -c '{ROLE}'{BT}", 1),
    ("M5 drop the heredoc splice filler (the P2 defect)",
     INTERP_R7, STRIP_SHIPPED, f"cat <<'SH' |\n{DEP}\nSH\nwc -l", 0),
    ("M6 keep ag/ack denied (the P1 exec channel)",
     compile_with(alt3(deny=DENY + ["ag", "ack"])), STRIP_CAND,
     f"ack --pager='psql -c \"{ROLE}\"' foo", 1),
]
for label, rx, strip, sentinel, want in MUTATIONS:
    got = m.classify(sentinel, probe_form(rx, strip), gate)
    red = got is not bool(want)
    rc |= 0 if red else 1
    print(f"    {label:62} {'flips -> RED' if red else 'STILL PASSES -> USELESS'}")

print("\n4. heredoc lemma - 'strict subset' silently depends on this and nothing tested it:")
print("   stripping a heredoc body must never CREATE a shipped match spanning the splice.")
viol = [why for cmd, _, _, why in ALL
        if m.INTERP_CUR.search(STRIP_CAND(cmd)) and not m.INTERP_CUR.search(cmd)]
was = [why for cmd, _, _, why in ALL
       if m.INTERP_CUR.search(STRIP_SHIPPED(cmd)) and not m.INTERP_CUR.search(cmd)]
rc |= 1 if viol else 0
print(f"    with the filler   : {'holds over all ' + str(len(ALL)) + ' rows' if not viol else 'VIOLATIONS: ' + str(viol)}")
print(f"    without it (today): {'holds' if not was else 'VIOLATIONS: ' + str(was)}"
      "   <- the counterexample the lemma was asserted without")

print("\n5. time budget - every construct that has ever backtracked in this work:")
for label, mk, fn_t in (
        ("blank run", lambda n: ";" + " " * n + "-x", None),
        ("backtick run", lambda n: BT * n + " -x", None),
        ("paren run", lambda n: "(" * n + " -x", None),
        ("subshell nest", lambda n: "(cd x && echo y" * n + " -z", None),
        ("commit msg parens", lambda n: 'git commit -m "' + "refactor (see note) " * n + '"', None),
        ("wrapper run", lambda n: ";" + "sudo " * n + "-x", None),
        ("env-assignment run", lambda n: ";" + "A=a=b=c " * n + "-x", None),
        ("path run", lambda n: ";" + "a/" * n + " -x", None),
        ("quoted tokens", lambda n: "psql " + '"x" ' * n + "--zzz", None),
        ("repeated options", lambda n: "bash " + "--rcfile /tmp/x " * n + "-z v", None),
        ("one long clause", lambda n: "psql " + "x " * n + "-c 'y'", None),
        # EDIT B is code, not a regex, and it now writes into its own output - time it too.
        ("heredoc stripper", lambda n: "".join(f"cat <<'E{i}' |\nbody\nE{i}\n" for i in range(n)),
         STRIP_CAND),
        ("unterminated heredocs", lambda n: "".join(f"cat <<'E{i}' |\nbody\n" for i in range(n)),
         STRIP_CAND)):
    row, worst = f"    {label:22}", 0.0
    for n in (400, 1600, 6400):
        s = mk(n)
        t0 = time.time()
        (fn_t or INTERP_R7.search)(s)
        el = time.time() - t0
        worst = max(worst, el)
        row += f" n={n}:{el:7.4f}s"
    over = worst > BUDGET
    rc |= 1 if over else 0
    print(row + ("  <== OVER BUDGET" if over else ""))

print("\n6. two-hook agreement + on-disk drift:")
# The plan said "the drift guard is red in between" while the region is applied to one hook and not
# the other. Measured in round 6: ZERO of the 40 pinned fixtures change verdict under this edit, so
# 06 reports 80/80 whether zero, one, or both hooks are edited. Nothing anywhere compared the two
# hooks' INTERP patterns. Post-edit, THIS is the assertion that catches a one-hook typo.
same_pat = (gate["INTERP"].pattern == ledger["INTERP"].pattern
            and gate["INTERP"].flags == ledger["INTERP"].flags)
sens = sum(1 for cn, cmd, ge, le in CASES
           if m.classify(cmd, m.mk_current, gate)
           is not m.classify(cmd, probe_form(INTERP_R7, STRIP_CAND), gate))
# Which `_strip_heredocs` is on disk? This file holds a PARAMETERISED copy rather than a frozen one,
# so it must prove the disk version is one of the two parameterisations and say which.
probe_rows = [c for c, _, _, _ in ALL] + [c for c, _ in OBSERVED]
fillers = [f for f, s in (("", STRIP_SHIPPED), ("#", STRIP_CAND))
           if all(s(c) == m.strip_heredocs(c) for c in probe_rows)]
print(f"    gate.INTERP == ledger.INTERP on disk (pattern + flags): {same_pat}")
print(f"    on-disk _strip_heredocs filler: {fillers!r}"
      f"{'   <== THIRD FORM - neither parameterisation matches disk' if len(fillers) != 1 else ''}")
print(f"    pinned fixtures whose verdict CHANGES under this edit: {sens}/{len(CASES)}"
      f"{'   <== so 06 CANNOT detect a half-applied edit' if sens == 0 else ''}")
rc |= 0 if same_pat else 1
rc |= 0 if len(fillers) == 1 else 1

print(f"\n{'ALL GATES PASS' if rc == 0 else 'GATE REFUSES - see above'}")
sys.exit(rc)
