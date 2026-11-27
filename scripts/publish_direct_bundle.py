#!/usr/bin/env python3
"""Publish an unpacked ComfyUI model tree to S3 as direct per-file objects + manifest.json.

Example:
  python3 scripts/publish_direct_bundle.py \
    --family h3 \
    --bundle-name beta7_sulpher3 \
    --source-dir /mnt/h3-build/beta7_sulpher3/files \
    --bucket rosely-infrastructure \
    --s3-prefix models/minimax-h3/beta7_sulpher3 \
    --region us-east-1
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config
from botocore.exceptions import ClientError

MIB = 1024 * 1024
GIB = 1024**3


def sha256_file(path: Path) -> str:
    if hasattr(hashlib, "file_digest"):
        with path.open("rb") as handle:
            return hashlib.file_digest(handle, "sha256").hexdigest()
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(32 * MIB), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload per-file S3 model bundle + manifest.json")
    parser.add_argument("--family", choices=["h3", "zit", "voice"], required=True)
    parser.add_argument("--bundle-name", required=True)
    parser.add_argument("--source-dir", required=True, help="Directory whose relative paths map under target root (ComfyUI/models/ or VOICE_BUNDLE_ROOT)")
    parser.add_argument("--bucket", default="rosely-infrastructure")
    parser.add_argument("--s3-prefix", required=True, help="Target S3 folder, e.g. models/minimax-h3/beta7_sulpher3")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--concurrency", type=int, default=16)
    parser.add_argument("--chunk-mib", type=int, default=64)
    parser.add_argument("--file-workers", type=int, default=3)
    parser.add_argument("--skip-existing", action="store_true", help="Skip upload if S3 object already has exact size")
    parser.add_argument("--local-manifest-out", default="", help="Optional local path to also save manifest.json")
    return parser.parse_args()


def priority_for(family: str, rel: str) -> int:
    # Lower priority number downloads first.
    if family == "zit":
        if rel.startswith(("diffusion_models/", "text_encoders/", "vae/", "loras/")):
            return 1
        return 2
    if family == "voice":
        if rel.startswith(("models/Qwen3-ASR-0.6B/", "models/chatterbox-turbo/", "voices/", "manifest/", "source/")):
            return 1
        return 2
    return 1


def main() -> int:
    args = parse_args()
    source_dir = Path(args.source_dir).resolve()
    if not source_dir.is_dir():
        raise SystemExit(f"Source directory does not exist: {source_dir}")

    s3_prefix = args.s3_prefix.strip("/")
    files_prefix = f"{s3_prefix}/files"

    local_files = sorted(p for p in source_dir.rglob("*") if p.is_file())
    if not local_files:
        raise SystemExit(f"No files found in {source_dir}")

    print(f"[publish:{args.bundle_name}] hashing {len(local_files)} files from {source_dir}...", flush=True)
    t0 = time.monotonic()

    def hash_one(path: Path) -> dict[str, Any]:
        rel = path.relative_to(source_dir).as_posix()
        size = path.stat().st_size
        digest = sha256_file(path)
        return {
            "path": rel,
            "s3_key": f"{files_prefix}/{rel}",
            "size": size,
            "sha256": digest,
            "priority": priority_for(args.family, rel),
            "_local": path,
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(local_files))) as pool:
        records = list(pool.map(hash_one, local_files))
    records.sort(key=lambda r: r["path"])

    total_bytes = sum(r["size"] for r in records)
    print(
        f"[publish:{args.bundle_name}] hashed {len(records)} files "
        f"({total_bytes / GIB:.2f} GiB) in {time.monotonic() - t0:.1f}s",
        flush=True,
    )
    for r in records:
        print(f"  {r['sha256']}  {r['size']:>12d}  {r['path']}", flush=True)

    transfer = TransferConfig(
        multipart_threshold=64 * MIB,
        multipart_chunksize=max(16, args.chunk_mib) * MIB,
        max_concurrency=max(4, args.concurrency),
        use_threads=True,
    )

    def make_s3():
        return boto3.client(
            "s3",
            region_name=args.region,
            config=Config(
                connect_timeout=60,
                read_timeout=900,
                tcp_keepalive=True,
                max_pool_connections=max(64, args.concurrency * 2),
                retries={"mode": "standard", "max_attempts": 15},
            ),
        )

    def upload_one(record: dict[str, Any]) -> None:
        s3 = make_s3()
        key = record["s3_key"]
        size = record["size"]
        local_path: Path = record["_local"]

        if args.skip_existing:
            try:
                head = s3.head_object(Bucket=args.bucket, Key=key)
                if int(head["ContentLength"]) == size and head.get("Metadata", {}).get("sha256") == record["sha256"]:
                    print(f"[skip-existing] s3://{args.bucket}/{key}", flush=True)
                    return
            except ClientError:
                pass

        start = time.monotonic()
        print(
            f"[upload] {record['path']} ({size / MIB:.1f} MiB) -> s3://{args.bucket}/{key}",
            flush=True,
        )
        s3.upload_file(
            str(local_path),
            args.bucket,
            key,
            ExtraArgs={
                "ServerSideEncryption": "AES256",
                "Metadata": {"sha256": record["sha256"]},
            },
            Config=transfer,
        )
        elapsed = max(0.001, time.monotonic() - start)
        print(
            f"[uploaded] {record['path']} in {elapsed:.1f}s ({(size / elapsed) / MIB:.1f} MiB/s)",
            flush=True,
        )

    # Upload largest files first for optimal parallelism.
    upload_order = sorted(records, key=lambda r: -r["size"])
    t_up = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(args.file_workers, len(upload_order))) as pool:
        futures = [pool.submit(upload_one, r) for r in upload_order]
        for fut in concurrent.futures.as_completed(futures):
            fut.result()

    print(
        f"[publish:{args.bundle_name}] uploaded all {len(records)} files in {time.monotonic() - t_up:.1f}s",
        flush=True,
    )

    manifest = {
        "schema_version": 1,
        "family": args.family,
        "bundle_name": args.bundle_name,
        "s3_prefix": files_prefix,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "file_count": len(records),
        "total_bytes": total_bytes,
        "files": [
            {
                "path": r["path"],
                "s3_key": r["s3_key"],
                "size": r["size"],
                "sha256": r["sha256"],
                "priority": r["priority"],
            }
            for r in records
        ],
    }
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()

    manifest_key = f"{s3_prefix}/manifest.json"
    checksum_key = f"{s3_prefix}/manifest.json.sha256"
    checksum_bytes = f"{manifest_sha}  manifest.json\n".encode("utf-8")

    s3 = make_s3()
    s3.put_object(
        Bucket=args.bucket,
        Key=manifest_key,
        Body=manifest_bytes,
        ContentType="application/json",
        ServerSideEncryption="AES256",
    )
    s3.put_object(
        Bucket=args.bucket,
        Key=checksum_key,
        Body=checksum_bytes,
        ContentType="text/plain",
        ServerSideEncryption="AES256",
    )

    if args.local_manifest_out:
        out_path = Path(args.local_manifest_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(manifest_bytes)
        out_path.with_suffix(out_path.suffix + ".sha256").write_bytes(checksum_bytes)

    print("\n=== PUBLISH COMPLETE ===", flush=True)
    print(f"MANIFEST_S3_URI=s3://{args.bucket}/{manifest_key}", flush=True)
    print(f"MANIFEST_KEY={manifest_key}", flush=True)
    print(f"MANIFEST_CHECKSUM_KEY={checksum_key}", flush=True)
    print(f"MANIFEST_SHA256={manifest_sha}", flush=True)
    print(f"TOTAL_BYTES={total_bytes}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
