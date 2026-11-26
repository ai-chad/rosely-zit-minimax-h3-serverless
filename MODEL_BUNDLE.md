# Direct Per-File S3 Model Bundles (`manifest.json`)

This deployment defaults to **direct per-file S3 manifests** instead of monolithic `.tar.zst` archives.

## Why direct per-file + `manifest.json`

- `.safetensors` weights are high-entropy and barely compress (<10% savings with zstd).
- Downloading individual files directly from S3 with `scripts/sync_models.py`:
  - eliminates tar+zstd extraction time;
  - avoids storing both a ~36–52 GiB archive and extracted tree simultaneously on `--disk 150`;
  - verifies exact byte size + SHA-256 per file in parallel as each file completes;
  - atomically renames each verified file from `/workspace/.rosely-h3-zit/<family>-staging/` into `/workspace/ComfyUI/models/...`, so ComfyUI never observes partial files and automatically invalidates its directory-mtime cache.

## Publishing a new direct model bundle from EC2

Stage the model tree using the relative layout expected under `ComfyUI/models/`:

```text
<source_dir>/
  diffusion_models/10Eros_Max_8stepTurbo_v1.0_hybrid-int8_HQ.safetensors
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
  vae/minimax_h3_video_vae_fp16.safetensors
  vae/minimax_h3_audio_vae_fp32.safetensors
```

Then run:

```bash
python3 scripts/publish_direct_bundle.py \
  --family h3 \
  --bundle-name beta7_sulpher3 \
  --source-dir /mnt/h3-build/beta7_sulpher3/files \
  --bucket rosely-infrastructure \
  --s3-prefix models/minimax-h3/beta7_sulpher3 \
  --region us-east-1 \
  --skip-existing
```

This uploads each file under `<s3-prefix>/files/...`, writes `<s3-prefix>/manifest.json` and `<s3-prefix>/manifest.json.sha256`, and prints the exact `MANIFEST_KEY` and `MANIFEST_SHA256` to paste into your Vast template (`.env.example` / `VAST_CREATE_COMMAND.txt`).

## Legacy `.tar.zst` compatibility

`scripts/sync_models.py` automatically detects `.tar.zst` keys if you point `ROSELY_H3_MODEL_KEY` or `ROSELY_ZIT_MODEL_KEY` back at an archive object. `scripts/build_combined_bundle.sh` is also retained for legacy combined-archive workflows.
