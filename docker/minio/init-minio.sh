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
echo "MinIO bucket ready: s3://$S3_BUCKET"

