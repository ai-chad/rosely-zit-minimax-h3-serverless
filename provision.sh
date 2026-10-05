#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1
export PYTHONUNBUFFERED=1

mkdir -p /var/log/portal
: > /var/log/portal/combined-provision.log
exec > >(tee -a /var/log/portal/combined-provision.log) 2>&1

APP_DIR=${APP_DIR:-/workspace/vast-pyworker}
COMFY_DIR=${COMFY_DIR:-/workspace/ComfyUI}
COMFY_COMMIT=${COMFY_COMMIT:-345c9190497c82cff53e71fb4ae00d1e135a6542}
STATE_DIR=${STATE_DIR:-/workspace/.rosely-h3-zit}
READY_MARKER=${STATE_DIR}/models.ready
PYWORKER_REPO=${PYWORKER_REPO:?PYWORKER_REPO must point to this combined deployment repository}
PYWORKER_REF=${PYWORKER_REF:-main}

MODEL_BUNDLE_MODE=${MODEL_BUNDLE_MODE:-split}
MIN_FREE_DISK_GB=${MIN_FREE_DISK_GB:-135}
MIN_EXTRACT_FREE_GB=${MIN_EXTRACT_FREE_GB:-70}

# Preferred final layout: one combined tar.zst with ComfyUI/models/... at root.
COMBINED_BUCKET=${ROSELY_COMBINED_S3_BUCKET:-rosely-infrastructure}
COMBINED_MODEL_KEY=${ROSELY_COMBINED_S3_MODEL_KEY:-models/combined/h3-zit-5090/h3-zit-5090-comfyui.tar.zst}
COMBINED_CHECKSUM_KEY=${ROSELY_COMBINED_S3_CHECKSUM_KEY:-${COMBINED_MODEL_KEY}.sha256}
COMBINED_REGION=${ROSELY_COMBINED_S3_REGION:-us-east-1}
COMBINED_ENDPOINT=${ROSELY_COMBINED_S3_ENDPOINT_URL:-}
COMBINED_EXPECTED_SHA=${ROSELY_COMBINED_EXPECTED_SHA256:-}

# Existing production H3 artifact. Split mode can deploy immediately without
# rebuilding the large model pack.
H3_BUCKET=${ROSELY_H3_S3_BUCKET:-rosely-infrastructure}
H3_MODEL_KEY=${ROSELY_H3_S3_MODEL_KEY:-models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst}
H3_CHECKSUM_KEY=${ROSELY_H3_S3_CHECKSUM_KEY:-models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst.sha256}
H3_REGION=${ROSELY_H3_S3_REGION:-us-east-1}
H3_ENDPOINT=${ROSELY_H3_S3_ENDPOINT_URL:-}
H3_EXPECTED_SHA=${ROSELY_H3_EXPECTED_SHA256:-dbecf6da69978835ef2be92efe1104a8c4ee904abe7ac35b8108bcba3835c006}

# Existing production Zenith/Z-Image artifact.
ZIT_BUCKET=${ROSELY_ZIT_MODEL_S3_BUCKET:-rosely-infrastructure}
ZIT_MODEL_KEY=${ROSELY_ZIT_MODEL_S3_KEY:-serverless/zimage/zenith13/zenith13-mxfp8-full-detailer-seedvr2-v3.tar.zst}
ZIT_REGION=${ROSELY_ZIT_MODEL_S3_REGION:-${AWS_ZIT_IMAGE_MODEL_S3_REGION:-us-east-1}}
ZIT_ENDPOINT=${ROSELY_ZIT_MODEL_S3_ENDPOINT_URL:-${AWS_ZIT_IMAGE_MODEL_S3_ENDPOINT_URL:-}}
ZIT_EXPECTED_SHA=${ROSELY_ZIT_EXPECTED_SHA256:-cfbd87e06b3b570c40c1436bea5cb31c0b1c70b772254d13791162f41df64fb7}
ZIT_EXPECTED_SIZE=${ROSELY_ZIT_EXPECTED_SIZE:-16309405103}

DOWNLOAD_CONCURRENCY=${ROSELY_MODEL_DOWNLOAD_CONCURRENCY:-16}
DOWNLOAD_CHUNK_MIB=${ROSELY_MODEL_DOWNLOAD_CHUNK_MIB:-64}
INSTALL_ZIT_OPTIONAL_NODES=${ROSELY_INSTALL_ZIT_OPTIONAL_NODES:-false}

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
    "At least ${required_gb} GiB free is required for ${purpose}. Use 180-200 GiB disk for comfortable retry headroom."
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

core_models_present() {
  [[ -s "$COMFY_DIR/models/diffusion_models/10Eros_Max_h3_hybrid_beta5_int8.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/vae/minimax_h3_video_vae_fp16.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/vae/minimax_h3_audio_vae_fp32.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/diffusion_models/Zenith_13.0_MXFP8_E4M3.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/text_encoders/qwen/qwen_3_4b_fp8_mixed.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/vae/Flux/flux_vae.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/loras/zpenis-zit-v1_5.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/loras/RealisticSnapshot-Zimage-Turbov5.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/loras/deedee_amateur_photography_zimage_base_and_turbo_v1.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/loras/z-image-illustria-01.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/loras/z-image-anime-01.safetensors" ]] &&
  [[ -s "$COMFY_DIR/models/loras/elusarca-anime-style.safetensors" ]]
}

core_model_sizes_sane() {
  core_models_present || return 1
  [[ $(stat -c %s "$COMFY_DIR/models/diffusion_models/10Eros_Max_h3_hybrid_beta5_int8.safetensors") -ge 20000000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors") -ge 15000000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/vae/minimax_h3_video_vae_fp16.safetensors") -ge 5000000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/vae/minimax_h3_audio_vae_fp32.safetensors") -ge 500000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/diffusion_models/Zenith_13.0_MXFP8_E4M3.safetensors") -ge 5000000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/text_encoders/qwen/qwen_3_4b_fp8_mixed.safetensors") -ge 1000000000 ]] &&
  [[ $(stat -c %s "$COMFY_DIR/models/vae/Flux/flux_vae.safetensors") -ge 100000000 ]]
}

bundle_fingerprint() {
  if [[ "$MODEL_BUNDLE_MODE" == "combined" ]]; then
    printf 'combined|%s|%s|%s' "$COMBINED_BUCKET" "$COMBINED_MODEL_KEY" "$COMBINED_EXPECTED_SHA"
  else
    printf 'split|%s|%s' "$H3_EXPECTED_SHA" "$ZIT_EXPECTED_SHA"
  fi
}

models_ready() {
  [[ -f "$READY_MARKER" ]] || return 1
  core_model_sizes_sane || return 1
  local expected actual
  expected=$(bundle_fingerprint)
  actual=$(sed -n 's/^fingerprint=//p' "$READY_MARKER" | head -1)
  [[ "$actual" == "$expected" ]]
}

mark_ready() {
  cat > "$READY_MARKER" <<EOF
profile=rosely-h3-zit-5090
mode=${MODEL_BUNDLE_MODE}
fingerprint=$(bundle_fingerprint)
verified_at=$(date -Iseconds)
EOF
}

# Generic boto3 download with optional S3 checksum object and/or fixed SHA/size.
download_artifact() {
  local label=$1 bucket=$2 key=$3 checksum_key=$4 region=$5 endpoint=$6 dest=$7 fixed_sha=$8 fixed_size=$9
  export DL_LABEL="$label" DL_BUCKET="$bucket" DL_KEY="$key" DL_CHECKSUM_KEY="$checksum_key"
  export DL_REGION="$region" DL_ENDPOINT="$endpoint" DL_DEST="$dest" DL_FIXED_SHA="$fixed_sha" DL_FIXED_SIZE="$fixed_size"
  export DL_CONCURRENCY="$DOWNLOAD_CONCURRENCY" DL_CHUNK_MIB="$DOWNLOAD_CHUNK_MIB"
  python -u - <<'PY'
from __future__ import annotations
import hashlib, os, threading, time
from pathlib import Path
import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config

MIB=1024*1024; GIB=1024**3
label=os.environ['DL_LABEL']; bucket=os.environ['DL_BUCKET']; key=os.environ['DL_KEY']
checksum_key=os.environ.get('DL_CHECKSUM_KEY',''); region=os.environ.get('DL_REGION') or 'us-east-1'
endpoint=os.environ.get('DL_ENDPOINT') or None; dest=Path(os.environ['DL_DEST'])
fixed_sha=os.environ.get('DL_FIXED_SHA','').strip().lower(); fixed_size=int(os.environ.get('DL_FIXED_SIZE') or 0)
concurrency=max(1,int(os.environ.get('DL_CONCURRENCY','16'))); chunk=max(16,int(os.environ.get('DL_CHUNK_MIB','64')))*MIB

kwargs=dict(region_name=region, endpoint_url=endpoint, config=Config(connect_timeout=60, read_timeout=900, tcp_keepalive=True, max_pool_connections=max(32,concurrency*2), retries={'mode':'standard','max_attempts':20}, signature_version='s3v4'))
# Standard AWS_* chain is preferred. Legacy ZiT model credentials remain accepted.
if not os.environ.get('AWS_ACCESS_KEY_ID') and os.environ.get('AWS_ZIT_IMAGE_MODEL_ACCESS_KEY_ID'):
    kwargs['aws_access_key_id']=os.environ['AWS_ZIT_IMAGE_MODEL_ACCESS_KEY_ID']
    kwargs['aws_secret_access_key']=os.environ['AWS_ZIT_IMAGE_MODEL_SECRET_ACCESS_KEY']
    if os.environ.get('AWS_ZIT_IMAGE_MODEL_SESSION_TOKEN'):
        kwargs['aws_session_token']=os.environ['AWS_ZIT_IMAGE_MODEL_SESSION_TOKEN']
s3=boto3.client('s3',**kwargs)
head=s3.head_object(Bucket=bucket,Key=key); size=int(head['ContentLength'])
print(f'[{label}] remote size {size/GIB:.2f} GiB',flush=True)
if fixed_size and size!=fixed_size: raise SystemExit(f'{label}: size mismatch expected {fixed_size}, got {size}')
expected=fixed_sha
if checksum_key:
    body=s3.get_object(Bucket=bucket,Key=checksum_key)['Body'].read().decode().strip()
    checksum_sha=body.split()[0].lower()
    if len(checksum_sha)!=64: raise SystemExit(f'{label}: invalid checksum object')
    if expected and checksum_sha!=expected: raise SystemExit(f'{label}: checksum object disagrees with fixed SHA')
    expected=checksum_sha
if not expected: raise SystemExit(f'{label}: expected SHA unavailable; configure checksum key or fixed SHA')

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(32*MIB),b''): h.update(b)
    return h.hexdigest()

if dest.is_file() and dest.stat().st_size==size:
    actual=sha(dest)
    if actual==expected:
        print(f'[{label}] reusing verified cached archive',flush=True); raise SystemExit(0)
    dest.unlink()

tmp=Path(str(dest)+'.part'); tmp.unlink(missing_ok=True); dest.parent.mkdir(parents=True,exist_ok=True)
transfer=TransferConfig(multipart_threshold=64*MIB,multipart_chunksize=chunk,max_concurrency=concurrency,use_threads=True)
class Progress:
    def __init__(self): self.seen=0; self.start=time.monotonic(); self.last=0; self.lock=threading.Lock()
    def __call__(self,n):
        with self.lock:
            self.seen+=n; now=time.monotonic()
            if self.seen>=size or now-self.last>=5:
                speed=self.seen/max(.001,now-self.start)
                print(f'[{label}] {self.seen/size*100:6.2f}% {self.seen/GIB:.2f}/{size/GIB:.2f} GiB {speed/MIB:.1f} MiB/s',flush=True); self.last=now
s3.download_file(bucket,key,str(tmp),Config=transfer,Callback=Progress())
if tmp.stat().st_size!=size: tmp.unlink(missing_ok=True); raise SystemExit(f'{label}: downloaded size mismatch')
actual=sha(tmp)
if actual!=expected: tmp.unlink(missing_ok=True); raise SystemExit(f'{label}: SHA mismatch expected {expected}, got {actual}')
tmp.replace(dest); print(f'[{label}] verified SHA-256 {actual}',flush=True)
PY
}

extract_combined_bundle() {
  local archive="$STATE_DIR/combined-models.tar.zst"
  log "Downloading combined H3+ZiT bundle"
  download_artifact combined "$COMBINED_BUCKET" "$COMBINED_MODEL_KEY" "$COMBINED_CHECKSUM_KEY" "$COMBINED_REGION" "$COMBINED_ENDPOINT" "$archive" "$COMBINED_EXPECTED_SHA" 0
  check_disk_space "$MIN_EXTRACT_FREE_GB" "combined model extraction"
  log "Extracting combined model artifact"
  tar --zstd --no-same-owner -xf "$archive" -C /workspace
  if [[ -f /workspace/model-files.sha256 ]]; then
    log "Verifying combined internal model manifest"
    (cd /workspace && sha256sum -c model-files.sha256)
    rm -f /workspace/model-files.sha256
  fi
  rm -f "$archive"
}

extract_split_bundles() {
  local h3_archive="$STATE_DIR/h3.tar.zst" zit_archive="$STATE_DIR/zit.tar.zst" staging="$STATE_DIR/zit-staging"
  log "Downloading current H3 production artifact"
  download_artifact h3 "$H3_BUCKET" "$H3_MODEL_KEY" "$H3_CHECKSUM_KEY" "$H3_REGION" "$H3_ENDPOINT" "$h3_archive" "$H3_EXPECTED_SHA" 0
  check_disk_space "$MIN_EXTRACT_FREE_GB" "H3 model extraction"
  tar --zstd --no-same-owner -xf "$h3_archive" -C /workspace
  if [[ -f /workspace/model-files.sha256 ]]; then
    log "Verifying H3 internal manifest"
    (cd /workspace && sha256sum -c model-files.sha256)
    rm -f /workspace/model-files.sha256
  else
    fail "H3 archive did not contain /workspace/model-files.sha256"
  fi
  rm -f "$h3_archive"

  log "Downloading current ZiT production artifact"
  download_artifact zit "$ZIT_BUCKET" "$ZIT_MODEL_KEY" "" "$ZIT_REGION" "$ZIT_ENDPOINT" "$zit_archive" "$ZIT_EXPECTED_SHA" "$ZIT_EXPECTED_SIZE"
  rm -rf "$staging"; mkdir -p "$staging"
  tar --zstd --no-same-owner -xf "$zit_archive" -C "$staging"
  [[ -d "$staging/models" ]] || fail "ZiT archive does not contain models/ root"
  log "Merging ZiT model tree into the shared ComfyUI model directory"
  while IFS= read -r -d '' src; do
    rel=${src#"$staging/models/"}
    dst="$COMFY_DIR/models/$rel"
    mkdir -p "$(dirname "$dst")"
    rm -f "$dst"
    mv "$src" "$dst"
    chmod 0644 "$dst"
  done < <(find "$staging/models" -type f -print0)
  rm -rf "$staging" "$zit_archive"
}

install_git_node() {
  local repo=$1 ref=$2 dirname=$3 dest="$COMFY_DIR/custom_nodes/$3"
  rm -rf "$dest"; mkdir -p "$dest"
  git -C "$dest" init -q
  git -C "$dest" remote add origin "$repo"
  git -C "$dest" fetch -q --depth 1 origin "$ref"
  git -C "$dest" checkout -q --detach FETCH_HEAD
}

install_optional_zit_nodes() {
  [[ "$INSTALL_ZIT_OPTIONAL_NODES" == "true" ]] || { log "Optional ZiT detailer/upscaler nodes disabled (base fallback workflows do not need them)"; return; }
  log "Installing pinned optional ZiT detailer/upscaler nodes"
  local impact_ref=429d0159ad429e64d2b3916e6e7be9c22d025c3c
  local sub_ref=50c7b71a6a224734cc9b21963c6d1926816a97f1
  local seed_ref=4490bd1f482e026674543386bb2a4d176da245b9
  local vr_ref=f633a8b0824e81cd9e3ad2f9f0f51f1f9680353b
  mkdir -p "$COMFY_DIR/custom_nodes"
  install_git_node https://github.com/ltdrdata/ComfyUI-Impact-Pack.git "$impact_ref" ComfyUI-Impact-Pack
  install_git_node https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git "$sub_ref" ComfyUI-Impact-Subpack
  install_git_node https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git "$seed_ref" ComfyUI-SeedVR2_VideoUpscaler
  install_git_node https://github.com/vrgamegirl19/comfyui-vrgamedevgirl.git "$vr_ref" comfyui-vrgamedevgirl
  python -m pip install --prefer-binary -r "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Pack/requirements.txt"
  COMFYUI_PATH="$COMFY_DIR" COMFYUI_MODEL_PATH="$COMFY_DIR/models" python "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Pack/install.py"
  python -m pip install --prefer-binary -r "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Subpack/requirements.txt"
  awk '!/^(torch|torchvision|torchaudio|opencv-python)([<>= ].*)?$/' "$COMFY_DIR/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler/requirements.txt" > "$STATE_DIR/seedvr2-requirements.filtered.txt"
  python -m pip install --prefer-binary -r "$STATE_DIR/seedvr2-requirements.filtered.txt"
  python -m pip install --prefer-binary -r "$COMFY_DIR/custom_nodes/comfyui-vrgamedevgirl/requirements.txt"
  python -m pip install --prefer-binary av imageio-ffmpeg transformers requests
  if ! python -c 'import torchaudio' >/dev/null 2>&1; then
    local torch_ver; torch_ver=$(python -c 'import torch; print(torch.__version__.split("+")[0])')
    python -m pip install --no-deps "torchaudio==${torch_ver}"
  fi
  if [[ -d "$COMFY_DIR/models/seedvr2" ]]; then
    rm -rf "$COMFY_DIR/models/SEEDVR2"
    ln -s "$COMFY_DIR/models/seedvr2" "$COMFY_DIR/models/SEEDVR2"
  fi
}

validate_core_models() {
  core_model_sizes_sane || fail "One or more H3/ZiT core model files are missing or unexpectedly small"
  log "Core H3 and ZiT model files validated"
  du -sh "$COMFY_DIR/models" || true
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

log "Provisioning START mode=${MODEL_BUNDLE_MODE} repo=${PYWORKER_REPO}@${PYWORKER_REF}"
[[ "$MODEL_BUNDLE_MODE" == "split" || "$MODEL_BUNDLE_MODE" == "combined" ]] || fail "MODEL_BUNDLE_MODE must be split or combined"
if [[ "$MODEL_BUNDLE_MODE" == "combined" && ! "$COMBINED_EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
  fail "ROSELY_COMBINED_EXPECTED_SHA256 must be the exact 64-character SHA-256 when MODEL_BUNDLE_MODE=combined"
fi

ensure_system_packages
[[ -f /venv/main/bin/activate ]] || fail "/venv/main missing; use a recent Vast PyTorch CUDA image with RTX 5090/Blackwell support"
source /venv/main/bin/activate

log "Checking CUDA / Blackwell"
python - <<'PY'
import torch
print('Torch:',torch.__version__,'CUDA:',torch.version.cuda,'available:',torch.cuda.is_available())
if not torch.cuda.is_available(): raise SystemExit('CUDA unavailable')
name=torch.cuda.get_device_name(0); cap=torch.cuda.get_device_capability(0)
print('GPU:',name,'compute capability:',cap)
if cap[0] < 12: raise SystemExit(f'Blackwell GPU required; detected {name} capability {cap}')
PY

log "Cloning combined deployment repository"
rm -rf "$APP_DIR"
git clone --progress --depth 1 --single-branch --branch "$PYWORKER_REF" "$PYWORKER_REPO" "$APP_DIR"
[[ -f "$APP_DIR/worker.py" && -f "$APP_DIR/model_server.py" ]] || fail "Combined repository is incomplete"

log "Installing application dependencies"
python -m pip install --prefer-binary -r "$APP_DIR/requirements.txt"
install_comfyui_preserving_models
log "Installing pinned ComfyUI dependencies"
python -m pip install --prefer-binary -r "$COMFY_DIR/requirements.txt"
mkdir -p "$COMFY_DIR/models"/{diffusion_models,text_encoders,vae,loras} "$COMFY_DIR"/{input,output,temp}

if models_ready; then
  log "Verified combined model state already present; skipping model download"
else
  rm -f "$READY_MARKER"
  check_disk_space "$MIN_FREE_DISK_GB" "fresh H3+ZiT provisioning"
  if [[ "$MODEL_BUNDLE_MODE" == "combined" ]]; then
    extract_combined_bundle
  else
    extract_split_bundles
  fi
  validate_core_models
  mark_ready
fi

# Ensure optional SeedVR2 compatibility alias whenever those assets exist.
if [[ -d "$COMFY_DIR/models/seedvr2" ]]; then
  rm -rf "$COMFY_DIR/models/SEEDVR2"
  ln -s "$COMFY_DIR/models/seedvr2" "$COMFY_DIR/models/SEEDVR2"
fi
install_optional_zit_nodes
validate_core_models

log "Disabling generic/conflicting model services"
for service in api-wrapper comfyui h3-comfyui h3-model-server rosely-comfyui rosely-model-server; do
  supervisorctl stop "$service" >/dev/null 2>&1 || true
done
for config in /etc/supervisor/conf.d/api-wrapper.conf /etc/supervisor/conf.d/comfyui.conf /etc/supervisor/conf.d/h3-services.conf; do
  [[ -f "$config" ]] && mv "$config" "${config}.disabled"
done
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true

log "Installing combined Supervisor services"
mkdir -p /opt/rosely-h3-zit-serverless
cp "$APP_DIR/scripts/start_comfyui.sh" /opt/rosely-h3-zit-serverless/
cp "$APP_DIR/scripts/start_model_server.sh" /opt/rosely-h3-zit-serverless/
chmod +x /opt/rosely-h3-zit-serverless/*.sh
cp "$APP_DIR/supervisor/combined-services.conf" /etc/supervisor/conf.d/combined-services.conf
supervisorctl reread
supervisorctl update

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

log "Waiting for combined FastAPI model server"
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

log "PROVISIONING COMPLETE"
supervisorctl status rosely-comfyui rosely-model-server || true
curl -fsS http://127.0.0.1:18288/health | jq . || true
nvidia-smi || true
df -h /workspace
log "Dedicated log: /var/log/portal/combined-provision.log"
