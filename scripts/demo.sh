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

if command -v cloudflared >/dev/null 2>&1; then
  tunnel_log="$(mktemp /tmp/aetherlake-tunnel.XXXXXX.log)"
  tunnel_pid=""
  trap '[[ -z "${tunnel_pid:-}" ]] || kill "$tunnel_pid" 2>/dev/null || true; rm -f "$tunnel_log"' EXIT INT TERM
  ./scripts/tunnel-backend.sh >"$tunnel_log" 2>&1 &
  tunnel_pid=$!
  tunnel_url=""
  for _ in {1..30}; do
    tunnel_url="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$tunnel_log" | head -n 1 || true)"
    [[ -n "$tunnel_url" ]] && break
    sleep 1
  done
  if [[ -n "$tunnel_url" ]]; then
    echo "Public backend tunnel: $tunnel_url"
    echo "Set Netlify API_BASE_URL to this URL, then redeploy."
  else
    echo "Tunnel started, but its public URL was not detected; see $tunnel_log"
  fi
  echo "Press Ctrl-C to stop the demo and tunnel."
  wait "$tunnel_pid"
else
  echo "cloudflared not installed; using local-only mode."
fi
