#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
from pathlib import Path

from vastai import Serverless


def image_payload(args: argparse.Namespace) -> dict:
    return {
        "input": {
            "task_type": "image",
            "request_id": args.request_id or "combined-zit-smoke",
            "mode": args.mode,
            "prompt": args.prompt,
            "width": args.width,
            "height": args.height,
            "steps": args.steps,
            "seed": args.seed,
        }
    }


def video_payload(args: argparse.Namespace) -> dict:
    data: dict = {
        "task_type": "video",
        "request_id": args.request_id or "combined-h3-smoke",
        "prompt": args.prompt,
        "width": args.width,
        "height": args.height,
        "duration_seconds": args.duration,
        "steps": args.steps,
        "include_audio": not args.no_audio,
        "seed": args.seed,
    }
    if args.input_image_url:
        data["input_image_url"] = args.input_image_url
    elif args.input_image_file:
        raw = Path(args.input_image_file).read_bytes()
        data["input_image_base64"] = base64.b64encode(raw).decode("ascii")
    else:
        raise SystemExit("video requires --input-image-url or --input-image-file")
    return {"input": data}


async def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--endpoint", default=os.getenv("VAST_ENDPOINT_NAME", "rosely-h3-zit-5090"))
    p.add_argument("--kind", choices=["image", "video"], required=True)
    p.add_argument("--request-id")
    p.add_argument("--prompt", default="portrait of an adult person, natural skin texture, soft daylight")
    p.add_argument("--mode", default="realistic")
    p.add_argument("--width", type=int)
    p.add_argument("--height", type=int)
    p.add_argument("--steps", type=int)
    p.add_argument("--duration", type=float, default=5.0)
    p.add_argument("--seed", type=int, default=12345)
    p.add_argument("--input-image-url")
    p.add_argument("--input-image-file")
    p.add_argument("--no-audio", action="store_true")
    args = p.parse_args()

    if args.kind == "image":
        args.width = args.width or 768
        args.height = args.height or 1344
        args.steps = args.steps or 12
        payload = image_payload(args)
        route = "/generate/image"
    else:
        args.width = args.width or 480
        args.height = args.height or 864
        args.steps = args.steps or 8
        payload = video_payload(args)
        route = "/generate/video"

    async with Serverless() as client:
        endpoint = await client.get_endpoint(name=args.endpoint)
        result = await endpoint.request(route, payload)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
