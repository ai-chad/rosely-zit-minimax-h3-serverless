#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
python -m py_compile model_server.py worker.py zit_workflow.py
python scripts/validate_repo.py
python -m unittest discover -s tests -v
bash -n provision.sh
bash -n scripts/start_comfyui.sh
bash -n scripts/start_model_server.sh
bash -n scripts/status.sh
bash -n scripts/build_combined_bundle.sh
python - <<'PY'
import json
from pathlib import Path
for p in Path('workflows').glob('*.json'):
    json.loads(p.read_text())
    print('JSON OK', p)
PY
echo "STATIC CHECKS PASSED"
