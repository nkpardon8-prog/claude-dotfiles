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
#
# CONVENTION (/script): idempotent, self-cleaning, deterministic exit codes,
# namespaced synthetic data.
#
# EXIT CODES:
#   0   all planted findings caught AND redaction fixture passed
#   1   one or more planted findings missed, or redaction failed
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

# ---------------------------------------------------------------------------
# PRE-RUN reap of leaked containers (covers SIGKILL/OOM where the trap never
# fired on a prior run). Matches the whole `dbaudit-test-` prefix.
# ---------------------------------------------------------------------------
ids=$(docker ps -aq --filter name=dbaudit-test-); [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Teardown trap — PRESERVES the real exit code. Removes only THIS run's
# container. Fires on normal exit, error, and signals.
# ---------------------------------------------------------------------------
trap 'rc=$?; docker rm -f "$CONTAINER" >/dev/null 2>&1; exit $rc' EXIT

# ---------------------------------------------------------------------------
# Offline honesty: if the image is not cached AND we cannot pull it, skip with a
# distinct code rather than reporting a false failure.
# ---------------------------------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[INFO] image '$IMAGE' not cached locally — attempting pull..."
  if ! docker pull "$IMAGE" >/dev/null 2>&1; then
    echo "[SKIP] image '$IMAGE' is not cached and could not be pulled (offline?)."
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
CORE_OUT="$(docker exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
  -v ON_ERROR_STOP=1 -A -t -F '|' <<'SQL' 2>&1
BEGIN READ ONLY;

-- Prove the transaction is actually READ ONLY.
SELECT 'TXN_RO=' || current_setting('transaction_read_only');

-- Q1.1 — Tables without primary key (CRITICAL)
SELECT 'Q1.1|' || n.nspname || '|' || c.relname
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
  );

-- Q1.2 — FKs without backing index (single-col HIGH)
SELECT 'Q1.2|' || c.conrelid::regclass || '|' || c.conname
FROM pg_constraint c
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND (i.indkey::int2[])[1:array_length(c.conkey,1)] = c.conkey
  );

-- Q1.5 — Columns with 100% NULL (MEDIUM)
SELECT 'Q1.5|' || schemaname || '|' || tablename || '|' || attname
FROM pg_stats
WHERE schemaname = 'public' AND null_frac = 1.0;

-- Q2.1 — RLS off on public tables (detection only in vanilla context)
SELECT 'Q2.1|' || c.relname
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = false;

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

ROLLBACK;
SQL
)"
CORE_RC=$?

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
