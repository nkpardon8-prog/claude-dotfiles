#!/usr/bin/env python3
"""
prod-ledger — a shared, auto-maintained log of prod-facing actions (push / deploy /
migrate) so parallel Claude agents know what is already live before they act.

Why: multiple agents share one repo + one prod. A passive doc doesn't get read.
This is hook-driven instead:
  * PostToolUse `record` auto-appends on every push/deploy/migrate Bash command —
    nobody has to remember to log.
  * SessionStart `inject` puts the recent ledger into every new agent's context —
    nobody has to remember to read.
  * `show` / `add` are the manual CLI for humans + agents mid-session.

Per-project: keyed by the git repo (all worktrees of one repo share one ledger).
Stored locally at ~/.claude/prod-ledger/<project>.jsonl (no git merge conflicts;
all the user's agents run on one machine). FAIL-OPEN everywhere — never breaks a
tool call or a session start.
"""
import sys, os, json, time, subprocess, re

LEDGER_DIR = os.path.expanduser("~/.claude/prod-ledger")
PROD = re.compile(
    r"git\s+push\b"
    r"|gcloud\s+run\s+deploy"
    r"|gcloud\s+run\s+services\s+update"
    r"|gcloud\s+builds\s+submit"
    r"|prisma\s+migrate\s+deploy"
    r"|migrate\s+resolve\s+--applied"
    r"|ALLOW_PROD_MIGRATE_DEPLOY"
    r"|MIGRATOR_DIRECT_URL"
    r"|neon\.tech"
    r"|db:migrate:deploy"
    r"|ALTER\s+ROLE\b[^;]*\b(?:BYPASSRLS|NOBYPASSRLS)\b",
    re.IGNORECASE,
)

# --- Fail-closed prod classifier (duplicated verbatim in prod-coordination-gate.py)
# A migrate is a prod op UNLESS every postgres URL in the migrate's OWN shell
# clause PARSES (urlparse hostname — never substring) to exactly localhost /
# 127.0.0.1 / the docker service hostname `postgres`. Anything unknown, spoofed
# (user:localhost@prod.internal, @localhost.evil.example), or unparseable stays
# PROD. `docker exec` / `POSTGRES_` tokens / env-var bare migrates do NOT exempt.
# Spec: tmp/ready-plans/2026-07-10-skill-stack-top-fixes.md — "Prod narrowing"
# (Key Pseudocode 6). These hook scripts have no shared import path, so the
# classifier is duplicated in both by design; the fixture suite pins them equal.
MIGRATE = re.compile(r"prisma\s+migrate\s+deploy|db:migrate:deploy", re.I)
PRODMARK = re.compile(r"ALLOW_PROD_MIGRATE_DEPLOY|MIGRATOR_DIRECT_URL|neon\.tech", re.I)


def _all_urls_local(cmd):
    # Only exact hostname equality counts; parse failure = NOT local (prod-risk).
    from urllib.parse import urlparse
    urls = re.findall(r"postgres(?:ql)?://[^\s\"']+", cmd, re.I)
    if not urls:
        return False
    for u in urls:
        try:
            host = (urlparse(u).hostname or "").lower()
        except ValueError:
            return False
        if host not in ("localhost", "127.0.0.1", "postgres"):
            return False
    return True


def is_prod(cmd):
    if not PROD.search(cmd):
        return False
    # NON-MIGRATE prod signals win FIRST — a compound like
    # `<cloud-deploy> && <local migrate>` (or ledger-side `<push> && <local
    # migrate>`) must stay PROD; the local exemption applies ONLY when the
    # migrate pattern is the SOLE prod signal present.
    if PROD.search(MIGRATE.sub("", cmd)):
        return True
    # EXACTLY-ONE-MIGRATE rule (mixed-migrate masking): fail closed on multiples.
    if len(MIGRATE.findall(cmd)) != 1:
        return True
    # PER-CLAUSE BINDING: the local URL must live in the SAME shell clause as the
    # migrate — an unrelated local URL elsewhere in the compound never exempts.
    # Split on ALL clause boundaries (alternation order: && before &, || before |).
    clauses = re.split(r"&&|\|\||;|\||&|\n|\r", cmd)
    migrate_clauses = [c for c in clauses if MIGRATE.search(c)]
    if len(migrate_clauses) != 1:
        return True
    if _all_urls_local(migrate_clauses[0]) and not PRODMARK.search(cmd):
        return False
    return True  # unknown/unparseable target = prod-risk


def project_slug(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd or ".", "rev-parse", "--git-common-dir"],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            p = r.stdout.strip()
            if not os.path.isabs(p):
                p = os.path.join(cwd or ".", p)
            slug = os.path.basename(os.path.dirname(os.path.abspath(p)))
            if slug:
                return slug
    except Exception:
        pass
    return os.path.basename(os.path.abspath(cwd or ".")) or "default"


def ledger_path(slug):
    os.makedirs(LEDGER_DIR, exist_ok=True)
    return os.path.join(LEDGER_DIR, slug + ".jsonl")


def kind_of(cmd):
    c = cmd.lower()
    if "git push" in c:
        return "push"
    if "gcloud run deploy" in c or "run services update" in c:
        return "deploy"
    if "builds submit" in c:
        return "build"
    if "alter role" in c:
        return "role"
    return "migrate"


def add_entry(slug, sid, kind, detail, cwd):
    e = {
        "ts": int(time.time()),
        "sid": (sid or "?")[:8],
        "kind": kind,
        "detail": (detail or "").replace("\n", " ").strip()[:200],
        "cwd": os.path.basename(os.path.abspath(cwd or ".")),
    }
    try:
        with open(ledger_path(slug), "a") as f:
            f.write(json.dumps(e) + "\n")
    except Exception:
        pass


def recent(slug, n):
    try:
        with open(ledger_path(slug)) as f:
            lines = f.read().splitlines()
        return [json.loads(x) for x in lines[-n:] if x.strip()]
    except Exception:
        return []


def ago(ts):
    a = max(0, int(time.time()) - int(ts))
    if a < 60:
        return "just now"
    if a < 3600:
        return f"{a // 60}m ago"
    if a < 86400:
        return f"{a // 3600}h{(a % 3600) // 60:02d}m ago"
    return f"{a // 86400}d ago"


def render(entries):
    if not entries:
        return ""
    out = []
    for e in entries:
        out.append(f"  [{ago(e.get('ts', 0))}] ({e.get('sid', '?')}/{e.get('cwd', '')}) "
                   f"{e.get('kind', '')}: {e.get('detail', '')}")
    return "\n".join(out)


def best_effort_sha(cwd, cmd):
    # For a push, capture what HEAD points at so the line says what's live.
    if "git push" not in cmd.lower():
        return ""
    try:
        r = subprocess.run(["git", "-C", cwd or ".", "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            return " @" + r.stdout.strip()
    except Exception:
        pass
    return ""


def main():
    args = sys.argv[1:]
    sub = args[0] if args else "show"

    # --- CLI: show ---
    if sub == "show":
        n = int(args[1]) if len(args) > 1 and args[1].isdigit() else 15
        slug = project_slug(os.getcwd())
        body = render(recent(slug, n))
        if body:
            print(f"Prod ledger — {slug} (last {n}):\n{body}")
        else:
            print(f"Prod ledger — {slug}: (empty)")
        return

    # --- CLI: add <kind> <detail...> ---
    if sub == "add" and len(args) >= 3:
        slug = project_slug(os.getcwd())
        add_entry(slug, os.environ.get("CLAUDE_SESSION_ID", "manual"), args[1], " ".join(args[2:]), os.getcwd())
        print("recorded.")
        return

    # --- HOOK: record (PostToolUse) ---
    if sub == "record":
        try:
            d = json.loads(sys.stdin.read() or "{}")
            if (d.get("tool_name") or "") != "Bash":
                return
            cmd = (d.get("tool_input") or {}).get("command", "") or ""
            if not cmd or not is_prod(cmd):
                return
            resp = d.get("tool_response") or {}
            # Skip clear failures / interruptions (fail-open: if unsure, record).
            if isinstance(resp, dict) and (resp.get("isError") or resp.get("interrupted")):
                return
            cwd = d.get("cwd") or os.getcwd()
            sid = d.get("session_id", "?")
            detail = cmd.replace("\n", " ").strip()[:160] + best_effort_sha(cwd, cmd)
            add_entry(project_slug(cwd), sid, kind_of(cmd), detail, cwd)
        except Exception:
            pass
        return

    # --- HOOK: inject (SessionStart) ---
    if sub == "inject":
        try:
            d = json.loads(sys.stdin.read() or "{}")
            cwd = d.get("cwd") or os.getcwd()
            ents = recent(project_slug(cwd), 8)
            if not ents:
                return
            ctx = ("PROD LEDGER (recent push/deploy/migrate by all agents on this repo — "
                   "know what's already live before you push; run `prod-ledger show` for more):\n"
                   + render(ents))
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "hookEventVersion": "SessionStart-v1",
                "additionalContext": ctx,
            }}))
        except Exception:
            pass
        return


try:
    main()
except SystemExit:
    raise
except Exception:
    pass
sys.exit(0)
