"""Batch/cache contracts; run with Docling Mac's runtime Python, without models."""

import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "Backend"
sys.path.insert(0, str(BACKEND))
import result_cache
import worker


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="docling batch tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.sequence = 0

    def source(self, name="source.html", text="批量转换测试"):
        source = self.root / name
        source.write_text(f"<!doctype html><html><body><h1>{text}</h1><p>Local document.</p></body></html>", encoding="utf-8")
        return source

    def manifest(self, sources, *, ocr=False, identity="models-v1", protected=()):
        self.sequence += 1
        path = self.root / f"manifest-{self.sequence}.json"
        data = {
            "jobs": [{"id": str(uuid.uuid4()), "source": str(source)} for source in sources],
            "ocr": ocr, "cache": str(self.cache),
            "output": str(self.root / f"session-{self.sequence}"),
            "protected": [str(path) for path in protected], "models_identity": identity,
        }
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def run_cli(self, manifest, backend=BACKEND):
        started = time.perf_counter()
        process = subprocess.run(
            [sys.executable, str(backend / "worker.py"), "--batch", str(manifest)],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"},
        )
        events = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
        return process, events, time.perf_counter() - started

    def completed(self, process, events, count):
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(events[-1]["event"], "batch_complete")
        self.assertFalse([event for event in events if event["event"] == "error"], process.stdout)
        completed = [event for event in events if event["event"] == "complete"]
        self.assertEqual(len(completed), count)
        return completed

    def in_process(self, manifest):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            worker.run_batch(manifest)
        return [json.loads(line) for line in stdout.getvalue().splitlines() if line.strip()]

    def test_identical_content_different_names_reuses_second_result(self):
        first = self.source("first.html")
        second = self.root / "different filename.html"
        shutil.copyfile(first, second)
        process, events, _ = self.run_cli(self.manifest([first, second]))
        completed = self.completed(process, events, 2)
        self.assertEqual([event["cached"] for event in completed], [False, True])
        self.assertEqual(completed[0]["output"], completed[1]["output"])

    def test_cross_batch_cache_hit_never_initializes_converter(self):
        source = self.source()
        process, events, _ = self.run_cli(self.manifest([source]))
        first = self.completed(process, events, 1)[0]
        with patch.object(worker, "make_converter", side_effect=AssertionError("cached batch loaded converter")) as create:
            events = self.in_process(self.manifest([source]))
        create.assert_not_called()
        completed = [event for event in events if event["event"] == "complete"]
        self.assertEqual(len(completed), 1, events)
        self.assertTrue(completed[0]["cached"])
        self.assertEqual(completed[0]["output"], first["output"])

    def test_changed_content_invalidates_cache(self):
        source = self.source(text="Original contents")
        process, events, _ = self.run_cli(self.manifest([source]))
        first = self.completed(process, events, 1)[0]
        self.source(text="Changed contents")
        process, events, _ = self.run_cli(self.manifest([source]))
        second = self.completed(process, events, 1)[0]
        self.assertFalse(second["cached"])
        self.assertNotEqual(first["output"], second["output"])
        self.assertIn("Changed contents", (Path(second["output"]) / "document.md").read_text())

    def test_ocr_and_model_identity_invalidate_cache(self):
        source = self.source()
        outputs = []
        for ocr, identity in [(False, "models-v1"), (True, "models-v1"), (True, "models-v2")]:
            process, events, _ = self.run_cli(self.manifest([source], ocr=ocr, identity=identity))
            event = self.completed(process, events, 1)[0]
            self.assertFalse(event["cached"])
            outputs.append(event["output"])
        self.assertEqual(len(set(outputs)), 3)

    def test_worker_and_engine_lock_changes_invalidate_cache(self):
        backend = self.root / "Backend"
        backend.mkdir()
        for name in ("worker.py", "result_cache.py", "uv.lock", "runtime.json"):
            shutil.copyfile(BACKEND / name, backend / name)
        source = self.source()
        outputs = []
        for changed_file in (None, "worker.py", "uv.lock"):
            if changed_file:
                with (backend / changed_file).open("a") as stream:
                    stream.write("\n# Acceptance version change.\n")
            process, events, _ = self.run_cli(self.manifest([source]), backend)
            event = self.completed(process, events, 1)[0]
            self.assertFalse(event["cached"])
            outputs.append(event["output"])
        self.assertEqual(len(set(outputs)), 3)

    def test_corrupt_input_does_not_block_following_job_or_enter_cache(self):
        broken = self.root / "broken.docx"
        broken.write_bytes(b"PK\x03\x04broken-office-document")
        good = self.source()
        manifest = self.manifest([broken, good])
        jobs = json.loads(manifest.read_text())["jobs"]
        process, events, _ = self.run_cli(manifest)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(events[-1]["event"], "batch_complete")
        failures = [event for event in events if event["event"] == "error"]
        successes = [event for event in events if event["event"] == "complete"]
        self.assertEqual([event["id"] for event in failures], [jobs[0]["id"]])
        self.assertEqual([event["id"] for event in successes], [jobs[1]["id"]])
        cache = result_cache.ResultCache(self.cache, worker.configuration())
        key = cache.key(result_cache.fingerprint(broken)[0], ".docx", False, "models-v1")
        self.assertFalse((self.cache / key).exists())

    def test_missing_cache_file_is_rebuilt(self):
        self.check_missing_cache_file("document.json")

    def test_missing_cache_manifest_is_rebuilt(self):
        self.check_missing_cache_file("result.json")

    def check_missing_cache_file(self, filename):
        source = self.source()
        process, events, _ = self.run_cli(self.manifest([source]))
        first = self.completed(process, events, 1)[0]
        (Path(first["output"]) / filename).unlink()
        process, events, _ = self.run_cli(self.manifest([source]))
        rebuilt = self.completed(process, events, 1)[0]
        self.assertFalse(rebuilt["cached"])
        self.assertTrue((Path(rebuilt["output"]) / filename).is_file())
        process, events, _ = self.run_cli(self.manifest([source]))
        self.assertTrue(self.completed(process, events, 1)[0]["cached"])

    def test_partial_results_are_available_but_never_cached(self):
        source = self.source()

        def partial(_source, output, *_args, **_kwargs):
            output.mkdir(parents=True)
            for name in result_cache.FILES:
                (output / name).write_text("partial document")
            return {"partial": True, "warnings": ["one page failed"], "pages": 1}

        with patch.object(worker, "make_converter", return_value=object()) as create:
            with patch.object(worker, "convert", side_effect=partial) as convert:
                events = self.in_process(self.manifest([source, source]))
        completed = [event for event in events if event["event"] == "complete"]
        self.assertEqual(len(completed), 2, events)
        self.assertEqual(create.call_count, 1)
        self.assertEqual(convert.call_count, 2)
        self.assertTrue(all(event["partial"] and not event["cached"] for event in completed))
        self.assertTrue(all(Path(event["output"]).is_dir() for event in completed))
        self.assertFalse([path for path in self.cache.iterdir() if path.is_dir()])

    def test_capacity_and_ttl_pruning_keep_protected_results(self):
        for scenario in ("capacity", "ttl"):
            with self.subTest(scenario=scenario):
                root = self.root / scenario
                config = {**worker.configuration(), "cache_max_bytes": 10_000_000, "cache_max_age_days": 14}
                cache = result_cache.ResultCache(root, config)
                protected, removable = root / ("a" * 64), root / ("b" * 64)
                for target in (protected, removable):
                    staging = self.root / f"{scenario}-{target.name}"
                    staging.mkdir()
                    for name in result_cache.FILES:
                        (staging / name).write_text("sample export")
                    cache.publish(staging, target.name, {"partial": False, "warnings": [], "pages": 1})
                if scenario == "capacity":
                    config["cache_max_bytes"] = 1
                else:
                    old = time.time() - 15 * 86400
                    for target in (protected, removable):
                        os.utime(target / "result.json", (old, old))
                result_cache.ResultCache(root, config, [str(protected)])
                self.assertTrue(protected.is_dir())
                self.assertFalse(removable.exists())

    def test_cache_lock_rejects_a_parallel_engine(self):
        source = self.source()
        self.cache.mkdir()
        with (self.cache / ".lock").open("w") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            process, events, _ = self.run_cli(self.manifest([source]))
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(events[-1]["event"], "error")
        self.assertIn("另一个转换进程", events[-1]["message"])
        self.assertNotIn("started", [event["event"] for event in events])

    def test_100_html_mixed_duplicate_batch(self):
        sources = [self.source(f"file-{index:03}.html", f"Batch document {index % 20:02}") for index in range(100)]
        process, events, first_seconds = self.run_cli(self.manifest(sources))
        first = self.completed(process, events, 100)
        process, events, second_seconds = self.run_cli(self.manifest(sources))
        second = self.completed(process, events, 100)
        self.assertEqual(sum(event["cached"] for event in first), 80)
        self.assertTrue(all(event["cached"] for event in second))
        self.assertFalse([event for event in events if event["event"] == "status"])
        digests = []
        for index, event in enumerate(second):
            output = Path(event["output"])
            markdown = (output / "document.md").read_text()
            self.assertIn(f"Batch document {index % 20:02}", markdown)
            self.assertTrue(all((output / name).stat().st_size > 0 for name in result_cache.FILES))
            digests.append(hashlib.sha256(markdown.encode()).hexdigest())
        receipt = {
            "status": "passed", "files": 100, "unique_contents": 20, "format": "HTML",
            "hf_hub_offline": True,
            "first_batch": {"wall_seconds": first_seconds, "completed": 100, "cache_hits": 80},
            "cached_batch": {"wall_seconds": second_seconds, "completed": 100, "cache_hits": 100,
                             "converter_load_status_events": 0},
            "markdown_sha256": digests,
            "worker_sha256": hashlib.sha256((BACKEND / "worker.py").read_bytes()).hexdigest(),
            "engine_lock_sha256": hashlib.sha256((BACKEND / "uv.lock").read_bytes()).hexdigest(),
        }
        (ROOT / ".build").mkdir(exist_ok=True)
        (ROOT / ".build/batch-stress.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
