from __future__ import annotations

import asyncio
import hashlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import model_server
from scripts import sync_models


class StagedReadinessTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.model_dir = self.root / "models"
        self.state_dir = self.root / "state"
        self.model_dir.mkdir(parents=True, exist_ok=True)
        self.state_dir.mkdir(parents=True, exist_ok=True)

        self.orig_zit = model_server.EXPECTED_ZIT_MODELS
        self.orig_h3 = model_server.EXPECTED_H3_MODELS
        self.orig_h3_ready = model_server.H3_READY_MARKER
        self.orig_h3_status = model_server.H3_STATUS_FILE
        self.orig_zit_ready = model_server.ZIT_READY_MARKER
        self.orig_zit_status = model_server.ZIT_STATUS_FILE
        self.orig_voice_ready = model_server.VOICE_READY_MARKER
        self.orig_voice_status = model_server.VOICE_STATUS_FILE
        self.orig_voice_env = model_server.VOICE_ENV_FILE
        self.orig_voice_enabled = model_server.VOICE_ENABLED
        self.orig_voice_vram_mode = model_server.VOICE_VRAM_MODE_RAW
        self.orig_require_h3 = model_server.REQUIRE_H3_FOR_HEALTH
        self.orig_require_voice = model_server.REQUIRE_VOICE_FOR_HEALTH
        self.orig_active_family = model_server.active_family

        model_server.EXPECTED_ZIT_MODELS = {
            name: self.model_dir / path.relative_to(model_server.MODEL_DIR)
            for name, path in self.orig_zit.items()
        }
        model_server.EXPECTED_H3_MODELS = {
            name: self.model_dir / path.relative_to(model_server.MODEL_DIR)
            for name, path in self.orig_h3.items()
        }
        model_server.H3_READY_MARKER = self.state_dir / "h3.ready"
        model_server.H3_STATUS_FILE = self.state_dir / "h3-download-status.json"
        model_server.ZIT_READY_MARKER = self.state_dir / "zit.ready"
        model_server.ZIT_STATUS_FILE = self.state_dir / "zit-download-status.json"
        model_server.VOICE_READY_MARKER = self.state_dir / "voice.ready"
        model_server.VOICE_STATUS_FILE = self.state_dir / "voice-download-status.json"
        model_server.VOICE_ENV_FILE = self.state_dir / "rosely-voice-avatar.env"
        model_server.VOICE_ENABLED = True
        model_server.VOICE_VRAM_MODE_RAW = "switch"
        model_server.REQUIRE_H3_FOR_HEALTH = False
        model_server.REQUIRE_VOICE_FOR_HEALTH = False
        model_server.active_family = None

        for p in model_server.EXPECTED_ZIT_MODELS.values():
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b"ok")
        model_server.ZIT_READY_MARKER.write_text("family=zit\n", encoding="utf-8")
        model_server.comfy_health.mark_success()

    def tearDown(self) -> None:
        model_server.EXPECTED_ZIT_MODELS = self.orig_zit
        model_server.EXPECTED_H3_MODELS = self.orig_h3
        model_server.H3_READY_MARKER = self.orig_h3_ready
        model_server.H3_STATUS_FILE = self.orig_h3_status
        model_server.ZIT_READY_MARKER = self.orig_zit_ready
        model_server.ZIT_STATUS_FILE = self.orig_zit_status
        model_server.VOICE_READY_MARKER = self.orig_voice_ready
        model_server.VOICE_STATUS_FILE = self.orig_voice_status
        model_server.VOICE_ENV_FILE = self.orig_voice_env
        model_server.VOICE_ENABLED = self.orig_voice_enabled
        model_server.VOICE_VRAM_MODE_RAW = self.orig_voice_vram_mode
        model_server.REQUIRE_H3_FOR_HEALTH = self.orig_require_h3
        model_server.REQUIRE_VOICE_FOR_HEALTH = self.orig_require_voice
        model_server.active_family = self.orig_active_family
        self._tmp.cleanup()

    def _populate_h3(self) -> None:
        for p in model_server.EXPECTED_H3_MODELS.values():
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b"h3")
        model_server.H3_READY_MARKER.write_text("family=h3\n", encoding="utf-8")
        model_server.H3_STATUS_FILE.write_text(
            json.dumps({"status": "ready", "percent": 100.0}),
            encoding="utf-8",
        )

    def test_health_ok_while_h3_downloading(self) -> None:
        model_server.H3_STATUS_FILE.write_text(
            json.dumps({"status": "downloading", "percent": 42.5}),
            encoding="utf-8",
        )
        with mock.patch.dict(os.environ, {"ROSELY_H3_OUTPUT_BUCKET": "rosely-infrastructure"}):
            res = asyncio.run(model_server.health())
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["models"]["zit"], "available")
        self.assertEqual(res["models"]["h3"], "downloading")
        self.assertEqual(res["h3_model"], "10Eros_Max_8stepTurbo_v1.0_hybrid-int8_HQ.safetensors")

    def test_wait_for_h3_succeeds_without_holding_generation_lock(self) -> None:
        model_server.H3_STATUS_FILE.write_text(
            json.dumps({"status": "downloading", "percent": 50.0}),
            encoding="utf-8",
        )

        async def run() -> None:
            waiter = asyncio.create_task(model_server._wait_for_h3_ready("vid_wait_1"))
            await asyncio.sleep(0.05)
            # ZiT image requests must still be able to acquire generation_lock while H3 waits.
            self.assertFalse(model_server.generation_lock.locked())
            self.assertEqual(model_server.h3_waiting_requests, 1)
            self._populate_h3()
            await waiter

        asyncio.run(run())
        self.assertEqual(model_server.h3_waiting_requests, 0)
        state, missing, _ = model_server._h3_availability()
        self.assertEqual(state, "available")
        self.assertEqual(missing, [])

    def test_wait_for_h3_fails_fast_on_download_error(self) -> None:
        model_server.H3_STATUS_FILE.write_text(
            json.dumps({"status": "failed", "error": "checksum mismatch"}),
            encoding="utf-8",
        )
        with self.assertRaises(model_server.HTTPException) as ctx:
            asyncio.run(model_server._wait_for_h3_ready("vid_fail_1"))
        self.assertEqual(ctx.exception.status_code, 503)
        self.assertEqual(ctx.exception.detail["reason"], "h3_model_download_failed")

    def test_patch_h3_workflow_supports_v1_model_and_samplers(self) -> None:
        wf, meta = model_server._patch_h3_workflow(
            {
                "prompt": "gentle smile",
                "width": 480,
                "height": 864,
                "duration_seconds": 5,
                "steps": 8,
                "sampler": "lcm",
                "scheduler": "simple",
                "seed": 77,
            },
            "ref.png",
            "req_v1",
        )
        self.assertEqual(
            wf["2"]["inputs"]["unet_name"],
            "10Eros_Max_8stepTurbo_v1.0_hybrid-int8_HQ.safetensors",
        )
        self.assertEqual(wf["12"]["inputs"]["sampler_name"], "lcm")
        self.assertEqual(meta["sampler"], "lcm")
        self.assertEqual(meta["model"], "10Eros_Max_8stepTurbo_v1.0_hybrid-int8_HQ.safetensors")

    def test_safe_rel_path_rejects_traversal(self) -> None:
        self.assertEqual(
            sync_models._safe_rel_path("diffusion_models/a.safetensors").as_posix(),
            "diffusion_models/a.safetensors",
        )
        with self.assertRaises(ValueError):
            sync_models._safe_rel_path("../etc/passwd")
        with self.assertRaises(ValueError):
            sync_models._safe_rel_path("diffusion_models/../../bad.safetensors")

    def test_sync_direct_manifest_atomic_and_cached_skip(self) -> None:
        comfy_dir = self.root / "ComfyUI"
        state_dir = self.root / "sync_state"
        payload_a = b"model-weights-a" * 1024
        payload_b = b"model-weights-b" * 512
        sha_a = hashlib.sha256(payload_a).hexdigest()
        sha_b = hashlib.sha256(payload_b).hexdigest()

        manifest = {
            "schema_version": 1,
            "family": "h3",
            "bundle_name": "beta7_sulpher3",
            "s3_prefix": "models/minimax-h3/beta7_sulpher3/files",
            "files": [
                {
                    "path": "diffusion_models/m.safetensors",
                    "s3_key": "models/minimax-h3/beta7_sulpher3/files/diffusion_models/m.safetensors",
                    "size": len(payload_a),
                    "sha256": sha_a,
                    "priority": 1,
                },
                {
                    "path": "vae/v.safetensors",
                    "s3_key": "models/minimax-h3/beta7_sulpher3/files/vae/v.safetensors",
                    "size": len(payload_b),
                    "sha256": sha_b,
                    "priority": 1,
                },
            ],
        }
        manifest_bytes = json.dumps(manifest).encode("utf-8")
        manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
        objects = {
            "models/minimax-h3/beta7_sulpher3/manifest.json": manifest_bytes,
            "models/minimax-h3/beta7_sulpher3/manifest.json.sha256": f"{manifest_sha}  manifest.json\n".encode(),
            "models/minimax-h3/beta7_sulpher3/files/diffusion_models/m.safetensors": payload_a,
            "models/minimax-h3/beta7_sulpher3/files/vae/v.safetensors": payload_b,
        }
        download_calls: list[str] = []

        class FakeS3:
            def get_object(self, Bucket: str, Key: str):
                return {"Body": io.BytesIO(objects[Key])}

            def download_file(self, Bucket: str, Key: str, Filename: str, Config=None, Callback=None):
                download_calls.append(Key)
                data = objects[Key]
                Path(Filename).write_bytes(data)
                if Callback:
                    Callback(len(data))

        args = SimpleNamespace(
            family="h3",
            bucket="rosely-infrastructure",
            model_key="models/minimax-h3/beta7_sulpher3/manifest.json",
            checksum_key="models/minimax-h3/beta7_sulpher3/manifest.json.sha256",
            expected_sha256=manifest_sha,
            expected_size=0,
            region="us-east-1",
            endpoint_url="",
            comfy_dir=str(comfy_dir),
            state_dir=str(state_dir),
            concurrency=8,
            chunk_mib=16,
            file_workers=2,
            retries=1,
        )

        with mock.patch.object(sync_models, "_build_s3_client", return_value=FakeS3()):
            sync_models._sync_direct_manifest(args)
            self.assertEqual(len(download_calls), 2)
            self.assertEqual(
                (comfy_dir / "models/diffusion_models/m.safetensors").read_bytes(),
                payload_a,
            )
            self.assertEqual(
                (comfy_dir / "models/vae/v.safetensors").read_bytes(),
                payload_b,
            )
            self.assertTrue((state_dir / "h3.ready").is_file())
            status_data = json.loads((state_dir / "h3-download-status.json").read_text())
            self.assertEqual(status_data["status"], "ready")
            self.assertEqual(status_data["percent"], 100.0)

            # Second run should skip all downloads via verified ready fingerprint.
            sync_models._sync_direct_manifest(args)
            self.assertEqual(len(download_calls), 2)

    def test_seedvr2_layout_and_validation_cache_populated(self) -> None:
        models_root = self.root / "seedvr2_models"
        seedvr2_dir = models_root / "SEEDVR2"
        seedvr2_dir.mkdir(parents=True, exist_ok=True)
        gguf = seedvr2_dir / "seedvr2_ema_7b-Q4_K_M.gguf"
        gguf.write_bytes(b"gguf-bytes")
        entries = [
            {
                "rel_str": "SEEDVR2/seedvr2_ema_7b-Q4_K_M.gguf",
                "sha256": "db9cb2ad90ebd40d2e8c29da2b3fc6fd03ba87cd58cbadceccca13ad27162789",
            }
        ]
        sync_models._finalize_seedvr2_layout(models_root, entries)
        self.assertTrue((models_root / "seedvr2").is_symlink())
        cache_path = seedvr2_dir / ".validation_cache.json"
        self.assertTrue(cache_path.is_file())
        cache = json.loads(cache_path.read_text(encoding="utf-8"))
        self.assertEqual(cache["seedvr2_ema_7b-Q4_K_M.gguf"]["size"], len(b"gguf-bytes"))
        self.assertEqual(
            cache["seedvr2_ema_7b-Q4_K_M.gguf"]["hash"],
            "db9cb2ad90ebd40d2e8c29da2b3fc6fd03ba87cd58cbadceccca13ad27162789",
        )

    def test_health_ok_while_h3_and_voice_bootstrapping(self) -> None:
        model_server.H3_STATUS_FILE.write_text(
            json.dumps({"status": "downloading", "percent": 25.0}), encoding="utf-8"
        )
        model_server.VOICE_STATUS_FILE.write_text(
            json.dumps({"status": "installing", "stage": "installing_ditto_env", "percent": 88.0}),
            encoding="utf-8",
        )
        with mock.patch.dict(os.environ, {"ROSELY_H3_OUTPUT_BUCKET": "rosely-infrastructure"}):
            res = asyncio.run(model_server.health())
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["models"], {"h3": "downloading", "zit": "available", "voice": "installing"})
        self.assertIn("/v1/tts", res["routes"])
        self.assertIn("/v1/avatar/generate", res["routes"])

    def test_wait_for_voice_succeeds_without_holding_lock(self) -> None:
        model_server.VOICE_STATUS_FILE.write_text(
            json.dumps({"status": "installing", "percent": 75.0}), encoding="utf-8"
        )

        async def run() -> None:
            waiter = asyncio.create_task(model_server._wait_for_voice_ready("/v1/tts"))
            await asyncio.sleep(0.05)
            self.assertFalse(model_server.generation_lock.locked())
            self.assertEqual(model_server.voice_waiting_requests, 1)
            model_server.VOICE_READY_MARKER.write_text("family=voice\n", encoding="utf-8")
            model_server.VOICE_STATUS_FILE.write_text(
                json.dumps({"status": "ready", "percent": 100.0}), encoding="utf-8"
            )
            await waiter

        asyncio.run(run())
        self.assertEqual(model_server.voice_waiting_requests, 0)
        state, _ = model_server._voice_availability()
        self.assertEqual(state, "available")

    def test_voice_env_key_loaded_dynamically_and_live_call_blocks_comfy(self) -> None:
        model_server.VOICE_ENV_FILE.write_text(
            "VOICE_API_KEY=abc\nGATEWAY_API_KEY=secret_dyn_123\n", encoding="utf-8"
        )
        with mock.patch.dict(os.environ, {"GATEWAY_API_KEY": ""}, clear=False):
            self.assertEqual(model_server._read_voice_gateway_key(), "secret_dyn_123")

        with mock.patch.object(model_server, "_is_live_call_active", return_value=True):
            with self.assertRaises(model_server.HTTPException) as ctx:
                asyncio.run(model_server._prepare_family("h3"))
            self.assertEqual(ctx.exception.status_code, 503)
            self.assertEqual(ctx.exception.detail["reason"], "live_call_in_progress")

    def test_switch_mode_stops_voice_when_returning_to_zit_and_frees_comfy_for_voice(self) -> None:
        calls: list[str] = []

        async def fake_free(reason: str) -> None:
            calls.append(f"free:{reason}")

        async def fake_ctl(action: str, timeout_s: float) -> None:
            calls.append(f"ctl:{action}")

        gw_running = False

        async def fake_gw_healthy() -> bool:
            return gw_running

        async def run() -> None:
            nonlocal gw_running
            model_server.active_family = "zit"
            with (
                mock.patch.object(model_server, "_free_comfy_memory", side_effect=fake_free),
                mock.patch.object(model_server, "_run_voice_ctl", side_effect=fake_ctl),
                mock.patch.object(model_server, "_is_live_call_active", return_value=False),
                mock.patch.object(model_server, "_voice_gateway_healthy", side_effect=[False, True, True]),
            ):
                await model_server._prepare_family("voice")
                self.assertEqual(model_server.active_family, "voice")
                await model_server._prepare_family("h3")
                self.assertEqual(model_server.active_family, "h3")

        asyncio.run(run())
        self.assertEqual(calls, ["free:family_switch=zit->voice", "ctl:start", "ctl:stop"])

    def test_sync_direct_manifest_supports_dest_root_and_ready_marker_for_voice(self) -> None:
        dest_root = self.root / "rosely-voice-v1"
        state_dir = self.root / "voice_sync_state"
        payload = b"wav-voice-bytes" * 64
        sha = hashlib.sha256(payload).hexdigest()
        manifest = {
            "schema_version": 1,
            "family": "voice",
            "bundle_name": "rosely-voice-ditto-v1",
            "s3_prefix": "models/voice-avatar/rosely-voice-ditto-v1/files",
            "files": [
                {
                    "path": "voices/en_female_original.wav",
                    "s3_key": "models/voice-avatar/rosely-voice-ditto-v1/files/voices/en_female_original.wav",
                    "size": len(payload),
                    "sha256": sha,
                    "priority": 1,
                }
            ],
        }
        manifest_bytes = json.dumps(manifest).encode("utf-8")
        manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
        objects = {
            "models/voice-avatar/rosely-voice-ditto-v1/manifest.json": manifest_bytes,
            "models/voice-avatar/rosely-voice-ditto-v1/manifest.json.sha256": f"{manifest_sha}  manifest.json\n".encode(),
            "models/voice-avatar/rosely-voice-ditto-v1/files/voices/en_female_original.wav": payload,
        }

        class FakeS3:
            def get_object(self, Bucket: str, Key: str):
                return {"Body": io.BytesIO(objects[Key])}

            def download_file(self, Bucket: str, Key: str, Filename: str, Config=None, Callback=None):
                data = objects[Key]
                Path(Filename).write_bytes(data)
                if Callback:
                    Callback(len(data))

        custom_marker = state_dir / "voice-models.ready"
        args = SimpleNamespace(
            family="voice",
            bucket="rosely-infrastructure",
            model_key="models/voice-avatar/rosely-voice-ditto-v1/manifest.json",
            checksum_key="models/voice-avatar/rosely-voice-ditto-v1/manifest.json.sha256",
            expected_sha256=manifest_sha,
            expected_size=0,
            region="us-east-1",
            endpoint_url="",
            comfy_dir=str(self.root / "ComfyUI"),
            dest_root=str(dest_root),
            ready_marker=str(custom_marker),
            state_dir=str(state_dir),
            concurrency=4,
            chunk_mib=16,
            file_workers=1,
            retries=1,
        )
        with mock.patch.object(sync_models, "_build_s3_client", return_value=FakeS3()):
            sync_models._sync_direct_manifest(args)
        self.assertEqual((dest_root / "voices/en_female_original.wav").read_bytes(), payload)
        self.assertTrue(custom_marker.is_file())
        self.assertFalse((state_dir / "voice.ready").exists())

    def test_voice_ctl_detached_daemon_does_not_leak_flock_or_hang_stop(self) -> None:
        # Regression test: spawning detached uvicorn daemons inside voice_ctl.sh
        # must close fd 9 (voice-ctl.lock) so a subsequent stop never deadlocks.
        script_text = (Path(__file__).resolve().parent.parent / "scripts" / "voice_ctl.sh").read_text(encoding="utf-8")
        self.assertIn("close_fds=True", script_text)
        self.assertIn("start_new_session=True", script_text)
        self.assertIn("flock -w 30 9", script_text)

        import subprocess

        lock_file = self.state_dir / "test-voice-ctl.lock"
        pid_file = self.state_dir / "daemon.pid"
        py_exe = os.sys.executable
        start_cmd = (
            f'exec 9>"{lock_file}"; flock -w 5 9; '
            f'"{py_exe}" -c "import subprocess, sys; '
            f'p = subprocess.Popen([sys.executable, \'-c\', \'import time; time.sleep(30)\'], '
            f'stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, '
            f'close_fds=True, start_new_session=True); '
            f'open({str(pid_file)!r}, \'w\').write(str(p.pid))"'
        )
        subprocess.run(["/bin/bash", "-c", start_cmd], check=True, timeout=5)
        daemon_pid = int(pid_file.read_text().strip())
        try:
            # Must acquire lock immediately while daemon is still alive!
            stop_cmd = f'exec 9>"{lock_file}"; flock -w 2 9 && echo LOCK_ACQUIRED'
            res = subprocess.run(["/bin/bash", "-c", stop_cmd], capture_output=True, text=True, check=True, timeout=5)
            self.assertIn("LOCK_ACQUIRED", res.stdout)
        finally:
            try:
                os.kill(daemon_pid, 9)
            except ProcessLookupError:
                pass

    def test_voice_request_rejects_fast_with_503_while_h3_video_is_busy(self) -> None:
        (self.state_dir / "voice.ready").write_text("ok", encoding="utf-8")

        class FakeRequest:
            async def json(self):
                return {"input": "hello", "voice": "en_female_original"}

        async def run() -> None:
            async with model_server.generation_lock:
                model_server.current_job_family = "h3"
                try:
                    with self.assertRaises(model_server.HTTPException) as ctx:
                        await model_server._proxy_voice("/v1/tts", FakeRequest())
                finally:
                    model_server.current_job_family = None
            self.assertEqual(ctx.exception.status_code, 503)
            self.assertEqual(ctx.exception.detail["status"], "busy")
            self.assertEqual(ctx.exception.detail["reason"], "video_generation_in_progress")
            self.assertTrue(ctx.exception.detail["retryable"])

        with (
            mock.patch.object(model_server, "VOICE_ENABLED", True),
            mock.patch.object(model_server, "REJECT_VOICE_WHILE_VIDEO_BUSY", True),
        ):
            asyncio.run(run())

    def test_ditto_warm_does_not_block_concurrent_stt_or_tts(self) -> None:
        (self.state_dir / "voice.ready").write_text("ok", encoding="utf-8")
        model_server.VOICE_ENV_FILE.write_text("GATEWAY_API_KEY=secret_test\n", encoding="utf-8")
        warm_entered = asyncio.Event()
        release_warm = asyncio.Event()

        class FakeResp:
            def __init__(self, data):
                self.status_code = 200
                self._data = data

            def json(self):
                return self._data

        class FakeClient:
            is_closed = False

            async def post(self, url, json=None, headers=None, timeout=None):
                if url.endswith("/v1/ditto/warm"):
                    warm_entered.set()
                    await release_warm.wait()
                    return FakeResp({"ok": True, "clips": {}})
                return FakeResp({"text": "hello"})

        class FakeReq:
            def __init__(self, body):
                self._body = body

            async def json(self):
                return self._body

        async def run() -> None:
            model_server.active_family = "voice"
            model_server._voice_last_healthy_at = 1e12
            with mock.patch.object(model_server, "_get_voice_gateway_client", return_value=FakeClient()):
                warm_task = asyncio.create_task(model_server._proxy_voice("/v1/ditto/warm", FakeReq({"clips": []})))
                await asyncio.wait_for(warm_entered.wait(), timeout=2)
                # /v1/stt must complete immediately while /v1/ditto/warm is still running!
                stt_res = await asyncio.wait_for(
                    model_server._proxy_voice("/v1/stt", FakeReq({"audio_base64": "YQ=="})),
                    timeout=2,
                )
                self.assertEqual(stt_res, {"text": "hello"})
                release_warm.set()
                warm_res = await asyncio.wait_for(warm_task, timeout=2)
                self.assertEqual(warm_res, {"ok": True, "clips": {}})

        asyncio.run(run())
        self.assertEqual(model_server._voice_inflight, 0)


if __name__ == "__main__":
    unittest.main()
