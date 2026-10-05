from __future__ import annotations

import unittest

from zit_workflow import MODE_TO_FILE, build_zit_workflow


class ZiTWorkflowTests(unittest.TestCase):
    def test_all_modes_build(self) -> None:
        for mode in MODE_TO_FILE:
            workflow, meta = build_zit_workflow(
                mode=mode,
                prompt="portrait test",
                request_id="req 123",
                seed=42,
                width=768,
                height=1344,
            )
            self.assertEqual(workflow["4"]["inputs"]["text"], "portrait test")
            self.assertEqual(workflow["7"]["inputs"]["seed"], 42)
            self.assertEqual(workflow["9"]["inputs"]["filename_prefix"], "image/zit/req-123")
            self.assertEqual(meta["mode"], mode)

    def test_alias(self) -> None:
        _, meta = build_zit_workflow(
            mode="anime",
            prompt="test",
            request_id="x",
            seed=1,
        )
        self.assertEqual(meta["mode"], "anime_illustria")

    def test_overrides(self) -> None:
        workflow, meta = build_zit_workflow(
            mode="realistic_male",
            prompt="test",
            request_id="x",
            seed=1,
            lora_strength=0.55,
            steps=9,
            cfg=1.2,
            sampler_name="dpmpp_sde",
            scheduler="simple",
        )
        self.assertEqual(workflow["10"]["inputs"]["strength_model"], 0.55)
        self.assertEqual(workflow["7"]["inputs"]["steps"], 9)
        self.assertEqual(meta["lora_strength"], 0.55)

    def test_invalid_dimensions(self) -> None:
        with self.assertRaises(ValueError):
            build_zit_workflow(
                mode="realistic",
                prompt="test",
                request_id="x",
                seed=1,
                width=769,
                height=1344,
            )


if __name__ == "__main__":
    unittest.main()
