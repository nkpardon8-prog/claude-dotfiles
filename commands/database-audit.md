---
description: Deep multi-provider database audit (Supabase, Neon, vanilla Postgres) — schema, RLS, security, prod-readiness, client coherence. Read-only. Refuses prod without --env=prod. Optionally emits DATABASE.md.
argument-hint: "[--provider=supabase|neon|postgres] [--only=schema,rls,security,prod,client] [--env=prod]"
expected_subagents: 4
---

# /database-audit

Runs a provider-agnostic, severity-tiered, **read-only** audit of a Postgres-backed repo (Supabase, Neon, or vanilla Postgres) and writes a redacted markdown report to `./tmp/db-audit/`. Ends with an optional `DATABASE.md` reference doc for LLM context priming. **Never mutates the DB, never commits, never runs mutating git, never echoes connection strings or secrets.**

The orchestrator is a thin sequencer. The substance lives in sub-files that it `Read`s explicitly (they are NOT auto-loaded):

- `database-audit/guards.md` — Forbidden Tools, SELECT-only 5-rule + `BEGIN READ ONLY` rule 6, the provider-dispatched prod guard, the two-phase preflight split.
- `database-audit/redaction.md` — redaction rules 1–5 (incl. connection-string redaction).
- `database-audit/core.md` — the portable `pg_catalog`/`information_schema`/`pg_stats` query library (Q1.1–Q4.2), shared by all providers.
- `database-audit/providers/<provider>.md` — the connection method, prod-guard contribution, and non-portable platform checks for the detected provider.

## Invariants (must never weaken)

These hold regardless of provider or flags — they are restated here and enforced verbatim from `guards.md`/`redaction.md`:

1. **No data-plane SQL before the prod guard resolves.** This is the single most important correctness invariant. No `psql` core session, no `execute_sql`, no `run_sql` may be dispatched until Phase 0b discharges. Metadata-only calls (`get_project_url`, `list_branches`, `describe_project`, `get_connection_string`) are permitted in Phase 0a because they touch no user data.
2. **Forbidden Tools** (`guards.md` holds the authoritative, broader explicit denylist for both Supabase and Neon mutators): never call any mutating provider tool — e.g. Supabase `apply_migration`, `deploy_edge_function`, `create_branch`, `merge_branch`, `reset_branch`, `rebase_branch`, `delete_branch`, `pause_project`, `restore_project`, `update_storage_config`; Neon `run_sql_transaction`, `prepare_database_migration`, `complete_database_migration`, `provision_neon_auth`, `provision_neon_data_api`, `create_branch`, `delete_branch`, `reset_from_parent` — any SQL execution with a non-SELECT (DML/DDL) query, or any mutating `git` command. This enumeration is illustrative; `guards.md` is the source of truth. The only permitted git subcommands are the three read-only ones actually used: `git ls-files`, `git grep`, and `git check-ignore` (tracked-file secret scan, `.env`-tracked check, gitignore coverage).
3. **SELECT-only guard** (`guards.md`, rules 1–6): fixed library only, first-keyword whitelist, full-body DML blacklist, SECURITY DEFINER caveat, and `BEGIN READ ONLY; … ROLLBACK;` mechanical wrapper on the psql path.
4. **Two separate invariants, never conflated:** (a) `BEGIN READ ONLY` blocks WRITES (DB-enforced, always on); (b) the prod guard blocks data-plane READS against prod until `--env=prod` (orchestration-enforced). A read-only transaction still reads prod PII — the guard is what stops that.
5. **Redaction** (`redaction.md`): redact secret values, mark policy expressions, never SELECT PII values (column NAMES only), emit env key NAMES only. Never echo `$DATABASE_URL` or any secret value.
6. **Graceful per-module degradation:** on any tool/SQL error in Phases 1–5, emit `[INFO] Module N — {tool} unavailable: {error}` (with `{error}` passed through the `redaction.md` rules first — it can carry connection strings/secrets) and continue. A total absence of connection source (Step 0a.6 case (a)) is NOT an abort either: run filesystem-only modules and write a partial report. Only a TRUE preflight failure aborts with no report — and that is exactly ONE case: not a DB repo at all (NONE of the Step 0a.2 signals present — no Supabase/Neon signal, no `$DATABASE_URL`, no on-disk `*.sql`/migrations/schema files). The `postgres` fallback with an empty `$DATABASE_URL` is NOT this case when any other signal (e.g. on-disk SQL) is present — that is case (a).

---

## Phase 0a — Detect + load (NO data-plane SQL)

### Step 0a.1 — Parse + validate flags (strict — no silent ignores)

Parse `$ARGUMENTS`:

- `--provider=<p>` → force provider (`supabase`, `neon`, `postgres`); skips auto-detection.
- `--only=<csv>` → run only named modules (`schema`, `rls`, `security`, `prod`, `client`).
- `--env=prod` → user explicitly confirms prod access.

Validation:

- Any flag not in `{--provider, --only, --env}` → print `"Unknown flag: <flag>. Valid: --provider=<supabase|neon|postgres>, --only=<csv>, --env=prod"` and stop.
- Any value for `--provider` other than `supabase|neon|postgres` → print `"Unknown value for --provider: <val>. Valid: supabase, neon, postgres"` and stop.
- Any module name in `--only=<csv>` not in `{schema, rls, security, prod, client}` → print `"Unknown module in --only: <name>. Valid: schema, rls, security, prod, client"` and stop.
- Any value for `--env` other than `prod` → print `"Unknown value for --env: <val>. Only --env=prod is supported"` and stop.

### Step 0a.2 — Provider auto-detection (DETERMINISTIC precedence)

If `--provider` was passed, skip detection and use it. Otherwise evaluate in this exact order — the FIRST matching rule wins:

1. **Explicit `--provider` wins** (handled above).
2. **Supabase** if ANY of:
   - `./supabase/config.toml` exists, OR
   - `package.json` contains `@supabase/supabase-js` or `@supabase/ssr`, OR
   - any `.env*` contains `SUPABASE_URL`, OR
   - `DATABASE_URL` is non-empty AND its host matches `*.supabase.co` / `*.pooler.supabase.com`.
3. **Neon** if:
   - `package.json` contains `@neondatabase/serverless`, OR
   - `DATABASE_URL` is non-empty AND its host matches `*.neon.tech`.
4. **Else `postgres`** — but ONLY if at least one database signal is present (see below). The `postgres` fallback selects the *provider* for a repo that IS a DB project but matched no Supabase/Neon signal; it does NOT mean "always proceed."

**True-preflight-failure gate (evaluated alongside detection):** Determine whether this repo is a database project at all. It IS a DB project if ANY of these signals is present:

- a Supabase signal (`./supabase/config.toml`, `@supabase/supabase-js` / `@supabase/ssr` dep, any `.env*` with `SUPABASE_URL`), OR
- a Neon signal (`@neondatabase/serverless` dep), OR
- a non-empty `$DATABASE_URL` (any host), OR
- any database artifact on disk: `*.sql` files, a migrations directory (`./supabase/migrations/`, `./migrations/`, `./db/migrations/`, `./drizzle/`, `./prisma/migrations/`), or a schema file (`schema.sql`, `schema.prisma`, `drizzle` schema).

If **NONE** of these signals is present, this is the ONLY **true preflight failure**: print `"This repo doesn't appear to use a database (no Supabase/Neon/Postgres signal, no DATABASE_URL, no SQL/migration/schema files). Aborted — nothing to audit."` and **stop with no report** (mirrors `/supabase-audit` Step 0.2 abort). The `postgres` fallback in rule 4 is reached only when a signal IS present but it is not Supabase/Neon (e.g. a bare `$DATABASE_URL`, or only on-disk SQL/migrations). A repo with on-disk SQL but no reachable connection is a DB project → it proceeds to the filesystem-only path (case (a)), NOT this abort.

Determinism rules (do NOT deviate):

- **`DATABASE_URL` host-match fires ONLY when the var is non-empty AND matches a known host regex.** An empty or unset `DATABASE_URL` must NEVER auto-match a host — it falls through to the next rule.
- **Dual-driver tiebreak:** because Supabase (rule 2) is evaluated before Neon (rule 3), a repo with BOTH a Supabase signal (`config.toml` / `SUPABASE_URL`) AND a bare `@neondatabase/serverless` dep resolves to **Supabase** — Supabase signals win over a bare Neon dep. This preserves parity with the proven `/supabase-audit` Step 0.2 so a Supabase repo never silently degrades to `postgres`.

Record which signal selected the provider (for the report Meta section).

### Step 0a.3 — Explicit Read order of sub-files (NOT auto-loaded)

`Read` the sub-files in THIS order — guard before core is a hard precondition:

1. `Read ~/.claude-dotfiles/commands/database-audit/guards.md`
2. `Read ~/.claude-dotfiles/commands/database-audit/redaction.md`
3. `Read ~/.claude-dotfiles/commands/database-audit/core.md`
4. `Read ~/.claude-dotfiles/commands/database-audit/providers/<detected>.md`

Then echo a preflight line:

```
preflight loaded (provider=<provider>, signal=<which detection signal fired>) + guard pending
```

**HARD precondition:** `guards.md` must be loaded AND the prod guard (Phase 0b) must be resolved BEFORE any `core.md` query is dispatched. If this echo line has not printed, no SQL phase may begin.

### Step 0a.4 — Resolve connection SOURCE (metadata-only; do NOT open a core session)

Resolve per the detected provider's `(a) Connection` section — metadata-only calls are allowed here, but do NOT open a core SQL session yet:

- **supabase** → Supabase MCP. Call `mcp__supabase__get_project_url`. On success, parse project ref. On error → this is **no-connection-source case (a)** (see below): the Supabase adapter has no `psql` fallback, so an unreachable MCP means there is no connection source at all. Do NOT hard-abort. Emit `[INFO] No DB connection/MCP available — SQL + platform modules skipped; filesystem checks only` (include the redacted MCP error text), record `Connection source: none` in Meta, then run the **filesystem-only path** (Step 0a.6) and skip Phases 0b–5 SQL.
- **neon** → connection SOURCE precedence (from `providers/neon.md`): explicit `$DATABASE_URL` (non-empty) → else `get_connection_string` via Neon MCP (read-only, **DIRECT** non-pooler host) → else **no-connection-source case (a)** (no DATABASE_URL and no MCP connstring): filesystem-only path (Step 0a.6). If Neon MCP is configured, put it in read-only mode (`?readonly=true` on the server URL, header `x-read-only` fallback) and note which mechanism in Meta.
- **postgres** → explicit `$DATABASE_URL` only; if empty/unset → **no-connection-source case (a)**: filesystem-only path (Step 0a.6).

**NEVER echo the resolved connection string** (redaction rule 4). It is used only as the `psql`/`run_sql` target.

### Step 0a.5 — Report directory + .gitignore check (runs BEFORE any report-writing path)

**Ordering invariant:** this step MUST complete BEFORE any code path that writes a report — including the Step 0a.6 case-(a) filesystem-only partial report, the Phase 0b prod-stop partial report, and the Phase 6 full report. It runs here in Phase 0a preflight, before the detection branches fan out into those write paths, so the report directory always exists first. Any path that writes a report must treat "report directory exists (or its sanctioned fallback is selected)" as a precondition — re-ensure it (idempotent `mkdir -p`) if entering a write path directly.

- Create `./tmp/db-audit/` if absent (idempotent `mkdir -p`). If `./tmp/` is not writable, fall back to the per-run file `$(pwd)/db-audit-YYYY-MM-DD-HHmm.md` (this fallback path is the sanctioned write-location exception in `guards.md` Forbidden Tools). Never write to `$HOME`.
- **Store the resolved write location in named variables that every report-writing path (Step 0a.6, Phase 0b prod-stop, Phase 6) MUST reference — do NOT hardcode `./tmp/db-audit/` downstream:**
  - **Normal case (`./tmp/` writable):** set `REPORT_DIR=./tmp/db-audit`. The timestamped report is `$REPORT_DIR/<ts>.md` (where `<ts>` is `YYYY-MM-DD-HHmm`) and the rolling copy is `$REPORT_DIR/latest.md`.
  - **Fallback case (`./tmp/` NOT writable):** there is no directory to host a `latest.md`; set `REPORT_FILE=$(pwd)/db-audit-<ts>.md` and `REPORT_DIR=$(pwd)`. The `latest.md` copy is SKIPPED in this case (a single per-run file in `$(pwd)` is the sanctioned exception; do not create additional files there). Record this in Meta as the resolved report path.
  - In the normal case also set `REPORT_FILE=$REPORT_DIR/<ts>.md` for a uniform reference. Phase 6 always writes `REPORT_FILE`, and writes `$REPORT_DIR/latest.md` ONLY when `./tmp/` was writable.
- Read `.gitignore`. If `tmp/` is not covered → emit INFO finding: ".gitignore does not cover tmp/ — audit reports may be committed accidentally." (zero-data-touch — recorded for Meta + Info section.)

### Step 0a.6 — No-connection-source path (graceful degradation case (a))

This path fires whenever Step 0a.4 found **no usable connection source at all** for the detected provider:

- **supabase** → `mcp__supabase__get_project_url` errored (no `psql` fallback exists for this adapter).
- **neon** → no `$DATABASE_URL` AND no `get_connection_string` from Neon MCP.
- **postgres** → no `$DATABASE_URL`.

Because there is **no connection, there is no prod-data risk** — so this is NOT a prod-stop, and it is NOT a hard abort. Instead:

0. **Ensure the report directory first.** Re-ensure Step 0a.5 ran (idempotent `mkdir -p ./tmp/db-audit/`, or the sanctioned `$(pwd)/db-audit-…md` fallback if `./tmp/` is unwritable) AND that the `REPORT_DIR` / `REPORT_FILE` variables are resolved. The partial report MUST NOT write to a non-existent dir — this path can be entered directly from detection, so do not assume Step 0a.5 already created it; re-ensure here, then write the partial report to `REPORT_FILE` (Phase 6 step 6 rules apply).
1. Emit the finding `[INFO] No DB connection/MCP available — SQL + platform modules skipped; filesystem checks only`. If a tool error string is being surfaced, pass it through the `redaction.md` rules first (scrub connection strings / secret-shaped tokens) before writing or printing it.
2. Do NOT enter Phase 0b (the prod guard needs no resolution — there is nothing to read).
3. Run the zero-data-touch filesystem modules via `guards.md` `run_filesystem_only_modules` — **honoring `--only`** (see the `--only` rule below). This is the SAME canonical filesystem-only set used by the Phase 0b prod-stop path, defined once in `guards.md` ("Filesystem-only module set (THE canonical rule)"): `core.md` Module FS (FS.1 repo secret scan, FS.2 tracked-files scan, FS.3 `.env`-tracked check, FS.4 seed-data check — all `security`-gated; FS.5 env-drift — `prod`-gated), migration-on-disk drift (`schema`/`prod`-gated), and the Step 0a.5 `.gitignore tmp/` check (always-on/ungated). These touch no DB.
4. Proceed to Phase 6 report assembly and **write the partial report**, then exit cleanly. Record `Connection source: none` and `Modules skipped: <all SQL + platform modules; plus any FS modules excluded by --only>` in Meta.

**`--only` in this filesystem-only path (REQUIRED — do not run all unconditionally):** When `--only` is set, run ONLY the filesystem modules whose governing `--only` token is present:

- FS.1–FS.4 are gated on `security`.
- FS.5 (env-drift) is gated on `prod`.
- migration-on-disk drift is gated on `schema` OR `prod` (either token enables it).
- the `.gitignore tmp/` check is always-on / ungated (it runs regardless of `--only`).

If `--only` is set and excludes **every** available filesystem module (e.g. `--only=client` or `--only=rls`), emit `[INFO] no filesystem modules selected under --only` and still write the (near-empty, ungated-`.gitignore`-check-only) report. When `--only` is unset, run all filesystem modules (current behavior).

This is distinct from the Phase 0b prod-stop (case (b)): there a connection EXISTS but prod is unconfirmed, so filesystem-only modules run and we STOP pending `--env=prod`. Here there is no connection, so we run filesystem-only modules and EXIT with a complete partial report (no stop, no resume prompt).

**True-preflight-failure vs case (a) — stated once, no contradiction:** The case-(a) path here is for a repo that IS a DB project (some signal present per the Step 0a.2 true-preflight-failure gate) but has **no reachable connection/MCP**. That is ALWAYS a clean filesystem-only partial report — NEVER a bare abort. The ONLY abort-with-no-report case is the Step 0a.2 true preflight failure: **NONE** of the DB signals present (no Supabase/Neon signal, no `$DATABASE_URL`, no on-disk `*.sql`/migrations/schema files). That abort is decided in Step 0a.2 and never reached here — by the time Step 0a.6 runs, at least one signal exists, so the empty-`DATABASE_URL`-on-`postgres` situation is case (a) (filesystem-only report), not an abort.

---

## Phase 0b — Prod guard (resolves BEFORE any data-plane SQL)

**Only reached when a connection source WAS resolved in Step 0a.4 (case (b) territory).** If Step 0a.6 (no-connection-source case (a)) fired, skip this phase entirely — there is no connection to guard and the report has already been assembled from filesystem-only modules.

Invoke the **generalized provider-dispatched prod guard** from `guards.md`, dispatching to the detected provider's signal function:

- **supabase** → the A/B/C/D branch-shape ladder (`providers/supabase.md` `supabase_branch_ladder()`, via the metadata-only `mcp__supabase__list_branches`). Capture the raw branch-list shape for Meta.
- **neon** → `neon_current_is_nondefault_branch_positively()` (`providers/neon.md`, via metadata-only `describe_project`). NOTPROD only on positive non-default identification; MCP absent / indeterminate / any error ⇒ PROD (safe default).
- **postgres** → always PROD (no control plane).

**If PROD and `--env=prod` was NOT passed (case (b) — connection present but prod unconfirmed):** first re-ensure the report directory exists (Step 0a.5 / `mkdir -p ./tmp/db-audit/` or the sanctioned fallback — the partial report must never write to a non-existent dir) AND that `REPORT_DIR` / `REPORT_FILE` are resolved (the partial report is written to `REPORT_FILE` per Phase 6 step 6 rules). Then print the `guards.md` stop/resume prompt (with the fired signal), run the zero-data-touch modules via `guards.md` `run_filesystem_only_modules` — the SAME canonical filesystem-only set as Step 0a.6, defined once in `guards.md` ("Filesystem-only module set (THE canonical rule)") and **honoring `--only` exactly as in Step 0a.6** (FS.1–FS.4 `security`-gated, **FS.5 env-drift `prod`-gated and INCLUDED in this prod-stop path** since it is zero-data-touch, migration-on-disk drift `schema`/`prod`-gated, `.gitignore tmp/` check always-on/ungated; if `--only` excludes every available FS module, emit `[INFO] no filesystem modules selected under --only`; when `--only` is unset, run all) — then **STOP before opening ANY core SQL session / `execute_sql` / `run_sql`.** Do not proceed to Phases 1–5 SQL. Honor the documented resume paths (`--env=prod` re-invoke, or the exact phrase `proceed on prod`). (Contrast with case (a) in Step 0a.6: there NO connection exists, so we do not stop — we write the partial report and exit cleanly.)

Once the guard discharges (NOTPROD, or `--env=prod`/`proceed on prod` confirmed), echo the resolved-state line — it MUST explicitly carry the resolved provider, the fired prod-signal, and `guards loaded`:

```
preflight loaded + guard resolved (provider=<provider>, prod-signal=<which signal fired>, guards loaded) — beginning SQL phases
```

**Checkable precondition (assertion, not just prose):** Before dispatching any **DATA-PLANE SQL** (`psql` core session / `execute_sql` / `run_sql`), confirm this exact resolved-state line was emitted with all three fields populated. If it was not emitted, **halt** — do not issue any data-plane query. Metadata-only control-plane calls (`get_project_url`, `list_branches`, `describe_project`, `get_connection_string`) are EXPLICITLY PERMITTED in Phase 0a precisely to resolve the guard — they touch no user data, so they run BEFORE the resolved-state line. The bar is: **no data-plane SQL before the resolved-state line** (not "no control-plane probe" — the guard could not resolve without those metadata calls).

---

## Phases 1–4 — Core + platform modules

Honor `--only` throughout (skip a module if `--only` is set and does not include its name). Apply graceful per-module degradation: on any tool/SQL error emit `[INFO] Module N — {tool} unavailable: {error}` and continue — only preflight aborts.

**Pre-redaction of `{error}` (mandatory):** the raw `{error}` text from a failed tool/SQL call can contain connection details (a `postgres://…` URI, a host, or a secret-shaped token). Before this `[INFO] Module N — {tool} unavailable: {error}` finding is written or printed, pass `{error}` through the `redaction.md` rules (especially rule 5 connection-string redaction and rule 1 secret-value redaction). The same applies to the Step 0a.6 / case-(a) `[INFO] No DB connection/MCP available …` finding when it carries an MCP error string. Never let an unredacted error string reach the report or stdout.

### Core (portable, all providers — `core.md`)

Dispatch the `core.md` fixed-library queries, gated behind the discharged guard, via:

- **psql path (PREFERRED whenever a direct connection exists)** (neon / postgres, and neon when `get_connection_string` resolved a direct host): wrap in `BEGIN READ ONLY; … ROLLBACK;` (`guards.md` rule 6) so read-only is DB-ENFORCED, run with `psql "$DATABASE_URL" -v ON_ERROR_STOP=1` (or libpq `PG*` env / `~/.pgpass` on a shared host — see `guards.md` rule 6 credential-exposure note).
- **MCP path (FALLBACK — only when no direct connection exists)** (supabase via `mcp__supabase__execute_sql`; neon via `run_sql` when no `$DATABASE_URL`/connstring): SELECT-only per the guard. Read-only here is NOT DB-enforced — it relies on the fixed-library + textual guard (rules 1–4), so the fixed-library discipline is load-bearing on this path (`guards.md` rule 6).

**Per-module dispatch (one query error must NOT abort the batch — `guards.md` rule 6).** Dispatch the core library **per module (or per query)**, each in its own `BEGIN READ ONLY; … ROLLBACK;` invocation, so `ON_ERROR_STOP=1` scopes to a single invocation. A single failing query is logged `[INFO] Module N — {tool} unavailable: {error}` (pre-redacted) and the REST CONTINUE — never run the whole library as one all-or-nothing `ON_ERROR_STOP=1` batch, which would abort remaining queries on one error and violate the graceful per-module degradation contract (Invariant 6). This per-module isolation also aligns with `--only` gating, and applies on the MCP fallback path too.

Run, honoring `--only`:

- **Module 1 — Schema** (`schema`): Q1.1–Q1.8 + migration drift (applied-migrations list supplied by the provider adapter).
- **Module 2 — RLS** (`rls`): Q2.1–Q2.5. RLS-off severity is CONTEXT-DEPENDENT — the provider adapter sets the final severity (Supabase/Neon-Data-API → CRITICAL; vanilla → HIGH).
- **Module 3 — Security, portable subset** (`security`): Q3.1 (PII inventory), Q3.3 (dynamic SQL).
- **Module 4 — Production Readiness, portable subset** (`prod`): Q4.1 (version, against the provider's supported-major list), Q4.2 (connection saturation).
- **Module FS — Filesystem security** (zero-data-touch, provider-agnostic): FS.1 repo secret scan, FS.2 tracked-files secret scan, FS.3 `.env`-tracked check, FS.4 seed-data check (all gated `security`); FS.5 env-drift check (gated `prod`). All of these (FS.1–FS.5) also run in BOTH the no-connection case (a) and the prod-stop path via `run_filesystem_only_modules` — the canonical filesystem-only set defined once in `guards.md` (see Phase 0b / Step 0a.6). FS.5 is included there because it is zero-data-touch.

### Platform modules (provider-specific — `providers/<provider>.md`)

**`--only` GATES platform modules exactly like core modules.** Each platform check has a governing `--only` token; when `--only` is set and does NOT include a check's token, that check is **SKIPPED and issues NO SQL / no `execute_sql` / no `run_sql` / no control-plane probe for it** (so e.g. `--only=rls` never fires Supabase `storage.buckets`, the `pg_cron` probe, `pg_publication_tables`, or `get_advisors`). When `--only` is unset, all platform checks run (current behavior). The governing-token mapping (platform modules in `providers/supabase.md` and `providers/neon.md` are each annotated with their token):

- **`security`** → Supabase `get_advisors({type:"security"})`, risky extensions, pg_cron probe + inventory, the portable dynamic-SQL/secret scans' Supabase platform steps, Supabase Q3.x advisor-severity mapping; Neon Data-API-enabled probe + `neon_auth` / `pg_session_jwt` RLS checks.
- **`prod`** → Supabase `get_advisors({type:"performance"})`, version (supported-major list), connection saturation, slow-query log (`get_logs`), pooler-port grep, manual checks (SMTP/MFA/PITR/webhooks); Neon scale-to-zero, autoscaling, compute-vs-max_connections, pooling, IP allowlist, protected/sprawl/restore-window.
- **`rls`** → RLS-off severity escalation, anon / Data-API classification — so `--only=rls` STILL runs the Data-API-enabled control-plane probe that feeds `neon.md`'s Q2.1→CRITICAL escalation (this fixes the prior coupling where the escalation input was gated out).
- **`client`** → storage buckets, edge functions, realtime publications, Module 5 client coherence, `generate_typescript_types` diff.

A platform module whose governing token is NOT present in `--only` is **SKIPPED — no SQL is issued for it.**

Then run the detected provider's platform modules (each gated by its token above):

- **supabase** → security/performance advisors (`get_advisors`), anon/RLS classification + RLS-off→CRITICAL escalation, risky extensions (`list_extensions`), pg_cron inventory, slow-query log (`get_logs`), pooler-port grep, migration drift (`list_migrations`), manual checks (SMTP/MFA/PITR/webhooks), storage buckets, edge functions, realtime publications. (Seed-data and env-drift checks are NOT Supabase-platform checks — they are provider-agnostic filesystem checks in `core.md` Module FS, FS.4 / FS.5.)
- **neon** → control-plane checks (scale-to-zero, autoscaling, compute-vs-max_connections, pooling, IP allowlist, protected branches + "prod branch not protected", branch sprawl, restore window), slow queries (`list_slow_queries`), Neon Auth / `pg_session_jwt` RLS classification, Data-API RLS-or-bust escalation. **SKIP-with-INFO each control-plane check if Neon MCP is absent — the psql core still runs; do NOT abort.**
- **postgres** → NONE. Emit INFO-N/A for advisors / storage / edge / realtime / autoscaling per `providers/postgres.md`.

---

## Phase 5 — Client coherence (sub-agent)

Skip if `--only` is set and does not include `client`.

**Scratch-file write-location rule (write-allowlist compliance).** Module 5's `.client-scan.md` scratch file is written under the **RESOLVED report location** — the same `$REPORT_DIR` variable Step 0a.5 set and Phase 6 uses — NOT a hardcoded `./tmp/db-audit/`. Concretely:

- **Normal case (`./tmp/` writable, `REPORT_DIR=./tmp/db-audit`):** the sub-agent writes `$REPORT_DIR/.client-scan.md` (i.e. `./tmp/db-audit/.client-scan.md`). Substitute the resolved `$REPORT_DIR` into the embedded sub-agent prompt before dispatching — do NOT pass a literal `./tmp/db-audit/` if `REPORT_DIR` resolved elsewhere.
- **Fallback case (`./tmp/` NOT writable, `REPORT_DIR=$(pwd)`):** the only sanctioned write in this mode is the single `$(pwd)/db-audit-<ts>.md` report (Step 0a.5 / `guards.md` Forbidden Tools). A scratch `.client-scan.md` would violate that write allowlist, so **SKIP Module 5 client-coherence entirely** and emit `[INFO] Module 5 skipped — no writable tmp/ for the client-scan scratch file`. Do not spawn the sub-agent in this case.

- **supabase** (only when `REPORT_DIR` is a writable `./tmp/` location per the rule above) → spawn the Module-5 client-coherence sub-agent. **The sub-agent prompt MUST be embedded VERBATIM into the `Agent` call** — a spawned sub-agent does NOT inherit the orchestrator's Read'd files, so the contract from `providers/supabase.md` "Sub-agent contract — embed this block verbatim" must be passed as literal prompt text (do not reference the provider file from inside the sub-agent). Embed this exact block as the Agent prompt (substituting the resolved `$REPORT_DIR` for the write path):

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

  Then perform the main-skill consumption (cross-reference) per `providers/supabase.md` "Main-skill consumption" steps 1–7 (table/rpc/channel/bucket/column existence, service_role-in-client → CRITICAL, anon-singleton → LOW, truncation → MEDIUM, `generate_typescript_types` diff → MEDIUM per drifted file). On any MCP error emit `[INFO] Module 5 — {tool} unavailable: {error}` and continue.

- **neon / postgres** → emit `[INFO] Module 5 — no JS Supabase client; client-coherence N/A on <provider>.` and the `[INFO] generate_typescript_types N/A on <provider>.` note. Do not spawn the sub-agent.

---

## Phase 6 — Report assembly

1. Collect all findings from Modules 1–5 into a list.
2. Apply the redaction pass (`redaction.md` rules 1–5) BEFORE writing anything to disk.
3. **Deduplicate** findings by `(severity, title, object_name)` BEFORE the sort — identical migration-drift findings emitted by both core Module 1 (`core.md` Migration drift) and the Supabase platform migration-drift module collapse to a single finding.
4. Sort: **severity DESC → module → object_name ASC** (deterministic).
5. Render markdown. The title is **provider-templated**:

```
# Database Audit — <provider> — <host>

- Generated: <ISO timestamp>
- Provider: <supabase | neon | postgres>
- Connection host: <host — never the full connection string / secrets>
- Prod signal: <which prod-signal fired + why (e.g. supabase Signal A / neon default==true / postgres always-PROD)>
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
- Provider: <provider>
- Which prod-signal fired: <signal + provider-specific reason>
- .gitignore covers tmp/: OK | MISSING
- Connection source: <DATABASE_URL | Supabase MCP | Neon get_connection_string (direct) | none> (NEVER the value)
- Neon read-only mechanism (neon only): <?readonly=true | x-read-only header | N/A>
- Modules skipped: <list or "none">
- Sub-agent truncation: <none | reason>
- Provider metadata raw shape: <captured branch/project response for debugging — redacted>
```

6. Write to the resolved `REPORT_FILE` from Step 0a.5 (`$REPORT_DIR/<ts>.md` in the normal case, or the `$(pwd)/db-audit-<ts>.md` fallback when `./tmp/` was unwritable). **Do NOT hardcode `./tmp/db-audit/` here — honor the resolved variable so the fallback path is actually used.**
7. Copy to `$REPORT_DIR/latest.md` ONLY in the normal (`./tmp/` writable) case. In the fallback case there is no `REPORT_DIR` to host a rolling copy, so SKIP the `latest.md` copy (the single `$(pwd)/db-audit-<ts>.md` file is the sole sanctioned write).
8. Print a one-screen summary with finding counts per severity and the resolved report path (`REPORT_FILE`).

---

## Phase 7 — DATABASE.md offer

Prompt the user:

```
Generate a persistent DATABASE.md reference doc at <chosen_path>?
This file is committable (by you, not by me) and helps future LLM sessions
work from a cached schema snapshot instead of re-introspecting. (y/n)
```

Path selection: `./docs/` exists → `./docs/DATABASE.md`; else `./documentation/` → `./documentation/DATABASE.md`; else `./DATABASE.md`.

### Foreign-file guard

If the target file exists, read its first two lines. If line 1 does NOT start with `_Generated by /database-audit on `:

```
<path> exists and was not generated by this skill. Its content will be replaced.
Type the path again to confirm, or 'cancel':
```

Overwrite only on exact path re-entry. If line 1 matches the marker, overwrite silently.

### DATABASE.md content spec (provider-conditionalized)

```
_Generated by /database-audit on <ISO date>. Regenerate to update. DO NOT HAND-EDIT._
<provider> | <project ref or host> | Postgres <version>

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

## Edge Functions          ← Supabase-only — emit only when provider=supabase
(name | slug | deployed version — from list_edge_functions)

## Storage Buckets         ← Supabase-only — emit only when provider=supabase
(name | public | has_policies)

## Auth Providers Enabled  ← Supabase-only — emit only when provider=supabase
```

**Provider conditionalization:** the `## Edge Functions`, `## Storage Buckets`, and `## Auth Providers Enabled` sections are **Supabase-only**. Emit them as populated tables ONLY when `provider=supabase`. For neon/postgres, render each as `_N/A — not applicable to <provider>._` (or omit per the provider file's guidance) — never as an empty populated table.

Line 1 is always the generator marker — this is what the foreign-file guard checks on future runs.

### Redaction pass (MANDATORY — DATABASE.md is a committable file)

**Before writing DATABASE.md, run the full redaction pass (`redaction.md` rules 1–5) over its ENTIRE content.** DATABASE.md embeds RLS policy `qual` / `with_check` expressions and function COMMENTs, both of which can carry secret-shaped tokens, hardcoded credentials, or sensitive logic — and unlike the audit report (which lives in gitignored `./tmp/`), DATABASE.md is intended to be committed. The redaction step is therefore load-bearing here, not optional.

- Apply rules 1–5 to the whole document, with particular attention to the `## RLS Policies` `qual` / `with_check` columns and the `## Functions` COMMENT text.
- Prefix any section that contains policy logic (the `## RLS Policies` section, and any function COMMENT that embeds policy/authorization logic) with the redaction.md "contains policy logic — handle like source code" warning line, so a reader treats those expressions as source code rather than safe-to-share documentation.
- Never write DATABASE.md before this pass completes.
