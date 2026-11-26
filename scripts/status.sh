#!/usr/bin/env bash
set -euo pipefail

echo "=== Supervisor ==="
supervisorctl status rosely-comfyui rosely-h3-sync rosely-model-server || true

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
echo "=== H3 Background Sync Status ==="
if [[ -f /workspace/.rosely-h3-zit/h3-download-status.json ]]; then
  cat /workspace/.rosely-h3-zit/h3-download-status.json
else
  echo "(no h3-download-status.json yet)"
fi

echo
echo "=== Core model files ==="
find /workspace/ComfyUI/models -type f \( -name '*.safetensors' -o -name '*.gguf' \) -printf '%s %p\n' | sort -n || true

echo
echo "=== Disk ==="
df -h /workspace
