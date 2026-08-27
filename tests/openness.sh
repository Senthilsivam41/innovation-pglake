#!/usr/bin/env bash
# The openness claim, made falsifiable: a different engine reads the same bytes.
#
# pgduck_server is a separate DuckDB process reachable only over its own Unix socket. A query
# issued there never enters PostgreSQL or pg_lake - it goes straight to object storage. If the
# numbers match, the SDM view really is in the lake rather than merely backed by it.
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

metadata=$("${psql_exec[@]}" -Atqc "
  SELECT metadata_location FROM iceberg_tables
   WHERE table_namespace = 'dm_sol_production_analytics'
     AND table_name = 'well_production_daily'")
test -n "$metadata"

pg_oil=$("${psql_exec[@]}" -Atqc "
  SELECT round(sum(oil_bbl)::numeric, 3) FROM dm_sol_production_analytics.well_production_daily")
test -n "$pg_oil"

duck_oil=$("${duck_exec[@]}" -c "
  SELECT round(sum(oil_bbl)::numeric, 3) FROM iceberg_scan('$metadata')")

test "$pg_oil" = "$duck_oil"

echo "Openness test passed: DuckDB read $duck_oil bbl from object storage with no PostgreSQL in the query path"
