# Source provenance

This combined deployment was derived from the current `main` trees inspected on 2026-10-04:

- `robert2398/rosely-minimax-h3-ref2va-serverless`
  - tree: `6f6056935dfc7a7b024f3186bceab56071a52c2b`
  - retained H3 model names, workflow, request semantics, S3 output semantics, pinned ComfyUI commit, Blackwell guard, and Vast worker benchmark behavior.

- `robert2398/rosely-zit-v13-vast-serverless-upscaler-detailer`
  - tree: `2cbfc062f9917e32ce8d8665a2e0e95892a367f6`
  - retained Zenith model names, eight workflow modes, LoRA defaults, current ZiT archive URI/SHA/size, and optional custom-node revisions.

The old ai-dock ZiT API-wrapper patch/watchdog is intentionally not used. The combined endpoint submits both workflow families through the H3-style FastAPI -> direct ComfyUI API path so one process owns GPU scheduling.
