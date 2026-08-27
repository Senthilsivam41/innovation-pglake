#!/usr/bin/env bash
# The analytical job must be idempotent, must genuinely rewrite Iceberg, and must not let the
# denormalised copies drift from the enterprise model they were derived from.
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

sdm_rows() {
  "${psql_exec[@]}" -Atqc "SELECT count(*) FROM dm_sol_production_analytics.well_production_daily"
}
sdm_snapshot() {
  "${psql_exec[@]}" -Atqc \
    "SELECT semantic.snapshot_id('dm_sol_production_analytics.well_production_daily')"
}

"${psql_exec[@]}" -qc "CALL aetherlake.build_well_production_daily()"
first_rows=$(sdm_rows)
first_snap=$(sdm_snapshot)

"${psql_exec[@]}" -qc "CALL aetherlake.build_well_production_daily()"
second_rows=$(sdm_rows)
second_snap=$(sdm_snapshot)

# Idempotent: rerunning the same window must not duplicate a single row ...
test "$first_rows" = "$second_rows"
# ... but it must still have rewritten the table, or nothing was actually rebuilt.
test "$first_snap" != "$second_snap"
test "$first_rows" -gt 0

"${psql_exec[@]}" <<'SQL'
DO $$
DECLARE duplicates bigint;
BEGIN
    SELECT count(*) INTO duplicates FROM (
        SELECT node_external_id
          FROM dm_sol_production_analytics.well_production_daily
         GROUP BY node_external_id HAVING count(*) > 1) d;
    IF duplicates <> 0 THEN
        RAISE EXCEPTION 'SDM build produced % duplicated daily rows', duplicates;
    END IF;
END
$$;

DO $$
BEGIN
    -- The load-bearing assertion. wellName and fieldName are denormalised copies, which is
    -- only defensible because they are derived and never authored: the build recomputes them
    -- every run, so drift is bounded by one build interval and caught here.
    IF EXISTS (
        SELECT 1
          FROM dm_sol_production_analytics.well_production_daily_v1 d
          JOIN dm_dom_well_production.asset_v1 wb ON wb.node_external_id = d.wellbore
          JOIN dm_dom_well_production.asset_v1 w  ON w.node_external_id  = wb.parent
          JOIN dm_dom_well_production.asset_v1 f  ON f.node_external_id  = w.parent
         WHERE d.well_name IS DISTINCT FROM w.name
            OR d.field_name IS DISTINCT FROM f.name
            OR d.well IS DISTINCT FROM w.node_external_id
            OR d.field IS DISTINCT FROM f.node_external_id
    ) THEN
        RAISE EXCEPTION 'denormalised context drifted from the enterprise model';
    END IF;
END
$$;

DO $$
DECLARE latest aetherlake.sdm_build_log;
DECLARE closed aetherlake.sdm_build_log;
BEGIN
    SELECT * INTO latest FROM aetherlake.sdm_build_log ORDER BY build_id DESC LIMIT 1;
    IF latest.rows_written = 0 THEN
        RAISE EXCEPTION 'lineage recorded a build that wrote nothing';
    END IF;
    IF latest.source_snapshots = '{}'::jsonb OR cardinality(latest.source_views) = 0 THEN
        RAISE EXCEPTION 'lineage did not record which sources the build read';
    END IF;

    -- pg_lake publishes the Iceberg snapshot at COMMIT, so a build cannot observe its own
    -- result; each run closes out the previous one instead. The second run above must
    -- therefore have closed the first, and closed it to a *different* snapshot - which is
    -- what proves the rebuild really rewrote the table rather than no-opping.
    SELECT * INTO closed FROM aetherlake.sdm_build_log
     WHERE build_id < latest.build_id ORDER BY build_id DESC LIMIT 1;
    IF closed.build_id IS NULL THEN
        RAISE EXCEPTION 'expected at least two builds in the lineage log';
    END IF;
    IF closed.snapshot_after IS NULL THEN
        RAISE EXCEPTION 'build % was never closed out by the run that followed it', closed.build_id;
    END IF;
    IF closed.snapshot_after IS NOT DISTINCT FROM closed.snapshot_before THEN
        RAISE EXCEPTION 'build % did not advance the Iceberg snapshot', closed.build_id;
    END IF;
END
$$;

DO $$
DECLARE with_intervention bigint;
BEGIN
    -- interventionCount can only come from traversing the enterprise graph, so a non-zero
    -- count proves the job consumed the semantic layer rather than just the record store.
    SELECT count(*) INTO with_intervention
      FROM dm_sol_production_analytics.well_production_daily
     WHERE intervention_count > 0;
    IF with_intervention = 0 THEN
        RAISE EXCEPTION 'no daily row picked up an intervention; the graph traversal did not run';
    END IF;
END
$$;
SQL

echo "SDM job tests passed ($first_rows daily rows, snapshot $first_snap -> $second_snap)"
