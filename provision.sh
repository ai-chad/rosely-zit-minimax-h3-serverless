#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export PYTHONUNBUFFERED=1

mkdir -p /var/log/portal
: > /var/log/portal/combined-provision.log
exec > >(tee -a /var/log/portal/combined-provision.log) 2>&1

# ---------------------------------------------------------------------------
# 1. Unified AWS credentials + shared S3 bucket (authoritative)
#    Intentionally overwrites stale Vast cached AWS_* / legacy ZiT aliases.
# ---------------------------------------------------------------------------
: "${AWS_UNIFIED_ACCESS_KEY_ID:?AWS_UNIFIED_ACCESS_KEY_ID is required}"
: "${AWS_UNIFIED_SECRET_ACCESS_KEY:?AWS_UNIFIED_SECRET_ACCESS_KEY is required}"
: "${ROSELY_S3_BUCKET:=rosely-infrastructure}"
: "${ROSELY_S3_REGION:=us-east-1}"
: "${ROSELY_PRESIGNED_URL_EXPIRES_SECONDS:=3600}"

export AWS_ACCESS_KEY_ID="$AWS_UNIFIED_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_UNIFIED_SECRET_ACCESS_KEY"
if [[ -n "${AWS_UNIFIED_SESSION_TOKEN:-}" ]]; then
  export AWS_SESSION_TOKEN="$AWS_UNIFIED_SESSION_TOKEN"
else
  unset AWS_SESSION_TOKEN || true
fi

unset AWS_ZIT_IMAGE_MODEL_ACCESS_KEY_ID || true
unset AWS_ZIT_IMAGE_MODEL_SECRET_ACCESS_KEY || true
unset AWS_ZIT_IMAGE_MODEL_SESSION_TOKEN || true
unset AWS_ZIT_IMAGE_ACCESS_KEY_ID || true
unset AWS_ZIT_IMAGE_SECRET_ACCESS_KEY || true
unset AWS_ZIT_IMAGE_SESSION_TOKEN || true
unset ROSELY_ZIT_S3_ACCESS_KEY_ID || true
unset ROSELY_ZIT_S3_SECRET_ACCESS_KEY || true
unset ROSELY_ZIT_S3_SESSION_TOKEN || true

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
export ROSELY_H3_PRESIGNED_URL_EXPIRES_SECONDS="$ROSELY_PRESIGNED_URL_EXPIRES_SECONDS"
export ROSELY_ZIT_PRESIGNED_URL_EXPIRES_SECONDS="$ROSELY_PRESIGNED_URL_EXPIRES_SECONDS"

# ---------------------------------------------------------------------------
# 2. Core paths, pinned versions, and direct per-file manifest defaults
# ---------------------------------------------------------------------------
APP_DIR="${APP_DIR:-/workspace/vast-pyworker}"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
COMFY_COMMIT="${COMFY_COMMIT:-345c9190497c82cff53e71fb4ae00d1e135a6542}"
STATE_DIR="${STATE_DIR:-/workspace/.rosely-h3-zit}"
PYWORKER_REPO="${PYWORKER_REPO:?PYWORKER_REPO must point to this combined deployment repository}"
PYWORKER_REF="${PYWORKER_REF:-main}"

MODEL_BUNDLE_MODE="${MODEL_BUNDLE_MODE:-direct}"
MIN_FREE_DISK_GB="${MIN_FREE_DISK_GB:-85}"
MIN_CUDA_CAPABILITY="${MIN_CUDA_CAPABILITY:-8.9}"
INSTALL_ZIT_OPTIONAL_NODES="${ROSELY_INSTALL_ZIT_OPTIONAL_NODES:-true}"
INSTALL_SAM2="${ROSELY_INSTALL_SAM2:-false}"
WAIT_FOR_H3_DURING_PROVISION="${ROSELY_WAIT_FOR_H3_DURING_PROVISION:-false}"

DEFAULT_H3_MODEL_NAME="10Eros_Max_8stepTurbo_v1.0_hybrid-int8_HQ.safetensors"
H3_MODEL_NAME="${ROSELY_H3_MODEL_NAME:-$DEFAULT_H3_MODEL_NAME}"

DEFAULT_H3_MANIFEST_KEY="models/minimax-h3/beta7_sulpher3/manifest.json"
DEFAULT_H3_MANIFEST_SHA="45ad09171573a127d7388e6ab22ed0852069bc1046d5931bb821579175b7d529"

DEFAULT_ZIT_MANIFEST_KEY="serverless/zimage/zenith13/zenith13-mxfp8-full-detailer-seedvr2-v3-direct/manifest.json"
DEFAULT_ZIT_MANIFEST_SHA="14b308d29489719b09beeff9708e6961537319eadc02cdac4f94b68da47fd6d4"
LEGACY_ZIT_ARCHIVE_KEY="serverless/zimage/zenith13/zenith13-mxfp8-full-detailer-seedvr2-v3.tar.zst"
LEGACY_ZIT_ARCHIVE_SHA="cfbd87e06b3b570c40c1436bea5cb31c0b1c70b772254d13791162f41df64fb7"
LEGACY_ZIT_ARCHIVE_SIZE="16309405103"

H3_MODEL_KEY="${ROSELY_H3_MODEL_KEY:-${ROSELY_H3_S3_MODEL_KEY:-$DEFAULT_H3_MANIFEST_KEY}}"
H3_CHECKSUM_KEY="${ROSELY_H3_MODEL_CHECKSUM_KEY:-${ROSELY_H3_S3_CHECKSUM_KEY:-${H3_MODEL_KEY}.sha256}}"
H3_EXPECTED_SHA="${ROSELY_H3_EXPECTED_SHA256:-}"
if [[ -z "$H3_EXPECTED_SHA" && "$H3_MODEL_KEY" == "$DEFAULT_H3_MANIFEST_KEY" && "$DEFAULT_H3_MANIFEST_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
  H3_EXPECTED_SHA="$DEFAULT_H3_MANIFEST_SHA"
fi

ZIT_MODEL_KEY="${ROSELY_ZIT_MODEL_KEY:-${ROSELY_ZIT_MODEL_S3_KEY:-$DEFAULT_ZIT_MANIFEST_KEY}}"
ZIT_CHECKSUM_KEY="${ROSELY_ZIT_MODEL_CHECKSUM_KEY:-}"
if [[ -z "$ZIT_CHECKSUM_KEY" && "$ZIT_MODEL_KEY" == *.json ]]; then
  ZIT_CHECKSUM_KEY="${ZIT_MODEL_KEY}.sha256"
fi
ZIT_EXPECTED_SHA="${ROSELY_ZIT_EXPECTED_SHA256:-}"
if [[ -z "$ZIT_EXPECTED_SHA" ]]; then
  if [[ "$ZIT_MODEL_KEY" == "$DEFAULT_ZIT_MANIFEST_KEY" && "$DEFAULT_ZIT_MANIFEST_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
    ZIT_EXPECTED_SHA="$DEFAULT_ZIT_MANIFEST_SHA"
  elif [[ "$ZIT_MODEL_KEY" == "$LEGACY_ZIT_ARCHIVE_KEY" ]]; then
    ZIT_EXPECTED_SHA="$LEGACY_ZIT_ARCHIVE_SHA"
  fi
fi
ZIT_EXPECTED_SIZE="${ROSELY_ZIT_EXPECTED_SIZE:-0}"
if [[ "$ZIT_EXPECTED_SIZE" == "0" && "$ZIT_MODEL_KEY" == "$LEGACY_ZIT_ARCHIVE_KEY" ]]; then
  ZIT_EXPECTED_SIZE="$LEGACY_ZIT_ARCHIVE_SIZE"
fi

DOWNLOAD_CONCURRENCY="${ROSELY_MODEL_DOWNLOAD_CONCURRENCY:-16}"
DOWNLOAD_CHUNK_MIB="${ROSELY_MODEL_DOWNLOAD_CHUNK_MIB:-32}"
ZIT_FILE_WORKERS="${ROSELY_ZIT_FILE_WORKERS:-4}"
H3_FILE_WORKERS="${ROSELY_H3_FILE_WORKERS:-3}"

mkdir -p "$STATE_DIR"

log() { printf '\n[%s] [Rosely H3+ZiT] %s\n' "$(date -Iseconds)" "$*"; }
fail() { log "ERROR: $*"; exit 1; }
on_error() {
  local code=$? line=${1:-unknown}
  log "Provisioning failed at line ${line} with exit code ${code}"
  exit "$code"
}
trap 'on_error $LINENO' ERR

check_disk_space() {
  local required_gb=$1 purpose=${2:-operation}
  local available_kb required_kb
  available_kb=$(df -Pk /workspace | awk 'NR==2 {print $4}')
  required_kb=$((required_gb * 1024 * 1024))
  log "Available /workspace disk: $((available_kb / 1024 / 1024)) GiB (${purpose})"
  (( available_kb >= required_kb )) || fail \
    "At least ${required_gb} GiB free is required for ${purpose}."
}

ensure_system_packages() {
  local packages=()
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v ffmpeg >/dev/null 2>&1 || packages+=(ffmpeg)
  command -v git >/dev/null 2>&1 || packages+=(git)
  command -v jq >/dev/null 2>&1 || packages+=(jq)
  command -v zstd >/dev/null 2>&1 || packages+=(zstd)
  command -v supervisorctl >/dev/null 2>&1 || packages+=(supervisor)
  dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed' || packages+=(ca-certificates)
  dpkg-query -W -f='${Status}' libgl1 2>/dev/null | grep -q 'install ok installed' || packages+=(libgl1)
  if ! dpkg-query -W -f='${Status}' libglib2.0-0t64 2>/dev/null | grep -q 'install ok installed'; then
    if apt-cache show libglib2.0-0t64 >/dev/null 2>&1; then
      packages+=(libglib2.0-0t64)
    else
      packages+=(libglib2.0-0)
    fi
  fi
  if (( ${#packages[@]} )); then
    log "Installing system packages: ${packages[*]}"
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${packages[@]}"
    rm -rf /var/lib/apt/lists/*
  fi
}

clone_exact_commit() {
  local repo=$1 commit=$2 destination=$3
  if [[ -d "$destination/.git" ]]; then
    local existing
    existing=$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)
    if [[ "$existing" == "$commit" ]]; then
      return 0
    fi
  fi
  rm -rf "$destination"
  git init -q "$destination"
  git -C "$destination" remote add origin "$repo"
  git -C "$destination" fetch -q --depth 1 origin "$commit"
  git -C "$destination" checkout --detach -q FETCH_HEAD
}

install_comfyui_preserving_models() {
  local current="" backup=""
  if [[ -d "$COMFY_DIR/.git" ]]; then
    current=$(git -C "$COMFY_DIR" rev-parse HEAD 2>/dev/null || true)
  fi
  if [[ "$current" == "$COMFY_COMMIT" ]]; then
    log "Pinned ComfyUI already installed"
    return
  fi
  if [[ -d "$COMFY_DIR/models" ]]; then
    backup=$(mktemp -d /workspace/.combined-models-backup.XXXXXX)
    mv "$COMFY_DIR/models" "$backup/models"
  fi
  log "Installing pinned ComfyUI ${COMFY_COMMIT}"
  clone_exact_commit https://github.com/Comfy-Org/ComfyUI.git "$COMFY_COMMIT" "$COMFY_DIR"
  if [[ -n "$backup" && -d "$backup/models" ]]; then
    rm -rf "$COMFY_DIR/models"
    mv "$backup/models" "$COMFY_DIR/models"
    rmdir "$backup" || true
  fi
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  log "Installing uv for fast parallel Python wheel installation"
  python -m pip install --prefer-binary -q uv || true
}

fast_pip_install() {
  if command -v uv >/dev/null 2>&1; then
    if uv pip install --python /venv/main/bin/python --no-progress "$@"; then
      return 0
    fi
    log "uv pip install failed; falling back to pip"
  fi
  python -m pip install --prefer-binary "$@"
}

filter_req_file() {
  local src=$1 dst=$2 drop_sam2=${3:-false}
  if [[ "$drop_sam2" == "true" ]]; then
    awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ && !/^(torch|torchvision|torchaudio|opencv-python)([<>=~! ].*)?$/ && !/facebookresearch\/sam2/' "$src" > "$dst"
  else
    awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ && !/^(torch|torchvision|torchaudio|opencv-python)([<>=~! ].*)?$/' "$src" > "$dst"
  fi
}

install_comfy_and_optional_zit_nodes() {
  local req_args=()
  filter_req_file "$COMFY_DIR/requirements.txt" "$STATE_DIR/comfy-requirements.filtered.txt" false
  req_args+=(-r "$STATE_DIR/comfy-requirements.filtered.txt")

  if [[ "$INSTALL_ZIT_OPTIONAL_NODES" == "true" ]]; then
    log "Cloning pinned optional ZiT detailer/upscaler nodes in parallel"
    local impact_ref=429d0159ad429e64d2b3916e6e7be9c22d025c3c
    local sub_ref=50c7b71a6a224734cc9b21963c6d1926816a97f1
    local seed_ref=4490bd1f482e026674543386bb2a4d176da245b9
    local vr_ref=f633a8b0824e81cd9e3ad2f9f0f51f1f9680353b
    mkdir -p "$COMFY_DIR/custom_nodes"

    clone_exact_commit https://github.com/ltdrdata/ComfyUI-Impact-Pack.git "$impact_ref" "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Pack" &
    local p1=$!
    clone_exact_commit https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git "$sub_ref" "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Subpack" &
    local p2=$!
    clone_exact_commit https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git "$seed_ref" "$COMFY_DIR/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler" &
    local p3=$!
    clone_exact_commit https://github.com/vrgamegirl19/comfyui-vrgamedevgirl.git "$vr_ref" "$COMFY_DIR/custom_nodes/comfyui-vrgamedevgirl" &
    local p4=$!
    wait "$p1" "$p2" "$p3" "$p4"

    local drop_sam2=true
    [[ "$INSTALL_SAM2" == "true" ]] && drop_sam2=false
    filter_req_file "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Pack/requirements.txt" "$STATE_DIR/impact-requirements.filtered.txt" "$drop_sam2"
    filter_req_file "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Subpack/requirements.txt" "$STATE_DIR/subpack-requirements.filtered.txt" false
    filter_req_file "$COMFY_DIR/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler/requirements.txt" "$STATE_DIR/seedvr2-requirements.filtered.txt" false
    filter_req_file "$COMFY_DIR/custom_nodes/comfyui-vrgamedevgirl/requirements.txt" "$STATE_DIR/vrgd-requirements.filtered.txt" false

    req_args+=(
      -r "$STATE_DIR/impact-requirements.filtered.txt"
      -r "$STATE_DIR/subpack-requirements.filtered.txt"
      -r "$STATE_DIR/seedvr2-requirements.filtered.txt"
      -r "$STATE_DIR/vrgd-requirements.filtered.txt"
      av imageio-ffmpeg transformers requests
    )
  else
    log "Optional ZiT detailer/upscaler nodes disabled"
  fi

  log "Installing ComfyUI + node Python dependencies in one fast pass (while ZiT downloads)"
  fast_pip_install "${req_args[@]}"

  if [[ "$INSTALL_ZIT_OPTIONAL_NODES" == "true" ]]; then
    # Prevent Impact-Pack install.py from downloading sam_vit_b_01ec64.pth from
    # external mirrors while our verified S3 ZiT sync provides it.
    touch "$COMFY_DIR/custom_nodes/skip_download_model"
    COMFYUI_PATH="$COMFY_DIR" COMFYUI_MODEL_PATH="$COMFY_DIR/models" \
      python "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Pack/install.py"

    if ! python -c 'import torchaudio' >/dev/null 2>&1; then
      local torch_ver cuda_tag
      torch_ver=$(python -c 'import torch; print(torch.__version__.split("+")[0])')
      cuda_tag=$(python -c 'import torch; v=torch.__version__; print(v.split("+")[1] if "+" in v else "")')
      if [[ -n "$cuda_tag" ]]; then
        fast_pip_install --no-deps --extra-index-url "https://download.pytorch.org/whl/${cuda_tag}" "torchaudio==${torch_ver}+${cuda_tag}" \
          || fast_pip_install --no-deps --extra-index-url "https://download.pytorch.org/whl/${cuda_tag}" torchaudio \
          || fast_pip_install --no-deps torchaudio
      else
        fast_pip_install --no-deps "torchaudio==${torch_ver}" || fast_pip_install --no-deps torchaudio
      fi
    fi
  fi
}

validate_zit_core_models() {
  local required=(
    "$COMFY_DIR/models/diffusion_models/Zenith_13.0_MXFP8_E4M3.safetensors"
    "$COMFY_DIR/models/text_encoders/qwen/qwen_3_4b_fp8_mixed.safetensors"
    "$COMFY_DIR/models/vae/Flux/flux_vae.safetensors"
    "$COMFY_DIR/models/loras/zpenis-zit-v1_5.safetensors"
    "$COMFY_DIR/models/loras/RealisticSnapshot-Zimage-Turbov5.safetensors"
    "$COMFY_DIR/models/loras/deedee_amateur_photography_zimage_base_and_turbo_v1.safetensors"
    "$COMFY_DIR/models/loras/z-image-illustria-01.safetensors"
    "$COMFY_DIR/models/loras/z-image-anime-01.safetensors"
    "$COMFY_DIR/models/loras/elusarca-anime-style.safetensors"
  )
  for f in "${required[@]}"; do
    [[ -s "$f" ]] || fail "Missing or empty required ZiT model file: $f"
  done
  [[ $(stat -c %s "$COMFY_DIR/models/diffusion_models/Zenith_13.0_MXFP8_E4M3.safetensors") -ge 5000000000 ]] || fail "Zenith model unexpectedly small"
  [[ $(stat -c %s "$COMFY_DIR/models/text_encoders/qwen/qwen_3_4b_fp8_mixed.safetensors") -ge 1000000000 ]] || fail "ZiT text encoder unexpectedly small"
  [[ $(stat -c %s "$COMFY_DIR/models/vae/Flux/flux_vae.safetensors") -ge 100000000 ]] || fail "ZiT VAE unexpectedly small"
  log "Core ZiT model files validated"
}

validate_comfy_nodes() {
  log "Validating required ComfyUI node classes for both model families"
  python - <<'PY'
import json, urllib.request
url='http://127.0.0.1:18189/object_info'
with urllib.request.urlopen(url, timeout=20) as r:
    obj=json.load(r)
required={
 'CLIPLoader','UNETLoader','VAELoader','LoadImage','MiniMaxH3SigmaShift',
 'MiniMaxH3ReferenceToVideo','BasicGuider','RandomNoise','BasicScheduler',
 'KSamplerSelect','SamplerCustomAdvanced','VAEDecode','VAEDecodeAudio',
 'CreateVideo','SaveVideo','CLIPTextEncode','ConditioningZeroOut',
 'EmptyLatentImage','KSampler','SaveImage','LoraLoaderModelOnly'
}
missing=sorted(required-set(obj))
if missing: raise SystemExit('Missing required ComfyUI nodes: '+', '.join(missing))
print('Required H3 + ZiT ComfyUI nodes OK:', len(required))
PY
}

write_runtime_env() {
  local env_file="/opt/rosely-h3-zit-serverless/runtime.env"
  cat > "$env_file" <<EOF
: "\${APP_DIR:=${APP_DIR}}"
: "\${COMFY_DIR:=${COMFY_DIR}}"
: "\${STATE_DIR:=${STATE_DIR}}"
: "\${ROSELY_S3_BUCKET:=${ROSELY_S3_BUCKET}}"
: "\${ROSELY_S3_REGION:=${ROSELY_S3_REGION}}"
: "\${ROSELY_H3_MODEL_NAME:=${H3_MODEL_NAME}}"
: "\${ROSELY_H3_MODEL_KEY:=${H3_MODEL_KEY}}"
: "\${ROSELY_H3_MODEL_CHECKSUM_KEY:=${H3_CHECKSUM_KEY}}"
: "\${ROSELY_H3_EXPECTED_SHA256:=${H3_EXPECTED_SHA}}"
: "\${ROSELY_MODEL_DOWNLOAD_CONCURRENCY:=${DOWNLOAD_CONCURRENCY}}"
: "\${ROSELY_MODEL_DOWNLOAD_CHUNK_MIB:=${DOWNLOAD_CHUNK_MIB}}"
: "\${ROSELY_H3_FILE_WORKERS:=${H3_FILE_WORKERS}}"
EOF
  chmod 0644 "$env_file"
}

# ---------------------------------------------------------------------------
# 3. Execute fast-boot staged provisioning
# ---------------------------------------------------------------------------
PROV_START=$(date +%s)
log "Provisioning START mode=${MODEL_BUNDLE_MODE} repo=${PYWORKER_REPO}@${PYWORKER_REF}"
log "Shared S3 bucket=${ROSELY_S3_BUCKET} region=${ROSELY_S3_REGION}"
log "ZiT artifact=${ZIT_MODEL_KEY}"
log "H3  artifact=${H3_MODEL_KEY} (model=${H3_MODEL_NAME})"

ensure_system_packages
[[ -f /venv/main/bin/activate ]] || fail "/venv/main missing; use a recent Vast PyTorch CUDA image with RTX 5090/Blackwell support"
source /venv/main/bin/activate

log "Checking CUDA / GPU capability (min=${MIN_CUDA_CAPABILITY})"
MIN_CUDA_CAPABILITY="$MIN_CUDA_CAPABILITY" python - <<'PY'
import os, torch
print('Torch:', torch.__version__, 'CUDA:', torch.version.cuda, 'available:', torch.cuda.is_available())
if not torch.cuda.is_available():
    raise SystemExit('CUDA unavailable')
name = torch.cuda.get_device_name(0)
cap = torch.cuda.get_device_capability(0)
vram_gb = torch.cuda.get_device_properties(0).total_memory / (1024**3)
print(f'GPU: {name} compute capability: {cap} VRAM: {vram_gb:.1f} GiB')
min_req = tuple(int(x) for x in os.environ.get('MIN_CUDA_CAPABILITY', '8.9').split('.'))
if cap < min_req:
    raise SystemExit(f'GPU compute capability >= {min_req} required; detected {name} capability {cap}')
if cap[0] < 12:
    print(f'NOTE: Non-Blackwell GPU ({name}, CC {cap}, {vram_gb:.1f} GiB VRAM); MXFP8/NVFP4 will use comfy-kitchen fallback paths.')
PY

log "Cloning combined deployment repository"
rm -rf "$APP_DIR"
git clone --progress --depth 1 --single-branch --branch "$PYWORKER_REF" "$PYWORKER_REPO" "$APP_DIR"
[[ -f "$APP_DIR/worker.py" && -f "$APP_DIR/model_server.py" && -f "$APP_DIR/scripts/sync_models.py" ]] || fail "Combined repository is incomplete"

log "Installing application dependencies"
ensure_uv
fast_pip_install -r "$APP_DIR/requirements.txt"

install_comfyui_preserving_models
mkdir -p "$COMFY_DIR/models"/{diffusion_models,text_encoders,vae,loras} "$COMFY_DIR"/{input,output,temp}

if [[ ! -f "$STATE_DIR/zit.ready" || ! -f "$STATE_DIR/h3.ready" ]]; then
  check_disk_space "$MIN_FREE_DISK_GB" "H3+ZiT direct model sync"
fi

# Phase 1: Overlap ZiT model download with ComfyUI + optional ZiT custom nodes installation.
log "Phase 1: Starting ZiT direct model sync in parallel with ComfyUI & optional node installs"
: > /var/log/portal/zit-model-sync.log
python -u "$APP_DIR/scripts/sync_models.py" \
  --family zit \
  --bucket "$ROSELY_S3_BUCKET" \
  --model-key "$ZIT_MODEL_KEY" \
  --checksum-key "$ZIT_CHECKSUM_KEY" \
  --expected-sha256 "$ZIT_EXPECTED_SHA" \
  --expected-size "$ZIT_EXPECTED_SIZE" \
  --region "$ROSELY_S3_REGION" \
  --endpoint-url "${ROSELY_S3_ENDPOINT_URL:-}" \
  --comfy-dir "$COMFY_DIR" \
  --state-dir "$STATE_DIR" \
  --concurrency "$DOWNLOAD_CONCURRENCY" \
  --chunk-mib "$DOWNLOAD_CHUNK_MIB" \
  --file-workers "$ZIT_FILE_WORKERS" \
  --retries 3 \
  > /var/log/portal/zit-model-sync.log 2>&1 &
ZIT_SYNC_PID=$!

install_comfy_and_optional_zit_nodes

log "Waiting for ZiT model sync (pid=${ZIT_SYNC_PID}) to finish"
if ! wait "$ZIT_SYNC_PID"; then
  log "ZiT model sync failed! Tail of /var/log/portal/zit-model-sync.log:"
  tail -120 /var/log/portal/zit-model-sync.log || true
  fail "ZiT model sync failed"
fi
tail -25 /var/log/portal/zit-model-sync.log || true

# Ensure SeedVR2 uppercase directory + lowercase compatibility alias both exist.
if [[ -d "$COMFY_DIR/models/SEEDVR2" && ! -L "$COMFY_DIR/models/SEEDVR2" ]]; then
  if [[ ! -e "$COMFY_DIR/models/seedvr2" || -L "$COMFY_DIR/models/seedvr2" ]]; then
    rm -f "$COMFY_DIR/models/seedvr2"
    ln -s "$COMFY_DIR/models/SEEDVR2" "$COMFY_DIR/models/seedvr2"
  fi
elif [[ -d "$COMFY_DIR/models/seedvr2" && ! -L "$COMFY_DIR/models/seedvr2" ]]; then
  rm -rf "$COMFY_DIR/models/SEEDVR2"
  ln -s "$COMFY_DIR/models/seedvr2" "$COMFY_DIR/models/SEEDVR2"
fi
validate_zit_core_models

# Pre-seed H3 status file as "downloading" if not already ready so model_server
# never sees a transient "missing" window before rosely-h3-sync starts writing.
if [[ ! -f "$STATE_DIR/h3.ready" ]]; then
  cat > "$STATE_DIR/h3-download-status.json" <<EOF
{
  "family": "h3",
  "mode": "direct_manifest",
  "status": "downloading",
  "model_key": "${H3_MODEL_KEY}",
  "percent": 0.0,
  "started_at": "$(date -Iseconds)",
  "updated_at": "$(date -Iseconds)",
  "finished_at": null,
  "error": null
}
EOF
fi

log "Phase 2: Starting shared ComfyUI, model server (ZiT live), and background H3 model sync"
for service in api-wrapper comfyui h3-comfyui h3-model-server rosely-comfyui rosely-h3-sync rosely-model-server; do
  supervisorctl stop "$service" >/dev/null 2>&1 || true
done
for config in /etc/supervisor/conf.d/api-wrapper.conf /etc/supervisor/conf.d/comfyui.conf /etc/supervisor/conf.d/h3-services.conf; do
  [[ -f "$config" ]] && mv "$config" "${config}.disabled"
done
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true

mkdir -p /opt/rosely-h3-zit-serverless
cp "$APP_DIR/scripts/start_comfyui.sh" /opt/rosely-h3-zit-serverless/
cp "$APP_DIR/scripts/start_h3_sync.sh" /opt/rosely-h3-zit-serverless/
cp "$APP_DIR/scripts/start_model_server.sh" /opt/rosely-h3-zit-serverless/
cp "$APP_DIR/scripts/status.sh" /opt/rosely-h3-zit-serverless/
chmod +x /opt/rosely-h3-zit-serverless/*.sh
write_runtime_env
cp "$APP_DIR/supervisor/combined-services.conf" /etc/supervisor/conf.d/combined-services.conf
supervisorctl reread
supervisorctl update
supervisorctl start rosely-comfyui >/dev/null 2>&1 || true
supervisorctl start rosely-h3-sync >/dev/null 2>&1 || true
supervisorctl start rosely-model-server >/dev/null 2>&1 || true

log "Waiting for shared ComfyUI"
comfy_ok=0
for _ in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:18189/system_stats >/dev/null 2>&1; then comfy_ok=1; break; fi
  state=$(supervisorctl status rosely-comfyui 2>/dev/null | awk '{print $2}' || true)
  [[ "$state" == FATAL || "$state" == EXITED ]] && break
  sleep 2
done
(( comfy_ok == 1 )) || {
  supervisorctl status || true; nvidia-smi || true; tail -300 /var/log/portal/comfyui.log 2>/dev/null || true
  fail "Shared ComfyUI did not become healthy within 360 seconds"
}
validate_comfy_nodes

log "Waiting for combined FastAPI model server (ZiT-ready health)"
server_ok=0
for _ in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:18288/health >/dev/null 2>&1; then server_ok=1; break; fi
  state=$(supervisorctl status rosely-model-server 2>/dev/null | awk '{print $2}' || true)
  [[ "$state" == FATAL || "$state" == EXITED ]] && break
  sleep 2
done
(( server_ok == 1 )) || {
  supervisorctl status || true; nvidia-smi || true
  tail -300 /var/log/portal/comfyui.log 2>/dev/null || true
  tail -300 /var/log/portal/model-server.log 2>/dev/null || true
  fail "Combined model server did not become healthy within 360 seconds"
}

if [[ "$WAIT_FOR_H3_DURING_PROVISION" == "true" ]]; then
  log "ROSELY_WAIT_FOR_H3_DURING_PROVISION=true: waiting for H3 background sync to finish"
  while [[ ! -f "$STATE_DIR/h3.ready" ]]; do
    st=$(jq -r '.status // "downloading"' "$STATE_DIR/h3-download-status.json" 2>/dev/null || echo "downloading")
    if [[ "$st" == "failed" ]]; then
      tail -120 /var/log/portal/h3-model-sync.log || true
      fail "H3 background sync failed"
    fi
    sleep 3
  done
  log "H3 models verified and ready"
fi

ELAPSED=$(( $(date +%s) - PROV_START ))
log "PROVISIONING COMPLETE in ${ELAPSED}s (ZiT LIVE; H3 background sync active/ready)"
supervisorctl status rosely-comfyui rosely-h3-sync rosely-model-server || true
curl -fsS http://127.0.0.1:18288/health | jq . || true
nvidia-smi || true
df -h /workspace
log "Logs: /var/log/portal/combined-provision.log, /var/log/portal/zit-model-sync.log, /var/log/portal/h3-model-sync.log"
