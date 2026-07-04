#!/usr/bin/env bash
set -Eeuo pipefail

: "${PG_MAJOR:=18}"
: "${POSTGRES_DB:=aetherlake}"
: "${POSTGRES_USER:=aetherlake_admin}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${APP_USER:=aetherlake_app}"
: "${APP_PASSWORD:?APP_PASSWORD is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_PREFIX:=warehouse}"
: "${DELTA_CRON:=*/5 * * * *}"
: "${VACUUM_CRON:=17 * * * *}"
: "${DELTA_BATCH_SIZE:=10000}"

base=/home/postgres
pg_bin="$base/pgsql-$PG_MAJOR/bin"
pgdata="$base/pgsql-$PG_MAJOR/data"
socket_dir="$base/pgduck_socket_dir"
marker="$pgdata/.aetherlake-initialized"

mkdir -p "$pgdata/base/pgsql_tmp" "$socket_dir"
chmod 0700 "$pgdata/base/pgsql_tmp" "$socket_dir"

cat > "$pgdata/aetherlake.conf" <<EOF
listen_addresses = '*'
port = 5432
password_encryption = 'scram-sha-256'
shared_preload_libraries = 'pg_extension_base,pg_cron'
cron.database_name = '$POSTGRES_DB'
pg_lake_engine.host = 'host=$socket_dir port=5332'
pg_lake_iceberg.default_location_prefix = 's3://$S3_BUCKET/$S3_PREFIX/'
EOF

grep -q "aetherlake.conf" "$pgdata/postgresql.conf" || \
  printf "\ninclude = 'aetherlake.conf'\n" >> "$pgdata/postgresql.conf"

cat > "$pgdata/pg_hba.conf" <<'EOF'
local all all trust
host all all 127.0.0.1/32 scram-sha-256
host all all ::1/128 scram-sha-256
host all all 0.0.0.0/0 scram-sha-256
EOF

shutdown() {
  "$pg_bin/pg_ctl" -D "$pgdata" -m fast stop >/dev/null 2>&1 || true
}
trap shutdown TERM INT

if [[ ! -f "$marker" ]]; then
  "$pg_bin/pg_ctl" -D "$pgdata" -w start

  "$pg_bin/psql" -v ON_ERROR_STOP=1 -U postgres -d postgres \
    --set=admin_user="$POSTGRES_USER" \
    --set=admin_password="$POSTGRES_PASSWORD" \
    --set=database_name="$POSTGRES_DB" \
    --set=app_user="$APP_USER" \
    --set=app_password="$APP_PASSWORD" \
    -f /docker-entrypoint-initdb.d/00-bootstrap.sql

  for sql in /docker-entrypoint-initdb.d/[0-9][1-9]-*.sql; do
    "$pg_bin/psql" -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      --set=app_user="$APP_USER" \
      --set=delta_cron="$DELTA_CRON" \
      --set=vacuum_cron="$VACUUM_CRON" \
      --set=delta_batch_size="$DELTA_BATCH_SIZE" \
      -f "$sql"
  done

  touch "$marker"
  "$pg_bin/pg_ctl" -D "$pgdata" -m fast -w stop
fi

exec "$pg_bin/postgres" -D "$pgdata"

