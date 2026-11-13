"""pnpm workspaces, the repo policy and the run-local Postgres lane (2026-11-13, DAVID; review round 2).

  * Hook (_hooks_stage/rrun-route.py judge_pnpm), as a real subprocess on a DAVID-shaped fixture: only
    rd_pnpm.exact_form's shapes, on decoded words, are routed (review round 2's counterexamples stay here).
  * rd_pnpm: exact_form / strict bodies / no pre- or post- script; needs_pg follows the form, fail-closed.
  * Client (rd_run): the policy applies to every command of the repo (env vars, overlay, tracked env
    files); the header carries it; exit 79's class.
  * Runner (rr_runner.pl, fake npm / node / pnpm / docker): pnpm via corepack (lock waited on with the
    heartbeat pump; workspace inputs in the stamp); policy_env / policy_files on a plain command; the lane
    with every refusal BEFORE GO, the exact URL match, cleanup only by the container id after a label check.
"""
import fcntl
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
from rdmods import TEST_HOME  # noqa: E402
from test_hook import HookBase  # noqa: E402  (a base with helpers only, no tests of its own)
import test_runner as tr  # noqa: E402

import rd_common  # noqa: E402
import rd_pnpm  # noqa: E402
import rd_pool  # noqa: E402
import rd_run  # noqa: E402

LANE = rd_common.DEFAULTS["rr_pg_lanes"][0]


def pgurl(user, pw, rest):
    """A fake postgres URL, assembled at runtime so no source line holds a user:password@ pair (the
    dotfiles secret scanner, scripts/secret-scan.sh RX_CONN)."""
    return f"postgres://{user}:{pw}@{rest}"
CFG = {"rr_pg_lanes": [LANE]}
CID = "c" * 64


def wjson(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f)


def workspace(root, name="david"):
    """A DAVID-shaped pnpm workspace (git marker, lockfile, apps/web, packages/db, packages/ui,
    tests/hammer) with the shapes review round 2 used."""
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, ".git"))
    wjson(os.path.join(d, "package.json"), {"name": name, "packageManager": "pnpm@9.15.9", "scripts": {
        "typecheck": "pnpm -r typecheck", "test": "pnpm -r test",
        "test:hammer": "pnpm --filter @david/hammer test",
        "lint": "pnpm -r --filter @david/web lint", "dev": "pnpm --filter @david/web dev",
        "check:all": "echo checking && pnpm --filter @david/hammer test",
        "db:migrate": "pnpm --filter @david/db migrate", "db:provision": "pnpm --filter @david/db provision"}})
    with open(os.path.join(d, "pnpm-workspace.yaml"), "w") as f:
        f.write("# comment\npackages:\n  - 'packages/*'\n  - 'apps/*'\n  - 'tests/*'\n")
    with open(os.path.join(d, "pnpm-lock.yaml"), "w") as f:
        f.write("lockfileVersion: '9.0'\n")
    wjson(os.path.join(d, "apps/web/package.json"), {"name": "@david/web", "scripts": {
        "test": "vitest run", "typecheck": "tsc --noEmit", "lint": "eslint", "dev": "next dev",
        "build": "next build", "test:watch": "vitest", "test:db": "pnpm --filter @david/hammer test"}})
    wjson(os.path.join(d, "packages/ui/package.json"), {"name": "@david/ui", "scripts": {
        "lint": "pnpm build && eslint", "build": "vite build", "test": "vitest", "typecheck": "tsc --noEmit"}})
    wjson(os.path.join(d, "packages/db/package.json"), {"name": "@david/db", "scripts": {
        "migrate": "tsx src/migrate.ts", "provision": "tsx src/provision-app-login.ts", "typecheck": "tsc --noEmit"}})
    wjson(os.path.join(d, "tests/hammer/package.json"), {"name": "@david/hammer",
                                                          "scripts": {"test": "vitest run", "typecheck": "tsc --noEmit"},
                                                          "devDependencies": {"@david/db": "workspace:*"}})
    os.makedirs(os.path.join(d, "tests/hammer/src"))
    return d


# ---------------------------------------------------------------------------- hook

ROUTED = [   # (cwd relative to the workspace, command, rewrite): rd_pnpm.exact_form's shapes only
    ("apps/web", "pnpm typecheck", "rrun pnpm typecheck"),
    ("", "pnpm --filter @david/web test", "rrun pnpm --filter @david/web test"),
    ("", "pnpm -F @david/web typecheck", "rrun pnpm -F @david/web typecheck"),
    ("", "pnpm --filter=@david/hammer typecheck", "rrun pnpm --filter=@david/hammer typecheck"),
    ("", "pnpm --filter @david/hammer test src/a.test.ts", "rrun pnpm --filter @david/hammer test src/a.test.ts"),
    ("", "pnpm --filter hammer test", "rrun pnpm --filter hammer test"),              # unique unscoped name
    ("", "pnpm --filter @david/hammer exec vitest run src/guard.test.ts -t refuses",
     "rrun pnpm --filter @david/hammer exec vitest run src/guard.test.ts -t refuses"),
    ("", "pnpm --filter @david/hammer exec vitest run --reporter=dot", "rrun pnpm --filter @david/hammer exec vitest run --reporter=dot"),
    ("", "cd tests/hammer && npx vitest run src/a.test.ts", "cd tests/hammer && rrun npx vitest run src/a.test.ts"),
    ("", "cd tests/hammer && vitest run src/a.test.ts", "cd tests/hammer && rrun pnpm exec vitest run src/a.test.ts"),
    ("tests/hammer", "pnpm exec vitest run src/a.test.ts", "rrun pnpm exec vitest run src/a.test.ts"),
    ("tests/hammer", "vitest run", "rrun pnpm exec vitest run"),
]
STAYS = [    # (cwd, command)
    ("", "pnpm dev"), ("", "pnpm install"), ("", "pnpm add -D vitest"), ("", "pnpm db:migrate"), ("", "pnpm build"),
    ("", "pnpm --filter @david/web build"), ("", "pnpm --filter @david/web test:watch"),
    ("", "pnpm --filter @david/web exec vitest"), ("", "pnpm --filter @david/web exec vitest run --coverage"),
    ("", "pnpm --filter @david/web test -u"), ("", "pnpm --filter @david/web test -- -u"),
    ("", "pnpm --filter @david/web test -- src/a.test.ts"), ("", "pnpm --filter @david/web exec tsc"),
    ("", "pnpm --filter '[origin/main]' test"), ("", "pnpm --filter '@david/*' test"), ("", "pnpm --filter ./apps/web test"),
    ("", "pnpm --filter @david/nope test"), ("tests/hammer", "vitest"), ("tests/hammer", "vitest run --watch"),
    ("", "pnpm --unknown-flag test"), ("", "RRUN=0 pnpm -r typecheck"), ("", "FOO=1 pnpm --filter @david/web test"),
    ("", "timeout 600 pnpm -r typecheck"),
    # shapes no longer routed: root scripts, lint, npm in a workspace, -r test, root exec
    ("", "pnpm typecheck"), ("", "pnpm test:hammer"), ("", "pnpm lint"), ("", "pnpm -r test"), ("", "pnpm test"),
    ("tests/hammer", "npm test"), ("tests/hammer", "pnpm test"), ("", "pnpm exec vitest run tests/hammer/src/a.test.ts"),
    # review round 2 counterexamples
    ("tests/hammer", "pnpm test '--update'"), ("tests/hammer", "pnpm exec vitest run '--watch'"),
    ("tests/hammer", 'npx vitest run "--update"'), ("tests/hammer", "vitest run \\--watch"),
    ("", "pnpm --filter @david/fwd test"),         # test = pnpm test:base --update (args through an expansion)
    ("", "pnpm --filter @david/pre test"),         # pretest = pnpm build (a lifecycle script)
    ("", "pnpm --filter @david/pre typecheck"),    # pretypecheck runs too
    ("", "pnpm -r --include-workspace-root typecheck"), ("", "pnpm --filter @david/env test"),   # body assigns
    ("", "pnpm --filter @david/ui lint"), ("", "pnpm --filter @david/ui test"), ("", "pnpm check:all"),
    ("tests/hammer", "npm test -u"), ("tests/hammer", "npm test -- -w"),
    ("", "pnpm --filter @david/hammer exec vitest run src/a.test.ts -t 'two words'"),   # any quoting: local
    ("", "pnpm -r typecheck"),                     # packages/pre has pretypecheck: not proven
    # final review: an in-word `#` must not hide the rest of the line from the veto
    ("tests/hammer", "npx vitest run -t case#tag --update"), ("tests/hammer", "vitest run -t case#tag -u"),
    ("", "pnpm --filter @david/hammer exec vitest run -t case#tag --update"),
    ("", "pnpm --filter @david/hammer test src/a#b.test.ts --watch"),
]


def review_packages(ws):
    """Packages shaped like review round 2's counterexamples."""
    wjson(os.path.join(ws, "packages/fwd/package.json"), {"name": "@david/fwd", "scripts": {
        "test": "pnpm test:base --update", "test:base": "vitest run"}})
    wjson(os.path.join(ws, "packages/pre/package.json"), {"name": "@david/pre", "scripts": {
        "test": "vitest run", "pretest": "pnpm build", "typecheck": "tsc --noEmit", "pretypecheck": "node db.mjs"}})
    wjson(os.path.join(ws, "packages/env/package.json"), {"name": "@david/env", "scripts": {
        "test": "DATABASE_URL=" + pgurl("owner", "secret", "remote/db") + " vitest run"}})


class PnpmHook(HookBase):
    def setUp(self):
        super().setUp()
        self.ws = workspace(self.home)
        review_packages(self.ws)

    def at(self, rel, command):
        out = self.hook(dict(self.bash(command), cwd=os.path.join(self.ws, rel)))
        return out and out["hookSpecificOutput"]["updatedInput"]["command"]

    def test_routed(self):
        for rel, cmd, want in ROUTED:
            with self.subTest(cwd=rel, cmd=cmd):
                self.assertEqual(self.at(rel, cmd), want)

    def test_stays_here(self):
        for rel, cmd in STAYS:
            with self.subTest(cwd=rel, cmd=cmd):
                self.assertIsNone(self.at(rel, cmd))

    def test_recursive_typecheck_routes_when_every_package_is_strict(self):
        shutil.rmtree(os.path.join(self.ws, "packages/pre"))
        self.assertEqual(self.at("", "pnpm -r typecheck"), "rrun pnpm -r typecheck")
        self.assertEqual(self.at("", "pnpm --recursive typecheck 2>&1 | tail -20"),
                         "rrun pnpm --recursive typecheck 2>&1 | tail -20")

    def test_npm_projects_unchanged(self):
        """pnpm in an npm project, and a bare tool there, still stay here (no pnpm lockfile)."""
        for cmd in ("pnpm test", "pnpm -r typecheck", "vitest run src/a.test.ts"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.rewritten(cmd))

    def test_npm_path_judges_decoded_words_too(self):
        """Review round 2 finding 3 in the npm path: a quoted veto flag is the flag."""
        for cmd in ("npx vitest run '--watch'", 'npx vitest run "-u"', "npx eslint . '--fix'",
                    "npx vitest run -t case#tag --update", "npx vitest run a#b -u"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.rewritten(cmd))
        self.assertEqual(self.rewritten("npx vitest run 'src/a b.test.ts'"), "rrun npx vitest run 'src/a b.test.ts'")


# ---------------------------------------------------------------------------- rd_pnpm

class Forms(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="pn-", dir=TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        self.ws = workspace(self.d)
        review_packages(self.ws)

    def form(self, cmd, rel=""):
        return rd_pnpm.exact_form(os.path.join(self.ws, rel), shlex.split(cmd), self.ws)

    def pg(self, cmd, rel=""):
        return rd_pnpm.needs_pg(self.ws, os.path.join(self.ws, rel), shlex.split(cmd))

    def test_the_shapes(self):
        self.assertEqual(self.form("pnpm --filter @david/hammer test"), ("vitest", ["tests/hammer"]))
        self.assertEqual(self.form("pnpm --filter @david/hammer exec vitest run src/a.test.ts --testNamePattern=x"),
                         ("vitest", ["tests/hammer"]))
        self.assertEqual(self.form("vitest run src/a.test.ts", "tests/hammer"), ("vitest", ["tests/hammer"]))
        self.assertEqual(self.form("pnpm typecheck", "apps/web"), ("tsc", ["apps/web"]))
        for cmd in ("pnpm --filter @david/hammer test --", "pnpm --filter @david/hammer test -u",
                    "pnpm --filter @david/hammer test --watch", "pnpm --filter @david/hammer test FOO=1",
                    "pnpm --filter @david/fwd test", "pnpm --filter @david/pre test", "pnpm --filter @david/env test",
                    "pnpm -r --include-workspace-root typecheck", "pnpm exec vitest run x"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.form(cmd))

    def test_recursive_typecheck_needs_every_body_strict(self):
        """`pnpm -r typecheck` reaches packages/pre, whose pretypecheck runs too: not a proven tsc form."""
        self.assertIsNone(self.form("pnpm -r typecheck"))
        self.assertTrue(self.pg("pnpm -r typecheck"))
        shutil.rmtree(os.path.join(self.ws, "packages/pre"))
        self.assertEqual(self.form("pnpm -r typecheck")[0], "tsc")
        self.assertFalse(self.pg("pnpm -r typecheck"))

    def test_lane_follows_the_form(self):
        for rel, cmd in (("", "pnpm --filter @david/hammer test"), ("", "pnpm --filter @david/web test"),
                         ("tests/hammer", "vitest run"), ("tests/hammer", "npx vitest run src/a.test.ts"),
                         ("", "pnpm --filter @david/pre typecheck"),          # pretypecheck: not proven -> Postgres
                         ("", "pnpm lint"), ("", "node scripts/x.mjs"), ("", "pnpm test:hammer")):
            with self.subTest(cwd=rel, cmd=cmd):
                self.assertTrue(self.pg(cmd, rel))
        for rel, cmd in (("apps/web", "pnpm typecheck"), ("", "pnpm --filter @david/hammer typecheck")):
            with self.subTest(cwd=rel, cmd=cmd):
                self.assertFalse(self.pg(cmd, rel))

    def test_policy_is_the_worktree_top_not_the_cwd(self):
        with open(os.path.join(self.ws, "tests/hammer/package-lock.json"), "w") as f:
            f.write("{}")                                     # a nested npm lockfile changes nothing
        self.assertIs(rd_pnpm.repo_policy(CFG, self.ws), LANE)
        self.assertIsNone(rd_pnpm.repo_policy(CFG, workspace(self.d, "other")))
        for p, want in ((".env", True), ("a/b/.env.local", True), (".envrc", True), (".env.example", False),
                        ("x/.env.sample", False), (".env.template", False), ("env", False), ("a.env", False)):
            self.assertEqual(rd_pnpm.is_env_file(p), want, p)


# ---------------------------------------------------------------------------- client

class Client(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="pnc-", dir=TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)

    def git(self, ws, *args):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + list(args),
                       cwd=ws, env=rdmods.child_env(self.d), check=True, capture_output=True)

    def git_ws(self, name="david", tracked_env=False):
        ws = workspace(self.d, name)
        shutil.rmtree(os.path.join(ws, ".git"))
        with open(os.path.join(ws, ".gitignore"), "w") as f:
            f.write("node_modules/\n.env\n.env.local\n")
        for n, body in ((".env", "DATABASE_URL=" + pgurl("owner", "REAL", "ep-x.neon.tech/neondb") + "\n"),
                        (".env.local", "X=1\n"), (".env.example", "DATABASE_URL=\n")):
            with open(os.path.join(ws, n), "w") as f:
                f.write(body)
        if tracked_env:
            with open(os.path.join(ws, "tests/hammer/.env.test"), "w") as f:
                f.write("A=1\n")
        self.git(ws, "init", "-q")
        self.git(ws, "add", "-A")
        self.git(ws, "commit", "-qm", "i")
        # untracked, NOT ignored: the ordinary overlay would carry these (review finding 1)
        for n in ("apps/web/.env.staging", ".env.extra"):
            with open(os.path.join(ws, n), "w") as f:
                f.write("SECRET=REAL\n")
        with open(os.path.join(ws, ".env.example"), "a") as f:
            f.write("# changed\n")
        return ws

    def test_default_spec(self):
        self.assertEqual((LANE["image"], LANE["user"], LANE["password"], LANE["db"], LANE["app_role"],
                          LANE["app_url_env"]),
                         ("postgres:16-alpine", "david", "david", "postgres", "david_app_login", "DATABASE_URL_APP"))
        self.assertEqual(LANE["setup"], [["pnpm", "db:migrate"], ["pnpm", "db:provision"]])
        self.assertEqual(LANE["env"], {"MESSAGING_TRANSPORT": "echo", "CALL_TRANSPORT": "echo"})
        for g in ("TWILIO_*", "RETELL_*", "OPENROUTER_*", "SEED_ALLOW_REMOTE", "HAMMER_ALLOW_REMOTE_DB"):
            self.assertIn(g, LANE["strip_env"])

    def test_policy_on_every_command_and_lane_only_for_tests(self):
        ws = self.git_ws()
        wt = rd_run.resolve_worktree(ws)
        job, wt2 = rd_run.classify_job(CFG, wt, ["pnpm", "--filter", "@david/hammer", "test"], [], ws)
        self.assertEqual((job["cls"], job["db"], job["never_local"], job["retry_ok"]), ("db", True, True, False))
        self.assertIs(job["pg"], LANE)
        self.assertIs(wt2["policy"], LANE)
        self.assertNotIn("policy", wt)                            # the caller's dict is not changed
        self.assertEqual(rd_run.rd_cache.why_not_static(["pnpm"], job, [], {}), "a DB job")
        job, wt3 = rd_run.classify_job(CFG, wt, ["pnpm", "-r", "typecheck"], [], ws)
        self.assertNotIn("pg", job)
        self.assertEqual(job["cls"], "heavy")
        self.assertIs(wt3["policy"], LANE)                        # the policy holds for typecheck too
        job, _ = rd_run.classify_job(CFG, wt, ["pnpm", "exec", "vitest", "run", "tests/hammer/src/a.test.ts"], [], ws)
        self.assertIs(job["pg"], LANE)

    def test_no_env_file_ships_from_a_policy_repo(self):
        ws = self.git_ws()
        cfg = dict(CFG, rr_env_allow=[".env", ".env.local", ".env.*"])
        _tar, files, envs, _deleted = rd_run.build_overlay(cfg, ws, ["", "apps/web"])
        self.assertEqual(envs, [])
        self.assertEqual(sorted(f for f in files if ".env" in f), [".env.example"])    # a template may ship
        # sanity: the same repo without the policy would have shipped them (the test sees a leak)
        _tar, files, envs, _deleted = rd_run.build_overlay({"rr_env_allow": [".env"]}, ws, [""])
        self.assertEqual(envs, [".env"])
        self.assertIn("apps/web/.env.staging", files)

    def push_to(self, ws, bare):
        """rd_run.push (the one push rrun AND rd_warm use) into a local bare repo."""
        subprocess.run(["git", "init", "-q", "--bare", bare], check=True, capture_output=True)
        os.environ["RRUN_GIT_URL"] = bare
        self.addCleanup(os.environ.pop, "RRUN_GIT_URL", None)
        # a local push URL runs --receive-pack's `mkdir -p ~/rr/git` HERE: never the real HOME
        real_home = os.environ.get("HOME")
        os.environ["HOME"] = self.d
        self.addCleanup(os.environ.__setitem__, "HOME", real_home)
        cfg = dict(CFG, host="x", rr_base_branches=["main"])
        return rd_run.push(cfg, rd_run.resolve_worktree(ws))

    def refs(self, bare):
        return subprocess.run(["git", "-C", bare, "for-each-ref"], capture_output=True, text=True).stdout

    def test_the_push_refuses_a_tracked_env_file_index_head_or_base(self):
        import rd_warm
        self.assertIs(rd_warm.rd_run.push, rd_run.push)          # the warmer goes through the same guard
        ws = self.git_ws(tracked_env=True)
        bare = os.path.join(self.d, "b1.git")
        with self.assertRaises(rd_run.PolicyRefused) as e:
            self.push_to(ws, bare)
        self.assertIn("tests/hammer/.env.test", str(e.exception))
        self.assertEqual(self.refs(bare), "")                     # nothing reached the worker
        # review round 2: `git rm --cached` cleans the index but HEAD still has it
        self.git(ws, "rm", "-q", "--cached", "tests/hammer/.env.test")
        with self.assertRaises(rd_run.PolicyRefused) as e:
            self.push_to(ws, os.path.join(self.d, "b2.git"))
        self.assertIn("tests/hammer/.env.test", str(e.exception))
        # committed away: HEAD is clean, but a pushed base ref (origin/main) still has it
        self.git(ws, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.git(ws, "commit", "-qm", "untrack")
        with self.assertRaises(rd_run.PolicyRefused) as e:
            self.push_to(ws, os.path.join(self.d, "b3.git"))
        self.assertIn(rd_run.git_out(["rev-parse", "refs/remotes/origin/main"], ws).decode()[:12], str(e.exception))
        self.git(ws, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.assertEqual(self.push_to(ws, os.path.join(self.d, "b4.git"))[0][-len("refs/remotes/origin/main"):],
                         "refs/remotes/origin/main")              # clean everywhere: it ships

    def test_a_template_and_another_repo_push_as_before(self):
        self.push_to(self.git_ws("david2"), os.path.join(self.d, "t1.git"))    # .env.example only: fine
        ws = self.git_ws("other", tracked_env=True)
        self.push_to(ws, os.path.join(self.d, "t2.git"))                       # no policy: unchanged

    def test_argv_assignments_of_stripped_names_refuse(self):
        ws = self.git_ws()
        wt = rd_run.resolve_worktree(ws)
        for argv in (["env", "DATABASE_URL=" + pgurl("o", "REAL", "ep-x/n"), "node", "x.mjs"],
                     ["env", "TWILIO_AUTH_TOKEN=REAL", "pnpm", "test"], ["node", "PG_HOST=x"],
                     ["pnpm", "exec", "vitest", "run", "HUB_TEST_DATABASE_URL=x"], ["x", "SEED_ALLOW_REMOTE=1"],
                     ["x", "RETELL_API_KEY=k"], ["x", "OPENROUTER_API_KEY=k"], ["x", "PGPASSWORD=p"]):
            with self.subTest(argv=argv):
                rc = rd_run.argv_refusal(CFG, wt, argv)
                self.assertEqual((int(rc), rc.klass), (65, "needs-human"))
                self.assertNotIn("REAL", rc.why)
        # final review: an assignment INSIDE a token (env -S, sh -c), and any env option, refuse too
        for argv in (["env", "-S", "FOO=1 DATABASE_URL=" + pgurl("o", "REAL", "ep-x/n") + " pnpm test"],
                     ["env", "-S", "TWILIO_AUTH_TOKEN=REAL pnpm test"], ["sh", "-c", "TWILIO_AUTH_TOKEN=REAL node x"],
                     ["node", "x.mjs", "--set='PGHOST=ep-x'"], ["env", "-i", "node", "x.mjs"],
                     ["env", "--split-string=FOO=1 node", "x"], ["env", "-u", "HOME", "node"]):
            with self.subTest(argv=argv):
                rc = rd_run.argv_refusal(CFG, wt, argv)
                self.assertEqual((int(rc), rc.klass), (65, "needs-human"))
                self.assertNotIn("REAL", rc.why)
        self.assertIsNone(rd_run.argv_refusal(CFG, wt, ["env", "FOO=1", "VITEST_X=2", "pnpm", "test"]))
        self.assertIsNone(rd_run.argv_refusal(CFG, wt, ["node", "x.mjs", "--db-url=local", "MYDATABASE=1"]))
        self.assertIsNone(rd_run.argv_refusal(CFG, rd_run.resolve_worktree(self.git_ws("other")),
                                              ["env", "DATABASE_URL=x", "node"]))

    def test_logged_argv_has_no_url_userinfo(self):
        s = rd_run.short_argv(["node", "x.mjs", "--db=" + pgurl("owner", "REAL", "ep-x.neon.tech/n"), "https://u:p@h/x"])
        self.assertNotIn("REAL", s)
        self.assertNotIn("u:p@", s)
        self.assertIn("postgres://****@ep-x.neon.tech/n", s)

    def test_db_urls_and_provider_secrets_never_leave(self):
        ws = self.git_ws()
        env = {"DATABASE_URL": pgurl("o", "REAL", "ep-x.neon.tech/n"), "TEST_DB_URL": "x",
               "DATABASE_URL_APP": "y", "PGHOST": "ep-x", "PG_HOST": "ep-x", "TWILIO_AUTH_TOKEN": "REAL",
               "OPENROUTER_API_KEY": "R", "SEED_ALLOW_REMOTE": "1", "KEEP": "k"}
        cfg = dict(CFG, rr_env_pass=[])
        import io
        from contextlib import redirect_stderr
        err = io.StringIO()
        with redirect_stderr(err):
            got = rd_run.ship_env(cfg, env, ws)
        self.assertEqual(got, {"TEST_DB_URL": "x", "KEEP": "k"})
        self.assertNotIn("REAL", err.getvalue())
        self.assertIn("DATABASE_URL, DATABASE_URL_APP, OPENROUTER_API_KEY, PGHOST, PG_HOST, SEED_ALLOW_REMOTE, "
                      "TWILIO_AUTH_TOKEN", err.getvalue())
        self.assertEqual(rd_run.ship_env(cfg, env, self.git_ws("other")), env)    # no policy: unchanged

    def test_header_carries_the_policy_also_for_a_warm_prepare(self):
        ws = self.git_ws()
        wt = rd_run.resolve_worktree(os.path.join(ws, "tests/hammer"))
        self.assertEqual(rd_run.deps_dirs(wt["top"], wt["relcwd"], ["npx", "vitest", "run"]), [""])

        class H:
            cfg, entry = dict(rd_common.DEFAULTS, host="x"), None
        job, wt2 = rd_run.classify_job(H.cfg, wt, ["npx", "vitest", "run"], [], os.path.join(ws, "tests/hammer"))
        header = json.loads(rd_run.runner_frames(H, wt2, ["npx", "vitest", "run"], {}, [""], b"", [], [], job, False)[0][3])
        self.assertEqual((header["repo_policy"], header["pg_lane"]), (LANE, True))
        # rd_warm builds its own wt (no "policy" key) and a prepare-only job: the policy still goes
        header = json.loads(rd_run.runner_frames(H, wt, ["true"], {}, [""], b"", [], [], rd_pool.classify(["true"]),
                                                 False)[0][3])
        self.assertEqual(header["repo_policy"], LANE)
        self.assertNotIn("pg_lane", header)
        self.assertEqual(len(rd_pool.deps_shas(ws, [""])), 1)    # the probe sees the pnpm lockfile

    def test_exit_79_is_a_code_failure(self):
        rc = rd_run.Rc(79)
        self.assertEqual(rc.klass, "fail")
        self.assertIn(79, rd_run.rd_cache.INFRA_RC)              # never cached


# ---------------------------------------------------------------------------- runner

FAKE_NPM = r"""#!/bin/sh
printf '%%s\n' "npm $*" >> '%(log)s'
[ "$1" = install ] && [ "$2" = --prefix ] && { [ -f '%(dir)s/corepack-fail' ] && { echo "npm ERR! 404" >&2; exit 1; }
  mkdir -p "$3/node_modules/corepack/dist" && : > "$3/node_modules/corepack/dist/corepack.js"; }
exit 0
"""
FAKE_NODE = r"""#!/bin/sh
printf '%%s\n' "node $*" >> '%(log)s'
[ "$1" = -v ] && { echo v20.0.0; exit 0; }
[ "$2" = enable ] && { mkdir -p "$4" && cp '%(dir)s/pnpm.tmpl' "$4/pnpm" && chmod 755 "$4/pnpm"; }
exit 0
"""
FAKE_PNPM = r"""#!/bin/sh
APW=s3cr3tS3cr3tS3cr3t DPW=david                 # fixture passwords (as variables: the secret scanner)
printf '%%s\n' "pnpm $* | autopin=${COREPACK_ENABLE_AUTO_PIN-} prompt=${COREPACK_ENABLE_DOWNLOAD_PROMPT-} db=${DATABASE_URL:+set} gh=${GITHUB_ENV:+set} pwd=$(pwd)" >> '%(log)s'
P=$(printf %%s "$DATABASE_URL" | sed 's#.*127.0.0.1:\([0-9]*\)/.*#\1#')
case "$1" in
  install) [ -f '%(dir)s/pnpm-install-fail' ] && { echo "ERR_PNPM_OUTDATED_LOCKFILE boom" >&2; exit 1; }
           mkdir -p node_modules ;;
  db:migrate) [ -f '%(dir)s/migrate-fail' ] && { echo "migration 0042 failed on postgres://david:${DPW}@127.0.0.1:$P/postgres" >&2; exit 4; }
              echo "Applied 3 migration(s)" ;;
  db:provision)
    [ -f '%(dir)s/provision-skip' ] && exit 0
    u="postgres://david_app_login:${APW}@127.0.0.1:$P/postgres"
    [ -f '%(dir)s/provision-remote' ] && u="postgres://david_app_login:${APW}@ep-x.neon.tech/neondb"
    [ -f '%(dir)s/provision-query' ] && u="$u?%%68ost=db.example.com"
    [ -f '%(dir)s/provision-port' ] && u="postgres://david_app_login:${APW}@127.0.0.1:5432/postgres"
    echo "DATABASE_URL_APP=$u" >> "$GITHUB_ENV"
    echo "Provisioned david_app_login -> appended DATABASE_URL_APP=$u to \$GITHUB_ENV" ;;
esac
exit 0
"""
FAKE_DOCKER = r"""#!/bin/sh
printf '%%s\n' "docker $*" >> '%(log)s'
case "$1" in
  run) [ -f '%(dir)s/pg-run-fail' ] && { echo "Error response from daemon: pull access denied" >&2; exit 125; }
       prev=""
       for a in "$@"; do
         [ "$prev" = --cidfile ] && printf '%%s\n' '%(cid)s' > "$a"
         [ "$prev" = --label ] && case "$a" in rdocker.rrun=*) printf '%%s' "${a#rdocker.rrun=}" > '%(dir)s/pg.label' ;; esac
         prev="$a"
       done
       echo '%(cid)s' ;;
  exec) exit 0 ;;
  port) echo "127.0.0.1:$(cat '%(dir)s/pg.port.fake')" ;;
  inspect) [ -f '%(dir)s/pg-inspect-other' ] && { echo ffffffffffffffffffffffffffffffff; exit 0; }
           cat '%(dir)s/pg.label'; echo ;;
  rm) [ -f '%(dir)s/pg-rm-fail' ] && { echo "Error: removal in progress" >&2; exit 1; } ;;
esac
exit 0
"""
SHOW = ('echo "U=${DATABASE_URL-unset}|A=${DATABASE_URL_APP-unset}|M=$MESSAGING_TRANSPORT|C=$CALL_TRANSPORT'
        '|T=${TWILIO_AUTH_TOKEN-unset}|S=${SEED_ALLOW_REMOTE-unset}|P=${PGHOST-unset}|O=${OPENROUTER_API_KEY-unset}'
        '|R=${RETELL_API_KEY-unset}|G=${GITHUB_ENV-unset}|H=${HUB_TEST_DATABASE_URL-unset}|K=$KEEP'
        '|Q=${PG_HOST-unset}"; exit ${RC:-0}')
SECRETS = {"TWILIO_AUTH_TOKEN": "tw-REAL", "SEED_ALLOW_REMOTE": "1", "PGHOST": "ep-x.neon.tech",
           "OPENROUTER_API_KEY": "or-REAL", "RETELL_API_KEY": "re-REAL", "KEEP": "k",
           "DATABASE_URL": pgurl("o", "REAL", "ep-x.neon.tech/neondb"), "PG_HOST": "ep-x.neon.tech",
           "HUB_TEST_DATABASE_URL": pgurl("david", "david", "127.0.0.1:5432/postgres")}


class PnpmRunner(unittest.TestCase):
    """rr_runner.pl on a pnpm repo, with test_runner's harness (fed exactly like the laptop)."""
    run_runner, env, git, calls, header = (tr.RunnerTest.run_runner, tr.RunnerTest.env, tr.RunnerTest.git,
                                           tr.RunnerTest.calls, tr.RunnerTest.header)

    def setUp(self):
        tr.RunnerTest.setUp(self)
        self.addCleanup(shutil.rmtree, self.d, True)
        v = {"log": self.log, "dir": self.d, "cid": CID}
        for name, body in (("npm", FAKE_NPM), ("node", FAKE_NODE), ("docker", FAKE_DOCKER)):
            tr.wfile(os.path.join(self.bin, name), body % v)
            os.chmod(os.path.join(self.bin, name), 0o755)
        tr.wfile(os.path.join(self.d, "pnpm.tmpl"), FAKE_PNPM % v)
        # the repo becomes a pnpm workspace (no npm lockfile, no prisma)
        self.git("-C", self.src, "rm", "-q", "package-lock.json", "prisma/schema.prisma")
        tr.wfile(os.path.join(self.src, "package.json"), json.dumps({"name": "david", "packageManager": "pnpm@9.15.9"}))
        tr.wfile(os.path.join(self.src, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")
        tr.wfile(os.path.join(self.src, "pnpm-workspace.yaml"), "packages:\n  - 'tests/*'\n")
        os.makedirs(os.path.join(self.src, "tests", "hammer"))
        tr.wfile(os.path.join(self.src, "tests", "hammer", "package.json"), json.dumps({"name": "@david/hammer"}))
        self.commit("pnpm")
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.addCleanup(self.sock.close)
        self.port = self.sock.getsockname()[1]
        tr.wfile(os.path.join(self.d, "pg.port.fake"), str(self.port))

    def tearDown(self):
        pass

    def commit(self, msg):
        self.git("-C", self.src, "add", "-A")
        self.git("-C", self.src, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg)
        self.sha = self.git("-C", self.src, "rev-parse", "HEAD").strip()
        self.git("-C", self.src, "push", "-q", "-f", os.path.join(self.root, "git", tr.SLUG + ".git"), "HEAD:refs/heads/x")

    def flag(self, name):
        open(os.path.join(self.d, name), "w").close()

    def policy(self, argv=None, lane=True, **kw):
        extra = {"pg_lane": True} if lane else {}
        return self.run_runner(argv or ["/bin/sh", "-c", SHOW], repo_policy=dict(LANE), job_cls="db", **extra, **kw)

    def runs_log(self):
        with open(os.path.join(self.root, "log", "runs.log")) as f:
            return f.read().splitlines()

    def docker_rm_calls(self):
        return [c for c in self.calls() if c.startswith("docker rm")]

    # -------------------------------------------------------------------------- pnpm install
    def test_pnpm_via_corepack_once_then_warm(self):
        r = self.run_runner(["/bin/sh", "-c", "command -v pnpm; echo pin=$COREPACK_ENABLE_AUTO_PIN"])
        self.assertEqual(r.rc, 0, r.err)
        tools = os.path.join(self.root, "tools")
        self.assertEqual(r.out.splitlines(), [os.path.join(tools, "bin", "pnpm"), "pin=0"])
        self.assertIn("rrun: pnpm@9.15.9 install --frozen-lockfile", r.err)
        calls = self.calls()
        setup = lambda cs: [c for c in cs if c.startswith(("npm install", "pnpm install")) or " -g pnpm@" in c   # noqa: E731
                            or " enable " in c]
        first = setup(calls)
        self.assertEqual(len([c for c in first if c.startswith("npm install --prefix")]), 1)
        self.assertEqual(len([c for c in first if c.startswith("pnpm install")]), 1)
        self.assertIn("--frozen-lockfile --store-dir=%s/pnpm-store" % self.root, [c for c in first if c.startswith("pnpm install")][0])
        with open(os.path.join(self.mirror, "node_modules", ".rr-deps-stamp")) as f:
            stamp = f.read()
        self.assertTrue(stamp.startswith(rd_pool.deps_shas(self.src, [""])[0][1] + " "), stamp)   # the probe's digest
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        self.assertEqual(setup(self.calls()), first)              # warm: nothing installed again
        log = self.runs_log()
        self.assertIn("setup=cold", log[0])
        self.assertIn("setup=warm", log[1])
        # review note 12: a workspace package.json / a patch / .pnpmfile.cjs change is a new stamp
        for path, body in (("tests/hammer/package.json", json.dumps({"name": "@david/hammer", "version": "2"})),
                           ("patches/x@1.patch", "diff\n"), (".pnpmfile.cjs", "module.exports = {}\n")):
            os.makedirs(os.path.dirname(os.path.join(self.src, path)) or self.src, exist_ok=True)
            tr.wfile(os.path.join(self.src, path), body)
            self.commit(path)
            n = len([c for c in self.calls() if c.startswith("pnpm install")])
            self.assertEqual(self.run_runner(["true"], sha=self.sha).rc, 0)
            self.assertEqual(len([c for c in self.calls() if c.startswith("pnpm install")]), n + 1, path)

    def test_package_manager_version_is_in_the_stamp(self):
        self.assertEqual(self.run_runner(["true"]).rc, 0)
        tr.wfile(os.path.join(self.src, "package.json"), json.dumps({"name": "david", "packageManager": "pnpm@10.1.0+sha512.ab"}))
        self.commit("v10")
        r = self.run_runner(["true"], sha=self.sha)
        self.assertEqual(r.rc, 0, r.err)
        self.assertIn("rrun: pnpm@10.1.0 install", r.err)

    def test_install_failure_is_78_with_the_log_tail(self):
        self.flag("pnpm-install-fail")
        r = self.run_runner(["/bin/sh", "-c", "echo RAN"])
        self.assertEqual(r.rc, 78)
        self.assertIn("ERR_PNPM_OUTDATED_LOCKFILE", r.err)
        self.assertNotIn("RAN", r.out)

    def test_corepack_install_failure_is_78(self):
        self.flag("corepack-fail")
        r = self.run_runner(["true"])
        self.assertEqual(r.rc, 78)
        self.assertIn("failed in ~/rr/tools", r.err)

    def test_corepack_lock_is_waited_on_with_the_pump(self):
        """Review note 11: another run holding ~/rr/tools/.lock longer than hb_timeout must not lose this run."""
        tools = os.path.join(self.root, "tools")
        os.makedirs(tools)
        fd = os.open(os.path.join(tools, ".lock"), os.O_CREAT | os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX)
        threading.Timer(4.0, lambda: (fcntl.flock(fd, fcntl.LOCK_UN), os.close(fd))).start()
        t0 = time.time()

        def heartbeats(p):                                     # the laptop's heartbeat: any byte ('.' is dropped)
            end = time.time() + 25
            while p.poll() is None and time.time() < end:
                try:
                    p.stdin.write(b".")
                    p.stdin.flush()
                except (BrokenPipeError, ValueError, OSError):
                    return
                time.sleep(0.3)
        r = self.run_runner(["true"], hb_timeout=2, action=heartbeats)
        self.assertEqual(r.rc, 0, r.err)
        self.assertGreater(time.time() - t0, 3.5)

    # -------------------------------------------------------------------------- policy, any command
    def test_policy_env_on_a_plain_command(self):
        r = self.policy(lane=False, env=SECRETS)
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(r.out.strip(), "U=unset|A=unset|M=echo|C=echo|T=unset|S=unset|P=unset|O=unset|R=unset"
                                        "|G=unset|H=unset|K=k|Q=unset")
        self.assertFalse([c for c in self.calls() if c.startswith("docker run")])

    def test_sent_env_file_refused_before_install(self):
        r = self.policy(lane=False, tar=tr.tar_of([("tests/hammer/.env.local", b"X=1\n")]), env_files=[])
        self.assertEqual(r.rc, 65)
        self.assertIn("env file(s) were sent (tests/hammer/.env.local)", r.err)
        self.assertFalse([c for c in self.calls() if c.startswith("pnpm install")])

    def test_tracked_env_file_refused_before_install(self):
        tr.wfile(os.path.join(self.src, "tests", "hammer", ".env.test"), "A=1\n")
        tr.wfile(os.path.join(self.src, ".env.example"), "A=\n")
        self.git("-C", self.src, "add", "-f", "tests/hammer/.env.test", ".env.example")
        self.commit("tracked env")
        r = self.policy(lane=False, sha=self.sha)
        self.assertEqual(r.rc, 65)
        self.assertIn("tracks env file tests/hammer/.env.test", r.err)
        self.assertFalse([c for c in self.calls() if c.startswith("pnpm install")])

    def test_leftover_env_files_anywhere_removed_before_install(self):
        self.assertEqual(self.run_runner(["true"]).rc, 0)       # the mirror exists
        for rel in (".env", "tests/hammer/.env.local", "tests/hammer/src/.envrc"):
            os.makedirs(os.path.dirname(os.path.join(self.mirror, rel)), exist_ok=True)
            tr.wfile(os.path.join(self.mirror, rel), "DATABASE_URL=" + pgurl("o", "p", "ep-x.neon.tech/n") + "\n")
        os.makedirs(os.path.join(self.mirror, "node_modules", "pkg"), exist_ok=True)
        tr.wfile(os.path.join(self.mirror, "node_modules", "pkg", ".env"), "x\n")    # not ours to judge
        open(self.log, "w").close()
        os.unlink(os.path.join(self.mirror, "node_modules", ".rr-deps-stamp"))      # forces an install
        r = self.policy(["/bin/sh", "-c", "find . -name '.env*' -not -path './node_modules/*' | sort"], lane=False)
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(r.out, "")
        for rel in (".env", "tests/hammer/.env.local", "tests/hammer/src/.envrc"):
            self.assertIn("removed a leftover %s" % rel, r.err)
        self.assertLess(r.err.index("removed a leftover"), r.err.index("rrun: pnpm@"))   # before the install

    # -------------------------------------------------------------------------- the lane
    def test_lane_env_is_exactly_this_runs_postgres(self):
        r = self.policy(env=SECRETS)
        self.assertEqual(r.rc, 0, r.err)
        url = pgurl("david", "david", "127.0.0.1:%d/postgres" % self.port)
        app = pgurl("david_app_login", "s3cr3tS3cr3tS3cr3t", "127.0.0.1:%d/postgres" % self.port)
        self.assertEqual(r.out.strip(), "U=%s|A=%s|M=echo|C=echo|T=unset|S=unset|P=unset|O=unset|R=unset"
                                        "|G=unset|H=unset|K=k|Q=unset" % (url, app))
        self.assertNotIn("s3cr3t", r.err)                       # provision output goes to a log, never relayed
        self.assertNotIn("REAL", r.err + r.out)
        calls = self.calls()
        run = [c for c in calls if c.startswith("docker run")]
        self.assertEqual(len(run), 1)
        for part in ("-d --cidfile ", "--name rr-pg-", "--label rdocker.rrun=", "-p 127.0.0.1::5432",
                     "--tmpfs /var/lib/postgresql/data", "postgres:16-alpine"):
            self.assertIn(part, run[0])
        steps = [c.split(" |")[0] for c in calls if c.startswith("pnpm db:")]
        self.assertEqual(steps, ["pnpm db:migrate", "pnpm db:provision"])
        self.assertTrue(all("pwd=" + os.path.realpath(self.mirror) in c for c in calls if c.startswith("pnpm db:")))
        # all of it before GO
        err = r.err
        self.assertLess(err.index("db lane: ready"), err.index("%s STARTED" % self.nonce))
        # removed by its id after a label check, never by name
        self.assertEqual(self.docker_rm_calls(), ["docker rm -f -v " + CID])
        self.assertTrue([c for c in calls if c.startswith("docker inspect -f") and c.endswith(CID)])

    def test_lane_db_removed_by_id_on_command_failure(self):
        r = self.policy(env={"RC": "3"})
        self.assertEqual(r.rc, 3)
        self.assertEqual(self.docker_rm_calls(), ["docker rm -f -v " + CID])
        self.assertNotIn(" KEPT ", r.err)

    def test_setup_step_failure_is_79_before_go(self):
        self.flag("migrate-fail")
        r = self.policy()
        self.assertEqual(r.rc, 79)
        self.assertEqual(r.out, "")
        self.assertNotIn("%s STARTED" % self.nonce, r.err)
        self.assertIn("`pnpm db:migrate` failed on the worker (exit 4); the command was not started", r.err)
        self.assertIn("migration 0042 failed on postgres://****@127.0.0.1:", r.err)    # userinfo redacted
        self.assertNotIn("david:david@", r.err)
        self.assertFalse([c for c in self.calls() if c.startswith("pnpm db:provision")])
        self.assertEqual(self.docker_rm_calls(), ["docker rm -f -v " + CID])

    def test_app_url_must_be_exactly_this_runs(self):
        for flag, why in (("provision-remote", "is not exactly this run's Postgres"),
                          ("provision-query", "is not exactly this run's Postgres"),
                          ("provision-port", "is not exactly this run's Postgres"),
                          ("provision-skip", "did not provide DATABASE_URL_APP")):
            with self.subTest(flag=flag):
                for f in ("provision-remote", "provision-query", "provision-port", "provision-skip"):
                    if os.path.exists(os.path.join(self.d, f)):
                        os.unlink(os.path.join(self.d, f))
                self.flag(flag)
                open(self.log, "w").close()
                r = self.policy()
                self.assertEqual(r.rc, 65, r.err)
                self.assertIn(why, r.err)
                self.assertNotIn("%s STARTED" % self.nonce, r.err)      # pre-GO: needs-human, never "fail"
                self.assertNotIn("s3cr3t", r.err)
                self.assertNotIn("neon", r.err)
                self.assertEqual(r.out, "")
                self.assertEqual(self.docker_rm_calls(), ["docker rm -f -v " + CID])

    def test_postgres_that_does_not_start_is_70_and_nothing_is_removed_by_name(self):
        self.flag("pg-run-fail")
        r = self.policy()
        self.assertEqual(r.rc, 70)
        self.assertIn("pull access denied", r.err)
        self.assertIn("did not come up on this worker; the command was not started", r.err)
        self.assertFalse([c for c in self.calls() if c.startswith("pnpm db:")])
        self.assertEqual(self.docker_rm_calls(), [])           # no id was created: nothing is removed

    def test_cleanup_checks_the_label_and_reports_failure(self):
        self.flag("pg-inspect-other")
        r = self.policy()
        self.assertEqual(r.rc, 0, r.err)
        self.assertEqual(self.docker_rm_calls(), [])
        self.assertIn("not removing container cccccccccccc: it is not this run's", r.err)
        os.unlink(os.path.join(self.d, "pg-inspect-other"))
        self.flag("pg-rm-fail")
        r = self.policy()
        self.assertEqual(r.rc, 0, r.err)
        self.assertIn("could not remove the db lane container cccccccccccc", r.err)

    def test_bad_policy_is_refused(self):
        for bad in ({"image": "postgres:16'; rm -rf /"}, {"user": "da vid"}, {"setup": [["pnpm", ""]]},
                    {"setup": "pnpm db:migrate"}, {"env": {"A B": "1"}}, {"env": {"DATABASE_URL": "x"}},
                    {"strip_env": ["$X"]}, {"app_role": "a'b"}, {"app_url_env": "1X"}):
            with self.subTest(bad=bad):
                r = self.run_runner(["true"], repo_policy=dict(LANE, **bad))
                self.assertEqual(r.rc, 65, r.err)
        self.assertEqual(self.run_runner(["true"], pg_lane=True).rc, 65)      # a lane needs its policy


if __name__ == "__main__":
    unittest.main()
