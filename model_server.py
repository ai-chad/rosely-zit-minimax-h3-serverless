from __future__ import annotations

import asyncio
import base64
import contextlib
import copy
import json
import logging
import mimetypes
import os
import time
import uuid
from contextlib import asynccontextmanager
from io import BytesIO
from pathlib import Path
from typing import Any, Literal

import boto3
import httpx
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel, ConfigDict, Field

from zit_workflow import MODE_TO_FILE, build_zit_workflow, sanitize_request_id

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("rosely-h3-zit")

COMFY_URL = os.getenv("COMFY_URL", "http://127.0.0.1:18189").rstrip("/")
APP_DIR = Path(os.getenv("APP_DIR", "/workspace/vast-pyworker"))
H3_WORKFLOW_PATH = Path(
    os.getenv(
        "H3_WORKFLOW_PATH",
        str(APP_DIR / "workflows/minimax_h3_ref2va_api.json"),
    )
)
INPUT_DIR = Path(os.getenv("COMFY_INPUT_DIR", "/workspace/ComfyUI/input"))
OUTPUT_DIR = Path(os.getenv("COMFY_OUTPUT_DIR", "/workspace/ComfyUI/output"))
MODEL_DIR = Path(os.getenv("COMFY_MODEL_DIR", "/workspace/ComfyUI/models"))

VIDEO_GENERATION_TIMEOUT = int(os.getenv("GENERATION_TIMEOUT_SECONDS", "3600"))
IMAGE_GENERATION_TIMEOUT = int(os.getenv("IMAGE_GENERATION_TIMEOUT_SECONDS", "900"))
KEEP_LOCAL_OUTPUTS = os.getenv("KEEP_LOCAL_OUTPUTS", "false").lower() == "true"
MAX_INPUT_IMAGE_BYTES = int(
    os.getenv("MAX_INPUT_IMAGE_BYTES", str(30 * 1024 * 1024))
)
ALLOW_RAW_ZIT_WORKFLOW_JSON = (
    os.getenv("ALLOW_RAW_ZIT_WORKFLOW_JSON", "true").lower() == "true"
)
FREE_ON_FAMILY_SWITCH = (
    os.getenv("FREE_ON_FAMILY_SWITCH", "true").lower() == "true"
)
FAMILY_SWITCH_SETTLE_SECONDS = float(
    os.getenv("FAMILY_SWITCH_SETTLE_SECONDS", "0.5")
)

H3_BASE_MODEL = "10Eros_Max_h3_hybrid_beta5_int8.safetensors"
H3_TEXT_ENCODER = "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"
H3_VIDEO_VAE = "minimax_h3_video_vae_fp16.safetensors"
H3_AUDIO_VAE = "minimax_h3_audio_vae_fp32.safetensors"

ZIT_BASE_MODEL = "Zenith_13.0_MXFP8_E4M3.safetensors"
ZIT_TEXT_ENCODER = "qwen/qwen_3_4b_fp8_mixed.safetensors"
ZIT_VAE = "Flux/flux_vae.safetensors"

EXPECTED_MODELS: dict[str, Path] = {
    "h3_diffusion": MODEL_DIR / "diffusion_models" / H3_BASE_MODEL,
    "h3_text_encoder": MODEL_DIR / "text_encoders" / H3_TEXT_ENCODER,
    "h3_video_vae": MODEL_DIR / "vae" / H3_VIDEO_VAE,
    "h3_audio_vae": MODEL_DIR / "vae" / H3_AUDIO_VAE,
    "zit_diffusion": MODEL_DIR / "diffusion_models" / ZIT_BASE_MODEL,
    "zit_text_encoder": MODEL_DIR / "text_encoders" / ZIT_TEXT_ENCODER,
    "zit_vae": MODEL_DIR / "vae" / ZIT_VAE,
    "zit_lora_male_trans": MODEL_DIR / "loras/zpenis-zit-v1_5.safetensors",
    "zit_lora_snapshot": MODEL_DIR / "loras/RealisticSnapshot-Zimage-Turbov5.safetensors",
    "zit_lora_amateur": MODEL_DIR / "loras/deedee_amateur_photography_zimage_base_and_turbo_v1.safetensors",
    "zit_lora_anime_illustria": MODEL_DIR / "loras/z-image-illustria-01.safetensors",
    "zit_lora_anime_modern": MODEL_DIR / "loras/z-image-anime-01.safetensors",
    "zit_lora_anime_elusarca": MODEL_DIR / "loras/elusarca-anime-style.safetensors",
}

VALID_H3_SCHEDULERS = {"simple", "normal", "beta"}
VALID_REF_IMAGE_SIZES = {"match", "max"}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
VIDEO_EXTENSIONS = {".mp4", ".webm", ".mov", ".mkv"}

COMFY_PROBE_INTERVAL_SECONDS = float(
    os.getenv("COMFY_PROBE_INTERVAL_SECONDS", "10")
)
COMFY_PROBE_TIMEOUT_SECONDS = float(
    os.getenv("COMFY_PROBE_TIMEOUT_SECONDS", "2")
)
COMFY_HEALTH_STALE_SECONDS = float(
    os.getenv("COMFY_HEALTH_STALE_SECONDS", "90")
)
COMFY_BUSY_HEALTH_STALE_SECONDS = float(
    os.getenv("COMFY_BUSY_HEALTH_STALE_SECONDS", "900")
)
REJECT_IMAGE_WHILE_VIDEO_BUSY = (
    os.getenv("REJECT_IMAGE_WHILE_VIDEO_BUSY", "true").lower() == "true"
)


class ComfyHealthState:
    def __init__(self) -> None:
        self.ever_ready = False
        self.last_success_monotonic = 0.0
        self.last_error: str | None = None

    def mark_success(self) -> None:
        self.ever_ready = True
        self.last_success_monotonic = time.monotonic()
        self.last_error = None

    def mark_failure(self, error: str) -> None:
        self.last_error = error

    @property
    def age_seconds(self) -> float | None:
        if not self.ever_ready:
            return None
        return time.monotonic() - self.last_success_monotonic


comfy_health = ComfyHealthState()
generation_lock = asyncio.Lock()
active_family: Literal["h3", "zit"] | None = None
current_job_family: Literal["h3", "zit"] | None = None
family_switch_count = 0


async def comfy_health_monitor() -> None:
    timeout = httpx.Timeout(
        connect=1.0,
        read=COMFY_PROBE_TIMEOUT_SECONDS,
        write=1.0,
        pool=1.0,
    )
    async with httpx.AsyncClient(timeout=timeout) as client:
        while True:
            try:
                response = await client.get(f"{COMFY_URL}/system_stats")
                if response.status_code == 200:
                    comfy_health.mark_success()
                else:
                    comfy_health.mark_failure(f"status={response.status_code}")
            except Exception as exc:
                comfy_health.mark_failure(f"{type(exc).__name__}: {exc}")
            await asyncio.sleep(COMFY_PROBE_INTERVAL_SECONDS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    monitor_task = asyncio.create_task(
        comfy_health_monitor(),
        name="comfy-health-monitor",
    )
    try:
        yield
    finally:
        monitor_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await monitor_task


app = FastAPI(
    title="Rosely MiniMax H3 + Zenith/Z-Image RTX 5090 Server",
    version="1.0.0",
    lifespan=lifespan,
)


class GenerateEnvelope(BaseModel):
    model_config = ConfigDict(extra="allow")
    input: dict[str, Any] = Field(default_factory=dict)


def _payload(envelope: GenerateEnvelope) -> dict[str, Any]:
    data = dict(envelope.input)
    if not data:
        raise HTTPException(status_code=422, detail="input object is required")
    return data


def _missing_models() -> list[str]:
    return [name for name, path in EXPECTED_MODELS.items() if not path.is_file()]


def _load_h3_workflow() -> dict[str, Any]:
    if not H3_WORKFLOW_PATH.is_file():
        raise RuntimeError(f"H3 workflow not found: {H3_WORKFLOW_PATH}")

    workflow = json.loads(H3_WORKFLOW_PATH.read_text(encoding="utf-8"))
    required_types = {
        "1": "CLIPLoader",
        "2": "UNETLoader",
        "4": "VAELoader",
        "5": "VAELoader",
        "6": "MiniMaxH3SigmaShift",
        "7": "LoadImage",
        "8": "MiniMaxH3ReferenceToVideo",
        "9": "BasicGuider",
        "10": "RandomNoise",
        "11": "BasicScheduler",
        "12": "KSamplerSelect",
        "13": "SamplerCustomAdvanced",
        "14": "VAEDecode",
        "15": "VAEDecodeAudio",
        "16": "CreateVideo",
        "17": "SaveVideo",
    }
    for node_id, expected_type in required_types.items():
        node = workflow.get(node_id)
        if not node or node.get("class_type") != expected_type:
            raise RuntimeError(
                f"H3 workflow node {node_id}: expected {expected_type}, "
                f"got {None if not node else node.get('class_type')}"
            )

    expected_names = {
        ("1", "clip_name"): H3_TEXT_ENCODER,
        ("2", "unet_name"): H3_BASE_MODEL,
        ("4", "vae_name"): H3_VIDEO_VAE,
        ("5", "vae_name"): H3_AUDIO_VAE,
    }
    for (node_id, input_name), expected in expected_names.items():
        actual = workflow[node_id]["inputs"].get(input_name)
        if actual != expected:
            raise RuntimeError(
                f"H3 workflow {node_id}.{input_name}: "
                f"expected {expected!r}, got {actual!r}"
            )
    return workflow


H3_BASE_WORKFLOW = _load_h3_workflow()


async def _recover_after_generation_failure(reason: str) -> None:
    global active_family
    logger.warning("Resetting ComfyUI model state after generation failure: %s", reason)
    timeout = httpx.Timeout(15.0, connect=3.0)
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            with contextlib.suppress(Exception):
                await client.post(f"{COMFY_URL}/interrupt", json={})
            response = await client.post(
                f"{COMFY_URL}/free",
                json={"unload_models": True, "free_memory": True},
            )
            response.raise_for_status()
            await asyncio.sleep(max(0.0, FAMILY_SWITCH_SETTLE_SECONDS))
    except Exception as exc:
        logger.warning("ComfyUI failure cleanup itself failed: %s", exc)
    active_family = None


async def _prepare_family(family: Literal["h3", "zit"]) -> None:
    global active_family, family_switch_count

    if active_family == family:
        return

    old_family = active_family
    if FREE_ON_FAMILY_SWITCH and old_family is not None:
        timeout = httpx.Timeout(15.0, connect=3.0)
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.post(
                    f"{COMFY_URL}/free",
                    json={"unload_models": True, "free_memory": True},
                )
                response.raise_for_status()
                # /free sets flags consumed by ComfyUI's queue worker. We hold the
                # only generation lock, so it is idle here; a short settle avoids
                # racing the next prompt against the unload tick.
                await asyncio.sleep(max(0.0, FAMILY_SWITCH_SETTLE_SECONDS))
                with contextlib.suppress(Exception):
                    stats = await client.get(f"{COMFY_URL}/system_stats")
                    if stats.status_code == 200:
                        comfy_health.mark_success()
        except Exception as exc:
            logger.warning(
                "family_switch=%s->%s memory cleanup failed; continuing with "
                "ComfyUI smart memory management. error=%s",
                old_family,
                family,
                exc,
            )

    active_family = family
    if old_family is not None and old_family != family:
        family_switch_count += 1
    logger.info("gpu_family=%s previous=%s", family, old_family)


def _h3_length_from_duration(seconds: float) -> int:
    target = max(5, round(seconds * 24))
    return target + (5 - (target % 17)) % 17


def _validate_h3_dimensions(width: int, height: int) -> None:
    if width < 256 or height < 256:
        raise HTTPException(status_code=422, detail="width and height must be >= 256")
    if width % 32 or height % 32:
        raise HTTPException(
            status_code=422,
            detail="MiniMax H3 width and height must be divisible by 32",
        )
    if width * height > 1344 * 768:
        raise HTTPException(
            status_code=422,
            detail=(
                "Requested H3 canvas exceeds the recommended 1344x768 pixel "
                "area. For portrait use up to 768x1344."
            ),
        )


def _validate_h3_length(data: dict[str, Any]) -> tuple[int, float]:
    if data.get("length") is not None:
        length = int(data["length"])
        if length < 5 or length > 362 or length % 17 != 5:
            raise HTTPException(
                status_code=422,
                detail=(
                    "length must be in the H3 17k+5 grid and <= 362; "
                    "examples: 124 (~5s), 243 (~10s), 362 (~15s)"
                ),
            )
        return length, length / 24.0

    duration = float(data.get("duration_seconds", 5.0))
    if duration < 5.0 or duration > 15.0:
        raise HTTPException(
            status_code=422,
            detail="duration_seconds must be between 5 and 15",
        )
    length = _h3_length_from_duration(duration)
    return length, length / 24.0


def _prepare_h3_prompt(data: dict[str, Any]) -> str:
    prompt = str(data.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(status_code=422, detail="prompt is required")
    if "<Picture 1>" not in prompt:
        prompt = f"<Picture 1> {prompt}"
    return prompt


async def _download_input_image(data: dict[str, Any], request_id: str) -> str:
    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    encoded = data.get("input_image_base64")
    url = data.get("input_image_url")
    raw: bytes

    if encoded:
        if not isinstance(encoded, str):
            raise HTTPException(
                status_code=422,
                detail="input_image_base64 must be a string",
            )
        if encoded.startswith("data:"):
            encoded = encoded.split(",", 1)[1]
        try:
            raw = base64.b64decode(encoded, validate=False)
        except Exception as exc:
            raise HTTPException(
                status_code=422,
                detail=f"Invalid input_image_base64: {exc}",
            ) from exc
    elif url:
        headers = data.get("input_image_headers") or {}
        timeout = httpx.Timeout(120.0, connect=30.0)
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            try:
                response = await client.get(str(url), headers=headers)
                response.raise_for_status()
            except httpx.HTTPError as exc:
                raise HTTPException(
                    status_code=422,
                    detail=f"Could not download input image: {exc}",
                ) from exc
            raw = response.content
    else:
        raise HTTPException(
            status_code=422,
            detail="Provide input_image_url or input_image_base64",
        )

    if len(raw) > MAX_INPUT_IMAGE_BYTES:
        raise HTTPException(
            status_code=413,
            detail=(
                f"Input image exceeds "
                f"{MAX_INPUT_IMAGE_BYTES // (1024 * 1024)} MiB limit"
            ),
        )

    target = INPUT_DIR / f"h3_{sanitize_request_id(request_id)}.png"
    try:
        with Image.open(BytesIO(raw)) as image:
            image.convert("RGB").save(target, format="PNG")
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Invalid input image: {exc}") from exc
    return target.name


def _patch_h3_workflow(
    data: dict[str, Any],
    image_name: str,
    request_id: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    workflow = copy.deepcopy(H3_BASE_WORKFLOW)

    width = int(data.get("width", 480))
    height = int(data.get("height", 864))
    _validate_h3_dimensions(width, height)
    length, actual_duration = _validate_h3_length(data)

    steps = int(data.get("steps", 8))
    if steps < 4 or steps > 50:
        raise HTTPException(status_code=422, detail="steps must be between 4 and 50")

    scheduler = str(data.get("scheduler", "simple"))
    if scheduler not in VALID_H3_SCHEDULERS:
        raise HTTPException(
            status_code=422,
            detail=f"scheduler must be one of {sorted(VALID_H3_SCHEDULERS)}",
        )

    ref_image_size = str(data.get("ref_image_size", "match"))
    if ref_image_size not in VALID_REF_IMAGE_SIZES:
        raise HTTPException(
            status_code=422,
            detail="ref_image_size must be 'match' or 'max'",
        )

    shift_video = float(data.get("shift_video", 12.0))
    shift_audio = float(data.get("shift_audio", 3.0))
    seed = int(data.get("seed", int.from_bytes(os.urandom(6), "big")))
    if seed < 0:
        raise HTTPException(status_code=422, detail="seed must be >= 0")

    include_audio = bool(data.get("include_audio", True))
    prompt = _prepare_h3_prompt(data)
    legacy_lora_strength = data.get("lora_strength")

    workflow["6"]["inputs"]["shift_video"] = shift_video
    workflow["6"]["inputs"]["shift_audio"] = shift_audio
    workflow["7"]["inputs"]["image"] = image_name
    workflow["8"]["inputs"].update(
        {
            "prompt": prompt,
            "width": width,
            "height": height,
            "length": length,
            "ref_image_size": ref_image_size,
            "ref_images.ref_image_0": ["7", 0],
        }
    )
    workflow["10"]["inputs"]["noise_seed"] = seed
    workflow["11"]["inputs"].update(
        {"scheduler": scheduler, "steps": steps, "denoise": 1.0}
    )
    workflow["17"]["inputs"]["filename_prefix"] = (
        f"video/h3/{sanitize_request_id(request_id)}"
    )

    if not include_audio:
        workflow["16"]["inputs"].pop("audio", None)
        workflow.pop("15", None)

    metadata: dict[str, Any] = {
        "family": "h3",
        "model": H3_BASE_MODEL,
        "seed": seed,
        "width": width,
        "height": height,
        "length": length,
        "fps": 24,
        "duration_seconds_actual": actual_duration,
        "steps": steps,
        "scheduler": scheduler,
        "sampler": "res_multistep",
        "ref_image_size": ref_image_size,
        "include_audio": include_audio,
        "shift_video": shift_video,
        "shift_audio": shift_audio,
        "effective_prompt": prompt,
    }
    if legacy_lora_strength is not None:
        metadata["legacy_lora_strength_ignored"] = legacy_lora_strength
    return workflow, metadata


def _prepare_raw_zit_workflow(
    raw_workflow: Any,
    request_id: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if not ALLOW_RAW_ZIT_WORKFLOW_JSON:
        raise HTTPException(
            status_code=422,
            detail="Raw workflow_json is disabled; use mode/prompt fields",
        )
    if not isinstance(raw_workflow, dict) or not raw_workflow:
        raise HTTPException(status_code=422, detail="workflow_json must be an object")

    workflow = copy.deepcopy(raw_workflow)
    save_nodes = [
        node
        for node in workflow.values()
        if isinstance(node, dict) and node.get("class_type") == "SaveImage"
    ]
    if not save_nodes:
        raise HTTPException(
            status_code=422,
            detail="ZiT workflow_json must contain at least one SaveImage node",
        )

    safe_id = sanitize_request_id(request_id)
    for index, node in enumerate(save_nodes):
        suffix = "" if index == 0 else f"-{index + 1}"
        node.setdefault("inputs", {})["filename_prefix"] = (
            f"image/zit/{safe_id}{suffix}"
        )

    return workflow, {
        "family": "zit",
        "mode": "raw_workflow_json",
        "raw_workflow_json": True,
    }


async def _submit_and_wait(
    workflow: dict[str, Any],
    request_id: str,
    *,
    timeout_seconds: int,
    family: Literal["h3", "zit"],
) -> tuple[str, dict[str, Any]]:
    client_id = str(uuid.uuid4())
    timeout = httpx.Timeout(120.0, connect=20.0)

    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(
            f"{COMFY_URL}/prompt",
            json={"prompt": workflow, "client_id": client_id},
        )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail=f"ComfyUI rejected {family} prompt: {response.text}",
            )

        comfy_health.mark_success()
        body = response.json()
        if body.get("error") or body.get("node_errors"):
            raise HTTPException(status_code=502, detail=body)

        prompt_id = str(body["prompt_id"])
        logger.info(
            "family=%s request=%s comfy_prompt_id=%s submitted",
            family,
            request_id,
            prompt_id,
        )

        deadline = time.monotonic() + timeout_seconds
        poll_seconds = 2.0 if family == "zit" else 3.0
        while time.monotonic() < deadline:
            history_response = await client.get(f"{COMFY_URL}/history/{prompt_id}")
            history_response.raise_for_status()
            comfy_health.mark_success()
            history = history_response.json()
            if prompt_id in history:
                item = history[prompt_id]
                status = item.get("status", {})
                if status.get("status_str") == "error":
                    raise HTTPException(
                        status_code=500,
                        detail={
                            "request_id": request_id,
                            "prompt_id": prompt_id,
                            "family": family,
                            "status": status,
                        },
                    )
                return prompt_id, item
            await asyncio.sleep(poll_seconds)

        try:
            await client.post(
                f"{COMFY_URL}/interrupt",
                json={"prompt_id": prompt_id},
            )
        except Exception:
            logger.exception("Failed to interrupt timed-out prompt %s", prompt_id)
        raise HTTPException(
            status_code=504,
            detail=f"{family} generation timed out after {timeout_seconds}s",
        )


def _find_output_metadata(
    value: Any,
    extensions: set[str],
) -> dict[str, Any] | None:
    if isinstance(value, dict):
        filename = value.get("filename")
        if filename and Path(str(filename)).suffix.lower() in extensions:
            return value
        for nested in value.values():
            found = _find_output_metadata(nested, extensions)
            if found:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = _find_output_metadata(nested, extensions)
            if found:
                return found
    return None


def _resolve_output(
    history_item: dict[str, Any],
    request_id: str,
    *,
    extensions: set[str],
    family: Literal["h3", "zit"],
) -> tuple[Path, dict[str, Any]]:
    metadata = _find_output_metadata(history_item.get("outputs", {}), extensions)
    if metadata:
        subfolder = str(metadata.get("subfolder") or "")
        path = OUTPUT_DIR / subfolder / str(metadata["filename"])
        if path.is_file():
            return path, metadata

    safe_id = sanitize_request_id(request_id)
    candidates = sorted(
        (
            p
            for p in OUTPUT_DIR.rglob(f"*{safe_id}*")
            if p.is_file() and p.suffix.lower() in extensions
        ),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if candidates:
        path = candidates[0]
        return path, {
            "filename": path.name,
            "subfolder": str(path.parent.relative_to(OUTPUT_DIR)),
            "type": "output",
        }

    raise HTTPException(
        status_code=500,
        detail=f"ComfyUI completed but the request-specific {family} output was not found",
    )


def _output_config(family: Literal["h3", "zit"]) -> tuple[str, str, int]:
    if family == "h3":
        bucket = os.getenv("ROSELY_H3_OUTPUT_BUCKET") or os.getenv("ROSELY_H3_S3_BUCKET")
        prefix = os.getenv("ROSELY_H3_OUTPUT_PREFIX", "generated/minimax-h3")
        expires_raw = os.getenv("ROSELY_H3_PRESIGNED_URL_EXPIRES_SECONDS", "3600")
    else:
        bucket = (
            os.getenv("ROSELY_ZIT_OUTPUT_BUCKET")
            or os.getenv("AWS_ZIT_IMAGE_S3_BUCKET_NAME")
            or os.getenv("ROSELY_H3_OUTPUT_BUCKET")
            or os.getenv("ROSELY_H3_S3_BUCKET")
        )
        prefix = os.getenv("ROSELY_ZIT_OUTPUT_PREFIX", "generated/zit-fallback")
        expires_raw = os.getenv(
            "ROSELY_ZIT_PRESIGNED_URL_EXPIRES_SECONDS",
            os.getenv("ROSELY_H3_PRESIGNED_URL_EXPIRES_SECONDS", "3600"),
        )

    if not bucket:
        raise RuntimeError(f"No S3 output bucket configured for {family}")
    expires = int(expires_raw)
    if expires < 60 or expires > 604800:
        raise RuntimeError("presigned URL expiry must be between 60 and 604800 seconds")
    return bucket, prefix.strip("/"), expires


def _s3_client(family: Literal["h3", "zit"]):
    if family == "h3":
        region = os.getenv("ROSELY_H3_S3_REGION", "us-east-1")
        endpoint_url = os.getenv("ROSELY_H3_S3_ENDPOINT_URL") or None
        kwargs: dict[str, Any] = {}
    else:
        region = (
            os.getenv("ROSELY_ZIT_S3_REGION")
            or os.getenv("AWS_ZIT_IMAGE_S3_REGION")
            or os.getenv("ROSELY_H3_S3_REGION")
            or "us-east-1"
        )
        endpoint_url = (
            os.getenv("ROSELY_ZIT_S3_ENDPOINT_URL")
            or os.getenv("AWS_ZIT_IMAGE_S3_ENDPOINT_URL")
            or os.getenv("ROSELY_H3_S3_ENDPOINT_URL")
            or None
        )
        access = os.getenv("ROSELY_ZIT_S3_ACCESS_KEY_ID") or os.getenv(
            "AWS_ZIT_IMAGE_ACCESS_KEY_ID"
        )
        secret = os.getenv("ROSELY_ZIT_S3_SECRET_ACCESS_KEY") or os.getenv(
            "AWS_ZIT_IMAGE_SECRET_ACCESS_KEY"
        )
        session = os.getenv("ROSELY_ZIT_S3_SESSION_TOKEN") or os.getenv(
            "AWS_ZIT_IMAGE_SESSION_TOKEN"
        )
        kwargs = {}
        if access and secret:
            kwargs["aws_access_key_id"] = access
            kwargs["aws_secret_access_key"] = secret
            if session:
                kwargs["aws_session_token"] = session

    return boto3.client(
        "s3",
        endpoint_url=endpoint_url,
        region_name=region,
        **kwargs,
    )


def _upload_and_presign(
    path: Path,
    request_id: str,
    family: Literal["h3", "zit"],
) -> tuple[str, str, str, int]:
    bucket, prefix, expires = _output_config(family)
    key = f"{prefix}/{sanitize_request_id(request_id)}{path.suffix.lower()}"
    default_type = "video/mp4" if family == "h3" else "image/png"
    content_type = mimetypes.guess_type(path.name)[0] or default_type

    client = _s3_client(family)
    client.upload_file(
        str(path),
        bucket,
        key,
        ExtraArgs={"ContentType": content_type, "ServerSideEncryption": "AES256"},
    )
    presigned = client.generate_presigned_url(
        ClientMethod="get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=expires,
    )
    return presigned, bucket, key, expires


async def _delete_comfy_history(prompt_id: str) -> None:
    with contextlib.suppress(Exception):
        timeout = httpx.Timeout(5.0, connect=2.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            await client.post(f"{COMFY_URL}/history", json={"delete": [prompt_id]})


async def _generate_video(data: dict[str, Any]) -> dict[str, Any]:
    global current_job_family
    request_id = str(data.get("request_id") or f"h3_{uuid.uuid4().hex}")
    image_name: str | None = None
    output_path: Path | None = None
    prompt_id: str | None = None

    async with generation_lock:
        current_job_family = "h3"
        started = time.monotonic()
        try:
            _output_config("h3")
            await _prepare_family("h3")
            image_name = await _download_input_image(data, request_id)
            workflow, generation_meta = _patch_h3_workflow(data, image_name, request_id)
            try:
                prompt_id, history_item = await _submit_and_wait(
                    workflow,
                    request_id,
                    timeout_seconds=VIDEO_GENERATION_TIMEOUT,
                    family="h3",
                )
            except Exception as exc:
                await _recover_after_generation_failure(f"h3 request {request_id}: {exc}")
                raise
            output_path, comfy_metadata = _resolve_output(
                history_item,
                request_id,
                extensions=VIDEO_EXTENSIONS,
                family="h3",
            )
            try:
                output_url, bucket, key, expires = await asyncio.to_thread(
                    _upload_and_presign,
                    output_path,
                    request_id,
                    "h3",
                )
            except Exception as exc:
                logger.exception("H3 S3 upload failed request=%s", request_id)
                raise HTTPException(
                    status_code=502,
                    detail=f"Video generated but S3 upload/presign failed: {exc}",
                ) from exc

            return {
                "request_id": request_id,
                "prompt_id": prompt_id,
                "status": "completed",
                "task_type": "video",
                "output_url": output_url,
                "output_url_expires_in_seconds": expires,
                "s3_uri": f"s3://{bucket}/{key}",
                "s3_bucket": bucket,
                "s3_key": key,
                "size_bytes": output_path.stat().st_size,
                "generation_seconds": round(time.monotonic() - started, 2),
                "comfyui_output": comfy_metadata,
                **generation_meta,
            }
        finally:
            if image_name:
                (INPUT_DIR / image_name).unlink(missing_ok=True)
            if output_path and not KEEP_LOCAL_OUTPUTS:
                output_path.unlink(missing_ok=True)
            if prompt_id:
                await _delete_comfy_history(prompt_id)
            current_job_family = None


async def _generate_image(data: dict[str, Any]) -> dict[str, Any]:
    global current_job_family
    request_id = str(data.get("request_id") or f"zit_{uuid.uuid4().hex}")
    output_path: Path | None = None
    prompt_id: str | None = None

    if REJECT_IMAGE_WHILE_VIDEO_BUSY and generation_lock.locked() and current_job_family == "h3":
        raise HTTPException(
            status_code=503,
            detail={
                "status": "busy",
                "reason": "video_generation_in_progress",
                "retryable": True,
            },
        )

    async with generation_lock:
        current_job_family = "zit"
        started = time.monotonic()
        try:
            _output_config("zit")
            await _prepare_family("zit")

            if data.get("workflow_json") is not None:
                workflow, generation_meta = _prepare_raw_zit_workflow(
                    data["workflow_json"], request_id
                )
            else:
                try:
                    seed = int(data.get("seed", int.from_bytes(os.urandom(6), "big")))
                    workflow, generation_meta = build_zit_workflow(
                        mode=str(data.get("mode", "realistic")),
                        prompt=str(data.get("prompt") or ""),
                        request_id=request_id,
                        seed=seed,
                        width=int(data.get("width", 768)),
                        height=int(data.get("height", 1344)),
                        lora_strength=(
                            float(data["lora_strength"])
                            if data.get("lora_strength") is not None
                            else None
                        ),
                        steps=(
                            int(data["steps"])
                            if data.get("steps") is not None
                            else None
                        ),
                        cfg=(
                            float(data["cfg"])
                            if data.get("cfg") is not None
                            else None
                        ),
                        sampler_name=(
                            str(data["sampler_name"])
                            if data.get("sampler_name") is not None
                            else None
                        ),
                        scheduler=(
                            str(data["scheduler"])
                            if data.get("scheduler") is not None
                            else None
                        ),
                    )
                except (TypeError, ValueError) as exc:
                    raise HTTPException(status_code=422, detail=str(exc)) from exc

            try:
                prompt_id, history_item = await _submit_and_wait(
                    workflow,
                    request_id,
                    timeout_seconds=IMAGE_GENERATION_TIMEOUT,
                    family="zit",
                )
            except Exception as exc:
                await _recover_after_generation_failure(f"zit request {request_id}: {exc}")
                raise
            output_path, comfy_metadata = _resolve_output(
                history_item,
                request_id,
                extensions=IMAGE_EXTENSIONS,
                family="zit",
            )
            try:
                output_url, bucket, key, expires = await asyncio.to_thread(
                    _upload_and_presign,
                    output_path,
                    request_id,
                    "zit",
                )
            except Exception as exc:
                logger.exception("ZiT S3 upload failed request=%s", request_id)
                raise HTTPException(
                    status_code=502,
                    detail=f"Image generated but S3 upload/presign failed: {exc}",
                ) from exc

            return {
                "request_id": request_id,
                "prompt_id": prompt_id,
                "status": "completed",
                "task_type": "image",
                "output_url": output_url,
                "output_url_expires_in_seconds": expires,
                "s3_uri": f"s3://{bucket}/{key}",
                "s3_bucket": bucket,
                "s3_key": key,
                "size_bytes": output_path.stat().st_size,
                "generation_seconds": round(time.monotonic() - started, 2),
                "comfyui_output": comfy_metadata,
                **generation_meta,
            }
        finally:
            if output_path and not KEEP_LOCAL_OUTPUTS:
                output_path.unlink(missing_ok=True)
            if prompt_id:
                await _delete_comfy_history(prompt_id)
            current_job_family = None


def _infer_task_type(data: dict[str, Any]) -> Literal["image", "video"]:
    explicit = str(
        data.get("task_type") or data.get("kind") or data.get("family") or ""
    ).strip().lower()
    if explicit in {"image", "zit", "zimage", "z-image", "zenith"}:
        return "image"
    if explicit in {"video", "h3", "minimax", "minimax-h3"}:
        return "video"
    if data.get("workflow_json") is not None:
        return "image"
    if data.get("mode") in MODE_TO_FILE or data.get("mode") == "anime":
        return "image"
    return "video"


@app.get("/health")
async def health() -> dict[str, Any]:
    missing = _missing_models()
    h3_bucket_ok = bool(
        os.getenv("ROSELY_H3_OUTPUT_BUCKET") or os.getenv("ROSELY_H3_S3_BUCKET")
    )
    zit_bucket_ok = bool(
        os.getenv("ROSELY_ZIT_OUTPUT_BUCKET")
        or os.getenv("AWS_ZIT_IMAGE_S3_BUCKET_NAME")
        or os.getenv("ROSELY_H3_OUTPUT_BUCKET")
        or os.getenv("ROSELY_H3_S3_BUCKET")
    )
    if missing or not h3_bucket_ok or not zit_bucket_ok:
        raise HTTPException(
            status_code=503,
            detail={
                "status": "unhealthy",
                "reason": "local prerequisites missing",
                "missing_models": missing,
                "h3_s3_output_configured": h3_bucket_ok,
                "zit_s3_output_configured": zit_bucket_ok,
            },
        )

    if not comfy_health.ever_ready:
        raise HTTPException(
            status_code=503,
            detail={"status": "starting", "reason": "ComfyUI not probed yet"},
        )

    age = comfy_health.age_seconds
    allowed_stale = (
        COMFY_BUSY_HEALTH_STALE_SECONDS
        if generation_lock.locked()
        else COMFY_HEALTH_STALE_SECONDS
    )
    if age is None or age >= allowed_stale:
        raise HTTPException(
            status_code=503,
            detail={
                "status": "unhealthy",
                "reason": "ComfyUI heartbeat stale",
                "last_comfy_success_seconds_ago": round(age, 2) if age is not None else None,
                "last_probe_error": comfy_health.last_error,
                "gpu_busy": generation_lock.locked(),
                "stale_after_seconds": allowed_stale,
            },
        )

    return {
        "status": "ok",
        "profile": "rosely-h3-zit-5090",
        "comfyui": "alive",
        "active_family": active_family,
        "current_job_family": current_job_family,
        "gpu_busy": generation_lock.locked(),
        "family_switch_count": family_switch_count,
        "models": {"h3": "available", "zit": "available"},
        "routes": ["/generate/sync", "/generate/video", "/generate/image"],
        "last_comfy_success_seconds_ago": round(age, 2),
        "last_probe_error": comfy_health.last_error,
    }


@app.get("/ready")
async def ready() -> dict[str, Any]:
    missing = _missing_models()
    if missing:
        raise HTTPException(
            status_code=503,
            detail={"status": "not_ready", "missing_models": missing},
        )
    timeout = httpx.Timeout(connect=1.0, read=5.0, write=1.0, pool=1.0)
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.get(f"{COMFY_URL}/system_stats")
            response.raise_for_status()
        comfy_health.mark_success()
        return {
            "status": "ready",
            "comfyui": "ready",
            "active_family": active_family,
            "gpu_busy": generation_lock.locked(),
            "models": {"h3": "available", "zit": "available"},
        }
    except Exception as exc:
        comfy_health.mark_failure(f"{type(exc).__name__}: {exc}")
        raise HTTPException(
            status_code=503,
            detail={"status": "not_ready", "error": comfy_health.last_error},
        ) from exc


@app.get("/status")
async def status() -> dict[str, Any]:
    return {
        "active_family": active_family,
        "current_job_family": current_job_family,
        "gpu_busy": generation_lock.locked(),
        "family_switch_count": family_switch_count,
        "free_on_family_switch": FREE_ON_FAMILY_SWITCH,
        "reject_image_while_video_busy": REJECT_IMAGE_WHILE_VIDEO_BUSY,
    }


@app.post("/generate/video")
async def generate_video(envelope: GenerateEnvelope) -> dict[str, Any]:
    return await _generate_video(_payload(envelope))


@app.post("/generate/image")
async def generate_image(envelope: GenerateEnvelope) -> dict[str, Any]:
    return await _generate_image(_payload(envelope))


@app.post("/generate/sync")
async def generate_sync(envelope: GenerateEnvelope) -> dict[str, Any]:
    data = _payload(envelope)
    if _infer_task_type(data) == "image":
        return await _generate_image(data)
    return await _generate_video(data)
