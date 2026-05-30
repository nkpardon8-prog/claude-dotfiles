# database-audit — Supabase Provider Adapter

This file is `Read` by the `/database-audit` orchestrator **only when the detected/forced provider is `supabase`**. It declares (a) the Supabase connection method, (b) Supabase's contribution to the generalized prod-guard signal in `guards.md`, and (c) ONLY the Supabase-specific (non-portable) checks.

**Single source of truth:** the portable `pg_catalog`/`information_schema`/`pg_stats` queries (Q1.1–Q4.2) live in `core.md` and are NOT repeated here. This file references them by ID only. Everything below is logic that has no vanilla-Postgres equivalent.

---

## (a) Connection

Supabase is reached via the **Supabase MCP** — there is no direct `psql` path in the Supabase adapter; the portable `core.md` queries are dispatched through `mcp__supabase__execute_sql` (SELECT-only, see `guards.md`).

### Preflight detection (Phase 0a)

Provider is `supabase` when ANY of these repo signals match (mirrors the proven `/supabase-audit` Step 0.2 — must keep parity so a Supabase repo never silently degrades to `postgres`):

- `package.json` contains `@supabase/supabase-js` or `@supabase/ssr`
- `./supabase/config.toml` exists
- any `.env*` contains `SUPABASE_URL`
- `DATABASE_URL` host matches `*.supabase.co` / `*.pooler.supabase.com`

(Explicit `--provider=supabase` always wins; Supabase config.toml / `SUPABASE_URL` signals beat a bare `@neondatabase/serverless` dep — see orchestrator detection precedence.)

### MCP reachability (Phase 0a)

Call `mcp__supabase__get_project_url`. If it errors → print `"Supabase MCP unreachable. Run \`supabase link\` or check MCP config. Aborted."` and stop. (Supabase Preflight aborts on MCP error — there is no psql fallback for this adapter.)

Parse project ref from the returned URL: match `/https:\/\/([a-z0-9]+)\.supabase\.co/`, capture group 1.

### Tool names (use these EXACT identifiers)

| Purpose | Tool |
|---------|------|
| Project URL / ref | `mcp__supabase__get_project_url` |
| Branch metadata (prod guard) | `mcp__supabase__list_branches` |
| Table existence (Module 5) | `mcp__supabase__list_tables` |
| Extension inventory | `mcp__supabase__list_extensions` |
| Security / performance advisors | `mcp__supabase__get_advisors` |
| Postgres logs (slow queries) | `mcp__supabase__get_logs` |
| Applied migrations (drift) | `mcp__supabase__list_migrations` |
| SELECT-only SQL dispatch | `mcp__supabase__execute_sql` |
| TS types (Module 5 diff) | `mcp__supabase__generate_typescript_types` |
| Edge function inventory | `mcp__supabase__list_edge_functions` |

All mutating Supabase tools (`apply_migration`, `deploy_edge_function`, `create_branch`, `merge_branch`, `reset_branch`, `rebase_branch`, `delete_branch`) are in the `guards.md` Forbidden Tools list. Never call them.

---

## (b) Prod-guard contribution

The **generalized** prod guard lives in `guards.md`. This file supplies the Supabase signal function it dispatches to: the existing A/B/C/D branch-shape ladder.

```
supabase_branch_ladder():
  Call mcp__supabase__list_branches. Capture the raw response shape for the report Meta section.
  Evaluate signals in order:
    Signal A: list_branches returns an empty list → no branching            → TREAT AS PROD
    Signal B: any branch record has a field matching /parent.*ref/i whose
              value equals the current ref → current is parent              → TREAT AS PROD
    Signal C: any branch record has project_ref / project_id matching the
              current ref AND a sibling parent_project_ref that does NOT
              match → current IS a branch                                   → NOT PROD
    Signal D: none of the above (unknown shape)                             → TREAT AS PROD (safe default)
  Return PROD (signals A/B/D) or NOTPROD (signal C), plus which signal fired.
```

`list_branches` is a metadata-only call — it touches no user data, so it is permitted in Phase 0a, before the guard discharges. The stop/resume prompt itself (including the Supabase-flavored "Create a dev branch first: `supabase branches create <name>`" option text and the `proceed on prod` resume phrase) lives in `guards.md`. This function only produces the signal + the fired-signal letter.

---

## (c) Supabase-only platform modules

These have NO vanilla-Postgres equivalent. Portable SQL checks (Q1.1–Q4.2) are dispatched from `core.md` via `mcp__supabase__execute_sql`; do not re-list them here.

**`--only` gating applies to every platform module below** (see `database-audit.md` Platform-modules mapping). Each section is annotated with its governing `--only` token. If `--only` is set and does NOT include that token, the section is SKIPPED and issues NO `execute_sql` / advisor / control-plane call for it. When `--only` is unset, all run.

### Module 2 (RLS) — Supabase severity escalation + anon classification

`--only` token: **`rls`**.

- **RLS-off severity = CRITICAL.** Q2.1 (RLS off on public tables) is the portable query in `core.md`; its portable floor is the exposed-API context. In the Supabase context the `public` schema is reachable through the auto-generated PostgREST API as the `anon` role, so RLS-off escalates to **CRITICAL** here (this is the Supabase context the `core.md` note refers to).
- **anon/RLS classification heuristics (Q2.3 results).** Apply to the rows returned by the portable Q2.3 policy scan — these heuristics depend on the Supabase `anon` role:
  - `'anon'` in `roles` AND `cmd IN ('INSERT','UPDATE','DELETE')` → **HIGH** (anon write access)
  - `qual` contains `auth.uid()` without `(select auth.uid())` → **MEDIUM** (per-row re-eval perf bug; `auth.uid()` is Supabase-specific)
  - (The generic `qual = 'true'` blanket-permissive → CRITICAL classification already lives with Q2.3 in `core.md`.)

### Module 3 (Security) — Supabase platform steps

`--only` token: **`security`** (Step A advisors, Step E extensions, Step F pg_cron probe + inventory all gated by `security`).

**Step A — Supabase security advisors.** Call `mcp__supabase__get_advisors({type: "security"})`. Include every finding; map Supabase severity to our tiers. The Q3.x security-advisor mapping:

| Supabase advisor severity | Our tier |
|---------------------------|----------|
| ERROR / CRITICAL          | CRITICAL |
| WARN / WARNING            | HIGH     |
| INFO                      | INFO     |

**Step E — Risky extensions.** Call `mcp__supabase__list_extensions`. Flag: `http`, `pg_net`, `plpython3u`, `plpythonu`, any `*_fdw`. Severity: **HIGH**. Add an INFO note on the justification requirement.

**Step F — pg_cron inventory (conditional).** Execute only if `SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'` returns a row (this gating probe is a vetted SELECT). If absent → skip (INFO: "pg_cron not installed"). Otherwise:

```sql
-- Q3.2 — cron jobs
SELECT jobname, schedule, command, nodename, username
FROM cron.job;
```

Each job is an INFO finding. Suspicious `command` values (DML, TRUNCATE, COPY) → MEDIUM.

(`Q3.1` PII inventory and `Q3.3` dynamic-SQL scan are portable — they live in `core.md`.)

### Module 4 (Production Readiness) — Supabase platform steps

**Step A — Performance advisors.** Call `mcp__supabase__get_advisors({type: "performance"})`. Include every finding verbatim.

**Supported Postgres major versions** (supplied to portable Q4.1): `['15', '16', '17']`. List last updated: `2026-01`. Major version not in this list → HIGH. EOL staleness: if today's date is more than 18 months after `2026-01` → emit INFO: "Supabase Postgres version data may be stale; verify at supabase.com/docs."

**Step D — Slow-query log scan.** Call `mcp__supabase__get_logs({type: "postgres"})`. Scan entries for `duration:` values greater than 1000ms. Each slow-query entry → MEDIUM finding. Redact query text if it contains a secret-shaped string (redaction rule 1).

**Step E — Pooler-port grep.** Search serverless/edge paths (`api/`, `netlify/`, `functions/`, `app/api/`, `pages/api/`, `edge-functions/`) for `:5432`. Match → **HIGH**: "Use Supavisor transaction pooler on port 6543 for serverless/edge connections." (Portable file-scan via grep; no GNU `xargs -r` — if scoping by tracked files, use `files=$(git ls-files); [ -n "$files" ] && printf '%s\n' "$files" | xargs grep -l ':5432'` or `git grep -l ':5432'`.)

**Step I — Manual checks (SMTP, MFA, PITR, webhooks).** These cannot be verified via read-only SQL. Emit each as:

```
[INFO] {title}
- What: ...
- Severity-if-absent: HIGH
- Verify manually: {steps in Supabase dashboard}
```

Items: Custom SMTP configured; MFA + leaked-password protection enabled; PITR enabled (if on paid plan); DB webhook + auth hook secrets set; email confirmation required before login.

### Storage buckets

`storage.buckets` (via `mcp__supabase__execute_sql` if anon-accessible, else emit an INFO manual-check) → bucket existence + public flag + has_policies. Public buckets without policies → HIGH. Feeds the DATABASE.md Storage Buckets section.

### Edge functions

Call `mcp__supabase__list_edge_functions` → inventory (name | slug | deployed version). Feeds the DATABASE.md Edge Functions section and the Module-5 N/A note for non-Supabase providers.

### Realtime publications

Realtime publication membership (which tables are in the `supabase_realtime` publication, via a vetted SELECT against `pg_publication_tables`) feeds the Module-5 channel cross-reference (below). Not in publication → MEDIUM for any `.channel(...).on('postgres_changes', { table: 'X' })` site.

---

## Module 5 — Client coherence (sub-agent)

Skip if `--only` is set and does not include `client`. On any MCP error during cross-reference: emit `[INFO] Module 5 — {tool} unavailable: {error}` and continue.

> **CRITICAL GOTCHA:** A spawned sub-agent does **NOT** inherit the orchestrator's Read'd files. The sub-agent prompt below must be embedded **VERBATIM** into the `Agent` call as literal prompt text — do not reference this file from inside the sub-agent, and do not paraphrase it.

### Sub-agent contract — embed this block verbatim into the Agent call

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
   - `storage.buckets` (via `execute_sql` if anon-accessible, else INFO manual-check) → bucket existence.
   - `information_schema.columns` → `.select('a, b, c')` column-existence. Split by comma, trim each name, verify against table columns. Unknown column → HIGH. `'*'` → INFO only (wildcard accepted).
4. `createClient` with `key_source = 'service_role'` in client-reachable path → CRITICAL.
5. Multiple anon `createClient` sites in same bundle → LOW ("should be a singleton").
6. If `truncated: <reason>` → emit a MEDIUM finding in report body (not just Meta): "Module 5 scan truncated — {categories} hit the 500-row cap; approximately {fraction} of calls analyzed. Re-run with `--only=client` for full scan."
7. Call `mcp__supabase__generate_typescript_types`. Diff against committed `./**/database.types.ts` if present. Any drift → MEDIUM per file. (This step is Supabase-only — Neon/vanilla emit INFO-N/A.)

---

## DATABASE.md provider sections (Supabase-only)

The orchestrator's Phase-7 DATABASE.md template conditionalizes these sections per provider. The Supabase adapter populates:

```
## Edge Functions
(name | slug | deployed version — from list_edge_functions)

## Storage Buckets
(name | public | has_policies — from storage.buckets)

## Auth Providers Enabled
(enabled external/email/phone providers — manual-verify item; emit as inventory)
```

On Neon/vanilla these three sections emit INFO-N/A (see `providers/neon.md` and `providers/postgres.md`).
