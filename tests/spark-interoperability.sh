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
probe="spark_probe_$(date +%s)_$$"

psql_admin() {
  docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v probe="$probe" "$@"
}

cleanup() {
  psql_admin -Atqc "DROP TABLE IF EXISTS aetherlake.$probe" >/dev/null
}
trap cleanup EXIT

docker compose run --rm minio-init >/dev/null
bash scripts/provision-spark-reader.sh
# shellcheck disable=SC2016
docker compose run --rm --no-deps -e SPARK_PROBE="$probe" --entrypoint sh minio-init -c '
  mc alias set reader http://minio:9000 "$SPARK_S3_ACCESS_KEY_ID" "$SPARK_S3_SECRET_ACCESS_KEY" >/dev/null
  if printf x | mc pipe "reader/$S3_BUCKET/$S3_PREFIX/$SPARK_PROBE-denied" >/dev/null 2>&1; then
    mc alias set root http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    mc rm "root/$S3_BUCKET/$S3_PREFIX/$SPARK_PROBE-denied" >/dev/null
    exit 1
  fi
' >/dev/null
echo 'Spark object-store write denial: passed'
psql_admin <<'SQL'
CREATE TABLE aetherlake.:"probe" (id bigint NOT NULL, message text NOT NULL) USING iceberg;
GRANT SELECT ON aetherlake.:"probe" TO aetherlake_spark_reader;
INSERT INTO aetherlake.:"probe" VALUES (1, 'before');
SQL

snapshot=$(psql_admin -Atqc "SELECT lake_iceberg.metadata(metadata_location)->>'current-snapshot-id' FROM iceberg_tables WHERE table_namespace='aetherlake' AND table_name='$probe'")
[[ "$snapshot" =~ ^[0-9]+$ ]]

spark_check() {
  docker compose run --rm --no-deps spark-verify \
    --packages org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.9.2,org.apache.iceberg:iceberg-aws-bundle:1.9.2,org.postgresql:postgresql:42.7.7 \
    --conf spark.jars.ivy=/tmp/.ivy2 \
    /opt/spark/work-dir/spark_interop.py "$1" "$probe" "$snapshot"
}

spark_check baseline
psql_admin <<'SQL'
ALTER TABLE aetherlake.:"probe" ADD COLUMN source text;
ALTER TABLE aetherlake.:"probe" RENAME COLUMN source TO event_source;
INSERT INTO aetherlake.:"probe" (id, message, event_source) VALUES (2, 'after', 'postgres');
SQL
spark_check evolved
echo 'Independent Spark interoperability: passed'
