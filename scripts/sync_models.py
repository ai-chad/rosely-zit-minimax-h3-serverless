#!/usr/bin/env python3
"""High-speed, atomic per-file S3 manifest (and legacy tar.zst) model sync.

Supports two artifact formats, auto-detected by S3 key suffix:
1. Direct per-file manifest (`*.json`, recommended):
   Downloads individual model files in parallel directly to a staging directory
   on the same filesystem, verifies exact byte size + SHA-256 per file, and
   atomically renames each verified file into `<COMFY_DIR>/models/<rel>`.
   Eliminates archive extraction time and temporary archive disk overhead.
2. Legacy archive (`*.tar.zst`):
   Retained for backward compatibility with older Vast templates.

Writes live progress JSON to `<STATE_DIR>/<family>-download-status.json` and
writes `<STATE_DIR>/<family>.ready` only after every file is verified and in
place.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config

MIB = 1024 * 1024
GIB = 1024**3


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _sha256_file(path: Path) -> str:
    if hasattr(hashlib, "file_digest"):
        with path.open("rb") as handle:
            return hashlib.file_digest(handle, "sha256").hexdigest()
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(32 * MIB), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def _atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, path)


def _safe_rel_path(raw: str) -> Path:
    rel = Path(raw.strip().lstrip("/"))
    if not raw.strip() or rel.is_absolute() or ".." in rel.parts:
        raise ValueError(f"Unsafe relative model path in manifest: {raw!r}")
    return rel


def _build_s3_client(region: str, endpoint_url: str | None, max_pool: int):
    kwargs: dict[str, Any] = {
        "region_name": region or "us-east-1",
        "endpoint_url": endpoint_url or None,
        "config": Config(
            connect_timeout=60,
            read_timeout=900,
            tcp_keepalive=True,
            max_pool_connections=max(32, max_pool),
            retries={"mode": "standard", "max_attempts": 15},
            signature_version="s3v4",
        ),
    }
    if not os.environ.get("AWS_ACCESS_KEY_ID") and os.environ.get("AWS_UNIFIED_ACCESS_KEY_ID"):
        kwargs["aws_access_key_id"] = os.environ["AWS_UNIFIED_ACCESS_KEY_ID"]
        kwargs["aws_secret_access_key"] = os.environ["AWS_UNIFIED_SECRET_ACCESS_KEY"]
        if os.environ.get("AWS_UNIFIED_SESSION_TOKEN"):
            kwargs["aws_session_token"] = os.environ["AWS_UNIFIED_SESSION_TOKEN"]
    elif not os.environ.get("AWS_ACCESS_KEY_ID") and os.environ.get("AWS_ZIT_IMAGE_MODEL_ACCESS_KEY_ID"):
        kwargs["aws_access_key_id"] = os.environ["AWS_ZIT_IMAGE_MODEL_ACCESS_KEY_ID"]
        kwargs["aws_secret_access_key"] = os.environ["AWS_ZIT_IMAGE_MODEL_SECRET_ACCESS_KEY"]
        if os.environ.get("AWS_ZIT_IMAGE_MODEL_SESSION_TOKEN"):
            kwargs["aws_session_token"] = os.environ["AWS_ZIT_IMAGE_MODEL_SESSION_TOKEN"]
    return boto3.client("s3", **kwargs)


def _resolve_expected_sha(
    s3,
    *,
    label: str,
    bucket: str,
    checksum_key: str,
    expected_sha: str,
) -> str:
    fixed = expected_sha.strip().lower()
    if fixed and len(fixed) != 64:
        raise RuntimeError(f"{label}: expected SHA-256 must be 64 hex chars, got {fixed!r}")
    if checksum_key:
        body = s3.get_object(Bucket=bucket, Key=checksum_key)["Body"].read().decode("utf-8").strip()
        remote_sha = body.split()[0].lower() if body else ""
        if len(remote_sha) != 64:
            raise RuntimeError(f"{label}: invalid checksum object at s3://{bucket}/{checksum_key}")
        if fixed and remote_sha != fixed:
            raise RuntimeError(
                f"{label}: checksum object ({remote_sha}) disagrees with expected SHA ({fixed})"
            )
        return remote_sha
    return fixed


class ProgressTracker:
    def __init__(
        self,
        *,
        family: str,
        mode: str,
        model_key: str,
        status_path: Path,
        manifest_sha256: str,
        total_bytes: int,
        files_total: int,
    ) -> None:
        self.family = family
        self.mode = mode
        self.model_key = model_key
        self.status_path = status_path
        self.manifest_sha256 = manifest_sha256
        self.total_bytes = max(1, total_bytes)
        self.files_total = files_total
        self.downloaded_bytes = 0
        self.files_completed = 0
        self.active_files: set[str] = set()
        self.started_at = _utc_now()
        self.start_mono = time.monotonic()
        self.last_status_mono = 0.0
        self.last_log_mono = 0.0
        self.lock = threading.Lock()
        self._flush("downloading", force=True)

    def _snapshot(self, status: str, error: str | None = None) -> dict[str, Any]:
        elapsed = max(0.001, time.monotonic() - self.start_mono)
        pct = min(100.0, (self.downloaded_bytes / self.total_bytes) * 100.0)
        speed_mib = (self.downloaded_bytes / elapsed) / MIB
        now = _utc_now()
        return {
            "family": self.family,
            "mode": self.mode,
            "status": status,
            "model_key": self.model_key,
            "manifest_sha256": self.manifest_sha256,
            "total_bytes": self.total_bytes,
            "downloaded_bytes": self.downloaded_bytes,
            "percent": round(pct, 2),
            "speed_mib_s": round(speed_mib, 1),
            "files_completed": self.files_completed,
            "files_total": self.files_total,
            "active_files": sorted(self.active_files),
            "started_at": self.started_at,
            "updated_at": now,
            "finished_at": now if status in {"ready", "failed"} else None,
            "error": error,
        }

    def _flush(self, status: str, *, force: bool = False, error: str | None = None) -> None:
        now = time.monotonic()
        if not force and now - self.last_status_mono < 2.0:
            return
        self.last_status_mono = now
        snap = self._snapshot(status, error=error)
        _atomic_write_json(self.status_path, snap)
        if force or now - self.last_log_mono >= 5.0:
            self.last_log_mono = now
            print(
                f"[{self.family}] {snap['percent']:6.2f}% "
                f"{snap['downloaded_bytes'] / GIB:.2f}/{snap['total_bytes'] / GIB:.2f} GiB "
                f"({snap['files_completed']}/{snap['files_total']} files) "
                f"{snap['speed_mib_s']:.1f} MiB/s",
                flush=True,
            )

    def mark_file_started(self, rel: str) -> None:
        with self.lock:
            self.active_files.add(rel)
            self._flush("downloading", force=False)

    def add_bytes(self, amount: int) -> None:
        with self.lock:
            self.downloaded_bytes += amount
            self._flush("downloading", force=False)

    def mark_file_done(self, rel: str, reused_bytes: int = 0) -> None:
        with self.lock:
            self.active_files.discard(rel)
            if reused_bytes:
                self.downloaded_bytes += reused_bytes
            self.files_completed += 1
            self._flush("downloading", force=True)

    def mark_ready(self) -> None:
        with self.lock:
            self.active_files.clear()
            self.downloaded_bytes = self.total_bytes
            self.files_completed = self.files_total
            self._flush("ready", force=True)

    def mark_failed(self, error: str) -> None:
        with self.lock:
            self.active_files.clear()
            self._flush("failed", force=True, error=error)


def _read_ready_fingerprint(ready_marker: Path) -> str:
    if not ready_marker.is_file():
        return ""
    for line in ready_marker.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("fingerprint="):
            return line.split("=", 1)[1].strip()
    return ""


def _write_ready_marker(ready_marker: Path, *, family: str, mode: str, fingerprint: str) -> None:
    _atomic_write_text(
        ready_marker,
        "\n".join(
            [
                f"family={family}",
                f"mode={mode}",
                f"fingerprint={fingerprint}",
                f"verified_at={_utc_now()}",
            ]
        )
        + "\n",
    )


@contextmanager
def _family_lock(state_dir: Path, family: str):
    state_dir.mkdir(parents=True, exist_ok=True)
    lock_path = state_dir / f"{family}.lock"
    with lock_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _finalize_seedvr2_layout(models_root: Path, entries: list[dict[str, Any]] | None = None) -> None:
    """Ensure uppercase SEEDVR2/ exists (with lowercase alias) and pre-populate
    ComfyUI-SeedVR2_VideoUpscaler's .validation_cache.json so the first upscaler
    request never re-hashes or redownloads verified weights."""
    upper = models_root / "SEEDVR2"
    lower = models_root / "seedvr2"

    if upper.is_dir() and not upper.is_symlink():
        if lower.is_symlink() or not lower.exists():
            lower.unlink(missing_ok=True)
            os.symlink(upper, lower)
        cache_dir = upper
    elif lower.is_dir() and not lower.is_symlink():
        if upper.is_symlink() or not upper.exists():
            upper.unlink(missing_ok=True)
            os.symlink(lower, upper)
        cache_dir = upper
    else:
        return

    cache_path = cache_dir / ".validation_cache.json"
    cache: dict[str, Any] = {}
    if cache_path.is_file():
        try:
            loaded = json.loads(cache_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                cache = loaded
        except Exception:
            cache = {}

    if entries:
        for entry in entries:
            rel_str = str(entry["rel_str"])
            if not rel_str.lower().startswith("seedvr2/"):
                continue
            target = cache_dir / Path(rel_str).name
            if target.is_file():
                st = target.stat()
                cache[target.name] = {
                    "size": st.st_size,
                    "mtime": st.st_mtime,
                    "hash": str(entry["sha256"]),
                }
        if cache:
            _atomic_write_json(cache_path, cache)


def _sync_direct_manifest(args: argparse.Namespace) -> None:
    family = args.family
    models_root = Path(args.comfy_dir) / "models"
    state_dir = Path(args.state_dir)
    staging_root = state_dir / f"{family}-staging"
    ready_marker = state_dir / f"{family}.ready"
    status_path = state_dir / f"{family}-download-status.json"

    models_root.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)

    total_concurrency = max(2, int(args.concurrency))
    chunk_bytes = max(8, int(args.chunk_mib)) * MIB
    file_workers = max(1, int(args.file_workers))
    per_file_concurrency = max(2, min(total_concurrency, max(4, total_concurrency // max(1, min(file_workers, 3)))))

    s3 = _build_s3_client(
        args.region,
        args.endpoint_url,
        max_pool=max(64, total_concurrency * 3),
    )

    expected_manifest_sha = _resolve_expected_sha(
        s3,
        label=f"{family}-manifest",
        bucket=args.bucket,
        checksum_key=args.checksum_key,
        expected_sha=args.expected_sha256,
    )

    print(
        f"[{family}] fetching direct manifest s3://{args.bucket}/{args.model_key}",
        flush=True,
    )
    raw_manifest = s3.get_object(Bucket=args.bucket, Key=args.model_key)["Body"].read()
    actual_manifest_sha = hashlib.sha256(raw_manifest).hexdigest()
    if expected_manifest_sha and actual_manifest_sha != expected_manifest_sha:
        raise RuntimeError(
            f"{family}: manifest SHA-256 mismatch: expected {expected_manifest_sha}, got {actual_manifest_sha}"
        )

    manifest = json.loads(raw_manifest.decode("utf-8"))
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise RuntimeError(f"{family}: manifest contains no files")

    entries: list[dict[str, Any]] = []
    for item in files:
        rel = _safe_rel_path(str(item["path"]))
        size = int(item["size"])
        sha256 = str(item["sha256"]).strip().lower()
        s3_key = str(item["s3_key"]).strip()
        priority = int(item.get("priority", 10))
        if size <= 0 or len(sha256) != 64 or not s3_key:
            raise RuntimeError(f"{family}: malformed manifest entry: {item!r}")
        entries.append(
            {
                "rel": rel,
                "rel_str": rel.as_posix(),
                "dest": models_root / rel,
                "size": size,
                "sha256": sha256,
                "s3_key": s3_key,
                "priority": priority,
            }
        )

    total_bytes = sum(e["size"] for e in entries)
    fingerprint = f"manifest|{args.bucket}|{args.model_key}|{actual_manifest_sha}"

    # Fast path: ready marker matches exact manifest fingerprint and every target file has exact size.
    if _read_ready_fingerprint(ready_marker) == fingerprint and all(
        e["dest"].is_file() and e["dest"].stat().st_size == e["size"] for e in entries
    ):
        if family == "zit":
            _finalize_seedvr2_layout(models_root, entries)
        print(
            f"[{family}] verified direct manifest already ready ({len(entries)} files, {total_bytes / GIB:.2f} GiB)",
            flush=True,
        )
        tracker = ProgressTracker(
            family=family,
            mode="direct_manifest",
            model_key=args.model_key,
            status_path=status_path,
            manifest_sha256=actual_manifest_sha,
            total_bytes=total_bytes,
            files_total=len(entries),
        )
        tracker.mark_ready()
        return

    ready_marker.unlink(missing_ok=True)
    # Sort by priority ascending, then size descending (LPT scheduling avoids tail stragglers).
    entries.sort(key=lambda e: (e["priority"], -e["size"], e["rel_str"]))

    tracker = ProgressTracker(
        family=family,
        mode="direct_manifest",
        model_key=args.model_key,
        status_path=status_path,
        manifest_sha256=actual_manifest_sha,
        total_bytes=total_bytes,
        files_total=len(entries),
    )

    transfer_cfg = TransferConfig(
        multipart_threshold=min(chunk_bytes, 32 * MIB),
        multipart_chunksize=chunk_bytes,
        max_concurrency=per_file_concurrency,
        use_threads=True,
    )

    def sync_one(entry: dict[str, Any]) -> None:
        rel_str = entry["rel_str"]
        dest: Path = entry["dest"]
        expected_size: int = entry["size"]
        expected_sha: str = entry["sha256"]

        # Reuse already-verified destination file if present.
        if dest.is_file() and dest.stat().st_size == expected_size:
            if _sha256_file(dest) == expected_sha:
                print(f"[{family}] reusing verified {rel_str}", flush=True)
                tracker.mark_file_done(rel_str, reused_bytes=expected_size)
                return
            dest.unlink(missing_ok=True)

        stage_part = staging_root / f"{rel_str}.part"
        stage_part.parent.mkdir(parents=True, exist_ok=True)
        stage_part.unlink(missing_ok=True)
        dest.parent.mkdir(parents=True, exist_ok=True)

        tracker.mark_file_started(rel_str)
        file_start = time.monotonic()

        # Use a dedicated thread-local boto3 client per worker thread for clean connection pooling.
        worker_s3 = _build_s3_client(
            args.region,
            args.endpoint_url,
            max_pool=max(32, per_file_concurrency * 2),
        )
        worker_s3.download_file(
            args.bucket,
            entry["s3_key"],
            str(stage_part),
            Config=transfer_cfg,
            Callback=tracker.add_bytes,
        )

        actual_size = stage_part.stat().st_size
        if actual_size != expected_size:
            stage_part.unlink(missing_ok=True)
            raise RuntimeError(
                f"{family}: size mismatch for {rel_str}: expected {expected_size}, got {actual_size}"
            )

        actual_sha = _sha256_file(stage_part)
        if actual_sha != expected_sha:
            stage_part.unlink(missing_ok=True)
            raise RuntimeError(
                f"{family}: SHA-256 mismatch for {rel_str}: expected {expected_sha}, got {actual_sha}"
            )

        os.chmod(stage_part, 0o644)
        os.replace(stage_part, dest)
        elapsed = max(0.001, time.monotonic() - file_start)
        print(
            f"[{family}] verified & installed {rel_str} "
            f"({expected_size / MIB:.1f} MiB in {elapsed:.1f}s)",
            flush=True,
        )
        tracker.mark_file_done(rel_str)

    try:
        workers = min(file_workers, len(entries))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(sync_one, entry) for entry in entries]
            for fut in concurrent.futures.as_completed(futures):
                fut.result()
    except Exception as exc:
        tracker.mark_failed(f"{type(exc).__name__}: {exc}")
        raise

    shutil.rmtree(staging_root, ignore_errors=True)
    if family == "zit":
        _finalize_seedvr2_layout(models_root, entries)
    _write_ready_marker(
        ready_marker,
        family=family,
        mode="direct_manifest",
        fingerprint=fingerprint,
    )
    tracker.mark_ready()
    print(
        f"[{family}] direct manifest sync COMPLETE ({len(entries)} files, {total_bytes / GIB:.2f} GiB)",
        flush=True,
    )


def _sync_legacy_archive(args: argparse.Namespace) -> None:
    family = args.family
    comfy_dir = Path(args.comfy_dir)
    models_root = comfy_dir / "models"
    state_dir = Path(args.state_dir)
    ready_marker = state_dir / f"{family}.ready"
    status_path = state_dir / f"{family}-download-status.json"
    archive_path = state_dir / f"{family}.tar.zst"
    staging_root = state_dir / f"{family}-archive-staging"

    models_root.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)

    concurrency = max(2, int(args.concurrency))
    chunk_bytes = max(16, int(args.chunk_mib)) * MIB
    s3 = _build_s3_client(args.region, args.endpoint_url, max_pool=max(32, concurrency * 2))

    head = s3.head_object(Bucket=args.bucket, Key=args.model_key)
    remote_size = int(head["ContentLength"])
    if args.expected_size and remote_size != int(args.expected_size):
        raise RuntimeError(
            f"{family}: size mismatch expected {args.expected_size}, got {remote_size}"
        )

    expected_sha = _resolve_expected_sha(
        s3,
        label=f"{family}-archive",
        bucket=args.bucket,
        checksum_key=args.checksum_key,
        expected_sha=args.expected_sha256,
    )
    if not expected_sha:
        raise RuntimeError(f"{family}: expected SHA unavailable for legacy archive")

    fingerprint = f"archive|{args.bucket}|{args.model_key}|{expected_sha}"
    if _read_ready_fingerprint(ready_marker) == fingerprint:
        print(f"[{family}] legacy archive already marked ready", flush=True)
        tracker = ProgressTracker(
            family=family,
            mode="archive",
            model_key=args.model_key,
            status_path=status_path,
            manifest_sha256=expected_sha,
            total_bytes=remote_size,
            files_total=1,
        )
        tracker.mark_ready()
        return

    ready_marker.unlink(missing_ok=True)
    tracker = ProgressTracker(
        family=family,
        mode="archive",
        model_key=args.model_key,
        status_path=status_path,
        manifest_sha256=expected_sha,
        total_bytes=remote_size,
        files_total=1,
    )

    try:
        reused = False
        if archive_path.is_file() and archive_path.stat().st_size == remote_size:
            if _sha256_file(archive_path) == expected_sha:
                print(f"[{family}] reusing verified cached archive {archive_path}", flush=True)
                tracker.add_bytes(remote_size)
                reused = True
            else:
                archive_path.unlink(missing_ok=True)

        if not reused:
            part_path = Path(f"{archive_path}.part")
            part_path.unlink(missing_ok=True)
            tracker.mark_file_started(args.model_key)
            transfer = TransferConfig(
                multipart_threshold=64 * MIB,
                multipart_chunksize=chunk_bytes,
                max_concurrency=concurrency,
                use_threads=True,
            )
            s3.download_file(
                args.bucket,
                args.model_key,
                str(part_path),
                Config=transfer,
                Callback=tracker.add_bytes,
            )
            if part_path.stat().st_size != remote_size:
                part_path.unlink(missing_ok=True)
                raise RuntimeError(f"{family}: downloaded archive size mismatch")
            actual_sha = _sha256_file(part_path)
            if actual_sha != expected_sha:
                part_path.unlink(missing_ok=True)
                raise RuntimeError(
                    f"{family}: archive SHA mismatch expected {expected_sha}, got {actual_sha}"
                )
            os.replace(part_path, archive_path)

        shutil.rmtree(staging_root, ignore_errors=True)
        staging_root.mkdir(parents=True, exist_ok=True)
        print(f"[{family}] extracting legacy archive {archive_path}", flush=True)
        subprocess.run(
            ["tar", "--zstd", "--no-same-owner", "-xf", str(archive_path), "-C", str(staging_root)],
            check=True,
        )

        # Support both `ComfyUI/models/...` (H3 archive) and `models/...` (ZiT archive).
        if (staging_root / "ComfyUI" / "models").is_dir():
            extracted_models = staging_root / "ComfyUI" / "models"
        elif (staging_root / "models").is_dir():
            extracted_models = staging_root / "models"
        else:
            raise RuntimeError(f"{family}: archive missing ComfyUI/models or models/ root")

        manifest_sha_file = staging_root / "model-files.sha256"
        if manifest_sha_file.is_file():
            print(f"[{family}] verifying archive internal model-files.sha256", flush=True)
            subprocess.run(
                ["sha256sum", "-c", "model-files.sha256"],
                cwd=str(staging_root),
                check=True,
            )

        for src in sorted(extracted_models.rglob("*")):
            if not src.is_file():
                continue
            rel = src.relative_to(extracted_models)
            dst = models_root / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            os.chmod(src, 0o644)
            os.replace(src, dst)

        shutil.rmtree(staging_root, ignore_errors=True)
        archive_path.unlink(missing_ok=True)
        _write_ready_marker(ready_marker, family=family, mode="archive", fingerprint=fingerprint)
        tracker.mark_ready()
    except Exception as exc:
        tracker.mark_failed(f"{type(exc).__name__}: {exc}")
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Sync Rosely H3 or ZiT models from S3")
    parser.add_argument("--family", choices=["zit", "h3"], required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--model-key", required=True)
    parser.add_argument("--checksum-key", default="")
    parser.add_argument("--expected-sha256", default="")
    parser.add_argument("--expected-size", type=int, default=0)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--endpoint-url", default="")
    parser.add_argument("--comfy-dir", default="/workspace/ComfyUI")
    parser.add_argument("--state-dir", default="/workspace/.rosely-h3-zit")
    parser.add_argument("--concurrency", type=int, default=16)
    parser.add_argument("--chunk-mib", type=int, default=32)
    parser.add_argument("--file-workers", type=int, default=4)
    parser.add_argument("--retries", type=int, default=4)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    attempts = max(1, int(args.retries))
    is_manifest = args.model_key.strip().lower().endswith(".json")

    with _family_lock(Path(args.state_dir), args.family):
        for attempt in range(1, attempts + 1):
            try:
                if is_manifest:
                    _sync_direct_manifest(args)
                else:
                    _sync_legacy_archive(args)
                return 0
            except Exception as exc:
                print(
                    f"[{args.family}] sync attempt {attempt}/{attempts} failed: {type(exc).__name__}: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                if attempt >= attempts:
                    return 1
                backoff = min(30, 3 * attempt)
                print(f"[{args.family}] retrying in {backoff}s...", file=sys.stderr, flush=True)
                time.sleep(backoff)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
