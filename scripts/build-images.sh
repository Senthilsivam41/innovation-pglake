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

: "${PG_LAKE_REF:=01c529dedde75777e09298ae41786d9ae1f337cf}"
: "${PG_MAJOR:=18}"
: "${PG_LAKE_BUILD_JOBS:=2}"
: "${PG_LAKE_POSTGRES_IMAGE:=aetherlake/pg-lake-postgres:01c529d}"
: "${PGDUCK_IMAGE:=aetherlake/pgduck-server:01c529d}"

source_dir="$root/.aetherlake/pg_lake"
mkdir -p "$(dirname "$source_dir")"

if [[ ! -d "$source_dir/.git" ]]; then
  git clone --filter=blob:none https://github.com/Snowflake-Labs/pg_lake.git "$source_dir"
fi

git -C "$source_dir" fetch --depth 1 origin "$PG_LAKE_REF"
git -C "$source_dir" checkout --detach FETCH_HEAD
actual_ref=$(git -C "$source_dir" rev-parse HEAD)
if [[ "$actual_ref" != "$PG_LAKE_REF" ]]; then
  echo "Expected pg_lake $PG_LAKE_REF, resolved $actual_ref" >&2
  exit 1
fi

# Make the project-owned compatibility patch available inside the upstream
# Docker build context. It is applied only to the pinned source checkout.
cp "$root/docker/upstream-spatial-optional.patch" \
  "$source_dir/docker/aetherlake-spatial-optional.patch"

# Upstream's Dockerfile clones its source a second time from `main`. Apply a
# narrow patch so the inner build uses the same immutable commit as this cache.
if git -C "$source_dir" apply --check "$root/docker/upstream-pinned-ref.patch"; then
  git -C "$source_dir" apply "$root/docker/upstream-pinned-ref.patch"
elif ! git -C "$source_dir" apply --reverse --check "$root/docker/upstream-pinned-ref.patch"; then
  echo "Pinned-ref patch no longer applies to upstream Dockerfile" >&2
  exit 1
fi

echo "Building pg_lake PostgreSQL base from $PG_LAKE_REF"
docker build \
  --file "$source_dir/docker/Dockerfile" \
  --target pg_lake_postgres \
  --build-arg "PG_LAKE_REF=$PG_LAKE_REF" \
  --build-arg "PG_MAJOR=$PG_MAJOR" \
  --build-arg "PG_LAKE_BUILD_JOBS=$PG_LAKE_BUILD_JOBS" \
  --tag "$PG_LAKE_POSTGRES_IMAGE" \
  "$source_dir"

echo "Building pgduck_server base from $PG_LAKE_REF"
docker build \
  --file "$source_dir/docker/Dockerfile" \
  --target pgduck_server \
  --build-arg "PG_LAKE_REF=$PG_LAKE_REF" \
  --build-arg "PG_MAJOR=$PG_MAJOR" \
  --build-arg "PG_LAKE_BUILD_JOBS=$PG_LAKE_BUILD_JOBS" \
  --tag "$PGDUCK_IMAGE" \
  "$source_dir"

docker compose build postgres pgduck
