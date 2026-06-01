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
| `0`  | PASS — every planted finding was caught at the correct vanilla-context severity, and the redaction fixture redacted the fake secret. |
| `1`  | FAIL — one or more planted findings were missed, or redaction failed. Every miss is printed by name before exit. |
| `77` | SKIPPED — the Postgres image is not cached locally and the host is offline, so it could not be pulled. This is **not** a failure; run once while online to cache the image. |

### What it does

1. Reaps any leaked `dbaudit-test-*` containers (covers a prior SIGKILL/OOM
   where the teardown trap never fired), then starts a uniquely-named container.
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
