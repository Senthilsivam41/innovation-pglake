#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
: "${POSTGRES_DB:=aetherlake}"
: "${SPARK_READER_PASSWORD:=change-me-spark-local-only}"

query="SELECT current_user = 'aetherlake_spark_reader'
  AND has_table_privilege(current_user, 'pg_catalog.iceberg_tables', 'SELECT')
  AND has_table_privilege(current_user, 'pg_catalog.iceberg_namespace_properties', 'SELECT')
  AND has_table_privilege(current_user, 'aetherlake.events', 'SELECT')
  AND NOT has_table_privilege(current_user, 'aetherlake.events', 'INSERT,UPDATE,DELETE')
  AND NOT has_schema_privilege(current_user, 'aetherlake', 'CREATE')
  AND EXISTS (SELECT 1 FROM iceberg_tables WHERE table_namespace='aetherlake' AND table_name='events')"

docker compose exec -T -e PGPASSWORD="$SPARK_READER_PASSWORD" postgres \
  psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U aetherlake_spark_reader -d "$POSTGRES_DB" \
  -Atqc "$query" | grep -qx t
echo 'Spark catalog reader privileges: passed'
