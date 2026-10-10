#!/bin/sh
set -eu

alias_name=local
mc alias set "$alias_name" http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
mc mb --ignore-existing "$alias_name/$S3_BUCKET"

# Local parity with the production requirement. MinIO encrypts with its KMS
# when configured; this command is intentionally best-effort in a KMS-less lab.
if [ -n "${MINIO_KMS_SECRET_KEY:-}" ]; then
  mc encrypt set sse-s3 "$alias_name/$S3_BUCKET"
fi

mc anonymous set none "$alias_name/$S3_BUCKET"
mc admin user add "$alias_name" "$SPARK_S3_ACCESS_KEY_ID" "$SPARK_S3_SECRET_ACCESS_KEY"
printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::%s"],"Condition":{"StringLike":{"s3:prefix":["%s/*"]}}},{"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::%s/%s/*"]}]}' \
  "$S3_BUCKET" "$S3_PREFIX" "$S3_BUCKET" "$S3_PREFIX" | \
  mc admin policy create "$alias_name" aetherlake-spark-read /dev/stdin
mc admin policy attach "$alias_name" aetherlake-spark-read --user "$SPARK_S3_ACCESS_KEY_ID"
echo "MinIO bucket ready: s3://$S3_BUCKET"
