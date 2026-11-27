#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || command -v python)}"
"$PYTHON_BIN" -m py_compile model_server.py worker.py zit_workflow.py scripts/sync_models.py scripts/publish_direct_bundle.py
"$PYTHON_BIN" scripts/validate_repo.py
"$PYTHON_BIN" -m unittest discover -s tests -v
bash -n provision.sh
bash -n scripts/start_comfyui.sh
bash -n scripts/start_h3_sync.sh
bash -n scripts/start_voice_sync.sh
bash -n scripts/voice_ctl.sh
bash -n scripts/start_model_server.sh
bash -n scripts/status.sh
bash -n scripts/build_combined_bundle.sh
"$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path
for p in Path('workflows').glob('*.json'):
    json.loads(p.read_text())
    print('JSON OK', p)
PY
echo "STATIC CHECKS PASSED"
