# database-audit — Neon Provider Adapter

This file is `Read` by the `/database-audit` orchestrator **only when the detected/forced provider is `neon`**. It declares (a) the Neon connection method, (b) Neon's contribution to the generalized prod-guard signal in `guards.md`, and (c) ONLY the Neon-specific (non-portable) checks.

**Single source of truth:** the portable `pg_catalog`/`information_schema`/`pg_stats` queries (Q1.1–Q4.2) live in `core.md` and are NOT repeated here. This file references them by ID only.

**Neon has NO `get_advisors` analogue.** The portable `core.md` SQL library fills that gap — schema/RLS/secdef/dynsql/PII findings come entirely from the core queries, not from a platform advisor.

---

## (a) Connection

Neon is audited through **two surfaces** that degrade independently:

1. **Data plane (portable core).** The `core.md` queries run over the universal `psql` path wrapped in `BEGIN READ ONLY; … ROLLBACK;` (see `guards.md` rule 6), OR via the Neon MCP `run_sql` read-only tool.
2. **Control plane (Neon-only platform checks).** Neon's autoscaling / pooling / IP-allowlist / branch metadata is API/MCP-only — there is no SQL for it. When Neon MCP is **absent**, every control-plane check below **SKIPs with an INFO** ("Neon control-plane check unavailable — Neon MCP not configured") and the psql core still runs. Do NOT abort.

### Neon MCP — READ-ONLY mode

When Neon MCP is configured, it MUST be put in read-only mode for this audit:

- **Primary:** append `?readonly=true` to the Neon MCP **server URL**.
- **Fallback:** set the header `x-read-only` on the MCP server connection.

Document which mechanism is in effect in the report Meta section. (Read-only mode is belt-and-suspenders alongside the SELECT-only guard and `BEGIN READ ONLY` wrapper.)

### Neon MCP tool names

| Purpose | Tool |
|---------|------|
| SELECT-only SQL dispatch | `run_sql` |
| Project metadata (branches, flags) | `describe_project` |
| Single-branch detail | `describe_branch` |
| Compute inventory per branch | `list_branch_computes` |
| Schema diff between branches | `compare_database_schema` |
| Connection string (pooled/direct) | `get_connection_string` |
| Slow queries | `list_slow_queries` |
| Query plan | `explain_sql_statement` |

**There is NO `list_branches` tool** — branch discovery is via `describe_project` (which returns the branch list with flags). **There is NO `list_extensions` tool** — extension inventory is via a vetted portable SELECT against `pg_extension` (run through `run_sql` / psql). Mutating control-plane tools (create/merge/reset/rebase/delete branch, apply migration) are Forbidden (`guards.md`).

**FORBIDDEN Neon MCP tools (read-only audit — NEVER call any of these):** `run_sql_transaction`, `prepare_database_migration`, `complete_database_migration`, `provision_neon_auth`, `provision_neon_data_api`, `create_branch`, `delete_branch`, `reset_from_parent`. These mutate the database or control plane and have no place in a read-only audit. This list is in addition to the `guards.md` Forbidden Tools denylist.

**Namespaced tool identifiers.** Neon MCP tool identifiers may be namespaced depending on the connected server (e.g. `mcp__neon__run_sql` rather than bare `run_sql`). Use whatever identifier the connected Neon MCP exposes for the read-only tools (`run_sql`, `describe_project`, `describe_branch`, `get_connection_string`, `list_slow_queries`), and apply the same SELECT-only + forbidden-tool discipline regardless of namespacing.

### Connection SOURCE precedence (for the psql core)

Resolve in this exact order (Phase 0a — metadata only, do NOT open a core SQL session yet):

1. Explicit `$DATABASE_URL` (non-empty) → use it. **Pooler-host caveat:** if the explicit `$DATABASE_URL` host contains `-pooler` (a Neon PgBouncer transaction-mode endpoint), emit an `[INFO]` warning — pooled transaction-mode connections are unreliable for the multi-statement `BEGIN READ ONLY; … ROLLBACK;` heredoc the core path uses. When Neon MCP is available, prefer `get_connection_string` for the **DIRECT** (non-pooler) host for the core read-only transaction. If only the pooler URL is available (no MCP / no direct host), dispatch the core queries **per-statement** (NOT a multi-statement heredoc) to avoid PgBouncer transaction-mode issues. (Never echo the URL — redaction rule 4; the `-pooler` substring detection is on the host portion only.)
2. Else `get_connection_string` via Neon MCP — request the **read-only, DIRECT (non-pooler) host**. (The `-pooler` host is PgBouncer transaction mode; `BEGIN READ ONLY` heredoc semantics are most reliable on the direct host.)
3. Else **no-connection-source case (a)** — neither `$DATABASE_URL` nor a Neon MCP connstring is available. There is no connection, so no prod-data risk: this is NOT a prod-stop and NOT an abort. Hand off to the orchestrator's **Step 0a.6 no-connection-source path** — emit `[INFO] No DB connection/MCP available — SQL + platform modules skipped; filesystem checks only` (the historical `No connection source — set $DATABASE_URL or configure Neon MCP. Core SQL skipped.` note may accompany it), run ONLY the zero-data-touch filesystem modules, assemble the partial report, and exit cleanly. Do NOT enter Phase 0b. Record `Connection source: none` in Meta.

**NEVER echo the connection string** (redaction rule 4 — key NAMES only, never values). The resolved string is used only as the `psql`/`run_sql` target; it is never printed, logged, or written to the report.

### Preflight detection (Phase 0a)

Provider is `neon` when: `@neondatabase/serverless` is in `package.json` OR `DATABASE_URL` host matches `*.neon.tech`. (Explicit `--provider=neon` wins. Supabase signals beat a bare `@neondatabase/serverless` dep — see orchestrator precedence.)

---

## (b) Prod-guard contribution — SAFE DEFAULT

The **generalized** prod guard lives in `guards.md`. This file supplies the Neon signal function it dispatches to.

**Branch-flag model (verified):**
- Prod branch = the branch where `default == true`.
- The root branch additionally has `primary == true`.
- `protected` is a **separate** flag (not the same as default/primary).

```
neon_current_is_nondefault_branch_positively():
  Returns true ONLY on POSITIVE identification that the current connection
  targets a NON-default branch.
    - Call describe_project (metadata-only — touches no user data).
    - Map the current connection (from get_connection_string / $DATABASE_URL host)
      to its branch.
    - If that branch's `default == false` (positively identified) → return true (NOTPROD).
    - MCP absent / branch indeterminate / connection-to-branch mapping fails /
      ANY tool error → return false ⇒ guard resolves PROD (the safe default,
      matching vanilla).
```

So the guard yields **NOTPROD only on positive non-default identification**; everything uncertain ⇒ **PROD**. The stop/resume prompt (including the `proceed on prod` resume phrase) lives in `guards.md`.

**Additional finding:** if the `default == true` branch lacks `protected == true`, surface a finding: **"prod branch not protected"** (HIGH) — Neon's protected-branch flag guards the prod branch against accidental deletion/reset.

---

## (c) Neon-only platform checks

All control-plane checks below are **API/MCP-only** (no SQL). If Neon MCP is absent → each SKIPs-with-INFO; the psql core still runs.

**`--only` gating applies to every platform check below** (see `database-audit.md` Platform-modules mapping). Each section is annotated with its governing `--only` token. If `--only` is set and does NOT include that token, the section is SKIPPED and issues NO control-plane probe / `run_sql` for it. When `--only` is unset, all run. Note the Data-API-enabled probe is gated by **`rls`** (not `prod`) precisely so `--only=rls` still gathers the input that feeds the Q2.1→CRITICAL escalation.

### Control-plane (from `describe_project` / `describe_branch` / `list_branch_computes` / `get_connection_string`)

`--only` token: **`prod`** (scale-to-zero, autoscaling, compute-vs-max_connections, pooling, IP allowlist, protected branches, branch sprawl, restore window).

- **Scale-to-zero.** `suspend_timeout_seconds` per compute. Note the configured value; very low values on a prod branch can cause cold-start latency → INFO inventory (Severity-if-absent: N/A — informational).
- **Autoscaling.** `autoscaling_limit_min_cu` / `autoscaling_limit_max_cu`. If min == max (no autoscaling headroom) on a prod branch → MEDIUM. Report the min/max CU range in the body.
- **Compute size vs max_connections.** Cross-reference the compute size (CU) against the portable Q4.2 `max_connections` result — Neon derives `max_connections` from compute size; a small compute with a serverless/high-fanout app is a saturation risk → MEDIUM.
- **Connection pooling.** Determine whether the app uses the `-pooler` host (PgBouncer transaction mode) or the direct host. Serverless/edge runtimes SHOULD use the pooler; long-lived servers may use direct. Flag a mismatch as MEDIUM with the appropriate direction.
- **IP allowlist.** `allowed_ips`. Default `0.0.0.0` (or empty allowlist) = open to all IPs → HIGH on a prod branch. Report the policy, never the specific allowed addresses verbatim if they look sensitive.
- **Protected branches.** Already surfaced in the prod-guard contribution ("prod branch not protected"). Also inventory which branches are protected → INFO.
- **Branch sprawl / stale branches.** Count branches and flag long-lived non-default branches (cost driver AND data-exfiltration surface — each branch is a full copy-on-write fork of prod data). Many stale branches → MEDIUM (cost + exfil risk). Report count + oldest stale branch age.
- **Restore / history window.** The configured history-retention / point-in-time-restore window (`history_retention_seconds` or plan equivalent). Very short window on a prod branch → MEDIUM (limited recovery). Inventory as INFO otherwise.

### Slow queries (control-plane)

`--only` token: **`prod`**.

Call `list_slow_queries` (Neon's equivalent of the Supabase slow-query log). Each entry exceeding the threshold → MEDIUM. **Redaction:** logged query text can embed tokens, connection strings, and literal PII. Prefer reporting the query SHAPE/fingerprint over raw text; if raw text is included it MUST first be passed through the redaction pass (`redaction.md` rules 1–5) and truncated/summarized — never report a raw slow-query body. SKIP-with-INFO if MCP absent.

### Supported Postgres version (supplied to portable Q4.1)

Neon supported major versions: `['14', '15', '16', '17', '18']`. List last updated: `2026-05`. Review this list against the provider's version calendar periodically; EOL majors removed (PG13 EOL 2025-11), new GA majors added (PG18 GA 2025) — without `'18'` a PG18 branch would FALSELY emit the HIGH "unsupported version" finding. Major version not in this list → HIGH (passed to the portable Q4.1 check in `core.md`). EOL staleness: if today is more than 18 months after `2026-05` → INFO "Neon Postgres version data may be stale; verify at neon.com/docs."

### Neon-only SQL-checkable (via `run_sql` / psql — vetted SELECTs, gated behind the prod guard)

`--only` tokens (per check): **Neon Auth + Neon RLS (`pg_session_jwt`) → `security`**; **Neon Data API enabled-probe → `rls`** (so `--only=rls` still issues the Data-API probe feeding the Q2.1→CRITICAL escalation). If the governing token is absent from `--only`, that check issues no SELECT.

- **Neon Auth.** If a `neon_auth` schema exists (Neon Auth syncs user records there), inventory it → INFO. Tables under `neon_auth` holding PII feed the portable Q3.1 PII inventory.
- **Neon RLS.** Neon's RLS stack uses the `pg_session_jwt` extension plus `auth.user_id()` / `auth.session()` helpers and the `authenticated` / `anonymous` roles. If `pg_session_jwt` is installed (vetted SELECT against `pg_extension`), apply Neon-flavored RLS classification to the portable Q2.3 policy rows:
  - policy granted to `anonymous` for `INSERT`/`UPDATE`/`DELETE` → HIGH
  - policy referencing `auth.user_id()` / `auth.session()` is the expected pattern (no finding)
- **Neon Data API.** Neon's Data API is PostgREST-like — if enabled, it exposes the schema over HTTP and is **RLS-or-bust**. Q2.1 severity is CONTEXT-DEPENDENT (not a floor): CRITICAL when the table is reachable via an exposed data API (Supabase `anon` / Neon Data API), HIGH otherwise. When the Data API is enabled (control-plane signal, or `pgrst`/`postgrest` role/schema present), any `public` table WITHOUT RLS (portable Q2.1 result) resolves to **CRITICAL** — the exposed-API case, same as Supabase. If the Data API is NOT enabled and there is no anon exposure, RLS-off resolves to the HIGH/vanilla case (the core query is generic and reports the condition only; this adapter sets CRITICAL only under Data-API exposure).

---

## Module 5 / TS types / edge functions / storage / auth providers — INFO-N/A

Neon has no JS Supabase client, no edge functions, no storage buckets, and no `generate_typescript_types` analogue. Emit:

- **Module 5 client coherence:** `[INFO] Module 5 — no JS Supabase client; client-coherence N/A on Neon.`
- **TS-types diff (Supabase Module-5 step 7):** `[INFO] generate_typescript_types N/A on Neon.`
- **Edge functions / Storage buckets / Auth providers:** the Phase-7 DATABASE.md template must **conditionalize** these sections — on Neon they render as `_N/A — not applicable to Neon._` rather than populated tables.
