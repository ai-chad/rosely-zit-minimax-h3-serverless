# Rosely H3 + ZiT RTX 5090 Vast Serverless

Combined **single-GPU / single-ComfyUI** Vast Serverless deployment for:

- MiniMax H3 / `10Eros_Max_h3_hybrid_beta5_int8.safetensors` video generation
- Zenith 13 / Z-Image image generation as an overflow/fallback path

The existing production H3 and ZiT repositories are not modified. This repository is intended to be deployed as a third endpoint until the combined worker is proven in production.

## Why this layout

Only one ComfyUI process owns the RTX 5090. A single FastAPI model server exposes:

- `POST /generate/video`
- `POST /generate/image`
- `POST /generate/sync` (compatibility dispatcher)

Every generation passes through one `asyncio.Lock`, so H3 and ZiT cannot execute on the GPU simultaneously. When the requested model family changes, the server calls ComfyUI `/free` with `unload_models=true` and `free_memory=true` before submitting the next workflow. Consecutive requests from the same family stay warm.

By default, a ZiT fallback request arriving while an H3 video is actively running returns HTTP 503 with `video_generation_in_progress` instead of sitting behind a long video. Your backend can then keep/retry the primary image route.

## Model modes

The provisioner supports two modes:

### `MODEL_BUNDLE_MODE=split`

Uses the two current production archives directly. This is the safest first smoke test because it does not require rebuilding the model bundle.

### `MODEL_BUNDLE_MODE=combined`

Uses one merged `tar.zst` containing:

```text
ComfyUI/models/
  diffusion_models/
    10Eros_Max_h3_hybrid_beta5_int8.safetensors
    Zenith_13.0_MXFP8_E4M3.safetensors
  text_encoders/
    qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
    qwen/qwen_3_4b_fp8_mixed.safetensors
  vae/
    minimax_h3_video_vae_fp16.safetensors
    minimax_h3_audio_vae_fp32.safetensors
    Flux/flux_vae.safetensors
  ...ZiT LoRAs / optional assets...
model-files.sha256
```

Use `scripts/build_combined_bundle.sh` to build it from your two existing archives.

## Vast template

Recommended repository name:

```text
https://github.com/robert2398/rosely-h3-zit-5090-serverless.git
```

Set:

```text
SERVERLESS=true
PYWORKER_REPO=https://github.com/robert2398/rosely-h3-zit-5090-serverless.git
PYWORKER_REF=main
PROVISIONING_SCRIPT=https://raw.githubusercontent.com/robert2398/rosely-h3-zit-5090-serverless/main/provision.sh
```

Copy the remaining values from `.env.example` into the Vast template secrets/environment.

Recommended worker:

- RTX 5090 32 GB
- recent Blackwell-capable Vast PyTorch/CUDA image
- 64 GB RAM minimum; 96 GB+ preferred
- **180-200 GB disk recommended** during initial model provisioning

## Image request

```json
{
  "input": {
    "task_type": "image",
    "request_id": "img_123",
    "mode": "realistic",
    "prompt": "portrait of an adult person, natural skin texture, soft daylight",
    "width": 768,
    "height": 1344,
    "steps": 12,
    "seed": 12345
  }
}
```

Supported ZiT modes:

```text
realistic
realistic_male
realistic_trans
realistic_snapshot
realistic_amateur
anime_illustria
anime_modern
anime_elusarca
anime (alias of anime_illustria)
```

The current ZiT `workflow_json` request shape is also accepted on `/generate/image` and `/generate/sync`. The server replaces `SaveImage.filename_prefix` with a request-specific output path before execution.

## Video request

Your current H3 input shape remains valid. You can optionally add `task_type: "video"`:

```json
{
  "input": {
    "task_type": "video",
    "request_id": "video_123",
    "input_image_url": "https://example.com/reference.png",
    "prompt": "Natural coherent movement while preserving identity.",
    "width": 480,
    "height": 864,
    "duration_seconds": 5,
    "steps": 8,
    "scheduler": "simple",
    "include_audio": true
  }
}
```

`/generate/sync` defaults to H3/video unless the request explicitly identifies ZiT/image, contains `workflow_json`, or uses a ZiT `mode`.

## Output

Both routes return an S3 presigned URL and metadata:

```json
{
  "status": "completed",
  "task_type": "image",
  "output_url": "...",
  "s3_uri": "s3://...",
  "generation_seconds": 42.1
}
```

Video and image output prefixes are configured independently.

## Health

```bash
curl -s http://127.0.0.1:18288/health | jq .
curl -s http://127.0.0.1:18288/ready | jq .
curl -s http://127.0.0.1:18288/status | jq .
```

`/status` reports `active_family`, `current_job_family`, whether the GPU is busy, and family-switch count.

## Validation

Before publishing:

```bash
./scripts/static_check.sh
```

After a live Vast deployment, run at minimum:

1. H3 video from cold start.
2. ZiT image immediately after H3 (tests H3 -> ZiT switch).
3. Another ZiT image (tests warm reuse).
4. H3 video immediately after ZiT (tests ZiT -> H3 switch).
5. Start H3 and send ZiT concurrently; ZiT should receive `video_generation_in_progress` rather than cause VRAM contention.
6. Check `nvidia-smi`, `/health`, output S3 objects, and logs after every transition.

See `DEPLOYMENT.md` and `MODEL_BUNDLE.md` for exact rollout steps.
# rosely-zit-minimax-h3-serverless
