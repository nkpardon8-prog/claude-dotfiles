-- seed-bad-schema.sql — Tier-1 hermetic fixture for /database-audit core queries.
--
-- Plants a set of KNOWN schema defects that the portable core queries in
-- ../../core.md must catch. Everything lives in the namespaced schema
-- `dbaudit_test` (synthetic data, never collides with real objects). The
-- public-schema-scoped queries (Q1.5/Q1.6/Q2.1/Q2.3/Q3.1) read `public`, so the
-- objects those exercise are planted in `public` under a `dbaudit_` name prefix
-- and dropped/recreated idempotently.
--
-- ===========================================================================
-- PLANTED DEFECT MAP  (defect -> catching query -> EXPECTED SEVERITY in VANILLA
-- Postgres context — NOT Supabase context). The runner asserts against these.
-- ===========================================================================
--
--   D1  table with NO primary key            -> Q1.1  -> CRITICAL
--   D2  FK column with NO backing index       -> Q1.2  -> HIGH (single-column FK)
--   D3  table with RLS NOT enabled            -> Q2.1  -> (portable floor CRITICAL,
--         but see note) In VANILLA context with no anon role / no Data-API
--         exposure this is NOT auto-CRITICAL — the provider adapter MAY
--         downgrade. The runner asserts only that the OBJECT is *detected* by
--         Q2.1 (it appears in the result set), NOT that it is emitted CRITICAL,
--         because vanilla-context severity is provider-discretionary. Do not
--         assert a Supabase CRITICAL here or it false-fails.
--   D4  RLS enabled + blanket USING(true)     -> Q2.3  -> CRITICAL (qual = 'true'
--         is the unconditional heuristic regardless of provider exposure)
--   D5  SECURITY DEFINER fn, no/mutable
--         search_path                         -> Q2.4  -> HIGH
--   D6  column that is 100% NULL              -> Q1.5  -> MEDIUM
--   D7  PII-named column (email)              -> Q3.1  -> HIGH (only flagged when
--         the column also has an `anon` SELECT grant — see D7 setup; we create
--         the `anon` role and grant it so Q3.1's EXISTS clause matches)
--
-- NOT PLANTED / NOT ASSERTED:
--   Q1.3 (unused index) is GATED on `now() - stats_reset > interval '7 days'`.
--   A fresh Docker container has a stats_reset age of seconds, so Q1.3
--   SELF-SKIPS (emits a single INFO "stats reset within last 7 days"). We do
--   NOT plant or assert an unused-index finding — it cannot fire hermetically.
--
-- The file MUST end with ANALYZE; — Q1.5 (and Q1.6) read pg_stats, which is
-- EMPTY until ANALYZE populates it. Without the trailing ANALYZE the 100%-NULL
-- column is invisible to the query and the assertion false-fails.
-- ===========================================================================

-- Idempotent: drop and recreate the namespaced schema each run.
DROP SCHEMA IF EXISTS dbaudit_test CASCADE;
CREATE SCHEMA dbaudit_test;

-- ---------------------------------------------------------------------------
-- anon role: Q3.1 only flags a PII column when an `anon` role holds SELECT on
-- the table. Vanilla PG has no `anon` role, so we create one to exercise Q3.1.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END
$$;

-- ===========================================================================
-- D1 — table with NO primary key (Q1.1, CRITICAL)
-- Lives in dbaudit_test (Q1.1 scans all non-system schemas).
-- ===========================================================================
CREATE TABLE dbaudit_test.no_pk_table (
  id    integer,
  label text
);

-- ===========================================================================
-- D2 — FK column with NO backing index (Q1.2, HIGH for single-column FK)
-- A parent with a PK, a child whose FK column has no index.
-- ===========================================================================
CREATE TABLE dbaudit_test.fk_parent (
  id integer PRIMARY KEY
);

CREATE TABLE dbaudit_test.fk_child_no_index (
  id        integer PRIMARY KEY,
  parent_id integer REFERENCES dbaudit_test.fk_parent (id)
  -- intentionally NO index on parent_id
);

-- ===========================================================================
-- D3 — table with RLS NOT enabled (Q2.1).
-- Q2.1 scans schema 'public', so plant in public with a dbaudit_ prefix.
-- RLS is OFF by default on a freshly created table; we make it explicit.
-- VANILLA CONTEXT: detected by Q2.1 but NOT auto-CRITICAL (no anon API surface).
-- ===========================================================================
DROP TABLE IF EXISTS public.dbaudit_rls_off CASCADE;
CREATE TABLE public.dbaudit_rls_off (
  id   integer PRIMARY KEY,
  data text
);
ALTER TABLE public.dbaudit_rls_off DISABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- D4 — RLS enabled + blanket USING(true) permissive policy (Q2.3, CRITICAL).
-- Q2.3 scans schema 'public'. qual = 'true' is the blanket-permissive heuristic.
-- ===========================================================================
DROP TABLE IF EXISTS public.dbaudit_rls_blanket CASCADE;
CREATE TABLE public.dbaudit_rls_blanket (
  id   integer PRIMARY KEY,
  data text
);
ALTER TABLE public.dbaudit_rls_blanket ENABLE ROW LEVEL SECURITY;
CREATE POLICY dbaudit_blanket_all
  ON public.dbaudit_rls_blanket
  FOR SELECT
  USING (true);

-- ===========================================================================
-- D5 — SECURITY DEFINER function with NO search_path set (Q2.4, HIGH).
-- proconfig IS NULL because no SET search_path clause is attached.
-- ===========================================================================
CREATE FUNCTION dbaudit_test.secdef_no_searchpath()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
AS $$ SELECT 1 $$;

-- ===========================================================================
-- D6 — column that is 100% NULL (Q1.5, MEDIUM).
-- Q1.5 scans schema 'public' and reads pg_stats.null_frac = 1.0.
-- Insert rows so the column has stats; every value of all_null_col is NULL.
-- ===========================================================================
DROP TABLE IF EXISTS public.dbaudit_null_col CASCADE;
CREATE TABLE public.dbaudit_null_col (
  id           integer PRIMARY KEY,
  all_null_col text
);
INSERT INTO public.dbaudit_null_col (id, all_null_col)
SELECT g, NULL FROM generate_series(1, 50) AS g;

-- ===========================================================================
-- D7 — PII-named column with an anon SELECT grant (Q3.1, HIGH).
-- Q3.1 scans schema 'public', matches the column name regex (email|phone|...),
-- AND requires an `anon` SELECT grant via role_table_grants. We grant it.
-- ===========================================================================
DROP TABLE IF EXISTS public.dbaudit_pii CASCADE;
CREATE TABLE public.dbaudit_pii (
  id    integer PRIMARY KEY,
  email text
);
GRANT SELECT ON public.dbaudit_pii TO anon;

-- ===========================================================================
-- REQUIRED: populate pg_stats. Q1.5/Q1.6 are invisible without this.
-- ===========================================================================
ANALYZE;
