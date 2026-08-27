#!/usr/bin/env bash
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

"${psql_exec[@]}" -Atqc "SELECT aetherlake.healthcheck()" | grep -qx t
"${psql_exec[@]}" -Atqc "SELECT count(*) >= 2 FROM aetherlake.events" | grep -qx t
# The two contract tables plus every container compiled from models/.
"${psql_exec[@]}" -Atqc "SELECT count(*) >= 2 FROM aetherlake.catalog WHERE table_namespace = 'aetherlake'" | grep -qx t
"${psql_exec[@]}" -Atqc "SELECT count(*) > 2 FROM aetherlake.catalog" | grep -qx t
"${psql_exec[@]}" -Atqc "SELECT metadata_location LIKE 's3://%' FROM aetherlake.catalog ORDER BY table_name LIMIT 1" | grep -qx t

"${psql_exec[@]}" <<'SQL'
BEGIN;
INSERT INTO aetherlake.events(tenant_id, event_type, payload)
VALUES (9999, 'rollback.test', '{}');
ROLLBACK;
DO $$
BEGIN
  IF EXISTS (SELECT FROM aetherlake.events WHERE event_type = 'rollback.test') THEN
    RAISE EXCEPTION 'rollback row remained visible';
  END IF;
END
$$;

CALL aetherlake.sync_historical_deltas(10000);
CALL aetherlake.sync_historical_deltas(10000);

DO $$
DECLARE duplicates bigint;
BEGIN
  SELECT count(*) INTO duplicates
  FROM (SELECT event_id FROM aetherlake.event_history GROUP BY event_id HAVING count(*) > 1) d;
  IF duplicates <> 0 THEN
    RAISE EXCEPTION 'delta loop created duplicate history rows';
  END IF;
END
$$;

DO $$
DECLARE metadata jsonb;
BEGIN
  SELECT lake_iceberg.metadata(metadata_location) INTO metadata
  FROM iceberg_tables
  WHERE table_namespace = 'aetherlake' AND table_name = 'events';
  IF metadata::text NOT LIKE '%event_source%' THEN
    RAISE EXCEPTION 'schema evolution not present in Iceberg metadata';
  END IF;
END
$$;
SQL

docker compose exec -T pgduck psql -p 5332 -h /home/postgres/pgduck_socket_dir -Atqc "SELECT 1" | grep -qx 1
docker compose exec -T demo-ui python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz')"
docker compose exec -T demo-ui python -c "import urllib.request; assert urllib.request.urlopen('http://localhost:8080/api/overview').status == 200"

object_count=$(docker compose run --rm --no-deps --entrypoint sh minio-init -c \
  'mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc find "local/$S3_BUCKET" --name "*.parquet" | wc -l')
test "$object_count" -gt 0

echo "Smoke tests passed"
