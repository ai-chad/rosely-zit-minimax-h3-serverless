# Deployment procedure

## 1. First deploy in split mode

Create a new GitHub repository (recommended: `rosely-h3-zit-5090-serverless`) and upload this package unchanged.

In Vast, use the same Blackwell-compatible base image you use for the current H3 endpoint. Configure the environment from `.env.example`, keeping:

```text
MODEL_BUNDLE_MODE=split
ROSELY_INSTALL_ZIT_OPTIONAL_NODES=false
FREE_ON_FAMILY_SWITCH=true
REJECT_IMAGE_WHILE_VIDEO_BUSY=true
```

The split deployment downloads your existing H3 and ZiT S3 artifacts, verifies their known checksums, and merges them into the one shared `/workspace/ComfyUI/models` tree.

Do not route production fallback traffic yet. First test the new endpoint independently.

## 2. Smoke test the endpoint

Install the current Vast client locally:

```bash
pip install "vastai[serverless]"
```

Image:

```bash
python test_vast_combined.py \
  --endpoint rosely-h3-zit-5090 \
  --kind image \
  --mode realistic \
  --prompt "portrait of an adult person, natural skin texture, soft daylight"
```

Video:

```bash
python test_vast_combined.py \
  --endpoint rosely-h3-zit-5090 \
  --kind video \
  --input-image-url "https://YOUR-TEST-IMAGE" \
  --prompt "Preserve identity, subtle natural movement, stable camera"
```

Then repeat image -> image -> video to test both switching directions.

## 3. Backend routing

Recommended production behavior:

```text
image request
  -> primary ZiT endpoint
  -> if primary is overloaded / selected timeout / retryable 5xx
       -> combined endpoint /generate/image
          -> if 503 video_generation_in_progress
               -> do NOT wait on the 5090; retry/queue primary image path
```

Do not send fallback images blindly whenever a primary request is merely slow. Use your primary queue depth / capacity signal when possible.

Video requests can continue using the existing H3 endpoint until the combined endpoint has passed live switching tests. Then move video to the combined endpoint if desired.

## 4. Switch to one combined model artifact

Build and upload the merged artifact using `MODEL_BUNDLE.md`, then change:

```text
MODEL_BUNDLE_MODE=combined
ROSELY_COMBINED_S3_MODEL_KEY=...
ROSELY_COMBINED_S3_CHECKSUM_KEY=...
ROSELY_COMBINED_EXPECTED_SHA256=<sha256>
```

Roll one worker first and repeat the transition smoke test before replacing the rest.

## Logs

```bash
tail -f /var/log/portal/combined-provision.log
tail -f /var/log/portal/comfyui.log
tail -f /var/log/portal/model-server.log
/opt/rosely-h3-zit-serverless/status.sh
```

## Rollback

This bundle does not modify either current repository. If the combined endpoint misbehaves, point video back to the existing H3 endpoint and disable the image fallback route. No model/API migration is required.
