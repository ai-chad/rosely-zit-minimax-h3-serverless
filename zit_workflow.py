from __future__ import annotations

import copy
import json
import re
from pathlib import Path
from typing import Literal

WorkflowMode = Literal[
    "realistic",
    "realistic_male",
    "realistic_trans",
    "realistic_snapshot",
    "realistic_amateur",
    "anime_illustria",
    "anime_modern",
    "anime_elusarca",
]

WORKFLOW_DIR = Path(__file__).resolve().parent / "workflows"
MODE_TO_FILE = {
    "realistic": "zit_realistic.json",
    "realistic_male": "zit_realistic_male.json",
    "realistic_trans": "zit_realistic_trans.json",
    "realistic_snapshot": "zit_realistic_snapshot.json",
    "realistic_amateur": "zit_realistic_amateur.json",
    "anime_illustria": "zit_anime_illustria.json",
    "anime_modern": "zit_anime_modern.json",
    "anime_elusarca": "zit_anime_elusarca.json",
}
ALIASES = {"anime": "anime_illustria"}
_SAFE_ID = re.compile(r"[^A-Za-z0-9._-]+")


def _load_workflows() -> dict[str, dict]:
    loaded: dict[str, dict] = {}
    for mode, filename in MODE_TO_FILE.items():
        path = WORKFLOW_DIR / filename
        if not path.is_file():
            raise RuntimeError(f"ZiT workflow missing: {path}")
        loaded[mode] = json.loads(path.read_text(encoding="utf-8"))
    return loaded


_WORKFLOWS = _load_workflows()


def sanitize_request_id(request_id: str) -> str:
    safe_id = _SAFE_ID.sub("-", str(request_id).strip()).strip("-._")[:96]
    if not safe_id:
        raise ValueError("request_id must contain at least one safe character")
    return safe_id


def build_zit_workflow(
    *,
    mode: str = "realistic",
    prompt: str,
    request_id: str,
    seed: int,
    width: int = 768,
    height: int = 1344,
    lora_strength: float | None = None,
    steps: int | None = None,
    cfg: float | None = None,
    sampler_name: str | None = None,
    scheduler: str | None = None,
) -> tuple[dict, dict]:
    raw_mode = (mode or "realistic").strip().lower()
    selected_mode = ALIASES.get(raw_mode, raw_mode)
    if selected_mode not in _WORKFLOWS:
        raise ValueError(
            f"Unsupported ZiT mode: {selected_mode}. "
            f"Expected one of {sorted(_WORKFLOWS)}"
        )

    prompt = str(prompt).strip()
    if not prompt:
        raise ValueError("prompt must not be empty")

    width, height = int(width), int(height)
    if (
        width < 256
        or height < 256
        or width > 2048
        or height > 2048
        or width % 16
        or height % 16
    ):
        raise ValueError("width/height must be 256..2048 and divisible by 16")

    seed = int(seed)
    if seed < 0 or seed >= 2**63:
        raise ValueError("seed must be in [0, 2**63)")

    safe_id = sanitize_request_id(request_id)
    workflow = copy.deepcopy(_WORKFLOWS[selected_mode])
    workflow["4"]["inputs"]["text"] = prompt
    workflow["6"]["inputs"]["width"] = width
    workflow["6"]["inputs"]["height"] = height
    workflow["7"]["inputs"]["seed"] = seed
    workflow["9"]["inputs"]["filename_prefix"] = f"image/zit/{safe_id}"

    if "10" in workflow and lora_strength is not None:
        strength = float(lora_strength)
        if not 0.0 <= strength <= 1.5:
            raise ValueError("lora_strength must be 0.0..1.5")
        workflow["10"]["inputs"]["strength_model"] = strength

    if steps is not None:
        steps = int(steps)
        if not 1 <= steps <= 50:
            raise ValueError("steps must be in 1..50")
        workflow["7"]["inputs"]["steps"] = steps

    if cfg is not None:
        cfg = float(cfg)
        if not 0.0 < cfg <= 20.0:
            raise ValueError("cfg must be > 0 and <= 20")
        workflow["7"]["inputs"]["cfg"] = cfg

    if sampler_name is not None:
        sampler_name = str(sampler_name).strip()
        if not sampler_name:
            raise ValueError("sampler_name must not be empty")
        workflow["7"]["inputs"]["sampler_name"] = sampler_name

    if scheduler is not None:
        scheduler = str(scheduler).strip()
        if not scheduler:
            raise ValueError("scheduler must not be empty")
        workflow["7"]["inputs"]["scheduler"] = scheduler

    metadata = {
        "family": "zit",
        "mode": selected_mode,
        "model": workflow["1"]["inputs"]["unet_name"],
        "text_encoder": workflow["2"]["inputs"]["clip_name"],
        "vae": workflow["3"]["inputs"]["vae_name"],
        "seed": seed,
        "width": width,
        "height": height,
        "steps": int(workflow["7"]["inputs"]["steps"]),
        "cfg": float(workflow["7"]["inputs"]["cfg"]),
        "sampler": workflow["7"]["inputs"]["sampler_name"],
        "scheduler": workflow["7"]["inputs"]["scheduler"],
        "effective_prompt": prompt,
    }
    if "10" in workflow:
        metadata["lora"] = workflow["10"]["inputs"]["lora_name"]
        metadata["lora_strength"] = float(
            workflow["10"]["inputs"]["strength_model"]
        )

    return workflow, metadata
