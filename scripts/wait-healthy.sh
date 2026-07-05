#!/usr/bin/env bash
set -Eeuo pipefail

timeout=${1:-300}
deadline=$((SECONDS + timeout))

while (( SECONDS < deadline )); do
  postgres_state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' aetherlake-postgres-1 2>/dev/null || true)
  pgduck_state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' aetherlake-pgduck-1 2>/dev/null || true)
  ui_state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' aetherlake-demo-ui-1 2>/dev/null || true)
  if [[ "$postgres_state" == healthy && "$pgduck_state" == healthy && "$ui_state" == healthy ]]; then
    echo "AetherLake is healthy"
    exit 0
  fi
  sleep 3
done

docker compose ps
docker compose logs --tail=100 postgres pgduck minio demo-ui
echo "AetherLake did not become healthy within ${timeout}s" >&2
exit 1
