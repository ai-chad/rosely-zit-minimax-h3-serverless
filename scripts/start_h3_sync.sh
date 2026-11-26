#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p /var/log/portal
: > /var/log/portal/h3-model-sync.log

if [[ -f /opt/rosely-h3-zit-serverless/runtime.env ]]; then
  # shellcheck disable=SC1091
  source /opt/rosely-h3-zit-serverless/runtime.env
fi

: "${AWS_UNIFIED_ACCESS_KEY_ID:?AWS_UNIFIED_ACCESS_KEY_ID is required}"
: "${AWS_UNIFIED_SECRET_ACCESS_KEY:?AWS_UNIFIED_SECRET_ACCESS_KEY is required}"
: "${ROSELY_S3_BUCKET:=rosely-infrastructure}"
: "${ROSELY_S3_REGION:=us-east-1}"

export AWS_ACCESS_KEY_ID="$AWS_UNIFIED_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_UNIFIED_SECRET_ACCESS_KEY"

if [[ -n "${AWS_UNIFIED_SESSION_TOKEN:-}" ]]; then
  export AWS_SESSION_TOKEN="$AWS_UNIFIED_SESSION_TOKEN"
else
  unset AWS_SESSION_TOKEN || true
fi

APP_DIR="${APP_DIR:-/workspace/vast-pyworker}"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
STATE_DIR="${STATE_DIR:-/workspace/.rosely-h3-zit}"

H3_BUCKET="${ROSELY_H3_S3_BUCKET:-$ROSELY_S3_BUCKET}"
H3_REGION="${ROSELY_H3_S3_REGION:-$ROSELY_S3_REGION}"
H3_ENDPOINT="${ROSELY_H3_S3_ENDPOINT_URL:-${ROSELY_S3_ENDPOINT_URL:-}}"
H3_MODEL_KEY="${ROSELY_H3_MODEL_KEY:-${ROSELY_H3_S3_MODEL_KEY:-models/minimax-h3/beta7_sulpher3/manifest.json}}"
H3_CHECKSUM_KEY="${ROSELY_H3_MODEL_CHECKSUM_KEY:-${ROSELY_H3_S3_CHECKSUM_KEY:-${H3_MODEL_KEY}.sha256}}"
H3_EXPECTED_SHA="${ROSELY_H3_EXPECTED_SHA256:-}"
DOWNLOAD_CONCURRENCY="${ROSELY_MODEL_DOWNLOAD_CONCURRENCY:-16}"
DOWNLOAD_CHUNK_MIB="${ROSELY_MODEL_DOWNLOAD_CHUNK_MIB:-32}"
H3_FILE_WORKERS="${ROSELY_H3_FILE_WORKERS:-3}"

source /venv/main/bin/activate
cd "$APP_DIR"

set -o pipefail
python -u "$APP_DIR/scripts/sync_models.py" \
  --family h3 \
  --bucket "$H3_BUCKET" \
  --model-key "$H3_MODEL_KEY" \
  --checksum-key "$H3_CHECKSUM_KEY" \
  --expected-sha256 "$H3_EXPECTED_SHA" \
  --region "$H3_REGION" \
  --endpoint-url "$H3_ENDPOINT" \
  --comfy-dir "$COMFY_DIR" \
  --state-dir "$STATE_DIR" \
  --concurrency "$DOWNLOAD_CONCURRENCY" \
  --chunk-mib "$DOWNLOAD_CHUNK_MIB" \
  --file-workers "$H3_FILE_WORKERS" \
  --retries 5 \
  2>&1 | tee -a /var/log/portal/h3-model-sync.log
