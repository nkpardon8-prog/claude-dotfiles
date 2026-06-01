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

Call `mcp__supabase__get_project_url`. If it succeeds, parse project ref from the returned URL: match `/https:\/\/([a-z0-9]+)\.supabase\.co/`, capture group 1.

**If it errors → graceful degradation case (a), NOT a hard abort.** The Supabase adapter has no `psql` fallback, so an unreachable MCP means there is **no connection source at all** — and with no connection there is **no prod-data risk**, so this is neither a prod-stop nor an abort. Instead:

1. Emit `[INFO] No DB connection/MCP available — SQL + platform modules skipped; filesystem checks only` (include the MCP error text passed through the `redaction.md` rules first — scrub any connection string / secret-shaped token). A short human note such as `Supabase MCP unreachable — run \`supabase link\` or check MCP config` may accompany it, but do NOT abort.
2. Hand off to the orchestrator's **Step 0a.6 no-connection-source path**: run ONLY the zero-data-touch filesystem modules (`run_filesystem_only_modules`), assemble the partial report, and exit cleanly. Do NOT enter Phase 0b.
3. Record `Connection source: none` in Meta.

(The one legitimate informational case is Phase 0 Supabase-detection-but-MCP-not-configured-at-all: same treatment — inform via the `[INFO]` finding and produce a filesystem-only report, never a bare abort.)

### Tool names (use these EXACT identifiers)

| Purpose | Tool |
|---------|------|
| Project URL / ref | `mcp__supabase__get_project_url` |
| Branch metadata (prod guard) | `mcp__supabase__list_branches` |
| Table existence (Module 5) | `mcp__supabase__list_tables` |
| Extension inventory | `mcp__supabase__list_extensions` |
| Security / performance advisors | `mcp__supabase__get_advisors` |
| Postgres logs (slow queries) | `mcp__supabase__get_logs` |
| Applied migrations (drift) | `mcp__supabase__list_migrations` |[^migdrift]

[^migdrift]: When this path emits migration-drift findings from the `list_migrations` result, it MUST use the canonical finding identity defined in `core.md` Module 1 → "Migration drift" (exact titles `Migration drift: local-not-in-DB` / `Migration drift: in-DB-not-local` and `object_name` = bare migration filename) so Phase 6 dedup collapses it with the core Module 1 emission.
| SELECT-only SQL dispatch | `mcp__supabase__execute_sql` |
| TS types (Module 5 diff) | `mcp__supabase__generate_typescript_types` |
| Edge function inventory | `mcp__supabase__list_edge_functions` |

All mutating Supabase tools (`apply_migration`, `deploy_edge_function`, `create_branch`, `merge_branch`, `reset_branch`, `rebase_branch`, `delete_branch`) are in the `guards.md` Forbidden Tools list. Never call them. The `guards.md` Forbidden Tools list is authoritative and now also bans `pause_project`, `restore_project`, and `update_storage_config` — defer to `guards.md` as the canonical denylist rather than re-enumerating it here.

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

**Indeterminate-probe safe default (matches Neon).** If `list_branches` errors, is empty, or returns an unrecognized/indeterminate shape → resolve **PROD** (the safe default) and apply the prod-stop, exactly like signal D. NEVER resolve NOT-PROD on an indeterminate branch probe. (An empty list is already signal A → PROD; an errored or unrecognized response folds into signal D → PROD.)

`list_branches` is a metadata-only call — it touches no user data, so it is permitted in Phase 0a, before the guard discharges. The stop/resume prompt itself (including the Supabase-flavored "Create a dev branch first: `supabase branches create <name>`" option text and the `proceed on prod` resume phrase) lives in `guards.md`. This function only produces the signal + the fired-signal letter.

---

## (c) Supabase-only platform modules

These have NO vanilla-Postgres equivalent. Portable SQL checks (Q1.1–Q4.2) are dispatched from `core.md` via `mcp__supabase__execute_sql`; do not re-list them here.

**`--only` gating applies to every platform module below** (see `database-audit.md` Platform-modules mapping). Each section is annotated with its governing `--only` token. If `--only` is set and does NOT include that token, the section is SKIPPED and issues NO `execute_sql` / advisor / control-plane call for it. When `--only` is unset, all run.

### Module 2 (RLS) — Supabase severity escalation + anon classification

`--only` token: **`rls`**.

- **RLS-off severity = CRITICAL (exposed-API case).** Q2.1 severity is CONTEXT-DEPENDENT (not a floor): CRITICAL when the table is reachable via an exposed data API (Supabase `anon` / Neon Data API), HIGH otherwise. Q2.1 (RLS off on public tables) is the portable query in `core.md`; it reports the condition only. In the Supabase context the `public` schema is reachable through the auto-generated PostgREST API as the `anon` role, so RLS-off resolves to **CRITICAL** here (this is the exposed-API case the `core.md` note refers to).
- **anon/RLS classification heuristics (Q2.3 results) — Supabase-specific, applied ON TOP of the core result.** These two heuristics are NOT in `core.md` (they reference Supabase concepts — the `anon` role and the `auth.uid()` helper). Apply them to the rows returned by the portable Q2.3 policy scan, in addition to the portable blanket-permissive heuristics that `core.md` already applied to the same rows:
  - `'anon'` in `roles` AND `cmd IN ('INSERT','UPDATE','DELETE')` → **HIGH** (anon write access; `anon` is the Supabase PostgREST role)
  - `qual` contains `auth.uid()` without `(select auth.uid())` → **MEDIUM** (per-row re-eval perf bug; `auth.uid()` is Supabase-specific)
  - (The provider-agnostic `qual = 'true'` and unconditional `with_check = 'true'` blanket-permissive → CRITICAL classifications stay with Q2.3 in `core.md` and are NOT repeated here, so a single policy row never gets two severity mechanisms from one file.)

### Module 3 (Security) — Supabase platform steps

`--only` token: **`security`** (Step A advisors, Step E extensions, Step F pg_cron probe + inventory all gated by `security`).

**Step A — Supabase security advisors.** Call `mcp__supabase__get_advisors({type: "security"})`. Include every finding; map Supabase severity to our tiers. The Q3.x security-advisor mapping:

| Supabase advisor severity | Our tier |
|---------------------------|----------|
| ERROR / CRITICAL          | CRITICAL |
| WARN / WARNING            | HIGH     |
| INFO                      | INFO     |

**Step E — Risky extensions.** Call `mcp__supabase__list_extensions`. Flag: `http`, `pg_net`, `plpython3u`, `plpythonu`, any `*_fdw`. Severity: **HIGH**. Add an INFO note on the justification requirement.

**Step F — pg_cron inventory (conditional).** Execute only if `pg_cron` is present in the `core.md` Preamble P3 extension inventory (P3 is the single extension-inventory source — do NOT re-query `pg_extension` here). If `pg_cron` is absent from the P3 result → skip (INFO: "pg_cron not installed"). Otherwise:

```sql
-- Q3.2 — cron jobs (NON-SECRET columns only)
SELECT jobid, jobname, schedule, active
FROM cron.job;
```

Each job is an INFO finding. **NEVER select `cron.job.command`** — command bodies can embed tokens, webhook URLs, connection strings, and literal PII, so they are excluded from the SELECT entirely (aligns with `core.md` Module 12.3, which never selects `cron.job.command` for this reason). Reporting the job's existence + schedule (`jobid`, `jobname`, `schedule`, `active`) is the signal; the command body is not worth the secret-exposure risk.

(`Q3.1` PII inventory and `Q3.3` dynamic-SQL scan are portable — they live in `core.md`.)

### Module 4 (Production Readiness) — Supabase platform steps

`--only` token: **`prod`** (performance advisors, version, slow-query log, pooler-port grep, manual checks all gated by `prod`).

**Step A — Performance advisors.** Call `mcp__supabase__get_advisors({type: "performance"})`. Include every finding verbatim.

**Supported Postgres major versions** (supplied to portable Q4.1): `['15', '16', '17', '18']`. List last updated: `2026-05`. Review this list against the provider's version calendar periodically; EOL majors removed (PG13 EOL 2025-11), new GA majors added (PG18 GA 2025). `'18'` is included pre-emptively: a too-new-but-listed version is harmless (no false finding), whereas omitting a GA major that Supabase offers would produce a false HIGH "unsupported version" finding. Major version not in this list → HIGH. EOL staleness: if today's date is more than 18 months after `2026-05` → emit INFO: "Supabase Postgres version data may be stale; verify at supabase.com/docs."

**Step D — Slow-query log scan.** Call `mcp__supabase__get_logs({type: "postgres"})`. Scan entries for `duration:` values greater than 1000ms. Each slow-query entry → MEDIUM finding. **Redaction:** logged query text can embed tokens, connection strings, and literal PII. Prefer reporting the query SHAPE/fingerprint over raw text; if raw text is included it MUST first be passed through the redaction pass (`redaction.md` rules 1–5) and truncated/summarized — never report a raw slow-query body.

**Step E — Pooler-port grep.** Search serverless/edge paths (`api/`, `netlify/`, `functions/`, `app/api/`, `pages/api/`, `edge-functions/`) for `:5432`. Match → **HIGH**: "Use Supavisor transaction pooler on port 6543 for serverless/edge connections." (Portable file-scan via grep; no GNU `xargs -r` — if scoping by tracked files, use `files=$(git ls-files); [ -n "$files" ] && printf '%s\n' "$files" | xargs grep -l ':5432'` or `git grep -l ':5432'`.)

**Step I — Manual checks (SMTP, MFA, webhooks).** These cannot be verified via read-only SQL. Emit each as:

```
[INFO] {title}
- What: ...
- Severity-if-absent: HIGH
- Verify manually: {steps in Supabase dashboard}
```

Items: Custom SMTP configured; MFA + leaked-password protection enabled; DB webhook + auth hook secrets set; email confirmation required before login.

(PITR was pulled out of this bundle into its own manual-verify INFO under the `backup` + `prod` tokens — see "Step I-PITR" below — so `--only=backup` surfaces recovery posture on Supabase. Module 14.3 in `core.md` is vanilla+Neon-only and DEFERS to that Supabase-owned PITR line; on a Supabase run core 14.3 emits nothing and cross-refs "PITR → see Supabase Step I-PITR".)

**Step I-PITR — PITR / point-in-time recovery (manual-verify).**

`--only` tokens: **`backup`** AND **`prod`** (this item runs whenever EITHER token is selected — `--only=backup` must surface PITR on Supabase, and a full prod-readiness pass `--only=prod` still includes it). PITR cannot be verified via read-only SQL. This is the **canonical Supabase PITR owner**; `core.md` Module 14.3 defers to it. Emit as a standalone manual-verify INFO with its own title/object_name (so it is NOT collapsed into the Step-I HIGH bundle by Phase-6 dedup) and never pass/fail:

```
[INFO] PITR (point-in-time recovery) enabled
- What: Supabase PITR add-on (paid plan) provides continuous WAL-based recovery to any moment in the retention window. Without it, recovery is limited to daily logical backups.
- Severity-if-absent: CRITICAL
- Verify manually: Supabase dashboard → Project Settings → Database → Point-in-Time Recovery (confirm enabled + retention window on a paid plan).
```

### Module 10/11 (Compliance & Encryption) — Supabase at-rest encryption (manual-verify)

`--only` token: **`compliance`**.

Most of Modules 10/11 are portable-core (`pg_extension` pgaudit/crypto-tooling posture, `ssl`/`pg_stat_ssl` in-transit checks) and run from `core.md` via `mcp__supabase__execute_sql` — they need no Supabase-specific section. The one genuinely Supabase-specific facet is **at-rest encryption**, which cannot be verified via read-only SQL and is a `[PROVIDER]` manual-verify INFO (never pass/fail):

```
[INFO] At-rest encryption (storage)
- What: Supabase encrypts the underlying database storage at rest with AES-256.
- Severity-if-absent: N/A (platform-managed — verify, do not assert pass/fail)
- Verify manually: Supabase dashboard / Supabase security & compliance docs (SOC2 report) → confirm AES-256 at-rest encryption for the project's region/plan.
```

### Storage buckets

`--only` token: **`client`**.

`storage.buckets` (via `mcp__supabase__execute_sql` if anon-accessible, else emit an INFO manual-check) → bucket existence + public flag + has_policies. Public buckets without policies → HIGH. Feeds the DATABASE.md Storage Buckets section.

### Edge functions

`--only` token: **`client`**.

Call `mcp__supabase__list_edge_functions` → inventory (name | slug | deployed version). Feeds the DATABASE.md Edge Functions section and the Module-5 N/A note for non-Supabase providers.

### Realtime publications

`--only` token: **`client`**.

Realtime publication membership (which tables are in the `supabase_realtime` publication, via a vetted SELECT against `pg_publication_tables`) feeds the Module-5 channel cross-reference (below). Not in publication → MEDIUM for any `.channel(...).on('postgres_changes', { table: 'X' })` site.

---

## Module 5 — Client coherence (sub-agent)

Skip if `--only` is set and does not include `client`. On any MCP error during cross-reference: emit `[INFO] Module 5 — {tool} unavailable: {error}` and continue.

> **CRITICAL GOTCHA:** A spawned sub-agent does **NOT** inherit the orchestrator's Read'd files. The sub-agent prompt below must be embedded **VERBATIM** into the `Agent` call as literal prompt text — do not reference this file from inside the sub-agent, and do not paraphrase it.

**Scratch-file location (write-allowlist compliance).** The `.client-scan.md` scratch file is written under the RESOLVED report location (`$REPORT_DIR` from Step 0a.5), NOT a hardcoded `./tmp/db-audit/`. Substitute the resolved `$REPORT_DIR` into the `Write results to $REPORT_DIR/.client-scan.md` line before dispatching. In the `$(pwd)` fallback mode (no writable `./tmp/`, `REPORT_DIR=$(pwd)`), the single `$(pwd)/db-audit-<ts>.md` report is the only sanctioned write — so Module 5 is SKIPPED with `[INFO] Module 5 skipped — no writable tmp/ for the client-scan scratch file` (per orchestrator Phase 5) and the sub-agent is NOT spawned.

**Cross-reference is IN-MEMORY only (no repo literals in SQL).** Cross-referencing compares repo-derived names against catalog results in memory; repo literals are NEVER concatenated into executed SQL. Read the catalog (`list_tables` / `information_schema` / `pg_proc`) into memory once, then compare the repo-derived table / function / column NAMES against those in-memory results — NEVER interpolate a repo-derived literal into a SQL string (that violates the fixed-library guard and is an injection vector from a hostile repo).

### Sub-agent contract — embed this block verbatim into the Agent call

```
Goal: catalog every Supabase client call in this repo for schema-coherence audit.

Write results to $REPORT_DIR/.client-scan.md using EXACTLY this structure:

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

1. Read `$REPORT_DIR/.client-scan.md` (the same resolved report location the sub-agent wrote to — NOT a hardcoded `./tmp/db-audit/`). If missing → emit `[INFO] Module 5 skipped: sub-agent output not found.` and continue.
2. Parse each `##` section table.
3. Cross-reference — fetch the catalog ONCE into memory (`list_tables` for tables, a `pg_proc` SELECT for functions, `information_schema.columns` for columns, the realtime-publication SELECT for channels, `storage.buckets` for buckets) and compare the repo-derived names against those in-memory results. Repo-derived literals are NEVER concatenated into an executed SQL string — comparison is in-memory only:
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
