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


# --- Inert-data stripping (part of the shared, duplicated classifier) ---------
# The classifier reads the TEXT of a Bash command, so a dangerous phrase that is
# merely DATA - a commit message, a mission-bridge note, a heredoc body - used to
# be classified as PERFORMING the operation. Measured 2026-08-13: 11 of 1344
# prod-ledger entries were `mission-write.sh` bridge writes filed as push/migrate,
# and two sessions took ~/.claude/prod.lock for a note-write (one held it 2d17h,
# blocking every other agent's prod work until a human reconciled it).
#
# So quoted string literals and quoted/plain heredoc bodies are removed BEFORE
# classification: the shell never EXECUTES their contents. Fail-closed carve-outs
# leave the text INTACT (still scanned) when:
#   * an interpreter-style token is present, where a quoted string IS code
#     (`bash -c '...'`, `ssh host '...'`, `psql -c 'ALTER ROLE ...'`, `... | sh`,
#     `eval`, `xargs`, any `-c '` / `-e "` / `--command=`);
#   * the quoted run or heredoc body contains a command substitution (`$(` or a
#     backtick), which executes regardless of the quoting;
#   * the quoting/heredoc is unbalanced (no match => nothing is stripped).
# This does NOT lower the classifier's ceiling: text matching was always blind to
# indirection (write a script in one call, run it in the next), so the operations
# this can newly miss were already invisible to it.
# Alt-3 is NAME-AGNOSTIC and that is why it never regresses: no interpreter list, no gap walker,
# no path prefix - so an unnamed interpreter, a quoted executable name (`"/bin/bash" -c`) and a
# redirect before the flag (`bash 2>/tmp/err -c`) all stay caught. Four attempts to replace it with
# a closed name list each lost real executions it already covered. So the ONLY change is a
# SUBTRACTION: a search tool cannot trigger alt-3. `grep -niE "..."` - a SEARCH - held the
# machine-wide lock 4+ hours because IGNORECASE lets [ce] match the E.
# Spec + full measured record: tmp/ready-plans/2026-08-16-prod-classifier-residual-fix.md
#
# Three things here are load-bearing and each was learned by measurement, not reasoning:
#  * the blanks live INSIDE the lookahead. A standalone `[ \t]*` BACKTRACKS, so the guard gets
#    re-evaluated at a whitespace position where no denied name can match - which silently reduced
#    this to "only works when the tool name is the first byte of the command".
#  * the lookahead is PREFIX-AWARE, so a tool reached through sudo/git/env X=1//usr/bin//./ is seen.
#  * a BACKTICK and a `(` are in the anchor class AND excluded from the scan class. Either one in
#    the anchor class ALONE is QUADRATIC, because the scan must exclude what it anchors on.
#  * the name ends with (?=[ \t]|$), not \b: `\b` is satisfied by `=`, so `GREP=1 psql -c '...'`
#    would exempt its whole clause - a silent false negative shipped catches.
#
# A name is denied only when removing it is MEASURED to fix a real false positive, and a name whose
# own flags can EXECUTE another program is admitted only with that loss DECLARED:
#   grep/egrep/fgrep  no execution channel at all -> denying them cannot create a false negative.
#   rg/sed            have one (`rg --pre=CMD`, `sed -e '1e CMD'`, `s///e`) but each is measured to
#                     fix a real false positive -> kept, and the channel is GIVEN UP knowingly.
#                     Reversing that is one name in the alternation below.
#   ag/ack            have one (`--pager=CMD`) and fix nothing -> NOT denied.
#   awk               shells out via system() and takes program text via -e -> NOT denied.
INTERP = re.compile(
    r"(?:^|[\s|;&(])(?:eval|xargs|ssh)\b"
    r"|sh\s+-[a-z]*c\b"               # bash / zsh / dash / sh  -c, -lc, -ec
    r"|(?:^|[\n;|&(`])(?![ \t]*(?:(?:sudo|env|command|time|nohup|git)[ \t]+"
    r"|[A-Za-z_][A-Za-z0-9_]*=[^\s]*[ \t]+)*(?:[A-Za-z0-9_.~$-]*/)*"
    r"(?:grep|egrep|fgrep|rg|sed)(?=[ \t]|$))"
    r"[^\n;|&`(]*?\s-[a-z]*[ce]\s+['\"]"   # psql -c '...', python -c, node -e, sh -lc "..."
    r"|--(?:command|eval)="
    r"|\|\s*(?:ba|z|da|k)?sh\b",
    re.IGNORECASE,
)
SUBST = re.compile(r"\$\(|`")
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", re.S)
HEREDOC_OPEN = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def _strip_heredocs(cmd):
    out, pos = [], 0
    while True:
        m = HEREDOC_OPEN.search(cmd, pos)
        if not m:
            out.append(cmd[pos:])
            return "".join(out)
        nl = cmd.find("\n", m.end())
        if nl == -1:                                  # no body on this call
            out.append(cmd[pos:])
            return "".join(out)
        end = re.compile(r"^[ \t]*" + re.escape(m.group(2)) + r"[ \t]*$",
                         re.M).search(cmd, nl + 1)
        if not end:                                   # unterminated => fail closed
            out.append(cmd[pos:])
            return "".join(out)
        if SUBST.search(cmd[nl + 1:end.start()]):     # substitutions execute => keep
            out.append(cmd[pos:end.end()])
        else:
            # The `#` is the SPLICE GUARD. Deleting the body joins the opener line's tail directly
            # to the terminator tag, and `cat <<'SH' |` + `SH` matched branch 5 (`\|\s*sh\b`) in
            # the STRIPPED text while the ORIGINAL matched nothing - so stripping a note-write
            # CREATED a production verdict, the exact harm this stripping exists to remove.
            # `#` is monotone-SAFE: it is in no lead class, no anchor class and no literal of any
            # branch, so no branch can REQUIRE it - inserting it can only destroy a match, never
            # create one. It also leaves what remains reading as a shell comment.
            out.append(cmd[pos:nl + 1])
            out.append("#")
            out.append(cmd[end.start():end.end()])
        pos = end.end()


def _strip_inert_data(cmd):
    # ORDER MATTERS, and so does WHICH TEXT each half looks at. Decide the interpreter question on
    # the heredoc-STRIPPED text, so a body's PROSE cannot veto the stripping of its own container
    # (that is how a `cat > tmp/briefs/...` write was filed as a push and held the lock 2d17h).
    # When an interpreter fires, return the ORIGINAL so a body it may consume stays scannable
    # (`ssh box <<EOF ... EOF` really does run its body). Deliberately FAIL-CLOSED and deliberately
    # imprecise: in a multi-clause command the interpreter may live in a DIFFERENT clause from the
    # heredoc, so `ssh box 'true' && cat > notes.md <<EOF ... EOF` scans the note body and can file
    # a note-write as production. That is the safe direction, but it IS a false-positive source -
    # do not read this branch as proof that the interpreter owns the heredoc.
    stripped = _strip_heredocs(cmd)
    if INTERP.search(stripped):
        return cmd
    return QUOTED.sub(lambda m: m.group(0) if SUBST.search(m.group(0)) else " ", stripped)



# DB-connection env vars — a migrate's REAL target is whatever one of these points at.
CONN_VAR = re.compile(
    r"\b(?:[A-Z][A-Z0-9_]*_)?(?:DATABASE_URL|DB_URL|POSTGRES[A-Z0-9_]*|PG[A-Z0-9_]*|MIGRATOR[A-Z0-9_]*)"
    r"\s*=\s*(\S+)", re.I)


def _url_is_local(u):
    # Exact hostname equality only; parse failure = NOT local (prod-risk).
    from urllib.parse import urlparse
    try:
        host = (urlparse(u).hostname or "").lower()
    except ValueError:
        return False
    return host in ("localhost", "127.0.0.1", "postgres")


def _strip_comment(clause):
    # Drop an inline shell comment (` #...` to end of the clause): a postgres URL that appears
    # ONLY in a comment is a DECOY, never a real connection argument (codex-review CRITICAL 2026-07-12:
    # `DATABASE_URL=$PROD_URL <migrate> # postgresql://localhost/x` was wrongly exempted).
    return re.sub(r"(?:^|\s)#.*$", "", clause)


def _all_urls_local(cmd):
    urls = re.findall(r"postgres(?:ql)?://[^\s\"']+", cmd, re.I)
    if not urls:
        return False
    return all(_url_is_local(u) for u in urls)


def _migrate_target_provably_local(clause):
    # A migrate is exempt ONLY when its clause's connection target is PROVABLY local. Comments are
    # stripped first (decoy URLs don't count). Then BOTH must hold:
    #   (a) every remaining literal postgres URL is local AND there is >= 1 (no URL => unknown => prod),
    #   (b) every DB-connection env assignment resolves to a proven-local LITERAL — a var ref
    #       (`$PROD_URL`) or a non-local literal means the real target is not provably local => prod.
    c = _strip_comment(clause)
    if not _all_urls_local(c):
        return False
    for val in CONN_VAR.findall(c):
        val = val.strip().strip("'\"")
        if not (re.match(r"postgres(?:ql)?://", val, re.I) and _url_is_local(val)):
            return False
    return True


def is_prod(cmd):
    # Classify what the command RUNS, not every phrase it mentions.
    cmd = _strip_inert_data(cmd)
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
    if _migrate_target_provably_local(migrate_clauses[0]) and not PRODMARK.search(cmd):
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
    # Same inert-data rule as is_prod: a note whose TEXT says "git push" is not a push.
    c = _strip_inert_data(cmd).lower()
    if "git push" in c:
        return "push"
    if "gcloud run deploy" in c or "run services update" in c:
        return "deploy"
    if "builds submit" in c:
        return "build"
    if "alter role" in c:
        return "role"
    return "migrate"


# Credential shapes are REDACTED AT THIS CHOKEPOINT, before anything is written
# (2026-08-03). The ledger records the TEXT OF COMMANDS an agent ran, is world-readable by
# default, and is RE-INJECTED INTO EVERY SESSION at SessionStart - so anything captured here
# is both on disk for any local process and back in an LLM context on the next run.
#
# Measured on this machine before the fix: 119 connection strings with inline credentials in
# a single project's ledger. All of them were LOCAL docker test databases
# (postgres@localhost) - no production host, no API key - so nothing live was exposed. That
# is luck, not design: the recorder had no redaction at all, so a real DSN typed into one
# command would have been captured verbatim and replayed into context indefinitely.
#
# Redacting at the writer rather than scrubbing the file afterwards is the point: a scrub
# fixes today's rows, the chokepoint fixes every future one.
_REDACTIONS = [
    # scheme://user:password@host  ->  keep the shape, drop the credential
    (re.compile(r'\b([a-zA-Z][a-zA-Z0-9+.-]*://)([^:/@\s]+):([^@/\s]+)@'), r'\1\2:REDACTED@'),
    # provider-prefixed tokens: keep the prefix so the entry stays readable, drop the payload
    (re.compile(r'\b(sk-(?:ant|proj|svcacct)?-?|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|npm_|'
                r'AIza|ya29\.|whsec_|hf_|xox[abposr]-)[A-Za-z0-9_-]{16,}'), r'\1REDACTED'),
    (re.compile(r'\b(AKIA|ASIA)[0-9A-Z]{16}\b'), r'\1REDACTED'),
    (re.compile(r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'), 'JWT-REDACTED'),
    (re.compile(r'-----BEGIN[^-]*PRIVATE KEY-----'), 'PRIVATE-KEY-REDACTED'),
]


def redact(text):
    """Strip credential shapes from a string before it is persisted or re-injected."""
    if not text:
        return text
    for rx, repl in _REDACTIONS:
        text = rx.sub(repl, text)
    return text


def add_entry(slug, sid, kind, detail, cwd):
    e = {
        "ts": int(time.time()),
        "sid": (sid or "?")[:8],
        "kind": kind,
        "detail": redact((detail or "").replace("\n", " ").strip())[:200],
        "cwd": os.path.basename(os.path.abspath(cwd or ".")),
    }
    try:
        path = ledger_path(slug)
        # 0600 the ledger and 0700 its directory: it was world-readable (-rw-r--r--), so any
        # local process could read whatever had been captured before redaction existed.
        try:
            os.chmod(LEDGER_DIR, 0o700)
        except Exception:
            pass
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(e) + "\n").encode())
        finally:
            os.close(fd)
        try:
            os.chmod(path, 0o600)
        except Exception:
            pass
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
