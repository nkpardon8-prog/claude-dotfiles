# database-audit — Portable Core Query Library

This file is a **fixed library** of provider-agnostic `pg_catalog` / `information_schema` / `pg_stats` queries. It is `Read` by the `/database-audit` orchestrator. **Its queries are dispatched only AFTER the prod guard resolves (Phase 0b in `guards.md`).** No query in this file may run before the guard discharges — and per SELECT-only guard rule 1 (`guards.md`), these queries are a FIXED library: they must be issued verbatim, never dynamically constructed from variables.

Every query below runs identically on any Postgres (Supabase, Neon, vanilla). It is dispatched either via the universal `psql "$DATABASE_URL"` path wrapped in `BEGIN READ ONLY; … ROLLBACK;` (see `guards.md` rule 6) or via a provider MCP read-only SQL tool. Each query keeps its severity assignment exactly as below, EXCEPT Q2.1 (RLS-off), whose severity is context-dependent and set by the provider adapter — see the Module 2 note.

Supabase-specific checks (`get_advisors`, anon/RLS classification, storage, edge functions, realtime, auth manual checks) are NOT here — they live in `providers/supabase.md`.

---

## Table of contents

| Module | Title | `--only` token |
|--------|-------|----------------|
| 1  | Schema                                  | `schema`      |
| 2  | RLS                                     | `rls`         |
| 3  | Security (portable subset)              | `security`    |
| 4  | Production Readiness (portable subset)  | `prod`        |
| 5  | Client integration (provider-driven)    | `client`      |
| 6  | Operational Health                      | `health`      |
| 7  | Config & CIS                            | `config`      |
| 8  | Privileges & Roles                      | `privileges`  |
| 9  | Schema Integrity                        | `integrity`   |
| 10 | Audit Logging & Compliance              | `compliance`  |
| 11 | Encryption (in-transit / at-rest)       | `compliance`  |
| 12 | PII Governance                          | `pii`         |
| 13 | Migration Safety lint (filesystem)      | `migrations`  |
| 14 | Backup & Recovery                       | `backup`      |
| 15 | Exfiltration & Supply-Chain             | `exfil`       |
| FS | Filesystem security (zero-data-touch)    | per-check     |

---

## Preamble queries (run first in the health/config batch, behind the discharged prod guard — NOT preflight)

These three named queries are **data-plane SQL** and MUST run as the first queries INSIDE the Phases 1–4 health/config module batch, behind the discharged prod guard — exactly like Q4.1 reads the version today. They MUST NOT run in preflight (Phase 0a): that would violate the "no data-plane SQL before the prod guard discharges" invariant. On case (a) no-connection and case (b) prod-stop, none of these run, the results are unknown, and every downstream version-branched / capability-gated check emits its `[INFO] … skipped — no connection` form.

Run each ONCE. Downstream modules **REFERENCE these results, they never re-query** (N+1 prevention — do NOT re-`SELECT … FROM pg_extension` or re-probe capability per module).

### Preamble P1 — Server-major-version probe (`server_major`)

```sql
SELECT current_setting('server_version_num')::int / 10000 AS server_major;
```

`server_major` feeds the §B version branches (6.13, 6.18, 6.19). **This probe is intentionally SEPARATE from Q4.1** (`current_setting('server_version')` string under the `prod` token for EOL-policy matching): P1 is the integer major used for catalog branching under `health`/`config`. Do NOT consolidate them — `--only=health` without `prod` must still get `server_major`.

### Preamble P2 — Capability probe (`has_monitor`, `has_read_all_stats`)

```sql
SELECT pg_has_role(current_user,'pg_monitor','USAGE')        AS has_monitor,
       pg_has_role(current_user,'pg_read_all_stats','USAGE') AS has_read_all_stats;
```

Feeds the §C silent-blanking gate. If BOTH columns are false, the cross-session-visibility checks (6.3, 6.9, 6.10, 6.13, and Module 11 `pg_stat_ssl`) emit their partial-visibility INFO **unconditionally — never a clean pass — regardless of row contents** (a restricted role cannot distinguish "blank because restricted" from "blank because idle").

### Preamble P3 — Extension inventory

```sql
SELECT extname, extversion, n.nspname AS ext_schema
FROM pg_extension e JOIN pg_namespace n ON e.extnamespace = n.oid;
```

The single source of truth for installed extensions + their schema placement. Referenced by 6.13/6.14 (`pg_stat_statements`), Module 10 (pgaudit/pgcrypto/anon), Module 12 (anon/vault), 15.1 (postgres_fdw/dblink), and 15.4 (extension-in-public + currency). Do NOT re-`SELECT … FROM pg_extension` per module — read this result.

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
JOIN pg_stat_database d ON d.datname = current_database()
WHERE s.idx_scan = 0
  AND d.stats_reset IS NOT NULL
  AND now() - d.stats_reset > interval '7 days';
```

Because this query filters on `stats_reset > 7 days`, an empty result is ambiguous: it could mean "no unused indexes" OR "stats too young to judge." To disambiguate, FIRST run the companion stats-age probe below (also a vetted fixed-library query), then run the unused-index query above:

```sql
-- Q1.3-age — unused-index analysis precondition (run before Q1.3)
-- Gate on the CURRENT database's index-counter reset clock (pg_stat_database),
-- NOT pg_stat_bgwriter (which is the bgwriter/checkpointer reset clock).
SELECT stats_reset, now() - stats_reset AS stats_age
FROM pg_stat_database
WHERE datname = current_database();
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

**Canonical migration-drift finding identity (MANDATORY).** Migration drift can be emitted by more than one module — this core Module 1 AND a provider platform path (e.g. the Supabase `list_migrations` step). To let Phase 6 dedup (which keys on `(severity, title, object_name)`) collapse the duplicates, ANY module emitting a migration-drift finding (core Module 1 OR a provider platform path) MUST use this EXACT title and `object_name`:
- direction local-not-in-DB → title exactly `Migration drift: local-not-in-DB`, severity HIGH
- direction in-DB-not-local → title exactly `Migration drift: in-DB-not-local`, severity MEDIUM
- `object_name` = the bare migration filename (no path, no directory prefix) — one finding per drifted filename

Do NOT phrase the title any other way. Identical title + `object_name` across emitters is what makes dedup collapse them into one finding.

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

Apply the PORTABLE (provider-agnostic) blanket-permissive heuristics to results:
- `qual = 'true'` → CRITICAL (blanket permissive — USING clause matches every row)
- `with_check = 'true'` AND `cmd IN ('INSERT','UPDATE','ALL')` → CRITICAL (blanket permissive — unconditional WITH CHECK lets any row be written; catches INSERT/UPDATE policies whose permissiveness lives in `with_check`, not `qual`)

These two heuristics are provider-agnostic (they reference no provider-specific role or helper) and stay here. Provider adapters may apply ADDITIONAL provider-specific policy heuristics (e.g. `anon`-role write exposure, `auth.uid()` re-eval) to this same Q2.3 result set — those live in the provider file (`providers/supabase.md` for the Supabase `anon`/`auth.uid()` heuristics, `providers/neon.md` for the `anonymous`/`auth.user_id()` analog), applied on top of the core Q2.3 result. Do NOT duplicate them here, so a single policy row never gets two severity mechanisms from this file.

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

### Q2.6 — FORCE RLS gap [RO] (`rls`)

```sql
SELECT n.nspname, c.relname
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'public'
  AND c.relrowsecurity = true
  AND c.relforcerowsecurity = false;
```

A table with RLS enabled but FORCE RLS off is still bypassed by the table OWNER (and any role with `BYPASSRLS`), silently — policies do not apply to the owner. If the application connects as the table owner (common with a single bootstrap role), every RLS policy is a no-op for it. Scoped to `public` to match Q2.1/Q2.2; **non-public RLS tables are NOT covered by this check** (so Module 8.5's cross-ref does not over-claim).

Severity: MEDIUM (CRITICAL if the application connects as the table owner).

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
# ALWAYS pipe matches through the redaction step BEFORE anything is printed/written.
# <redact-pipe> applies redaction.md rules 1–5 to each "file:line:rawmatch" line,
# emitting "file:line  [REDACTED:<8hex>]" and DISCARDING the raw matched content.
git grep -n PATTERN | <redact-pipe>            # preferred: file:line, clean no-op on no match
# or, NUL-delimited (survives spaces in filenames):
git ls-files -z | xargs -0 grep -n PATTERN | <redact-pipe>
```

**WARNING: NEVER run the bare `git grep -n PATTERN` (or `grep -n PATTERN`) without the `<redact-pipe>` — the raw match contains the secret** (full `DATABASE_URL` / JWT / service-role value). The redact pipe (`redaction.md` rules 1–5) must consume the match before any byte reaches stdout, a file, or the report.

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
# ALWAYS terminate with | <redact-pipe> (redaction.md rules 1–5): it turns each
# "file:line:rawmatch" into "file:line  [REDACTED:<8hex>]" and discards the raw secret.
git grep -n 'SUPABASE_SERVICE_ROLE_KEY\|service_role\|postgres://\|postgresql://\|DATABASE_URL\|\(=\|:\|"\|'\''\)eyJ[A-Za-z0-9_-]\{20,\}' | <redact-pipe>
# preferred: file:line output, native NUL-safe over tracked files, clean no-op on no match.
# Equivalent NUL-delimited form:
git ls-files -z | xargs -0 grep -n 'SUPABASE_SERVICE_ROLE_KEY\|service_role\|postgres://\|postgresql://\|DATABASE_URL\|\(=\|:\|"\|'\''\)eyJ[A-Za-z0-9_-]\{20,\}' | <redact-pipe>
```

**WARNING: NEVER run the bare grep above without the trailing `| <redact-pipe>` — `git grep -n` prints the WHOLE matching line, which contains the raw `DATABASE_URL` / JWT / service-role secret.** Read-only git only (`git ls-files` / `git grep`); no mutation. Every match must pass through the redaction step before any byte reaches stdout, a file, or the report — emit `file:line` + `[REDACTED:<8hex>]` only, never the raw matched line.

### FS.3 — .env-tracked check (`--only=security`)

`.env`, `.env.local`, `.env.production` must be gitignored. If any of these files EXISTS in the working tree AND is tracked by git → **CRITICAL** (secrets are committed). Use read-only `git ls-files <name>` (a tracked file prints; untracked prints nothing) or `git check-ignore <name>`; emit one finding per tracked env file. Report the filename only — never the contents.

### FS.4 — Seed-data check (`--only=security`)

Read `./supabase/seed.sql` (and the generic `./seed.sql`, `./db/seed.sql`). If none exist → skip silently (no finding). If present, scan for `test@test.com`, `password='admin'`, `admin:admin`, `123456`. Any match → **MEDIUM** (weak/placeholder credentials in seed data). Redact matched password literals per `redaction.md` rule 1. Not Supabase-specific — the generic seed paths make it portable.

### FS.5 — Env-drift check (`--only=prod`)

Grep the repo for environment-variable reads: `process.env.X`, `Deno.env.get('X')`, `import.meta.env.X`. Collect the referenced key NAMES. Compare them to the keys defined in `.env.production`. Any key referenced in code but MISSING from `.env.production` → **HIGH**. Emit key **NAMES only**, never values (`redaction.md` rule 4).

If `.env.production` does not exist → emit `[INFO] No .env.production file present; env-drift check skipped.` Do not error.

---

## Module 6 — Operational Health (`health`)

Skip this phase if `--only` is set and does not include `health`.

On any MCP/SQL error: emit `[INFO] Module 6 — {tool} unavailable: {error}` and continue.

This module runs the §B version probe (Preamble P1), the §C capability probe (Preamble P2), and the P3 extension inventory FIRST (once), then references those results below. **Staging:** the high-yield pure-`[RO]` outage-causers are authored first (6.4, 6.6, 6.7, 6.2, 6.19), then the always-assessable `[RO]` checks (6.1, 6.11, 6.12, 6.15, 6.16, 6.17, 6.18), then the `[RO+priv]` / `[EXT]` second wave (6.3, 6.5, 6.8, 6.9, 6.10, 6.13, 6.14) which mostly INFO-skip on managed providers.

### Q6.4 — XID wraparound horizon [RO] (`health`)

```sql
SELECT datname, age(datfrozenxid) AS xid_age,
       current_setting('autovacuum_freeze_max_age')::int AS freeze_max
FROM pg_database
ORDER BY xid_age DESC
LIMIT 50;
```

Per-table attribution (bounded scan + total count):

```sql
SELECT n.nspname, c.relname, age(c.relfrozenxid) AS xid_age,
       (SELECT count(*) FROM pg_class WHERE relkind IN ('r','m','t')) AS total_relations
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind IN ('r','m','t')
ORDER BY xid_age DESC
LIMIT 50;
```

`xid_age` is how many transactions old the oldest unfrozen row is. As it approaches `autovacuum_freeze_max_age` (default 200M) autovacuum should freeze; if it keeps climbing toward 2^31 (~2.1B) the database will force a shutdown to prevent wraparound corruption. Flag `xid_age` > 80% of `autovacuum_freeze_max_age`. CRITICAL when > 90% of the freeze-max or approaching 2^31.

Severity: HIGH (CRITICAL near the wraparound threshold).

### Q6.6 — Sequence / int4-PK exhaustion [RO] (`health`)

Two parts. First, raw sequence consumption from `pg_sequences`:

```sql
SELECT schemaname, sequencename, last_value, max_value
FROM pg_sequences
ORDER BY (last_value::numeric / NULLIF(max_value,0)) DESC NULLS LAST
LIMIT 50;
```

Second, the int4-backed-PK linkage — the one genuinely tricky join, given **VERBATIM** (prose invites a wrong `pg_depend` direction). The sequence is the dependent object (`objid`); the table+column it feeds is the referenced object (`refobjid` + `refobjsubid`); both `classid` and `refclassid` are `pg_class`; `deptype` `'a'` = serial `OWNED BY`, `'i'` = `GENERATED … AS IDENTITY`:

```sql
SELECT s.relname AS sequence_name,
       t.relname AS table_name,
       a.attname AS column_name,
       seq.last_value
FROM pg_depend d
JOIN pg_class s ON s.oid = d.objid
JOIN pg_class t ON t.oid = d.refobjid
JOIN pg_attribute a ON (a.attrelid = d.refobjid AND a.attnum = d.refobjsubid)
JOIN pg_sequences seq ON (seq.schemaname = (SELECT nspname FROM pg_namespace WHERE oid = s.relnamespace)
                          AND seq.sequencename = s.relname)
WHERE d.classid = 'pg_class'::regclass
  AND d.refclassid = 'pg_class'::regclass
  AND d.deptype IN ('a','i')
  AND a.atttypid = 'int4'::regtype
ORDER BY seq.last_value DESC NULLS LAST
LIMIT 50;
```

An `int4` PK overflows at 2^31 (~2.147B). When a sequence backing an `int4` column has `last_value` approaching that, inserts will start failing. A bare app-assigned `int4` PK with no backing sequence cannot be measured here → report "int4 PK present (no sequence to measure)". **Degradation (false-clean class):** `pg_sequences.last_value` returns NULL when the audit role lacks SELECT on the sequence (common on managed providers). A NULL `last_value` MUST emit `[INFO] 6.6 — sequence value not readable under current role`, **NEVER a clean pass.**

Severity: HIGH (approaching ~2.1B).

### Q6.7 — Inactive / lagging replication slots [RO] (`health`)

```sql
SELECT slot_name, slot_type, active, wal_status,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes
FROM pg_replication_slots
ORDER BY retained_bytes DESC NULLS LAST;
```

An inactive replication slot (`active = false`) keeps pinning WAL (`restart_lsn` never advances), so `retained_bytes` grows without bound until the WAL volume fills — a disk-full outage. `wal_status = 'lost'` means WAL the slot needs was already removed (the consumer is broken). Inactive slot retaining large WAL = imminent outage.

Severity: HIGH (CRITICAL when `wal_status` is `'lost'`/`'unreserved'` or retained bytes are large).

### Q6.2 — Autovacuum / analyze recency [RO] (`health`)

```sql
SELECT schemaname, relname, last_autovacuum, last_autoanalyze,
       autovacuum_count, analyze_count, n_dead_tup
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC NULLS LAST
LIMIT 50;
```

Tables that have NEVER been autovacuumed/autoanalyzed (`last_autovacuum IS NULL` and `autovacuum_count = 0`) or whose last run is very stale, especially with high `n_dead_tup`, indicate vacuum is not keeping up — bloat, stale stats, and XID-age growth follow.

Severity: HIGH if a high-traffic table was never vacuumed; MEDIUM for staleness.

### Q6.19 — Collation version mismatch [RO] (`health`) — version-branched (§B), PG≥15

If `server_major < 15` → emit `[INFO] 6.19 — collation version check requires PG15+; skipped` and do nothing else. On PG ≥ 15 the actual-version functions exist and take an OID argument (no empty-paren call).

DB-level drift:

```sql
SELECT datname, datcollversion,
       pg_database_collation_actual_version(oid) AS actual_version
FROM pg_database
WHERE datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid);
```

Collation-object-level drift:

```sql
SELECT n.nspname, cl.collname, cl.collversion,
       pg_collation_actual_version(cl.oid) AS actual_version
FROM pg_collation cl JOIN pg_namespace n ON cl.collnamespace = n.oid
WHERE cl.collversion IS DISTINCT FROM pg_collation_actual_version(cl.oid);
```

Per-INDEX attribution (which btree indexes are at risk via `pg_index.indcollation`):

```sql
SELECT n.nspname, ic.relname AS index_name, tc.relname AS table_name,
       cl.collname, cl.collversion,
       pg_collation_actual_version(cl.oid) AS actual_version
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class tc ON tc.oid = i.indrelid
JOIN pg_namespace n ON ic.relnamespace = n.oid
JOIN unnest(i.indcollation) WITH ORDINALITY AS col(colloid, ord) ON true
JOIN pg_collation cl ON cl.oid = col.colloid
WHERE col.colloid <> 0
  AND cl.collversion IS DISTINCT FROM pg_collation_actual_version(cl.oid);
```

A collation version drift after a libc/ICU upgrade means btree indexes built under the old collation may now be silently corrupt (wrong sort order → missed rows, unique-constraint violations). The per-index list says exactly which indexes need REINDEX.

Severity: HIGH.

### Q6.1 — Dead-tuple ratio / bloat estimate [RO] (`health`)

```sql
SELECT schemaname, relname, n_live_tup, n_dead_tup, n_mod_since_analyze,
       round(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0), 3) AS dead_ratio
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY dead_ratio DESC NULLS LAST
LIMIT 50;
```

A high `dead_ratio` (rule of thumb > 20% on a sizeable table) signals bloat: wasted storage and slower scans. This is a statistics-based estimate; exact bloat needs `pgstattuple` ([EXT], not run here).

Severity: MEDIUM.

### Q6.11 — Deadlocks [RO] (`health`)

```sql
SELECT datname, deadlocks, xact_rollback, xact_commit
FROM pg_stat_database
WHERE datname = current_database();
```

A nonzero and growing `deadlocks` counter indicates application lock-ordering problems. Point-in-time only (no historical rate available in a stateless audit).

Severity: INFO if low/zero; MEDIUM if notably nonzero.

### Q6.12 — Cache & index hit ratio [RO] (`health`)

```sql
SELECT datname,
       round(blks_hit::numeric / NULLIF(blks_hit + blks_read, 0), 4) AS cache_hit_ratio
FROM pg_stat_database
WHERE datname = current_database();
```

OLTP workloads target > 99% buffer cache hit ratio. A low ratio means working set does not fit in `shared_buffers` (or the instance is undersized) → heavy disk I/O.

Severity: MEDIUM if below ~99%.

### Q6.15 — Invalid indexes [RO] (`health`)

```sql
SELECT n.nspname, ic.relname AS index_name, tc.relname AS table_name,
       i.indisvalid, i.indisready
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class tc ON tc.oid = i.indrelid
JOIN pg_namespace n ON ic.relnamespace = n.oid
WHERE i.indisvalid = false OR i.indisready = false;
```

An index with `indisvalid = false` is a leftover from a failed `CONCURRENTLY` build — it consumes space, is maintained on writes, but is NOT used by the planner. (Unused / duplicate indexes are covered by Module 1 Q1.3/Q1.4 — cross-ref, not duplicated here.)

Severity: MEDIUM.

### Q6.16 — Statistics staleness [RO] (`health`)

```sql
SELECT s.schemaname, s.relname, s.n_mod_since_analyze, c.reltuples,
       current_setting('default_statistics_target') AS stats_target
FROM pg_stat_user_tables s
JOIN pg_class c ON c.relname = s.relname
WHERE s.n_mod_since_analyze > 0
ORDER BY s.n_mod_since_analyze DESC NULLS LAST
LIMIT 50;
```

A high `n_mod_since_analyze` relative to `reltuples` means the planner is working from stale row estimates → bad plans. Cross-ref Q6.2 (autovacuum recency drives ANALYZE).

Severity: MEDIUM.

### Q6.17 — Size outliers / giant unpartitioned tables [RO] (`health`)

```sql
SELECT n.nspname, c.relname,
       pg_total_relation_size(c.oid) AS total_bytes,
       (c.oid IN (SELECT partrelid FROM pg_partitioned_table)) AS is_partitioned_parent,
       (SELECT count(*) FROM pg_class WHERE relkind IN ('r','p')) AS total_relations
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
ORDER BY total_bytes DESC
LIMIT 50;
```

The largest tables, flagging any very large table that is NOT a partition parent (a giant monolithic table is a vacuum/maintenance/lock-window liability that partitioning would relieve).

Severity: INFO (MEDIUM for a very large unpartitioned hot table).

### Q6.18 — Checkpoint tuning [RO] (`health`) — version-branched (§B)

Checkpoint COUNTS only — do NOT also read buffer columns (their semantics moved at PG17). Branch on `server_major`:

PG ≥ 17 → `pg_stat_checkpointer`:

```sql
SELECT num_timed, num_requested
FROM pg_stat_checkpointer;
```

PG < 17 → `pg_stat_bgwriter`:

```sql
SELECT checkpoints_timed, checkpoints_req
FROM pg_stat_bgwriter;
```

A high ratio of requested (forced) checkpoints to timed checkpoints means `max_wal_size` is too small — checkpoints are triggered by WAL volume rather than `checkpoint_timeout`, causing I/O spikes. Flag when requested ≳ timed.

Severity: MEDIUM.

### Q6.3 — VACUUM blocked by xmin horizon [RO+priv] (`health`)

§C gate: if Preamble P2 shows `has_monitor = false AND has_read_all_stats = false`, emit `[INFO] 6.3 — partial visibility; cross-session data restricted under current role (no pg_monitor/pg_read_all_stats)` UNCONDITIONALLY (never a clean pass) and skip the query. Otherwise:

```sql
SELECT
  (SELECT min(backend_xmin) FROM pg_stat_activity WHERE backend_xmin IS NOT NULL) AS oldest_activity_xmin,
  (SELECT min(catalog_xmin) FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL) AS oldest_slot_catalog_xmin,
  (SELECT count(*) FROM pg_prepared_xacts) AS prepared_xact_count;
```

An old `backend_xmin` (a long-lived transaction), an old slot `catalog_xmin`, or a stranded prepared transaction holds back the global xmin horizon, so VACUUM cannot remove dead tuples anywhere — bloat accumulates DB-wide even though autovacuum is running.

Severity: MEDIUM (HIGH if a very old horizon blocks all cleanup).

### Q6.5 — Multixact wraparound horizon [RO] (`health`)

```sql
SELECT datname, mxid_age(datminmxid) AS mxid_age,
       current_setting('autovacuum_multixact_freeze_max_age')::int AS mxid_freeze_max
FROM pg_database
ORDER BY mxid_age DESC
LIMIT 50;
```

The multixact analog of XID wraparound (Q6.4): heavy use of row-level share locks / FKs consumes multixact IDs, which also wrap at 2^31. `mxid_age` approaching `autovacuum_multixact_freeze_max_age` (and ultimately 2^31) risks the same forced shutdown.

Severity: HIGH (CRITICAL near the threshold).

### Q6.8 — Replication lag / standby posture [RO+priv] / [PROVIDER] (`health`) — folds light-touch HA

```sql
SELECT application_name, state, sync_state,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

Plus sync posture:

```sql
SELECT current_setting('synchronous_standby_names') AS sync_standby_names;
```

Reports connected standbys (HA: standby-exists Y/N), their lag, and whether replication is synchronous (`sync_state`, `synchronous_standby_names`). Zero rows = no streaming standby attached (single point of failure for self-managed). On managed providers replication is provider-internal: if `pg_stat_replication` is empty AND this is a managed provider, emit `[PROVIDER]` manual-verify INFO `Severity-if-absent: HIGH` ("HA / replica posture → verify in provider console") rather than asserting "no standby."

Severity: MEDIUM (lag) / INFO+PROVIDER (HA posture on managed).

### Q6.9 — Idle-in-transaction + long-running-active [RO+priv] (`health`)

§C gate: if `has_monitor = false AND has_read_all_stats = false`, emit `[INFO] 6.9 — partial visibility; cross-session data restricted under current role (no pg_monitor/pg_read_all_stats)` UNCONDITIONALLY (never a clean pass) and skip. Otherwise:

```sql
SELECT
  (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction') AS idle_in_txn_count,
  (SELECT max(now() - xact_start) FROM pg_stat_activity WHERE state = 'idle in transaction') AS max_idle_in_txn_age,
  (SELECT max(now() - query_start) FROM pg_stat_activity WHERE state = 'active') AS max_active_query_age;
```

`idle in transaction` sessions hold locks and pin the xmin horizon while doing nothing — a classic bloat/lock source. A multi-hour ACTIVE query is a distinct signal (it also holds locks and pins xmin). Both warrant investigation.

Severity: MEDIUM.

### Q6.10 — Blocked queries / lock contention [RO+priv] (`health`)

§C gate: if `has_monitor = false AND has_read_all_stats = false`, emit `[INFO] 6.10 — partial visibility; cross-session data restricted under current role (no pg_monitor/pg_read_all_stats)` UNCONDITIONALLY (never a clean pass) and skip. Otherwise (note: the catalog identifier `pg_locks` contains the substring `lock` but is preceded by `_`, so it does NOT trip the guards.md rule-4 `\bLOCK\b` word-boundary blacklist — substring-only, intentional; likewise `pg_blocking_pids()`):

```sql
SELECT count(*) AS waiting_count,
       count(DISTINCT unnest_pids) AS distinct_blockers
FROM pg_locks l
LEFT JOIN LATERAL unnest(pg_blocking_pids(l.pid)) AS unnest_pids ON true
WHERE NOT l.granted;
```

Ungranted lock requests with a non-empty blocker set indicate live contention — sessions waiting on locks held by others. Point-in-time snapshot.

Severity: MEDIUM.

### Q6.13 — Top queries / temp-spill [EXT] + [RO+priv] (`health`) — version-branched (§B)

[EXT] probe FIRST against Preamble P3: if `pg_stat_statements` is NOT in the extension inventory → emit `[INFO] 6.13 — extension pg_stat_statements not installed; skipped` and stop. Then the §C gate: if `has_monitor = false AND has_read_all_stats = false` → emit `[INFO] 6.13 — partial visibility; cross-session data restricted under current role (no pg_monitor/pg_read_all_stats)` UNCONDITIONALLY (never a clean pass) and stop (the view shows only the current role's rows otherwise). If both clear, branch DECISIVELY on `server_major`:

PG ≥ 13:

```sql
SELECT queryid, calls, total_exec_time, mean_exec_time, rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 50;
```

PG < 13:

```sql
SELECT queryid, calls, total_time, mean_time, rows
FROM pg_stat_statements
ORDER BY total_time DESC
LIMIT 50;
```

Companion seq-scan signal [RO] (always assessable):

```sql
SELECT schemaname, relname, seq_scan, idx_scan
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY seq_scan DESC NULLS LAST
LIMIT 50;
```

The top time-consuming queries (and tables driven by sequential scans) are the optimization targets. `queryid` is a normalized fingerprint, not literal SQL, so no value redaction is needed; if any query text is surfaced, apply redaction rule 1.

Severity: MEDIUM (INFO inventory of hot queries).

### Q6.14 — Missing-index advisor [EXT] (`health`)

[EXT] probe FIRST against Preamble P3: if `pg_stat_statements` is absent → `[INFO] 6.14 — extension pg_stat_statements not installed; skipped`. This is an INFO-only advisory derived from correlating `pg_stat_statements` hot queries (Q6.13) with `pg_stats` selectivity:

```sql
SELECT schemaname, tablename, attname, null_frac, n_distinct
FROM pg_stats
WHERE schemaname = 'public'
  AND n_distinct > 100
ORDER BY n_distinct DESC
LIMIT 50;
```

High-cardinality columns (large `n_distinct`, low `null_frac`) that appear in frequent WHERE/JOIN predicates of the hot queries are candidates for a new index. Advisory only — verify against actual query plans before acting.

Severity: INFO.

### Q6.20 — Free disk / WAL volume / pool saturation [PROVIDER] (`health`)

Manual-verify INFO — not assessable from inside Postgres on managed providers. Check the provider's metrics (CloudWatch `FreeStorageSpace` / `TransactionLogsDiskUsage`; PgBouncer / Supavisor `SHOW POOLS` for connection-pool saturation). Emit one INFO line.

`Severity-if-absent: HIGH.`

---

## Module 7 — Config & CIS (`config`)

Skip this phase if `--only` is set and does not include `config`.

On any MCP/SQL error: emit `[INFO] Module 7 — {tool} unavailable: {error}` and continue.

All [RO]. Read every setting in ONE query (N+1 prevention — not N per-setting `SHOW`), then assert in-prose with LITERAL pass/fail predicates below. Where a setting is genuinely policy-dependent, emit `[INFO] inventory: <observed>` rather than pass/fail.

### Q7.1 — CIS settings inventory [RO] (`config`)

```sql
SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
  'log_connections','log_disconnections','logging_collector','log_line_prefix',
  'log_checkpoints','log_lock_waits','log_min_duration_statement','log_temp_files',
  'log_statement','shared_preload_libraries',
  'ssl','ssl_min_protocol_version','password_encryption',
  'fsync','full_page_writes','autovacuum','track_counts','track_activities',
  'statement_timeout','idle_in_transaction_session_timeout','lock_timeout',
  'autovacuum_freeze_max_age','listen_addresses'
);
```

Assertions (apply to the result rows):

- **Logging / audit — MEDIUM if miss:** `log_connections='on'`, `log_disconnections='on'`, `logging_collector='on'`, `log_line_prefix` contains `%m %u %d`, `log_checkpoints='on'`, `log_lock_waits='on'`, `log_min_duration_statement` ≠ `-1`, `log_temp_files` ≠ `-1`, `shared_preload_libraries` ⊇ `pgaudit`. `log_statement` → **[INFO] inventory: <observed>** (policy-dependent, no fixed expectation).
- **Security — HIGH if miss:** `ssl='on'`, `ssl_min_protocol_version` ≥ `TLSv1.2`, `password_encryption='scram-sha-256'` (flag `md5`).
- **Durability / ops:** `fsync='on'` (HIGH), `full_page_writes='on'` (HIGH), `autovacuum='on'` (HIGH), `track_counts='on'` / `track_activities='on'` (MEDIUM), `statement_timeout='0'` (MEDIUM — no cap), `idle_in_transaction_session_timeout='0'` (MEDIUM), `lock_timeout='0'` (MEDIUM), `autovacuum_freeze_max_age` > `1000000000` (HIGH).
- **Network exposure:** `listen_addresses='*'` → **INFO only** (expected on managed / containerized PG; real exposure is governed by `pg_hba` + network ACLs). Public-reachability / IP-allowlist = `[PROVIDER]` manual-verify.

Cross-ref: `ssl` posture is also referenced by Module 11 (emit once here, cross-ref there); `pgaudit` presence is referenced by Module 10.

Severity: per-setting as listed above.

### Q7.2 — Host-based auth rules [RO+priv] (`config`)

```sql
SELECT type, database, user_name, address, auth_method
FROM pg_hba_file_rules;
```

`pg_hba_file_rules` requires superuser/privileged access; on managed providers it errors for the non-superuser audit role. Per-module dispatch (guards.md rule 6) catches the permission error → emit `[INFO] 7.2 — host-based auth rules not assessable on this provider (needs pg_monitor/superuser)`. When readable: flag `auth_method` of `trust` (HIGH — no auth) or `password` (MEDIUM — cleartext-equivalent; prefer `scram-sha-256`); confirm `hostssl` is used for remote connections. Data-dir perms (0700) / unix-socket perms = `[PROVIDER]` manual-verify.

Severity: HIGH (`trust`) / MEDIUM (weak method) / INFO (degraded).

---

## Module 8 — Privileges & Roles (`privileges`)

Skip this phase if `--only` is set and does not include `privileges`.

On any MCP/SQL error: emit `[INFO] Module 8 — {tool} unavailable: {error}` and continue.

All [RO]. Read role attributes from `pg_roles` (NOT `pg_authid` — `pg_authid` exposes `rolpassword`, denied by redaction rule 6 and unreadable to non-superusers anyway).

### Q8.1 — Role attribute sprawl [RO] (`privileges`)

```sql
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls,
       rolcanlogin, rolconnlimit, rolvaliduntil
FROM pg_roles
WHERE rolname NOT LIKE 'pg\_%';
```

Flag over-privileged roles: `rolsuper` (SUPERUSER), `rolcreaterole`, `rolcreatedb`, and especially **`rolbypassrls = true`** (CRITICAL — a `BYPASSRLS` role silently defeats every RLS policy, the same exposure as Q2.6's owner bypass but DB-wide). Login roles with `rolconnlimit = -1` (no connection cap) are a saturation risk (MEDIUM); human login roles with a NULL `rolvaliduntil` (never-expiring) are a hygiene concern (LOW/MEDIUM).

Severity: CRITICAL (`rolbypassrls`) / HIGH (superuser sprawl) / MEDIUM / LOW as above.

### Q8.2 — PUBLIC grants [RO] (`privileges`)

Table-level grants to PUBLIC:

```sql
SELECT table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'PUBLIC';
```

Schema and function ACLs mentioning PUBLIC:

```sql
SELECT n.nspname AS schema_name, n.nspacl::text AS schema_acl
FROM pg_namespace n
WHERE n.nspacl::text LIKE '%=%'
  AND array_to_string(n.nspacl, ',') LIKE '%=U%';
```

```sql
SELECT p.proname, n.nspname, p.proacl::text AS proc_acl
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.proacl IS NOT NULL
  AND array_to_string(p.proacl, ',') LIKE '=%';
```

Default privileges granted to PUBLIC:

```sql
SELECT defaclnamespace::regnamespace AS schema_name, defaclobjtype, defaclacl::text
FROM pg_default_acl
WHERE array_to_string(defaclacl, ',') LIKE '=%';
```

A grant whose grantee is empty (the `=privs` ACL form) or `PUBLIC` means EVERY role — including `anon` on managed providers — gets that privilege. PUBLIC SELECT on a sensitive table, PUBLIC USAGE/CREATE on a schema, or PUBLIC EXECUTE on a function is a common over-exposure.

Severity: HIGH (PUBLIC data/exec grant) / MEDIUM (PUBLIC schema USAGE).

### Q8.3 — Privileged role membership [RO] (`privileges`)

```sql
SELECT m.roleid::regrole AS granted_role,
       m.member::regrole AS member_role,
       m.admin_option
FROM pg_auth_members m
WHERE m.roleid::regrole::text IN (
  'pg_read_all_data','pg_write_all_data','pg_monitor',
  'pg_read_all_stats','pg_execute_server_program',
  'pg_read_server_files','pg_write_server_files'
)
   OR m.roleid IN (SELECT oid FROM pg_roles WHERE rolsuper);
```

Membership in superuser or the powerful `pg_*` default roles (especially `pg_write_all_data`, `pg_execute_server_program`, the server-file roles) is an escalation path. `admin_option = true` lets the member re-grant the role to others.

Severity: HIGH.

### Q8.4 — SECURITY DEFINER search_path [RO] (`privileges`) — CROSS-REF

Already shipped as **Q2.4** (SECURITY DEFINER functions with mutable `search_path`, severity HIGH). Do NOT re-run any SQL here. Emit a pointer only: `[INFO] 8.4 — SECURITY DEFINER search_path → see Q2.4 (Module 2)`.

### Q8.5 — FORCE RLS [RO] (`privileges`) — CROSS-REF

Already covered by the new **Q2.6** (FORCE RLS gap, Module 2). Do NOT re-run any SQL here. Emit a pointer only: `[INFO] 8.5 — FORCE RLS / owner bypass → see Q2.6 (Module 2)`. Note Q2.6 is `public`-scoped, so this cross-ref does not claim coverage of non-public RLS tables.
