# /user:verify — Full Verification Pipeline

Run a complete build→typecheck→lint→test→security verification pipeline. Hard-gates on each step — if one fails, stop and fix before continuing.

## Step 1: Detect Project Type

Check for project markers:
```bash
ls package.json Cargo.toml go.mod pyproject.toml Makefile 2>/dev/null
```

Read the detected config file to determine:
- Package manager (npm, bun, yarn, pnpm, cargo, go, pip)
- Available scripts (build, typecheck, lint, test)
- Test framework

## Step 2: Build

Run the project's build command:
```bash
# Node: npm run build / bun run build
# Rust: cargo build
# Go: go build ./...
```

**HARD GATE:** If build fails, stop. Show errors. Fix them. Re-run this step.

## Step 3: Type Check

```bash
# TypeScript: npx tsc --noEmit
# Rust: cargo check
# Python: mypy . / pyright
```

**HARD GATE:** If type check fails, stop. Show errors. Fix them. Re-run this step.

## Step 4: Lint

```bash
# Node: npm run lint / bun run lint
# Rust: cargo clippy
# Go: golangci-lint run
# Python: ruff check .
```

**HARD GATE:** If lint fails, stop. Fix violations. Re-run this step.

## Step 5: Test

```bash
# Node: npm test / bun test
# Rust: cargo test
# Go: go test ./...
# Python: pytest
```

**HARD GATE:** If tests fail, stop. Show failures. Fix them. Re-run this step.

## Step 6: Security Scan

Search for common security issues in changed files:

```bash
git diff --name-only HEAD 2>/dev/null || git diff --name-only
```

In those files, check for:
- Hardcoded API keys, tokens, passwords (patterns: `sk-`, `api_key=`, `password=`, `secret`)
- `console.log` statements left in production code
- `TODO` / `FIXME` / `HACK` comments that should be resolved
- Disabled security features (`// eslint-disable`, `@ts-ignore`, `DANGEROUSLY`)

Report findings but don't hard-gate — let the user decide which to address.

## Step 7: Diff Review

Summarize what changed:
```bash
git diff --stat
```

Show a brief summary of:
- Files modified / added / deleted
- Nature of changes (feature, fix, refactor, etc.)
- Any documentation that needs updating (per global CLAUDE.md rules)

## Final Verdict

Report: **PASS** (all gates passed) or **FAIL** (which step failed)

If PASS, tell the user: "Verification complete. Ready to commit/push when you are."
If FAIL, show exactly what needs fixing.
