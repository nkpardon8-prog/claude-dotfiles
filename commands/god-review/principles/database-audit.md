---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Bash(cat:*), Read, Grep, Glob, TodoWrite
description: "Check for database schema/migration/RLS hygiene violations in repo SQL and schema files (stack-gated: HAS_DATABASE)"
argument-hint: "[scope]"
---

# /god-review:principles:database-audit — Static Database Schema/Migration Hygiene

**Stack gate:** This principle self-skips if `HAS_DATABASE` is not detected.

You are statically auditing the repository's database surface — migration SQL, schema files (`schema.prisma`, ORM models, raw `*.sql`), and policy declarations — for schema/migration/RLS hygiene violations. **This lens reads repo files ONLY. It opens NO database connection, makes NO network call, and runs NO SQL.** It is the read-only, git-revertable slice of database auditing that fits god-review's safety model.

## Scope: A Deliberately Narrow, Non-Redundant Slice

This principle owns a **narrow set of repo-static findings** and explicitly defers everything else. It does NOT attempt the live, credentialed audit that `/database-audit` performs (advisors, live RLS coverage, `pg_stats`-driven column analysis, connection/pooler/control-plane checks). Those require a DB connection god-review cannot and must not open.

### OWNED finding set (the non-redundant slice)

1. **RLS-disabled or blanket-permissive policies in migrations.** Tables created in `migrations/**.sql` that never get `ENABLE ROW LEVEL SECURITY`, or policies declared with a blanket `USING (true)` / `WITH CHECK (true)` predicate that grants unconditional access. Category: `DATA_LEAK`.
2. **SECURITY DEFINER functions with mutable or missing `search_path`.** `CREATE FUNCTION … SECURITY DEFINER` blocks in SQL files that do not pin `SET search_path = …` (or pin it to a mutable/empty value). Category: `INJECTION`.
3. **Migration drift / ordering gaps.** Local migration files whose ordering (timestamp/sequence prefixes) has gaps, duplicates, or out-of-order entries relative to the declared convention; orphaned/edited-after-apply migrations where detectable from git history. Category: `DATA_INTEGRITY`.
4. **PII-named columns declared without an accompanying RLS policy.** Columns whose names match common PII patterns (`email`, `phone`, `ssn`, `dob`, `date_of_birth`, `address`, `full_name`, `first_name`, `last_name`, `credit_card`, `card_number`, `tax_id`, `passport`, `ip_address`) declared in schema/migration files on a table that has no RLS policy declared in the same repo. Category: `DATA_LEAK`.
5. **Unindexed foreign keys declared in schema files — ONLY if not already owned by `architecture-backend`.** A `REFERENCES`/`FOREIGN KEY` column with no matching index/`CREATE INDEX` declaration. Emit this ONLY when `architecture-backend` is not active for the repo (i.e., no backend signal); if `architecture-backend` is active, defer to it and do NOT re-report. Category: `DATA_INTEGRITY`.

Severity for each finding type defers entirely to `CRITERIA.md` — do not invent a severity taxonomy here, and do not invent a new category. Use only the existing `DATA_INTEGRITY` / `INJECTION` / `DATA_LEAK` categories listed above.

## Stack Gate Check

In Phase 1, recompute `HAS_DATABASE`:
```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
HAS_DATABASE=$(/bin/bash -c 'find "$1" -maxdepth 6 \( -path "*/node_modules" -o -path "*/.git" \) -prune -o \( -name "*.sql" -o -path "*/migrations/*" -o -name "schema.prisma" \) -print' _ "$WORKDIR" 2>/dev/null | head -1)
if [ -z "$HAS_DATABASE" ]; then
  pkgs=$(/bin/bash -c 'find "$1" -maxdepth 6 \( -path "*/node_modules" -o -path "*/.git" \) -prune -o -name package.json -print0' _ "$WORKDIR" 2>/dev/null)
  [ -n "$pkgs" ] && HAS_DATABASE=$(printf '%s' "$pkgs" | xargs -0 grep -l "@supabase/supabase-js\|@neondatabase/serverless\|\"pg\"\|drizzle-orm\|prisma" 2>/dev/null | head -1)
fi
```

If `HAS_DATABASE` is empty: output "(skipped — no database detected)" and exit.

## Phase 1: Gather Context

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

# Load shared context (incl. known-issues) if available
[ -f tmp/god-review/context-package.md ] && head -120 tmp/god-review/context-package.md

# Enumerate the DB surface (repo files only — no connection)
/bin/bash -c 'find "$1" -maxdepth 6 \( -path "*/node_modules" -o -path "*/.git" \) -prune -o \( -name "*.sql" -o -name "schema.prisma" \) -print' _ "$WORKDIR" 2>/dev/null
/bin/bash -c 'find "$1" -maxdepth 6 \( -path "*/node_modules" -o -path "*/.git" \) -prune -o -type d -name migrations -print' _ "$WORKDIR" 2>/dev/null

# Detect whether architecture-backend is active (it owns unindexed-FK if so)
HAS_AUTHED_HANDLER=$(/bin/bash -c 'find "$1" -maxdepth 5 \( -path "*/node_modules" -o -path "*/.git" \) -prune -o -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" \) -print0' _ "$WORKDIR" 2>/dev/null | xargs -0 grep -l "authenticatedHandler\|requireAuth\|withAuth\|@authenticated\|protectedRoute" 2>/dev/null | head -1)
HAS_BACKEND_PROJECT=$(/bin/bash -c 'find "$1" -maxdepth 4 \( -path "*/node_modules" -o -path "*/.git" \) -prune -o \( -name "main.go" -o -name "go.mod" -o -name "Cargo.toml" -o -name "requirements.txt" -o -name "pyproject.toml" -o -name "Gemfile" -o -name "pom.xml" \) -print' _ "$WORKDIR" 2>/dev/null | head -1)
ARCH_BACKEND_ACTIVE="${HAS_AUTHED_HANDLER}${HAS_BACKEND_PROJECT}"
echo "architecture-backend active (owns unindexed-FK if non-empty): [$ARCH_BACKEND_ACTIVE]"

git rev-parse --abbrev-ref HEAD
```

Use TodoWrite to log each DB-surface file and each candidate violation.

## Phase 2: Identify Candidates

### 2.1 RLS-disabled / blanket-permissive policies (migrations/**.sql)

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# Tables created in migrations
grep -rniE "create table" "$WORKDIR" --include="*.sql" 2>/dev/null | grep -iE "migration" | head -50
# Which tables enable RLS at all
grep -rniE "enable row level security" "$WORKDIR" --include="*.sql" 2>/dev/null | head -50
# Blanket-permissive policies — unconditional access
grep -rniE "using[[:space:]]*\([[:space:]]*true[[:space:]]*\)|with check[[:space:]]*\([[:space:]]*true[[:space:]]*\)" "$WORKDIR" --include="*.sql" 2>/dev/null | head -50
```
Cross-reference: every `CREATE TABLE` in a migration whose table never appears in an `ENABLE ROW LEVEL SECURITY` statement is a candidate. Every `USING (true)` / `WITH CHECK (true)` policy is a candidate.

### 2.2 SECURITY DEFINER functions with mutable/missing search_path

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
grep -rniE "security definer" "$WORKDIR" --include="*.sql" 2>/dev/null | head -50
# Pinned search_path is the mitigation; flag SECURITY DEFINER bodies lacking it
grep -rniE "set[[:space:]]+search_path" "$WORKDIR" --include="*.sql" 2>/dev/null | head -50
```
For each `SECURITY DEFINER` function, Read the surrounding function body. A function is a candidate if it does NOT pin `SET search_path = …` to a fixed schema list (empty/mutable search_path is a privilege-escalation vector).

### 2.3 Migration drift / ordering gaps

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# List migration files in order; inspect numeric/timestamp prefixes for gaps or dupes
/bin/bash -c 'find "$1" -path "*/migrations/*" -name "*.sql" -print' _ "$WORKDIR" 2>/dev/null | sort
# Migrations edited after their introduction commit (drift signal)
/bin/bash -c 'find "$1" -path "*/migrations/*" -name "*.sql" -print' _ "$WORKDIR" 2>/dev/null | while read m; do
  commits=$(git log --oneline -- "$m" 2>/dev/null | wc -l | tr -d ' ')
  [ "$commits" -gt 1 ] && echo "DRIFT-CANDIDATE ($commits commits): $m"
done
```
Candidates: ordering prefixes with gaps/duplicates/out-of-order entries, or applied migrations edited after introduction (git shows >1 commit touching the file).

### 2.4 PII-named columns without an RLS policy

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
grep -rniE "(email|phone|ssn|dob|date_of_birth|address|full_name|first_name|last_name|credit_card|card_number|tax_id|passport|ip_address)" \
  "$WORKDIR" --include="*.sql" --include="schema.prisma" 2>/dev/null | head -80
```
For each PII-named column, determine the owning table; if that table has no RLS policy declared anywhere in the repo SQL, it is a candidate.

### 2.5 Unindexed foreign keys (ONLY if architecture-backend NOT active)

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# Only run this section if ARCH_BACKEND_ACTIVE (from Phase 1) is EMPTY.
grep -rniE "references|foreign key" "$WORKDIR" --include="*.sql" --include="schema.prisma" 2>/dev/null | head -80
grep -rniE "create index|@@index|@index" "$WORKDIR" --include="*.sql" --include="schema.prisma" 2>/dev/null | head -80
```
For each FK column, check whether a matching index/`CREATE INDEX` is declared. If not, AND `architecture-backend` is inactive, it is a candidate. If `architecture-backend` is active, SKIP this section entirely (it owns the finding).

## Phase 3: Deep Analysis

For each candidate, Read the exact declaration and confirm the violation:

1. **RLS:** Confirm the table holds data exposed to a client role (Supabase anon/authenticated, PostgREST/Data API). A `USING (true)` policy on an internal-only table is lower severity than on a client-exposed one — defer the exact severity to CRITERIA.md, but record the exposure context.
2. **SECURITY DEFINER:** Confirm there is no `SET search_path` clause pinned to a fixed value. A function that pins `search_path = ''` or `= public, pg_temp` is mitigated — do not flag it.
3. **Migration drift:** Confirm the ordering anomaly is real (not just a naming convention you misread) and that an edited-after-apply migration is not merely a never-applied draft.
4. **PII without RLS:** Confirm the column genuinely holds PII (not e.g. a `company_address` reference table that is public by design) and that no RLS policy covers its table.
5. **Unindexed FK:** Confirm no covering index exists and that `architecture-backend` is inactive.

Discard candidates that are clearly placeholders, comments, fixtures, or test seed data unless they ship to production.

## Phase 4: Generate Report

```markdown
# Static Database Hygiene Report

**Scope:** {scope}
**Status:** {PASS | FAIL}
**Tier:** 2 (stack-gated: HAS_DATABASE)
**Mode:** STATIC — repo files only, no DB connection, no SQL executed

## Summary

{N} RLS gaps, {M} SECURITY DEFINER search_path issues, {K} migration ordering/drift issues, {P} PII-without-RLS columns, {F} unindexed FKs.

## Findings

| # | Type | File:Line | Category | Severity | Detail |
|---|------|-----------|----------|----------|--------|
| 1 | RLS-off / USING(true) | `{file}:{line}` | DATA_LEAK | {see CRITERIA.md} | {table/policy} |
| 2 | SECURITY DEFINER search_path | `{file}:{line}` | INJECTION | {see CRITERIA.md} | {function} |
| 3 | Migration drift/ordering | `{file}:{line}` | DATA_INTEGRITY | {see CRITERIA.md} | {gap/dup/edit} |
| 4 | PII column without RLS | `{file}:{line}` | DATA_LEAK | {see CRITERIA.md} | {column/table} |
| 5 | Unindexed FK | `{file}:{line}` | DATA_INTEGRITY | {see CRITERIA.md} | {fk column} |

## Recommended Actions

- Enable RLS and replace blanket `USING (true)` predicates with row-scoped predicates.
- Pin `SET search_path` on every `SECURITY DEFINER` function.
- Resolve migration ordering gaps; never edit an already-applied migration — add a new one.
- Add an RLS policy for any table holding PII columns exposed to client roles.
- Add a covering index for each foreign key (if architecture-backend is not already tracking it).

## INFO — Live audit not performed here

[INFO] god-review's database-audit lens is STATIC (repo files only) and cannot run the live, credentialed checks (advisors, live RLS coverage, pg_stats column analysis, connection/pooler/control-plane). Run `/database-audit` against a **dev branch** for those live checks.
```

## Phase 5: Output

1. Save findings to `tmp/god-review/principles/database-audit-findings.md`.
2. ALWAYS emit the single INFO finding above recommending `/database-audit` on a dev branch — even on PASS — because the live checks were not (and cannot be) performed here.
3. Print summary:
   - PASS: no owned violations found in repo SQL/schema files.
   - FAIL: any owned violation found.

```bash
mkdir -p tmp/god-review/principles
```

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity/category definitions. This principle uses ONLY the existing categories `DATA_INTEGRITY`, `INJECTION`, `DATA_LEAK` and defers all severity taxonomy to CRITERIA.md.

- **PASS**: No RLS-off/blanket policies, no unpinned SECURITY DEFINER, no migration ordering/drift gaps, no PII-without-RLS, no unindexed FK (when owned) in tracked repo SQL/schema files.
- **FAIL**: Any owned violation present.

## Known Issues (don't re-report)

- Load from `tmp/god-review/context-package.md` known-issues section if available.
- `service_role` keys / `.env` secret leakage — owned by `secret-leak`. Do NOT re-report secret values appearing in source or migrations.
- N+1 query patterns / runtime query shape / query-in-loop — owned by `architecture-backend`. This is a STATIC schema lens; it does not analyze runtime query patterns.
- Unindexed foreign keys when `architecture-backend` is active — that principle owns it; this lens defers (see Phase 2.5).
- Live-only concerns (advisors, live RLS coverage, pg_stats column stats, pooler/connection/control-plane health) are out of scope by design — they are surfaced via the single INFO recommending `/database-audit`, not as findings here.

Run analysis on: $ARGUMENTS (or full repo if empty).
