# database-audit — Portable Core Query Library

This file is a **fixed library** of provider-agnostic `pg_catalog` / `information_schema` / `pg_stats` queries. It is `Read` by the `/database-audit` orchestrator. **Its queries are dispatched only AFTER the prod guard resolves (Phase 0b in `guards.md`).** No query in this file may run before the guard discharges — and per SELECT-only guard rule 1 (`guards.md`), these queries are a FIXED library: they must be issued verbatim, never dynamically constructed from variables.

Every query below runs identically on any Postgres (Supabase, Neon, vanilla). It is dispatched either via the universal `psql "$DATABASE_URL"` path wrapped in `BEGIN READ ONLY; … ROLLBACK;` (see `guards.md` rule 6) or via a provider MCP read-only SQL tool. Each query keeps its severity assignment exactly as below, EXCEPT Q2.1 (RLS-off), whose severity is context-dependent and set by the provider adapter — see the Module 2 note.

Supabase-specific checks (`get_advisors`, anon/RLS classification, storage, edge functions, realtime, auth manual checks) are NOT here — they live in `providers/supabase.md`.

---

## Module 1 — Schema

Skip this phase if `--only` is set and does not include `schema`.

On any MCP/SQL error: emit `[INFO] Module 1 — {tool} unavailable: {error}` and continue.

### Q1.1 — Tables without primary key

```sql
SELECT n.nspname AS schema, c.relname AS table
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind IN ('r','p')
  AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
  );
```

Severity: CRITICAL.

### Q1.2 — FKs without backing index (1-based slice, composite FKs are INFO candidates)

```sql
SELECT c.conrelid::regclass AS table, c.conname AS fk,
       array_length(c.conkey, 1) AS fk_col_count
FROM pg_constraint c
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND (i.indkey::int2[])[1:array_length(c.conkey,1)] = c.conkey
      AND i.indpred IS NULL
      AND i.indisvalid
  );
```

Use the returned `fk_col_count` to split deterministically: `fk_col_count = 1` (single-column FK miss) → HIGH. `fk_col_count > 1` (multi-column FK miss) → INFO (order-sensitive; treat as candidate, flag for manual review).

### Q1.3 — Unused indexes (gated on stats age)

```sql
SELECT s.schemaname, s.relname AS table, s.indexrelname AS idx, s.idx_scan
FROM pg_stat_user_indexes s
JOIN pg_stat_bgwriter b ON TRUE
WHERE s.idx_scan = 0
  AND b.stats_reset IS NOT NULL
  AND now() - b.stats_reset > interval '7 days';
```

Because this query filters on `stats_reset > 7 days`, an empty result is ambiguous: it could mean "no unused indexes" OR "stats too young to judge." To disambiguate, FIRST run the companion stats-age probe below (also a vetted fixed-library query), then run the unused-index query above:

```sql
-- Q1.3-age — unused-index analysis precondition (run before Q1.3)
SELECT stats_reset, now() - stats_reset AS stats_age
FROM pg_stat_bgwriter;
```

Interpret using the companion result:
- If `stats_age < interval '7 days'` OR `stats_reset IS NULL` → emit the INFO `unused-index analysis skipped — stats reset within last 7 days` and do NOT report a clean unused-index result (the Q1.3 result is uninformative in this state).
- Otherwise → the Q1.3 result is meaningful: an empty result is a genuine "no unused indexes," and any rows are LOW findings. Severity of findings: LOW.

### Q1.4 — Duplicate indexes

```sql
SELECT indrelid::regclass AS table,
       array_agg(indexrelid::regclass) AS duplicates
FROM pg_index
GROUP BY indrelid, indkey
HAVING count(*) > 1;
```

Severity: MEDIUM. Caveat: this groups by `(indrelid, indkey)` only, ignoring predicates/opclasses/uniqueness/INCLUDE columns — candidates only; verify equivalence (same predicate, opclass, uniqueness, INCLUDE columns) before acting; emit as INFO-with-verify, not an automatic MEDIUM, when any grouped index differs in those dimensions.

### Q1.5 — Columns with 100% NULL

```sql
SELECT schemaname, tablename, attname, null_frac
FROM pg_stats
WHERE schemaname = 'public' AND null_frac = 1.0;
```

Severity: MEDIUM.

### Q1.6 — Columns with one distinct value

```sql
SELECT schemaname, tablename, attname, n_distinct
FROM pg_stats
WHERE schemaname = 'public' AND n_distinct = 1;
```

Severity: LOW.

### Q1.7 — Tables missing BOTH created_at and updated_at

```sql
SELECT t.table_name
FROM information_schema.tables t
WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema = t.table_schema
      AND c.table_name = t.table_name
      AND c.column_name IN ('created_at','updated_at')
  );
```

Severity: LOW.

### Q1.8 — Naming-case inconsistency

```sql
SELECT table_name,
       bool_or(column_name ~ '[A-Z]') AS has_camel,
       bool_or(column_name ~ '_')     AS has_snake
FROM information_schema.columns
WHERE table_schema = 'public'
GROUP BY table_name
HAVING bool_or(column_name ~ '[A-Z]') AND bool_or(column_name ~ '_');
```

Severity: LOW.

### Migration drift

Compare migration filenames recorded in the DB against `./<migrations-dir>/*.sql` on disk (the provider adapter supplies how the applied-migrations list is obtained — Supabase via `list_migrations`, others via the migrations bookkeeping table / on-disk only). Files present locally but not in DB → HIGH. Files in DB but not locally → MEDIUM.

Orphaned-row detection emitted as INFO manual-check item ("Cost too high to run per-FK queries automatically — verify referential integrity manually").

---

## Module 2 — RLS

Skip this phase if `--only` is set and does not include `rls`.

On any MCP/SQL error: emit `[INFO] Module 2 — {tool} unavailable: {error}` and continue.

Note: RLS-off severity is CONTEXT-DEPENDENT (not a floor). It is CRITICAL when the table is reachable via an exposed data API (Supabase `anon` / Neon Data API), HIGH otherwise (vanilla Postgres with no anon role or public API surface). The provider adapter sets the final value; the portable query only reports the condition.

### Q2.1 — RLS off on public tables

```sql
SELECT c.relname AS table
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND c.relrowsecurity = false;
```

Severity: CONTEXT-DEPENDENT (not a floor) — CRITICAL when the table is reachable via an exposed data API (Supabase `anon` / Neon Data API), HIGH otherwise (vanilla Postgres). The provider adapter sets the final value; this query reports the condition. See the section note above.

### Q2.2 — RLS on but no policies

```sql
SELECT c.relname AS table
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'public' AND c.relrowsecurity = true
  AND NOT EXISTS (
    SELECT 1 FROM pg_policies p
    WHERE p.schemaname = n.nspname AND p.tablename = c.relname
  );
```

Severity: HIGH (RLS on with zero policies means all rows are locked out silently).

### Q2.3 — All policies (heuristic scan)

```sql
SELECT schemaname, tablename, policyname, cmd, roles, qual, with_check
FROM pg_policies WHERE schemaname = 'public';
```

Apply heuristics to results:
- `qual = 'true'` → CRITICAL (blanket permissive — USING clause matches every row)
- `with_check = 'true'` AND `cmd IN ('INSERT','UPDATE','ALL')` → CRITICAL (blanket permissive — unconditional WITH CHECK lets any row be written; catches INSERT/UPDATE policies whose permissiveness lives in `with_check`, not `qual`)
- `qual` contains `auth.uid()` without `(select auth.uid())` → MEDIUM (per-row re-eval perf bug)
- `'anon'` in roles AND `cmd IN ('INSERT','UPDATE','DELETE')` → HIGH

Policy expressions included in findings with redaction rule 2 prefix applied (see `redaction.md`).

### Q2.4 — SECURITY DEFINER functions with mutable search_path

```sql
SELECT n.nspname AS schema, p.proname AS function
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.prosecdef = true
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND (
    p.proconfig IS NULL
    OR NOT EXISTS (
      SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%'
    )
  );
```

Severity: HIGH.

### Q2.5 — Materialized views bypassing RLS

```sql
SELECT schemaname, matviewname
FROM pg_matviews
WHERE schemaname = 'public';
```

Caveat: candidates only — the fixed query lists matviews; determining whether a matview reads RLS-protected tables requires reading its definition (`pg_get_viewdef`) during deep analysis. Emit as INFO-with-verify (flag for manual review), not an automatic MEDIUM, unless deep analysis confirms it reads an RLS-protected table. Note: matviews run as owner and ignore RLS on underlying tables.

---

## Module 3 — Security (portable subset)

Skip this phase if `--only` is set and does not include `security`.

On any MCP/SQL error: emit `[INFO] Module 3 — {tool} unavailable: {error}` and continue.

> Provider-specific security steps (Supabase security advisors, risky-extension and pg_cron inventory) live in `providers/*.md`. The provider-agnostic FILESYSTEM security checks (repo secret scan, tracked-files secret scan, .env-tracked check) are NOT here — they are zero-data-touch and live in the **Filesystem security** module at the bottom of this file (so they also run in the prod-stop path). Only the portable SQL checks are below.

### Q3.1 — PII inventory (PII-sensitive columns with anon SELECT access)

The schema-list and exposed-role are PARAMETERS the provider adapter supplies. Defaults (Supabase / vanilla): `schema IN ('public')` and `grantee = 'anon'`. The **Neon adapter** passes `schema IN ('public','neon_auth')` and `grantee = 'anonymous'`. The query is still a vetted fixed-library constant — the adapter selects from the documented parameter sets below, it does not construct arbitrary SQL.

Default (Supabase / vanilla) form:

```sql
SELECT c.table_schema, c.table_name, c.column_name
FROM information_schema.columns c
WHERE c.table_schema IN ('public')
  AND c.column_name ~* 'email|phone|ssn|dob|address|ip_addr|token|password|secret'
  AND EXISTS (
    SELECT 1 FROM information_schema.role_table_grants g
    WHERE g.table_schema = c.table_schema
      AND g.table_name = c.table_name
      AND g.grantee = 'anon'
      AND g.privilege_type = 'SELECT'
  );
```

Neon adapter form (schema-list and role swapped per the parameters above):

```sql
SELECT c.table_schema, c.table_name, c.column_name
FROM information_schema.columns c
WHERE c.table_schema IN ('public','neon_auth')
  AND c.column_name ~* 'email|phone|ssn|dob|address|ip_addr|token|password|secret'
  AND EXISTS (
    SELECT 1 FROM information_schema.role_table_grants g
    WHERE g.table_schema = c.table_schema
      AND g.table_name = c.table_name
      AND g.grantee = 'anonymous'
      AND g.privilege_type = 'SELECT'
  );
```

Severity: HIGH. Report column NAMES only — never SELECT actual PII values (see `redaction.md` rule 3).

### Q3.3 — Functions with dynamic SQL (prosrc, not pg_get_functiondef)

```sql
SELECT n.nspname, p.proname, p.prosrc
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.prosrc ~* 'EXECUTE\s'
LIMIT 50;
```

This catches all PL/pgSQL dynamic SQL — `EXECUTE format(...)`, `EXECUTE sql_text`, `EXECUTE '...'` — not just `EXECUTE format`. Any row → HIGH finding (SQL-injection surface). During deep analysis, exclude the safe `EXECUTE ... USING` bound-parameter-only forms (no string concatenation into the statement) as non-findings. `prosrc` contents redacted if they contain secret-shaped strings (see `redaction.md` rule 1).

---

## Module 4 — Production Readiness (portable subset)

Skip this phase if `--only` is set and does not include `prod`.

On any MCP/SQL error: emit `[INFO] Module 4 — {tool} unavailable: {error}` and continue.

> Provider-specific prod-readiness steps (performance advisors, slow-query logs, pooler-port grep, manual checks) live in `providers/*.md`. The provider-agnostic FILESYSTEM prod checks (seed-data check, env-drift check) are NOT here — they are zero-data-touch and live in the **Filesystem security** module at the bottom of this file. Only the portable SQL checks are below.

### Q4.1 — Postgres version check

```sql
SELECT current_setting('server_version') AS version;
```

The provider adapter supplies the supported-major-version list and any EOL-staleness note. Extract the major version from the result; if not in the provider's supported list → HIGH.

### Q4.2 — Connection saturation (severity scales with the active/max ratio)

```sql
SELECT
  (SELECT count(*) FROM pg_stat_activity WHERE state = 'active') AS active,
  current_setting('max_connections')::int AS max_conn;
```

Severity scales with the active/max ratio (`N/M`) to avoid flagging healthy databases as findings (no-noise principle):
- ratio `< 80%` → INFO
- ratio `>= 80%` → MEDIUM
- ratio `>= 95%` → HIGH

Body includes: `"active N of max M (N/M%)"`.

---

## Module FS — Filesystem security (zero-data-touch; runs in prod-stop path too)

These checks are **provider-agnostic**, touch **no database** (only the local filesystem + read-only git), and are exactly the "filesystem / grep / secret-scan / migration-on-disk" modules the prod guard's `run_filesystem_only_modules` promises in `guards.md`. They run in BOTH paths:

- **Normal path:** gated by `--only` as noted per check below (secret/.env checks under `security`, seed-data under `security`, env-drift under `prod`). When `--only` is unset, all run.
- **Prod-stop path:** when the prod guard fires PROD without `--env=prod`, `guards.md` `run_filesystem_only_modules` runs the SAME canonical filesystem-only set BEFORE the STOP — FS.1–FS.4 (security), FS.5 env-drift (prod-gated), migration-on-disk drift (schema/prod), and the always-on `.gitignore tmp/` check — honoring `--only` via each module's governing token. These are the only checks allowed to run against an unconfirmed prod, because they issue zero data-plane SQL. The set is identical to the no-connection case (a) path; see the canonical rule in `guards.md` (`run_filesystem_only_modules`).

**Read-only constraint:** the only `git` subcommands permitted here are `git ls-files`, `git grep`, and `git check-ignore`. No mutating git. No filesystem writes outside `./tmp/db-audit/`.

**Portability constraint (macOS/Darwin):** there is NO GNU `xargs -r` on Darwin. Never rely on `xargs -r`. FS.1 and FS.2 must report `file:line` (use `grep -n` / `git grep -n` — NOT `grep -l`, which gives filenames only). For the tracked-files scan, use NUL-delimited plumbing so filenames with spaces survive — `git grep -n PATTERN` (preferred — handles this natively and no-ops cleanly with no match), OR `git ls-files -z | xargs -0 grep -n PATTERN`. Never use a newline-`xargs` form for the tracked scan:

```bash
git grep -n PATTERN   # preferred: file:line output, clean no-op on no match
# or, NUL-delimited (survives spaces in filenames):
git ls-files -z | xargs -0 grep -n PATTERN
```

**Redaction (mechanical, redact-before-print):** any matched secret VALUE reported by these checks is redacted per `redaction.md` (rule 1 for secret/JWT values, rule 4 for env-key names, rule 5 for `postgres://`/`postgresql://` connection strings) — never echo a raw secret value or connection string. A raw `grep -n` prints the WHOLE matching line, which contains the raw secret; pipe every match through the redaction step (`redaction.md` rules 1–5) BEFORE anything is written or printed, so output is `file:line` + `[REDACTED:<8hex>]` and NEVER the raw matched content. Report file names, line numbers, key names, and `[REDACTED:…]` placeholders only.

### FS.1 — Repo secret scan (`--only=security`)

Grep the working tree for leaked secrets. **Exclude** these paths/globs:
`node_modules/`, `.git/`, `.next/`, `.nuxt/`, `dist/`, `build/`, `out/`, `.vercel/`, `.netlify/`, `storybook-static/`, `.turbo/`, `coverage/`, `supabase/.branches/`, `tmp/`, `*.lock`.

Patterns (provider-agnostic — Supabase keys AND generic connection-string / service-role leakage):
- `SUPABASE_SERVICE_ROLE_KEY`
- `service_role`
- `DATABASE_URL` and connection-string shapes (`postgres://`, `postgresql://`) — generic, so this is not Supabase-only
- `(=|:|"|')eyJ[A-Za-z0-9_-]{20,}` (JWT in assignment/string context — tightened to avoid base64 false positives)

**Never print the raw matched line.** A default `grep` prints the entire matching line, which can contain a raw `DATABASE_URL`, JWT, or service-role key. Pipe every FS.1 match through the redaction pass (`redaction.md` rules 1–5) BEFORE anything is written or printed, and report only FILENAME + line number + a `[REDACTED:<first-8-of-sha256>]` placeholder. Report match LOCATIONS, not match CONTENTS. Use `grep -n` for line numbers and discard the matched text after redaction.

Classification:
- Match in a **client-reachable** path (`src/`, `app/`, `components/`, `pages/`, `public/`, `.env.local`) → **CRITICAL** (location-only; value redacted per `redaction.md`).
- Match in `server/`, `api/`, `edge/`, `scripts/` → **INFO** (expected server-side usage).

### FS.2 — Tracked-files secret scan (`--only=security`)

Scan **git-tracked** files for the SAME secret pattern set as FS.1 (don't let the tracked-file scan miss what the repo scan catches): `SUPABASE_SERVICE_ROLE_KEY`, `service_role`, generic `DATABASE_URL` and connection-string shapes (`postgres://`, `postgresql://`), and the JWT-in-assignment shape (`(=|:|"|')eyJ[A-Za-z0-9_-]{20,}`). Any match → **HIGH**. **Never print the raw matched line** — a `grep -n` prints the whole matching line (which contains the raw secret); pipe every FS.2 match through the redaction pass (`redaction.md` rules 1–5) BEFORE anything is written or printed, and report the **filename + line number** (`file:line`) only, with the value as a `[REDACTED:<first-8-of-sha256>]` placeholder. Report match LOCATIONS, not match CONTENTS. Use `grep -n` / `git grep -n` for line numbers — NOT `grep -l` (filenames only).

Use NUL-delimited plumbing so filenames with spaces survive (Darwin has no GNU `xargs -r`):

```bash
git grep -n 'SUPABASE_SERVICE_ROLE_KEY\|service_role\|postgres://\|postgresql://\|DATABASE_URL\|\(=\|:\|"\|'\''\)eyJ[A-Za-z0-9_-]\{20,\}'
# preferred: file:line output, native NUL-safe over tracked files, clean no-op on no match.
# Equivalent NUL-delimited form:
git ls-files -z | xargs -0 grep -n 'SUPABASE_SERVICE_ROLE_KEY\|service_role\|postgres://\|postgresql://\|DATABASE_URL\|\(=\|:\|"\|'\''\)eyJ[A-Za-z0-9_-]\{20,\}'
```

Read-only git only (`git ls-files` / `git grep`); no mutation. Pipe the `file:line` output through the redaction step before printing — never emit the raw matched line.

### FS.3 — .env-tracked check (`--only=security`)

`.env`, `.env.local`, `.env.production` must be gitignored. If any of these files EXISTS in the working tree AND is tracked by git → **CRITICAL** (secrets are committed). Use read-only `git ls-files <name>` (a tracked file prints; untracked prints nothing) or `git check-ignore <name>`; emit one finding per tracked env file. Report the filename only — never the contents.

### FS.4 — Seed-data check (`--only=security`)

Read `./supabase/seed.sql` (and the generic `./seed.sql`, `./db/seed.sql`). If none exist → skip silently (no finding). If present, scan for `test@test.com`, `password='admin'`, `admin:admin`, `123456`. Any match → **MEDIUM** (weak/placeholder credentials in seed data). Redact matched password literals per `redaction.md` rule 1. Not Supabase-specific — the generic seed paths make it portable.

### FS.5 — Env-drift check (`--only=prod`)

Grep the repo for environment-variable reads: `process.env.X`, `Deno.env.get('X')`, `import.meta.env.X`. Collect the referenced key NAMES. Compare them to the keys defined in `.env.production`. Any key referenced in code but MISSING from `.env.production` → **HIGH**. Emit key **NAMES only**, never values (`redaction.md` rule 4).

If `.env.production` does not exist → emit `[INFO] No .env.production file present; env-drift check skipped.` Do not error.
