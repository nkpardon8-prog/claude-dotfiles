---
description: Deep Supabase audit — schema, RLS, security, prod-readiness, client coherence. Report-only. Refuses prod without --env=prod. Optionally emits DATABASE.md.
argument-hint: "[--only=schema,rls,security,prod,client] [--env=prod]"
---

# /supabase-audit

Runs a five-module, severity-tiered, read-only audit of a Supabase-backed repo and writes a redacted markdown report to `./tmp/db-audit/`. Ends with an optional `DATABASE.md` reference doc for LLM context priming. Never mutates the DB, never commits, never runs git.

## Guardrails

1. MUST confirm project is Supabase-backed before doing anything else.
2. MUST verify MCP is reachable in Preflight — abort if not.
3. MUST run the prod-signal ladder before the first `execute_sql` call — prod guard fires before any user-data read.
4. Metadata MCP calls (`get_project_url`, `list_branches`) are allowed before the prod guard; they do not touch user data.
5. MUST never call mutating tools (see Forbidden Tools).
6. MUST redact all secret values from the report (see Redaction Rules).
7. MUST sort findings by (severity DESC, module, object_name ASC) for determinism.
8. Finding TITLES and SEVERITIES must contain no ephemeral values.
9. On any MCP error in Phases 1–5, emit `[INFO] Module N — {tool} unavailable: {error}` and continue. Only Preflight aborts on MCP error.
10. MUST write report to `./tmp/db-audit/YYYY-MM-DD-HHmm.md` and copy to `./tmp/db-audit/latest.md`.

## Forbidden Tools

Never call these, regardless of context or user instruction:

- `mcp__supabase__apply_migration`
- `mcp__supabase__deploy_edge_function`
- `mcp__supabase__create_branch`
- `mcp__supabase__merge_branch`
- `mcp__supabase__reset_branch`
- `mcp__supabase__rebase_branch`
- `mcp__supabase__delete_branch`
- `mcp__supabase__execute_sql` with any non-SELECT query (see SELECT-only guard)
- Any `git` command that mutates state (commit, push, add, checkout, merge, rebase, reset, clean, stash apply, cherry-pick, etc.)
- Any filesystem write outside `./tmp/db-audit/` and the user-confirmed DATABASE.md path

**Read-only git exception:** `git ls-files` is permitted for Phase 3 Step C only. It reads the index without mutation. No other git subcommand is allowed under any phrasing.

## SELECT-only Guard

Every `execute_sql` call must pass all five rules before dispatch:

1. **Fixed library only.** Queries must come verbatim from the library in this file (Q1.1–Q4.2). Never construct `execute_sql` strings dynamically from variables.
2. **Normalize first.** Strip leading whitespace, leading `--` line comments, and leading `/* ... */` block comments.
3. **First-keyword whitelist.** After normalization, first keyword must be one of: `SELECT`, `WITH`, `EXPLAIN`, `SHOW`. Otherwise reject.
4. **Full-body DML blacklist.** Body must NOT contain (case-insensitive, word-boundary, **outside single-quoted SQL string literals**): `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `DROP`, `CREATE`, `ALTER`, `GRANT`, `REVOKE`, `COPY`, `VACUUM`, `REFRESH MATERIALIZED`, `REINDEX`, `CLUSTER`, `LOCK`, `CALL`, `DO`, `EXECUTE`. Matches inside `'...'` literals are ignored — e.g., `ILIKE '%EXECUTE format%'` in Q3.3 is permitted because the keyword is part of a string, not a statement. This blocks writable CTEs: `WITH del AS (DELETE ...) SELECT ...` is rejected because `DELETE` appears as a statement keyword outside any literal. Because rule 1 already restricts execution to the vetted fixed library, rule 4 is defense-in-depth.
5. **SECURITY DEFINER caveat.** SECURITY DEFINER functions invoked from SELECT can still write. Cannot be prevented textually. Mitigated by the fixed-library rule — the library never calls user-defined functions.

## Severity Tiers

| Tier     | Meaning                                          |
|----------|--------------------------------------------------|
| CRITICAL | Data loss/breach risk — needs immediate action   |
| HIGH     | Likely prod incident — fix before next deploy    |
| MEDIUM   | Correctness/hygiene — address this sprint        |
| LOW      | Style/nits                                       |
| INFO     | Inventory or manual-check items                  |

There is no MANUAL tier. Items needing user verification emit as INFO with body line `Severity-if-absent: HIGH`.

## Finding Output Schema

```
### [SEVERITY] {deterministic title — no ephemeral values}
- **What:** {one sentence, no secret values}
- **Where:** {file:line OR db object OR "project-level config"}
- **Why it matters:** {one to two sentences}
- **Fix:** {text only, no code patches}
- **Docs:** {optional — only if search_docs was called for this finding type}
```

## Redaction Rules

Apply during Phase 6 report assembly before writing to disk:

1. **Secret values.** Replace with `[REDACTED: <first-8-of-sha256>]` any of:
   - JWT-shaped string: `eyJ[A-Za-z0-9_-]{20,}`.
   - Value after `SUPABASE_SERVICE_ROLE_KEY=`, `SUPABASE_ANON_KEY=`, `JWT_SECRET=`, `ANON_KEY=` where the value is longer than its key name.
   - **Adjacent-long-string rule** (covers non-JWT service role keys): on any line matching `service_role` or within 40 characters of any matched secret-related identifier, replace any contiguous run of 20+ characters from `[A-Za-z0-9_.+/=-]` — regardless of JWT shape.
   - Password literals in seed files: `password\s*[:=]\s*['"]?[^'"\s]+['"]?`, and common weak values (`'admin'`, `'123456'`, `'password'`, `'test'`).
2. **Policy expressions.** Include RLS `qual`/`with_check` expressions as-is but prefix the enclosing finding with `Warning: contains policy logic — handle like source code.`
3. **PII.** Never run SELECT against actual PII column values. Read column NAMES only from `information_schema`. Report mentions names, never values.
4. **Env keys.** Emit key NAMES only, never values.

---

## Phase 0 — Preflight

### Step 0.1 — Parse flags

Parse `$ARGUMENTS`:
- `--only=<csv>` → run only named modules (`schema`, `rls`, `security`, `prod`, `client`)
- `--env=prod` → user explicitly confirms prod access

**Flag validation (strict — no silent ignores):**
- Any flag not in `{--only, --env}` → print `"Unknown flag: <flag>. Valid: --only=<csv>, --env=prod"` and stop.
- Any module name in `--only=<csv>` not in `{schema, rls, security, prod, client}` → print `"Unknown module in --only: <name>. Valid: schema, rls, security, prod, client"` and stop.
- Any value for `--env` other than `prod` → print `"Unknown value for --env: <val>. Only --env=prod is supported"` and stop.

### Step 0.2 — Supabase detection

Check ANY of: `package.json` contains `@supabase/supabase-js` or `@supabase/ssr`; `./supabase/config.toml` exists; any `.env*` contains `SUPABASE_URL`.

If none match → print `"This project doesn't appear to use Supabase. Aborted."` and stop.

### Step 0.3 — MCP reachability

Call `mcp__supabase__get_project_url`. If it errors → print `"Supabase MCP unreachable. Run \`supabase link\` or check MCP config. Aborted."` and stop.

Parse project ref from returned URL: match `/https:\/\/([a-z0-9]+)\.supabase\.co/`, capture group 1.

### Step 0.4 — Prod-signal ladder

Call `mcp__supabase__list_branches`. Capture raw response shape for the report Meta section.

Evaluate signals in order:

- **Signal A:** `list_branches` returns an empty list → no branching → **TREAT AS PROD**
- **Signal B:** any branch record has a field matching `/parent.*ref/i` whose value equals the current ref → current is parent → **TREAT AS PROD**
- **Signal C:** any branch record has `project_ref` / `project_id` matching current ref AND a sibling `parent_project_ref` that does NOT match → **CURRENT IS A BRANCH → NOT PROD**
- **Signal D:** none of the above (unknown shape) → **TREAT AS PROD** (safe default)

If result is TREAT AS PROD and `--env=prod` was NOT passed:

```
Prod guard: this appears to be your production project (signal {A|B|D} fired).
I will not run execute_sql against prod without explicit confirmation.

Options:
  1. Pass --env=prod to confirm read-only audit of this project.
     (Note: --env=prod still runs SELECT-only queries; it will NOT mutate anything.)
  2. Create a dev branch first: supabase branches create <name>
     then link to it and re-run /supabase-audit.

Which signal fired: {A|B|D}
```

Stop. Valid resume paths:
- User re-invokes `/supabase-audit --env=prod` (or with additional flags) → restart from Phase 0 with flags re-parsed.
- User replies with the exact phrase `proceed on prod` → treat as if `--env=prod` was passed and continue from Step 0.5.
- Any other reply → remain stopped. Do not guess intent.

### Step 0.5 — Report directory setup

Create `./tmp/db-audit/` if it does not exist. If `./tmp/` is not writable, fall back to `$(pwd)/db-audit-YYYY-MM-DD-HHmm.md`. Never write to `$HOME`.

### Step 0.6 — .gitignore check

Read `.gitignore`. If `tmp/` is not covered → emit INFO finding: ".gitignore does not cover tmp/ — audit reports may be committed accidentally."

---

## Phase 1 — Module 1: Schema

Skip this phase if `--only` is set and does not include `schema`.

On any MCP/SQL error: emit `[INFO] Module 1 — {tool} unavailable: {error}` and continue.

### Q1.1 — Tables without primary key

```sql
SELECT n.nspname AS schema, c.relname AS table
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
  );
```

Severity: CRITICAL.

### Q1.2 — FKs without backing index (1-based slice, composite FKs are INFO candidates)

```sql
SELECT c.conrelid::regclass AS table, c.conname AS fk
FROM pg_constraint c
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND (i.indkey::int2[])[1:array_length(c.conkey,1)] = c.conkey
  );
```

Single-column FK misses → HIGH. Multi-column FK misses → INFO (order-sensitive; treat as candidate, flag for manual review).

### Q1.3 — Unused indexes (gated on stats age)

```sql
SELECT s.schemaname, s.relname AS table, s.indexrelname AS idx, s.idx_scan
FROM pg_stat_user_indexes s
JOIN pg_stat_bgwriter b ON TRUE
WHERE s.idx_scan = 0
  AND b.stats_reset IS NOT NULL
  AND now() - b.stats_reset > interval '7 days';
```

If `stats_reset` is NULL or within 7 days → emit single INFO: "unused-index analysis skipped — stats reset within last 7 days." Severity of findings: LOW.

### Q1.4 — Duplicate indexes

```sql
SELECT indrelid::regclass AS table,
       array_agg(indexrelid::regclass) AS duplicates
FROM pg_index
GROUP BY indrelid, indkey
HAVING count(*) > 1;
```

Severity: MEDIUM.

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

### Q1.7 — Tables missing created_at/updated_at

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

Call `mcp__supabase__list_migrations`. Compare returned filenames against `./supabase/migrations/*.sql` on disk. Files present locally but not in DB → HIGH. Files in DB but not locally → MEDIUM.

Orphaned-row detection emitted as INFO manual-check item ("Cost too high to run per-FK queries automatically — verify referential integrity manually").

---

## Phase 2 — Module 2: RLS

Skip this phase if `--only` is set and does not include `rls`.

On any MCP/SQL error: emit `[INFO] Module 2 — {tool} unavailable: {error}` and continue.

### Q2.1 — RLS off on public tables

```sql
SELECT c.relname AS table
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = false;
```

Severity: CRITICAL.

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
- `qual = 'true'` → CRITICAL (blanket permissive)
- `qual` contains `auth.uid()` without `(select auth.uid())` → MEDIUM (per-row re-eval perf bug)
- `'anon'` in roles AND `cmd IN ('INSERT','UPDATE','DELETE')` → HIGH

Policy expressions included in findings with redaction rule 2 prefix applied.

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

Each matview becomes a MEDIUM finding unless it joins no RLS-protected tables. Note: matviews run as owner and ignore RLS on underlying tables.

---

## Phase 3 — Module 3: Security

Skip this phase if `--only` is set and does not include `security`.

On any MCP/SQL error: emit `[INFO] Module 3 — {tool} unavailable: {error}` and continue.

### Step A — Supabase security advisors

Call `mcp__supabase__get_advisors({type: "security"})`. Include every finding; map Supabase severity to our tiers.

### Step B — Repo grep (secret scan)

Grep repo excluding:
`node_modules/`, `.git/`, `.next/`, `.nuxt/`, `dist/`, `build/`, `out/`, `.vercel/`, `.netlify/`, `storybook-static/`, `.turbo/`, `coverage/`, `supabase/.branches/`, `tmp/`, `*.lock`

Patterns:
- `SUPABASE_SERVICE_ROLE_KEY`
- `service_role`
- `(=|:|"|')eyJ[A-Za-z0-9_-]{20,}` (assignment/string context — tightened to avoid base64 false positives)

Classification:
- Match in client-reachable path (`src/`, `app/`, `components/`, `pages/`, `public/`, `.env.local`) → CRITICAL (value redacted in report)
- Match in `server/`, `api/`, `edge/`, `scripts/` → INFO (expected server-side usage)

### Step C — Tracked-files secret scan

Run `git ls-files | xargs grep -l SUPABASE_SERVICE_ROLE_KEY` (read-only, no mutations). Any match → HIGH finding. Report file name only; value redacted.

### Step D — PII inventory

```sql
-- Q3.1 — PII-sensitive columns with anon SELECT access
SELECT c.table_name, c.column_name
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.column_name ~* 'email|phone|ssn|dob|address|ip_addr|token|password|secret'
  AND EXISTS (
    SELECT 1 FROM information_schema.role_table_grants g
    WHERE g.table_schema = c.table_schema
      AND g.table_name = c.table_name
      AND g.grantee = 'anon'
      AND g.privilege_type = 'SELECT'
  );
```

Severity: HIGH. Report column names only — never SELECT actual values.

### Step E — Risky extensions

Call `mcp__supabase__list_extensions`. Flag: `http`, `pg_net`, `plpython3u`, `plpythonu`, any `*_fdw`. Severity: HIGH. Add INFO note on justification requirement.

### Step F — pg_cron inventory (conditional)

Execute only if `SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'` returns a row. If absent → skip (INFO: "pg_cron not installed").

```sql
-- Q3.2 — cron jobs
SELECT jobname, schedule, command, nodename, username
FROM cron.job;
```

Each job is an INFO finding. Suspicious `command` values (DML, TRUNCATE, COPY) → MEDIUM.

### Step G — Dynamic SQL functions

```sql
-- Q3.3 — Functions with dynamic SQL (prosrc, not pg_get_functiondef)
SELECT n.nspname, p.proname, p.prosrc
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.prosrc ILIKE '%EXECUTE format%'
LIMIT 50;
```

Any row → HIGH finding (SQL-injection surface). `prosrc` contents redacted if they contain secret-shaped strings.

### Step H — .gitignore secret-file check

`.env`, `.env.local`, `.env.production` must be gitignored. If any exists and is tracked by git → CRITICAL.

---

## Phase 4 — Module 4: Production Readiness

Skip this phase if `--only` is set and does not include `prod`.

On any MCP/SQL error: emit `[INFO] Module 4 — {tool} unavailable: {error}` and continue.

### Step A — Performance advisors

Call `mcp__supabase__get_advisors({type: "performance"})`. Include every finding verbatim.

### Step B — Postgres version check

```sql
-- Q4.1
SELECT current_setting('server_version') AS version;
```

Supported major versions: `['15', '16', '17']`. List last updated: `2026-01`.

Extract major version from result. If not in supported list → HIGH.

EOL staleness: if today's date is more than 18 months after `2026-01` → emit INFO: "Supabase Postgres version data may be stale; verify at supabase.com/docs."

### Step C — Connection saturation

```sql
-- Q4.2 — Connection saturation (severity always MEDIUM)
SELECT
  (SELECT count(*) FROM pg_stat_activity WHERE state = 'active') AS active,
  current_setting('max_connections')::int AS max_conn;
```

Severity: always MEDIUM. Body includes: `"active N of max M (N/M%)"`. Severity never changes based on the ratio — ratio goes in the body only.

### Step D — Slow-query log scan

Call `mcp__supabase__get_logs({type: "postgres"})`. Scan entries for `duration:` values greater than 1000ms. Each slow-query entry → MEDIUM finding. Redact query text if it contains a secret-shaped string.

### Step E — Pooler-port grep

Search serverless/edge paths (`api/`, `netlify/`, `functions/`, `app/api/`, `pages/api/`, `edge-functions/`) for `:5432`. Match → HIGH: "Use Supavisor transaction pooler on port 6543 for serverless/edge connections."

### Step F — Seed-data check

Read `./supabase/seed.sql`. If absent, skip silently (no finding emitted). If present, scan for `test@test.com`, `password='admin'`, `admin:admin`, `123456`. Matches → MEDIUM.

### Step G — Env drift

Grep repo for `process.env.X`, `Deno.env.get('X')`, `import.meta.env.X`. Compare key names to `.env.production`. Missing keys → HIGH. Emit key NAMES only, no values.

If `.env.production` does not exist → emit `[INFO] No .env.production file present; env-drift check skipped.` Do not error.

### Step H — Migration drift (independent recompute)

Runs here as well as in Module 1 so that `--only=prod` still surfaces drift. Call `mcp__supabase__list_migrations` and compare against `./supabase/migrations/*.sql` on disk. Files present locally but not in DB → HIGH. Files in DB but not locally → MEDIUM. (If Module 1 also ran, findings are identical — deduplicate during report assembly by object name.)

### Step I — Manual checks (SMTP, MFA, PITR, webhooks)

These cannot be verified via read-only SQL. Emit each as:

```
[INFO] {title}
- What: ...
- Severity-if-absent: HIGH
- Verify manually: {steps in Supabase dashboard}
```

Items: Custom SMTP configured; MFA + leaked-password protection enabled; PITR enabled (if on paid plan); DB webhook + auth hook secrets set; email confirmation required before login.

---

## Phase 5 — Module 5: Client Coherence (sub-agent)

Skip this phase if `--only` is set and does not include `client`.

On any MCP/SQL error during cross-reference: emit `[INFO] Module 5 — {tool} unavailable: {error}` and continue.

### Sub-agent contract

Spawn a sub-agent with this exact prompt:

```
Goal: catalog every Supabase client call in this repo for schema-coherence audit.

Write results to ./tmp/db-audit/.client-scan.md using EXACTLY this structure:

  # client-scan
  <one line: `truncated: false` or `truncated: <reason>`>

  ## from
  | file | line | table | select |
  |------|------|-------|--------|
  | src/api/orders.ts | 42 | orders | id, total, status |

  ## rpc
  | file | line | fn | arg_count |

  ## channel_postgres_changes
  | file | line | table |

  ## storage_from
  | file | line | bucket |

  ## create_client
  | file | line | key_source |         # anon | service_role | other

  ## nplus1_candidates
  | file | line | snippet |

Patterns to grep (ripgrep syntax):
  - \.from\(['"]([^'"]+)['"]\)
  - \.rpc\(['"]([^'"]+)['"],?\s*(\{[^}]*\})?
  - \.channel\([^)]*\)\.on\(['"]postgres_changes['"]\s*,\s*\{\s*[^}]*table:\s*['"]([^'"]+)['"]
  - \.storage\.from\(['"]([^'"]+)['"]\)
  - createClient\(
  - \.from\([^)]+\)[^;]*(\.map|\.forEach|for\s*\()          # N+1 signal

Exclude paths: node_modules/, .git/, .next/, .nuxt/, dist/, build/, out/, .vercel/,
  .netlify/, storybook-static/, .turbo/, coverage/, supabase/.branches/, tmp/, *.lock

Cap 500 rows per section; set truncated line if any section hits the cap.
Return when written. Reply with just the path to the file you wrote.
```

### Main-skill consumption

1. Read `./tmp/db-audit/.client-scan.md`. If missing → emit `[INFO] Module 5 skipped: sub-agent output not found.` and continue.
2. Parse each `##` section table.
3. Cross-reference:
   - `mcp__supabase__list_tables` → `.from('X')` table-existence. Unknown table → HIGH.
   - `pg_proc` SELECT → `.rpc('fn')` function-existence. Unknown function → HIGH.
   - Realtime publication SELECT → channel table membership. Not in publication → MEDIUM.
   - `storage.buckets` (via execute_sql if anon-accessible, else INFO manual-check) → bucket existence.
   - `information_schema.columns` → `.select('a, b, c')` column-existence. Split by comma, trim each name, verify against table columns. Unknown column → HIGH. `'*'` → INFO only (wildcard accepted).
4. `createClient` with `key_source = 'service_role'` in client-reachable path → CRITICAL.
5. Multiple anon `createClient` sites in same bundle → LOW ("should be a singleton").
6. If `truncated: <reason>` → emit MEDIUM finding in report body (not just Meta): "Module 5 scan truncated — {categories} hit the 500-row cap; approximately {fraction} of calls analyzed. Re-run with `--only=client` for full scan."
7. Call `mcp__supabase__generate_typescript_types`. Diff against committed `./**/database.types.ts` if present. Any drift → MEDIUM per file.

---

## Phase 6 — Report Assembly

1. Collect all findings from Modules 1–5 into a list.
2. Apply redaction pass (Redaction Rules 1–4 above).
3. Sort: severity DESC → module → object_name ASC.
4. Render markdown:

```
# Supabase Audit — <project_url_host>

- Generated: <ISO timestamp>
- Project ref: <ref>
- Branch signal: <which signal fired (A/B/C/D)>
- Modules run: <list>
- Flags: <parsed flags>

## Summary
| Severity | Count |
|----------|-------|
| CRITICAL | N     |
| HIGH     | N     |
| MEDIUM   | N     |
| LOW      | N     |
| INFO     | N     |

## Critical Findings
{findings}

## High Findings
{findings}

## Medium Findings
{findings}

## Low Findings
{findings}

## Info
{findings}

## Meta
- .gitignore covers tmp/: OK | MISSING
- MCP project URL: <url>
- Modules skipped: <list or "none">
- Sub-agent truncation: <none | reason>
- list_branches raw shape: <full captured response for debugging>
```

5. Write to `./tmp/db-audit/YYYY-MM-DD-HHmm.md`.
6. Copy to `./tmp/db-audit/latest.md`.
7. Print one-screen summary to user with finding counts per severity and the report path.

---

## Phase 7 — DATABASE.md Offer

Prompt the user:

```
Generate a persistent DATABASE.md reference doc at <chosen_path>?
This file is committable (by you, not by me) and helps future LLM sessions
work from a cached schema snapshot instead of re-introspecting. (y/n)
```

Path selection: `./docs/` exists → `./docs/DATABASE.md`; else `./documentation/` → `./documentation/DATABASE.md`; else `./DATABASE.md`.

### Foreign-file guard

If target file exists, read its first two lines. If line 1 does NOT start with `_Generated by /supabase-audit on `:

```
<path> exists and was not generated by this skill. Its content will be replaced.
Type the path again to confirm, or 'cancel':
```

Overwrite only on exact path re-entry. If line 1 matches the marker, overwrite silently.

### DATABASE.md content spec

```
_Generated by /supabase-audit on <ISO date>. Regenerate to update. DO NOT HAND-EDIT._
<project ref> | Postgres <version>

## Tables
### public.<table>
| Column | Type | Nullable | Default | Notes |
- PK: ...
- FKs in: ..., FKs out: ...
- Indexes: ...
- Approx rows: <n_live_tup from pg_stat_user_tables>

## Enums & Custom Types

## Functions
(signature + COMMENT if any)

## Triggers
| Table | Event | Function |

## RLS Policies
(per table: name | cmd | roles | qual | with_check)

## Edge Functions
(name | slug | deployed version — from list_edge_functions)

## Storage Buckets
(name | public | has_policies)

## Auth Providers Enabled

## FK Graph
(adjacency list: table_a → table_b via col)
```

Line 1 is always the generator marker — this is what the foreign-file guard checks on future runs.
