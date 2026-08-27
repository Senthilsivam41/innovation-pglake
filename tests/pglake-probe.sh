#!/usr/bin/env bash
# Capability probe for the pinned pg_lake build.
#
# The semantic layer's type map, the SDM job's idempotency and the openness proof all assume
# behaviour that upstream documents but this pinned build has never been checked for. Each
# probe reports rather than aborts, so one run tells you everything that needs a fallback.
#
# Read the output as a gate: anything reporting FAIL has a documented fallback in the plan.
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${POSTGRES_DB:=aetherlake}"
: "${POSTGRES_USER:=aetherlake_admin}"

psql_exec=(docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB")
duck_exec=(docker compose exec -T pgduck psql -p 5332 -h /home/postgres/pgduck_socket_dir -X -Atq)

"${psql_exec[@]}" -q <<'SQL'
CREATE SCHEMA IF NOT EXISTS probe;

-- Reports one line per probe as "S<n> <PASS|FAIL> <detail>" without aborting the run.
CREATE OR REPLACE PROCEDURE probe.report(p_id text, p_what text, p_sql text)
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RAISE NOTICE '% PASS %', p_id, p_what;
EXCEPTION WHEN others THEN
    RAISE NOTICE '% FAIL % -- %', p_id, p_what, replace(SQLERRM, E'\n', ' ');
END
$$;
SQL

echo "== S1: column types on USING iceberg =="
"${psql_exec[@]}" <<'SQL' 2>&1 | grep -E "^(NOTICE|psql:)" | sed 's/^NOTICE:  //'
DROP TABLE IF EXISTS probe.types;
CALL probe.report('S1.text[]',      'text[] column',           $$CREATE TABLE probe.t_arr (a text[]) USING iceberg$$);
CALL probe.report('S1.date',        'date column',             $$CREATE TABLE probe.t_date (a date) USING iceberg$$);
CALL probe.report('S1.timestamptz', 'timestamptz column',      $$CREATE TABLE probe.t_ts (a timestamptz) USING iceberg$$);
CALL probe.report('S1.float8',      'double precision column', $$CREATE TABLE probe.t_f8 (a double precision) USING iceberg$$);
CALL probe.report('S1.jsonb',       'jsonb column',            $$CREATE TABLE probe.t_js (a jsonb) USING iceberg$$);
CALL probe.report('S1.int64',       'bigint column',           $$CREATE TABLE probe.t_i8 (a bigint) USING iceberg$$);
CALL probe.report('S1.arr_rt',      'text[] round trip',
    $$INSERT INTO probe.t_arr VALUES (ARRAY['a','b']); PERFORM 1 FROM probe.t_arr WHERE a @> ARRAY['a']$$);
SQL

echo
echo "== S2: DML on USING iceberg (MERGE and ON CONFLICT are known-unsupported) =="
"${psql_exec[@]}" <<'SQL' 2>&1 | grep -E "^NOTICE" | sed 's/^NOTICE:  //'
DROP TABLE IF EXISTS probe.dml;
CREATE TABLE probe.dml (k int, v text) USING iceberg;
INSERT INTO probe.dml VALUES (1, 'a'), (2, 'b');
CALL probe.report('S2.delete',   'DELETE ... WHERE',  $$DELETE FROM probe.dml WHERE k = 1$$);
CALL probe.report('S2.update',   'UPDATE ... SET',    $$UPDATE probe.dml SET v = 'c' WHERE k = 2$$);
CALL probe.report('S2.truncate', 'TRUNCATE',          $$TRUNCATE probe.dml$$);
CALL probe.report('S2.ctas',     'CREATE TABLE AS',   $$CREATE TABLE probe.ctas USING iceberg AS SELECT 1 AS k$$);
CALL probe.report('S2.rename',   'ALTER TABLE RENAME',$$ALTER TABLE probe.dml RENAME TO dml_renamed$$);
SQL

echo
echo "== S6: Iceberg snapshot id is readable and advances =="
"${psql_exec[@]}" -Atq <<'SQL'
DO $$
DECLARE before_id bigint; after_id bigint;
BEGIN
    CREATE TABLE IF NOT EXISTS probe.snap (k int) USING iceberg;
    INSERT INTO probe.snap VALUES (1);
    SELECT semantic.snapshot_id('probe.snap') INTO before_id;
    INSERT INTO probe.snap VALUES (2);
    SELECT semantic.snapshot_id('probe.snap') INTO after_id;
    IF before_id IS NULL THEN
        RAISE NOTICE 'S6 FAIL current-snapshot-id is null; fall back to snapshots->-1';
    ELSIF before_id = after_id THEN
        RAISE NOTICE 'S6 PARTIAL snapshot id % did not advance in-transaction; report it as snapshotIdAtPlanTime', before_id;
    ELSE
        RAISE NOTICE 'S6 PASS snapshot advanced % -> %', before_id, after_id;
    END IF;
END
$$;
SQL

echo
echo "== S4/S5: predicate pushdown through a compiled view =="
"${psql_exec[@]}" -Atqc "
  EXPLAIN (VERBOSE, COSTS OFF)
  SELECT node_external_id FROM dm_dom_well_production.asset_v1
   WHERE well_type = 'producer'" 2>&1 | sed 's/^/    /'

echo
echo "== S3: does the pgduck sidecar expose iceberg_scan()? =="
metadata=$("${psql_exec[@]}" -Atqc "
  SELECT metadata_location FROM iceberg_tables
   WHERE table_namespace = 'dm_dom_well_production' AND table_name = 'asset'" 2>/dev/null || true)
if [[ -z "$metadata" ]]; then
  echo "    S3 SKIP the asset table has no Iceberg metadata yet"
elif "${duck_exec[@]}" -c "SELECT count(*) FROM iceberg_scan('$metadata')" >/dev/null 2>&1; then
  echo "    S3 PASS iceberg_scan() works over the sidecar socket"
else
  echo "    S3 FAIL iceberg_scan() unavailable; fall back to read_parquet() and ship a duckdb CLI service"
fi

"${psql_exec[@]}" -qc "DROP SCHEMA probe CASCADE" >/dev/null 2>&1 || true
echo
echo "Probe complete. Every FAIL has a documented fallback in the implementation plan."
