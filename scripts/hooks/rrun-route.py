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
    or -p/-b configs that all set "noEmit": true; `npx vitest run ...` (also `npm exec ...`); `npx jest ...`;
    `npx eslint ...`; `./node_modules/.bin/<tool>` the same, and an absolute
    `/.../node_modules/.bin/<tool>` inside the worktree (rewritten relative to the cwd: the laptop path
    does not exist on the worker; only for a node_modules rrun installs there - worker_tool_path); `npm test` / `npm run test*` /
    `typecheck*` / `type-check*` / `lint*` when package.json defines the script. Only when the
    segment's cwd is in a git repo and the nearest lockfile is npm's (workers run `npm ci`) or
    pnpm's (judge_pnpm below); no yarn / bun, and no bare `tsc` in an npm project - a worker's
    PATH has no node_modules/.bin.
  * pnpm workspaces (2026-11-12; workers install them with `pnpm install --frozen-lockfile` through
    corepack): `pnpm [-r | --filter X | -C dir] <test*|typecheck*|lint*>` (also `pnpm run x`,
    `pnpm test:hammer`, a root script that fans out), `pnpm [--filter X] exec <tsc|vitest|jest|eslint>`,
    `npx <tool>` / `npm test` in a workspace package, and a bare `vitest run` / `tsc --noEmit` there
    (rewritten to `rrun pnpm exec vitest run ...`). Every script / tool the command reaches
    (rd_pnpm.walk) must pass the same vetoes as npm's; anything rd_pnpm cannot read stays here.
    rrun itself picks the lane (a hammer test gets its run-local Postgres; rd_pnpm.pg_lane).
  * Never offloaded, pattern hit or not: watch / UI / dev-server / write-back runs (--watch*, -w,
    --ui, --coverage, --fix, -u/--update, --outputFile, --outDir, --open, --inspect, --stdin,
    bare `vitest`, vite / next / nodemon heads), script names with dev / start / serve / preview /
    watch / e2e / playwright / browser / ui / fix / format / update / coverage / install..., a
    script BODY that watches, serves or writes (package.json is read), a pnpm / yarn / bun lockfile,
    an unknown cwd (`cd $D`) or no git repo. Such a segment is simply left alone.
  * Segment-safe: splits on unquoted && || ; | & and newlines with a quote/comment-aware
    scanner. A matching segment is rewritten only when the match is in unquoted text, its head is
    a node package runner (npm/node/npx/pnpm/yarn/bun) after plain NAME=value assignments, it is
    not a pipe target, and it has no parens / braces / input redirect. A $(...) / backtick is opaque
    text (scan / subst_end); when the command is routed, every one must sit after a segment's head
    and match subst_ok's exact grammar (git diff --name-only / git ls-files / find <relative dirs>,
    piped only into grep / head / tail / sort / uniq; no $, ~, .., absolute path): it expands here
    before rrun. Any word naming this Mac (localhost...) or --inspect anywhere, or a command over
    8 KB, leaves it alone. One that cannot be
    bounded, sits inside "...", or in an unquoted heredoc body, an unbalanced quote, or ANY matching
    segment that is not safe, leaves the whole command alone.
  * Heredocs (`<<W`, `<<'W'`, `<<"W"`, `<<-W`): the body, through its terminator line, is opaque
    text in no segment (the `<<W` segment is never rewritten: `<` is an input redirect), so `npx
    vitest run` in a body is never routed; later segments, also ones after `<<W` on its own line
    (`cat > f <<E && npx vitest run f`), are judged as usual and a `cd` before still moves them.
    Not certain -> the whole command is left alone: `<<<`, a delimiter with $ / backtick / partial
    quoting, no terminator line, two heredocs on one line, a multi-line quote or a line
    continuation between `<<W` and the body.
  * Leading NAME=value assignments stay where they are (an env prefix, so values never enter
    rrun's argv) and each non-RRUN_/RDOCKER_ name gets `rrun -e NAME`, which forwards the value
    from rrun's own environment: `FOO=1 npm run test:db` -> `FOO=1 rrun -e FOO npm run test:db`.
    RDOCKER_MODE=local is dropped; RRUN_* / RDOCKER_* only configure the laptop side. A value
    must match [A-Za-z0-9_./:@%+,=-]* (no globs, ~, $, quotes...), else the command is left alone.
  * Words split only on space/tab: any other whitespace or invisible format char (\\v \\f \\r,
    NBSP, U+2000.., U+200B, ...) leaves the command alone. So does shell state set by an EARLIER
    segment that would not reach the mini: export, declare/typeset, set -a / allexport /
    setopt allexport, source / `.`, an array assignment (`a=(...)`), or a bare assignment to a
    name that is already exported (in the hook's own environment, any case) or shell-special
    (IFS, CDPATH, zsh's path/fpath...): `PATH=/x; npm test`. A bare assignment to any other name
    is shell-local - no child sees it, here or through rrun, and `$NAME` expands locally before
    rrun runs - so `SP=/tmp/x && npx vitest run a` routes the vitest part.
    Forwarded instead (forwarded(), 2026-11-13): an earlier `export A=b` / `export A` and `source f`
    / `. f` whose file holds only `[export ]NAME=value` lines ($-free values), with `set -a` / `set +a`:
    each exported name gets `rrun -e NAME`; PATH / HOME / DYLD_* ... never (left alone). A value
    naming this Mac (localhost, 127.0.0.1, 0.0.0.0, [::1], host.docker.internal) in a prefix, an
    export or a sourced file leaves the command alone: a worker cannot reach it.
  * Builds: a `npm run build` segment (rd_pool.BUILD_RE) is routed only when its package dir is
    mapped in rr_outputs (rd_pool.outputs_for: repo name -> package dir -> output dirs), so rrun
    can copy the outputs back. The dir = the hook's cwd, moved by earlier plain `cd <dir>`
    segments, plus `--prefix X`; the repo comes from git there. Unmapped builds stay untouched.
  * `node [--max-old-space-size=N] <file.mjs>` routes when a check / lint / typecheck / verify / test
    package.json script runs exactly that file (node_check_script); check* / verify* script NAMES
    are vetoed like every script, except an exact CHECKER_ALLOW name whose body is exactly `node
    scripts/check-<x>.mjs`; a checker BODY may not --inspect / c8 / nyc / --coverage / --update / -u /
    --watch / set any VAR=. A script whose name or body builds, runs one that does, or holds a runner
    call script_builds cannot follow past its flags, only ever meets the build rule. Any body with
    -u / --update / UPDATE_*= / *SNAPSHOT*= stays here.
  * Decision log: one JSON line per heavy-looking command (HEAVY_LOOK_RE) in
    <RDOCKER_HOME or ~>/.local/state/rdocker/hook.log: time, session id, routed / local / skipped,
    a reason code, cwd, the redacted command (redact()). 0600, rotated at 5 MB, never raises.
  * Returns ONLY updatedInput (never a permission decision), so normal permission prompts still
    apply to the rewritten command. Every other tool_input key is preserved.
  * FAILS OPEN: any parse error or unexpected input -> exit 0 with no output (call unchanged).
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time
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
# a heredoc we fully understand: <<W / <<'W' / <<"W" / <<-W, W plain, then a word end
HEREDOC_RE = re.compile(r"<<(-?)[ \t]*(?:'([A-Za-z0-9_.-]+)'|\"([A-Za-z0-9_.-]+)\"|([A-Za-z0-9_.-]+))"
                        r"(?=[ \t\n>;&|]|$)")
# NAME=, NAME+=, NAME[i]= : any assignment form, for the earlier-shell-state check
ASSIGNISH_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?=(.*)$", re.S)
# names whose plain (unexported) assignment still changes how the local shell runs later words:
# word splitting, `cd` lookup, zsh's tied arrays (path=(...) rewrites the exported PATH)
SHELL_SPECIAL = {"IFS", "CDPATH", "cdpath", "path", "fpath", "manpath", "module_path"}

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
                            r"|ui|fix|format|fmt|update|snapshots?|snap|coverage|cov|debug|inspect|open"
                            r"|storybook|install|i|ci|add|remove|rm|uninstall|up|upgrade|link|exec"
                            r"|dlx|create|init)([:._-]|$)")
# The name veto applies to EVERY script. A dentall checker whose name only looks like a write run
# (`check:update-record`, `check:*-coverage`, `check:ci-*`, `check:patient-link-*`) is exempt only
# when it is in this exact list AND its body is exactly `node scripts/check-<x>.mjs`.
CHECKER_ALLOW = {
    "check:ai-tab-coverage", "check:care-hold-coverage", "check:ci-entrypoints", "check:ci-entrypoints:self-test",
    "check:ci-split", "check:csrf-coverage", "check:patient-create-chokepoint",
    "check:patient-create-chokepoint:self-test", "check:patient-link-bundle", "check:patient-link-bundle:self-test",
    "check:patient-link-origins", "check:rls-coverage", "check:tenant-context-coverage", "check:update-record",
    "check:upload-scan-coverage", "check:workflow-test-coverage"}
CHECKER_BODY_RE = re.compile(r"node scripts/check-[A-Za-z0-9._-]+\.mjs")         # fullmatch
CHECKER_NAME_RE = re.compile(r"^(check|verify|lint|typecheck|type-check)([:._-]|$)")
# a checker's body (and a `node` script's npm body) must not attach a debugger, measure coverage,
# update, watch, or set ANY variable first
CHECKER_BODY_VETO_RE = re.compile(r"--inspect|(^|[\s;&|(])(c8|nyc)(\s|$)|--coverage|--update|(^|\s)-u(\s|$)"
                                  r"|--watch|(^|[\s;&|(])[A-Za-z_][A-Za-z0-9_]*=")
BUILDS_RE = re.compile(r"build", re.I)                    # a script name / body that builds: build rule only
RUNNERS = {"npm", "pnpm", "npx", "yarn", "bun", "pnpx", "corepack"}
RUNNER_VALUE_FLAGS = {"--prefix", "-C", "--dir", "--filter", "-F", "-w", "--workspace", "--cwd"}
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
# a word naming this Mac: localhost, the whole 127.0.0.0/8 (also short forms 127.1, 127.0.1), 0.0.0.0,
# ::1 / [::1], host.docker.internal, and `0` as a host (http://0:3000, 0:3000, --host 0, HOST=0)
LOCAL_PAT = (r"(?i)localhost|host\.docker\.internal|::1"
             r"|(?<![\w.])127(?:\.[0-9]{1,3}){1,3}(?![\w.])|(?<![\w.])0\.0\.0\.0(?![\w.])"
             r"|://0(?=[:/\s'\"]|$)|(?<![\w.:/-])0:[0-9]{1,5}(?![0-9])"
             r"|(?:--host(?:name)?|--bind|\bHOST|\bHOSTNAME)(?:=|\s+)0(?![\w.])")
LOCAL_URL_RE = re.compile(LOCAL_PAT)
# any script body (test scripts included): writes snapshots / records, watches, serves, names this Mac
BODY_VETO_RE = re.compile(LOCAL_PAT + r"|(?:^|[\s;&|(])(?:UPDATE_\w*|\w*SNAPSHOT\w*)="
                          r"|--watch|--ui\b|--fix\b|--write\b|--update|--coverage|--outputFile|--output-file"
                          r"|--outDir|--open\b|(^|\s)-[wu](\s|$)|e2e|browser|playwright|cypress"
                          r"|(^|[\s;&|(/])(vite|next|nuxt|astro|nodemon|concurrently|webpack-dev-server"
                          r"|storybook|start-storybook|http-server|live-server|serve)(\s|$|[;&|)])")
REDIR_WORD_RE = re.compile(r"^[0-9]*(&?>>?|>&|<)")
BUILD_SHORT_VETO = {"-w", "-u", "-o"}                         # a mapped build: watch / update / output stays here
PNPM_LOCK = "pnpm-lock.yaml"
NPM_LOCKS = ("package-lock.json", "npm-shrinkwrap.json")
OTHER_LOCKS = ("pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock")
NOEMIT_RE = re.compile(r'"noEmit"\s*:\s*true')

# ---- gaps closed 2026-11-13 (tmp/research/2026-11-13-local-compute-leaks.md) ----------------------
# A $(...) / `...` is opaque text. When the command is routed, every substitution must match
# subst_ok's exact grammar (relative file lists only: it expands here, before rrun, and a laptop
# absolute path does not exist on the worker).
# names an `export` / sourced file may not forward: they reshape the worker's own shell or paths
FORWARD_DENY = {"PATH", "HOME", "PWD", "OLDPWD", "SHELL", "USER", "LOGNAME", "TMPDIR", "TERM", "BASH_ENV",
                "ENV", "ZDOTDIR", "NODE_PATH", "NODE_OPTIONS"} | SHELL_SPECIAL
FORWARD_DENY_PREFIX = ("DYLD_", "LD_", "RRUN_", "RDOCKER_")
SRC_LINE_RE = re.compile(r"^(export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
SRC_VALUE_RE = re.compile(r"[A-Za-z0-9_./:@%+,=-]*|'[^'\n]*'|\"[^\"$`\\\n]*\"")
# a value naming this Mac (a DB on a mirrored port, a local dev server) means nothing on a worker:
# such a command stays here (2026-11-13: agents typed RRUN=0 by hand for exactly these)
INSPECT_RE = re.compile(r"--inspect")                    # a debugger attach: this Mac's, never a worker's
# a sourced file is forwarded only when it is not an env file and names no secret: values of these
# would otherwise be copied into a worker's environment
SECRET_NAME_RE = re.compile(r"(?i)(TOKEN|SECRET|KEY|PASSWORD|PASS|AUTH|CREDENTIAL|DATABASE_URL|^PG)")
MAX_CMD = 8192                                           # longer: left alone before any regex runs
# `node <script>` routes only when a check / lint / typecheck / verify / test npm script of this repo
# runs exactly that file (the npm form already routes by category: rr_route_patterns)
NODE_SCRIPT_RE = re.compile(r"(\.\.?/)*[A-Za-z0-9_][A-Za-z0-9_./-]*\.(mjs|cjs|js)")
CHECK_SCRIPT_RE = re.compile(r"^(check|lint|typecheck|type-check|verify|test)([:._-][\w:.-]*)?$")
NODE_FLAG_RE = re.compile(r"--max-old-space-size=[0-9]+")

# ---- decision log: one JSON line per heavy-looking command (routed / local / skipped + why) ----------
HOOK_LOG_MAX = 5 * 1024 * 1024
HEAVY_LOOK_RE = re.compile(
    r"(^|[\s;&|(/])(tsc|vitest|jest|eslint)(\s|$)|test:db|run-guard-tier|test-with-db"
    r"|\b(npm|pnpm|yarn|bun)\b[^\n;&|]*?\s(test|t|typecheck|type-check|lint|check|verify|build)([:\s]|$)"
    r"|\b(npm|pnpm|yarn|bun)\b[^\n;&|]*?\srun\s+(-\S+\s+)*(test|typecheck|type-check|lint|check|verify|build)"
    r"|\bnode\b[^\n;&|]*?\s\S*(check|guard|selftest|verify)\S*\.[mc]?js")
# rd_run.short_argv's userinfo rule, widened: userinfo may hold `/` (a password)
URL_USERINFO_RE = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*://)[^\s@'\"]*@")
ASSIGN_VALUE_RE = re.compile(r"(^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"]*\"|'[^']*'|\S*)")
AUTH_RE = re.compile(r"(?i)(authorization:\s*(bearer\s+|basic\s+)?|bearer\s+|token[=:]\s*)[^\s'\"]+")
SECRET_FLAG_RE = re.compile(r"(?i)(--(?:password|passwd|api-key|apikey|token|secret|access-token)(?:=|\s+))"
                            r"(\"[^\"]*\"|'[^']*'|\S+)")
HEADER_RE = re.compile(r"(?i)((?:-H|--header)\s*[\"']?[^\"'\n:]*(?:key|authorization|token|cookie|secret)"
                       r"[^\"'\n:]*:\s*)[^\"'\n]*")
CURL_USER_RE = re.compile(r"((?:^|\s)(?:-u|--user)(?:=|\s+))([^\s:]+):\S+")


def why_no(why, code, value=None):
    """Record the first reason a command stays here (the decision log), return `value`."""
    if why is not None and not why:
        why.append(code)
    return value


def redact(cmd, limit=300):
    """The command as logged: only the first line when it carries a heredoc (a body may hold
    anything); URL userinfo, every NAME=value value, auth tokens and headers, --password / --api-key /
    --token values and `curl -u user:pw` blanked; then truncated."""
    if "<<" in cmd and "\n" in cmd:
        cmd = cmd.split("\n", 1)[0] + " [heredoc body not logged]"
    s = URL_USERINFO_RE.sub(r"\1****@", cmd)
    s = HEADER_RE.sub(lambda m: m.group(1) + "****", s)
    s = SECRET_FLAG_RE.sub(lambda m: m.group(1) + "****", s)
    s = CURL_USER_RE.sub(lambda m: m.group(1) + m.group(2) + ":****", s)
    s = ASSIGN_VALUE_RE.sub(lambda m: "%s%s=****" % (m.group(1), m.group(2)), s)
    s = AUTH_RE.sub(lambda m: m.group(1) + "****", s)
    return s if len(s) <= limit else s[:limit - 3] + "..."


def log_decision(h, sid, decision, why, cmd, cwd=None):
    """Append one line to <home>/.local/state/rdocker/hook.log (RDOCKER_HOME honoured, like every
    other rdocker state file); rotated to hook.log.1 past ~5 MB. Never raises: a log that cannot be
    written must not change or block the command."""
    try:
        d = os.path.join(h, ".local", "state", "rdocker")
        p = os.path.join(d, "hook.log")
        os.makedirs(d, exist_ok=True)
        try:
            if os.path.getsize(p) > HOOK_LOG_MAX:
                os.replace(p, p + ".1")
        except OSError:
            pass
        line = json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "sid": (sid or "")[:64],
                           "d": decision, "why": why, "cwd": cwd or "", "cmd": redact(cmd)})
        fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, (line + "\n").encode("utf-8", "replace"))
        finally:
            os.close(fd)
    except Exception:
        pass


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
    """-> (segments, masked, shape, subs) or None when the quoting is unbalanced or a heredoc or a
    substitution is not certain. segments: [(start, end, op_before)]; masked: cmd with quoted/escaped
    text, comments, heredoc bodies and $(...) / `...` blanked; shape: the same but quoted, escaped
    and substituted text kept as non-space, so words split where the shell splits them; subs: the
    [(start, end)] of every substitution. All have cmd's length, so indexes line up with the original.
    A heredoc (`<<W`, `<<'W'`, `<<"W"`, `<<-W`) is opaque: its body, through the terminator line,
    belongs to no segment; the segment holding `<<W` (whose `<` vetoes a rewrite) ends at the line
    end, and more commands may follow `<<W` on its own line (`cat > f <<E && npx vitest run f`).
    Unsure -> None: `<<<`, an odd delimiter ($, backtick, partly quoted...), no terminator line, a
    second heredoc or a multi-line quote / line continuation before the body, a substitution in an
    unquoted heredoc body or inside double quotes, or one subst_end() cannot bound."""
    segs, masked, shape, subs = [], list(cmd), list(cmd), []
    i, n, start, op = 0, len(cmd), 0, ""
    word_start = True
    pending = None                                            # (delimiter, strip_tabs, quoted) awaiting its body
    while i < n:
        c = cmd[i]
        if c == "\n" and pending:
            end = heredoc_end(cmd, i + 1, pending[0], pending[1])
            if end is None:
                return None                                   # no terminator line: unsure
            if not pending[2] and ("$(" in cmd[i:end] or "`" in cmd[i:end]):
                return None                                   # expands here: may hide segments
            segs.append((start, i, op))
            for k in range(i, end):
                masked[k], shape[k] = " ", " "
            i, start, op, pending, word_start = end, end, "\n", None, True   # cmd[end]: the newline after it
            continue
        if c == "\\":
            if pending and cmd[i + 1:i + 2] == "\n":
                return None                                   # continuation before the body
            for k in range(i, min(i + 2, n)):
                masked[k], shape[k] = " ", "Q"
            i += 2
            word_start = False
            continue
        if c in "'\"":
            j = i + 1
            while j < n and cmd[j] != c:
                j += 2 if (c == '"' and cmd[j] == "\\") else 1
            if j >= n or (pending and "\n" in cmd[i:j]):
                return None                                   # unbalanced / spans the body
            if c == '"' and ("$(" in cmd[i:j] or "`" in cmd[i:j]):
                return None                                   # a substitution inside "...": not judged
            for k in range(i, j + 1):
                masked[k], shape[k] = " ", "Q"
            i = j + 1
            word_start = False
            continue
        if cmd.startswith("$(", i) or c == "`":
            j = subst_end(cmd, i)
            if j is None:
                return None
            subs.append((i, j))
            for k in range(i, j):
                masked[k], shape[k] = " ", "Q"
            i, word_start = j, False
            continue
        if c == "#" and word_start:
            j = cmd.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                masked[k], shape[k] = " ", " "
            i = j
            continue
        if c == "<" and cmd.startswith("<<", i):
            m = HEREDOC_RE.match(cmd, i)
            if pending or not m:
                return None                                   # <<<, two heredocs, odd delimiter
            pending = (m.group(2) or m.group(3) or m.group(4), m.group(1) == "-", m.group(4) is None)
            for k in range(m.end(1), m.end()):
                masked[k], shape[k] = (" ", " ") if cmd[k] in " \t" else (" ", "Q")
            i, word_start = m.end(), False
            continue
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
    if pending:
        return None                                           # heredoc with no body at all
    segs.append((start, n, op))
    return segs, "".join(masked), "".join(shape), subs


def subst_end(cmd, i):
    """Index just past the $(...) or `...` starting at cmd[i], else None when it is not plainly
    bounded: a backtick body with quotes, parens, $( or a backslash; inside $( ): a heredoc, a
    comment, a `case` (its `x)` breaks paren counting), a backtick, or a "..." holding $( / `."""
    n = len(cmd)
    if cmd[i] == "`":
        j = cmd.find("`", i + 1)
        if j == -1 or re.search(r"[\\\"'()#\n]|\$\(", re.sub(r"'[^'\n`]*'", "", cmd[i + 1:j])):
            return None
        return j + 1
    depth, j = 1, i + 2
    while j < n:
        c = cmd[j]
        if c == "'":
            k = cmd.find("'", j + 1)
            if k == -1:
                return None
            j = k + 1
            continue
        if c == '"':
            k = j + 1
            while k < n and cmd[k] != '"':
                k += 2 if cmd[k] == "\\" else 1
            if k >= n or "$(" in cmd[j:k] or "`" in cmd[j:k]:
                return None
            j = k + 1
            continue
        if c in "`#" or cmd.startswith("<<", j) or (re.match(r"case\b", cmd[j:]) and cmd[j - 1] in " \t;(|&"):
            return None
        if c == "\\":
            j += 2
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return None


def subst_ok(text):
    """A substitution whose output may go to rrun (it expands here, before rrun runs) - an exact
    grammar, everything else leaves the command alone:
      git diff --name-only [refs / paths] | git ls-files [patterns] | find <relative dirs> [-name|-path|-type X]...
    optionally piped only into grep [-v|-E|-F]... <pattern>, head [-n N|-N], tail [-n N|-N], sort [-u], uniq.
    Never: $ (a variable can hold a laptop path), backtick, ~, .., an absolute path (also quoted),
    any other command (sed / awk / cat / xargs ...), operators or redirects."""
    body = text[2:-1] if text.startswith("$(") else text[1:-1]
    if re.search(r"[$`~\\\n]|\.\.", body):
        return False
    try:
        lex = shlex.shlex(body, posix=True, punctuation_chars="|;&<>()")
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        return False
    parts, cur = [], []
    for t in toks:
        if t == "|":
            parts.append(cur)
            cur = []
        elif t and t[0] in ";&<>()" and set(t) <= set(";&<>()|"):
            return False
        else:
            cur.append(t)
    parts.append(cur)
    if any(not p for p in parts) or any(t.startswith("/") for p in parts for t in p):
        return False
    first = parts[0]
    if first[:3] == ["git", "diff", "--name-only"]:
        rest = first[3:]
        ok = all(t == "--" or not t.startswith("-") for t in rest)
    elif first[:2] == ["git", "ls-files"]:
        ok = all(not t.startswith("-") for t in first[2:])
    elif first[0] == "find":
        k, ok = 1, True
        while k < len(first) and not first[k].startswith("-"):
            k += 1
        if k == 1:
            ok = False                                        # find needs a relative start dir
        while ok and k < len(first):
            ok = first[k] in ("-name", "-path", "-type") and k + 1 < len(first)
            k += 2
    else:
        ok = False
    for p in parts[1:]:
        if not ok:
            break
        head, args = p[0], p[1:]
        if head == "grep":
            flags = [t for t in args if t.startswith("-")]
            ok = len(args) - len(flags) == 1 and not args[-1].startswith("-") \
                and all(f in ("-v", "-E", "-F") for f in flags)
        elif head in ("head", "tail"):
            ok = args in ([],) or (len(args) == 1 and re.fullmatch(r"-[0-9]+", args[0]) is not None) \
                or (len(args) == 2 and args[0] == "-n" and args[1].isdigit())
        elif head == "sort":
            ok = args in ([], ["-u"])
        elif head == "uniq":
            ok = args == []
        else:
            ok = False
    return ok


def heredoc_end(cmd, pos, delim, strip_tabs):
    """Index just past the terminator line of a heredoc body starting at pos, else None."""
    n = len(cmd)
    while pos < n:
        eol = cmd.find("\n", pos)
        eol = n if eol == -1 else eol
        line = cmd[pos:eol]
        if (line.lstrip("\t") if strip_tabs else line) == delim:
            return eol
        pos = eol + 1
    return None


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


def rewrite_segment(cmd, shape, s, e, op, patterns=None, depth=0, builds=None, cwd=None, seg_cwd=None,
                    subs=(), fwd=(), why=None):
    """-> replacement text for cmd[s:e], or None when the segment is not fully understood. subs: the
    command's substitution spans (allowed only after the head); fwd: names an earlier export /
    source exported, forwarded as `rrun -e NAME` like a NAME=value prefix."""
    if op in ("|", "|&"):
        return why_no(why, "pipe-target")
    toks = [(m.start() + s, m.end() + s) for m in WORD_RE.finditer(shape[s:e])]
    front, names, head, wraps = [], [], None, []
    k = 0
    while k < len(toks):
        ts, te = toks[k]
        word = cmd[ts:te]
        if shape[ts:te] != word:                              # quoting in env/head: not simple
            if head is None and wraps is not None:
                break                                         # maybe `bash -c '...'`: checked below
            return why_no(why, "unsure-segment")
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
                    return why_no(why, "unsure-segment")      # e.g. `timeout` with no duration
                wraps.append((True, cmd[ts:toks[j - 1][1]]))
                k = j
                continue
            head = (ts, word)
            break
        if not VALUE_RE.fullmatch(m.group(2)):
            return why_no(why, "env-value")                   # glob, ~, $, ... : not simple
        if forward_name(m.group(1)) is None:
            return why_no(why, "env-deny")                    # PATH / HOME / NODE_OPTIONS ...: not forwarded
        k += 1
        if word == "RDOCKER_MODE=local":
            continue
        front.append(word)
        if not m.group(1).startswith(("RRUN_", "RDOCKER_")):
            names.append(m.group(1))
    if not toks:
        return why_no(why, "unsure-segment")
    lead = cmd[s:toks[0][0]]
    env = "".join(w + " " for w in front)
    kept = "".join(w + " " for keep, w in wraps if keep)
    sc = shell_c(cmd, shape, toks, k) if depth == 0 and patterns is not None else None
    if sc:                                                    # bash -c '<script>': rewrite inside
        inner = route(cmd[sc[0]:sc[1]], patterns, depth + 1, builds, cwd, why)
        if inner is None:
            return None
        allw = "".join(w + " " for _, w in wraps)            # heavy-slot still gates the laptop part
        return lead + env + allw + cmd[toks[k][0]:sc[0]] + inner + cmd[sc[1]:e]
    if head is None or os.path.basename(head[1]) not in HEADS:
        return why_no(why, "head")
    text = list(cmd[s:e])
    for a, b in subs:
        if s <= a < e:
            if a < head[0] + len(head[1]):
                return why_no(why, "subst-head")              # a substitution before the arguments
            text[a - s:b - s] = " " * (b - a)                 # its text is opaque, expands here
    if UNSAFE_IN_SEGMENT.search("".join(text)):
        return why_no(why, "unsafe-segment")
    flags = "".join("-e %s " % n for n in dict.fromkeys(list(fwd) + names))
    tail = cmd[head[0]:e]
    if head[1] in TOOLS and seg_cwd and pnpm_root(seg_cwd, git_top(seg_cwd)):
        tail = "pnpm exec " + tail                            # a worker's PATH has no node_modules/.bin
    if os.path.isabs(head[1]):                                # /abs/.../node_modules/.bin/<tool>
        top = git_top(seg_cwd) if seg_cwd else None
        tool = worker_tool_path(head[1], seg_cwd, top) if top else None
        if tool is None:
            return why_no(why, "bin-path")
        tail = tool + cmd[head[0] + len(head[1]):e]
    return lead + env + kept + "rrun " + flags + tail


def shell_c_script(cmd, shape, s, e):
    """The script text when the segment runs `bash|sh|zsh -c '<script>'`, else ""."""
    toks = [(m.start() + s, m.end() + s) for m in WORD_RE.finditer(shape[s:e])]
    for k in range(len(toks)):
        sc = shell_c(cmd, shape, toks, k)
        if sc:
            return cmd[sc[0]:sc[1]]
    return ""


def exported(name):
    """True when a bare `name=value` could change what a child process (local or via rrun) sees,
    or how the local shell reads later words: name is already exported (in the hook's own
    environment, inherited from the same parent as the Bash tool's shell; any case, for zsh's
    tied path/PATH pairs) or is a shell-special name."""
    return name in os.environ or name.upper() in os.environ or name in SHELL_SPECIAL


def sets_state(masked, s, e):
    """True when segment masked[s:e] may change shell state a later `rrun` (a child process on
    another machine) would not inherit: export/declare/typeset/source, `.`, set -a/allexport
    (also zsh's setopt allexport / all_export), or a bare assignment to an already-exported or
    shell-special name. A bare assignment to any other name is shell-local: no child sees it,
    here or through rrun, and `$NAME` expands in the local shell before rrun runs. Quoted text
    is blanked in `masked`, so `echo "export"` is fine."""
    words = WORD_RE.findall(masked[s:e])
    while words and words[0] in KEYWORDS:
        words = words[1:]
    if not words:
        return False
    if words[0] == "." or STATE_WORDS.intersection(words):
        return True
    if "set" in words and any(w == "allexport" or re.match(r"^[-+][A-Za-z]*a", w) for w in words):
        return True
    if "setopt" in words and any(w.lower().replace("_", "") in ("allexport", "a") for w in words):
        return True
    first = ASSIGNISH_RE.match(words[0])
    if first and first.group(3).startswith("("):
        return True                                           # array assignment: not judged
    if all(ASSIGNISH_RE.match(w) for w in words):
        return any(exported(ASSIGNISH_RE.match(w).group(1)) for w in words)
    return False


def forward_name(name):
    """-> True to forward an exported name, False to skip it (RRUN_* / RDOCKER_* configure this
    side), None when it must not reach a worker at all (PATH, HOME, DYLD_*...)."""
    if name == "RRUN" or name.startswith(("RRUN_", "RDOCKER_")):
        return False
    if name in FORWARD_DENY or name.startswith(FORWARD_DENY_PREFIX):
        return None
    return True


def export_names(cmd, masked, s, e, subs, why):
    """`export A=b [C ...]` -> the names it exports, or None (flags, odd words, a denied name, a
    value naming this Mac). Quoted / substituted values are fine: rrun -e reads the exported value."""
    words = WORD_RE.findall(masked[s:e])[1:]
    dec = decoded(cmd, s, e, subs)[0]
    if not words or dec is None:
        return why_no(why, "state")
    names = []
    for w in words:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)(=.*)?$", w)
        if not m:
            return why_no(why, "state")
        ok = forward_name(m.group(1))
        if ok is None:
            return why_no(why, "state")
        if ok:
            names.append(m.group(1))
    return names


def source_names(cmd, masked, s, e, cwd, allexport, why):
    """`source f` / `. f` -> the names the file exports, read now: it may hold only blank lines,
    comments and `[export ]NAME=value` lines with a plain or quoted ($-free) value. A plain
    assignment exports only under `set -a` or for an already-exported name. None when unsure: an
    unknown cwd, a missing / large file, any other line, a denied name, a localhost value, or the
    file's name in an earlier segment (it may be written first, so its content now is not certain)."""
    words, raw = WORD_RE.findall(masked[s:e]), cmd[s:e].split()
    if len(words) != 2 or len(raw) != 2 or not SIMPLE_FILE_RE.fullmatch(raw[1]) or not cwd:
        return why_no(why, "state")
    path = os.path.normpath(os.path.join(cwd, os.path.expanduser(raw[1])))
    if os.path.basename(path) in cmd[:s] or os.path.basename(path).startswith(".env"):
        return why_no(why, "state")                           # may be written first / an env file: secrets
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > 65536:
            return why_no(why, "state")
        with open(path, errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return why_no(why, "state")
    names = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = SRC_LINE_RE.match(line)
        if not m or not SRC_VALUE_RE.fullmatch(m.group(3)):
            return why_no(why, "state")
        ok = forward_name(m.group(2))
        if ok is None:
            return why_no(why, "state")
        if LOCAL_URL_RE.search(m.group(3)) or INSPECT_RE.search(m.group(3)):
            return why_no(why, "local-url" if LOCAL_URL_RE.search(m.group(3)) else "inspect")
        if ok and (m.group(1) or allexport or exported(m.group(2))):
            if SECRET_NAME_RE.search(m.group(2)):
                return why_no(why, "state-secret")            # never copy a secret's value to a worker
            names.append(m.group(2))
    return names


def forwarded(cmd, masked, segs, cwds, subs, upto, why=None):
    """-> for each segment, the names exported by EARLIER segments (`export A=b`, `source f`, with
    `set -a` / `set +a`), which rrun forwards with -e; None when an earlier segment (before `upto`)
    sets shell state a remote rrun would not see and we cannot forward (sets_state)."""
    out, names, allexport = [], [], False
    for (s, e, _), c in zip(segs, cwds):
        out.append(list(names))
        if s >= upto:
            continue
        words = WORD_RE.findall(masked[s:e])
        got = []
        if not words:
            continue
        if words[0] == "export":
            got = export_names(cmd, masked, s, e, subs, why)
        elif words[0] in ("source", "."):
            got = source_names(cmd, masked, s, e, c, allexport, why)
        elif words in (["set", "-a"], ["set", "+a"]):
            allexport = words[1] == "-a"
        elif sets_state(masked, s, e) or (allexport and ASSIGNISH_RE.match(words[0])):
            return why_no(why, "state")
        if got is None:
            return None
        names.extend(n for n in got if n not in names)
    return out


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


def strip_redirects(words):
    """Words up to the first redirect (what the command itself receives)."""
    out = []
    for w in words:
        if REDIR_WORD_RE.match(w):
            break
        out.append(w)
    return out


SUB_WORD = "__rrun_subst__"


def decoded(cmd, s, e, subs=()):
    """-> (the segment's shell-decoded words, had quoting) or (None, True): heredoc segments and
    anything shlex cannot split are never judged. A substitution decodes as one opaque word
    (SUB_WORD) and counts as quoting."""
    text = cmd[s:e]
    inner = [(a, b) for a, b in subs if s <= a < e]
    for a, b in reversed(inner):
        text = text[:a - s] + SUB_WORD + text[b - s:]
    if "<<" in text:
        return None, True
    try:
        words = shlex.split(text, comments=False)             # the scanner owns comments: an in-word `#`
                                                              # (case#tag --update) must not swallow the rest
    except ValueError:
        return None, True
    return words, bool(inner) or bool(re.search(r"['\"\\]", text))


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
    if base == "npm" and sub in ("exec", "x"):              # `npm exec vitest run` == `npx vitest run`
        j = i + 1
        if j < len(words) and words[j] == "--":
            j += 1
        if j < len(words) and words[j] in TOOLS:
            return {"tool": words[j], "args": words[j + 1:], "prefix": prefix, "bare": False}
        return None
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


BIN_PATH_RE = re.compile(r"^(?:.*/)?node_modules/\.bin/[^/]+$")


def worker_tool_path(word, cwd, top):
    """A tool given by path (`./node_modules/.bin/tsc`, `/abs/repo/node_modules/.bin/vitest`) -> the
    word to use on the worker, or None to leave the command here. Allowed only for
    `<dir>/node_modules/.bin/<tool>` where <dir> is inside this git worktree AND is a dir whose
    packages rrun installs on the worker: the nearest npm lockfile dir at or above the cwd, or, for
    a command run at the repo root, a first-level package with its own npm lockfile. An absolute
    path becomes relative to the cwd (the worker runs it in its mirror; the laptop path does not
    exist there): /abs/repo/node_modules/.bin/tsc -> ./node_modules/.bin/tsc."""
    if not BIN_PATH_RE.match(word) or "~" in word:
        return None
    path = os.path.realpath(os.path.join(cwd, word))                  # /tmp vs /private/tmp alike
    pkg = os.path.dirname(os.path.dirname(os.path.dirname(path)))     # the dir holding node_modules
    rtop, rcwd = os.path.realpath(top), os.path.realpath(cwd)
    if pkg != rtop and not pkg.startswith(rtop + os.sep):
        return None
    lock = nearest(rcwd, rtop, NPM_LOCKS)
    own_lock = any(os.path.isfile(os.path.join(pkg, n)) for n in NPM_LOCKS)
    if not ((lock and lock[0] == pkg) or (rcwd == rtop and os.path.dirname(pkg) == rtop and own_lock)):
        return None
    if not os.path.isabs(word):
        return word
    rel = os.path.relpath(path, rcwd)
    return rel if rel.startswith("../") else "./" + rel


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


def pnpm_root(cwd, top):
    """The dir of the nearest lockfile at or above cwd when it is pnpm's, else None."""
    lock = nearest(cwd, top, NPM_LOCKS + OTHER_LOCKS) if top else None
    return lock[0] if lock and lock[1] == PNPM_LOCK else None


def judge_pnpm(dec, cwd, top):
    """A command in a pnpm workspace: routed ONLY when its decoded words, with nothing before the head
    (no NAME=value, no wrapper) and no quoting anywhere, are one of rd_pnpm.exact_form's shapes."""
    import rd_pnpm                                            # beside rd_common (load_cfg put it on sys.path)
    return bool(dec) and rd_pnpm.exact_form(cwd, dec, top) is not None


def script_vetoed(name, body):
    """True when an npm script must stay here by its NAME (SCRIPT_VETO_RE, every script; exempt only
    an exact CHECKER_ALLOW name whose body is exactly `node scripts/check-<x>.mjs`) or, for a
    checker-category name, by its BODY (CHECKER_BODY_VETO_RE)."""
    exempt = name in CHECKER_ALLOW and isinstance(body, str) and CHECKER_BODY_RE.fullmatch(body.strip())
    if SCRIPT_VETO_RE.search(name) and not exempt:
        return True
    return bool(CHECKER_NAME_RE.match(name) and isinstance(body, str) and CHECKER_BODY_VETO_RE.search(body))


def script_builds(pkg_dir, top, name, body, depth=0):
    """True when the script builds, or when we cannot be sure it does not (fail closed): its name or
    body says build, a body vetoed by BODY_VETO_RE, or a runner call in its body (npm / pnpm / yarn /
    bun / npx ...) that is not fully followed: `[flags] run|run-script [flags] <name> [args]`,
    `test` / `t`, pnpm / yarn shorthand names, or `npx [flags] <tsc|vitest|jest|eslint>` without
    `-b`. Every flag on either side of `run` is skipped (with the value of --prefix / -C / --filter
    / -w / --workspace); a script it names must exist, and is followed the same way (3 levels).
    Such a script goes through the build rule (rr_outputs) only, never a checker path."""
    if BUILDS_RE.search(name):
        return True
    if not isinstance(body, str):
        return depth > 0                                      # a nested script we cannot read: fail closed
    if BUILDS_RE.search(body) or BODY_VETO_RE.search(body):
        return True
    for seg in re.split(r"&&|\|\||[;|&\n()]", body):
        words = [w for w in seg.split() if not ASSIGN_RE.match(w)]
        while words and os.path.basename(words[0]) in DROP_WRAPPERS | set(KEEP_WRAPPERS):
            words = words[1:]
        if not words:
            continue
        if os.path.basename(words[0]) not in RUNNERS:
            if any(os.path.basename(w) in RUNNERS for w in words):
                return True                                   # a runner behind a wrapper / cross-env: not followed
            continue
        runner, i = os.path.basename(words[0]), 1

        def skip_flags(i):
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in RUNNER_VALUE_FLAGS else 1
            return i
        i = skip_flags(i)
        if i >= len(words):
            return True
        if runner in ("npx", "pnpx"):
            if words[i] not in TOOLS or any(w in ("-b", "--build") for w in words[i:]):
                return True
            continue
        if runner == "corepack":
            return True
        sub = words[i]
        if sub in ("run", "run-script") or (runner == "bun" and sub == "run"):
            i = skip_flags(i + 1)
            if i >= len(words):
                return True
            sub = words[i]
        elif sub in ("test", "t") and runner == "npm":
            sub = "test"
        elif runner == "npm" or sub in ("exec", "dlx", "x", "install", "i", "add", "ci"):
            return True                                     # npm exec / install ...: not followed
        if depth >= 3:
            return True
        sub_body = script_body(pkg_dir, top, sub)
        if sub_body is None or script_builds(pkg_dir, top, sub, sub_body, depth + 1):
            return True
    return False


def node_check_script(core, cwd, top):
    """`node [--max-old-space-size=N] <file.mjs> [args]` that a check / lint / typecheck / verify /
    test npm script of this repo runs (its body: optional NAME=value, then `node [that flag] <the
    same file>`, one command, no watch / serve / write) -> True. The npm form of that script already
    routes by category; this is the same job typed directly (dentall's `node scripts/check-*.mjs`,
    `*.selftest.mjs`). A script no package.json names stays here: it may be a quick one-off."""
    i = 1
    while i < len(core) and NODE_FLAG_RE.fullmatch(core[i]):
        i += 1
    if i >= len(core) or not NODE_SCRIPT_RE.fullmatch(core[i]) or BUILDS_RE.search(core[i]):
        return False
    if any(w in SHORT_VETO["script"] for w in core[i + 1:]):
        return False
    lock = nearest(cwd, top, NPM_LOCKS + OTHER_LOCKS)
    if not lock or lock[1] in OTHER_LOCKS:
        return False
    rtop = os.path.realpath(top)
    target = os.path.realpath(os.path.join(cwd, core[i]))
    if not target.startswith(rtop + os.sep):
        return False
    d = os.path.normpath(cwd)
    while True:
        pj = os.path.join(d, "package.json")
        try:
            with open(pj) as f:
                scripts = json.load(f).get("scripts") if os.path.isfile(pj) else None
        except (OSError, ValueError, AttributeError):
            scripts = None
        for name, body in (scripts.items() if isinstance(scripts, dict) else ()):
            if not isinstance(body, str) or not CHECK_SCRIPT_RE.match(name) or script_vetoed(name, body) \
                    or BODY_VETO_RE.search(body) or CHECKER_BODY_VETO_RE.search(body) \
                    or BUILDS_RE.search(name + " " + body) or re.search(r"[;&|`$()<>]", body):
                continue
            w = body.split()
            while len(w) > 1 and w[0] == "node" and NODE_FLAG_RE.fullmatch(w[1]):
                w = [w[0]] + w[2:]
            if len(w) >= 2 and w[0] == "node" and os.path.realpath(os.path.join(d, w[1])) == target:
                return True
        if d == os.path.normpath(top) or os.path.dirname(d) == d:
            return False
        d = os.path.dirname(d)


def judge(words, cwd, pattern_hit, dec=None, quoted=False, why=None):
    """Should this segment go to rrun? pattern_hit: rr_route_patterns matched. words = masked words; dec =
    the segment's shell-DECODED words (trailing redirects cut) or None; quoted = it had quoting. Every
    veto below is judged on the decoded words, so `'--watch'` is --watch (review round 2).
    -> True to route it (rewrite_segment still checks it is simple), False to leave it here; why
    (a list) gets the first veto's reason code for the decision log."""
    if cwd is None:
        return why_no(why, "cwd-unknown", False)              # cwd unknown (`cd $D`)
    top = git_top(cwd)
    if top is None:
        return why_no(why, "no-git", False)                   # rrun needs a git repo
    if dec is None:                                           # a heredoc segment: judged on its masked words as
        dec, quoted = words, True                             # before (it is never rewritable: `<`), so a match
                                                              # there still leaves the WHOLE command alone
    core = core_words(dec)
    if not core or os.path.basename(core[0]) in SERVER_HEADS:
        return why_no(why, "server", False)
    if any(re.match(r"UPDATE_\w*=", w) for w in dec[:len(dec) - len(core)]):
        return why_no(why, "update-env", False)               # an UPDATE_* prefix may mean "write"
    if any(w.startswith(LONG_VETO) for w in core):
        return why_no(why, "veto-flag", False)
    job = parse_job(core)
    if os.path.basename(core[0]) == "pnpm" or (pnpm_root(cwd, top) and "/" not in core[0]
                                               and not (job and job.get("prefix"))):
        ok = bool(pnpm_root(cwd, top)) and not quoted and core == strip_redirects(dec) \
            and judge_pnpm(core, cwd, top)
        return ok or why_no(why, "pnpm-shape", False)
    if job is None:
        if pattern_hit:
            return not any(w in ("-w", "-u") for w in core) or why_no(why, "veto-flag", False)
        if os.path.basename(core[0]) == "node" and node_check_script(core, cwd, top):
            return True
        return why_no(why, "node-script" if os.path.basename(core[0]) == "node" else "not-heavy", False)
    if job.get("tool") and "/" in core[0] and worker_tool_path(core[0], cwd, top) is None:
        return why_no(why, "bin-path", False)                 # a path the worker cannot run
    kind = job.get("tool") or "script"
    if any(w in SHORT_VETO[kind] for w in job["args"]):
        return why_no(why, "veto-flag", False)
    pkg = os.path.normpath(os.path.join(cwd, os.path.expanduser(job["prefix"] or ".")))
    lock = nearest(pkg, top, NPM_LOCKS + OTHER_LOCKS)
    if lock and lock[1] in OTHER_LOCKS:
        return why_no(why, "lockfile", False)                 # workers install with npm ci only
    if kind == "script":
        name = job["script"]
        body = script_body(pkg, top, name)
        if job["runner"] != "npm" or script_vetoed(name, body):
            return why_no(why, "script-veto", False)          # a worker may have no pnpm / yarn / bun
        if body is not None and BODY_VETO_RE.search(body):
            return why_no(why, "script-body", False)
        if script_builds(pkg, top, name, body):
            return why_no(why, "build", False)                # the build rule (rr_outputs) decides
        if pattern_hit:
            return True
        ok = bool(job["runner"] == "npm" and (SCRIPT_RE.match(name) or CHECKER_NAME_RE.match(name))
                  and body is not None and lock)
        return ok or why_no(why, "script-unknown", False)
    tool, args = job["tool"], job["args"]
    if tool == "vitest" and (not args or args[0] != "run"):
        return why_no(why, "watch", False)                    # bare vitest = watch mode
    if pattern_hit:
        return True
    if job["bare"] or not lock:
        return why_no(why, "bare-tool" if job["bare"] else "no-lockfile", False)
    if tool == "tsc":
        return tsc_checks_only(args, cwd) or why_no(why, "tsc-emits", False)
    return True


def route(cmd, patterns, depth=0, builds=None, cwd=None, why=None):
    """-> rewritten command, or None to leave it unchanged (why, a list, gets the reason code)."""
    if len(cmd) > MAX_CMD:
        return why_no(why, "too-long")                        # before any regex: bounded cost
    if any(c not in " \t\n" and unicodedata.category(c) in ("Zs", "Zl", "Zp", "Cc", "Cf")
           for c in cmd):
        return why_no(why, "odd-whitespace")                  # odd whitespace: words unclear
    scanned = scan(cmd)
    if scanned is None:
        return why_no(why, "unsure-quoting")
    segs, masked, shape, subs = scanned
    # ONE check over every word of the whole command (raw segment text, which holds every argument,
    # export value and substitution, plus the shell-decoded words, so `local"host"` is seen too;
    # heredoc bodies belong to no segment): anything naming this Mac stays here
    whole = " ".join(cmd[s:e] + " " + " ".join(decoded(cmd, s, e)[0] or []) for s, e, _ in segs)
    if LOCAL_URL_RE.search(whole):
        return why_no(why, "local-url")
    if INSPECT_RE.search(whole):
        return why_no(why, "inspect")
    regs = [re.compile(p) for p in patterns]
    cwds = seg_cwds(cmd, segs, masked, cwd) if cwd else [None] * len(segs)
    hits, hit_cwd = [], {}
    for (s, e, op), c in zip(segs, cwds):
        hit_cwd[s] = c
        text = masked[s:e]
        words = WORD_RE.findall(text)
        dec, quoted = decoded(cmd, s, e, subs)
        jwhy = why if HEAVY_LOOK_RE.search(text) else None    # only a heavy-looking segment's veto explains
        if depth == 0 and any(r.search(shell_c_script(cmd, shape, s, e)) for r in regs):
            hits.append((s, e, op))                           # bash -c '...': judged inside
        elif builds is not None and "build" in text and builds.is_build(text):
            if c and git_top(c) and dec is not None \
                    and not any(w.startswith(LONG_VETO) or w in BUILD_SHORT_VETO for w in dec) \
                    and builds.mapped(words, c):
                hits.append((s, e, op))                       # a build rrun copies back
            else:
                why_no(jwhy, "build")                         # a build: ONLY the build rule decides
        elif any(r.search(text) for r in regs):
            if judge(words, c, True, dec, quoted, jwhy):
                hits.append((s, e, op))
        elif judge(words, c, False, dec, quoted, jwhy):
            hits.append((s, e, op))
    if not hits:
        return why_no(why, "not-heavy")
    if not all(subst_ok(cmd[a:b]) for a, b in subs):
        return why_no(why, "subst")                           # output may be a laptop path / hide work
    fwd = forwarded(cmd, masked, segs, cwds, subs, hits[-1][0], why)
    if fwd is None:
        return None                                           # earlier state would not reach the mini
    starts = [s for s, _, _ in segs]
    out = cmd
    for s, e, op in reversed(hits):
        new = rewrite_segment(cmd, shape, s, e, op, patterns, depth, builds, cwd, hit_cwd.get(s),
                              subs, fwd[starts.index(s)], why)
        if new is None:
            return why_no(why, "unsure-segment")              # unsure about one -> touch none
        out = out[:s] + new + out[e:]
    return out


AUTOPULL_PLIST = "Library/LaunchAgents/com.claude.dotfiles-autopull.plist"


def ensure_autopull(h):
    """Every Mac that uses the pool keeps its dotfiles current: install the 2-minute fast-forward
    pull (scripts/dotfiles-autopull.sh) the first time it is missing. One stat per call; the install
    runs detached so the hook never waits on it."""
    if sys.platform != "darwin" or os.path.exists(os.path.join(h, AUTOPULL_PLIST)):
        return
    script = os.path.join(h, ".claude-dotfiles", "scripts", "dotfiles-autopull.sh")
    if not os.path.isfile(script):
        return
    try:
        subprocess.Popen(["/bin/bash", script, "--ensure"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def decide(cmd, cwd, h):
    """-> (decision, why, new command or None) for one Bash command: decision is routed / local
    (judged and kept here) / skipped (a gate before judging: opt-out marker, on a worker, no rrun)."""
    marker = next((m for m in SKIP_MARKERS if m in cmd), None)
    if marker:
        return "skipped", "already-rrun" if marker == "rrun" else "marker:" + marker.rstrip("/"), None
    if os.environ.get("RRUN_REMOTE"):
        return "skipped", "remote", None
    rrun_real = rrun_installed(h)
    if not rrun_real:
        return "skipped", "no-rrun", None
    ensure_autopull(h)
    user = user_cfg(h)
    if not any(t in cmd for t in PREFILTER) and "rr_route_patterns" not in user:
        return "skipped", "prefilter", None
    cfg = load_cfg(rrun_real, user)
    if os.path.isdir(os.path.join(h, cfg.get("rr_root") or "rr", "git")):
        return "skipped", "worker", None                     # this is the mini
    why = []
    new = route(cmd, cfg.get("rr_route_patterns") or [], builds=Builds(cfg, cwd), cwd=cwd, why=why)
    if not new or new == cmd:
        return "local", (why or ["not-heavy"])[0], None
    return "routed", "ok", new


def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input") or {}
        cmd = tool_input.get("command")
    except Exception:
        return
    if data.get("tool_name") != "Bash" or not isinstance(cmd, str) or not cmd.strip():
        return
    h = home()
    if len(cmd) > MAX_CMD:                                    # left alone before any regex runs
        sid = data.get("session_id") if isinstance(data.get("session_id"), str) else ""
        log_decision(h, sid, "local", "too-long", cmd[:MAX_CMD], data.get("cwd") if isinstance(data.get("cwd"), str) else "")
        return
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) and data.get("cwd") else os.getcwd()
    try:
        decision, why, new = decide(cmd, cwd, h)
    except Exception as e:                                    # fail open, but say so in the log
        decision, why, new = "local", "error:" + type(e).__name__, None
    if new or HEAVY_LOOK_RE.search(cmd):
        sid = data.get("session_id") if isinstance(data.get("session_id"), str) else ""
        log_decision(h, sid, decision, why, cmd, cwd)
    if not new:
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
