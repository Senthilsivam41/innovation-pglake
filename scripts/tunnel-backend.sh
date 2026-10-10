#!/usr/bin/env bash
set -Eeuo pipefail

port="${DEMO_UI_PORT:-8080}"

exec cloudflared tunnel --url "http://localhost:${port}" --no-autoupdate --loglevel info
