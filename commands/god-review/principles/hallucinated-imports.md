---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Bash(cat:*), Bash(npm:*), Bash(pip:*), Read, Grep, Glob, TodoWrite
description: "Detect imports of packages that are not declared in the project's dependency manifest (Tier 1, FAIL)"
argument-hint: "[scope] [--online]"
---

# /god-review:principles:hallucinated-imports — Hallucinated Import Detector

You are scanning for imports of packages that do not exist in the project's declared dependencies. This catches AI hallucination (inventing package names), slopsquatting attacks (real-but-malicious packages with plausible names), and missing dependency declarations.

**THIS IS A TIER 1 LENS. ANY UNDECLARED NON-RELATIVE NON-STDLIB IMPORT = FAIL. Findings are promoted one confidence level before section assignment.**

## The Principle

Every non-relative, non-standard-library import must correspond to a package declared in the project's dependency manifest (`package.json`, `requirements.txt`, `Pipfile`, `pyproject.toml`, `Cargo.toml`, `go.mod`). An import with no declaration is either hallucinated (the package doesn't exist), undeclared (it exists but isn't listed — fragile), or a supply-chain attack vector.

## Why This Matters

- AI code generators frequently invent plausible-sounding package names that don't exist (failure mode #15 — hallucinated dependencies)
- Undeclared imports work "by accident" (peer dependency, globally installed, wrong lockfile) until they don't
- Slopsquatting: attackers register common AI-hallucinated package names; importing them installs malware
- Missing declarations cause reproducibility failures — the code works locally but breaks in CI or on a fresh clone
- Optional `--online` mode catches declared-but-nonexistent packages (packages listed in manifest but not in registry)

## Phase 1: Gather Context

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

# Load shared context if available
[ -f tmp/god-review/context-package.md ] && head -80 tmp/god-review/context-package.md

# Detect project type(s)
ls "$WORKDIR/package.json" 2>/dev/null && echo "HAS_NODEJS=yes"
ls "$WORKDIR/requirements.txt" 2>/dev/null && echo "HAS_REQUIREMENTS=yes"
ls "$WORKDIR/Pipfile" 2>/dev/null && echo "HAS_PIPFILE=yes"
ls "$WORKDIR/pyproject.toml" 2>/dev/null && echo "HAS_PYPROJECT=yes"
ls "$WORKDIR/Cargo.toml" 2>/dev/null && echo "HAS_CARGO=yes"
ls "$WORKDIR/go.mod" 2>/dev/null && echo "HAS_GO=yes"

# Show current branch
git rev-parse --abbrev-ref HEAD
```

Use TodoWrite to track each undeclared import found.

## Phase 2: Identify Candidates

### 2.1 Extract Declared Dependencies

```bash
# Node.js — extract all declared dep names (dependencies + devDependencies + peerDependencies + optionalDependencies)
if [ -f "$WORKDIR/package.json" ]; then
  cat "$WORKDIR/package.json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for section in ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies']:
    for pkg in d.get(section, {}):
        print(pkg)
" 2>/dev/null | sort -u
fi

# Python — requirements.txt
[ -f "$WORKDIR/requirements.txt" ] && grep -v '^\s*#' "$WORKDIR/requirements.txt" | grep -oE '^[A-Za-z0-9_.-]+' | sort -u

# Python — pyproject.toml [project.dependencies]
[ -f "$WORKDIR/pyproject.toml" ] && grep -E '^\s+"[A-Za-z0-9_.-]' "$WORKDIR/pyproject.toml" | grep -oE '"[A-Za-z0-9_.-]+' | tr -d '"' | sort -u

# Python — Pipfile [packages] section
[ -f "$WORKDIR/Pipfile" ] && awk '/^\[packages\]/,/^\[/' "$WORKDIR/Pipfile" | grep -oE '^[A-Za-z0-9_.-]+' | sort -u

# Rust — Cargo.toml [dependencies]
[ -f "$WORKDIR/Cargo.toml" ] && awk '/^\[dependencies\]/,/^\[/' "$WORKDIR/Cargo.toml" | grep -oE '^[a-z0-9_-]+' | sort -u

# Go — go.mod require block
[ -f "$WORKDIR/go.mod" ] && awk '/^require/,/^\)/' "$WORKDIR/go.mod" | grep -oE '^\s+([a-zA-Z0-9./\-_]+)' | tr -d ' ' | sort -u
```

### 2.2 Extract Imports from Source Files

```bash
# Node.js / TypeScript: ES module imports and CommonJS requires
find "$WORKDIR" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.mjs" -o -name "*.cjs" \) \
  \( -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/.next/*" \) \
  -print0 2>/dev/null | xargs -0 grep -hE "^import .* from ['\"]([^'\"./][^'\"]*)['\"]|require\(['\"]([^'\"./][^'\"]*)['\"]" 2>/dev/null \
  | grep -oE "['\"]([^'\".][^'\"]*)['\"]" | tr -d "\"'" | grep -v '^node:' | sort -u

# Python: import and from...import statements
find "$WORKDIR" -type f -name "*.py" \
  \( -not -path "*/.git/*" -not -path "*/dist/*" -not -path "*/__pycache__/*" -not -path "*/venv/*" -not -path "*/.venv/*" \) \
  -print0 2>/dev/null | xargs -0 grep -hE "^import ([A-Za-z0-9_.]+)|^from ([A-Za-z0-9_.]+) import" 2>/dev/null \
  | grep -oE "(import|from) ([A-Za-z0-9_]+)" | awk '{print $2}' | sort -u

# Rust: extern crate and use statements (top-level package names only)
find "$WORKDIR" -type f -name "*.rs" \
  \( -not -path "*/.git/*" -not -path "*/target/*" \) \
  -print0 2>/dev/null | xargs -0 grep -hE "^(extern crate|use) ([a-zA-Z0-9_]+)" 2>/dev/null \
  | awk '{print $2}' | tr -d ';' | cut -d: -f1 | sort -u
```

### 2.3 Cross-Check: Imports vs Declared Deps

For Node.js:
- Strip package scope: `@scope/name` → declared as `@scope/name` in package.json (scope is part of the name, must match exactly)
- Relative imports (`./`, `../`) → skip (not external packages)
- Built-in Node.js modules (`fs`, `path`, `crypto`, `node:*`, `buffer`, `events`, `stream`, `util`, `http`, `https`, `url`, `os`, `child_process`, `process`, `module`, `readline`, `assert`, `timers`, `zlib`, `net`, `tls`, `dns`, `v8`, `vm`, `cluster`, `worker_threads`, `perf_hooks`, `inspector`, `trace_events`, `wasi`, `diagnostics_channel`) → skip
- Everything else must appear in a declared dep section

For Python:
- Standard library modules → skip. Common stdlib: `os`, `sys`, `re`, `json`, `pathlib`, `typing`, `datetime`, `collections`, `itertools`, `functools`, `math`, `random`, `hashlib`, `hmac`, `base64`, `urllib`, `http`, `email`, `io`, `abc`, `copy`, `dataclasses`, `enum`, `contextlib`, `logging`, `threading`, `multiprocessing`, `subprocess`, `shutil`, `tempfile`, `glob`, `fnmatch`, `configparser`, `argparse`, `unittest`, `inspect`, `importlib`, `ast`, `dis`, `gc`, `traceback`, `warnings`, `weakref`, `struct`, `array`, `queue`, `heapq`, `bisect`, `time`, `calendar`, `locale`, `gettext`, `string`, `textwrap`, `difflib`, `pprint`, `csv`, `sqlite3`, `xml`, `html`, `socket`, `ssl`, `select`, `signal`, `mmap`, `ctypes`, `platform`, `sysconfig`, `builtins`, `__future__`
- Internal first-party imports (matching the package name in pyproject.toml `[project] name`) → skip
- Everything else must appear in requirements.txt / Pipfile / pyproject.toml deps

### 2.4 Optional Online Check (`--online` flag)

If `--online` is in $ARGUMENTS:

```bash
# For each declared Node.js dep, verify it exists in npm registry
for pkg in $(cat "$WORKDIR/package.json" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(p) for s in ['dependencies','devDependencies'] for p in d.get(s,{})]" 2>/dev/null); do
  npm view "$pkg" name 2>/dev/null || echo "REGISTRY_MISS: $pkg"
done

# For each declared Python dep, verify it exists on PyPI
for pkg in $(grep -v '^\s*#' "$WORKDIR/requirements.txt" 2>/dev/null | grep -oE '^[A-Za-z0-9_.-]+'); do
  pip show "$pkg" 2>/dev/null | grep -q "^Name:" || echo "REGISTRY_MISS: $pkg"
done
```

## Phase 3: Deep Analysis

For each undeclared import:

1. **Confirm it is not a relative import.** Paths starting with `./`, `../`, or `/` are not external packages — skip.

2. **Confirm it is not stdlib/builtin.** Cross-check against the stdlib lists above.

3. **Check if it's a workspace package or monorepo sibling.** In a monorepo (workspaces in package.json, or `packages/` directory), internal packages are often imported by name. Check if a matching `packages/<name>/package.json` exists with a matching `name` field.

4. **Check if it was recently added to the manifest** (might be in a separate manifest-update commit not included in the current diff):
```bash
git log --oneline -5 -- package.json requirements.txt Cargo.toml go.mod pyproject.toml Pipfile 2>/dev/null
```

5. **Assess the risk:** Is this a realistic package name that could exist? Is it a plausible AI hallucination? Does a package with this exact name exist in the registry (if online check is enabled)?

## Phase 4: Generate Report

```markdown
# Hallucinated Imports Report

**Scope:** {scope}
**Status:** {PASS | FAIL}
**Tier:** 1 (always-on, promoted)
**Online mode:** {enabled | disabled (pass --online to enable registry check)}

## Summary

{N} undeclared imports found across {M} files. {K} registry misses (online mode only).

## Undeclared Imports

| Import | File | Line | Declared In | Risk | Severity |
|--------|------|------|-------------|------|----------|
| `{pkg}` | `{file}:{line}` | `{import statement}` | not declared | {hallucinated/missing-decl/monorepo-internal} | FAIL |

## Registry Misses (online mode only)

| Package | Declared In | Registry Status | Risk |
|---------|-------------|-----------------|------|
| `{pkg}` | `package.json:dependencies` | NOT FOUND | Potential hallucination or typo |

## Recommendations

1. For `{pkg}` in `{file}`: either add to package.json dependencies or replace with the correct package name
2. Run `npm install {pkg}` / `pip install {pkg}` to verify the package exists before committing
```

## Phase 5: Output

1. Save findings to `tmp/god-review/principles/hallucinated-imports-findings.md`
2. Print summary:
   - PASS: all imports are declared or stdlib/relative
   - FAIL: any undeclared non-relative non-stdlib import found

```bash
mkdir -p tmp/god-review/principles
```

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- **PASS**: All imports in source files are either: relative (`./`, `../`), standard library / builtin, or declared in the project's manifest (`package.json`, `requirements.txt`, `Pipfile`, `pyproject.toml`, `Cargo.toml`, `go.mod`).
- **FAIL**: Any non-relative, non-stdlib import that does not appear in any dep section of the project's manifest.

## Risk Levels

- **CRITICAL**: Undeclared import whose package name does not exist in the public registry (confirmed hallucination or slopsquatting vector)
- **HIGH**: Undeclared import of a package with a name similar to a common package but slightly different (potential typosquat)
- **MEDIUM**: Undeclared import of a package that exists in the registry but is not in the manifest (missing declaration — fragile but functional)
- **LOW**: Import that appears to be a workspace/monorepo sibling package (needs verification)

## Known Issues (don't re-report)

- Load from `tmp/god-review/context-package.md` known-issues section if available
- Do NOT flag imports from `node:*` namespace (e.g., `node:fs`, `node:path`) — these are explicit Node.js built-in references
- Do NOT flag imports from workspace siblings in monorepos — check for a `packages/<name>/package.json` with matching `name` field before flagging
- Do NOT flag type-only imports (`import type { Foo } from 'pkg'`) from `@types/*` packages — these are dev-only type declarations and may be declared as devDependencies or implicitly included
- Python `__future__` is always stdlib — do not flag

Run analysis on: $ARGUMENTS (or full repo if empty). Pass `--online` to enable registry validation.
