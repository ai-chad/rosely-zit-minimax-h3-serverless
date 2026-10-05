# Building the single H3 + ZiT model artifact

The deployment package does not contain the ~50 GB of model weights. It contains the code and a builder that merges your two existing model archives into the format expected by `MODEL_BUNDLE_MODE=combined`.

## Download the current archives

Using AWS CLI credentials that can read `rosely-infrastructure`:

```bash
aws s3 cp \
  s3://rosely-infrastructure/models/minimax-h3/10eros-beta5-5090/10eros-beta5-5090-comfyui.tar.zst \
  ./h3.tar.zst

aws s3 cp \
  s3://rosely-infrastructure/serverless/zimage/zenith13/zenith13-mxfp8-full-detailer-seedvr2-v3.tar.zst \
  ./zit.tar.zst
```

## Build

```bash
chmod +x scripts/build_combined_bundle.sh
./scripts/build_combined_bundle.sh \
  ./h3.tar.zst \
  ./zit.tar.zst \
  ./h3-zit-5090-comfyui.tar.zst
```

The script:

- extracts the exact H3 tree;
- overlays the exact ZiT `models/` tree into `ComfyUI/models/`;
- regenerates `model-files.sha256` for the complete final tree;
- validates all seven core H3/ZiT model files;
- writes `h3-zit-5090-comfyui.tar.zst` and `.sha256`.

## Upload

```bash
aws s3 cp h3-zit-5090-comfyui.tar.zst \
  s3://rosely-infrastructure/models/combined/h3-zit-5090/h3-zit-5090-comfyui.tar.zst

aws s3 cp h3-zit-5090-comfyui.tar.zst.sha256 \
  s3://rosely-infrastructure/models/combined/h3-zit-5090/h3-zit-5090-comfyui.tar.zst.sha256
```

Copy the SHA printed by the builder into:

```text
ROSELY_COMBINED_EXPECTED_SHA256=<sha>
```

Then set `MODEL_BUNDLE_MODE=combined`.

## Optional ZiT detailer/upscaler nodes

The model archive may retain your SAM, Ultralytics, SeedVR2, and LoRA files. The default fallback workflows in this package use only standard ComfyUI nodes and therefore leave `ROSELY_INSTALL_ZIT_OPTIONAL_NODES=false` to avoid modifying the stable H3 Python environment.

If you later send raw fallback workflows that use Impact Pack, SeedVR2, or VRGameDevGirl nodes, set:

```text
ROSELY_INSTALL_ZIT_OPTIONAL_NODES=true
```

The provisioner installs the same pinned custom-node revisions used by the current ZiT repository while filtering out dependencies that would replace the CUDA-tested PyTorch stack.
