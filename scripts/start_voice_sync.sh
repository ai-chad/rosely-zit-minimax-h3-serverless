#!/usr/bin/env bash
set -Eeuo pipefail

# Background Phase 2 bootstrap for Rosely Voice Avatar (Qwen3-ASR + Chatterbox Turbo
# + Ditto TensorRT + optional LiveKit agent) on the unified 3-in-1 worker.
# Runs concurrently with rosely-h3-sync while ZiT is already live serving requests.

mkdir -p /var/log/portal
: > /var/log/portal/voice-model-sync.log
exec > >(tee -a /var/log/portal/voice-model-sync.log) 2>&1

if [[ -f /opt/rosely-h3-zit-serverless/runtime.env ]]; then
  # shellcheck disable=SC1091
  source /opt/rosely-h3-zit-serverless/runtime.env
fi

APP_DIR="${APP_DIR:-/workspace/vast-pyworker}"
WORKSPACE="${WORKSPACE:-/workspace}"
STATE_DIR="${STATE_DIR:-/workspace/.rosely-h3-zit}"
ENABLE_VOICE="${ROSELY_ENABLE_VOICE:-true}"
VOICE_BUNDLE_ROOT="${ROSELY_VOICE_BUNDLE_ROOT:-${WORKSPACE}/rosely-voice-v1}"
VOICE_APP_DIR="${ROSELY_VOICE_APP_DIR:-${WORKSPACE}/rosely-vast-voice-avatar}"
VOICE_REPO="${ROSELY_VOICE_REPO:-https://github.com/ai-chad/rosely-vast-voice-avatar.git}"
VOICE_REF="${ROSELY_VOICE_REF:-main}"
VOICE_VRAM_MODE="${ROSELY_VOICE_VRAM_MODE:-auto}"
LIVE_CALL_ENABLED="${ROSELY_LIVE_CALL_ENABLED:-${LIVE_CALL_ENABLED:-1}}"
DITTO_SOURCE_CACHE_DISK_GB="${DITTO_SOURCE_CACHE_DISK_GB:-10}"

DEFAULT_VOICE_MANIFEST_KEY="models/voice-avatar/rosely-voice-ditto-v1/manifest.json"
DEFAULT_VOICE_MANIFEST_SHA="334a6170d549cae722100b49cfdd716e0d59882d90fd6d68c9e59e22704e4421"

VOICE_MODEL_KEY="${ROSELY_VOICE_MODEL_KEY:-$DEFAULT_VOICE_MANIFEST_KEY}"
VOICE_CHECKSUM_KEY="${ROSELY_VOICE_MODEL_CHECKSUM_KEY:-${VOICE_MODEL_KEY}.sha256}"
VOICE_EXPECTED_SHA="${ROSELY_VOICE_EXPECTED_SHA256:-}"
if [[ -z "$VOICE_EXPECTED_SHA" && "$VOICE_MODEL_KEY" == "$DEFAULT_VOICE_MANIFEST_KEY" ]]; then
  VOICE_EXPECTED_SHA="$DEFAULT_VOICE_MANIFEST_SHA"
fi

STATUS_FILE="${STATE_DIR}/voice-download-status.json"
READY_MARKER="${STATE_DIR}/voice.ready"
MODELS_READY_MARKER="${STATE_DIR}/voice-models.ready"
STARTED_AT="$(date -Iseconds)"

mkdir -p "$STATE_DIR" "$WORKSPACE/rosely-logs" "$WORKSPACE/rosely-run"

log() { printf '\n[%s] [Rosely Voice] %s\n' "$(date -Iseconds)" "$*"; }

write_status() {
  local st="$1" pct="${2:-0}" err="${3:-}" stage="${4:-$1}"
  local tmp="${STATUS_FILE}.tmp.$$"
  /venv/main/bin/python - "$st" "$pct" "$err" "$stage" "$VOICE_MODEL_KEY" "$STARTED_AT" "$tmp" <<'PY'
import json, sys
from datetime import datetime, timezone
st, pct, err, stage, model_key, started_at, out_path = sys.argv[1:]
now = datetime.now(timezone.utc).isoformat()
payload = {
    "family": "voice",
    "mode": "direct_manifest",
    "status": st,
    "stage": stage,
    "model_key": model_key,
    "percent": float(pct),
    "started_at": started_at,
    "updated_at": now,
    "finished_at": now if st in {"ready", "failed", "disabled"} else None,
    "error": err or None,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
  mv -f "$tmp" "$STATUS_FILE"
}

on_error() {
  local code=$? line=${1:-unknown}
  log "ERROR: Voice Avatar bootstrap failed at line ${line} (exit ${code})"
  write_status "failed" 0 "voice bootstrap failed at line ${line} (exit ${code})" "failed" || true
  exit "$code"
}
trap 'on_error $LINENO' ERR

if [[ "$ENABLE_VOICE" != "true" ]]; then
  log "ROSELY_ENABLE_VOICE=${ENABLE_VOICE}; skipping Voice Avatar bootstrap"
  write_status "disabled" 100 "" "disabled"
  exit 0
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

VOICE_BUCKET="${ROSELY_VOICE_S3_BUCKET:-$ROSELY_S3_BUCKET}"
VOICE_REGION="${ROSELY_VOICE_S3_REGION:-$ROSELY_S3_REGION}"
VOICE_ENDPOINT="${ROSELY_VOICE_S3_ENDPOINT_URL:-${ROSELY_S3_ENDPOINT_URL:-}}"
DOWNLOAD_CONCURRENCY="${ROSELY_MODEL_DOWNLOAD_CONCURRENCY:-16}"
DOWNLOAD_CHUNK_MIB="${ROSELY_MODEL_DOWNLOAD_CHUNK_MIB:-32}"
VOICE_FILE_WORKERS="${ROSELY_VOICE_FILE_WORKERS:-4}"

source /venv/main/bin/activate
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1

# 1. Direct per-file S3 sync of ASR + TTS + Ditto TRT + 28 voice WAVs + Ditto source tarball
log "Step 1/5: Syncing Voice Avatar + Ditto direct S3 bundle (${VOICE_MODEL_KEY}) -> ${VOICE_BUNDLE_ROOT}"
python -u "$APP_DIR/scripts/sync_models.py" \
  --family voice \
  --bucket "$VOICE_BUCKET" \
  --model-key "$VOICE_MODEL_KEY" \
  --checksum-key "$VOICE_CHECKSUM_KEY" \
  --expected-sha256 "$VOICE_EXPECTED_SHA" \
  --region "$VOICE_REGION" \
  --endpoint-url "$VOICE_ENDPOINT" \
  --dest-root "$VOICE_BUNDLE_ROOT" \
  --ready-marker "$MODELS_READY_MARKER" \
  --state-dir "$STATE_DIR" \
  --concurrency "$DOWNLOAD_CONCURRENCY" \
  --chunk-mib "$DOWNLOAD_CHUNK_MIB" \
  --file-workers "$VOICE_FILE_WORKERS" \
  --retries 5

write_status "installing" 55 "" "unpacking_sources"

# 2. Unpack pinned Ditto source tarball & clone rosely-vast-voice-avatar service code
DITTO_ROOT="${VOICE_BUNDLE_ROOT}/source/ditto-talkinghead"
if [[ ! -s "$DITTO_ROOT/stream_pipeline_offline.py" ]]; then
  log "Step 2/5: Unpacking pinned Ditto talking-head source"
  mkdir -p "$DITTO_ROOT"
  tarball=$(ls "${VOICE_BUNDLE_ROOT}/source"/ditto-talkinghead-*.tar.gz 2>/dev/null | head -n 1 || true)
  if [[ -n "$tarball" && -s "$tarball" ]]; then
    tar xzf "$tarball" -C "$DITTO_ROOT" --strip-components=1
  else
    curl -fsSL --retry 5 --retry-delay 3 \
      "https://codeload.github.com/antgroup/ditto-talkinghead/tar.gz/c3e47eee2e626500017a0556b470d6d4182f85e8" \
      | tar xzf - -C "$DITTO_ROOT" --strip-components=1
  fi
fi

if [[ ! -d "$VOICE_APP_DIR/.git" ]]; then
  log "Cloning Voice Avatar runtime repo ${VOICE_REPO}@${VOICE_REF}"
  rm -rf "$VOICE_APP_DIR"
  git clone --depth 1 --single-branch --branch "$VOICE_REF" "$VOICE_REPO" "$VOICE_APP_DIR"
else
  log "Voice Avatar runtime repo already present at ${VOICE_APP_DIR}"
fi
[[ -f "$VOICE_APP_DIR/voice_gateway.py" && -f "$VOICE_APP_DIR/ditto_server.py" && -f "$VOICE_APP_DIR/requirements-ditto.txt" ]] \
  || { log "ERROR: Incomplete Voice Avatar repo at ${VOICE_APP_DIR}"; exit 1; }

# Symlink /workspace/rosely-voices -> bundle voices for backward compatibility.
if [[ -d "${VOICE_BUNDLE_ROOT}/voices" && ! -e "${WORKSPACE}/rosely-voices" ]]; then
  ln -s "${VOICE_BUNDLE_ROOT}/voices" "${WORKSPACE}/rosely-voices"
fi

# 3. Provision isolated Python 3.10 environments (asr, tts, ditto) using uv
write_status "installing" 65 "" "installing_python_envs"
UV_BIN="$(command -v uv || true)"
if [[ -z "$UV_BIN" ]]; then
  python -m pip install --prefer-binary -q uv
  UV_BIN="$(command -v uv)"
fi

log "Step 3/5: Ensuring Python 3.10 and isolated voice virtualenvs (asr, tts, ditto)"
"$UV_BIN" python install 3.10
ENVS="${WORKSPACE}/rosely-venvs"
mkdir -p "$ENVS"

UV_VOICE_CACHE="${STATE_DIR}/uv-voice-cache"
mkdir -p "$UV_VOICE_CACHE"
cleanup_uv_cache() {
  rm -rf "$UV_VOICE_CACHE" || true
}
trap cleanup_uv_cache EXIT

uv_install() {
  local py="$1"
  shift
  if UV_CACHE_DIR="$UV_VOICE_CACHE" "$UV_BIN" pip install --python "$py" --no-progress --index-strategy unsafe-best-match "$@"; then
    return 0
  fi
  log "uv pip install fallback to pip for ${py}"
  "$py" -m pip install --no-cache-dir "$@"
}

for env_name in asr tts ditto; do
  if [[ ! -x "$ENVS/$env_name/bin/python" ]]; then
    "$UV_BIN" venv --python 3.10 --seed "$ENVS/$env_name"
  fi
done

if [[ ! -e "$ENVS/asr/.rosely_installed" ]]; then
  log "Installing Qwen3-ASR environment (torch 2.6.0/cu124 + qwen-asr)"
  uv_install "$ENVS/asr/bin/python" torch==2.6.0 torchaudio==2.6.0 \
    --index-url https://download.pytorch.org/whl/cu124 --extra-index-url https://pypi.org/simple
  uv_install "$ENVS/asr/bin/python" 'qwen-asr==0.0.6' 'fastapi>=0.115,<1' 'uvicorn[standard]>=0.30,<1' \
    'python-multipart>=0.0.18' 'httpx>=0.28,<1'
  "$ENVS/asr/bin/python" -c 'import torch, qwen_asr, fastapi, uvicorn; print("ASR env OK:", torch.__version__)'
  touch "$ENVS/asr/.rosely_installed"
fi

write_status "installing" 78 "" "installing_tts_env"
if [[ ! -e "$ENVS/tts/.rosely_installed" ]]; then
  log "Installing Chatterbox Turbo TTS environment (torch 2.6.0/cu124 + chatterbox-tts)"
  uv_install "$ENVS/tts/bin/python" torch==2.6.0 torchaudio==2.6.0 \
    --index-url https://download.pytorch.org/whl/cu124 --extra-index-url https://pypi.org/simple
  uv_install "$ENVS/tts/bin/python" 'chatterbox-tts==0.1.7' 'fastapi>=0.115,<1' 'uvicorn[standard]>=0.30,<1' \
    'python-multipart>=0.0.18' 'httpx>=0.28,<1'
  uv_install "$ENVS/tts/bin/python" 'setuptools==80.10.2'
  "$ENVS/tts/bin/python" -c 'import torch, chatterbox, perth; assert perth.PerthImplicitWatermarker is not None; print("TTS env OK:", torch.__version__)'
  touch "$ENVS/tts/.rosely_installed"
fi

write_status "installing" 88 "" "installing_ditto_env"
CUDNN8_DIR="$ENVS/ditto/cudnn8"
if [[ ! -e "$ENVS/ditto/.rosely_installed" ]]; then
  log "Installing Ditto TensorRT environment (torch 2.5.1/cu121 + TensorRT 8.6.1 + private cuDNN 8)"
  uv_install "$ENVS/ditto/bin/python" torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1 \
    --index-url https://download.pytorch.org/whl/cu121 --extra-index-url https://pypi.org/simple
  uv_install "$ENVS/ditto/bin/python" -r "$VOICE_APP_DIR/requirements-ditto.txt" \
    --extra-index-url https://pypi.nvidia.com
  site="$("$ENVS/ditto/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  mkdir -p "$site/tensorrt"
  cat > "$site/tensorrt/__init__.py" <<'EOF'
# Stand-in for the tensorrt==8.6.1 meta-package: expose tensorrt_bindings as tensorrt.
import sys
import tensorrt_bindings as _trt
sys.modules[__name__] = _trt
EOF
  tmp_cudnn="$(mktemp -d)"
  "$ENVS/ditto/bin/python" -m pip download -q --no-deps --only-binary=:all: nvidia-cudnn-cu12==8.9.7.29 -d "$tmp_cudnn"
  rm -rf "$CUDNN8_DIR" && mkdir -p "$CUDNN8_DIR"
  "$ENVS/ditto/bin/python" -m zipfile -e "$tmp_cudnn"/nvidia_cudnn_cu12-8.9.7.29-*.whl "$CUDNN8_DIR"
  rm -rf "$tmp_cudnn"
  LD_LIBRARY_PATH="$CUDNN8_DIR/nvidia/cudnn/lib:${LD_LIBRARY_PATH:-}" "$ENVS/ditto/bin/python" - <<'PY'
import torch, tensorrt, livekit.rtc, webrtcvad
assert torch.cuda.is_available(), "CUDA unavailable in Ditto venv"
cap = torch.cuda.get_device_capability(0)
print(f"Ditto env OK: torch={torch.__version__} tensorrt={tensorrt.__version__} gpu_cc={cap}")
if cap[0] >= 12:
    print("WARNING: Blackwell GPU (CC >= 12.0) detected; pre-compiled TensorRT 8.6.1 ditto_trt_Ampere_Plus engines require Ampere/Ada (RTX 3090/4090) or ONNX-to-TRT rebuild.")
PY
  touch "$ENVS/ditto/.rosely_installed"
fi

# 4. Write persistent secure voice environment config (preserving existing keys)
write_status "installing" 96 "" "writing_env"
log "Step 4/5: Writing ${WORKSPACE}/rosely-voice-avatar.env"
ENV_FILE="${WORKSPACE}/rosely-voice-avatar.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
VOICE_API_KEY="${VOICE_API_KEY:-$(openssl rand -hex 32)}"
GATEWAY_API_KEY="${GATEWAY_API_KEY:-$(openssl rand -hex 32)}"
cat > "$ENV_FILE" <<EOF
VOICE_API_KEY=${VOICE_API_KEY}
GATEWAY_API_KEY=${GATEWAY_API_KEY}
BUNDLE_ROOT=${VOICE_BUNDLE_ROOT}
ASR_MODEL_PATH=${VOICE_BUNDLE_ROOT}/models/Qwen3-ASR-0.6B
TTS_MODEL_PATH=${VOICE_BUNDLE_ROOT}/models/chatterbox-turbo
VOICES_DIR=${VOICE_BUNDLE_ROOT}/voices
AVATAR_MEDIA_ROOT=${WORKSPACE}/rosely-avatar-data
ASR_PORT=8001
TTS_PORT=8002
GATEWAY_PORT=8000
LIVE_CALL_ENABLED=${LIVE_CALL_ENABLED}
LIVE_PORT=8006
DITTO_PORT=8005
DITTO_ROOT=${DITTO_ROOT}
DITTO_MODELS=${VOICE_BUNDLE_ROOT}/models/ditto
DITTO_PYTHON_ENV=${ENVS}/ditto
DITTO_CUDNN8_DIR=${CUDNN8_DIR}/nvidia/cudnn/lib
DITTO_SOURCE_CACHE_DISK_GB=${DITTO_SOURCE_CACHE_DISK_GB}
EOF
chmod 600 "$ENV_FILE"

# 5. Mark Voice Avatar ready!
cat > "${READY_MARKER}.tmp.$$" <<EOF
family=voice
mode=direct_manifest
model_key=${VOICE_MODEL_KEY}
verified_at=$(date -Iseconds)
EOF
mv -f "${READY_MARKER}.tmp.$$" "$READY_MARKER"
write_status "ready" 100 "" "ready"

# If running in resident VRAM mode (explicit or >=30 GiB GPU), politely ask
# model_server to warm the voice stack under generation_lock if idle.
effective_mode="$VOICE_VRAM_MODE"
if [[ "$effective_mode" == "auto" ]]; then
  vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ' ' || echo 0)
  if [[ "$vram_mb" =~ ^[0-9]+$ ]] && (( vram_mb >= 30720 )); then
    effective_mode="resident"
  else
    effective_mode="switch"
  fi
fi

log "Step 5/5: Voice Avatar READY (vram_mode=${effective_mode}, live_call=${LIVE_CALL_ENABLED})"
if [[ "$effective_mode" == "resident" ]]; then
  log "Resident mode active: requesting idle warm-up via model_server"
  curl -fsS -X POST --max-time 260 http://127.0.0.1:18288/internal/voice/warm || \
    log "WARN: idle voice warm-up skipped/deferred; first voice request will warm on demand"
else
  log "Switch mode active (<30 GiB VRAM): voice stack stays unloaded while ZiT/H3 use full GPU VRAM and auto-starts on first voice request (~10-15s)."
fi
