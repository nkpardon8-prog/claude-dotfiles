#!/bin/bash
# 04-classifier-corpus.sh — evaluate CANDIDATE classifier designs against a corpus, before editing
# the real hook files.
#
# Part 2 proposes three edits to the shared classifier. Two independent reviews (Claude + Codex)
# converged on the same two CRITICAL defects in them, including a FALSE NEGATIVE on a listed
# must-stay-PROD carve-out (`psql "$PROD_URL" -c 'ALTER ROLE app BYPASSRLS'`). A false negative here
# means a real production role-flip runs unlocked and unlogged.
#
# Arguing about regexes in prose is how those defects got written. This runs them.
#
# It loads the REAL helpers out of prod-coordination-gate.py (truncated before main(), so nothing
# executes and no lock is touched), then evaluates each candidate `_strip_inert_data` over a corpus
# labelled in BOTH directions. A candidate is only correct if it gets every row right.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
python3 - <<'PY'
import os, re, sys

GATE = os.path.join(os.path.dirname(os.path.abspath("__file__")), "..", "prod-coordination-gate.py")
GATE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0] if sys.argv[0] else ".")), GATE))
if not os.path.exists(GATE):
    GATE = os.path.expanduser("~/.claude-dotfiles/scripts/hooks/prod-coordination-gate.py")

src = open(GATE).read()
marker = "\ntry:\n    main()"
cut = src.find(marker)
assert cut != -1, "harness marker missing — the gate's module bottom changed"
ns = {"__name__": "gate_probe"}
exec(compile(src[:cut], GATE, "exec"), ns)          # nothing runs; main() is not reached

PROD           = ns["PROD"]; MIGRATE = ns["MIGRATE"]
QUOTED         = ns["QUOTED"]; SUBST = ns["SUBST"]
strip_heredocs = ns["_strip_heredocs"]
INTERP_CUR     = ns["INTERP"]

# ── the corpus: (command, must_be_prod, why) ───────────────────────────────────────────────
CORPUS = [
    # ---- MUST STAY PROD (a false negative here is an unlocked production action) ----
    ('psql "$PROD_URL" -c \'ALTER ROLE app BYPASSRLS\'', True, "listed carve-out; connection arg before -c"),
    ("psql -h db.prod -U app -c 'ALTER ROLE app BYPASSRLS'", True, "value-taking flags before -c"),
    ("bash -c 'ALLOW_PROD_MIGRATE_DEPLOY=1 npm run db:migrate:deploy'", True, "listed carve-out"),
    ('docker exec box sh -lc "gcloud run deploy summit-api"', True, "listed carve-out"),
    ("ssh deploybox 'gcloud run deploy summit-api'", True, "listed carve-out"),
    ("echo \"$(gcloud run deploy summit-api)\"", True, "command substitution"),
    ("ssh box <<'EOF'\ngcloud run deploy summit-api\nEOF", True, "heredoc consumed by ssh"),
    ("sh <<'EOF'\ngcloud run deploy summit-api\nEOF", True, "heredoc executed directly by sh"),
    ("cat <<'EOF' | sh\ngcloud run deploy summit-api\nEOF", True, "heredoc piped to sh"),
    ("cat <<'EOF' | /bin/sh\ngcloud run deploy summit-api\nEOF", True, "piped to an absolute-path sh"),
    ("eval \"$(cat <<'EOF'\ngcloud run deploy summit-api\nEOF\n)\"", True, "heredoc via eval + substitution"),
    ("su - postgres -c 'npm run db:migrate:deploy'", True, "su -c wrapper"),
    ("gcloud run deploy summit-api --region us-central1", True, "the plain form"),

    # ---- MUST STAY SAFE (a false positive here takes the machine-wide lock) ----
    ('grep -niE "gcloud builds submit|gcloud run deploy|gcloud run services"', False, "THE 4.3h outage: a search"),
    ('rg "prisma migrate deploy" server/', False, "a search"),
    ("sed -e 's/gcloud run deploy/x/' f", False, "sed -e is not an interpreter -e"),
    ('grep -c "prisma migrate deploy" f', False, "grep -c is not psql -c"),
    ("cat > tmp/briefs/x.md <<'EOF'\nWe discussed bash -c and git push here.\nEOF",
     False, "THE brief-write: a document that quotes shell"),
    ("echo 'gcloud run deploy is what we will run tomorrow'", False, "quoted prose"),
]

def classify(cmd, strip_fn):
    """Mirror is_prod's front half: strip inert data, then look for prod markers."""
    stripped = strip_fn(cmd)
    return bool(PROD.search(stripped) or MIGRATE.search(stripped))

def quoted_sub(c):
    return QUOTED.sub(lambda m: m.group(0) if SUBST.search(m.group(0)) else " ", c)

# ── candidate A: CURRENT shipped behavior ──────────────────────────────────────────────────
def cand_current(cmd):
    if INTERP_CUR.search(cmd):
        return cmd
    return quoted_sub(strip_heredocs(cmd))

# ── candidate B: the plan's Edit B (strip heredocs FIRST, then check INTERP) ────────────────
def cand_planB(cmd):
    c = strip_heredocs(cmd)
    if INTERP_CUR.search(c):
        return c
    return quoted_sub(c)

# ── candidate C: the reviewer's PROBE formulation ──────────────────────────────────────────
# Decide INTERP on the stripped text (so a body's PROSE cannot veto its own container), but when
# INTERP fires return the ORIGINAL, unstripped command (so an interpreter in the CONTAINER keeps
# the body scannable). This is what deletes the plan's Edit C entirely.
def cand_probe(cmd):
    if INTERP_CUR.search(strip_heredocs(cmd)):
        return cmd
    return quoted_sub(strip_heredocs(cmd))

CANDS = [("current (shipped)", cand_current),
         ("plan Edit B", cand_planB),
         ("reviewer probe", cand_probe)]

print(f"corpus: {len(CORPUS)} rows  ({sum(1 for _,p,_ in CORPUS if p)} must-be-PROD, "
      f"{sum(1 for _,p,_ in CORPUS if not p)} must-be-SAFE)\n")

results = {}
for name, fn in CANDS:
    wrong = []
    for cmd, want, why in CORPUS:
        try:
            got = classify(cmd, fn)
        except Exception as e:
            got = f"ERROR:{e}"
        if got is not want:
            kind = "FALSE-NEG" if want else "FALSE-POS"
            wrong.append((kind, why, cmd.split("\n")[0][:58]))
    results[name] = wrong
    print(f"=== {name}: {len(CORPUS)-len(wrong)}/{len(CORPUS)} correct ===")
    for kind, why, c in wrong:
        print(f"    {kind:9} {why:46} | {c}")
    print()

print("NOTE: no candidate is expected to be perfect yet — this probe exists to make the tradeoff")
print("visible and measurable BEFORE the shared classifier is edited. A FALSE-NEG is an unlocked")
print("production action; a FALSE-POS is a machine-wide lock. They are not equally bad.")
PY
