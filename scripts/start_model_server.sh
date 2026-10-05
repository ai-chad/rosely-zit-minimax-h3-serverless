#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /var/log/portal
: > /var/log/portal/model-server.log

: "${AWS_UNIFIED_ACCESS_KEY_ID:?AWS_UNIFIED_ACCESS_KEY_ID is required}"
: "${AWS_UNIFIED_SECRET_ACCESS_KEY:?AWS_UNIFIED_SECRET_ACCESS_KEY is required}"
: "${ROSELY_S3_BUCKET:=rosely-infrastructure}"
: "${ROSELY_S3_REGION:=us-east-1}"
: "${ROSELY_PRESIGNED_URL_EXPIRES_SECONDS:=3600}"

# Force boto3 to use the new unified credentials even if Vast injects stale
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY values.
export AWS_ACCESS_KEY_ID="$AWS_UNIFIED_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_UNIFIED_SECRET_ACCESS_KEY"

if [[ -n "${AWS_UNIFIED_SESSION_TOKEN:-}" ]]; then
  export AWS_SESSION_TOKEN="$AWS_UNIFIED_SESSION_TOKEN"
else
  unset AWS_SESSION_TOKEN || true
fi

# model_server.py historically supports ZiT-specific credential aliases.
# Remove them so they cannot override the unified boto3 credential chain.
unset AWS_ZIT_IMAGE_ACCESS_KEY_ID || true
unset AWS_ZIT_IMAGE_SECRET_ACCESS_KEY || true
unset AWS_ZIT_IMAGE_SESSION_TOKEN || true
unset ROSELY_ZIT_S3_ACCESS_KEY_ID || true
unset ROSELY_ZIT_S3_SECRET_ACCESS_KEY || true
unset ROSELY_ZIT_S3_SESSION_TOKEN || true

# Force both output families onto the one shared bucket/region.
export ROSELY_H3_OUTPUT_BUCKET="$ROSELY_S3_BUCKET"
export ROSELY_ZIT_OUTPUT_BUCKET="$ROSELY_S3_BUCKET"
export ROSELY_H3_S3_BUCKET="$ROSELY_S3_BUCKET"
export ROSELY_H3_S3_REGION="$ROSELY_S3_REGION"
export ROSELY_ZIT_S3_REGION="$ROSELY_S3_REGION"

export ROSELY_H3_S3_ENDPOINT_URL="${ROSELY_S3_ENDPOINT_URL:-}"
export ROSELY_ZIT_S3_ENDPOINT_URL="${ROSELY_S3_ENDPOINT_URL:-}"

export ROSELY_H3_PRESIGNED_URL_EXPIRES_SECONDS="$ROSELY_PRESIGNED_URL_EXPIRES_SECONDS"
export ROSELY_ZIT_PRESIGNED_URL_EXPIRES_SECONDS="$ROSELY_PRESIGNED_URL_EXPIRES_SECONDS"

source /venv/main/bin/activate
cd /workspace/vast-pyworker

set -o pipefail
python -m uvicorn model_server:app \
  --host 127.0.0.1 \
  --port 18288 \
  --workers 1 \
  2>&1 | tee -a /var/log/portal/model-server.log
