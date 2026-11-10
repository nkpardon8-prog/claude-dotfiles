#!/usr/bin/env python3
"""
PreToolUse rewrite (Bash) - send heavy one-shot dev commands to the compute pool via `rrun`.

Why: type-checks, test suites, lint and builds make the Mac running the agents unresponsive, and a
DB test run split across the link (runner here, Postgres on a worker) took 673 s vs 12 s on one
machine. Agents will not remember to type `rrun`, so this rewrites e.g. `npx tsc --noEmit` into
`rrun npx tsc --noEmit`; rrun picks the worker (rd_pool) and falls back by itself. The rdocker
shim's safety net catches whatever this misses (it keeps such a DB on the laptop).

Behavior:
  * Patterns: `rr_route_patterns` from rdocker's config (rd_common.DEFAULTS deep-merged with
    ~/.config/rdocker/config.json) - the one list the shim's safety net also uses. rd_common is
    found next to the real file behind ~/.local/bin/rrun, and only imported after the prefilter.
  * Prefilter: a substring test (PREFILTER: test / tsc / lint / vitest / build ...) so every
    other Bash call exits at once. A config that sets its own rr_route_patterns skips the prefilter.
  * No-op when: rrun is not installed (~/.local/bin/rrun missing, or no rrun on PATH); we are on
    the mini (RRUN_REMOTE set, or ~/<rr_root>/git exists); the command already mentions rrun;
    a skip marker is present: RRUN=0, real-od/, doctor-drive, --approve=browser.
  * One-shot dev commands (judge(), on top of the patterns): `npx [--prefix X] tsc` with --noEmit
    or -p/-b configs that all set "noEmit": true; `npx vitest run ...`; `npx jest ...`;
    `npx eslint ...`; `./node_modules/.bin/<tool>` the same; `npm test` / `npm run test*` /
    `typecheck*` / `type-check*` / `lint*` when package.json defines the script. Only when the
    segment's cwd is in a git repo and the nearest lockfile is npm's (workers run `npm ci`; no
    pnpm / yarn / bun, and no bare `tsc` - a worker's PATH has no node_modules/.bin).
  * Never offloaded, pattern hit or not: watch / UI / dev-server / write-back runs (--watch*, -w,
    --ui, --coverage, --fix, -u/--update, --outputFile, --outDir, --open, --inspect, --stdin,
    bare `vitest`, vite / next / nodemon heads), script names with dev / start / serve / preview /
    watch / e2e / playwright / browser / ui / fix / format / update / coverage / install..., a
    script BODY that watches, serves or writes (package.json is read), a pnpm / yarn / bun lockfile,
    an unknown cwd (`cd $D`) or no git repo. Such a segment is simply left alone.
  * Segment-safe: splits on unquoted && || ; | & and newlines with a quote/comment-aware
    scanner. A matching segment is rewritten only when the match is in unquoted text, its head is
    a node package runner (npm/node/npx/pnpm/yarn/bun) after plain NAME=value assignments, it is
    not a pipe target, and it has no parens / braces / input redirect. Any $( / backtick (a
    substitution can hide its own segments), heredoc or unbalanced quote, or ANY matching segment
    that is not safe, leaves the whole command alone.
  * Leading NAME=value assignments stay where they are (an env prefix, so values never enter
    rrun's argv) and each non-RRUN_/RDOCKER_ name gets `rrun -e NAME`, which forwards the value
    from rrun's own environment: `FOO=1 npm run test:db` -> `FOO=1 rrun -e FOO npm run test:db`.
    RDOCKER_MODE=local is dropped; RRUN_* / RDOCKER_* only configure the laptop side. A value
    must match [A-Za-z0-9_./:@%+,=-]* (no globs, ~, $, quotes...), else the command is left alone.
  * Words split only on space/tab: any other whitespace or invisible format char (\\v \\f \\r,
    NBSP, U+2000.., U+200B, ...) leaves the command alone. So does shell state set by an EARLIER
    segment that would not reach the mini: export, declare/typeset, set -a / allexport,
    source / `.`, or a bare assignment (`FOO=1; npm run test:db`).
  * Builds: a `npm run build` segment (rd_pool.BUILD_RE) is routed only when its package dir is
    mapped in rr_outputs (rd_pool.outputs_for: repo name -> package dir -> output dirs), so rrun
    can copy the outputs back. The dir = the hook's cwd, moved by earlier plain `cd <dir>`
    segments, plus `--prefix X`; the repo comes from git there. Unmapped builds stay untouched.
  * Returns ONLY updatedInput (never a permission decision), so normal permission prompts still
    apply to the rewritten command. Every other tool_input key is preserved.
  * FAILS OPEN: any parse error or unexpected input -> exit 0 with no output (call unchanged).
"""
import json
import os
import re
import sys
import unicodedata

PREFILTER = ("test:db", "rehearse:migrations", "test-with-db", "check:db-all", "run-guard-tier",
             "check:server-test-typecheck", "--noEmit", "vitest", "check", "lint", "typecheck",
             "type-check", "verify", "test", "jest", "eslint", "max-old-space-size", "build", "tsc",
             "npm t")
SKIP_MARKERS = ("rrun", "RRUN=0", "real-od/", "doctor-drive", "--approve=browser")
HEADS = {"npm", "node", "npx", "pnpm", "yarn", "bun", "tsc", "vitest", "jest", "eslint"}   # also ./node_modules/.bin/<x>
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
VALUE_RE = re.compile(r"[A-Za-z0-9_./:@%+,=-]*")   # fullmatch
UNSAFE_IN_SEGMENT = re.compile(r"\$\(|`|[(){}<]")
WORD_RE = re.compile(r"[^ \t]+")                 # the only separators we accept: space, tab
STATE_WORDS = {"export", "declare", "typeset", "source"}
KEYWORDS = {"then", "do", "else", "elif", "!", "{", "("}
# Wrappers between the assignments and the node runner. heavy-slot.sh (a LAPTOP concurrency gate)
# is dropped: the job no longer runs on the laptop and the mini has its own slots. The others stay
# in front of rrun, which then runs under them: `timeout 600 npm ...` -> `timeout 600 rrun npm ...`.
DROP_WRAPPERS = {"heavy-slot.sh"}
KEEP_WRAPPERS = {"timeout": 1, "gtimeout": 1, "time": 0, "nice": 0, "caffeinate": 0}
WRAP_ARG_RE = re.compile(r"-[A-Za-z]+|[0-9]+(\.[0-9]+)?[smhd]?")      # flags / durations only
SHELLS = {"bash", "sh", "zsh"}
SIMPLE_FILE_RE = re.compile(r"[A-Za-z0-9_./~@%+,=-]+")
REDIR_RE = re.compile(r"[0-9]?(>>?|>&)([0-9]|[A-Za-z0-9_./~@%+,=-]+)")

# ---- one-shot dev commands (structural, on top of rr_route_patterns) ----------------------------
# The jobs rd_pool.classify() places well: tsc (heavy), vitest / jest / test scripts (normal),
# eslint / lint scripts (light). Only `npx <tool>`, a path to the tool (./node_modules/.bin/tsc) and
# `npm` scripts: a worker's PATH has no node_modules/.bin (a bare `tsc` may not exist there), and it
# installs deps with `npm ci` only (no pnpm / yarn / bun).
TOOLS = {"tsc", "vitest", "jest", "eslint"}
NPX_SOLO = {"-y", "--yes", "--no", "--no-install", "-q", "--quiet"}
NPM_SOLO = {"-s", "--silent", "-q", "--quiet", "--if-present"}
NPM_RUN = {"run", "run-script", "rum", "urn"}
SCRIPT_RE = re.compile(r"^(test|typecheck|type-check|lint)([:._-][\w:.-]*)?$")
# never offload: watch / interactive / dev-server / writes-files-the-agent-reads-here script names
SCRIPT_VETO_RE = re.compile(r"watch|(^|[:._-])(dev|start|serve|preview|e2e|playwright|cypress|browser"
                            r"|ui|fix|format|fmt|update|snapshots?|snap|coverage|cov|debug|open"
                            r"|storybook|install|i|ci|add|remove|rm|uninstall|up|upgrade|link|exec"
                            r"|dlx|create|init)([:._-]|$)")
# flags that make a run watch, serve, open a UI, or write files (coverage, reports, fixes, snapshots,
# emitted JS) that would land on the worker instead of here
LONG_VETO = ("--watch", "--ui", "--fix", "--coverage", "--collectCoverage", "--outputFile",
             "--output-file", "--outDir", "--outFile", "--declarationDir", "--update", "--browser",
             "--inspect", "--init", "--open", "--generateTrace", "--stdin", "--write", "--api",
             "--standalone", "--emitDeclarationOnly")
SHORT_VETO = {"tsc": {"-w"}, "vitest": {"-w", "-u"}, "jest": {"-u"}, "eslint": {"-o"},
              "script": {"-w", "-u", "-o"}}
SERVER_HEADS = {"vite", "next", "nuxt", "astro", "nodemon", "webpack-dev-server", "storybook",
                "serve", "http-server", "live-server", "concurrently"}
# a script BODY (package.json) that watches, serves, writes or drives a browser stays here
BODY_VETO_RE = re.compile(r"--watch|--ui\b|--fix\b|--write\b|--coverage|--outputFile|--output-file"
                          r"|--outDir|--open\b|(^|\s)-[wu](\s|$)|e2e|browser|playwright|cypress"
                          r"|(^|[\s;&|(/])(vite|next|nuxt|astro|nodemon|concurrently|webpack-dev-server"
                          r"|storybook|start-storybook|http-server|live-server|serve)(\s|$|[;&|)])")
REDIR_WORD_RE = re.compile(r"^[0-9]*(&?>>?|>&|<)")
NPM_LOCKS = ("package-lock.json", "npm-shrinkwrap.json")
OTHER_LOCKS = ("pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock")
NOEMIT_RE = re.compile(r'"noEmit"\s*:\s*true')


def home():
    return os.path.abspath(os.path.expanduser(os.environ.get("RDOCKER_HOME") or "~"))


def rrun_installed(h):
    """-> realpath of ~/.local/bin/rrun when it exists and an rrun is on PATH, else None."""
    link = os.path.join(h, ".local", "bin", "rrun")
    if not os.access(link, os.X_OK):
        return None
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and os.access(os.path.join(d, "rrun"), os.X_OK):
            return os.path.realpath(link)
    return None


def user_cfg(h):
    try:
        with open(os.path.join(h, ".config", "rdocker", "config.json")) as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) else {}
    except (OSError, ValueError):
        return {}


def load_cfg(rrun_real, user):
    """rdocker's merged config (DEFAULTS + user keys) via the rd_common shipped beside rrun."""
    sys.path.insert(0, os.path.dirname(rrun_real))
    import rd_common
    return rd_common.merge_cfg(user)


def scan(cmd):
    """-> (segments, masked) or None when the quoting is unbalanced or a heredoc is present.
    segments: [(start, end, op_before)]; masked: cmd with quoted/escaped text and comments
    blanked; shape: the same but quoted/escaped text kept as non-space, so words split where the
    shell splits them. Both have cmd's length, so indexes line up with the original."""
    segs, masked, shape = [], list(cmd), list(cmd)
    i, n, start, op = 0, len(cmd), 0, ""
    word_start = True
    while i < n:
        c = cmd[i]
        if c == "\\":
            for k in range(i, min(i + 2, n)):
                masked[k], shape[k] = " ", "Q"
            i += 2
            word_start = False
            continue
        if c in "'\"":
            j = i + 1
            while j < n and cmd[j] != c:
                j += 2 if (c == '"' and cmd[j] == "\\") else 1
            if j >= n:
                return None                                   # unbalanced quote
            for k in range(i, j + 1):
                masked[k], shape[k] = " ", "Q"
            i = j + 1
            word_start = False
            continue
        if c == "#" and word_start:
            j = cmd.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                masked[k], shape[k] = " ", " "
            i = j
            continue
        if c == "<" and cmd.startswith("<<", i):
            return None                                       # heredoc / herestring
        two = cmd[i:i + 2]
        if two in ("&&", "||", "|&"):
            segs.append((start, i, op))
            op, i, start, word_start = two, i + 2, i + 2, True
            continue
        if c in ";|\n" or (c == "&" and cmd[i - 1:i] != ">" and cmd[i + 1:i + 2] != ">"):
            segs.append((start, i, op))
            op, i, start, word_start = c, i + 1, i + 1, True
            continue
        word_start = c in " \t"
        i += 1
    segs.append((start, n, op))
    return segs, "".join(masked), "".join(shape)


def shell_c(cmd, shape, toks, k):
    """toks[k:] is `bash|sh|zsh -c '<script>'` (one single-quoted script, then only output
    redirects like `2>&1` / `> file`) -> (script_start, script_end) inside the quotes, else None."""
    if len(toks) - k < 3:
        return None
    rest = [cmd[a:b] for a, b in toks[k + 3:]]
    while rest:
        if rest[0] in (">", ">>", "2>", "2>>") and len(rest) > 1 and SIMPLE_FILE_RE.fullmatch(rest[1]):
            rest = rest[2:]
        elif REDIR_RE.fullmatch(rest[0]):
            rest = rest[1:]
        else:
            return None
    (hs, he), (fs, fe), (qs, qe) = toks[k:k + 3]
    if os.path.basename(cmd[hs:he]) not in SHELLS or cmd[fs:fe] != "-c":
        return None
    if cmd[qs] != "'" or cmd[qe - 1] != "'" or qe - qs < 2 or "'" in cmd[qs + 1:qe - 1]:
        return None
    return qs + 1, qe - 1


def rewrite_segment(cmd, shape, s, e, op, patterns=None, depth=0, builds=None, cwd=None):
    """-> replacement text for cmd[s:e], or None when the segment is not fully understood."""
    if op in ("|", "|&"):
        return None
    toks = [(m.start() + s, m.end() + s) for m in WORD_RE.finditer(shape[s:e])]
    front, names, head, wraps = [], [], None, []
    k = 0
    while k < len(toks):
        ts, te = toks[k]
        word = cmd[ts:te]
        if shape[ts:te] != word:                              # quoting in env/head: not simple
            if head is None and wraps is not None:
                break                                         # maybe `bash -c '...'`: checked below
            return None
        m = ASSIGN_RE.match(word) if not wraps else None
        if m and not wraps:
            pass
        else:
            base = os.path.basename(word)
            if base in DROP_WRAPPERS:
                wraps.append((False, word))
                k += 1
                continue
            if base in KEEP_WRAPPERS:
                j = k + 1
                while j < len(toks) and WRAP_ARG_RE.fullmatch(cmd[toks[j][0]:toks[j][1]]):
                    j += 1
                if j - k - 1 < KEEP_WRAPPERS[base]:
                    return None                               # e.g. `timeout` with no duration
                wraps.append((True, cmd[ts:toks[j - 1][1]]))
                k = j
                continue
            head = (ts, word)
            break
        if not VALUE_RE.fullmatch(m.group(2)):
            return None                                       # glob, ~, $, ... : not simple
        k += 1
        if word == "RDOCKER_MODE=local":
            continue
        front.append(word)
        if not m.group(1).startswith(("RRUN_", "RDOCKER_")):
            names.append(m.group(1))
    if not toks:
        return None
    lead = cmd[s:toks[0][0]]
    env = "".join(w + " " for w in front)
    kept = "".join(w + " " for keep, w in wraps if keep)
    sc = shell_c(cmd, shape, toks, k) if depth == 0 and patterns is not None else None
    if sc:                                                    # bash -c '<script>': rewrite inside
        inner = route(cmd[sc[0]:sc[1]], patterns, depth + 1, builds, cwd)
        if inner is None:
            return None
        allw = "".join(w + " " for _, w in wraps)            # heavy-slot still gates the laptop part
        return lead + env + allw + cmd[toks[k][0]:sc[0]] + inner + cmd[sc[1]:e]
    if head is None or os.path.basename(head[1]) not in HEADS:
        return None
    if UNSAFE_IN_SEGMENT.search(cmd[s:e]):
        return None
    flags = "".join("-e %s " % n for n in dict.fromkeys(names))
    return lead + env + kept + "rrun " + flags + cmd[head[0]:e]


def shell_c_script(cmd, shape, s, e):
    """The script text when the segment runs `bash|sh|zsh -c '<script>'`, else ""."""
    toks = [(m.start() + s, m.end() + s) for m in WORD_RE.finditer(shape[s:e])]
    for k in range(len(toks)):
        sc = shell_c(cmd, shape, toks, k)
        if sc:
            return cmd[sc[0]:sc[1]]
    return ""


def sets_state(masked, s, e):
    """True when segment masked[s:e] may change shell state a later `rrun` (a child process on
    another machine) would not inherit: export/declare/typeset/source, `.`, set -a/allexport,
    or a bare assignment. Quoted text is blanked in `masked`, so `echo "export"` is fine."""
    words = WORD_RE.findall(masked[s:e])
    while words and words[0] in KEYWORDS:
        words = words[1:]
    if not words:
        return False
    if words[0] == "." or STATE_WORDS.intersection(words):
        return True
    if "set" in words and any(w == "allexport" or re.match(r"^[-+][A-Za-z]*a", w) for w in words):
        return True
    return all(ASSIGN_RE.match(w) for w in words)


class Builds:
    """Decides whether a `npm run build` segment run in a given dir has mapped outputs."""

    def __init__(self, cfg, cwd):
        self.cfg, self.cwd = cfg, cwd

    def is_build(self, text):
        import rd_pool
        return bool(rd_pool.BUILD_RE.search(text))

    def mapped(self, words, cwd):
        import rd_pool
        import rd_run
        try:
            wt = rd_run.resolve_worktree(cwd)
        except Exception:
            return False
        return bool(rd_pool.outputs_for(self.cfg, wt["slug"], rd_pool.build_pkg_dir(wt["relcwd"], words)))


def seg_cwds(cmd, segs, masked, start):
    """cwd of each segment: `start`, moved by plain `cd <simple path>` segments (None = unknown)."""
    out, cur = [], start
    for s, e, _ in segs:
        out.append(cur)
        words = WORD_RE.findall(masked[s:e])
        if words and words[0] == "cd":
            raw = cmd[s:e].split()
            if cur and len(words) == 2 and len(raw) == 2 and SIMPLE_FILE_RE.fullmatch(raw[1]):
                cur = os.path.normpath(os.path.join(cur, os.path.expanduser(raw[1])))
            else:
                cur = None
    return out


def core_words(words):
    """Masked words of a segment minus leading NAME=value / wrappers and trailing redirects."""
    i = 0
    while i < len(words):
        w, b = words[i], os.path.basename(words[i])
        if ASSIGN_RE.match(w) or b in DROP_WRAPPERS:
            i += 1
        elif b in KEEP_WRAPPERS:
            i += 1
            while i < len(words) and WRAP_ARG_RE.fullmatch(words[i]):
                i += 1
        else:
            break
    out = []
    for w in words[i:]:
        if REDIR_WORD_RE.match(w):
            break
        out.append(w)
    return out


def parse_job(words):
    """core words -> {"tool": tsc|vitest|jest|eslint, "args", "prefix", "bare"} or
    {"script": name, "runner", "args", "prefix"}; None for any shape we do not fully know."""
    if not words:
        return None
    head, base = words[0], os.path.basename(words[0])
    if base in TOOLS:
        return {"tool": base, "args": words[1:], "prefix": None, "bare": "/" not in head}
    if "/" in head:
        return None
    i, prefix = 1, None
    if base == "npx":
        while i < len(words) and words[i].startswith("-"):
            w = words[i]
            if w == "--prefix" and i + 1 < len(words):
                prefix, i = words[i + 1], i + 2
            elif w.startswith("--prefix="):
                prefix, i = w[len("--prefix="):], i + 1
            elif w in NPX_SOLO:
                i += 1
            else:
                return None                                   # -p / -c / --package: not simple
        if i < len(words) and words[i] in TOOLS:
            return {"tool": words[i], "args": words[i + 1:], "prefix": prefix, "bare": False}
        return None
    if base not in ("npm", "pnpm", "yarn", "bun"):
        return None
    while i < len(words) and words[i].startswith("-"):
        w = words[i]
        if w in ("--prefix", "-C") and i + 1 < len(words) and base == "npm":
            prefix, i = words[i + 1], i + 2
        elif w.startswith("--prefix=") and base == "npm":
            prefix, i = w[len("--prefix="):], i + 1
        elif w in NPM_SOLO:
            i += 1
        else:
            return None                                       # -w / --workspace: package unclear
    if i >= len(words):
        return None
    sub, name = words[i], None
    if base == "npm" and sub in ("test", "t", "tst"):
        name, i = "test", i + 1
    elif sub in NPM_RUN or (base != "npm" and sub == "run"):
        i += 1
        while i < len(words) and words[i] in NPM_SOLO:
            i += 1
        if i < len(words) and not words[i].startswith("-"):
            name, i = words[i], i + 1
    elif base in ("pnpm", "yarn") and not sub.startswith("-"):
        name, i = sub, i + 1                                  # `pnpm typecheck` shorthand
    if name is None:
        return None
    return {"script": name, "runner": base, "args": words[i:], "prefix": prefix}


def git_top(d):
    """Nearest ancestor of d (lexically) holding a .git entry, else None."""
    d = os.path.normpath(d)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        up = os.path.dirname(d)
        if up == d:
            return None
        d = up


def nearest(start, top, names):
    """-> (dir, name) of the first of `names` found walking up from start to top, else None."""
    d = os.path.normpath(start)
    while True:
        for n in names:
            if os.path.isfile(os.path.join(d, n)):
                return d, n
        if d == top or os.path.dirname(d) == d or not d.startswith(top):
            return None
        d = os.path.dirname(d)


def script_body(pkg_dir, top, name):
    """The package.json script `name` npm would run from pkg_dir, or None when not found."""
    found = nearest(pkg_dir, top, ("package.json",))
    if not found:
        return None
    try:
        with open(os.path.join(found[0], "package.json")) as f:
            scripts = json.load(f).get("scripts")
    except (OSError, ValueError, AttributeError):
        return None
    body = scripts.get(name) if isinstance(scripts, dict) else None
    return body if isinstance(body, str) else None


def tsc_checks_only(args, cwd):
    """tsc that emits nothing: --noEmit, or every -p/-b config it names sets "noEmit": true."""
    if "--noEmit" in args:
        return True
    cfgs = []
    for k, a in enumerate(args):
        if a in ("-p", "--project"):
            if k + 1 >= len(args) or args[k + 1].startswith("-"):
                return False
            cfgs.append(args[k + 1])
        elif a in ("-b", "--build"):
            more = [x for x in args[k + 1:] if not x.startswith("-")]
            cfgs.extend(more or ["."])
    if not cfgs:
        return False                                          # plain `tsc`: emits per tsconfig
    for c in cfgs:
        p = os.path.join(cwd, os.path.expanduser(c))
        p = os.path.join(p, "tsconfig.json") if os.path.isdir(p) else p
        try:
            with open(p) as f:
                if not NOEMIT_RE.search(f.read(262144)):
                    return False
        except OSError:
            return False
    return True


def judge(words, cwd, pattern_hit):
    """Should this segment (masked words) go to rrun? pattern_hit: rr_route_patterns matched.
    -> True to route it (rewrite_segment still checks it is simple), False to leave it here."""
    if cwd is None:
        return False                                          # cwd unknown (`cd $D`)
    top = git_top(cwd)
    if top is None:
        return False                                          # rrun needs a git repo
    core = core_words(words)
    if not core or os.path.basename(core[0]) in SERVER_HEADS:
        return False
    if any(w.startswith(LONG_VETO) for w in core):
        return False
    job = parse_job(core)
    if job is None:
        return pattern_hit and not any(w in ("-w", "-u") for w in core)
    kind = job.get("tool") or "script"
    if any(w in SHORT_VETO[kind] for w in job["args"]):
        return False
    pkg = os.path.normpath(os.path.join(cwd, os.path.expanduser(job["prefix"] or ".")))
    lock = nearest(pkg, top, NPM_LOCKS + OTHER_LOCKS)
    if lock and lock[1] in OTHER_LOCKS:
        return False                                          # workers install with npm ci only
    if kind == "script":
        name = job["script"]
        if job["runner"] != "npm" or SCRIPT_VETO_RE.search(name):
            return False                                      # a worker may have no pnpm / yarn / bun
            return False
        body = script_body(pkg, top, name)
        if body is not None and BODY_VETO_RE.search(body):
            return False
        if pattern_hit:
            return True
        return bool(job["runner"] == "npm" and SCRIPT_RE.match(name) and body is not None and lock)
    tool, args = job["tool"], job["args"]
    if tool == "vitest" and (not args or args[0] != "run"):
        return False                                          # bare vitest = watch mode
    if pattern_hit:
        return True
    if job["bare"] or not lock:
        return False
    if tool == "tsc":
        return tsc_checks_only(args, cwd)
    return True


def route(cmd, patterns, depth=0, builds=None, cwd=None):
    """-> rewritten command, or None to leave it unchanged."""
    if "$(" in cmd or "`" in cmd:
        return None                                           # a substitution can hide segments
    if any(c not in " \t\n" and unicodedata.category(c) in ("Zs", "Zl", "Zp", "Cc", "Cf")
           for c in cmd):
        return None                                           # odd whitespace: words unclear
    scanned = scan(cmd)
    if scanned is None:
        return None
    segs, masked, shape = scanned
    regs = [re.compile(p) for p in patterns]
    cwds = seg_cwds(cmd, segs, masked, cwd) if cwd else [None] * len(segs)
    hits = []
    for (s, e, op), c in zip(segs, cwds):
        text = masked[s:e]
        words = WORD_RE.findall(text)
        if depth == 0 and any(r.search(shell_c_script(cmd, shape, s, e)) for r in regs):
            hits.append((s, e, op))                           # bash -c '...': judged inside
        elif any(r.search(text) for r in regs):
            if judge(words, c, True):
                hits.append((s, e, op))
        elif builds is not None and "build" in text and c and git_top(c) \
                and builds.is_build(text) and not any(w.startswith(LONG_VETO) for w in words) \
                and builds.mapped(words, c):
            hits.append((s, e, op))                           # a build rrun copies back
        elif judge(words, c, False):
            hits.append((s, e, op))
    if not hits:
        return None
    if any(sets_state(masked, s, e) for s, e, _ in segs if s < hits[-1][0]):
        return None                                           # earlier state would not reach the mini
    out = cmd
    for s, e, op in reversed(hits):
        new = rewrite_segment(cmd, shape, s, e, op, patterns, depth, builds, cwd)
        if new is None:
            return None                                       # unsure about one -> touch none
        out = out[:s] + new + out[e:]
    return out


def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input") or {}
        cmd = tool_input.get("command")
    except Exception:
        return
    if data.get("tool_name") != "Bash" or not isinstance(cmd, str) or not cmd.strip():
        return
    if any(m in cmd for m in SKIP_MARKERS) or os.environ.get("RRUN_REMOTE"):
        return
    h = home()
    rrun_real = rrun_installed(h)
    if not rrun_real:
        return
    user = None
    if not any(t in cmd for t in PREFILTER):
        user = user_cfg(h)
        if "rr_route_patterns" not in user:
            return
    cfg = load_cfg(rrun_real, user_cfg(h) if user is None else user)
    if os.path.isdir(os.path.join(h, cfg.get("rr_root") or "rr", "git")):
        return                                                # this is the mini
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) and data.get("cwd") else os.getcwd()
    new = route(cmd, cfg.get("rr_route_patterns") or [], builds=Builds(cfg, cwd), cwd=cwd)
    if not new or new == cmd:
        return
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": {**tool_input, "command": new},
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
