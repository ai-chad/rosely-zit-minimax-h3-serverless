from __future__ import annotations

import ast
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from zit_workflow import MODE_TO_FILE, build_zit_workflow  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


for py in [ROOT / "model_server.py", ROOT / "worker.py", ROOT / "zit_workflow.py"]:
    ast.parse(py.read_text(encoding="utf-8"), filename=str(py))
    print("AST OK", py.name)

h3 = json.loads((ROOT / "workflows/minimax_h3_ref2va_api.json").read_text())
require(h3["1"]["inputs"]["clip_name"] == "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors", "H3 encoder mismatch")
require(h3["2"]["inputs"]["unet_name"] == "10Eros_Max_h3_hybrid_beta5_int8.safetensors", "H3 model mismatch")
require(h3["17"]["class_type"] == "SaveVideo", "H3 SaveVideo missing")
print("H3 workflow OK")

expected_loras = {
    "realistic": None,
    "realistic_male": "zpenis-zit-v1_5.safetensors",
    "realistic_trans": "zpenis-zit-v1_5.safetensors",
    "realistic_snapshot": "RealisticSnapshot-Zimage-Turbov5.safetensors",
    "realistic_amateur": "deedee_amateur_photography_zimage_base_and_turbo_v1.safetensors",
    "anime_illustria": "z-image-illustria-01.safetensors",
    "anime_modern": "z-image-anime-01.safetensors",
    "anime_elusarca": "elusarca-anime-style.safetensors",
}
for mode in MODE_TO_FILE:
    wf, meta = build_zit_workflow(
        mode=mode,
        prompt="validation prompt",
        request_id="validate 1",
        seed=123,
    )
    require(wf["1"]["inputs"]["unet_name"] == "Zenith_13.0_MXFP8_E4M3.safetensors", f"{mode}: model mismatch")
    require(wf["2"]["inputs"]["clip_name"] == "qwen/qwen_3_4b_fp8_mixed.safetensors", f"{mode}: encoder mismatch")
    require(wf["3"]["inputs"]["vae_name"] == "Flux/flux_vae.safetensors", f"{mode}: VAE mismatch")
    require(wf["9"]["inputs"]["filename_prefix"] == "image/zit/validate-1", f"{mode}: output prefix mismatch")
    expected = expected_loras[mode]
    actual = wf.get("10", {}).get("inputs", {}).get("lora_name")
    require(actual == expected, f"{mode}: LoRA mismatch: {actual} != {expected}")
    require(meta["family"] == "zit", f"{mode}: family metadata missing")
print("All ZiT workflows OK")

server_text = (ROOT / "model_server.py").read_text()
for route in ["/generate/sync", "/generate/video", "/generate/image", "/health", "/ready"]:
    require(route in server_text, f"Missing route {route}")
require("generation_lock = asyncio.Lock()" in server_text, "Global generation lock missing")
require("/free" in server_text, "ComfyUI family-switch cleanup missing")
print("Server invariants OK")

print("VALIDATION PASSED")
