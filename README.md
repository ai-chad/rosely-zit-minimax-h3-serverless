# Rosely H3 + ZiT RTX 5090 Vast Serverless (v2 — Direct Per-File Fast Boot)

Combined **single-GPU / single-ComfyUI** Vast Serverless deployment for:

- **MiniMax H3 / `10Eros-Max v1.0`** (`10Eros_Max_8stepTurbo_v1.0_hybrid-int8_HQ.safetensors` — Beta 5 + Beta 7 + Sulphur-3 FL2VA hybrid with baked-in 8-step turbo)
- **Zenith 13 / Z-Image** (`Zenith_13.0_MXFP8_E4M3.safetensors` + LoRAs + optional FaceDetailer / SeedVR2)

## Fast-Boot Staged Architecture

Unlike legacy archive-based provisioning (~5+ min cold boot), v2 uses **direct per-file S3 manifests (`manifest.json`)** and **two-phase staged startup**:

1. **Phase 1 (~60–90s to live ZiT traffic):**
   - `provision.sh` starts `scripts/sync_models.py --family zit` **in parallel** with `ComfyUI/requirements.txt` and optional ZiT custom nodes (which also clone in parallel).
   - Direct per-file downloads stream straight from S3 to `/workspace/.rosely-h3-zit/zit-staging/`, verify exact size + SHA-256 per file, and atomically rename into `/workspace/ComfyUI/models/...` — **zero tar/zstd extraction time and zero temporary archive disk overhead**.
   - As soon as ZiT + ComfyUI are ready, Supervisor starts `rosely-comfyui`, `rosely-model-server`, and `rosely-h3-sync` in the background.
   - `/health` returns `200 OK` as soon as ZiT is ready (`models: {"zit": "available", "h3": "downloading"}`), and `worker.py` runs a tiny `512x512` 4-step ZiT benchmark so Vast Serverless marks the worker READY right away.
2. **Phase 2 (background H3 sync, ~1–2 min later):**
   - `rosely-h3-sync` downloads the 4 `beta7_sulpher3` MiniMax H3 files directly from S3 in parallel, verifies SHA-256 per file, atomically moves them into `/workspace/ComfyUI/models/...` (which automatically invalidates ComfyUI's directory-mtime cache), and writes `/workspace/.rosely-h3-zit/h3.ready`.
   - If a `/generate/video` request arrives while H3 is still downloading, `model_server.py` waits cleanly for `h3.ready` **without holding `generation_lock`** (so ZiT image traffic continues unblocked) and then runs the video seamlessly.

## Why single ComfyUI + single GPU lock

Only one ComfyUI process owns the RTX 5090. A single FastAPI model server exposes:

- `POST /generate/video`
- `POST /generate/image`
- `POST /generate/sync` (compatibility dispatcher)

Every generation passes through one `asyncio.Lock`, so H3 and ZiT cannot execute on the GPU simultaneously. When the requested model family changes, the server calls ComfyUI `/free` with `unload_models=true` and `free_memory=true` before submitting the next workflow. Consecutive requests from the same family stay warm.

By default, a ZiT fallback request arriving while an H3 video is actively running returns HTTP 503 with `video_generation_in_progress` instead of sitting behind a long video.

## S3 Direct Per-File Artifacts (`rosely-infrastructure`, `us-east-1`)

- **MiniMax H3 (`beta7_sulpher3` — `10Eros-Max v1.0`):**
  - Manifest: `models/minimax-h3/beta7_sulpher3/manifest.json`
  - Checksum: `models/minimax-h3/beta7_sulpher3/manifest.json.sha256`
  - Files:
    - `diffusion_models/10Eros_Max_8stepTurbo_v1.0_hybrid-int8_HQ.safetensors`
    - `text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`
    - `vae/minimax_h3_video_vae_fp16.safetensors`
    - `vae/minimax_h3_audio_vae_fp32.safetensors`
- **Zenith 13 / Z-Image (v3 direct):**
  - Manifest: `serverless/zimage/zenith13/zenith13-mxfp8-full-detailer-seedvr2-v3-direct/manifest.json`
  - Checksum: `serverless/zimage/zenith13/zenith13-mxfp8-full-detailer-seedvr2-v3-direct/manifest.json.sha256`

Legacy `.tar.zst` keys remain supported automatically by `scripts/sync_models.py` if configured.

## Vast Template Settings

- Base image: `vastai/pytorch:cuda-13.0.3-auto`
- Disk: `150 GB` (direct per-file mode uses ~60 GB total models with zero archive temp space)
- GPU: RTX 5090 32 GB (Blackwell, compute capability >= 12)
- RAM: 64 GB minimum; 96 GB+ preferred
- See [VAST_CREATE_COMMAND.txt](VAST_CREATE_COMMAND.txt) and [.env.example](.env.example).

## Video Request (`10Eros-Max v1.0`)

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
    "sampler": "res_multistep",
    "scheduler": "simple",
    "include_audio": true
  }
}
```

Supported H3 samplers: `res_multistep` (default), `lcm`, `euler`, `er_sde`, `dpmpp_2m`, `dpmpp_sde`, `uni_pc`.
Supported H3 schedulers: `simple` (default), `normal`, `beta`, `sgm_uniform`, `beta57`, `karras`, `ddim_uniform`.
Set `ROSELY_H3_FORCE_SAMPLER=lcm` (or `euler`, etc.) to override sampler across all requests during experimentation without modifying the backend.

## Image Request (ZiT)

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

Supported ZiT modes: `realistic`, `realistic_male`, `realistic_trans`, `realistic_snapshot`, `realistic_amateur`, `anime_illustria`, `anime_modern`, `anime_elusarca`, `anime` (alias of `anime_illustria`), plus raw `workflow_json`.

## Health & Observability

```bash
curl -s http://127.0.0.1:18288/health | jq .
curl -s http://127.0.0.1:18288/ready | jq .
curl -s http://127.0.0.1:18288/status | jq .
/opt/rosely-h3-zit-serverless/status.sh
```

Logs:
- `/var/log/portal/combined-provision.log`
- `/var/log/portal/zit-model-sync.log`
- `/var/log/portal/h3-model-sync.log`
- `/var/log/portal/comfyui.log`
- `/var/log/portal/model-server.log`

## Validation

```bash
./scripts/static_check.sh
```
