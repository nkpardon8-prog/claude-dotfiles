#!/usr/bin/env python3
"""Round-2 scorer: VERIFY the plan-reviewer's hand-simulated findings by measurement, and score a
revision-3 candidate built from its suggested fixes.

The reviewer had no shell; every one of its claims is a hand-trace. Each adversarial row below is
tagged with the finding it tests, so a claim that does not reproduce is visible rather than absorbed.
Scores BOTH hooks' PROD regexes (finding 3: the defect being fixed is ledger-only).
"""
import os, re

H = os.path.expanduser("~/.claude-dotfiles/scripts/hooks")


def load(fname):
    path = os.path.join(H, fname)
    src = open(path).read()
    cut = src.find("\ntry:\n    main()")
    assert cut != -1, fname
    ns = {"__name__": "probe", "__file__": path}
    exec(compile(src[:cut], path, "exec"), ns)
    return ns


gate = load("prod-coordination-gate.py")
ledger = load("prod-ledger.py")
QUOTED, SUBST, strip_heredocs = gate["QUOTED"], gate["SUBST"], gate["_strip_heredocs"]
INTERP_CUR = gate["INTERP"]

# ---------------- revision 2 (what the plan currently says) ----------------
NAMES2 = r"python[0-9.]*|perl|ruby|node|deno|psql|mysql|mariadb|osascript|fish|pwsh"
SHELL = r"(?:ba|z|da|k|a)?sh"
LEAD2 = r"(?:^|[\s|;&(/\"'])"
GAP2 = r"(?:\s+[^\s|;&<>\n]+)*?"
CMDPOS2 = r"(?:^|[\n;|&(])\s*"
INTERP_R2 = re.compile(
    LEAD2 + r"(?:eval|xargs|ssh|su|runuser|doas)\b"
    + r"|" + LEAD2 + SHELL + r"\b(?:\s+--?[A-Za-z-]+)*\s+-[A-Za-z]*c\b"
    + r"|" + LEAD2 + r"(?:" + NAMES2 + r")\b" + GAP2 + r"\s+-[A-Za-z]*[ce]\s+['\"]"
    + r"|--(?:command|eval)="
    + r"|\|\s*(?:\S*/)?" + SHELL + r"\b"
    + r"|" + CMDPOS2 + r"(?:\S*/)?" + SHELL + r"\b(?:\s+-[A-Za-z]+)*\s*<<",
    re.IGNORECASE,
)

# ---------------- revision 3 (reviewer's fixes F1,F2,F4,F5,F6 applied) ----------------
NAMES3 = (r"python[0-9.]*|perl|ruby|node|deno|ts-node|bun|psql|mysql|mariadb|osascript"
          r"|fish|pwsh|tclsh")
LEAD_Q = r"(?:^|[\s|;&(/\"'])"      # quote-inclusive: ONLY the sh -c branch needs it
LEAD_N = r"(?:^|[\s|;&(/])"         # quote-free: prevents `grep -rn \"ssh ...\"` flipping to PROD
# F1: walk a QUOTED token whole, so a DSN containing & or > cannot break the walk.
# F4: separators are [ \t]+ only, so a newline cannot bridge two clauses.
GAP3 = r"(?:[ \t]+(?:\"[^\"\n]*\"|'[^'\n]*'|[0-9]*[<>]&?[0-9]*|[^\s|;&<>\n]+))*?"
# F5: accept the space-separated long form (--command 'x', --eval "x") as well as -c/-e.
FLAG3 = r"[ \t]+--?[A-Za-z]*(?:[ce]|command|eval)[ \t]+['\"]"
# F6: allow a wrapper/env prefix run before the shell in the two heredoc-execution branches.
PREFIX = r"(?:(?:sudo|env|time|nohup|command)\s+|\S+=\S+\s+)*"
CMDPOS3 = r"(?:^|[\n;|&(])\s*"
INTERP_R3 = re.compile(
    LEAD_N + r"(?:eval|xargs|ssh|su|runuser|doas)\b"
    + r"|" + LEAD_Q + SHELL + r"\b(?:[ \t]+--?[A-Za-z-]+)*[ \t]+-[A-Za-z]*c\b"
    + r"|" + LEAD_N + r"(?:" + NAMES3 + r")\b" + GAP3 + FLAG3
    + r"|--(?:command|eval)="
    + r"|\|\s*" + PREFIX + r"(?:\S*/)?" + SHELL + r"\b"
    + r"|" + CMDPOS3 + PREFIX + r"(?:\S*/)?" + SHELL + r"\b(?:[ \t]+-[A-Za-z]+)*[ \t]*<<",
    re.IGNORECASE,
)

DEPLOY = "gcloud run deploy summit-api"
ROLEFLIP = "ALTER ROLE app BYPASSRLS"
DSN = "postgresql://app@db.prod.example/summit?sslmode=require&connect_timeout=10"

# (command, must_be_prod_on_gate, must_be_prod_on_ledger, why)
CORPUS = [
    # ===== original 19 must-be-PROD =====
    (f'psql "$PROD_URL" -c \'{ROLEFLIP}\'', 1, 1, "carve-out: conn arg before -c"),
    (f"psql -h db.prod -U app -c '{ROLEFLIP}'", 1, 1, "value-taking flags before -c"),
    (f"psql -v ON_ERROR_STOP=1 -c '{ROLEFLIP}'", 1, 1, "-v assignment before -c"),
    ("bash -c 'ALLOW_PROD_MIGRATE_DEPLOY=1 npm run db:migrate:deploy'", 1, 1, "carve-out"),
    (f"bash --noprofile -c '{DEPLOY}'", 1, 1, "long flag before -c"),
    (f'docker exec box sh -lc "{DEPLOY}"', 1, 1, "carve-out"),
    (f'docker exec box "sh -lc \'{DEPLOY}\'"', 1, 1, "quote as leading boundary"),
    (f"ssh deploybox '{DEPLOY}'", 1, 1, "carve-out"),
    (f"/usr/bin/ssh box '{DEPLOY}'", 1, 1, "absolute-path ssh [INVENTED]"),
    (f'echo "$({DEPLOY})"', 1, 1, "command substitution"),
    (f"ssh box <<'EOF'\n{DEPLOY}\nEOF", 1, 1, "heredoc consumed by ssh"),
    (f"sh <<'EOF'\n{DEPLOY}\nEOF", 1, 1, "pd:6 heredoc executed by sh"),
    (f"bash <<'EOF'\n{DEPLOY}\nEOF", 1, 1, "pd:6 heredoc executed by bash"),
    (f"cat <<'EOF' | sh\n{DEPLOY}\nEOF", 1, 1, "heredoc piped to sh"),
    (f"cat <<'EOF' | /bin/sh\n{DEPLOY}\nEOF", 1, 1, "pd:6 absolute-path sh"),
    (f"eval \"$(cat <<'EOF'\n{DEPLOY}\nEOF\n)\"", 1, 1, "heredoc via eval"),
    ("su - postgres -c 'npm run db:migrate:deploy'", 1, 1, "su -c wrapper"),
    (f"python3 -OOc 'import os; os.system(\"{DEPLOY}\")'", 1, 1, "multi-letter -OOc [INVENTED]"),
    (f"{DEPLOY} --region us-central1", 1, 1, "the plain form [OBSERVED]"),

    # ===== NEW: reviewer findings 1, 5, 6 - claimed FALSE NEGATIVES in revision 2 =====
    (f'psql "{DSN}" -c \'{ROLEFLIP}\'', 1, 1, "F1 DSN with & breaks gap walk"),
    (f'psql "$PROD_URL" 2>&1 -c \'{ROLEFLIP}\'', 1, 1, "F1 redirection token has >"),
    (f'psql "$PROD_URL" --command \'{ROLEFLIP}\'', 1, 1, "F5 space-separated long form"),
    (f"ts-node -e 'require(\"child_process\").execSync(\"{DEPLOY}\")'", 1, 1, "F5 name not in list"),
    (f"sudo sh <<'EOF'\n{DEPLOY}\nEOF", 1, 1, "F6 sudo prefix before shell"),
    (f"DEBUG=1 sh <<'EOF'\n{DEPLOY}\nEOF", 1, 1, "F6 env-assignment prefix"),
    (f"cat <<'EOF' | sudo sh\n{DEPLOY}\nEOF", 1, 1, "F6 sudo after the pipe"),

    # ===== original 9 must-be-SAFE =====
    ('grep -niE "gcloud builds submit|gcloud run deploy|gcloud run services"', 0, 0,
     "THE 4.3h outage [OBSERVED]"),
    ('rg "prisma migrate deploy" server/', 0, 0, "a search"),
    (f"sed -e 's/{DEPLOY}/x/' f", 0, 0, "sed -e is not an interpreter -e"),
    ('grep -c "prisma migrate deploy" f', 0, 0, "grep -c is not psql -c"),
    # F3: body now carries a GATE-prod token too, so this row finally DISCRIMINATES Edit B.
    (f"cat > tmp/briefs/x.md <<'EOF'\nWe discussed bash -c and {DEPLOY} and git push here.\nEOF",
     0, 0, "F3 THE brief-write, now discriminating [OBSERVED]"),
    (f"cat > /tmp/sh <<'EOF'\n{DEPLOY}\nEOF", 0, 0, "file NAMED sh, not a shell"),
    (f"echo '{DEPLOY} is what we will run tomorrow'", 0, 0, "quoted prose"),
    (f"ls | grep python && sed -e 's/{DEPLOY}/x/' f", 0, 0, "name+flag bridged by &&"),
    (f'git commit -m "fix: stop filing {DEPLOY} as a deploy"', 0, 0, "commit message"),

    # ===== NEW: reviewer findings 2, 4 - claimed FALSE POSITIVES in revision 2 =====
    (f"grep -rn \"ssh deploybox '{DEPLOY}'\" docs/", 0, 0, "F2 search quoting an ssh deploy"),
    (f"git commit -m \"runbook: '/usr/bin/ssh box {DEPLOY}' is banned\"", 0, 0, "F2 quote+slash lead"),
    ('psql --version\ngrep -c "prisma migrate deploy" server/src/db.ts', 0, 0,
     "F4 newline bridges the gap"),
]


def quoted_sub(c):
    return QUOTED.sub(lambda m: m.group(0) if SUBST.search(m.group(0)) else " ", c)


def mk_current(cmd):
    return cmd if INTERP_CUR.search(cmd) else quoted_sub(strip_heredocs(cmd))


def probe_form(rx):
    def f(cmd):
        h = strip_heredocs(cmd)
        return cmd if rx.search(h) else quoted_sub(h)
    return f


def classify(cmd, strip_fn, ns):
    saved = ns["_strip_inert_data"]
    ns["_strip_inert_data"] = strip_fn
    try:
        return ns["is_prod"](cmd)
    finally:
        ns["_strip_inert_data"] = saved


# ---------------- revision 3b: branch 1 keeps the SHIPPED lead class ----------------
# F2's residual: `/` in branch 1's lead makes `git commit -m "... '/usr/bin/ssh box <deploy>' ..."`
# a false positive, because an absolute-path interpreter inside quoted PROSE is textually identical
# to one in command position. Per the reviewer's own rule - never take a widening that costs false
# positives without an OBSERVED row justifying it - branch 1 reverts to the shipped lead class.
# Cost: `/usr/bin/ssh box '<deploy>'` stays a false negative. That is PRE-EXISTING and unchanged,
# not a regression, and it is an invented row with no observed instance.
LEAD_S = r"(?:^|[\s|;&(])"
INTERP_R3B = re.compile(
    LEAD_S + r"(?:eval|xargs|ssh|su|runuser|doas)\b"
    + r"|" + LEAD_Q + SHELL + r"\b(?:[ \t]+--?[A-Za-z-]+)*[ \t]+-[A-Za-z]*c\b"
    + r"|" + LEAD_N + r"(?:" + NAMES3 + r")\b" + GAP3 + FLAG3
    + r"|--(?:command|eval)="
    + r"|\|\s*" + PREFIX + r"(?:\S*/)?" + SHELL + r"\b"
    + r"|" + CMDPOS3 + PREFIX + r"(?:\S*/)?" + SHELL + r"\b(?:[ \t]+-[A-Za-z]+)*[ \t]*<<",
    re.IGNORECASE,
)

# ---------------- revision 4: + Codex lane ----------------
# Changes on top of 3b, each traceable to a measured Codex finding:
#  C6  the row that justified a quote-inclusive lead is MISLABELLED - `docker exec box "sh -lc 'x'"`
#      passes ONE argv element, so docker tries to exec a file literally named `sh -lc 'x'` and the
#      command performs nothing. Quotes therefore leave EVERY lead class; the real prod form
#      (unquoted `docker exec box sh -lc 'x'`) is still caught by the plain whitespace lead.
#  C9  `(?-i:[ce])` makes the flag letter case-SENSITIVE while the rest stays case-insensitive.
#      This is the ROOT of the original outage: IGNORECASE is why `-niE` matched `[ce]`.
#      It also kills `python3 -E 'script.py'` (a real shipped false positive).
#  C7  `\S*/` let a REDIRECTION be consumed (`>/tmp/sh <<EOF` is a redirect, not execution).
#      Restrict the path prefix to path characters so it cannot cross `>` `<` `|` `&`.
LEAD_P = r"(?:^|[\s|;&(])"
PATHPFX = r"(?:[A-Za-z0-9_.\-]*/)*"
FLAG4 = r"[ \t]+--?[A-Za-z]*(?:(?-i:[ce])|command|eval)[ \t]+['\"]"
INTERP_R4 = re.compile(
    LEAD_P + r"(?:eval|xargs|ssh|su|runuser|doas)\b"
    + r"|" + LEAD_P + PATHPFX + SHELL + r"\b(?:[ \t]+--?[A-Za-z-]+)*[ \t]+-[A-Za-z]*c\b"
    + r"|" + LEAD_P + r"(?:" + NAMES3 + r")\b" + GAP3 + FLAG4
    + r"|--(?:command|eval)="
    + r"|\|\s*" + PREFIX + PATHPFX + SHELL + r"\b"
    + r"|" + CMDPOS3 + PREFIX + PATHPFX + SHELL + r"\b(?:[ \t]+[^\s|;&<>\n]+)*?[ \t]*<<",
    re.IGNORECASE,
)

# Codex's new adversarial rows (C6/C7/C9). The docker-quoted row is RELABELLED per C6.
CORPUS.extend([
    (f"command sh <<'EOF'\n{DEPLOY}\nEOF", 1, 1, "C5 `command` prefix before shell"),
    (f"sh -o pipefail <<'EOF'\n{DEPLOY}\nEOF", 1, 1, "C5 value-taking shell option"),
    (f"rg 'ssh box {DEPLOY}' docs/", 0, 0, "C6 single-quoted ssh in a search"),
    (f"sed '/ssh box {DEPLOY}/d' docs/ops.md", 0, 0, "C6 quoted ssh in a sed script"),
    (f"git commit -m 'ssh: document {DEPLOY}'", 0, 0, "C6 quoted ssh in a commit msg"),
    (f"rg '/usr/bin/ssh box {DEPLOY}' docs/", 0, 0, "C6 quoted absolute-path ssh"),
    (f">/tmp/sh <<'EOF'\n{DEPLOY}\nEOF", 0, 0, "C7 redirection, NOT execution"),
    (f"python3 -E '{DEPLOY}'", 0, 0, "C9 -E is not python code (IGNORECASE root cause)"),
    (f"docker exec box sh -lc '{DEPLOY}'", 1, 1, "C6 the REAL docker prod form"),
])
# C6: relabel the mislabelled row - one argv element docker cannot shell-parse.
CORPUS[:] = [(c, 0, 0, why + " [RELABELLED per C6: docker cannot shell-parse one argv]")
             if why == "quote as leading boundary" else (c, g, l, why)
             for (c, g, l, why) in CORPUS]

CANDS = [("current (shipped)", mk_current),
         ("revision 2 (plan as written)", probe_form(INTERP_R2)),
         ("revision 3b (plan-reviewer fixes)", probe_form(INTERP_R3B)),
         ("revision 4 (+ Codex fixes)", probe_form(INTERP_R4))]

for name, fn in CANDS:
    wrong = []
    for cmd, wg, wl, why in CORPUS:
        for hookname, ns, want in (("gate", gate, wg), ("ledger", ledger, wl)):
            got = classify(cmd, fn, ns)
            if got is not bool(want):
                wrong.append((("FALSE-NEG" if want else "FALSE-POS"), hookname, why))
    total = len(CORPUS) * 2
    print(f"=== {name}: {total-len(wrong)}/{total} ===")
    for kind, hook, why in wrong:
        print(f"    {kind:9} [{hook:6}] {why}")
    print()
