# database-audit — Vanilla Postgres Provider Adapter

This file is `Read` by the `/database-audit` orchestrator **only when the detected/forced provider is `postgres`** (the fallback when no Supabase or Neon signal matched). It declares (a) the connection method, (b) the prod-guard contribution, and (c) that there are NO platform modules — vanilla Postgres is the portable `core.md` floor and nothing more.

**Single source of truth:** every portable query (Q1.1–Q4.2) lives in `core.md`. This file does NOT repeat any query. Vanilla Postgres runs `core.md` and only `core.md`.

---

## (a) Connection

Direct `psql`, no control plane:

```sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN READ ONLY;
  -- core query library Qx.y verbatim from core.md
ROLLBACK;
SQL
```

- The `BEGIN READ ONLY; … ROLLBACK;` wrapper is the DB-enforced no-mutation guarantee (`guards.md` rule 6). It blocks WRITES; it does NOT discharge the prod guard.
- If the connection requires TLS and `$DATABASE_URL` lacks an SSL mode, append `?sslmode=require` to the connection string. **Never echo `$DATABASE_URL`** (redaction rule 4 — key NAMES only).
- Connection SOURCE: explicit `$DATABASE_URL` only. If `$DATABASE_URL` is empty/unset → SKIP the core with `[INFO] No connection source — set $DATABASE_URL. Core SQL skipped.` (no control plane to fall back to).

### Preflight detection (Phase 0a)

`postgres` is the **fallback** provider — selected when neither the Supabase nor the Neon detection signals matched (and `--provider` was not forced). A non-empty `DATABASE_URL` whose host matches no known provider host falls through to `postgres` (it never auto-matches Supabase/Neon).

---

## (b) Prod-guard contribution — always PROD

Vanilla Postgres has **no control plane** to consult for branch/environment metadata, so the generalized prod guard (`guards.md`) resolves to **always PROD** (the safe default). Per the guard: if PROD and `--env=prod` was not passed, run only zero-data-touch modules, then STOP before opening any psql core session. The stop/resume prompt lives in `guards.md`.

```
postgres signal: always PROD (no control plane).
```

---

## (c) Platform modules — NONE

Vanilla Postgres has no provider-specific surface. It runs the portable `core.md` library (schema Q1.x, RLS Q2.x, security Q3.1/Q3.3, prod Q4.1/Q4.2) and nothing else. Provider-supplied inputs to the core:

- **Supported Postgres major versions** (for portable Q4.1): `['13', '14', '15', '16', '17']`. List last updated: `2026-05`. Major version not in this list → HIGH. EOL staleness: if today is more than 18 months after `2026-05` → INFO "Postgres version support data may be stale; verify at postgresql.org."
- **Migration drift:** vanilla has no managed migrations API. Use on-disk migration files only, compared against a migrations bookkeeping table if one is present (per the `core.md` Migration drift note); otherwise emit INFO "no managed migration ledger — drift not checkable from DB."

### RLS-off is NOT auto-CRITICAL here (vanilla-context severity)

On vanilla Postgres there is no `anon` role and no auto-generated public API (no PostgREST / Supabase Data API), so an RLS-disabled `public` table is NOT automatically exposed. The portable Q2.1 finding therefore uses the **vanilla-context severity (HIGH, not CRITICAL)** — RLS is still a missing defense-in-depth control, but the breach-on-by-default exposure that justifies CRITICAL in the Supabase/Neon-Data-API context is absent here. Do not escalate Q2.1 to CRITICAL for `postgres`.

(This is the severity the Tier-1 Docker harness asserts — vanilla-context, not Supabase's CRITICAL.)

### Everything Supabase/Neon-specific emits INFO-N/A

- Security/performance advisors → `[INFO] advisors N/A — no control plane on vanilla Postgres.`
- Storage buckets / edge functions / realtime publications → `[INFO] N/A — Supabase-only surfaces.`
- Autoscaling / scale-to-zero / pooler / IP-allowlist / branch metadata → `[INFO] N/A — no control plane on vanilla Postgres.`
- Module 5 client coherence → `[INFO] Module 5 — no JS Supabase client; client-coherence N/A.`
- `generate_typescript_types` diff → `[INFO] generate_typescript_types N/A on vanilla Postgres.`
- DATABASE.md Edge Functions / Storage Buckets / Auth Providers sections render as `_N/A — not applicable to vanilla Postgres._` (Phase-7 template conditionalizes per provider).
