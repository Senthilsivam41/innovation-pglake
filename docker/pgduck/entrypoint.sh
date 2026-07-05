#!/usr/bin/env bash
set -Eeuo pipefail

: "${PG_MAJOR:=18}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${AWS_REGION:=us-east-1}"
: "${S3_ENDPOINT:=https://s3.amazonaws.com}"
: "${S3_PATH_STYLE:=false}"
: "${S3_USE_SSL:=true}"

base=/home/postgres
socket_dir="$base/pgduck_socket_dir"
tmp_dir="$base/pgsql-$PG_MAJOR/data/base/pgsql_tmp"
init_file=/tmp/aetherlake-pgduck-init.sql
endpoint_host=${S3_ENDPOINT#http://}
endpoint_host=${endpoint_host#https://}
url_style=vhost
[[ "$S3_PATH_STYLE" == "true" ]] && url_style=path

sudo mkdir -p "$socket_dir" "$tmp_dir" "$base/cache"
sudo chown -R postgres:postgres "$socket_dir" "$tmp_dir" "$base/cache"
sudo chmod 0700 "$socket_dir" "$tmp_dir" "$base/cache"

sed \
  -e "s|__S3_BUCKET__|$S3_BUCKET|g" \
  -e "s|__AWS_ACCESS_KEY_ID__|$AWS_ACCESS_KEY_ID|g" \
  -e "s|__AWS_SECRET_ACCESS_KEY__|$AWS_SECRET_ACCESS_KEY|g" \
  -e "s|__AWS_REGION__|$AWS_REGION|g" \
  -e "s|__S3_ENDPOINT_HOST__|$endpoint_host|g" \
  -e "s|__S3_URL_STYLE__|$url_style|g" \
  -e "s|__S3_USE_SSL__|$S3_USE_SSL|g" \
  /etc/aetherlake/init.sql.template > "$init_file"
chmod 0600 "$init_file"

exec "$base/pgsql-$PG_MAJOR/bin/pgduck_server" \
  --cache_dir "$base/cache" \
  --unix_socket_directory "$socket_dir" \
  --unix_socket_group postgres \
  --port 5332 \
  --init_file_path "$init_file"
