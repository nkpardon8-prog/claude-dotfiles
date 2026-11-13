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
import time
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
    # a bare assignment to a name not already exported is shell-local: no child sees it, here or remote
    ("FOO=1; npm run test:db", "FOO=1; rrun npm run test:db"),
    ("FOO=1 BAR='x y'; npm run test:db", "FOO=1 BAR='x y'; rrun npm run test:db"),
    ("cd server && FOO=1 && npm run test:db", "cd server && FOO=1 && rrun npm run test:db"),
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
    # 2026-11-13: an earlier `export` is forwarded like a NAME=value prefix; `set -a` alone sets nothing
    ("export FOO=1; npm run test:db", "export FOO=1; rrun -e FOO npm run test:db"),
    ("export FOO=1 && npm run test:db", "export FOO=1 && rrun -e FOO npm run test:db"),
    ("set -a; npm run test:db", "set -a; rrun npm run test:db"),
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
    "npm run test:db < input.txt",
    'npm run test:db -- -t "unbalanced',
    'FOO="a b" npm run test:db',
    "for f in a b; do npm run test:db; done",
    "# npm run test:db",
    "x=`true; npm run test:db; true`",
    "echo $(true; npm run test:db; true)",
    "npm run test:db && FOO='a b' npm run test:db:rls",   # one unsure hit -> touch none
    "ls -la",
    # a substitution outside subst_ok's exact grammar (git diff --name-only / ls-files / find + filters)
    "npm run test:db $(echo x)", "npm run test:db `echo x`", "npm run test:db && echo $(date)",
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
    "declare -x FOO=1; npm run test:db",
    "set -ea && npm run test:db",
    "set -o allexport; npm run test:db",
    "source .env && npm run test:db",
    ". ./env.sh; npm run test:db",
    "if true; then export X=1; fi; npm run test:db",
    # bare assignments that DO reach a child: an exported name (PATH/HOME are in the hook's env),
    # zsh's tied path array, shell-special names, array assignments, zsh allexport
    "PATH=/x; npm run test:db",
    "path=(/x $path); npm run test:db",
    "IFS=,; npm run test:db",
    "CDPATH=/x; cd server && npm run test:db",
    "arr=(a b); npm run test:db",
    "PATH+=:/x; npm run test:db",
    "setopt allexport; FOO=1; npm run test:db",
    "setopt ALL_EXPORT; npm run test:db",
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
    "typecheck:test": "tsc --noEmit -p tsconfig.test.json",
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
    ("npx vitest run $(git diff --name-only)", "rrun npx vitest run $(git diff --name-only)"),
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
    "docker compose run app npm test", "npx tsc --noEmit -p $(pwd)", "npm run test:nope && echo $(date)",
    "echo x | npx vitest run a", "cd $D && npx vitest run a", "cd /tmp && npx vitest run a",
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
        """No git repo -> nothing; yarn lockfile -> nothing; no lockfile -> only the patterns; a pnpm
        project (workers install it with pnpm via corepack) routes only rd_pnpm.exact_form's shapes
        (tests/test_pnpm.py covers workspaces)."""
        pn = project(self.home, "pn", lock="pnpm-lock.yaml")
        yn = project(self.home, "yn", lock="yarn.lock")
        bare = project(self.home, "nolock", lock=None)
        loose = project(self.home, "loose", git=False)
        for cmd, cwd, want in (
                ("npx vitest run a", pn, "rrun npx vitest run a"), ("npm run lint", pn, None),   # not an exact form
                ("pnpm typecheck", pn, "rrun pnpm typecheck"), ("pnpm build", pn, None),
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


class AbsoluteBinPaths(HookBase):
    """2026-11-11: agents typed `/abs/repo/node_modules/.bin/<tool>`. Such a path is routed only
    inside the worktree and only for a node_modules rrun installs on the worker, rewritten relative
    to the cwd (the laptop path does not exist there); anything else stays here, as typed."""

    def at(self, command, cwd=None):
        out = self.hook(dict(self.bash(command), cwd=cwd or self.proj))
        return out and out["hookSpecificOutput"]["updatedInput"]["command"]

    def test_inside_the_worktree_becomes_relative(self):
        p = self.proj
        for cmd, want in (
                (p + "/node_modules/.bin/tsc --noEmit -p tsconfig.check.json",
                 "rrun ./node_modules/.bin/tsc --noEmit -p tsconfig.check.json"),
                (p + "/node_modules/.bin/vitest run src/a.test.ts 2>&1 | tail",
                 "rrun ./node_modules/.bin/vitest run src/a.test.ts 2>&1 | tail"),
                (p + "/node_modules/.bin/eslint src", "rrun ./node_modules/.bin/eslint src"),
                (os.path.realpath(p) + "/node_modules/.bin/jest src/a.test.ts",   # /private/tmp form
                 "rrun ./node_modules/.bin/jest src/a.test.ts"),
                ("FOO=1 %s/node_modules/.bin/vitest run a" % p, "FOO=1 rrun -e FOO ./node_modules/.bin/vitest run a"),
                ("cd client && %s/node_modules/.bin/vitest run a" % p,      # client has no lockfile: root's deps
                 "cd client && rrun ../node_modules/.bin/vitest run a")):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.at(cmd), want)

    def test_a_lockfile_subpackage_from_the_root_only(self):
        with open(os.path.join(self.proj, "client", "package-lock.json"), "w") as f:
            f.write("{}")
        sub = self.proj + "/client/node_modules/.bin/vitest run a"
        self.assertEqual(self.at(sub), "rrun ./client/node_modules/.bin/vitest run a")
        self.assertEqual(self.at(self.proj + "/client/node_modules/.bin/vitest run a",
                                 os.path.join(self.proj, "client")), "rrun ./node_modules/.bin/vitest run a")

    def test_same_safety_rules_as_relative_paths(self):
        p = self.proj
        other = project(self.home, "other")
        for cmd in (p + "/client/node_modules/.bin/vitest run a",    # no lockfile there: not installed
                    other + "/node_modules/.bin/vitest run a",         # another repo
                    "/usr/local/bin/vitest run a", "/tmp/x/node_modules/.bin/vitest run a",
                    p + "/node_modules/.bin/vitest", p + "/node_modules/.bin/vitest run --watch",
                    p + "/node_modules/.bin/eslint src --fix", p + "/node_modules/.bin/tsc -p tsconfig.json",
                    p + "/node_modules/.bin/vite build", p + "/node_modules/.bin/prettier --check .",
                    "RRUN=0 " + p + "/node_modules/.bin/vitest run a"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd))
        pn = project(self.home, "pn", lock="pnpm-lock.yaml")
        self.assertIsNone(self.at(pn + "/node_modules/.bin/vitest run a", pn))


class LeakedOnTheMini(HookBase):
    """Commands agents really ran that stayed local before: a bare scratch assignment and a heredoc."""

    def at(self, command, **extra):
        out = self.hook(dict(self.bash(command), cwd=self.proj), **extra)
        return out and out["hookSpecificOutput"]["updatedInput"]["command"]

    def test_bare_scratch_assignment_no_longer_blocks(self):
        client = os.path.join(self.proj, "client")
        cmd = ("cd %s && SP=/private/tmp/claude-501/x/scratchpad && npx tsc --noEmit -p . ; echo tsc=$?; "
               "npm run typecheck:test >/dev/null 2>&1; echo tct=$?; "
               "RRUN_CACHE=0 npx vitest run src/pages/__tests__/X.test.tsx src/pages/__tests__/Y.test.tsx" % client)
        want = ("cd %s && SP=/private/tmp/claude-501/x/scratchpad && rrun npx tsc --noEmit -p . ; echo tsc=$?; "
                "rrun npm run typecheck:test >/dev/null 2>&1; echo tct=$?; "
                "RRUN_CACHE=0 rrun npx vitest run src/pages/__tests__/X.test.tsx src/pages/__tests__/Y.test.tsx" % client)
        self.assertEqual(self.at(cmd), want)

    def test_assignment_to_an_exported_name_still_blocks(self):
        self.assertEqual(self.at("FOO=2; npm test"), "FOO=2; rrun npm test")
        self.assertIsNone(self.at("FOO=2; npm test", FOO="1"))
        self.assertIsNone(self.at("BAR=x FOO=2; npm test", FOO="1"))
        self.assertIsNone(self.at("foo=2; npm test", FOO="1"))           # zsh ties lower/upper pairs
        self.assertEqual(self.at("FOO=2 npm test", FOO="1"), "FOO=2 rrun -e FOO npm test")   # a prefix: forwarded

    def test_heredoc_then_cd_then_vitest(self):
        os.makedirs(os.path.join(self.proj, "server", "src"))
        body = ("import pathlib\np = pathlib.Path('a.ts')\n"
                "p.write_text(p.read_text().replace('npx vitest run x', 'y'))\n")
        cmd = ("cd %s/server/src && python3 - <<'EOF'\n%sEOF\n cd .. && "
               "npx vitest run src/__tests__/a.test.ts src/__tests__/b.test.ts" % (self.proj, body))
        want = ("cd %s/server/src && python3 - <<'EOF'\n%sEOF\n cd .. && "
                "rrun npx vitest run src/__tests__/a.test.ts src/__tests__/b.test.ts" % (self.proj, body))
        self.assertEqual(self.at(cmd), want)

    def test_heredoc_forms_route_later_segments(self):
        for cmd, want in (
                ("cat <<EOF > notes.txt\nhello\nEOF\nnpm test", "cat <<EOF > notes.txt\nhello\nEOF\nrrun npm test"),
                ('cat <<"EOF"\nhi\nEOF\nnpm test', 'cat <<"EOF"\nhi\nEOF\nrrun npm test'),
                ("cat << EOF\nhi\nEOF\nnpm test", "cat << EOF\nhi\nEOF\nrrun npm test"),
                ("cat <<-EOF >x\n\tbody\n\tEOF\nnpm test", "cat <<-EOF >x\n\tbody\n\tEOF\nrrun npm test"),
                ("cat <<A\na\nA\ncat <<B\nb\nB\nnpm test", "cat <<A\na\nA\ncat <<B\nb\nB\nrrun npm test"),
                ("cat <<EOF && npm test\nbody\nEOF", "cat <<EOF && rrun npm test\nbody\nEOF"),
                ("cat <<'EOF' > plan.md\nnpx vitest run src/a.test.ts\nEOF\nnpm test",
                 "cat <<'EOF' > plan.md\nnpx vitest run src/a.test.ts\nEOF\nrrun npm test")):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.at(cmd), want)

    def test_heredoc_fail_safes(self):
        for cmd in (
                "cat <<'EOF' > plan.md\nnpx vitest run src/a.test.ts\nEOF",   # body text is never routed
                "cat <<EOF > plan.md\nnpm run test:db\nEOF",
                "cat <<EOF > notes.txt\nnpm test\nEOF\necho done",          # nothing heavy after it
                "cat <<EOF\nhello\nnpm test",                                 # no terminator line
                "cat <<EOF\nEOF \nnpm test",                                  # `EOF ` is not the terminator
                "cat <<EOF",
                "cat <<< hi; npm test",                                        # here-string
                "cat <<<hi\nnpm test",
                "cat <<A <<B\na\nA\nb\nB\nnpm test",                          # two on one line
                "cat <<A; cat <<B\na\nA\nb\nB\nnpm test",
                "cat <<EOF 'a\nb'\nEOF\nnpm test",                             # quote spans the body
                "cat <<$X\nbody\n$X\nnpm test",                                # $ in the delimiter
                "cat <<E\"OF\"\nbody\nEOF\nnpm test",                           # partly quoted
                "cat <<\\EOF\nbody\nEOF\nnpm test",
                "cat <<EOF\n$(date)\nEOF\nnpm test",                            # substitution in the body
                "cat <<EOF\n`date`\nEOF\nnpm test",
                "npx vitest run a <<EOF\nx\nEOF",                               # the owner itself: `<`
                "npx vitest run a <<EOF\nx\nEOF\nnpm test"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd))


class ClosedGaps(HookBase):
    """2026-11-13 gaps (tmp/research/2026-11-13-local-compute-leaks.md), with the shapes dentall agents
    really typed: a substitution in an argument, a heredoc line that carries the test run, an earlier
    `export` / `source`, `node scripts/check-*.mjs`, checker names with update / coverage in them,
    and a value naming this Mac (the RRUN=0 cause: a DB on a mirrored laptop port)."""

    DENTALL = {
        "test": "vitest run", "typecheck": "tsc --noEmit",
        "check:update-record": "node scripts/check-update-record.mjs",
        "check:update-record:strict": "UPDATE_RECORD_STRICT=true node scripts/check-update-record.mjs",
        "check:tenant-context-coverage": "node scripts/check-tenant-context-coverage.mjs",
        "check:dev-db-guard:self-test": "node scripts/_lib/dev-db-guard.selftest.mjs",
        "check:ui-mirror-coverage": "node client/scripts/check-ui-mirror-coverage.mjs",
        "check:patient-link-origins": "node scripts/check-patient-link-origins.mjs",
        "check:writes": "node scripts/check-writes.mjs --write",
        "check:cov": "vitest run --coverage",
        "gen:demo-endpoints": "node scripts/gen-demo-endpoints.mjs",
        "check:guard:self-test": "node scripts/_lib/guard.selftest.mjs",
        "check:lint-plain": "node scripts/check-lint-plain.mjs",
        "check:debug-x": "node scripts/check-x.mjs", "check:inspect-x": "node scripts/check-x.mjs",
        "check:cov-x": "node scripts/check-x.mjs", "check:watch-x": "node scripts/check-x.mjs",
        "check:update-x": "node scripts/check-x.mjs", "check:snap-x": "node scripts/check-x.mjs",
        "check:c8": "c8 node scripts/check-x.mjs", "check:nyc": "nyc node scripts/check-x.mjs",
        "check:insp": "node --inspect-brk scripts/check-x.mjs", "check:upd": "node scripts/check-x.mjs --update",
        "check:env": "FOO=1 node scripts/check-x.mjs", "check:dashu": "node scripts/check-x.mjs -u",
        "check:wat": "node scripts/check-x.mjs --watch",
        "check:coverage-fake": "node scripts/check-x.mjs && echo done",
        "verify:build": "node scripts/verify-dist.mjs", "check:all": "npm run build && npm run lint",
        "lint:bundle": "npm run lint:inner", "lint:inner": "vite build --mode check",
        "check:build-env": "node scripts/check-build-env.mjs",
        "check:local": "node scripts/check-x.mjs --base http://localhost:3000",
        # round 2: nested scripts are followed past every flag; an unfollowable call is a build
        "lint:p": "npm run --silent verify:c", "verify:c": "next build",
        "lint:q": "npm --prefix . run lint:inner", "lint:r": "npm --prefix . run -s lint:plain2",
        "lint:plain2": "eslint .", "lint:s": "npm run-script --if-present -s verify:c",
        "check:pn": "pnpm -r --filter x run --silent verify:c", "lint:npx": "npx tsc -b",
        "lint:npxok": "npx eslint . && npm test", "lint:exec": "npm exec foo",
        "lint:missing": "npm run nope", "lint:wrapped": "cross-env A=1 npm run lint:plain2",
        "lint:timeout": "timeout 60 npm run lint:plain2", "lint:deep": "npm run lint:r",
        # round 2: any body that updates snapshots / records stays here, test scripts included
        "test:u": "vitest run -u", "test:upd": "vitest run --update",
        "test:snap2": "UPDATE_SNAPSHOTS=1 vitest run", "test:snap3": "VITEST_SNAPSHOT_UPDATE=1 vitest run",
        "test:plain": "vitest run",
    }

    def setUp(self):
        super().setUp()
        self.dent = project(self.home, "dentall-x", scripts=self.DENTALL)

    def at(self, command, cwd=None, **extra):
        out = self.hook(dict(self.bash(command), cwd=cwd or self.dent), **extra)
        return out and out["hookSpecificOutput"]["updatedInput"]["command"]

    def write(self, name, text):
        with open(os.path.join(self.dent, name), "w") as f:
            f.write(text)

    def test_substitution_in_an_argument_routes(self):
        for cmd in (
                "f=$(git ls-files | grep FormComposerAction.mirror) && npx vitest run $f",
                "cd client && npx vitest run $(git ls-files 'src/**/*.test.tsx' | grep -E \"OfficeView|PatientProfile\")",
                "npx vitest run `git diff --name-only origin/dev -- '*.test.ts'`",
                "npx vitest run $(find src -name '*.test.ts' -type f | grep -v legacy | sort -u | head -n 20)",
                "npm run check:update-record -- $(git diff --name-only origin/dev HEAD | grep -E '^docs/')"):
            with self.subTest(cmd=cmd):
                self.assertIn("rrun ", self.at(cmd) or "")
        self.assertEqual(self.at("f=$(git ls-files | grep a.test) && npx vitest run $f"),
                         "f=$(git ls-files | grep a.test) && rrun npx vitest run $f")

    def test_substitution_fail_safes(self):
        for cmd in (
                "npx tsc --noEmit -p $(git rev-parse --show-toplevel)/server",   # laptop absolute path
                "npx tsc --noEmit -p $(pwd)", "npx vitest run $(realpath src/a.test.ts)",
                "npx vitest run $(cat /tmp/list.txt)", "npx vitest run $(ls src | xargs realpath)",
                "npx vitest run \"$(git diff --name-only)\"",                       # inside double quotes
                "$(npm bin)/vitest run a", "npx $(echo vitest) run a",            # substitution in the head
                "F=$(git diff --name-only) npx vitest run",                      # ... in an env prefix
                "npx vitest run $(git diff --name-only; rm -rf x)", "npx vitest run $(case x in a) echo;; esac)",
                "npx vitest run $(git diff --name-only", "npx vitest run `git diff 'x`",
                "x=`true; npm run test:db; true`", "echo $(true; npm run test:db; true)",
                # review repros: anything that can print a laptop path or run more than a file list
                "npx vitest run $(git ls-files $CLAUDE_PROJECT_DIR/src)",
                "npx vitest run $(git ls-files | sed 's|^|/Users/me/repo/|')",
                "npx vitest run $(git ls-files | awk '{print ENVIRON[\"HOME\"] \"/\" $0}')",
                "npx vitest run $(cat files.txt)", "npx vitest run $(git ls-files | xargs echo)",
                "npx vitest run $(git ls-files ../other)", "npx vitest run $(git diff --name-only origin/dev...HEAD)", "npx vitest run $(git ls-files '/abs/x')",
                "npx vitest run $(find /Users/me -name '*.test.ts')", "npx vitest run $(find ~/x -name a)",
                "npx vitest run $(find src -exec rm {} +)", "npx vitest run $(git diff origin/dev)",
                "npx vitest run $(git diff --name-only --relative=..)", "npx vitest run $(git log --name-only)",
                "npx vitest run $(git ls-files | grep -r x)", "npx vitest run $(git ls-files | tail -f)",
                "npx vitest run $(git ls-files > f)", "npx vitest run $(echo src/a.test.ts)",
                "N=$(git rev-list --count HEAD..origin/dev) && echo $N && npm run -s check:update-record"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd))

    def test_heredoc_line_carrying_the_run(self):
        cmd = ("cat > src/x.test.tsx <<'E' && npx vitest run src/x.test.tsx\nimport { it } from 'vitest'\n"
               "it('x', () => {})\nE")
        self.assertEqual(self.at(cmd), cmd.replace("&& npx", "&& rrun npx"))
        cmd = "python3 - <<'EOF'; cd client && npx tsc --noEmit\np = 'a'\nEOF\nnpm run typecheck"
        self.assertEqual(self.at(cmd), "python3 - <<'EOF'; cd client && rrun npx tsc --noEmit\np = 'a'\nEOF\n"
                                       "rrun npm run typecheck")
        for cmd in ("cat <<E | npx vitest run a\nx\nE",                          # a pipe target
                    "cat <<E && npx vitest run a\n$(date)\nE",                   # substitution in the body
                    "cat <<E && npx vitest run a\nx"):                            # no terminator
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd))

    def test_export_and_source_are_forwarded(self):
        self.write("dbenv.sh", "# test DB\nexport TEST_SHARD=2\n"
                               "TEST_DB_CONSTRAINED=1\nexport RRUN_TIMING=1\nRRUN=1\n")
        self.assertEqual(self.at(". ./dbenv.sh && npm run test:db"),
                         ". ./dbenv.sh && rrun -e TEST_SHARD npm run test:db")
        self.assertEqual(self.at("source dbenv.sh; npm --prefix client test"),
                         "source dbenv.sh; rrun -e TEST_SHARD npm --prefix client test")
        self.assertEqual(self.at("set -a && . ./dbenv.sh && set +a && npm run test:db"),
                         "set -a && . ./dbenv.sh && set +a && rrun -e TEST_SHARD -e TEST_DB_CONSTRAINED npm run test:db")
        self.assertEqual(self.at("export A=b && npx vitest run a"), "export A=b && rrun -e A npx vitest run a")
        self.assertEqual(self.at('export A="x y" B && FOO=1 npm test'), 'export A="x y" B && FOO=1 rrun -e A -e B -e FOO npm test')
        self.assertEqual(self.at("export RRUN_TIMING=1 && npm test"), "export RRUN_TIMING=1 && rrun npm test")
        self.assertEqual(self.at("npm test && export A=1"), "rrun npm test && export A=1")

    def test_export_and_source_fail_safes(self):
        self.write("local.sh", f"export DATABASE_URL=postgres://david:{'david'}@localhost:20007/postgres\n")
        self.write("subst.sh", "L=prov.log\nexport TEST_DATABASE_URL=$(sed -n 's/^X=//p' $L) RRUN=0\n")
        self.write("cmd.sh", "export A=1\ncd server\n")
        self.write("path.sh", "export PATH=/x\n")
        self.write(".env.test", "export TEST_SHARD=1\n")
        for name, line in (("db.sh", "export TEST_DATABASE_URL=postgres://app@db.internal/t"),
                           ("pg.sh", "export PGHOST=db.internal"), ("tok.sh", "export GH_TOKEN=x"),
                           ("key.sh", "export OPENAI_API_KEY=x"), ("pw.sh", "export DB_PASSWORD=x"),
                           ("auth.sh", "export AUTH_SECRET=x"), ("no.sh", "export NODE_OPTIONS=--max-old-space-size=4096"),
                           ("insp.sh", "export X=--inspect-brk")):
            self.write(name, line + "\n")
        for cmd in (". ./local.sh && npm run test:db", ". ./subst.sh && npm run test:db",
                    ". ./cmd.sh && npm test", ". ./path.sh && npm test", ". ./missing.sh && npm test",
                    "echo 'export A=1' > env.sh && . ./env.sh && npm test",        # written first
                    ". $F && npm test", ". ./a.sh ./b.sh && npm test",
                    "export PATH=/x:$PATH && npm test", "export -n A && npm test", "export && npm test",
                    "export DATABASE_URL=postgres://u@localhost:20007/db && npx vitest run a",
                    "export DYLD_INSERT_LIBRARIES=x && npm test",
                    "if true; then export X=1; fi; npm run test:db", "declare -x A=1; npm test",
                    "set -a; A=1; npm test", "set -ea && npm run test:db",
                    # sourced env files and secret names are never copied to a worker
                    ". ./.env.test && npm test", ". ./db.sh && npm run test:db", ". ./pg.sh && npm test",
                    ". ./tok.sh && npm test", ". ./key.sh && npm test", ". ./pw.sh && npm test",
                    ". ./auth.sh && npm test", ". ./no.sh && npm test", ". ./insp.sh && npm test",
                    "export NODE_OPTIONS=--max-old-space-size=4096 && npm test",
                    "NODE_OPTIONS=--max-old-space-size=4096 npm test", "export X=--inspect && npm test",
                    "PATH=/x npm run test:db"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd))

    def test_node_check_scripts_named_by_package_json(self):
        for cmd, want in (
                ("node scripts/check-update-record.mjs", "rrun node scripts/check-update-record.mjs"),
                ("node scripts/check-tenant-context-coverage.mjs --self-test 2>&1 | tail -3",
                 "rrun node scripts/check-tenant-context-coverage.mjs --self-test 2>&1 | tail -3"),
                ("node scripts/_lib/guard.selftest.mjs", "rrun node scripts/_lib/guard.selftest.mjs"),
                ("node ./scripts/check-update-record.mjs", "rrun node ./scripts/check-update-record.mjs"),
                ("cd client && node ../scripts/check-update-record.mjs", "cd client && rrun node ../scripts/check-update-record.mjs"),
                ("node --max-old-space-size=4096 scripts/check-patient-link-origins.mjs",
                 "rrun node --max-old-space-size=4096 scripts/check-patient-link-origins.mjs"),
                # an exact CHECKER_ALLOW name whose body is exactly `node scripts/check-<x>.mjs`
                ("npm run -s check:update-record 2>&1 | tail", "rrun npm run -s check:update-record 2>&1 | tail"),
                ("npm run check:tenant-context-coverage", "rrun npm run check:tenant-context-coverage"),
                ("npm run check:patient-link-origins", "rrun npm run check:patient-link-origins"),
                ("npm run check:lint-plain", "rrun npm run check:lint-plain")):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.at(cmd), want)
        for cmd in ("node scripts/check-small.mjs",                    # no package.json script runs it
                    "node scripts/gen-demo-endpoints.mjs",             # not a check
                    "node scripts/check-writes.mjs",                   # its script writes (--write)
                    "npm run check:writes", "npm run check:cov",       # body writes / coverage
                    "node client/scripts/check-ui-mirror-coverage.mjs --write", "node scripts/check-update-record.mjs -w",
                    "node --inspect scripts/check-update-record.mjs", "node -e 1", "node /tmp/check-x.mjs",
                    "npm run test:coverage", "npm run test:update",
                    # review repros: the name veto applies to every script, the body veto to checkers
                    "UPDATE_RECORD_STRICT=true node scripts/check-update-record.mjs",   # UPDATE_* prefix
                    "npm run -s check:update-record:strict",           # VAR= in the body
                    "node scripts/_lib/dev-db-guard.selftest.mjs",     # its script's name says dev
                    "npm run check:ui-mirror-coverage",                # ui + coverage, not allowlisted
                    "npm run check:debug-x", "npm run check:inspect-x", "npm run check:cov-x",
                    "npm run check:watch-x", "npm run check:update-x", "npm run check:snap-x",
                    "npm run check:c8", "npm run check:nyc", "npm run check:insp", "npm run check:upd",
                    "npm run check:env", "npm run check:dashu", "npm run check:wat",
                    "npm run check:coverage-fake",                     # allowlist needs the EXACT body
                    "npm run verify:build", "npm run check:all", "npm run lint:bundle",
                    "node scripts/check-build-env.mjs", "npm run check:local"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd))
        pn = project(self.home, "pn2", lock="pnpm-lock.yaml", scripts=self.DENTALL)
        self.assertIsNone(self.at("node scripts/check-update-record.mjs", cwd=pn))   # workers: npm ci here

    def test_nested_scripts_are_followed_or_fail_closed(self):
        for cmd in ("npm run lint:p", "npm run lint:q", "npm run lint:s", "npm run check:pn",
                    "npm run lint:npx", "npm run lint:exec", "npm run lint:missing",
                    "npm run lint:wrapped", "npm run lint:timeout",
                    "npm run test:u", "npm run test:upd", "npm run test:snap2", "npm run test:snap3"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd))
        for cmd in ("npm run lint:r", "npm run lint:plain2", "npm run lint:npxok", "npm run lint:deep",
                    "npm run test:plain"):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.at(cmd), "rrun " + cmd)

    def test_a_value_naming_this_mac_stays_here(self):
        for cmd in (f"DATABASE_URL=postgres://david:{'david'}@localhost:20007/postgres npx vitest run a",
                    "BASE=http://127.0.0.1:5391 npm test", "API=http://0.0.0.0:3000 npx vitest run a",
                    "H=host.docker.internal npm run test:db",
                    # review repros: ONE check over every word of the command
                    "npx vitest run a --base-url http://localhost:3000", "npm run test:db -- --host ::1",
                    "export DATABASE_URL=$(cat url.txt | grep localhost) && npm run test:db",
                    "export U=http://LOCALHOST:1 && npm test", "npm test -- 'http://127.0.0.1:9'",
                    "npx vitest run a --url=local\"host\":3000", "git commit -m 'localhost' && npm test",
                    # round 2: all of 127.0.0.0/8 (short forms too), 0 as a host, [::1]
                    "npx vitest run a --base http://127.1:3000", "npx vitest run a --base 127.0.1",
                    "npx vitest run a --base http://127.0.0.2/x", "npx vitest run a --url http://0:3000",
                    "npx vitest run a --api 0:8080", "npx vitest run a --host 0", "HOST=0 npm test",
                    "npx vitest run a --url http://[::1]:9", "npx vitest run a --base 127.255.255.254"):
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd))
        for cmd in ("RRUN_CACHE=0 npx vitest run a", "npx vitest run src/v127.1.test.ts",
                    "npx vitest run a --retry 0", "npx vitest run a --testTimeout=10000"):
            with self.subTest(cmd=cmd):
                self.assertIsNotNone(self.at(cmd))
        self.assertEqual(self.at("DATABASE_URL=postgres://u@db.internal/x npm test"),
                         "DATABASE_URL=postgres://u@db.internal/x rrun -e DATABASE_URL npm test")


class DecisionLog(HookBase):
    """Every heavy-looking command leaves one JSON line: routed / local / skipped + why."""

    def log(self):
        p = os.path.join(self.home, ".local", "state", "rdocker", "hook.log")
        if not os.path.exists(p):
            return []
        with open(p) as f:
            return [json.loads(x) for x in f]

    def run_cmd(self, command, **extra):
        return self.hook(dict(self.bash(command), session_id="sess-1", cwd=self.proj), **extra)

    def test_one_line_per_heavy_looking_command(self):
        self.run_cmd("npx vitest run src/a.test.ts")
        self.run_cmd("npx tsc -p tsconfig.json")               # emits: stays
        self.run_cmd("npx vitest")                             # watch
        self.run_cmd("RRUN=0 npx vitest run a")
        self.run_cmd("npm run test:db", RRUN_REMOTE="1")
        self.run_cmd("ls -la && git status")                   # not heavy-looking: no line
        self.run_cmd("cd $D && npx vitest run a")
        got = [(x["d"], x["why"]) for x in self.log()]
        self.assertEqual(got, [("routed", "ok"), ("local", "tsc-emits"), ("local", "watch"),
                               ("skipped", "marker:RRUN=0"), ("skipped", "remote"), ("local", "cwd-unknown")])
        first = self.log()[0]
        self.assertEqual(first["sid"], "sess-1")
        self.assertEqual(first["cwd"], self.proj)
        self.assertEqual(first["cmd"], "npx vitest run src/a.test.ts")
        self.assertEqual(oct(os.stat(os.path.join(self.home, ".local", "state", "rdocker", "hook.log")).st_mode & 0o777), "0o600")

    def test_secrets_are_redacted_and_long_commands_cut(self):
        self.run_cmd(f"DATABASE_URL=postgres://u:{'s3cret'}@db.x/y TOKEN=abc123 npm run test:db -- a " + "x" * 600)
        line = self.log()[0]
        self.assertNotIn("s3cret", json.dumps(line))
        self.assertNotIn("abc123", json.dumps(line))
        self.assertTrue(line["cmd"].startswith("DATABASE_URL=**** TOKEN=**** npm run test:db"))
        self.assertLessEqual(len(line["cmd"]), 300)
        self.run_cmd(f"curl -H 'Authorization: Bearer zz9' x; npx vitest run --reporter=dot postgres://a:{'pw'}@h/d")
        s = json.dumps(self.log()[1])
        self.assertNotIn("zz9", s)
        self.assertNotIn(":pw@", s)
        self.assertIn("--reporter=dot", s)                     # a flag is not an assignment

    def test_review_redactions(self):
        for cmd, secret in (("mysql --password=hunter2 && npm test", "hunter2"),
                            ("x --api-key abc123 && npm test", "abc123"), ("x --api-key=abc124 && npm test", "abc124"),
                            ("x --token tk9 && npm test", "tk9"), ("x --token=tk8 && npm test", "tk8"),
                            ("curl -H 'X-Api-Key: zz7' u && npm test", "zz7"),
                            ('curl -H "Authorization: Basic zz6" u && npm test', "zz6"),
                            ("curl -u bob:pw5 u && npm test", "pw5"),
                            ("psql postgres://u:p/w4@h/db && npm test", "p/w4"),
                            ("cat > f.txt <<E && npm test\nSECRET=zz3\nE", "zz3")):
            with self.subTest(cmd=cmd):
                self.run_cmd(cmd)
                self.assertNotIn(secret, json.dumps(self.log()[-1]))
        self.assertEqual(self.log()[-1]["cmd"], "cat > f.txt <<E && npm test [heredoc body not logged]")

    def test_a_command_over_8_kb_is_left_alone(self):
        out = self.run_cmd("npx vitest run a " + "b " * 4200)
        self.assertIsNone(out)
        self.assertEqual((self.log()[-1]["d"], self.log()[-1]["why"]), ("local", "too-long"))

    def test_rotates_and_never_breaks_the_hook(self):
        d = os.path.join(self.home, ".local", "state", "rdocker")
        os.makedirs(d)
        with open(os.path.join(d, "hook.log"), "w") as f:
            f.write("x" * (5 * 1024 * 1024 + 1))
        self.run_cmd("npx vitest run a")
        self.assertTrue(os.path.exists(os.path.join(d, "hook.log.1")))
        self.assertEqual(len(self.log()), 1)
        shutil.rmtree(d)
        open(d, "w").close()                                    # the state dir is a FILE: no log possible
        out = self.run_cmd("npx vitest run a")
        self.assertEqual(out["hookSpecificOutput"]["updatedInput"]["command"], "rrun npx vitest run a")

    def test_rdocker_home_is_honoured(self):
        other = tempfile.mkdtemp(prefix="hook-other-", dir=TEST_HOME)
        self.addCleanup(shutil.rmtree, other, True)
        self.run_cmd("npx vitest run a", HOME=other)
        self.assertEqual(len(self.log()), 1)
        self.assertFalse(os.path.exists(os.path.join(other, ".local", "state", "rdocker", "hook.log")))


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

    def test_a_mapped_build_with_a_watch_or_update_flag_stays(self):
        """Review round 2 finding 8: the mapped-build fast path skipped judge(); its decoded words now get
        the same veto (-w / -u / -o / --watch / --update ..., quoted or not)."""
        admin = os.path.join(self.repo, "admin-client")
        for cmd in ("npm run build -w", "npm run build -- --watch", "npm run build '--watch'", "npm run build -u",
                    "npm run build -- -o out", "cd ../server && npm run build --update",
                    "npm run build -- x#y --watch", "npm run build -- a#b -w"):   # an in-word # hides nothing
            with self.subTest(cmd=cmd):
                self.assertIsNone(self.at(cmd, admin))
        self.assertEqual(self.at("npm run build", admin), "rrun npm run build")

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


@unittest.skipUnless(sys.platform == "darwin", "the autopull LaunchAgent is macOS-only")
class AutopullEnsure(HookBase):
    """Every Mac that uses the pool self-installs the 2-minute dotfiles fast-forward pull."""

    def fake_autopull(self):
        d = os.path.join(self.home, ".claude-dotfiles", "scripts")
        os.makedirs(d)
        marker = os.path.join(self.home, "ensured")
        with open(os.path.join(d, "dotfiles-autopull.sh"), "w") as f:
            f.write(f'echo "$1" >> "{marker}"\n')
        return marker

    def wait_for(self, path, secs=5):
        end = time.time() + secs
        while time.time() < end and not os.path.exists(path):
            time.sleep(0.05)
        return os.path.exists(path)

    def test_missing_plist_triggers_ensure_without_changing_output(self):
        marker = self.fake_autopull()
        self.assertIsNone(self.hook(self.bash("ls")))
        self.assertTrue(self.wait_for(marker))
        self.assertEqual(open(marker).read().strip(), "--ensure")

    def test_present_plist_is_left_alone(self):
        marker = self.fake_autopull()
        la = os.path.join(self.home, "Library", "LaunchAgents")
        os.makedirs(la)
        open(os.path.join(la, "com.claude.dotfiles-autopull.plist"), "w").close()
        self.hook(self.bash("ls"))
        time.sleep(0.5)
        self.assertFalse(os.path.exists(marker))
