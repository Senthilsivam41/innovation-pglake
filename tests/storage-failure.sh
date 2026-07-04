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

before=$("${psql_exec[@]}" -Atqc "SELECT count(*) FROM aetherlake.events")
metadata_before=$("${psql_exec[@]}" -Atqc "SELECT metadata_location FROM iceberg_tables WHERE table_namespace='aetherlake' AND table_name='events'")

docker compose stop minio
set +e
"${psql_exec[@]}" -qc "INSERT INTO aetherlake.events(tenant_id,event_type,payload) VALUES (7777,'storage.failure','{}')"
insert_status=$?
set -e
docker compose start minio

if [[ $insert_status -eq 0 ]]; then
  echo "Expected an Iceberg write to fail while MinIO was stopped" >&2
  exit 1
fi

./scripts/wait-healthy.sh 180
after=$("${psql_exec[@]}" -Atqc "SELECT count(*) FROM aetherlake.events")
metadata_after=$("${psql_exec[@]}" -Atqc "SELECT metadata_location FROM iceberg_tables WHERE table_namespace='aetherlake' AND table_name='events'")

test "$before" = "$after"
test "$metadata_before" = "$metadata_after"
"${psql_exec[@]}" -Atqc "SELECT count(*) FROM aetherlake.events WHERE event_type='storage.failure'" | grep -qx 0

echo "Storage failure rollback test passed"

