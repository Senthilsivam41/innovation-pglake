#!/usr/bin/env bash
# The openness claim, made falsifiable: a different engine reads the same bytes and agrees.
#
# The engine is a stock DuckDB (docker/duckdb), pinned by digest, that knows nothing about
# PostgreSQL or pg_lake. It talks only to object storage. If its numbers match, the solution
# view really is in the lake rather than merely backed by it.
#
# Two things this deliberately does NOT do:
#   - use the pgduck sidecar: it is part of this stack, so it proves less; and its custom build
#     cannot install DuckDB's `iceberg` extension anyway.
#   - use read_parquet() over the data directory: that reads every Parquet file present,
#     including ones superseded by copy-on-write DELETE, so it over-counts precisely where the
#     SDM rebuild happens. Only iceberg_scan() honours the current snapshot.
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
: "${AWS_REGION:=us-east-1}"

psql_exec=(docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB")

duckdb_scan() {
  # $1 = Iceberg metadata location, $2 = projection over the scanned table
  docker compose run --rm -T duckdb "
    INSTALL httpfs; LOAD httpfs;
    INSTALL iceberg; LOAD iceberg;
    CREATE SECRET (
      TYPE s3,
      KEY_ID '${AWS_ACCESS_KEY_ID}',
      SECRET '${AWS_SECRET_ACCESS_KEY}',
      REGION '${AWS_REGION}',
      ENDPOINT 'minio:9000',
      URL_STYLE 'path',
      USE_SSL false
    );
    SELECT $2 FROM iceberg_scan('$1');
  " 2>/dev/null | tail -1 | tr -d '\r'
}

metadata=$("${psql_exec[@]}" -Atqc "
  SELECT metadata_location FROM iceberg_tables
   WHERE table_namespace = 'dm_sol_production_analytics'
     AND table_name = 'well_production_daily'")
test -n "$metadata"

pg_rows=$("${psql_exec[@]}" -Atqc \
  "SELECT count(*) FROM dm_sol_production_analytics.well_production_daily")
pg_oil=$("${psql_exec[@]}" -Atqc \
  "SELECT round(sum(oil_bbl)::numeric, 3) FROM dm_sol_production_analytics.well_production_daily")
test "$pg_rows" -gt 0

duck_rows=$(duckdb_scan "$metadata" "count(*)")
duck_oil=$(duckdb_scan "$metadata" "round(sum(oil_bbl)::DECIMAL(18,3), 3)")

if [[ "$pg_rows" != "$duck_rows" ]]; then
  echo "Row count disagrees: PostgreSQL $pg_rows, DuckDB $duck_rows" >&2
  exit 1
fi
if [[ "$pg_oil" != "$duck_oil" ]]; then
  echo "Oil volume disagrees: PostgreSQL $pg_oil, DuckDB $duck_oil" >&2
  exit 1
fi

echo "Openness test passed: a stock DuckDB read $duck_rows rows / $duck_oil bbl straight from"
echo "object storage, with no PostgreSQL in the query path."
