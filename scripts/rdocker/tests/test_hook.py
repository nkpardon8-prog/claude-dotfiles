"""Hermetic tests for the rrun-route PreToolUse hook (_hooks_stage/rrun-route.py).

The hook runs as a real subprocess fed hook JSON on stdin, under a temp home (rdmods.child_env):
~/.local/bin/rrun is a symlink to the staged `rrun` (so the hook finds the staged rd_common and its
rr_route_patterns), and is never executed.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
from rdmods import STAGE, TEST_HOME  # noqa: E402

# Staged beside the rdocker files as _hooks_stage/; installed as scripts/hooks/ next to scripts/rdocker/.
HOOK = next((p for p in (os.path.join(STAGE, "_hooks_stage", "rrun-route.py"),
                         os.path.join(os.path.dirname(STAGE), "hooks", "rrun-route.py"))
             if os.path.isfile(p)), "rrun-route.py not found")

# (command, expected rewrite)
POSITIVE = [
    ("npm run test:db", "rrun npm run test:db"),
    ("npm run test:db:rls", "rrun npm run test:db:rls"),
    ("npm --prefix server run test:db -- careHold", "rrun npm --prefix server run test:db -- careHold"),
    ("npm run release:rehearse:migrations", "rrun npm run release:rehearse:migrations"),
    ("npm run check:db-all 2>&1 | tail -20", "rrun npm run check:db-all 2>&1 | tail -20"),
    ("heavy-slot.sh node scripts/run-guard-tier.mjs needs-install", "rrun node scripts/run-guard-tier.mjs needs-install"),
    ("npm run check:server-test-typecheck", "rrun npm run check:server-test-typecheck"),
    ("cd server && npx tsc --noEmit -p tsconfig.json 2>&1 | head", "cd server && rrun npx tsc --noEmit -p tsconfig.json 2>&1 | head"),
    ("npx tsc -p tsconfig.vitest.json --noEmit", "rrun npx tsc -p tsconfig.vitest.json --noEmit"),
    ("./node_modules/.bin/tsc -p tsconfig.vitest.json --noEmit", "rrun ./node_modules/.bin/tsc -p tsconfig.vitest.json --noEmit"),
    ("cd server && npx vitest run", "cd server && rrun npx vitest run"),
    ("npx vitest run --reporter=dot 2>&1 | tail -20", "rrun npx vitest run --reporter=dot 2>&1 | tail -20"),
    ("npx vitest run > out.log 2>&1", "rrun npx vitest run > out.log 2>&1"),
    ("npm run lint 2>&1 | tail", "rrun npm run lint 2>&1 | tail"),
    ("npm run check:enqueue-trace", "rrun npm run check:enqueue-trace"),
    ("cd client && npm run typecheck", "cd client && rrun npm run typecheck"),
    ("npx eslint . --ext ts,tsx", "rrun npx eslint . --ext ts,tsx"),
    ("node --max-old-space-size=4096 scripts/check-tenant-context-coverage.mjs",
     "rrun node --max-old-space-size=4096 scripts/check-tenant-context-coverage.mjs"),
    ("cd server && npx vitest run src/lib/dashboard src/__tests__/lib/reports 2>&1 | tail",
     "cd server && rrun npx vitest run src/lib/dashboard src/__tests__/lib/reports 2>&1 | tail"),
    ("node scripts/test-with-db.mjs src/a.db.test.ts", "rrun node scripts/test-with-db.mjs src/a.db.test.ts"),
    ("node ../../scripts/test-with-db.mjs", "rrun node ../../scripts/test-with-db.mjs"),
    ("cd server && npm run test:db", "cd server && rrun npm run test:db"),
    ("cd server; npm run test:db 2>&1 | tail -n 40", "cd server; rrun npm run test:db 2>&1 | tail -n 40"),
    ("npm run test:db > out.log 2>&1", "rrun npm run test:db > out.log 2>&1"),
    ("RDOCKER_MODE=local npm run test:db", "rrun npm run test:db"),
    # assignments stay an env prefix (values never in rrun's argv); `-e NAME` forwards each one
    ("FOO=1 BAR=x/y npm run test:db", "FOO=1 BAR=x/y rrun -e FOO -e BAR npm run test:db"),
    ("RRUN_TIMING=1 RDOCKER_MODE=local DEBUG=1 npm run test:db",
     "RRUN_TIMING=1 DEBUG=1 rrun -e DEBUG npm run test:db"),
    ("FOO=a:b@c%d+e,f=g-h_i.j/k BAR= npm run test:db",
     "FOO=a:b@c%d+e,f=g-h_i.j/k BAR= rrun -e FOO -e BAR npm run test:db"),
    ("FOO=1\tnpm run test:db", "FOO=1 rrun -e FOO npm run test:db"),
    ("set -e; npm run test:db", "set -e; rrun npm run test:db"),
    ("find . -name x; npm run test:db", "find . -name x; rrun npm run test:db"),
    ('echo "export"; npm run test:db', 'echo "export"; rrun npm run test:db'),
    ("npm run test:db; export X=1", "rrun npm run test:db; export X=1"),   # state set AFTER
    ('npm run test:db -- -t "care hold release"', 'rrun npm run test:db -- -t "care hold release"'),
    ("git commit -m 'wip' && npm run test:db", "git commit -m 'wip' && rrun npm run test:db"),
    ("npm run test:db && npm run test:db:rls", "rrun npm run test:db && rrun npm run test:db:rls"),
    ("npm run test:db  # db suite", "rrun npm run test:db  # db suite"),
    ("  npm run test:db", "  rrun npm run test:db"),
    ("npm run build\nnpm run test:db", "npm run build\nrrun npm run test:db"),
    # wrappers: the laptop gate heavy-slot.sh is dropped; timeout/time/nice/caffeinate stay outside rrun
    ("~/.local/bin/heavy-slot.sh npm run test:db -- a.ts", "rrun npm run test:db -- a.ts"),
    ("FOO=1 heavy-slot.sh npm run test:db", "FOO=1 rrun -e FOO npm run test:db"),
    ("timeout 600 npm run test:db", "timeout 600 rrun npm run test:db"),
    ("time nice -n 5 npm run test:db", "time nice -n 5 rrun npm run test:db"),
    ("caffeinate -i npm run test:db 2>&1 | tail", "caffeinate -i rrun npm run test:db 2>&1 | tail"),
    # bash -c '<script>': the script is routed by the same rules; heavy-slot keeps gating the laptop part
    ("heavy-slot.sh bash -c 'npm run build | tail -4; RDOCKER_MODE=local npm run test:db -- x.ts' 2>&1 | tail",
     "heavy-slot.sh bash -c 'npm run build | tail -4; rrun npm run test:db -- x.ts' 2>&1 | tail"),
    ("bash -c 'npm run test:db'", "bash -c 'rrun npm run test:db'"),
    ("bash -c 'cd server && npm run test:db' > o.log 2>&1",
     "bash -c 'cd server && rrun npm run test:db' > o.log 2>&1"),
]

NEGATIVE = [
    "npx tsc -p tsconfig.json",                      # an emitting build: not a check
    "node scripts/check-small.mjs",                  # a plain small node script
    "npx vitest",                                    # watch mode: interactive
    "npm run test:e2e",                              # browser tests need the laptop
    "npm run dev",
    "npm run build",
    "cat tsconfig.json",
    "timeout npm run test:db",                       # timeout with no duration: not understood
    "bash -c 'echo test:db'",
    "bash -c 'FOO=$X npm run test:db'",
    "bash -c 'npm run test:db' extra-arg",
    "bash -c \"npm run test:db\"",                   # double-quoted script: $ expansion unclear
    "sh -c 'bash -c \"npm run test:db\"'",
    'git commit -m "fix test:db flake"',
    "git commit -m 'rehearse release:rehearse:migrations'",
    "echo test:db",
    "npm run lint && echo test:db",                 # a matching segment we don't understand
    'sh -c "cd server && npm run test:db"',
    "ssh mini npm run test:db",
    "xargs npm run test:db",
    "cat <<EOF\nnpm run test:db\nEOF",
    "cat x | npm run test:db",
    "(cd server && npm run test:db)",
    "{ npm run test:db; }",
    "npm run test:db $(echo x)",
    "npm run test:db `echo x`",
    "npm run test:db < input.txt",
    'npm run test:db -- -t "unbalanced',
    'FOO="a b" npm run test:db',
    "for f in a b; do npm run test:db; done",
    "# npm run test:db",
    "npm run test:db && echo $(date)",              # any substitution -> touch nothing
    "x=`true; npm run test:db; true`",
    "echo $(true; npm run test:db; true)",
    "npm run test:db && FOO='a b' npm run test:db:rls",   # one unsure hit -> touch none
    "ls -la",
    # assignment values beyond [A-Za-z0-9_./:@%+,=-]*: the shell would expand/split them
    "FOO=*.ts npm run test:db",
    "FOO=~/x npm run test:db",
    "FOO=$BAR npm run test:db",
    "FOO=${BAR} npm run test:db",
    "FOO=[x] npm run test:db",
    "FOO=a\\ b npm run test:db",
    "FOO=a!b npm run test:db",
    # whitespace other than space/tab (words would split differently)
    "FOO=1\vnpm run test:db",
    "npm run\vtest:db",
    "npm\fx run test:db",
    "FOO=1\u00a0npm run test:db",
    "npm\u00a0run test:db",
    "npm run\u2003test:db",
    "npm run test:db\u200b",
    "npm run test:db\r",
    "npm run test:db\u2028",
    # earlier shell state that a remote rrun would not see
    "export FOO=1; npm run test:db",
    "export FOO=1 && npm run test:db",
    "declare -x FOO=1; npm run test:db",
    "set -a; npm run test:db",
    "set -ea && npm run test:db",
    "set -o allexport; npm run test:db",
    "source .env && npm run test:db",
    ". ./env.sh; npm run test:db",
    "FOO=1; npm run test:db",
    "FOO=1 BAR='x y'; npm run test:db",
    "if true; then export X=1; fi; npm run test:db",
    "cd server && FOO=1 && npm run test:db",
]

OPT_OUT = [
    "rrun npm run test:db",
    "~/.local/bin/rrun npm run test:db",
    "RRUN=0 npm run test:db",
    "npm run test:db # real-od/ harness",
    "doctor-drive npm run test:db",
    "npm run test:db -- --approve=browser",
]


SCRIPTS = {
    "test": "vitest run", "test:unit": "vitest run src", "test:watch": "vitest",
    "test:sneaky": "vitest --watch", "test:e2e": "playwright test", "test:cov": "vitest run --coverage",
    "typecheck": "tsc --noEmit", "typecheck:server": "tsc --noEmit -p server",
    "lint": "eslint .", "lint:fix": "eslint . --fix", "lint:ci": "eslint . --fix",
    "dev": "vite", "start": "node server.js", "build": "vite build", "build:prod": "vite build",
}


def project(root, name, git=True, lock="package-lock.json", scripts=None):
    """A package dir (`.git` marker, package.json scripts, a lockfile, two tsconfigs) + client/."""
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "client"))
    if git:
        os.makedirs(os.path.join(d, ".git"))
    for sub in (d, os.path.join(d, "client")):
        with open(os.path.join(sub, "package.json"), "w") as f:
            json.dump({"scripts": scripts or SCRIPTS}, f)
    if lock:
        with open(os.path.join(d, lock), "w") as f:
            f.write("{}")
    with open(os.path.join(d, "tsconfig.json"), "w") as f:
        f.write('{"compilerOptions": {"outDir": "dist"}}')        # emits: not a check
    with open(os.path.join(d, "tsconfig.check.json"), "w") as f:
        f.write('{\n  "extends": "./tsconfig.json",\n  "compilerOptions": {"noEmit": true}\n}')
    return d


# One-shot dev commands routed by structure (run in the default project)
ONESHOT = [
    ("npx tsc -p tsconfig.check.json", "rrun npx tsc -p tsconfig.check.json"),
    ("npx tsc -b tsconfig.check.json", "rrun npx tsc -b tsconfig.check.json"),
    ("npx --prefix client tsc --noEmit -p tsconfig.json", "rrun npx --prefix client tsc --noEmit -p tsconfig.json"),
    ("npx vitest run src/a.test.ts", "rrun npx vitest run src/a.test.ts"),
    ("npm exec vitest run src/a.test.ts", "rrun npm exec vitest run src/a.test.ts"),   # seen leaking on Nick's mini
    ("npm exec -- vitest run src/a.test.ts", "rrun npm exec -- vitest run src/a.test.ts"),
    ("npm x eslint client/src", "rrun npm x eslint client/src"),
    ("npx vitest run src/a.test.ts src/b.test.ts 2>&1 | tail", "rrun npx vitest run src/a.test.ts src/b.test.ts 2>&1 | tail"),
    ("npx --prefix client vitest run src/x.test.ts", "rrun npx --prefix client vitest run src/x.test.ts"),
    ("FOO=1 npx vitest run a", "FOO=1 rrun -e FOO npx vitest run a"),
    ("timeout 300 npx vitest run src/a.test.ts", "timeout 300 rrun npx vitest run src/a.test.ts"),
    ("./node_modules/.bin/vitest run src/a.test.ts", "rrun ./node_modules/.bin/vitest run src/a.test.ts"),
    ("npx jest src/a.test.ts", "rrun npx jest src/a.test.ts"),
    ("npx jest --ci 2>&1 | tail -20", "rrun npx jest --ci 2>&1 | tail -20"),
    ("npx eslint src/a.ts", "rrun npx eslint src/a.ts"),
    ("npx eslint src --ext .ts > lint.log 2>&1", "rrun npx eslint src --ext .ts > lint.log 2>&1"),
    ("npm test", "rrun npm test"),
    ("npm t", "rrun npm t"),
    ("npm test -- src/a.test.ts", "rrun npm test -- src/a.test.ts"),
    ("npm run test", "rrun npm run test"),
    ("npm run test:unit -- src/a", "rrun npm run test:unit -- src/a"),
    ("npm run typecheck", "rrun npm run typecheck"),
    ("npm run typecheck:server", "rrun npm run typecheck:server"),
    ("npm run lint -- src/a.ts 2>&1 | tail", "rrun npm run lint -- src/a.ts 2>&1 | tail"),
    ("npm --prefix client run test", "rrun npm --prefix client run test"),
    ("cd client && npx tsc --noEmit && npx vitest run", "cd client && rrun npx tsc --noEmit && rrun npx vitest run"),
    ("npx tsc -p tsconfig.check.json; npx eslint src", "rrun npx tsc -p tsconfig.check.json; rrun npx eslint src"),
    ("git status && npx vitest run src/a.test.ts | tail -20", "git status && rrun npx vitest run src/a.test.ts | tail -20"),
    ("npx vitest run a && npx vitest --watch", "rrun npx vitest run a && npx vitest --watch"),   # watch half stays
]

# Never offloaded (run in the default project, so only the rule itself keeps them here)
NEVER = [
    # watch / interactive
    "npm exec vitest", "npm exec vitest watch", "npm exec vitest run --watch",
    "npx vitest", "npx vitest watch", "npx vitest -w", "npx vitest run --watch", "npx vitest run -w",
    "npx vitest run --ui", "npx vitest --ui", "npx vitest bench", "npx jest --watch", "npx jest --watchAll",
    "npx tsc -w -p tsconfig.check.json", "npx tsc --noEmit --watch", "npx tsc --noEmit -w",
    "npm run test:watch", "npm run test:sneaky", "npm run test -- --watch",
    # dev servers
    "npm run dev", "npm start", "npm run start", "npx vite", "npx vite preview", "npx next dev",
    # builds rrun would not copy back
    "vite build", "npx vite build", "pnpm build", "npm run build", "npm run build:prod",
    # installs
    "npm install", "npm ci", "npm i -D vitest", "npm add eslint", "pnpm add -D vitest",
    # writes files the agent then reads here
    "npx vitest run --coverage", "npx vitest run -u", "npx vitest run --outputFile=r.json",
    "npx jest -u", "npx jest --coverage", "npx eslint . --fix", "npx eslint src -o report.txt",
    "npm run lint:fix", "npm run lint:ci", "npm run test:cov", "npx tsc -p tsconfig.json",
    "npx tsc", "npx tsc -p tsconfig.json --outDir out",
    # bare tools (a worker's PATH has no node_modules/.bin) and non-npm runners
    "tsc -p tsconfig.check.json", "vitest run src/a.test.ts", "eslint src", "jest src",
    "yarn test", "pnpm test", "pnpm typecheck", "bun run test",
    # unclear / remote / container / heredoc / substitution / pipe target
    "cat <<EOF\nnpx vitest run a\nEOF", "ssh hp npx vitest run a", "docker run node npx vitest run a",
    "docker compose run app npm test", "npx vitest run $(git diff --name-only)",
    "npx tsc --noEmit -p $(pwd)", "echo x | npx vitest run a", "cd $D && npx vitest run a",
    "cd /tmp && npx vitest run a", "npm run test:nope && echo $(date)",
    "npx -p typescript -c 'tsc -p tsconfig.check.json'", "bash -c \"npx vitest run a\"",
    # opt-outs
    "RRUN=0 npx vitest run a", "rrun npx vitest run a", "RRUN=0 npm test",
]


class HookBase(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="hook-", dir=TEST_HOME)
        self.addCleanup(shutil.rmtree, self.home, True)
        self.bin = os.path.join(self.home, ".local", "bin")
        os.makedirs(self.bin)
        os.symlink(os.path.join(STAGE, "rrun"), os.path.join(self.bin, "rrun"))
        # the default cwd: a git project with an npm lockfile (rrun needs a repo; workers `npm ci`)
        self.proj = project(self.home, "proj")

    def hook(self, payload, *bins, **extra):
        env = rdmods.child_env(self.home, *(bins or (self.bin,)), **extra)
        raw = payload if isinstance(payload, str) else json.dumps(payload)
        p = subprocess.run(["/usr/bin/python3", "-I", HOOK], input=raw, env=env, cwd=self.proj,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stderr, "")
        return json.loads(p.stdout) if p.stdout.strip() else None

    def bash(self, command, **extra_input):
        return {"hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": dict(command=command, **extra_input)}

    def rewritten(self, command, *bins, **extra):
        out = self.hook(self.bash(command), *bins, **extra)
        if out is None:
            return None
        hso = out["hookSpecificOutput"]
        self.assertEqual(set(out), {"hookSpecificOutput"})
        self.assertEqual(set(hso), {"hookEventName", "updatedInput"})   # never a permission decision
        self.assertEqual(hso["hookEventName"], "PreToolUse")
        return hso["updatedInput"]["command"]


class RewriteMatrix(HookBase):
    def test_positive(self):
        for cmd, want in POSITIVE:
            with self.subTest(cmd=cmd):
                self.assertEqual(self.rewritten(cmd), want)

    def test_negative(self):
        for cmd in NEGATIVE:
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.rewritten(cmd))

    def test_opt_outs(self):
        for cmd in OPT_OUT:
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.rewritten(cmd))

    def test_oneshot(self):
        for cmd, want in ONESHOT:
            with self.subTest(cmd=cmd):
                self.assertEqual(self.rewritten(cmd), want)

    def test_never(self):
        for cmd in NEVER:
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.rewritten(cmd))

    def test_project_kinds(self):
        """No git repo -> nothing; pnpm/yarn lockfile -> nothing; no lockfile -> only the patterns."""
        pn = project(self.home, "pn", lock="pnpm-lock.yaml")
        yn = project(self.home, "yn", lock="yarn.lock")
        bare = project(self.home, "nolock", lock=None)
        loose = project(self.home, "loose", git=False)
        for cmd, cwd, want in (
                ("npx vitest run a", pn, None), ("npm run lint", pn, None), ("pnpm typecheck", pn, None),
                ("npm run test:db", yn, None), ("npx tsc --noEmit", yn, None),
                ("npx vitest run a", bare, None), ("npm test", bare, None),
                ("npm run test:db", bare, "rrun npm run test:db"),          # a pattern: as before
                ("npm run test:db", loose, None), ("npx vitest run a", loose, None),
                ("cd client && npx vitest run a", loose, None),
                ("cd ../proj && npx vitest run a", loose, "cd ../proj && rrun npx vitest run a"),
                ("npx vitest run a", os.path.join(self.proj, "client"), "rrun npx vitest run a")):
            with self.subTest(cmd=cmd, cwd=cwd):
                out = self.hook(dict(self.bash(cmd), cwd=cwd))
                self.assertEqual(out and out["hookSpecificOutput"]["updatedInput"]["command"], want)

    def test_fast(self):
        """The routing decision itself stays far below the 50 ms budget (interpreter start aside)."""
        import time
        env = rdmods.child_env(self.home, self.bin)
        code = ("import importlib.util,json,sys,time;"
                "s=importlib.util.spec_from_file_location('h',sys.argv[1]);h=importlib.util.module_from_spec(s);"
                "s.loader.exec_module(h);t=time.perf_counter();"
                "[h.route(c,[],cwd=sys.argv[2]) for c in json.loads(sys.argv[3])];"
                "print((time.perf_counter()-t)/len(json.loads(sys.argv[3])))")
        cmds = [c for c, _ in ONESHOT] + NEVER
        p = subprocess.run(["/usr/bin/python3", "-I", "-c", code, HOOK, self.proj, json.dumps(cmds)],
                           env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertLess(float(p.stdout), 0.005)
        t = time.perf_counter()
        self.rewritten("npx vitest run src/a.test.ts")
        self.assertLess(time.perf_counter() - t, 1.0)    # the whole subprocess, generous for CI noise

    def test_tool_input_preserved(self):
        out = self.hook(self.bash("npm run test:db", description="db tests", timeout=600000,
                                  run_in_background=True))
        self.assertEqual(out["hookSpecificOutput"]["updatedInput"],
                         {"command": "rrun npm run test:db", "description": "db tests",
                          "timeout": 600000, "run_in_background": True})


class NoOps(HookBase):
    def test_rrun_link_missing(self):
        os.unlink(os.path.join(self.bin, "rrun"))
        self.assertIsNone(self.rewritten("npm run test:db"))

    def test_rrun_not_on_path(self):
        empty = os.path.join(self.home, "empty-bin")
        os.makedirs(empty)
        self.assertIsNone(self.rewritten("npm run test:db", empty))

    def test_on_the_mini(self):
        self.assertIsNone(self.rewritten("npm run test:db", RRUN_REMOTE="1"))
        os.makedirs(os.path.join(self.home, "rr", "git"))
        self.assertIsNone(self.rewritten("npm run test:db"))

    def test_other_tools_and_malformed_input(self):
        for payload in ("", "not json", "[1, 2]", "{\"tool_name\": \"Bash\"}",
                        json.dumps({"tool_name": "Bash", "tool_input": {"command": 7}}),
                        json.dumps({"tool_name": "Write", "tool_input": {"command": "npm run test:db"}})):
            with self.subTest(payload=payload):
                self.assertIsNone(self.hook(payload))

    def test_broken_rd_common_fails_open(self):
        fake = os.path.join(self.home, "fake-install")
        os.makedirs(fake)
        with open(os.path.join(fake, "rd_common.py"), "w") as f:
            f.write("raise RuntimeError('boom')\n")
        with open(os.path.join(fake, "rrun"), "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(os.path.join(fake, "rrun"), 0o755)
        os.unlink(os.path.join(self.bin, "rrun"))
        os.symlink(os.path.join(fake, "rrun"), os.path.join(self.bin, "rrun"))
        self.assertIsNone(self.rewritten("npm run test:db"))


class Builds(HookBase):
    """`npm run build` is routed only in a package dir rr_outputs maps (default: dentall's server,
    client and admin-client -> dist), judged from the hook's cwd, `cd X &&` and --prefix."""

    def setUp(self):
        super().setUp()
        self.repo = os.path.join(self.home, "code", "dentall")
        for d in ("server", "client", "admin-client", "docs"):
            os.makedirs(os.path.join(self.repo, d))
            with open(os.path.join(self.repo, d, "package.json"), "w") as f:
                f.write("{}")
        env = rdmods.child_env(self.home, self.bin)
        for args in (["init", "-q"], ["add", "-A"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                      "commit", "-qm", "init"]):
            subprocess.run(["git"] + args, cwd=self.repo, env=env, check=True, capture_output=True)

    def at(self, command, cwd):
        out = self.hook(dict(self.bash(command), cwd=cwd))
        return out and out["hookSpecificOutput"]["updatedInput"]["command"]

    def test_mapped_builds_route_unmapped_stay(self):
        root, admin = self.repo, os.path.join(self.repo, "admin-client")
        for cmd, cwd, want in (
                ("cd server && npm run build", root, "cd server && rrun npm run build"),
                ("npm --prefix client run build 2>&1 | tail", root, "rrun npm --prefix client run build 2>&1 | tail"),
                ("npm run build", admin, "rrun npm run build"),
                ("cd ../server; npm run build", admin, "cd ../server; rrun npm run build"),
                ("cd server && npm run build && npm run test:db", root,
                 "cd server && rrun npm run build && rrun npm run test:db"),
                ("npm run build", root, None),                   # the repo root is not mapped
                ("cd docs && npm run build", root, None),
                ("cd $D && npm run build", root, None),          # dir unknown
                ("npx tsc -p tsconfig.json", admin, None),       # only the `npm run build` shape
                ("npm run build:prod", admin, None),
                ("npm run build", self.home, None)):             # not a git repo
            with self.subTest(cmd=cmd, cwd=cwd):
                self.assertEqual(self.at(cmd, cwd), want)

    def test_rr_outputs_config_replaces_the_map(self):
        d = os.path.join(self.home, ".config", "rdocker")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "config.json"), "w") as f:
            json.dump({"rr_outputs": {"dentall": {"docs": ["out"]}}}, f)
        self.assertIsNone(self.at("cd server && npm run build", self.repo))
        self.assertEqual(self.at("cd docs && npm run build", self.repo), "cd docs && rrun npm run build")


class ConfigPatterns(HookBase):
    def write_cfg(self, cfg):
        d = os.path.join(self.home, ".config", "rdocker")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "config.json"), "w") as f:
            json.dump(cfg, f)

    def test_custom_patterns_bypass_the_prefilter(self):
        self.write_cfg({"rr_route_patterns": [r"(^|\s)test:integration(\s|$)"]})
        self.assertEqual(self.rewritten("npm run test:integration"), "rrun npm run test:integration")
        self.assertIsNone(self.rewritten("node scripts/test-with-db.mjs"))   # the override replaces the list

    def test_custom_rr_root_marks_the_mini(self):
        self.write_cfg({"rr_root": "rr-alt"})
        os.makedirs(os.path.join(self.home, "rr-alt", "git"))
        self.assertIsNone(self.rewritten("npm run test:db"))

    def test_invalid_pattern_fails_open(self):
        self.write_cfg({"rr_route_patterns": ["(unclosed"]})
        self.assertIsNone(self.rewritten("npm run test:db"))


if __name__ == "__main__":
    unittest.main()
