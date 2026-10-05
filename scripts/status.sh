#!/usr/bin/env bash
set -euo pipefail

echo "=== Supervisor ==="
supervisorctl status rosely-comfyui rosely-model-server || true

echo
echo "=== GPU ==="
nvidia-smi || true

echo
echo "=== ComfyUI ==="
curl -fsS http://127.0.0.1:18189/system_stats | jq . || true

echo
echo "=== Combined model server ==="
curl -fsS http://127.0.0.1:18288/health | jq . || true
curl -fsS http://127.0.0.1:18288/status | jq . || true

echo
echo "=== Core model files ==="
find /workspace/ComfyUI/models -type f \( -name '*.safetensors' -o -name '*.gguf' \) -printf '%s %p\n' | sort -n || true

echo
echo "=== Disk ==="
df -h /workspace
