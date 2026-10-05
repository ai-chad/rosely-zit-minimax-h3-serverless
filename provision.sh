#!/usr/bin/env bash
set -Eeuo pipefail

# Unified S3 + credential compatibility wrapper.
# This wrapper makes the new ROSELY_S3_* and AWS_UNIFIED_* variables
# authoritative, so stale/cached Vast AWS/ZiT environment variables cannot
# silently override the deployment.
BASELINE_COMMIT="${ROSELY_PROVISION_BASELINE_COMMIT:-e5afd4e0fe39ff03170a5aaa075b3936b8afd060}"
BASELINE_URL="https://raw.githubusercontent.com/ai-chad/rosely-zit-minimax-h3-serverless/${BASELINE_COMMIT}/provision.sh"
BASELINE_PATH="/tmp/rosely-h3-zit-provision-core.sh"

: "${AWS_UNIFIED_ACCESS_KEY_ID:?AWS_UNIFIED_ACCESS_KEY_ID is required}"
: "${AWS_UNIFIED_SECRET_ACCESS_KEY:?AWS_UNIFIED_SECRET_ACCESS_KEY is required}"
: "${ROSELY_S3_BUCKET:=rosely-infrastructure}"
: "${ROSELY_S3_REGION:=us-east-1}"
: "${ROSELY_PRESIGNED_URL_EXPIRES_SECONDS:=3600}"

# ---------------------------------------------------------------------------
# Make the new unified credentials authoritative.
# This intentionally OVERWRITES any stale AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY cached in the Vast template/base environment.
# ---------------------------------------------------------------------------
export AWS_ACCESS_KEY_ID="$AWS_UNIFIED_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_UNIFIED_SECRET_ACCESS_KEY"

if [[ -n "${AWS_UNIFIED_SESSION_TOKEN:-}" ]]; then
  export AWS_SESSION_TOKEN="$AWS_UNIFIED_SESSION_TOKEN"
else
  unset AWS_SESSION_TOKEN || true
fi

# Prevent old ZiT-specific cached credentials from taking precedence at runtime.
unset AWS_ZIT_IMAGE_MODEL_ACCESS_KEY_ID || true
unset AWS_ZIT_IMAGE_MODEL_SECRET_ACCESS_KEY || true
unset AWS_ZIT_IMAGE_MODEL_SESSION_TOKEN || true
unset AWS_ZIT_IMAGE_ACCESS_KEY_ID || true
unset AWS_ZIT_IMAGE_SECRET_ACCESS_KEY || true
unset AWS_ZIT_IMAGE_SESSION_TOKEN || true
unset ROSELY_ZIT_S3_ACCESS_KEY_ID || true
unset ROSELY_ZIT_S3_SECRET_ACCESS_KEY || true
unset ROSELY_ZIT_S3_SESSION_TOKEN || true

# ---------------------------------------------------------------------------
# Shared bucket/region are authoritative for BOTH H3 and ZiT.
# We overwrite legacy family-specific bucket/region variables so stale values
# cached in Vast cannot point one family at an old bucket.
# ---------------------------------------------------------------------------
export ROSELY_H3_S3_BUCKET="$ROSELY_S3_BUCKET"
export ROSELY_H3_S3_REGION="$ROSELY_S3_REGION"
export ROSELY_H3_S3_ENDPOINT_URL="${ROSELY_S3_ENDPOINT_URL:-}"

export ROSELY_ZIT_MODEL_S3_BUCKET="$ROSELY_S3_BUCKET"
export ROSELY_ZIT_MODEL_S3_REGION="$ROSELY_S3_REGION"
export ROSELY_ZIT_MODEL_S3_ENDPOINT_URL="${ROSELY_S3_ENDPOINT_URL:-}"

export ROSELY_H3_OUTPUT_BUCKET="$ROSELY_S3_BUCKET"
export ROSELY_ZIT_OUTPUT_BUCKET="$ROSELY_S3_BUCKET"
export ROSELY_ZIT_S3_REGION="$ROSELY_S3_REGION"
export ROSELY_ZIT_S3_ENDPOINT_URL="${ROSELY_S3_ENDPOINT_URL:-}"

export ROSELY_COMBINED_S3_BUCKET="$ROSELY_S3_BUCKET"
export ROSELY_COMBINED_S3_REGION="$ROSELY_S3_REGION"
export ROSELY_COMBINED_S3_ENDPOINT_URL="${ROSELY_S3_ENDPOINT_URL:-}"

export ROSELY_H3_PRESIGNED_URL_EXPIRES_SECONDS="$ROSELY_PRESIGNED_URL_EXPIRES_SECONDS"
export ROSELY_ZIT_PRESIGNED_URL_EXPIRES_SECONDS="$ROSELY_PRESIGNED_URL_EXPIRES_SECONDS"

# ---------------------------------------------------------------------------
# New concise model-key names -> legacy names consumed by the pinned core.
# The H3 and ZiT objects remain separate keys inside the same shared bucket.
# ---------------------------------------------------------------------------
export ROSELY_H3_S3_MODEL_KEY="${ROSELY_H3_MODEL_KEY:-models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst}"
export ROSELY_H3_S3_CHECKSUM_KEY="${ROSELY_H3_MODEL_CHECKSUM_KEY:-models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst.sha256}"

export ROSELY_ZIT_MODEL_S3_KEY="${ROSELY_ZIT_MODEL_KEY:-serverless/zimage/zenith13/zenith13-mxfp8-full-detailer-seedvr2-v3.tar.zst}"

if [[ -n "${ROSELY_COMBINED_MODEL_KEY:-}" ]]; then
  export ROSELY_COMBINED_S3_MODEL_KEY="$ROSELY_COMBINED_MODEL_KEY"
fi
if [[ -n "${ROSELY_COMBINED_MODEL_CHECKSUM_KEY:-}" ]]; then
  export ROSELY_COMBINED_S3_CHECKSUM_KEY="$ROSELY_COMBINED_MODEL_CHECKSUM_KEY"
fi

echo "[Rosely H3+ZiT] shared S3 bucket=${ROSELY_S3_BUCKET} region=${ROSELY_S3_REGION}"
echo "[Rosely H3+ZiT] unified credentials active; legacy cached credential aliases disabled"
echo "[Rosely H3+ZiT] loading pinned provisioning core ${BASELINE_COMMIT}"

command -v curl >/dev/null 2>&1 || {
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl ca-certificates
}

curl --fail --location --silent --show-error "$BASELINE_URL" --output "$BASELINE_PATH"
chmod 0755 "$BASELINE_PATH"

exec bash "$BASELINE_PATH"
