#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'TXT'
Usage:
  build_combined_bundle.sh H3_ARCHIVE.tar.zst ZIT_ARCHIVE.tar.zst OUTPUT.tar.zst

The H3 archive must contain ComfyUI/models/... and model-files.sha256.
The ZiT archive must contain models/... .
The output contains a single ComfyUI/models/... tree plus a regenerated
model-files.sha256 manifest at archive root.
TXT
}

[[ $# -eq 3 ]] || { usage; exit 2; }
H3_ARCHIVE=$(realpath "$1")
ZIT_ARCHIVE=$(realpath "$2")
OUTPUT=$(realpath -m "$3")
[[ -f "$H3_ARCHIVE" ]] || { echo "Missing H3 archive: $H3_ARCHIVE" >&2; exit 1; }
[[ -f "$ZIT_ARCHIVE" ]] || { echo "Missing ZiT archive: $ZIT_ARCHIVE" >&2; exit 1; }
command -v zstd >/dev/null || { echo "zstd is required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"
ZIT="$WORK/zit"
mkdir -p "$ROOT" "$ZIT" "$(dirname "$OUTPUT")"

echo "[1/5] Extracting H3 archive..."
tar --zstd --no-same-owner -xf "$H3_ARCHIVE" -C "$ROOT"
[[ -d "$ROOT/ComfyUI/models" ]] || { echo "H3 archive missing ComfyUI/models" >&2; exit 1; }

echo "[2/5] Extracting ZiT archive..."
tar --zstd --no-same-owner -xf "$ZIT_ARCHIVE" -C "$ZIT"
[[ -d "$ZIT/models" ]] || { echo "ZiT archive missing models/ root" >&2; exit 1; }

echo "[3/5] Merging ZiT model tree..."
while IFS= read -r -d '' src; do
  rel=${src#"$ZIT/models/"}
  dst="$ROOT/ComfyUI/models/$rel"
  mkdir -p "$(dirname "$dst")"
  cp -f --reflink=auto "$src" "$dst"
done < <(find "$ZIT/models" -type f -print0)

# Avoid carrying the old H3-only manifest into the new artifact.
rm -f "$ROOT/model-files.sha256"

echo "[4/5] Generating full model checksum manifest..."
(
  cd "$ROOT"
  find ComfyUI/models -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum > model-files.sha256
)

# Validate the final core set before spending time compressing it.
required=(
  "ComfyUI/models/diffusion_models/10Eros_Max_h3_hybrid_beta5_int8.safetensors"
  "ComfyUI/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
  "ComfyUI/models/vae/minimax_h3_video_vae_fp16.safetensors"
  "ComfyUI/models/vae/minimax_h3_audio_vae_fp32.safetensors"
  "ComfyUI/models/diffusion_models/Zenith_13.0_MXFP8_E4M3.safetensors"
  "ComfyUI/models/text_encoders/qwen/qwen_3_4b_fp8_mixed.safetensors"
  "ComfyUI/models/vae/Flux/flux_vae.safetensors"
  "ComfyUI/models/loras/zpenis-zit-v1_5.safetensors"
  "ComfyUI/models/loras/RealisticSnapshot-Zimage-Turbov5.safetensors"
  "ComfyUI/models/loras/deedee_amateur_photography_zimage_base_and_turbo_v1.safetensors"
  "ComfyUI/models/loras/z-image-illustria-01.safetensors"
  "ComfyUI/models/loras/z-image-anime-01.safetensors"
  "ComfyUI/models/loras/elusarca-anime-style.safetensors"
)
for rel in "${required[@]}"; do
  [[ -s "$ROOT/$rel" ]] || { echo "Missing final model: $rel" >&2; exit 1; }
done

LEVEL=${ZSTD_LEVEL:-10}
THREADS=${ZSTD_THREADS:-0}
echo "[5/5] Creating $OUTPUT (zstd level=$LEVEL threads=$THREADS)..."
rm -f "$OUTPUT" "$OUTPUT.sha256"
(
  cd "$ROOT"
  tar -cf - ComfyUI/models model-files.sha256 \
    | zstd -T"$THREADS" -"$LEVEL" -o "$OUTPUT"
)
sha256sum "$OUTPUT" > "$OUTPUT.sha256"

echo
echo "Combined bundle ready:"
ls -lh "$OUTPUT" "$OUTPUT.sha256"
cat "$OUTPUT.sha256"
