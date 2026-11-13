"""rdocker rd_pnpm: pnpm workspaces and the repo policy for rrun (2026-11-13, the DAVID lane, round 3).

Shared by the routing hook (scripts/hooks/rrun-route.py) and rrun (rd_run). Pure file reads
(package.json, pnpm-workspace.yaml); it never runs pnpm and never expands a script tree.

exact_form(cwd, argv) -> ("vitest" | "tsc", [package dirs]) for ONLY these shapes (argv = decoded words,
nothing before the head, no other token):
  pnpm typecheck                         (the package at cwd)
  pnpm -r|--recursive typecheck          (every non-root package that defines it)
  pnpm --filter|-F <pkg> test|typecheck  (also --filter=<pkg>; <pkg> = an exact name or a unique unscoped one)
  pnpm --filter <pkg> exec vitest run [args]
  pnpm exec vitest run [args] | npx vitest run [args] | vitest run [args]   (cwd in a package)
[args] = test file paths, `-t` / `--testNamePattern <name>` (or =<name>), `--reporter=<x>`. A script form reads
only the target package's script: its body must FULLY match VITEST_BODY (then its args pass the same rule) or
TSC_BODY (with --noEmit), and the package may have no pre<name> / post<name> script. Anything else -> None.

Repo policy (repo_policy): a git worktree whose top-level package.json name is an rr_pg_lanes `repo_package`.
Postgres lane (needs_pg): in such a repo, every command but a proven tsc form gets it (unknown = Postgres).
"""
import fnmatch
import glob
import json
import os
import re

LOCK = "pnpm-lock.yaml"
WORKSPACE = "pnpm-workspace.yaml"
VITEST_BODY = re.compile(r"^vitest run( [\w@./=-]+)*$")
TSC_BODY = re.compile(r"^tsc( --noEmit| -p [\w./-]+| --pretty false)*$")
_FILE_RE = re.compile(r"^[\w@][\w@./-]*$")              # a test file / dir path (no flag, no assignment)
_PKG_RE = re.compile(r"^(@[\w.-]+/)?[\w.-]+$")
_REPORTER_RE = re.compile(r"^--reporter=[\w-]+$")


def _read_json(path):
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def workspace_root(cwd, top=None):
    """The nearest dir at or above cwd (not above `top`, the git worktree) whose lockfile is pnpm's
    (pnpm-lock.yaml; a pnpm-workspace.yaml beside it lists the packages, none = one package), else
    None - also when the nearest lockfile is npm's."""
    d = os.path.abspath(cwd)
    stop = os.path.abspath(top) if top else None
    while True:
        if any(os.path.isfile(os.path.join(d, n)) for n in ("package-lock.json", "npm-shrinkwrap.json")):
            return None
        if os.path.isfile(os.path.join(d, LOCK)):
            return d
        up = os.path.dirname(d)
        if up == d or (stop and d == stop):
            return None
        d = up


def is_pnpm_dir(d):
    """A deps dir rrun installs with pnpm: a pnpm lockfile and no npm one."""
    return os.path.isfile(os.path.join(d, LOCK)) and not any(
        os.path.isfile(os.path.join(d, n)) for n in ("package-lock.json", "npm-shrinkwrap.json"))


def packages(root):
    """{reldir: package.json dict} for the workspace root ("") and every package its
    pnpm-workspace.yaml `packages:` globs name (`!glob` excluded)."""
    try:
        with open(os.path.join(root, WORKSPACE)) as f:
            text = f.read(65536)
    except OSError:
        text = ""                                             # a single-package pnpm project
    globs, inside = [], False
    for line in text.splitlines():
        s = line.split("#", 1)[0].rstrip()
        if not s.strip():
            continue
        if re.match(r"^packages\s*:\s*$", s):
            inside = True
            continue
        if inside and not s.startswith((" ", "\t", "-")):
            inside = False
        m = re.match(r"^\s*-\s*['\"]?([^'\"]+?)['\"]?\s*$", s) if inside else None
        if m:
            globs.append(m.group(1))
    out = {"": _read_json(os.path.join(root, "package.json"))}
    excl = [g[1:] for g in globs if g.startswith("!")]
    for g in (g for g in globs if not g.startswith("!")):
        for p in sorted(glob.glob(os.path.join(root, g), recursive=True)):
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            if rel.startswith("..") or "node_modules" in rel.split("/") or \
                    any(fnmatch.fnmatchcase(rel, x) for x in excl):
                continue
            if os.path.isfile(os.path.join(p, "package.json")):
                out[rel] = _read_json(os.path.join(p, "package.json"))
    return out


def _names(pkgs):
    return {rel: p.get("name") for rel, p in pkgs.items() if isinstance(p.get("name"), str)}


def _pkg_of(root, cwd, pkgs):
    """The workspace package holding cwd (its nearest package dir), "" for the root."""
    rel = os.path.relpath(os.path.abspath(cwd), root).replace(os.sep, "/")
    rel = "" if rel == "." else rel
    while rel and rel not in pkgs:
        rel = rel.rsplit("/", 1)[0] if "/" in rel else ""
    return rel


def vitest_args_ok(args):
    """Only test file paths, -t / --testNamePattern <name> (or =<name>) and --reporter=<x>."""
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-t", "--testNamePattern"):
            if i + 1 >= len(args):
                return False
            i += 2
        elif a.startswith("--testNamePattern=") or _REPORTER_RE.match(a) or _FILE_RE.match(a):
            i += 1
        else:
            return False
    return True


def _body_kind(pkg, name):
    """"vitest" / "tsc" when package.json's script `name` fully matches the strict body and the package
    has no pre<name> / post<name>, else None."""
    scripts = pkg.get("scripts") if isinstance(pkg.get("scripts"), dict) else {}
    body = scripts.get(name)
    if not isinstance(body, str) or "pre" + name in scripts or "post" + name in scripts:
        return None
    if VITEST_BODY.match(body) and vitest_args_ok(body.split()[2:]):
        return "vitest"
    if TSC_BODY.match(body) and "--noEmit" in body.split():
        return "tsc"
    return None


def _named(pkgs, name):
    """The one package rel named `name` (exact, else a unique unscoped match, as pnpm), or None."""
    if not _PKG_RE.match(name):
        return None
    names = _names(pkgs)
    hit = [r for r, n in names.items() if n == name]
    if not hit and "/" not in name:
        hit = [r for r, n in names.items() if n.rsplit("/", 1)[-1] == name]
    return hit[0] if len(hit) == 1 else None


def exact_form(cwd, argv, top=None):
    """-> ("vitest" | "tsc", [rels]) for one of the module doc's shapes, else None."""
    root = workspace_root(cwd, top)
    if root is None or not argv:
        return None
    pkgs = packages(root)
    here = _pkg_of(root, cwd, pkgs)
    in_pkg = here != "" or len(pkgs) == 1                     # a single-package project is its own package
    a = list(argv)
    if a[:2] == ["vitest", "run"] or a[:3] == ["npx", "vitest", "run"] or a[:4] == ["pnpm", "exec", "vitest", "run"]:
        n = {"vitest": 2, "npx": 3, "pnpm": 4}[a[0]]
        return ("vitest", [here]) if in_pkg and vitest_args_ok(a[n:]) else None
    if a[:1] != ["pnpm"]:
        return None
    if a == ["pnpm", "typecheck"]:
        return ("tsc", [here]) if _body_kind(pkgs[here], "typecheck") == "tsc" else None
    if a in (["pnpm", "-r", "typecheck"], ["pnpm", "--recursive", "typecheck"]):
        rels = sorted(r for r in pkgs if r and isinstance(pkgs[r].get("scripts"), dict)
                      and "typecheck" in pkgs[r]["scripts"])
        return ("tsc", rels) if rels and all(_body_kind(pkgs[r], "typecheck") == "tsc" for r in rels) else None
    if len(a) >= 3 and a[1] in ("--filter", "-F"):
        name, rest = a[2], a[3:]
    elif len(a) >= 2 and a[1].startswith("--filter="):
        name, rest = a[1][len("--filter="):], a[2:]
    else:
        return None
    rel = _named(pkgs, name)
    if rel is None or not rest:
        return None
    if rest[0] == "test" and _body_kind(pkgs[rel], "test") == "vitest" and vitest_args_ok(rest[1:]):
        return ("vitest", [rel])
    if rest == ["typecheck"] and _body_kind(pkgs[rel], "typecheck") == "tsc":
        return ("tsc", [rel])
    if rest[:3] == ["exec", "vitest", "run"] and vitest_args_ok(rest[3:]):
        return ("vitest", [rel])
    return None


# ---------------------------------------------------------------------------- repo policy / Postgres lane

def repo_policy(cfg, top):
    """The rr_pg_lanes entry for the git worktree at `top` (its top-level package.json name is the
    entry's repo_package), else None. Independent of the cwd and of any nested lockfile."""
    name = _read_json(os.path.join(top, "package.json")).get("name") if top else None
    for spec in cfg.get("rr_pg_lanes") or []:
        if isinstance(spec, dict) and isinstance(name, str) and name and spec.get("repo_package") == name:
            return spec
    return None


def needs_pg(top, cwd, argv):
    """In a policy repo: Postgres for every command but a proven tsc form (exact_form)."""
    form = exact_form(cwd, argv, top)
    return not (form and form[0] == "tsc")


ENV_FILE_RE = re.compile(r"^\.env")                          # .env, .env.local, .env.test, .envrc, ...
ENV_TEMPLATE_RE = re.compile(r"\.(example|sample|template)$")


def is_env_file(path):
    """A file a policy repo never ships or keeps on a worker: basename .env* except templates."""
    base = path.rsplit("/", 1)[-1]
    return bool(ENV_FILE_RE.match(base)) and not ENV_TEMPLATE_RE.search(base)
