# /database-audit — Two-Tier Test Harness

The `/database-audit` command has two test tiers. Tier 1 is hermetic and
automatable; Tier 2 is a documented manual procedure against throwaway live dev
branches. Together they cover what the command does — Tier 1 proves the portable
parts mechanically, Tier 2 proves the parts that can only exist against a real
provider control plane.

---

## Tier 1 — Hermetic Docker core test

Proves the previously-untested **portable SQL core**, **finding-emission**, and
**redaction** paths against an ephemeral, throwaway Postgres container. No
credentials, no external network (after the image is cached), no real data.

### Run it

```bash
bash run-core-audit-test.sh
```

Requires `docker`. Nothing binds on the host (psql runs *inside* the container);
host `psql` is not needed.

### Exit codes

| Code | Meaning                                                                 |
|------|-------------------------------------------------------------------------|
| `0`  | PASS — each planted defect is DETECTED by the correct core query (Qx.y marker) and the redaction engine produces the `[REDACTED:<8hex>]` marker. Severity values themselves are defined in `core.md` and are not asserted here. |
| `1`  | FAIL — one or more planted findings were missed, or redaction failed. Every miss is printed by name before exit. |
| `77` | SKIPPED — the Postgres image is not cached locally and the host is offline, so it could not be pulled. This is **not** a failure; run once while online to cache the image. |

### What it does

1. Reaps any leaked **non-running** `dbaudit-test-*` containers — exited/dead/
   created only (covers a prior SIGKILL/OOM where the teardown trap never fired);
   a concurrently-running test's live container is left untouched — then starts a
   uniquely-named container.
2. Waits for readiness via a `pg_isready` loop, then loads
   `seed-bad-schema.sql`, which plants known defects in a namespaced
   `dbaudit_test` schema (plus a few `dbaudit_`-prefixed objects in `public`
   for the `public`-scoped queries) and ends with `ANALYZE;`.
3. Runs the portable core queries (copied verbatim from `../../core.md`) inside
   a `BEGIN READ ONLY; … ROLLBACK;` transaction — this also proves SELECT-only
   guard rule 6 (the run asserts `transaction_read_only = on`).
4. Accumulates assertions: for each planted defect it greps the query output
   for the expected object and the query that should catch it. All misses are
   collected and printed; the script exits `1` once if any miss, `0` if clean.
5. Feeds an obviously-fake JWT-shaped `service_role` string through redaction
   rule 1 (`../../redaction.md`) and asserts the output contains `[REDACTED:`
   and does **not** contain the raw fake value.

The container is torn down by the `EXIT` trap (which preserves the real exit
code) on normal exit, assertion failure, and most signals; a `SIGKILL`/OOM leak
is reaped by the pre-run cleanup on the next run.

### Planted defects → catching query → expected vanilla-context severity

| Defect                                   | Query | Vanilla severity                                   |
|------------------------------------------|-------|----------------------------------------------------|
| Table with no primary key                | Q1.1  | CRITICAL                                            |
| Single-column FK with no backing index   | Q1.2  | HIGH                                                |
| Column that is 100% NULL                 | Q1.5  | MEDIUM (needs the seed's trailing `ANALYZE`)        |
| Table with RLS disabled                  | Q2.1  | Detection only — NOT auto-CRITICAL on vanilla PG (no anon/Data-API surface); severity is provider-discretionary, so only object presence is asserted |
| Blanket `USING (true)` permissive policy | Q2.3  | CRITICAL (`qual = 'true'` heuristic)                |
| SECURITY DEFINER fn w/o `search_path`     | Q2.4  | HIGH                                                |
| PII-named column (`email`) w/ anon SELECT | Q3.1  | HIGH                                                |

**Not asserted:** Q1.3 (unused index) is gated on
`now() - stats_reset > interval '7 days'`. A fresh container's stats are seconds
old, so Q1.3 self-skips with an INFO. It cannot fire hermetically and is
deliberately neither planted nor asserted (see the seed file's comment block).

### Modules 6–15 coverage

The Module 6–15 expansion is exercised in two classes. The whole core-query run
is ONE `psql -v ON_ERROR_STOP=1` invocation inside ONE
`BEGIN READ ONLY; … ROLLBACK;` transaction, so a single missing-relation/function
error aborts the entire transaction and fails every assertion. Only the
**image-major-correct** branch of any version-branched query is embedded (the
pinned image is `postgres:16` → `pg_stat_bgwriter`, NOT `pg_stat_checkpointer`;
collation uses `pg_database_collation_actual_version(<oid>)`). The PG17
`pg_stat_checkpointer` branch is **Tier-2** (see below).

**Seedable → a defect is planted and the finding is asserted:**

| Defect | Planted in seed | Query | Vanilla severity |
|--------|-----------------|-------|------------------|
| D8 — public table, RLS on + FORCE off | `public.dbaudit_force_rls_off` | Q2.6 | MEDIUM (owner bypass) |
| D9 — FK with no ON DELETE action | `public.dbaudit_fk_child` | Q9.1 | MEDIUM |
| D10 — `timestamp` (no tz) column | `public.dbaudit_ts_notz` | Q9.4 | MEDIUM |
| D11 — `money`-typed column | `public.dbaudit_money_col` | Q9.5 | MEDIUM |
| D12 — secret-shaped column (`api_key`) | `public.dbaudit_secrets` | Q15.3 (NAME-ONLY) | HIGH |
| D13 — extension in `public` schema (`pgcrypto`) | top-level `CREATE EXTENSION … SCHEMA public` | Q15.4 | MEDIUM |
| D15 — event trigger | `dbaudit_evt_trigger` (created LAST, no-op fn) | Q15.5 | INFO/MEDIUM |

> **D12 is asserted via Q15.3 ONLY**, never Q3.1: Q3.1 requires a
> `GRANT SELECT … TO anon` that D12 does not plant, whereas Q15.3 is
> grant-independent. **D13** relies on `pgcrypto` shipping in the digest-pinned
> `postgres:16` contrib image (confirmed present); if it were absent the
> `ON_ERROR_STOP=1` seed would abort. **D15**'s event trigger is created AFTER
> the seed's trailing `ANALYZE` with a no-op `RETURNS event_trigger` function so
> it never fires on earlier seed DDL (which would break the seed load).

**Shape-only → NOT seedable in a fresh container; only proves the query runs
read-only, exits 0, and returns its header columns (no finding asserted):**

| Check | Query | Why shape-only |
|-------|-------|----------------|
| XID wraparound | Q6.4 | can't fabricate a near-2^31 `datfrozenxid` cheaply |
| Sequence / int4-PK exhaustion | Q6.6 | can't fabricate a near-max sequence cheaply |
| Inactive/lagging replication slots | Q6.7 | no slots in a standalone fresh container |
| Invalid index (D14) | Q6.15 | can't seed `indisvalid=false` without a failed `CONCURRENTLY` |
| Checkpoint tuning | Q6.18 (`pg_stat_bgwriter`, PG16 branch) | counters reflect container lifetime only |
| Collation version drift | Q6.19 (`pg_database_collation_actual_version(oid)`) | no libc/ICU drift in a fresh image |
| WAL archiver health | Q14.1 (`pg_stat_archiver`) | archiving is off; nothing to fail |

For shape-only checks the proof is: `CORE_RC == 0` (no query in the shared
transaction raised an error) + `TXN_RO = on` still holds. Queries over
always-non-empty single-row catalogs (Q6.4/Q6.18/Q6.19/Q14.1) additionally
assert their marker is present; zero-row-legal queries (Q6.6/Q6.7/Q6.15) rely on
the `CORE_RC == 0` + `TXN_RO` guard, since an empty result is valid.

**`[PROVIDER]` manual-verify (NOT in Tier 1 at all):** these never run SQL and
cannot be hermetically asserted — Q6.20 (free disk / WAL volume / pool
saturation), Q10.2 (log retention/immutability), Q11.4 (at-rest encryption),
Q14.3 (PITR / last-backup / retention), Q14.4 (restore drill). They are
manual-verify INFO with a `Severity-if-absent:` line and belong to Tier 2.
`[RO+priv]` / `[EXT]` checks (Q6.3/6.8/6.9/6.10/6.13/6.14, Q7.2, Q11.2) degrade
to INFO under the unprivileged container role and are likewise validated in
Tier 2 against a real provider. Module 13 (migration-safety lint) is `[FS]`
filesystem-static and is not part of this DB-container test.

---

## Tier 2 — Manual live dev-branch procedure

Tier 1 cannot exercise provider control-plane modules or the Module-5
client-coherence sub-agent, because those depend on a real provider API/MCP and
a real application repo. Prove them by hand against **throwaway dev branches**
(never production):

### Setup

1. **Supabase:** create a throwaway dev branch of a test project (Supabase
   dashboard → Branches → create branch, or `supabase branches create`). Link
   the local repo to it. Never point this at a production project.
2. **Neon:** create a throwaway dev branch (`neonctl branches create`, or the
   Neon console). Confirm it is **not** the `default` branch — the prod guard
   treats `default == true` as PROD and will stop before any SQL.

### Run

```bash
# Supabase platform + client-coherence path (dev branch confirmed):
/database-audit --provider=supabase --env=prod

# Neon platform path (dev branch confirmed):
/database-audit --provider=neon --env=prod
```

> `--env=prod` here confirms a read-only audit of the linked target after the
> prod guard fires. It runs SELECT-only queries and mutates nothing. Only use it
> once you have confirmed the target is a throwaway dev branch.

### Eyeball these (the parts Tier 1 cannot reach hermetically)

- **Supabase platform modules:** `get_advisors` security/performance findings,
  anon/RLS classification, storage buckets, edge functions, realtime
  publications, auth manual checks (SMTP/MFA/PITR/webhooks), and the branch-shape
  prod ladder.
- **Neon platform modules:** branch list / branch sprawl, scale-to-zero,
  autoscaling bounds, pooler vs direct host, IP allowlist, restore window,
  `neon_auth` schema, `pg_session_jwt` RLS, Data API exposure. With Neon MCP
  unconfigured, confirm these emit `[INFO] … unavailable` and the psql core still
  runs (graceful degradation), with no abort.
- **Module-5 client coherence:** the sub-agent that scans application JS for
  Supabase client patterns (`.from()` / `.rpc()`), and on Neon/vanilla emits the
  INFO "no JS Supabase client; client-coherence N/A".
- **Report assembly + redaction on real output:** confirm the written report in
  `./tmp/db-audit/` redacts any real secret-shaped strings and never echoes
  `DATABASE_URL`.

### Teardown

Delete both throwaway dev branches when finished. Tier 2 leaves no automated
state — it is a human verification pass.
