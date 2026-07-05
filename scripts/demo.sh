#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from safe local defaults. Change passwords before any non-local deployment."
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${PG_LAKE_POSTGRES_IMAGE:=aetherlake/pg-lake-postgres:01c529d}"
: "${PGDUCK_IMAGE:=aetherlake/pgduck-server:01c529d}"
: "${DEMO_UI_PORT:=8080}"

if ! docker image inspect "$PG_LAKE_POSTGRES_IMAGE" >/dev/null 2>&1 || \
   ! docker image inspect "$PGDUCK_IMAGE" >/dev/null 2>&1; then
  echo "First run: compiling pinned pg_lake base images. This can take 20–60 minutes."
  ./scripts/build-images.sh
fi

docker compose up -d --build
./scripts/wait-healthy.sh 600

echo
echo "AetherLake stakeholder demo is ready: http://localhost:$DEMO_UI_PORT"
echo "MinIO console: http://localhost:${MINIO_CONSOLE_PORT:-9001}"

