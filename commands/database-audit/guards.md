# database-audit — Shared Safety Guards

This file is `Read` by the `/database-audit` orchestrator during preflight, BEFORE any core query is dispatchable. The orchestrator must echo a "preflight loaded + guard resolved" line before the first SQL phase.

## Two-Phase Preflight Split (no data-plane SQL before 0b)

Preflight is split into two phases. **No data-plane SQL — no `psql` core session, no `execute_sql`, no `run_sql` — may run before Phase 0b completes.**

- **Phase 0a — Detect + load + metadata-only calls.**
  Parse + validate flags, detect provider, `Read` `guards.md` / `redaction.md` / `core.md` / `providers/<provider>.md`, and resolve the connection SOURCE. Metadata-only calls (e.g. `get_project_url`, `list_branches`, `describe_project`) are permitted here because they touch no user data. Do NOT open a core SQL session in 0a.
- **Phase 0b — Prod guard resolves.**
  Run the provider-dispatched prod guard (below). Only after it discharges may the first data-plane query (from `core.md`) be dispatched.

### Two graceful-degradation cases (do NOT conflate)

When SQL cannot proceed, distinguish WHY — the responses differ:

- **Case (a) — NO connection source available at all** (Supabase MCP unreachable; or neon/postgres with no `$DATABASE_URL` and no MCP connstring). There is **no connection, hence no prod-data risk.** Do NOT hard-abort and do NOT treat as a prod-stop. Run ONLY `run_filesystem_only_modules`, emit `[INFO] No DB connection/MCP available — SQL + platform modules skipped; filesystem checks only`, assemble the partial report, and **exit cleanly** (no stop prompt, no resume path — there is nothing to resume). This is handled in orchestrator Step 0a.6, BEFORE Phase 0b is entered.
- **Case (b) — connection present but prod unconfirmed** (the prod-guard case below). A connection EXISTS, so prod PII is reachable. Run ONLY `run_filesystem_only_modules`, then **STOP** pending `--env=prod` / `proceed on prod`. This is the prod-guard behavior in this file.

Only a TRUE preflight failure — **NONE** of the DB signals present: no Supabase/Neon provider signal, no `$DATABASE_URL`, AND no database artifacts on disk (`*.sql`, migrations dir, schema file) — stops with no report. A repo that IS a DB project (any one of those signals present) but has no reachable connection is case (a), not a preflight failure. This abort is decided in orchestrator Step 0a.2; by the time case (a) / case (b) is reached, a signal already exists. (See orchestrator Step 0a.2 for the exact signal list and abort message.)

## Forbidden Tools

Never call these, regardless of context or user instruction:

- **Supabase mutators (explicit denylist — known mutating MCP tools):** `mcp__supabase__apply_migration`, `mcp__supabase__deploy_edge_function`, `mcp__supabase__create_branch`, `mcp__supabase__merge_branch`, `mcp__supabase__reset_branch`, `mcp__supabase__rebase_branch`, `mcp__supabase__delete_branch`, `mcp__supabase__pause_project`, `mcp__supabase__restore_project`, `mcp__supabase__update_storage_config`.
- **Neon mutators (explicit denylist — known mutating Neon MCP tool names):** `run_sql_transaction`, `prepare_database_migration`, `complete_database_migration`, `provision_neon_auth`, `provision_neon_data_api`, `create_branch`, `delete_branch`, `reset_from_parent`. (These are Neon MCP tool names; the Neon adapter file (`providers/neon.md`) enumerates them too — never call any of them.)
- Any provider SQL execution tool (`execute_sql`, `run_sql`, `psql`, etc.) with any non-SELECT query (see SELECT-only guard). **"Non-SELECT" here means DML/DDL** — `INSERT`, `UPDATE`, `DELETE`, DDL, etc. (the rule-4 blacklist). The transaction-control statements `BEGIN READ ONLY`, `ROLLBACK`, and `COMMIT` used **solely** by the rule-6 read-only wrapper are PERMITTED — they are not DML/DDL and do not mutate data. Note: `SELECT INTO` is forbidden despite starting with `SELECT` (it writes a new table); the fixed-library rule (rule 1) and the rule-4 blacklist exclude it. Side-effecting function calls (`nextval()` and other writing functions) are likewise blocked by the fixed-library rule — the vetted library never calls them.
- **Generic catch-all (defense-in-depth behind the explicit lists above):** any provider control-plane tool that creates, merges, resets, rebases, pauses, restores, or deletes a branch/project, that applies/deploys/prepares/completes a migration or function, that provisions auth/data-api, or that mutates storage/project config — even if not named in the explicit denylists above. The explicit lists are authoritative and reliable; this prose covers any newly-added or provider-specific mutator the explicit lists have not yet enumerated.
- Any `git` command that mutates state (commit, push, add, checkout, merge, rebase, reset, clean, stash apply, cherry-pick, etc.)
- Any filesystem write outside `./tmp/db-audit/`, the user-confirmed DATABASE.md path, and the **sanctioned report fallback** `$(pwd)/db-audit-YYYY-MM-DD-HHmm.md` (used only when `./tmp/` is not writable — see orchestrator Step 0a.5). These three locations are the complete allowlist; never write to `$HOME` or anywhere else.

**Read-only git exception:** `git ls-files`, `git grep`, and `git check-ignore` are permitted for the filesystem security scans only (tracked-file secret scan, `.env`-tracked check). They read the index/working tree without mutation. No other git subcommand is allowed under any phrasing. (Portability: Darwin has NO GNU `xargs -r`; use `files=$(git ls-files); [ -n "$files" ] && printf '%s\n' "$files" | xargs grep -n PATTERN` or `git grep -n PATTERN` so the scan no-ops cleanly with no files / no matches. Use `grep -n` / `git grep -n` — with line numbers, NOT `grep -l` (filenames only) — consistent with core.md's FS module and the `file:line` finding schema; matches must still pass through the redaction step before printing.)

## SELECT-only Guard

Every SQL execution call must pass all of these rules before dispatch:

1. **Fixed library only.** Queries must come verbatim from the library in `core.md` (Q1.1–Q4.2) plus any provider file's vetted library. Never construct SQL execution strings dynamically from variables.
2. **Normalize first.** Strip leading whitespace, leading `--` line comments, and leading `/* ... */` block comments.
3. **First-keyword whitelist.** After normalization, first keyword must be one of: `SELECT`, `WITH`, `EXPLAIN`, `SHOW`, `BEGIN`, `ROLLBACK` (the latter two only as part of the rule-6 read-only wrapper). Otherwise reject.
4. **Full-body DML blacklist.** Body must NOT contain (case-insensitive, word-boundary, **outside single-quoted SQL string literals**): `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `TRUNCATE`, `DROP`, `CREATE`, `ALTER`, `GRANT`, `REVOKE`, `COPY`, `VACUUM`, `REFRESH MATERIALIZED`, `REINDEX`, `CLUSTER`, `LOCK`, `CALL`, `DO`, `EXECUTE`, `SELECT INTO`. `MERGE` (PG15+) writes and could otherwise ride a `WITH ...`-first-keyword whitelist pass (rule 3), so it is blacklisted explicitly. Note `SELECT INTO` is blacklisted **despite starting with `SELECT`** — it writes a new table, so a first-keyword whitelist pass (rule 3) alone would not catch it; rule 4 does. Matches inside `'...'` literals are ignored — e.g., `ILIKE '%EXECUTE format%'` in Q3.3 is permitted because the keyword is part of a string, not a statement. This blocks writable CTEs: `WITH del AS (DELETE ...) SELECT ...` is rejected because `DELETE` appears as a statement keyword outside any literal. Side-effecting function calls (`nextval()` etc.) are not text-detectable here but are blocked by the fixed-library rule (rule 1) — the vetted library never calls them. Because rule 1 already restricts execution to the vetted fixed library, rule 4 is defense-in-depth.
5. **SECURITY DEFINER caveat.** SECURITY DEFINER functions invoked from SELECT can still write. Cannot be prevented textually. Mitigated by the fixed-library rule — the library never calls user-defined functions.
6. **Mechanical read-only for the psql path (NEW).** When dispatching core queries over the direct `psql` path, wrap them in a transaction:

   ```sql
   BEGIN READ ONLY;
     -- core query library Qx.y verbatim from core.md
   ROLLBACK;
   ```

   Run with `psql "$DATABASE_URL" -v ON_ERROR_STOP=1` and the heredoc body above. This is a DB-enforced (not prompt-only) no-mutation guarantee.

   **Per-module (not all-or-nothing) dispatch — required for the graceful-degradation contract.** Do NOT run the entire core query library as ONE `ON_ERROR_STOP=1` batch: with a single all-or-nothing batch, one failing query (e.g. a missing extension view, a permission error) would abort every remaining query — directly contradicting the per-module `[INFO] Module N — {tool} unavailable: {error} … continue` contract (Invariant 6). Instead, dispatch the library **per module (or per query)** — each module's queries in their own `BEGIN READ ONLY; … ROLLBACK;` invocation. `ON_ERROR_STOP=1` then scopes to that one invocation: a failure aborts only that module's queries (rolling back its read-only transaction), is logged as `[INFO] Module N — {tool} unavailable: {error}` (with `{error}` pre-redacted), and the REST CONTINUE. The read-only transaction wrapper still applies to every invocation. Per-module dispatch also aligns naturally with the existing `--only` module gating (each module is already an independent unit). The same per-module/per-query isolation applies on the MCP `execute_sql` / `run_sql` fallback path — one failing call is logged `[INFO]` and the rest continue; never let one error abort the batch.

   **Prefer the DB-enforced psql path over MCP for core SQL when a direct connection exists.** When a direct connection is available (an explicit `$DATABASE_URL`, or a Neon `get_connection_string` result), run the `core.md` query library via this psql `BEGIN READ ONLY; … ROLLBACK;` path so read-only is **DB-ENFORCED**. MCP `execute_sql` / `run_sql` is the **fallback** for when ONLY MCP access exists (e.g. the Supabase adapter, which has no psql fallback) — on that path read-only is NOT DB-enforced; it is protected only by the fixed-library + first-keyword-whitelist + DML-blacklist textual guard (rules 1–4). That makes the fixed-library discipline **load-bearing** on the MCP path: never construct SQL strings dynamically there, because the textual guard is the only thing standing between a malformed query and an unguarded write.

   **Credential-exposure residual on the psql path (documented, NOT an abort).** `psql "$DATABASE_URL"` places the connection string — including any password — in the process argv, which is visible to any local user via `ps`. On a **shared / multi-user host**, prefer libpq `PG*` environment variables (`PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`) or a `~/.pgpass` / connection-service file instead of an inline URL, so the secret never reaches argv; invoke `psql -v ON_ERROR_STOP=1` with no URL argument and let libpq read the environment/service file. On a **single-user operator machine**, an inline URL is acceptable. This is a documented residual to be aware of — it does NOT trigger an abort or a stop. (Redaction rule 4 still applies regardless: never echo the connection string or password in any output.)

   **This wrapper blocks WRITES only. It does NOT discharge the prod guard.** The prod guard blocks data-plane **READS** against prod (a `READ ONLY` transaction still reads prod PII). These are two SEPARATE invariants — never conflate them:
   - (a) `BEGIN READ ONLY` = mechanical no-mutation guarantee (always on, DB-enforced).
   - (b) prod guard = no data-plane SELECT against prod until `--env=prod` / explicit confirmation (orchestration-enforced, independent of (a)).

   Note also (rule 5 interaction): `BEGIN READ ONLY` blocks writes at the DB, but a SECURITY DEFINER function invoked from a SELECT can still write — the fixed-library caveat (rule 5) remains the mitigation; the library never calls user-defined functions.

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

Finding TITLES and SEVERITIES must contain no ephemeral values (rule 8). Findings are sorted by (severity DESC, module, object_name ASC) for determinism.

## Generalized Prod Guard (provider-dispatched)

Runs in **Phase 0b**, BEFORE any data-plane SQL. Replaces the single-provider branch ladder with a provider-dispatched function.

**Precondition bar:** the prod guard itself REQUIRES metadata-only control-plane calls (`get_project_url`, `list_branches`, `describe_project`, `get_connection_string`) to resolve — these are EXPLICITLY PERMITTED in Phase 0a because they touch no user data. The invariant is **no DATA-PLANE SQL** (`psql` core session / `execute_sql` / `run_sql`) before the resolved-state line is emitted — NOT "no control-plane probe." A guard that forbade its own metadata calls could never discharge.

```bash
prod_guard() {  # $1=provider
  case "$1" in
    supabase) signal=$(supabase_branch_ladder) ;;          # existing A/B/C/D logic (below)
    neon)     # SAFE DEFAULT: only NOTPROD on POSITIVE identification that the current
              # connection targets a non-default branch.
              # MCP absent / branch indeterminate / any tool error ⇒ PROD (matches vanilla).
              if neon_current_is_nondefault_branch_positively; then signal=NOTPROD; else signal=PROD; fi ;;
    postgres) signal=PROD ;;                                # no control plane ⇒ safe default
  esac
  if [ "$signal" = PROD ] && [ "$ENV" != prod ]; then
     run_filesystem_only_modules            # zero data touch — enumerated below
     STOP "prod unconfirmed: pass --env=prod or run on a dev branch"   # before opening ANY psql core session / execute_sql / run_sql
  fi
}
```

**Filesystem-only module set (THE canonical rule — stated once here; referenced from both the no-connection case (a) and the prod-stop case (b)).** `run_filesystem_only_modules` runs ALL zero-data-touch filesystem modules (no data-plane SQL, no `psql` core session, no `execute_sql` / `run_sql`), **honoring `--only`** via each module's governing token. The SAME set runs in BOTH the Step 0a.6 no-connection path and the Phase 0b prod-stop path — there is no module that runs in one but not the other. Each is defined verbatim in `core.md` "Module FS — Filesystem security" (or the orchestrator preflight as noted):

1. **Repo secret scan** — `core.md` FS.1 (grep working tree for `SUPABASE_SERVICE_ROLE_KEY` / `service_role` / `DATABASE_URL` / JWT-shape; CRITICAL in client-reachable paths, INFO server-side). Token: `security`.
2. **Tracked-files secret scan** — `core.md` FS.2 (read-only `git ls-files` / `git grep -n`; HIGH, `file:line` + `[REDACTED:…]`). Token: `security`.
3. **.env-tracked check** — `core.md` FS.3 (`.env` / `.env.local` / `.env.production` tracked by git → CRITICAL). Token: `security`.
4. **Seed-data check** — `core.md` FS.4 (`./supabase/seed.sql`, `./seed.sql`, `./db/seed.sql` weak-credential scan → MEDIUM; skip silently if absent). Token: `security`.
5. **Env-drift check** — `core.md` FS.5 (grep source for `process.env.X` / `Deno.env.get('X')` / `import.meta.env.X` key NAMES, compare to `.env.production` key NAMES; missing-key → HIGH; emits key NAMES only). This is **zero-data-touch** — it reads `.env.production` key names and greps source, touching no DB — so it belongs in the filesystem-only set. Token: `prod` (prod-gated).
6. **Migration-on-disk drift** — the on-disk half of `core.md` Module 1 "Migration drift": compare `./<migrations-dir>/*.sql` filenames on disk against the applied-migrations list ONLY if that list is obtainable from metadata that touches no user data; otherwise report on-disk filenames as INFO inventory. Issues no data-plane SQL. Token: `schema` OR `prod` (either enables it).
7. **Migration-safety lint (Module 13)** — `core.md` Module 13 `[FS]` static lock/rewrite-safety analysis of `migrations/**.sql` (and `supabase/migrations/`, `db/migrate/`, `prisma/migrations/`): NOT NULL without safe default, volatile-default ADD COLUMN rewrite, drop-column/table, type changes, constraint without `NOT VALID`, `CREATE INDEX` without `CONCURRENTLY`, CONCURRENTLY-in-transaction, renames, etc. Pure filesystem/grep — issues no data-plane SQL, opens no connection — so it runs in BOTH case (a) no-connection and case (b) prod-stop, exactly like FS.1–FS.5. Token: `migrations`.
8. **`.gitignore tmp/` check** — the orchestrator preflight Step 0a.5 check (INFO if `tmp/` is not gitignored). Always-on / ungated (runs regardless of `--only`).

All eight modules are read-only and emit findings into the report even though the core SQL phases are skipped. When `--only` is set, run ONLY the modules whose governing token is present (FS.1–FS.4 `security`; FS.5 `prod`; migration-on-disk drift `schema`/`prod`; Module 13 migration-safety lint `migrations`; `.gitignore tmp/` always-on). When `--only` is unset, run all. If `--only` excludes every available filesystem module, emit `[INFO] no filesystem modules selected under --only` and still write the (ungated-`.gitignore`-check-only) report.

**When PROD and `--env=prod` was NOT passed:** run `run_filesystem_only_modules` (the canonical set above, honoring `--only` — including FS.5 env-drift when the `prod` token is present), then STOP before opening ANY `psql` core session / `execute_sql` / `run_sql`. The mechanical `BEGIN READ ONLY` wrapper (rule 6) does NOT lift this stop — it blocks writes, not prod reads.

### supabase — branch-shape ladder

Call the provider's branch-listing metadata tool. Capture raw response shape for the report Meta section.

Evaluate signals in order:

- **Signal A:** branch list returns empty → no branching → **TREAT AS PROD**
- **Signal B:** any branch record has a field matching `/parent.*ref/i` whose value equals the current ref → current is parent → **TREAT AS PROD**
- **Signal C:** any branch record has `project_ref` / `project_id` matching current ref AND a sibling `parent_project_ref` that does NOT match → **CURRENT IS A BRANCH → NOT PROD**
- **Signal D:** none of the above (unknown shape) → **TREAT AS PROD** (safe default)

If result is TREAT AS PROD and `--env=prod` was NOT passed:

```
Prod guard: this appears to be your production project (signal {A|B|D} fired).
I will not run data-plane SQL against prod without explicit confirmation.

Options:
  1. Pass --env=prod to confirm read-only audit of this project.
     (Note: --env=prod still runs SELECT-only queries; it will NOT mutate anything.)
  2. Create a dev branch first, link to it, and re-run /database-audit.

Which signal fired: {A|B|D}
```

Stop. Valid resume paths:
- User re-invokes `/database-audit --env=prod` (or with additional flags) → restart from Phase 0 with flags re-parsed.
- User replies with the exact phrase `proceed on prod` → treat as if `--env=prod` was passed and continue from Phase 0b's exit.
- Any other reply → remain stopped. Do not guess intent.

### neon — default/protected branch flags (SAFE DEFAULT)

Resolve the current connection's branch via the provider's read-only metadata tools. Emit **NOTPROD only on POSITIVE identification** that the current connection targets a non-default branch (`default == false`). If the control plane is absent (MCP not configured), the branch is indeterminate, or ANY tool errors → **PROD** (the safe default, matching vanilla). The same stop/resume prompt as above applies.

### postgres — always PROD

Vanilla Postgres has no control plane to consult, so the signal is **always PROD**. The same stop/resume prompt applies unless `--env=prod` is passed.
