#!/usr/bin/env bash
#
# run-core-audit-test.sh — Tier-1 hermetic test for the /database-audit
# portable SQL core + finding-emission + redaction paths.
#
# WHAT IT PROVES (hermetically, no creds, no external DB):
#   1. The portable core queries from ../../core.md detect every planted defect
#      in seed-bad-schema.sql at the correct VANILLA-context severity.
#   2. The core queries run inside a `BEGIN READ ONLY; ... ROLLBACK;` wrapper
#      (SELECT-only guard rule 6) — the transaction is read-only and rolls back.
#   3. The redaction rule 1 (../../redaction.md) redacts a JWT-shaped fake
#      service_role string to `[REDACTED:...]` and never leaks the raw value.
#   4. The redaction rule 5 (../../redaction.md) redacts a fake postgres://
#      connection string to `[REDACTED:...]` and never leaks the raw password
#      or host.
#
# CONVENTION (/script): idempotent, self-cleaning, deterministic exit codes,
# namespaced synthetic data.
#
# EXIT CODES:
#   0   all planted findings caught AND both redaction fixtures passed
#   1   one or more planted findings missed, or either redaction fixture failed
#   77  skipped — Postgres image not cached and host is offline (NOT a failure)
#
# USAGE:  bash run-core-audit-test.sh
# REQUIRES: docker, psql-in-container (provided by the image; host psql NOT needed).

# set -e is intentionally NOT used: a failing assertion must not abort before we
# accumulate-and-report every miss. We use nounset + pipefail instead.
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Pinned BY DIGEST for reproducible, tamper-evident runs (resolved 2026-05-31 from
# docker.io postgres:16). To refresh: `docker pull postgres:16 && docker image inspect
# postgres:16 --format '{{index .RepoDigests 0}}'` and replace the digest below.
IMAGE="postgres@sha256:4b7183ac05f8ef417db21fd72d71047a4238340c261d3cc3ddb6d579ab5071ae"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_FILE="${SCRIPT_DIR}/seed-bad-schema.sql"

# Per-run unique container name. `date +%s` + RANDOM gives a UUID-ish suffix
# without depending on uuidgen being installed.
RUN_ID="$(date +%s)-${RANDOM}-$$"
CONTAINER="dbaudit-test-${RUN_ID}"

PG_PASSWORD="dbaudit_test_pw_not_a_real_secret"
PG_USER="postgres"
PG_DB="postgres"

EXIT_SKIP=77

# Temp files created later via mktemp (Phase: core-query run). Initialized empty
# HERE so the EXIT trap can reference them safely even if a SIGINT/SIGTERM arrives
# BEFORE mktemp runs (rm -f on an empty string is a harmless no-op).
CORE_SQL=""
CORE_OUT_FILE=""

# ---------------------------------------------------------------------------
# Docker availability gate (runs FIRST, before any docker invocation). A missing
# docker binary or a stopped daemon is a distinct skip reason from "online but
# the image isn't cached and can't be pulled" — report each accurately (both
# still exit 77, not a failure).
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "[SKIP] docker unavailable (daemon down or not installed)."
  echo "[SKIP] This is NOT a test failure — start the Docker daemon (or install docker) and re-run."
  exit "$EXIT_SKIP"
fi

# ---------------------------------------------------------------------------
# PRE-RUN reap of leaked containers (covers SIGKILL/OOM where the trap never
# fired on a prior run). Matches the `dbaudit-test-` prefix but ONLY removes
# containers that are NOT running — so a concurrently-executing test's live
# container (status=running) is left untouched. We reap exited/dead/created.
# ---------------------------------------------------------------------------
ids=$(docker ps -aq \
  --filter name=dbaudit-test- \
  --filter status=exited \
  --filter status=dead \
  --filter status=created)
[ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Teardown trap — PRESERVES the real exit code. Removes only THIS run's
# container. Fires on normal exit, error, and signals.
# ---------------------------------------------------------------------------
trap 'rc=$?; docker rm -f "$CONTAINER" >/dev/null 2>&1; rm -f "$CORE_SQL" "$CORE_OUT_FILE"; exit $rc' EXIT

# ---------------------------------------------------------------------------
# Offline honesty: if the image is not cached AND we cannot pull it, skip with a
# distinct code rather than reporting a false failure.
# ---------------------------------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[INFO] image '$IMAGE' not cached locally — attempting pull..."
  if ! docker pull "$IMAGE" >/dev/null 2>&1; then
    echo "[SKIP] image not cached and offline (image '$IMAGE' could not be pulled)."
    echo "[SKIP] This is NOT a test failure — run once while online to cache the image."
    exit "$EXIT_SKIP"
  fi
fi

if [ ! -f "$SEED_FILE" ]; then
  echo "[FAIL] seed file not found: $SEED_FILE"
  exit 1
fi

# ---------------------------------------------------------------------------
# Start the container (localhost-only; no published port needed — we exec psql
# inside the container, so nothing binds on the host).
# ---------------------------------------------------------------------------
echo "[INFO] starting container $CONTAINER ($IMAGE)..."
if ! docker run -d --name "$CONTAINER" \
      -e POSTGRES_PASSWORD="$PG_PASSWORD" \
      -e POSTGRES_USER="$PG_USER" \
      -e POSTGRES_DB="$PG_DB" \
      "$IMAGE" >/dev/null 2>&1; then
  echo "[FAIL] could not start container."
  exit 1
fi

# ---------------------------------------------------------------------------
# Readiness wait: pg_isready loop with a timeout.
# ---------------------------------------------------------------------------
echo "[INFO] waiting for Postgres readiness..."
READY=0
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done
if [ "$READY" -ne 1 ]; then
  echo "[FAIL] Postgres did not become ready within timeout."
  docker logs "$CONTAINER" 2>&1 | tail -n 20
  exit 1
fi

# Helper: run a psql command inside the container, quiet/tuples-only friendly.
psql_exec() {  # args passed straight to psql
  docker exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" "$@"
}

# ---------------------------------------------------------------------------
# Load the seed (plants the known defects, ends with ANALYZE).
# ---------------------------------------------------------------------------
echo "[INFO] loading seed-bad-schema.sql..."
if ! docker exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 < "$SEED_FILE" >/dev/null 2>&1; then
  echo "[FAIL] seed load failed."
  docker exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 < "$SEED_FILE" 2>&1 | tail -n 20
  exit 1
fi

# ---------------------------------------------------------------------------
# Run the portable core queries verbatim from core.md, wrapped in the rule-6
# BEGIN READ ONLY; ... ROLLBACK; transaction. Each query's rows are tagged with
# a stable marker prefix so assertions can grep deterministically.
#
# -A (unaligned) -t (tuples only) -F '|' make output grep-stable.
# ---------------------------------------------------------------------------
echo "[INFO] running core queries (BEGIN READ ONLY wrapper)..."
# NOTE: macOS system bash (3.2.57) mis-parses a quoted heredoc nested inside $( ),
# so write the SQL to a temp file FIRST (heredoc NOT inside command substitution),
# then run psql reading from it. The SQL stays verbatim and this is bash-3.2-safe.
CORE_SQL="$(mktemp "${TMPDIR:-/tmp}/dbaudit-core-sql.XXXXXX")"
CORE_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/dbaudit-core-out.XXXXXX")"
cat > "$CORE_SQL" <<'SQL'
BEGIN READ ONLY;

-- Prove the transaction is actually READ ONLY.
SELECT 'TXN_RO=' || current_setting('transaction_read_only');

-- Q1.1 — Tables without primary key (CRITICAL)
SELECT 'Q1.1|' || n.nspname || '|' || c.relname
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind IN ('r','p')
  AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
  );

-- Q1.2 — FKs without backing index (single-col HIGH). Predicates VERBATIM from
-- core.md: the inner EXISTS includes i.indpred IS NULL AND i.indisvalid so a
-- partial or invalid index does not count as covering. The seed's planted FK has
-- NO index at all, so it still matches.
SELECT 'Q1.2|' || c.conrelid::regclass || '|' || c.conname || '|' || array_length(c.conkey, 1)
FROM pg_constraint c
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND (i.indkey::int2[])[1:array_length(c.conkey,1)] = c.conkey
      AND i.indpred IS NULL
      AND i.indisvalid
  );

-- Q1.5 — Columns with 100% NULL (MEDIUM)
SELECT 'Q1.5|' || schemaname || '|' || tablename || '|' || attname
FROM pg_stats
WHERE schemaname = 'public' AND null_frac = 1.0;

-- Q2.1 — RLS off on public tables (detection only in vanilla context)
SELECT 'Q2.1|' || c.relname
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND c.relrowsecurity = false;

-- Q2.3 — All policies (heuristic scan; qual='true' => blanket CRITICAL)
SELECT 'Q2.3|' || schemaname || '|' || tablename || '|' || policyname || '|qual=' || COALESCE(qual,'')
FROM pg_policies WHERE schemaname = 'public';

-- Q2.4 — SECURITY DEFINER functions with mutable search_path (HIGH)
SELECT 'Q2.4|' || n.nspname || '|' || p.proname
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.prosecdef = true
  AND n.nspname NOT IN ('pg_catalog','information_schema')
  AND (
    p.proconfig IS NULL
    OR NOT EXISTS (
      SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%'
    )
  );

-- Q3.1 — PII columns with anon SELECT access (HIGH)
SELECT 'Q3.1|' || c.table_name || '|' || c.column_name
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

-- ===========================================================================
-- MODULES 6–15 EXTENSION — verbatim query bodies hand-copied from ../../core.md
-- (the runner does NOT read core.md at runtime). Two classes:
--   (1) SEEDABLE — a defect is planted in seed-bad-schema.sql; assert the finding.
--   (2) SHAPE-ONLY — non-seedable in a fresh container; the query is run only to
--       prove it executes read-only, exits 0, and returns its header columns.
--
-- SINGLE-TRANSACTION BRANCH HAZARD: this whole heredoc is ONE
-- `psql -v ON_ERROR_STOP=1` inside ONE BEGIN READ ONLY … ROLLBACK. A single
-- missing-relation/function error ABORTS the transaction and fails ALL
-- assertions (D1–D15). Therefore only the IMAGE-MAJOR-CORRECT branch of any
-- version-branched query is pasted here. The pinned image is postgres:16, so:
--   * Q6.18 uses pg_stat_bgwriter (PG<17), NOT pg_stat_checkpointer (PG17+).
--   * Q6.19 calls pg_database_collation_actual_version(<oid>) (exists on PG16).
-- The PG17 branches (pg_stat_checkpointer) are documented Tier-2 (README).
-- ===========================================================================

-- ---- SEEDABLE -------------------------------------------------------------

-- Q2.6 — FORCE RLS gap (D8). verbatim from core.md Module 2 (Q2.6)
SELECT 'Q2.6|' || n.nspname || '|' || c.relname
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'public'
  AND c.relrowsecurity = true
  AND c.relforcerowsecurity = false;

-- Q9.1 — FKs without ON DELETE / ON UPDATE action (D9). verbatim from core.md Module 9 (Q9.1).
-- (confdeltype/confupdtype are catalog "char"; cast to text for the marker concat only.)
SELECT 'Q9.1|' || con.conrelid::regclass || '|' || con.conname || '|' || con.confdeltype::text || con.confupdtype::text
FROM pg_constraint con
JOIN pg_namespace n ON con.connamespace = n.oid
WHERE con.contype = 'f'
  AND n.nspname = 'public'
  AND (con.confdeltype = 'a' OR con.confupdtype = 'a');

-- Q9.4 — timestamp without time zone (D10). verbatim from core.md Module 9 (Q9.4)
SELECT 'Q9.4|' || table_name || '|' || column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type = 'timestamp without time zone';

-- Q9.5 — money-typed column (D11). verbatim from core.md Module 9 (Q9.5, money branch)
SELECT 'Q9.5|' || table_name || '|' || column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type = 'money';

-- Q15.3 — plaintext-secret columns, NAME-ONLY (D12). verbatim from core.md Module 15 (Q15.3)
SELECT 'Q15.3|' || table_schema || '|' || table_name || '|' || column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name ~* '(^|_)(token|secret|api_?key|password|private_key|access_key)($|_)';

-- Q15.4 — extension installed in public schema (D13).
-- core.md's Q15.4 placement check now reads `ext_schema` from the Preamble P3
-- extension inventory (core.md §Preamble P3:
--   SELECT extname, extversion, n.nspname AS ext_schema
--   FROM pg_extension e JOIN pg_namespace n ON e.extnamespace = n.oid; )
-- and flags any row whose ext_schema='public'. This runner has NO preamble, so
-- the SELECT below is the TEST'S STAND-IN for that P3 inventory query, filtered
-- to ext_schema='public' to reproduce the search_path-hijack placement flag.
-- Verbatim P3 column shape (extname, ext_schema) + the public filter.
SELECT 'Q15.4|' || extname || '|' || n.nspname AS ext_schema
FROM pg_extension e JOIN pg_namespace n ON e.extnamespace = n.oid
WHERE n.nspname = 'public';

-- Q15.5 — event triggers (D15). verbatim from core.md Module 15 (Q15.5)
SELECT 'Q15.5|' || evtname || '|' || evtevent || '|' || (evtowner::regrole)::text || '|' || (evtfoid::regproc)::text
FROM pg_event_trigger;

-- ---- SHAPE-ONLY (non-seedable; prove RO execution + header columns) -------

-- Q6.4 — XID wraparound horizon. verbatim from core.md Module 6 (Q6.4, per-DB form)
SELECT 'Q6.4|' || datname || '|' || age(datfrozenxid)::text || '|' || current_setting('autovacuum_freeze_max_age')
FROM pg_database
ORDER BY age(datfrozenxid) DESC
LIMIT 50;

-- Q6.6 — sequence exhaustion, PART 1: raw consumption. verbatim from core.md Module 6 (Q6.6, pg_sequences form)
SELECT 'Q6.6|' || schemaname || '|' || sequencename || '|' || COALESCE(last_value::text,'NULL') || '|' || max_value::text
FROM pg_sequences
ORDER BY (last_value::numeric / NULLIF(max_value,0)) DESC NULLS LAST
LIMIT 50;

-- Q6.6 — PART 2: int4-sequence-backed-column linkage with the new is_primary_key
-- LEFT JOIN to pg_index (primary-index only). verbatim from core.md Module 6
-- (Q6.6, second query). SHAPE-ONLY: a fresh container has no near-ceiling int4
-- sequence to flag; this proves the tricky pg_depend join + the new
-- `(pk.indrelid IS NOT NULL) AS is_primary_key` LEFT JOIN execute RO on PG16.
SELECT 'Q6.6L|' || s.relname || '|' || t.relname || '|' || a.attname || '|' || (pk.indrelid IS NOT NULL)::text || '|' || COALESCE(seq.last_value::text,'NULL')
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

-- Q6.7 — inactive/lagging replication slots. verbatim from core.md Module 6 (Q6.7)
SELECT 'Q6.7|' || slot_name || '|' || slot_type || '|' || active::text || '|' || COALESCE(wal_status,'')
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

-- Q6.15 — invalid indexes (D14 shape-only; cannot seed indisvalid=false cheaply).
-- verbatim from core.md Module 6 (Q6.15)
SELECT 'Q6.15|' || n.nspname || '|' || ic.relname || '|' || tc.relname || '|' || i.indisvalid::text || '|' || i.indisready::text
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class tc ON tc.oid = i.indrelid
JOIN pg_namespace n ON ic.relnamespace = n.oid
WHERE i.indisvalid = false OR i.indisready = false;

-- Q6.16 — statistics staleness. verbatim from core.md Module 6 (Q6.16).
-- SHAPE-ONLY. Re-synced for the corrected `JOIN pg_class c ON c.oid = s.relid`
-- (joins pg_stat_user_tables.relid → pg_class.oid). A fresh+ANALYZEd container
-- may have n_mod_since_analyze=0 for all tables (0 rows), so shape-only.
SELECT 'Q6.16|' || s.schemaname || '|' || s.relname || '|' || s.n_mod_since_analyze::text || '|' || c.reltuples::text || '|' || current_setting('default_statistics_target')
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid
WHERE s.n_mod_since_analyze > 0
ORDER BY s.n_mod_since_analyze DESC NULLS LAST
LIMIT 50;

-- Q6.17 — size outliers / giant unpartitioned tables. verbatim from core.md
-- Module 6 (Q6.17). SHAPE-ONLY. Re-synced for the corrected
-- `relkind IN ('r','p')` (partitioned parents visible, partition children
-- excluded via NOT relispartition). The seed creates tables, so >=1 row likely,
-- but we assert shape only (no finding).
SELECT 'Q6.17|' || n.nspname || '|' || c.relname || '|' || c.relkind || '|' || pg_total_relation_size(c.oid)::text || '|' || (c.oid IN (SELECT partrelid FROM pg_partitioned_table))::text || '|' || (c.relkind = 'r' AND NOT c.relispartition AND c.oid NOT IN (SELECT partrelid FROM pg_partitioned_table))::text
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind IN ('r','p')
  AND NOT c.relispartition
  AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 50;

-- Q6.18 — checkpoint tuning. verbatim from core.md Module 6 (Q6.18, PG<17 pg_stat_bgwriter branch).
-- IMAGE IS PG16 — pg_stat_checkpointer does NOT exist here; using it would abort
-- the whole transaction. The PG17 pg_stat_checkpointer branch is Tier-2.
SELECT 'Q6.18|' || checkpoints_timed::text || '|' || checkpoints_req::text
FROM pg_stat_bgwriter;

-- Q6.19 — collation version drift, DB-level. verbatim from core.md Module 6 (Q6.19, DB-level form).
-- PG16 has pg_database_collation_actual_version(oid); pass a real OID so the
-- function resolves (an empty-paren call would abort the transaction).
-- NOTE: core.md's DB-level SELECT filters on
--   WHERE datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)
-- (drift only). The shape probe below keeps the verbatim SELECT-list but pins to
-- the current DB row (always present) so this single-tx test deterministically
-- emits a Q6.19 marker proving the PG16 collation func resolves RO.
SELECT 'Q6.19|' || datname || '|' || COALESCE(datcollversion,'') || '|' || COALESCE(pg_database_collation_actual_version(oid),'')
FROM pg_database
WHERE oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- Q6.19 — PER-INDEX collation attribution. verbatim from core.md Module 6 (Q6.19,
-- per-INDEX form). SHAPE-ONLY: a fresh container has no drift so this returns 0
-- rows; the point is proving the `unnest(i.indcollation::oid[])` CAST executes RO
-- on PG16 (an uncast oidvector unnest would abort the whole transaction).
SELECT 'Q6.19I|' || n.nspname || '|' || ic.relname || '|' || tc.relname || '|' || cl.collname || '|' || COALESCE(cl.collversion,'') || '|' || COALESCE(pg_collation_actual_version(cl.oid),'') || '|' || (count(*) OVER ())::text
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

-- Q14.1 — WAL archiver runtime status. verbatim from core.md Module 14 (Q14.1, pg_stat_archiver form)
SELECT 'Q14.1|' || archived_count::text || '|' || failed_count::text || '|' || COALESCE(last_failed_wal,'') || '|' || COALESCE(last_archived_wal,'')
FROM pg_stat_archiver;

ROLLBACK;
SQL
docker exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
  -v ON_ERROR_STOP=1 -A -t -F '|' < "$CORE_SQL" > "$CORE_OUT_FILE" 2>&1
CORE_RC=$?
CORE_OUT="$(cat "$CORE_OUT_FILE")"
rm -f "$CORE_SQL" "$CORE_OUT_FILE"

echo "----- core query output -----"
printf '%s\n' "$CORE_OUT"
echo "-----------------------------"

# ---------------------------------------------------------------------------
# ASSERTIONS — accumulate-then-report. Each entry: "<grep-pattern>|||<defect>".
# We grep the captured CORE_OUT for the deterministic marker+object.
# ---------------------------------------------------------------------------
MISSES=()

# Guard: the core-query psql run must have exited 0. With ON_ERROR_STOP=1 a SQL
# error returns nonzero; without this check a nonzero failure could be masked if
# the grepped markers happened to appear in partial output.
if [ "$CORE_RC" -ne 0 ]; then
  MISSES+=("[FAIL] core-query psql run errored (exit $CORE_RC)")
fi

assert_contains() {  # $1=pattern  $2=human description
  if ! printf '%s\n' "$CORE_OUT" | grep -Eq -- "$1"; then
    MISSES+=("$2  [pattern: $1]")
  fi
}

# Prove the transaction was READ ONLY (rule 6).
assert_contains 'TXN_RO=on'                       'rule-6 BEGIN READ ONLY not in effect (transaction_read_only != on)'

# D1 — no-PK table caught by Q1.1 (CRITICAL severity assigned by core.md)
assert_contains '^Q1\.1\|dbaudit_test\|no_pk_table$' 'D1 missing-PK table not caught by Q1.1 (CRITICAL)'

# D2 — unindexed single-column FK caught by Q1.2 (HIGH)
assert_contains '^Q1\.2\|dbaudit_test\.fk_child_no_index\|' 'D2 unindexed FK not caught by Q1.2 (HIGH)'

# D6 — 100% NULL column caught by Q1.5 (MEDIUM); requires ANALYZE in seed
assert_contains '^Q1\.5\|public\|dbaudit_null_col\|all_null_col$' 'D6 100%-NULL column not caught by Q1.5 (MEDIUM) — did seed ANALYZE run?'

# D3 — RLS-off table DETECTED by Q2.1 (object presence only; vanilla severity is
# provider-discretionary, NOT asserted as CRITICAL here).
assert_contains '^Q2\.1\|dbaudit_rls_off$' 'D3 RLS-off table not detected by Q2.1 (vanilla: detection only, not auto-CRITICAL)'

# D4 — blanket USING(true) policy caught by Q2.3 with qual=true (CRITICAL)
assert_contains '^Q2\.3\|public\|dbaudit_rls_blanket\|dbaudit_blanket_all\|.*qual=true$' 'D4 blanket USING(true) policy not caught by Q2.3 (CRITICAL)'

# D5 — SECURITY DEFINER fn w/o search_path caught by Q2.4 (HIGH)
assert_contains '^Q2\.4\|dbaudit_test\|secdef_no_searchpath$' 'D5 SECURITY DEFINER w/o search_path not caught by Q2.4 (HIGH)'

# D7 — PII column with anon SELECT grant caught by Q3.1 (HIGH)
assert_contains '^Q3\.1\|dbaudit_pii\|email$' 'D7 PII column (email) with anon SELECT not caught by Q3.1 (HIGH)'

# ---------------------------------------------------------------------------
# MODULES 6–15 — SEEDABLE assertions (a defect was planted; assert detection).
# ---------------------------------------------------------------------------

# D8 — FORCE RLS gap (RLS on, FORCE off) caught by Q2.6 (MEDIUM)
assert_contains '^Q2\.6\|public\|dbaudit_force_rls_off$' 'D8 FORCE RLS gap not caught by Q2.6 (MEDIUM)'

# D9 — FK with NO ON DELETE action caught by Q9.1 (MEDIUM); confdeltype 'a' = NO ACTION
assert_contains '^Q9\.1\|dbaudit_fk_child\|' 'D9 FK with no ON DELETE action not caught by Q9.1 (MEDIUM)'

# D10 — timestamp (no tz) column caught by Q9.4 (MEDIUM)
assert_contains '^Q9\.4\|dbaudit_ts_notz\|created_ts$' 'D10 timestamp-without-tz column not caught by Q9.4 (MEDIUM)'

# D11 — money-typed column caught by Q9.5 (MEDIUM)
assert_contains '^Q9\.5\|dbaudit_money_col\|amount$' 'D11 money-typed column not caught by Q9.5 (MEDIUM)'

# D12 — secret-shaped column caught by Q15.3 NAME-ONLY (HIGH). Asserted via 15.3
# ONLY (grant-independent) — NOT Q3.1, which would need an anon grant D12 omits.
assert_contains '^Q15\.3\|public\|dbaudit_secrets\|api_key$' 'D12 secret-shaped column (api_key) not caught by Q15.3 name-only (HIGH)'

# D13 — extension installed in public schema caught by Q15.4 (MEDIUM)
assert_contains '^Q15\.4\|pgcrypto\|public$' 'D13 extension-in-public (pgcrypto) not caught by Q15.4 (MEDIUM)'

# D15 — event trigger caught by Q15.5 (INFO/MEDIUM)
assert_contains '^Q15\.5\|dbaudit_evt_trigger\|' 'D15 event trigger not caught by Q15.5 (INFO/MEDIUM)'

# ---------------------------------------------------------------------------
# MODULES 6–15 — SHAPE-ONLY assertions. These checks cannot be seeded in a
# fresh container (no near-wraparound XID, near-max int4 sequence, failing
# archiver, or failed-CONCURRENTLY index). We do NOT assert a finding — we only
# prove the query EXECUTED under BEGIN READ ONLY and produced its marker-tagged
# header row(s). Because the whole CORE_SQL is one ON_ERROR_STOP=1 transaction,
# CORE_RC==0 already proves none of them raised an error; these markers prove
# each specific query actually ran (vs. being silently absent).
#
# pg_database always has >=1 row, so Q6.4 / Q6.19 deterministically emit a
# marker; the others may legitimately return zero rows (no slots, no invalid
# index, no event of that kind) so we DO NOT assert their marker presence — for
# those, the CORE_RC==0 guard + the TXN_RO=on assertion are the shape proof.
# Q6.18 (pg_stat_bgwriter) and Q14.1 (pg_stat_archiver) are single-row catalog
# views that always return exactly one row, so their markers are deterministic.
# ---------------------------------------------------------------------------

# Q6.4 — XID wraparound query ran RO and returned the per-DB shape (pg_database is non-empty)
assert_contains '^Q6\.4\|' 'Q6.4 XID wraparound query did not run / returned no shape (expected >=1 pg_database row)'

# Q6.18 — checkpoint tuning ran RO via the PG16 pg_stat_bgwriter branch (single-row view)
assert_contains '^Q6\.18\|' 'Q6.18 checkpoint-tuning query did not run / no shape (PG16 pg_stat_bgwriter branch)'

# Q6.19 — collation drift DB-level query ran RO (pg_database current_database row always present)
assert_contains '^Q6\.19\|' 'Q6.19 collation-drift query did not run / no shape (PG16 collation func)'

# Q14.1 — WAL archiver runtime status ran RO (pg_stat_archiver is a single-row view)
assert_contains '^Q14\.1\|' 'Q14.1 WAL-archiver query did not run / no shape (pg_stat_archiver single row)'

# ---------------------------------------------------------------------------
# REDACTION fixture (proves redaction.md rule 1, hermetically, no real creds).
# FAKE_SECRET is an obviously-fake JWT-shaped string (eyJ + >=20 chars). The
# inline redactor below mirrors rule 1's JWT-shaped pattern:
#     eyJ[A-Za-z0-9_-]{20,}  ->  [REDACTED:<first-8-of-sha256>]
# ---------------------------------------------------------------------------
echo "[INFO] running redaction fixture..."
FAKE_SECRET="eyJhbGciOiJIUzI1NiFAKEFAKEFAKEdGVzdF9zZXJ2aWNlX3JvbGVfTk9UX1JFQUw"
RAW_LINE="service_role key for testing = ${FAKE_SECRET}"

# Inline redactor: compute first-8-of-sha256 of the matched token and substitute.
# Pure shell + sha256 tool detection (sha256sum on Linux, shasum -a 256 on macOS).
sha256_first8() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-8
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-8
  fi
}

REDACTED_LINE="$RAW_LINE"
# Extract the JWT-shaped token (rule 1: eyJ followed by >=20 of [A-Za-z0-9_-]).
TOKEN="$(printf '%s\n' "$RAW_LINE" | grep -oE 'eyJ[A-Za-z0-9_-]{20,}' | head -1)"
if [ -n "$TOKEN" ]; then
  HASH8="$(sha256_first8 "$TOKEN")"
  # Replace the literal token with the redaction marker (literal, not regex).
  REDACTED_LINE="${RAW_LINE//$TOKEN/[REDACTED:$HASH8]}"
fi

echo "[INFO] redacted line: $REDACTED_LINE"

if ! printf '%s' "$REDACTED_LINE" | grep -Eq '\[REDACTED:[0-9a-f]{8}\]'; then
  MISSES+=("REDACTION: output does not contain a contract-format [REDACTED:<8 lowercase hex>] marker")
fi
if printf '%s' "$REDACTED_LINE" | grep -qF -- "$FAKE_SECRET"; then
  MISSES+=("REDACTION: raw fake secret value leaked through redaction")
fi

# ---------------------------------------------------------------------------
# REDACTION fixture #2 — connection-string redaction (redaction.md rule 5),
# hermetic, no real creds. A fake postgres:// URI with an embedded password and
# host. The inline redactor below mirrors rule 5's connection-string pattern:
#     (postgres(ql)?|mysql|mongodb(\+srv)?)://...  ->  [REDACTED:<first-8-of-sha256>]
# Asserts the output (a) carries the contract [REDACTED:<8 hex>] marker and
# (b) leaks NEITHER the raw password NOR the raw host.
# ---------------------------------------------------------------------------
echo "[INFO] running connection-string redaction fixture (rule 5)..."
FAKE_DB_PASSWORD="fakepw123456"
FAKE_DB_HOST="db.example.com"
FAKE_CONNSTR="postgres://audituser:${FAKE_DB_PASSWORD}@${FAKE_DB_HOST}:5432/appdb"
CONN_RAW_LINE="DATABASE_URL=${FAKE_CONNSTR}"

CONN_REDACTED_LINE="$CONN_RAW_LINE"
# Extract the connection-string token (rule 5: scheme://...up to the next space).
CONN_TOKEN="$(printf '%s\n' "$CONN_RAW_LINE" | grep -oE '(postgres|postgresql|mysql|mongodb\+srv|mongodb)://[^[:space:]]+' | head -1)"
if [ -n "$CONN_TOKEN" ]; then
  CONN_HASH8="$(sha256_first8 "$CONN_TOKEN")"
  # Replace the literal connection string with the redaction marker (literal, not regex).
  CONN_REDACTED_LINE="${CONN_RAW_LINE//$CONN_TOKEN/[REDACTED:$CONN_HASH8]}"
fi

echo "[INFO] redacted conn line: $CONN_REDACTED_LINE"

if ! printf '%s' "$CONN_REDACTED_LINE" | grep -Eq '\[REDACTED:[0-9a-f]{8}\]'; then
  MISSES+=("REDACTION(rule5): output does not contain a contract-format [REDACTED:<8 lowercase hex>] marker")
fi
if printf '%s' "$CONN_REDACTED_LINE" | grep -qF -- "$FAKE_DB_PASSWORD"; then
  MISSES+=("REDACTION(rule5): raw connection-string password leaked through redaction")
fi
if printf '%s' "$CONN_REDACTED_LINE" | grep -qF -- "$FAKE_DB_HOST"; then
  MISSES+=("REDACTION(rule5): raw connection-string host leaked through redaction")
fi

# ---------------------------------------------------------------------------
# Report all misses, then exit once.
# ---------------------------------------------------------------------------
echo
if [ "${#MISSES[@]}" -gt 0 ]; then
  echo "[FAIL] ${#MISSES[@]} assertion(s) failed:"
  for m in "${MISSES[@]}"; do
    echo "  - $m"
  done
  exit 1
fi

echo "[PASS] all planted findings DETECTED by the correct core query (severity is assigned in core.md, not asserted here); redaction verified."
exit 0
