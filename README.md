# Rosely Unified GPU Serverless Worker (v3 — ZiT + MiniMax H3 v1.0 + Voice Avatar)

Combined **single-GPU** Vast Serverless deployment serving all three Rosely model families on one instance:

- **Zenith 13 / Z-Image (`ZiT`)**: `Zenith_13.0_MXFP8_E4M3.safetensors` + LoRAs + FaceDetailer + SeedVR2 7B upscaler
- **MiniMax H3 (`10Eros-Max v1.0`)**: `10Eros_Max_8stepTurbo_v1.0_hybrid-int8_HQ.safetensors` (Beta 5 + Beta 7 + Sulphur-3 FL2VA hybrid, 8-step turbo; recommended `ROSELY_H3_FORCE_SAMPLER=lcm`)
- **Voice Avatar + Ditto Talking-Head**: `Qwen3-ASR-0.6B` (STT) + `Chatterbox Turbo` (TTS + 28 built-in voices) + `Ditto TensorRT 8.6.1` (turn-based video clips + optional LiveKit WebRTC live calls)

## Fast-Boot Staged Architecture

All three bundles use **direct per-file S3 manifests (`manifest.json`)** in `s3://rosely-infrastructure` (`us-east-1`) with **two-phase staged startup**:

1. **Phase 1 (~2–3 min to live ZiT traffic):**
   - `provision.sh` runs `scripts/sync_models.py --family zit` **in parallel** with `uv` installation of ComfyUI + optional ZiT nodes.
   - As soon as ZiT + ComfyUI are ready, Supervisor starts `rosely-comfyui`, `rosely-model-server`, `rosely-h3-sync`, and `rosely-voice-sync`.
   - `/health` returns `200 OK` as soon as ZiT is ready (`models: {"zit": "available", "h3": "downloading", "voice": "downloading"}`), and `worker.py` runs a fast `512×512` 4-step ZiT benchmark so Vast Serverless marks the worker READY right away.
2. **Phase 2 (background H3 + Voice Avatar sync in parallel):**
   - `rosely-h3-sync` downloads & verifies the 4 `beta7_sulpher3` MiniMax H3 files (`41.34 GiB`).
   - `rosely-voice-sync` downloads & verifies the 64-file `rosely-voice-ditto-v1` bundle (`7.47 GiB`: Qwen3-ASR + Chatterbox + Ditto TRT engines + 28 pre-converted 24 kHz mono WAVs + pinned Ditto source), clones `rosely-vast-voice-avatar`, installs isolated Python 3.10 venvs (`asr`, `tts`, `ditto` + private `cudnn8`) via `uv`, and marks `voice.ready`.
   - Requests to `/generate/video` or `/v1/*` wait cleanly for `h3.ready` / `voice.ready` **without holding `generation_lock`**, so ZiT image traffic continues unblocked.

## Single-GPU Coordination & VRAM Protection (`ROSELY_VOICE_VRAM_MODE`)

One FastAPI coordinator (`model_server.py`, port `18288`) owns a global `asyncio.Lock` across all 8 PyWorker routes:

- Image & Video: `POST /generate/image`, `POST /generate/video`, `POST /generate/sync`
- Voice & Ditto Avatar: `POST /v1/tts`, `POST /v1/stt`, `POST /v1/avatar/generate`, `POST /v1/ditto/warm`, `POST /v1/live/join`

VRAM behavior is controlled by `ROSELY_VOICE_VRAM_MODE` (`auto` | `switch` | `resident`):
- **`switch` (default on `< 30 GiB` GPUs such as RTX 4090 24 GB):**
  - Switching `zit`/`h3` → `voice` calls ComfyUI `/free` (`unload_models=true, free_memory=true`) and starts `asr` + `tts` + `ditto` (+ optional `live`) **in parallel** (~10–15 s). Consecutive voice/avatar/live calls stay warm with zero switch overhead.
  - Switching `voice` → `zit`/`h3` stops the voice GPU workers (~1–2 s) so ComfyUI receives 100% of the 24 GB VRAM with zero OOM risk.
  - While an active LiveKit call is running (`live_agent /health` reports `busy: true`), `zit`/`h3` requests return `503 live_call_in_progress` (retryable) instead of interrupting the live call.
- **`resident` (default on `>= 30 GiB` GPUs, or explicitly set):** keeps the voice services resident across switches.

> **GPU Architecture Note (RTX 4090 vs RTX 5090):**
> - **RTX 4090 (Ada Lovelace, SM89, 24 GB):** Supports **all 3 model families natively** (ZiT + H3 v1.0 + Voice + Ditto TensorRT 8.6.1 `ditto_trt_Ampere_Plus`).
> - **RTX 5090 (Blackwell, SM120, 32 GB):** ZiT + H3 v1.0 run at peak native speed, but Ditto's pre-compiled TensorRT 8.6.1 `ditto_trt_Ampere_Plus` engines predate Blackwell SM120 and require ONNX→TRT10 recompilation if Voice+Ditto is enabled on a 5090.

## S3 Direct Per-File Artifacts (`rosely-infrastructure`, `us-east-1`)

- **MiniMax H3 (`beta7_sulpher3` — `10Eros-Max v1.0`, `41.34 GiB`, 4 files):**
  - Manifest: `models/minimax-h3/beta7_sulpher3/manifest.json`
  - SHA-256: `45ad09171573a127d7388e6ab22ed0852069bc1046d5931bb821579175b7d529`
- **Zenith 13 / Z-Image (`v3-direct`, `17.97 GiB`, 16 files including official SeedVR2 7B):**
  - Manifest: `serverless/zimage/zenith13/zenith13-mxfp8-full-detailer-seedvr2-v3-direct/manifest.json`
  - SHA-256: `14b308d29489719b09beeff9708e6961537319eadc02cdac4f94b68da47fd6d4`
- **Voice Avatar + Ditto (`rosely-voice-ditto-v1`, `7.47 GiB`, 64 files):**
  - Manifest: `models/voice-avatar/rosely-voice-ditto-v1/manifest.json`
  - SHA-256: `334a6170d549cae722100b49cfdd716e0d59882d90fd6d68c9e59e22704e4421`

## Vast Template Settings

- Base image: `vastai/pytorch:cuda-13.0.3-auto`
- Disk: `150 GB` (`~82–90 GB` used for ZiT + H3 + Voice models + 3 isolated venvs, leaving `~60 GB` for Ditto cache & temp files)
- GPU: RTX 4090 24 GB (all 3 models native) or RTX 5090 32 GB (image + video; see Blackwell TRT 8.6.1 note above)
- RAM: 64 GB minimum; 96 GB+ preferred
- See [VAST_CREATE_COMMAND.txt](VAST_CREATE_COMMAND.txt) and [.env.example](.env.example).

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
- `/var/log/portal/voice-model-sync.log`
- `/var/log/portal/comfyui.log`
- `/var/log/portal/model-server.log`
- `/workspace/rosely-logs/{asr,tts,ditto,live,gateway}.log`

## Validation

```bash
./scripts/static_check.sh
```
