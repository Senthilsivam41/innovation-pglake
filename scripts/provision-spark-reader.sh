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
: "${POSTGRES_USER:=aetherlake_admin}"
: "${SPARK_READER_PASSWORD:=change-me-spark-local-only}"

docker compose exec -T -e SPARK_READER_PASSWORD="$SPARK_READER_PASSWORD" postgres \
  psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  < docker/postgres/init/07-spark-reader.sql
bash tests/spark-reader.sh
