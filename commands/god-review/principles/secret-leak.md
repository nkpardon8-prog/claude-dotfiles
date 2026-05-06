---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Bash(cat:*), Bash(awk:*), Bash(python3:*), Read, Grep, Glob, TodoWrite
description: "Detect secret values from .env files appearing in source code, and high-entropy strings matching API key patterns (Tier 1, CRITICAL)"
argument-hint: "[scope]"
---

# /god-review:principles:secret-leak — Secret Leak Detector

You are scanning for secrets committed to source code: values from `.env` files appearing in non-env source files, and high-entropy strings that match known API key patterns.

**THIS IS A TIER 1 LENS. ANY SECRET EXPOSURE = CRITICAL. Findings are promoted one confidence level before section assignment.**

## The Principle

Secret values — API keys, tokens, passwords, signing secrets — must never appear in source code committed to version control. `.env` files define the secret names; their values must remain isolated to those files and never propagate into source code, test fixtures, documentation, or configuration files tracked by git.

## Why This Matters

- Secrets committed to git are permanently exposed even after deletion — git history preserves them (failure mode #17 — secret leakage)
- API keys in source code are scraped by bots within minutes of a push to a public repo
- Even private repos leak via: forks, mirrors, accidental visibility changes, third-party integrations, git-bundle exports
- High-entropy strings matching key patterns (sk-, AKIA, ghp_) are targeted by automated secret scanners used by attackers
- This lens activates the hard gate in Phase 3: secret-handling files are NEVER auto-applied, even with `--fix`

## Phase 1: Gather Context

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

# Load shared context if available
[ -f tmp/god-review/context-package.md ] && head -80 tmp/god-review/context-package.md

# Find all .env files (including .env.local, .env.production, .env.example, etc.)
find "$WORKDIR" -maxdepth 3 -name ".env*" -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null

# Show current branch
git rev-parse --abbrev-ref HEAD
```

Use TodoWrite to log each secret candidate found.

## Phase 2: Identify Candidates

### 2.1 Extract Secret Values from .env Files

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

find "$WORKDIR" -maxdepth 3 -name ".env*" -not -path "*/.git/*" -not -path "*/node_modules/*" -not -name "*.example" -not -name "*.sample" -not -name "*.template" 2>/dev/null | while read envfile; do
  echo "=== $envfile ==="
  grep -E '^[A-Z_][A-Z0-9_]*=.+' "$envfile" 2>/dev/null | while IFS='=' read -r key value; do
    value="${value//\"/}"  # strip quotes
    value="${value//\'/}"
    # Only flag values that are >=16 chars OR match a known secret pattern prefix
    vlen="${#value}"
    if [ "$vlen" -ge 16 ] || echo "$value" | grep -qE '^(sk-|pk-|sk_live|sk_test|pk_live|pk_test|AKIA|ghp_|ghs_|gho_|ghu_|github_pat_|xox[baprs]-|SG\.|Bearer |rk_live_|rk_test_|AC[a-z0-9]{32}|AP[a-zA-Z0-9]{32}|EAA[a-zA-Z0-9]+|ya29\.|AIza)'; then
      echo "SECRET_KEY=$key VALUE_LEN=$vlen VALUE_PREFIX=${value:0:8}..."
    fi
  done
done
```

### 2.2 Search Source Code for .env Secret Values

For each extracted secret value, search the codebase:

```bash
# For each secret value (replace SECRET_VALUE with actual value from step 2.1):
SECRET_VALUE="<extracted_value>"
grep -rn --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
         --include="*.py" --include="*.rb" --include="*.go" --include="*.rs" \
         --include="*.java" --include="*.kt" --include="*.cs" --include="*.php" \
         --include="*.yaml" --include="*.yml" --include="*.json" --include="*.toml" \
         --include="*.md" --include="*.txt" --include="*.html" --include="*.xml" \
         --exclude-dir=".git" --exclude-dir="node_modules" --exclude-dir="dist" \
         --exclude-dir="build" --exclude-dir=".next" --exclude-dir="target" \
         -e "$SECRET_VALUE" "$WORKDIR" 2>/dev/null | grep -v '\.env'
```

Any hit outside `.env*` files = CRITICAL.

### 2.3 High-Entropy String Detection

```bash
# Scan source files for high-entropy strings matching API key patterns
# High entropy = >4.5 bits/char; min length 20 chars; matching key-like patterns

python3 << 'PYEOF'
import math, re, os, sys

def entropy(s):
    if not s:
        return 0
    freq = {}
    for c in s:
        freq[c] = freq.get(c, 0) + 1
    return -sum((f/len(s)) * math.log2(f/len(s)) for f in freq.values())

# Pattern: 20+ char strings with high entropy matching API key character sets
key_pattern = re.compile(r'\b([A-Za-z0-9_\-+/]{20,})\b')

# Known patterns that signal API keys even without scanning .env
known_prefixes = re.compile(r'^(sk-|pk-|sk_live|sk_test|pk_live|pk_test|AKIA[A-Z0-9]{16}|ghp_[A-Za-z0-9]{36}|ghs_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|ghu_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{59}|xox[baprs]-[A-Za-z0-9-]+|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}|ya29\.[A-Za-z0-9_-]+|AIza[A-Za-z0-9_-]{35})')

workdir = os.environ.get('WORKDIR', os.getcwd())
extensions = {'.ts', '.tsx', '.js', '.jsx', '.py', '.rb', '.go', '.rs', '.java', '.kt', '.cs', '.php', '.toml', '.yaml', '.yml'}
skip_dirs = {'node_modules', '.git', 'dist', 'build', '.next', 'target', '__pycache__', '.venv', 'venv'}

findings = []
for root, dirs, files in os.walk(workdir):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for fname in files:
        ext = os.path.splitext(fname)[1]
        if ext not in extensions:
            continue
        fpath = os.path.join(root, fname)
        # Skip test files for entropy scan (they often have base64/fixture data)
        if re.search(r'\.(test|spec)\.|_test\.|test_', fname):
            continue
        try:
            with open(fpath, 'r', errors='ignore') as f:
                for lineno, line in enumerate(f, 1):
                    for match in key_pattern.finditer(line):
                        s = match.group(1)
                        e = entropy(s)
                        if e > 4.5 and (len(s) >= 32 or known_prefixes.match(s)):
                            findings.append(f"{fpath}:{lineno}: entropy={e:.2f} len={len(s)} value={s[:12]}...")
        except Exception:
            pass

for f in findings[:50]:
    print(f)
print(f"\nTotal high-entropy findings: {len(findings)}")
PYEOF
```

### 2.4 Known Secret Pattern Direct Scan

```bash
# Scan for strings matching known secret prefixes directly in source (belt-and-suspenders)
grep -rn --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
         --include="*.py" --include="*.rb" --include="*.go" --include="*.rs" \
         --include="*.java" --include="*.php" --include="*.toml" \
         --exclude-dir=".git" --exclude-dir="node_modules" --exclude-dir="dist" \
         --exclude-dir="target" --exclude-dir=".next" \
         -E "(sk-[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}|ghp_[A-Za-z0-9]{36}|ghs_[A-Za-z0-9]{36}|AIza[A-Za-z0-9_-]{35}|SG\.[A-Za-z0-9_-]{22}\.|ya29\.[A-Za-z0-9_-]+)" \
         "$WORKDIR" 2>/dev/null | grep -v '\.env' | head -30
```

## Phase 3: Deep Analysis

For each candidate:

1. **Confirm the value is not a placeholder.** Strings like `YOUR_API_KEY_HERE`, `REPLACE_WITH_SECRET`, `<your-key>`, `example_key_123` are placeholders, not real secrets. Flag as LOW risk / informational only.

2. **Confirm the file is tracked by git** (not in .gitignore):
```bash
git check-ignore -q "<file>" 2>/dev/null || echo "TRACKED: file is committed"
```

3. **Check if the secret is already in git history** (worst case — already leaked):
```bash
git log --all --oneline --diff-filter=A -- "<file>" 2>/dev/null | head -3
```

4. **Assess blast radius:** Is this an API key with write access, a signing secret, a database password, or a read-only public key? The severity varies, but all are CRITICAL at minimum.

5. **For high-entropy strings:** Read the surrounding context. Is this a test fixture with random data? A base64-encoded binary asset? A hash value? Only flag if it genuinely looks like a credential (starts with known prefix, or appears in a variable named `key`, `token`, `secret`, `password`, `apiKey`, `api_key`, `credential`).

## Phase 4: Generate Report

```markdown
# Secret Leak Report

**Scope:** {scope}
**Status:** {PASS | FAIL}
**Tier:** 1 (always-on, promoted, hard gate in Phase 3)

## Summary

{N} .env secret values found in source code. {M} high-entropy strings matching API key patterns.

## .env Values Appearing in Source

| Secret Name | File | Line | Value Preview | Git-Tracked? | Severity |
|------------|------|------|---------------|-------------|----------|
| `{KEY}` | `{file}:{line}` | `{snippet}` | `{first 8 chars}...` | YES | CRITICAL |

## High-Entropy Strings Matching Key Patterns

| File | Line | Entropy | Length | Pattern Match | Severity |
|------|------|---------|--------|--------------|----------|
| `{file}:{line}` | `{snippet}` | {e:.2f} bits/char | {len} | `{prefix}*` | CRITICAL |

## Recommended Actions

**IMMEDIATE (before next push):**

1. Rotate any exposed key immediately — assume it is already compromised
2. Remove the secret from source: `git rm --cached <file>` or edit file
3. Add the file to `.gitignore` if it's a local config file
4. To fully purge from git history: `git filter-branch --index-filter 'git rm --cached --ignore-unmatch <file>' HEAD`

**Structural fix:**
5. Load secrets only from environment variables; never hardcode values
6. Add a pre-commit hook to prevent future leaks: `detect-secrets` or `gitleaks`
```

## Phase 5: Output

1. Save findings to `tmp/god-review/principles/secret-leak-findings.md`
2. Print summary:
   - PASS: no .env values in source, no high-entropy key-pattern strings outside test fixtures
   - FAIL: any .env value found in non-.env source files OR any high-entropy API-key-pattern string in tracked non-test source

```bash
mkdir -p tmp/god-review/principles
```

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- **PASS**: No `.env` secret values (≥16 chars or matching known prefixes) appear in any non-`.env*` tracked file. No high-entropy (>4.5 bits/char) strings matching known API key patterns found in non-test source files.
- **FAIL**: Any `.env` value matching criteria found in source code, OR any high-entropy string with a known key-pattern prefix found in non-test tracked source.

## Risk Levels

- **CRITICAL**: Active secret (matches known provider prefix like `sk-`, `AKIA`, `ghp_`) found in tracked source — rotate immediately
- **HIGH**: High-entropy string with key-like variable name in tracked source — may be active key, rotate to be safe
- **MEDIUM**: Secret found in a file that is in `.gitignore` but present on disk — not committed, but risky if gitignore is changed
- **LOW**: Placeholder-pattern string that looks like a key format but is clearly a template value

## Known Issues (don't re-report)

- Load from `tmp/god-review/context-package.md` known-issues section if available
- Do NOT flag `.env.example` or `.env.sample` or `.env.template` files — these are meant to document key names without real values
- Do NOT flag high-entropy strings in binary/asset files (`*.png`, `*.jpg`, `*.pdf`, `*.wasm`)
- Do NOT flag base64-encoded content that is clearly a public certificate or public key (begins with `-----BEGIN CERTIFICATE-----` or `-----BEGIN PUBLIC KEY-----`) — public keys are not secrets
- Do NOT flag test files containing clearly fake/synthetic keys labeled as such (e.g., `FAKE_KEY`, `TEST_SECRET`, in a jest mock or pytest fixture) — still verify they don't match actual .env values
- Do NOT flag values less than 16 characters that don't match a known prefix pattern — too short to be meaningful secrets

Run analysis on: $ARGUMENTS (or full repo if empty).
