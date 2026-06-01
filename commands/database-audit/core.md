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

## Preamble queries (run ONCE behind the discharged prod guard whenever ANY referencing data-plane module is selected — NOT preflight, NOT gated on health/config)

These three named queries are **data-plane SQL** and run ONCE, behind the discharged prod guard, the FIRST time ANY data-plane module that references them is selected — exactly like Q4.1 reads the version today. They are **NOT gated on the `health`/`config` tokens.** The dependency graph is wider than health/config: the compliance Modules 10/11, the PII Module 12, and the exfil Module 15 ALL consume the P3 extension inventory, and Modules 10/11 additionally consume Q7.1's `pg_settings` result. Concretely:

- **P3 (extension inventory)** is consumed by 6.13/6.14, Module 10 (pgaudit/pgcrypto/anon), Module 11 (crypto tooling), Module 12 (anon/vault), and Module 15 (15.1 postgres_fdw/dblink, 15.4 extension-in-public + currency). So P3 must run whenever ANY of `health`, `compliance`, `pii`, or `exfil` is selected — not just `health`/`config`.
- **Q7.1 (`pg_settings` inventory)** is consumed by Modules 10/11 (pgaudit in `shared_preload_libraries`, `ssl` posture). When `compliance` is selected WITHOUT `config`, Q7.1 still runs once so 10/11 can read it.

Whichever referencing module runs first triggers the preamble (and Q7.1) ONCE; every later module **REFERENCES the cached result and MUST NOT re-query** (N+1 prevention — do NOT re-`SELECT … FROM pg_extension`, re-probe capability, or re-`SELECT … FROM pg_settings` per module). They MUST NOT run in preflight (Phase 0a): that would violate the "no data-plane SQL before the prod guard discharges" invariant. On case (a) no-connection and case (b) prod-stop, none of these run, the results are unknown, and every downstream version-branched / capability-gated check emits its `[INFO] … skipped — no connection` form.

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

### Q6.6 — int4 sequence-backed column exhaustion [RO] (`health`)

Scope is ANY `int4` column backed by a sequence — not just primary keys. Exhaustion is a write-outage risk for any sequence-backed `int4` column (the next `INSERT` fails once the sequence crosses 2^31), so restricting to PKs would under-report. We report `is_primary_key` per column so PK cases are still distinguishable, but a non-PK int4 sequence near the ceiling is just as much an outage.

Two parts. First, raw sequence consumption from `pg_sequences`:

```sql
SELECT schemaname, sequencename, last_value, max_value
FROM pg_sequences
ORDER BY (last_value::numeric / NULLIF(max_value,0)) DESC NULLS LAST
LIMIT 50;
```

Second, the int4-sequence-backed-column linkage — the one genuinely tricky join, given **VERBATIM** (prose invites a wrong `pg_depend` direction). The sequence is the dependent object (`objid`); the table+column it feeds is the referenced object (`refobjid` + `refobjsubid`); both `classid` and `refclassid` are `pg_class`; `deptype` `'a'` = serial `OWNED BY`, `'i'` = `GENERATED … AS IDENTITY`. A LEFT JOIN to `pg_index` (primary-index only) flags whether the column is also a PK without restricting the result to PKs:

```sql
SELECT s.relname AS sequence_name,
       t.relname AS table_name,
       a.attname AS column_name,
       (pk.indrelid IS NOT NULL) AS is_primary_key,
       seq.last_value
FROM pg_depend d
JOIN pg_class s ON s.oid = d.objid
JOIN pg_class t ON t.oid = d.refobjid
JOIN pg_attribute a ON (a.attrelid = d.refobjid AND a.attnum = d.refobjsubid)
JOIN pg_sequences seq ON (seq.schemaname = (SELECT nspname FROM pg_namespace WHERE oid = s.relnamespace)
                          AND seq.sequencename = s.relname)
LEFT JOIN pg_index pk ON (pk.indrelid = d.refobjid
                          AND pk.indisprimary
                          AND d.refobjsubid = ANY(pk.indkey))
WHERE d.classid = 'pg_class'::regclass
  AND d.refclassid = 'pg_class'::regclass
  AND d.deptype IN ('a','i')
  AND a.atttypid = 'int4'::regtype
ORDER BY seq.last_value DESC NULLS LAST
LIMIT 50;
```

An `int4` column overflows at 2^31 (~2.147B). When a sequence backing an `int4` column has `last_value` approaching that, inserts will start failing — whether or not the column is a PK (`is_primary_key` tells you which). A bare app-assigned `int4` column with no backing sequence cannot be measured here (it has no sequence row to read). **Degradation (false-clean class):** `pg_sequences.last_value` returns NULL when the audit role lacks SELECT on the sequence (common on managed providers). A NULL `last_value` MUST emit `[INFO] 6.6 — sequence value not readable under current role`, **NEVER a clean pass.**

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

Per-INDEX attribution (which btree indexes are at risk via `pg_index.indcollation`). `indcollation` is an `oidvector`; `unnest` does NOT accept an `oidvector` directly on every PG version, so cast it to `oid[]` first (`i.indcollation::oid[]`). Bounded (`ORDER BY … LIMIT 50`) with a total count so a cluster-wide collation drift does not dump every index:

```sql
SELECT n.nspname, ic.relname AS index_name, tc.relname AS table_name,
       cl.collname, cl.collversion,
       pg_collation_actual_version(cl.oid) AS actual_version,
       count(*) OVER () AS total_affected_indexes
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class tc ON tc.oid = i.indrelid
JOIN pg_namespace n ON ic.relnamespace = n.oid
JOIN unnest(i.indcollation::oid[]) WITH ORDINALITY AS col(colloid, ord) ON true
JOIN pg_collation cl ON cl.oid = col.colloid
WHERE col.colloid <> 0
  AND cl.collversion IS DISTINCT FROM pg_collation_actual_version(cl.oid)
ORDER BY n.nspname, ic.relname
LIMIT 50;
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
JOIN pg_class c ON c.oid = s.relid
WHERE s.n_mod_since_analyze > 0
ORDER BY s.n_mod_since_analyze DESC NULLS LAST
LIMIT 50;
```

A high `n_mod_since_analyze` relative to `reltuples` means the planner is working from stale row estimates → bad plans. Cross-ref Q6.2 (autovacuum recency drives ANALYZE).

Severity: MEDIUM.

### Q6.17 — Size outliers / giant unpartitioned tables [RO] (`health`)

```sql
SELECT n.nspname, c.relname, c.relkind,
       pg_total_relation_size(c.oid) AS total_bytes,
       (c.oid IN (SELECT partrelid FROM pg_partitioned_table)) AS is_partitioned_parent,
       (c.relkind = 'r' AND NOT c.relispartition
        AND c.oid NOT IN (SELECT partrelid FROM pg_partitioned_table)) AS is_giant_unpartitioned,
       (SELECT count(*) FROM pg_class WHERE relkind IN ('r','p')) AS total_relations
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind IN ('r','p')
  AND NOT c.relispartition
  AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
ORDER BY total_bytes DESC
LIMIT 50;
```

The largest tables. `relkind IN ('r','p')` includes partitioned parents (`'p'`) so they are visible (and correctly labeled `is_partitioned_parent = true`, never flagged as monolithic); `NOT c.relispartition` excludes partition CHILDREN so a partitioned table's children are not mislabeled "giant unpartitioned." Only a row where `is_giant_unpartitioned = true` (a plain `relkind='r'` table that is neither a partition of anything nor a partitioned parent) is flagged as a monolithic table — a vacuum/maintenance/lock-window liability that partitioning would relieve.

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

§C gate: `pg_stat_replication` is cross-session and visible only to privileged roles, so a restricted role sees zero rows and would false-clean "no standby." If Preamble P2 shows `has_monitor = false AND has_read_all_stats = false`, emit `[INFO] 6.8 — partial visibility; cross-session data restricted under current role (no pg_monitor/pg_read_all_stats)` UNCONDITIONALLY (never a clean "no standby") and skip the query. Otherwise:

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

**Dispatch note (K4):** Q7.2 is dispatched in its OWN sub-unit (its own `BEGIN READ ONLY … ROLLBACK` / single MCP call) so a permission-denied on `pg_hba_file_rules` degrades to a LOCAL `[INFO]` and does NOT blank the rest of Module 7.

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

Schema ACLs mentioning PUBLIC — use `aclexplode` filtered to `grantee = 0` (the OID-0 PUBLIC pseudo-role), which works no matter WHERE the PUBLIC entry sits in the ACL array. A NULL `nspacl` means DEFAULT privileges, so coalesce to `acldefault('n', n.nspowner)` so default PUBLIC grants are not missed:

```sql
SELECT n.nspname AS schema_name, acl.privilege_type
FROM pg_namespace n
CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) AS acl
WHERE acl.grantee = 0
  AND acl.privilege_type IN ('USAGE','CREATE');
```

Function PUBLIC EXECUTE grants — `proacl IS NULL` means DEFAULT privileges, which INCLUDE `PUBLIC EXECUTE`, so `IS NULL` must NOT be treated as "no grant." Use `has_function_privilege('public', p.oid, 'EXECUTE')`, which resolves the effective privilege whether the ACL is explicit or defaulted:

```sql
SELECT n.nspname, p.proname
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND has_function_privilege('public', p.oid, 'EXECUTE');
```

Default privileges granted to PUBLIC (future objects) — filter the exploded ACL to `grantee = 0`:

```sql
SELECT d.defaclnamespace::regnamespace AS schema_name, d.defaclobjtype, acl.privilege_type
FROM pg_default_acl d
CROSS JOIN LATERAL aclexplode(d.defaclacl) AS acl
WHERE acl.grantee = 0;
```

A grant whose grantee is PUBLIC (grantee OID `0`, including the DEFAULT-privilege case where the ACL column is NULL) means EVERY role — including `anon` on managed providers — gets that privilege. PUBLIC SELECT on a sensitive table, PUBLIC USAGE/CREATE on a schema, or PUBLIC EXECUTE on a function is a common over-exposure.

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

---

## Module 9 — Schema Integrity (`integrity`)

Skip this phase if `--only` is set and does not include `integrity`.

On any MCP/SQL error: emit `[INFO] Module 9 — {tool} unavailable: {error}` and continue.

All [RO]. **`public`-scoped** (matches Q1.5/Q1.6/Q3.1). Extends Module 1 — cross-ref Q1.x, do not duplicate. Every name-heuristic regex below is pinned VERBATIM. The int4-PK overflow check is covered by Q6.6 (cross-ref).

### Q9.1 — FKs without ON DELETE / ON UPDATE action [RO] (`integrity`)

```sql
SELECT con.conrelid::regclass AS table_name, con.conname AS fk_name,
       con.confdeltype, con.confupdtype
FROM pg_constraint con
JOIN pg_namespace n ON con.connamespace = n.oid
WHERE con.contype = 'f'
  AND n.nspname = 'public'
  AND (con.confdeltype = 'a' OR con.confupdtype = 'a');
```

`confdeltype = 'a'` / `confupdtype = 'a'` is the default `NO ACTION` — a delete/update of a parent row referenced by children errors at runtime instead of cascading or nulling, often surfacing as a production incident. Verify the intended referential behavior was chosen deliberately.

Severity: MEDIUM.

### Q9.2 — Unvalidated constraints [RO] (`integrity`)

```sql
SELECT con.conrelid::regclass AS table_name, con.conname AS constraint_name,
       con.contype
FROM pg_constraint con
JOIN pg_namespace n ON con.connamespace = n.oid
WHERE n.nspname = 'public'
  AND con.convalidated = false;
```

A constraint added with `NOT VALID` and never `VALIDATE`d does NOT enforce on existing rows — pre-existing violations slip through, and the planner cannot rely on it.

Severity: MEDIUM.

### Q9.3 — Missing NOT NULL on identity-ish columns [RO] (`integrity`)

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name ~ '^(id|created_at|updated_at)$'
  AND is_nullable = 'YES';
```

Columns named `id` / `created_at` / `updated_at` are almost always meant to be mandatory; a nullable one allows orphan/incomplete rows and undermines audit trails.

Severity: LOW (MEDIUM for a nullable `id`).

### Q9.4 — `timestamp` without time zone [RO] (`integrity`)

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type = 'timestamp without time zone';
```

`timestamp` (no tz) stores wall-clock with no offset — ambiguous across DST/regions and a frequent source of off-by-hours bugs. Prefer `timestamptz`.

Severity: MEDIUM.

### Q9.5 — Fixed-width and discouraged types [RO] (`integrity`)

`char(n)` / `bpchar` (blank-padded fixed width, almost always misuse):

```sql
SELECT table_name, column_name, character_maximum_length
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type = 'character';
```

`numeric` WITHOUT precision ONLY for monetary-looking columns (an unconstrained `numeric` for money loses scale guarantees):

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type = 'numeric'
  AND numeric_precision IS NULL
  AND column_name ~* 'price|amount|cost|total|balance';
```

The `money` type (genuinely discouraged — locale-dependent, fixed scale):

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type = 'money';
```

`char(n)` pads with spaces and rarely behaves as intended; an unconstrained monetary `numeric` permits any scale (rounding drift); `money` is locale-dependent and not recommended. (Note: `text` is the PG-recommended string type — "unbounded text used as bounded" is intentionally NOT flagged.)

Severity: MEDIUM for each.

### Q9.6 — Missing UNIQUE on natural keys [RO] (`integrity`)

```sql
SELECT c.table_name, c.column_name
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.column_name ~* 'email|slug|username'
  AND NOT EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indrelid
    JOIN pg_namespace n ON ic.relnamespace = n.oid
    JOIN pg_attribute a ON (a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey))
    WHERE i.indisunique
      AND n.nspname = c.table_schema
      AND ic.relname = c.table_name
      AND a.attname = c.column_name
  );
```

Columns named `email` / `slug` / `username` are natural keys that should be UNIQUE; without a unique index duplicates accumulate and lookups are ambiguous.

Severity: LOW.

### Q9.7 — int4 PK overflow risk [RO] (`integrity`) — CROSS-REF

int4-backed PK / serial-vs-identity overflow is covered by **Q6.6**. Emit a pointer: `[INFO] 9.7 — int4 PK overflow risk → see Q6.6 (Module 6)`.

---

## Module 10 — Audit Logging & Compliance + Module 11 — Encryption (`compliance`)

Skip this phase if `--only` is set and does not include `compliance`.

On any MCP/SQL error: emit `[INFO] Module 10/11 — {tool} unavailable: {error}` and continue.

Read extension presence from Preamble P3 and settings from Q7.1 (do NOT re-query `pg_extension` or `pg_settings`).

### Q10.1 — pgaudit posture [RO] / [EXT] (`compliance`)

Check Preamble P3 for `pgaudit`. If absent → INFO ("pgaudit not installed; statement-level audit relies on `log_statement`" — cross-ref Q7.1 `log_statement` inventory). If present, confirm it is in `shared_preload_libraries` (from Q7.1) AND read its logging policy:

```sql
SELECT name, setting
FROM pg_settings
WHERE name IN ('pgaudit.log','pgaudit.log_catalog','pgaudit.log_parameter');
```

`pgaudit.log` should include `WRITE`, `DDL`, `ROLE` for a compliance-grade audit trail. Also detect trigger-based audit tables as a fallback pattern. The trigger MUST be correlated to the candidate table — a trigger anywhere in `public` does NOT make an unrelated audit-named table "audited." A table counts as trigger-audited when a trigger fires ON it (`event_object_table = t.table_name`, the audit/history table populated by a trigger) OR ON its source table (`<base>_history`/`<base>_audit`/`audit_<base>` ⇒ base table `<base>`, the common write-side-trigger pattern):

```sql
SELECT t.table_name
FROM information_schema.tables t
WHERE t.table_schema = 'public'
  AND t.table_name ~* '_history$|_audit$|^audit_'
  AND EXISTS (
    SELECT 1 FROM information_schema.triggers tr
    WHERE tr.event_object_schema = 'public'
      AND tr.event_object_table IN (
        t.table_name,
        regexp_replace(t.table_name, '(_history|_audit)$', ''),
        regexp_replace(t.table_name, '^audit_', '')
      )
  );
```

Severity: MEDIUM if no audit mechanism present; INFO inventory otherwise.

### Q11.1 — In-transit encryption [RO] (`compliance`)

`ssl` posture is read in Q7.1 — cross-ref ("ssl in-transit → see Module 7 / Q7.1"); emit the finding ONCE. `ssl='off'` → HIGH (connections unencrypted). `hostssl` enforcement in `pg_hba` is `[RO+priv]` (see Q7.2, degrade-with-INFO).

Severity: HIGH (`ssl='off'`).

### Q11.2 — Unencrypted live sessions [RO+priv] (`compliance`)

§C gate: if Preamble P2 shows `has_monitor = false AND has_read_all_stats = false`, emit `[INFO] 11.2 — partial visibility; cross-session data restricted under current role (no pg_monitor/pg_read_all_stats)` UNCONDITIONALLY (never a clean pass) and skip. Otherwise:

```sql
SELECT count(*) FILTER (WHERE ssl = false) AS unencrypted_sessions,
       count(*) AS total_sessions
FROM pg_stat_ssl;
```

Any live session with `ssl = false` is transmitting in cleartext. Under a restricted role `pg_stat_ssl` shows only the current session — the §C gate prevents a false-clean.

Severity: HIGH if unencrypted sessions present.

### Q11.3 — Crypto tooling presence [RO] / [EXT] (`compliance`)

From Preamble P3, report presence of `pgcrypto`, `supabase_vault`, `pgsodium`. Presence is informational (application-level encryption capability available); absence is INFO ("no in-DB crypto extension; column-level encryption, if required, is handled elsewhere").

Severity: INFO.

### Q10.2 — Log retention / immutability [PROVIDER] (`compliance`)

Manual-verify INFO — not assessable from inside Postgres. Verify log retention meets the applicable regime (PCI 12 months / HIPAA ~6 years / SOC2 1–2 years) and that logs are immutable/exported. Emit one INFO line.

`Severity-if-absent: HIGH.`

### Q11.4 — At-rest encryption [PROVIDER] (`compliance`)

Manual-verify INFO — never pass/fail. Verify at-rest encryption in the provider console (RDS KMS / Supabase AES-256 / Neon XTS-AES-256). Emit one INFO line: "verify at-rest encryption in provider console."

`Severity-if-absent: HIGH.` (Manual-verify only — never asserted pass or fail from SQL.)

---

## Module 12 — PII Governance (`pii`)

Skip this phase if `--only` is set and does not include `pii`.

On any MCP/SQL error: emit `[INFO] Module 12 — {tool} unavailable: {error}` and continue.

**NAME-ONLY.** Value-sampling is deferred (no `TABLESAMPLE`, no regex-on-values, no `--pii-sample` flag) — this eliminates reading real PII on a prod connection and the dynamic-identifier SQL that would violate the fixed-library guard.

### Q12.1 — PII candidate scan [RO] (`pii`) — name+type only

Reuse the existing **Q3.1** name+type candidate logic under the `pii` token (the provider adapter supplies the schema list + exposed role parameters; see Q3.1). Report column NAMES only — never SELECT actual PII values (redaction rule 3). When run under `--only=pii`, emit Q3.1's result here; do not duplicate the SQL body.

Severity: HIGH (PII column exposed to an anon-reachable grant) — see Q3.1.

### Q12.2 — Masking / anonymization tooling presence [RO] / [EXT] (`pii`)

From Preamble P3, report presence of the `anon` extension and `supabase_vault`. Also detect `anon` security labels:

```sql
SELECT objoid::regclass AS object_name, label
FROM pg_seclabel
WHERE provider = 'anon';
```

Presence indicates masking capability is available; absence is INFO (no in-DB dynamic masking).

Severity: INFO.

### Q12.3 — Retention heuristics [RO] (`pii`)

Soft-delete / expiry columns:

```sql
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name ~* '^(deleted_at|expires_at|expired_at|retention_until)$';
```

Scheduled-job presence (`cron.job` SCHEDULE ONLY — NEVER select `cron.job.command`; command bodies can embed secrets, consistent with existing cron redaction):

```sql
SELECT jobid, schedule, jobname
FROM cron.job;
```

**Dispatch note (K4):** this `cron.job` read is dispatched in its OWN sub-unit (its own `BEGIN READ ONLY … ROLLBACK` / single MCP call) so an absent-relation error (`cron.job` does not exist when `pg_cron` is not installed) degrades to a LOCAL `[INFO]` and does NOT blank the rest of Module 12. (If the `pg_cron` schema/table is absent the per-module dispatch logs `[INFO] 12.3 — pg_cron not present` and continues.) The presence of `deleted_at`/`expires_at`, date-partitioning, or a retention cron job suggests a retention mechanism; their ABSENCE on PII-bearing tables is a gap. RTBF (right-to-be-forgotten) structural posture — soft-vs-hard delete, FK cascade for erasure — plus classification certainty is process-level → manual-verify INFO ("verify retention/erasure enforcement out-of-band").

Severity: INFO (manual-verify; gap if no retention mechanism on PII tables).

---

## Module 13 — Migration Safety lint (`migrations`)

Skip this phase if `--only` is set and does not include `migrations`.

**[FS] — filesystem-only, NO database connection.** Static analysis of migration SQL files. Because it touches no data-plane, it runs in BOTH the normal path AND the prod-stop / no-connection path (it is registered in `guards.md` `run_filesystem_only_modules` with the `migrations` token, alongside FS.1–FS.5). It does NOT branch on `server_major` (no connection).

**Scope = LOCK-SAFETY / REWRITE-SAFETY rules ONLY** (the disjoint half). The god-review principle `god-review/principles/database-audit.md` already owns the 5 security/integrity static rules (RLS-off/blanket, SECURITY DEFINER search_path, migration drift/ordering, PII-without-RLS, unindexed FK) — Module 13 does NOT re-list or re-emit those; it cross-refs ("security/integrity migration rules → see god-review principle"). The taxonomy lives once, here.

### Migration file discovery (Darwin-safe)

Discover migration SQL under `migrations/`, `supabase/migrations/`, `db/migrate/`, `prisma/migrations/`. Use NUL-delimited plumbing (Darwin has NO GNU `xargs -r`):

```bash
# Read-only git only. NUL-delimited so paths with spaces survive.
git ls-files -z -- 'migrations/*.sql' 'supabase/migrations/*.sql' 'db/migrate/*.sql' 'prisma/migrations/*.sql' \
  | xargs -0 -I{} sh -c 'printf "%s\n" "{}"'
```

If `git ls-files` returns nothing, fall back to a read-only filesystem walk of those directories (no GNU-only flags). If no migration files exist → emit `[INFO] Module 13 — no migration files found; skipped` and continue.

### Lock / rewrite-safety rules (static SQL pattern lint)

Scan each discovered `.sql` file (line-numbered) for these patterns. Report `file:line` + rule name. (These are filesystem grep heuristics — they read migration TEXT, they do not run SQL, so no rule-4 concern.)

1. **NOT NULL without default** — `ADD COLUMN … NOT NULL` with no `DEFAULT` on an existing table → full-table rewrite + long lock. HIGH.
2. **Volatile-default ADD COLUMN** — `ADD COLUMN … DEFAULT <non-constant>` (PG < 11 rewrites the whole table; volatile defaults rewrite on any version). HIGH.
3. **Ban DROP** — `DROP COLUMN` / `DROP TABLE` / `DROP NOT NULL` of in-use objects (destructive; coordinate with deploy). MEDIUM.
4. **Changing column type** — `ALTER COLUMN … TYPE` → table rewrite + exclusive lock. HIGH.
5. **Constraint without NOT VALID** — `ADD CONSTRAINT … CHECK`/`FOREIGN KEY` without `NOT VALID` → validates all existing rows under lock. MEDIUM (recommend add-`NOT VALID`-then-`VALIDATE`).
6. **`ADD CONSTRAINT … UNIQUE` (inline)** — takes an exclusive lock building the index; prefer `CREATE UNIQUE INDEX CONCURRENTLY` then `ADD CONSTRAINT … USING INDEX`. MEDIUM.
7. **Index build without CONCURRENTLY** — `CREATE INDEX` not followed by `CONCURRENTLY` → blocks writes for the build. MEDIUM.
8. **CONCURRENTLY inside a transaction** — `CREATE INDEX CONCURRENTLY` (or `DROP … CONCURRENTLY`) appearing between `BEGIN`/`COMMIT` (or in a tool that wraps each migration in a transaction) → fails at runtime (cannot run in a txn block). HIGH.
9. **Rename column / table** — `RENAME COLUMN` / `RENAME TO` → breaks the old name for any in-flight code (do it in a backward-compatible multi-step). MEDIUM.
10. **Prefer-bigint / identity / timestamptz** — new `int4`/`serial` PK, `timestamp` (no tz) column, or `serial` instead of `GENERATED … AS IDENTITY` in a migration. LOW (cross-ref Q6.6 / Q9.4).

`[FS]` note: Module 13 is filesystem-only and runs case (a) no-connection and case (b) prod-stop, exactly like FS.1–FS.5.

Severity: per-rule as listed.

---

## Module 14 — Backup & Recovery (`backup`)

Skip this phase if `--only` is set and does not include `backup`.

On any MCP/SQL error: emit `[INFO] Module 14 — {tool} unavailable: {error}` and continue.

### Q14.1 — WAL archiving health [RO] (`backup`)

**NEVER select the `archive_command` VALUE** — `archive_command` is an arbitrary shell string that frequently embeds backup credentials / tokens / bucket URLs. Report only a BOOLEAN ("set"/"unset") for it. `archive_mode` and `archive_library` are safe to surface verbatim. The boolean is computed in-SQL so the literal command never leaves the database:

```sql
SELECT
  (SELECT setting FROM pg_settings WHERE name = 'archive_mode')    AS archive_mode,
  (SELECT setting FROM pg_settings WHERE name = 'archive_library') AS archive_library,
  ((SELECT setting FROM pg_settings WHERE name = 'archive_command') IS NOT NULL
   AND (SELECT setting FROM pg_settings WHERE name = 'archive_command') <> '') AS archive_command_set;
```

Report `archive_command_set` as "set"/"unset" only — never echo the command string itself.

Archiver runtime status (the catalog identifier `pg_stat_archiver` contains the substring `archiver`, not a standalone blacklisted keyword — substring-only, intentional; no rule-4 trip):

```sql
SELECT archived_count, failed_count, last_failed_wal, last_failed_time,
       last_archived_wal, last_archived_time
FROM pg_stat_archiver;
```

With `archive_mode='on'`, a nonzero `failed_count` with a recent `last_failed_time` (and a stale `last_archived_time`) means WAL archiving is SILENTLY FAILING — there is no point-in-time-recovery basis, even though the database looks healthy. This is the classic "backups were never actually working" outage.

Severity: CRITICAL when archiving is on but failing (`failed_count` rising / `last_failed_time` recent).

### Q14.2 — WAL retention sanity [RO] (`backup`)

```sql
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('wal_keep_size','max_wal_size','min_wal_size','wal_level');
```

`wal_keep_size` / `max_wal_size` too small relative to the recovery window or standby catch-up time risks standbys / slots falling off (needed WAL recycled before consumed). Inventory + flag obviously-tiny retention.

Severity: INFO (MEDIUM when retention is clearly insufficient for the topology).

### Q14.3 — PITR / last-backup / retention [PROVIDER] (`backup`)

Manual-verify INFO — core/vanilla + Neon ONLY. **On Supabase, 14.3 emits NOTHING here and cross-refs**: `[INFO] 14.3 — PITR → see Supabase Step I-PITR (provider adapter owns the PITR line)`. The Supabase adapter owns the PITR finding (its own title/severity), so this avoids a dedup collision (the `(severity,title,object_name)` key cannot collapse them — different titles + HIGH-vs-CRITICAL severities).

For core/vanilla and Neon: verify PITR / last-backup / retention window in the provider console (RDS `BackupRetentionPeriod`; Neon history-retention). Emit one INFO line.

`Severity-if-absent: CRITICAL.`

### Q14.4 — Restore drill [PROVIDER / process] (`backup`)

Manual-verify INFO — an audit confirms backups EXIST and are not failing (Q14.1), NOT that they actually restore. Verify "when was the last test restore?" out-of-band. Emit one INFO line.

`Severity-if-absent: HIGH.`

---

## Module 15 — Exfiltration & Supply-Chain (`exfil`)

Skip this phase if `--only` is set and does not include `exfil`.

On any MCP/SQL error: emit `[INFO] Module 15 — {tool} unavailable: {error}` and continue.

Mostly [RO]. Reads extension presence from Preamble P3. **Existence-only / name-only** throughout — NEVER select credential-bearing columns (redaction rule 6).

### Q15.1 — FDW / dblink egress [RO] (`exfil`)

From Preamble P3, note whether `postgres_fdw` / `dblink` are installed. Then enumerate foreign servers + their egress TARGET. `pg_foreign_server.srvoptions` MAY be selected, but redaction rule 6 requires dropping every option array element matching `^(password|passfile)=` while KEEPING host/dbname/port:

```sql
SELECT s.srvname AS server_name,
       w.fdwname AS fdw_type,
       ARRAY(
         SELECT opt FROM unnest(s.srvoptions) AS opt
         WHERE opt !~ '^(password|passfile)='
       ) AS egress_options,
       (SELECT count(*) FROM pg_user_mappings um WHERE um.srvid = s.oid) AS mapping_count
FROM pg_foreign_server s
JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw;
```

A foreign server points at an external host (the `host`/`dbname` in `egress_options`) — an SSRF / exfiltration egress path. **NEVER select `pg_user_mappings.umoptions`** (it stores `password=…` keyword-form creds that redaction rule 5's `postgres://` matcher does not catch) — report only the mapping COUNT per server.

Severity: HIGH (FDW egress present).

### Q15.2 — Logical replication exposure [RO] (`exfil`) — EXISTENCE-ONLY

Publications (name + all-tables flag only):

```sql
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
FROM pg_publication;
```

Subscriptions (name + enabled state ONLY — **NEVER select `pg_subscription.subconninfo`**, which holds keyword-form conninfo with a password that redaction rule 5 misses):

```sql
SELECT subname, subenabled
FROM pg_subscription;
```

A publication (especially `puballtables = true`) or an active subscription is a data-egress / ingress channel. Report existence + names + flags only, never the conninfo.

Severity: HIGH (`puballtables`) / MEDIUM (scoped publication / subscription present).

### Q15.3 — Plaintext secrets stored in tables [RO] (`exfil`) — NAME-ONLY

```sql
SELECT table_schema, table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name ~* '(^|_)(token|secret|api_?key|password|private_key|access_key)($|_)';
```

Columns whose NAMES suggest stored credentials/secrets in application tables. **No value inspection** (§D — deferred sampling). This is the inverse of FS.1/Q3.1: it finds secret-shaped columns regardless of any anon grant. Verify whether the values are encrypted at the application layer.

Severity: HIGH.

### Q15.4 — Extension placement & currency [RO] (`exfil`)

From Preamble P3 (`ext_schema`), flag any extension installed in the `public` schema — a search_path-hijack surface; extensions should live in a dedicated schema. **MEDIUM.**

Version currency (INFO only — managed providers pin curated versions, so "newer exists upstream" ≠ "should upgrade"; must NOT look actionable). Compare the installed version against `pg_available_extensions.default_version` (the version `CREATE/ALTER EXTENSION` would install) — NOT `max()` over all available versions, which compares text LEXICOGRAPHICALLY and wrongly ranks `1.9 > 1.10`:

```sql
SELECT e.extname, e.extversion AS installed_version,
       ae.default_version AS installable_version
FROM pg_extension e
JOIN pg_available_extensions ae ON ae.name = e.extname
WHERE e.extversion IS DISTINCT FROM ae.default_version;
```

Severity: MEDIUM (extension in `public`) / INFO (newer version available upstream).

### Q15.5 — Event triggers [RO] (`exfil`)

```sql
SELECT evtname, evtevent, evtenabled,
       evtowner::regrole AS owner,
       evtfoid::regproc AS function_name
FROM pg_event_trigger;
```

An enabled event trigger fires on DDL DB-wide and runs its function as a privileged context — a quiet persistence / backdoor surface (e.g. re-granting privileges or capturing schema changes). List owner + backing function for review.

Severity: INFO (MEDIUM for an enabled event trigger owned by a non-admin / unexpected role).
