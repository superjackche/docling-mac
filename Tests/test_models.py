import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


BACKEND = Path(__file__).resolve().parents[1] / "Backend"
sys.path.insert(0, str(BACKEND))
spec = importlib.util.spec_from_file_location("docling_mac_models", BACKEND / "models.py")
models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(models)


class ModelPreparationTests(unittest.TestCase):
    def test_download_failure_preserves_existing_state_and_does_not_verify(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "models.json"
            state.write_text("previously verified state")
            with patch.object(models, "required_snapshots", side_effect=OSError("download failed")):
                with patch.object(models, "verify_in_subprocess") as verify:
                    with contextlib.redirect_stdout(io.StringIO()):
                        with self.assertRaisesRegex(OSError, "download failed"):
                            models.prepare(state)
            self.assertEqual(state.read_text(), "previously verified state")
            verify.assert_not_called()

    def test_verification_failure_does_not_create_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "models.json"
            with patch.object(models, "required_snapshots", return_value=[]):
                with patch.object(models, "verify_in_subprocess", side_effect=RuntimeError("load failed")):
                    with contextlib.redirect_stdout(io.StringIO()):
                        with self.assertRaisesRegex(RuntimeError, "load failed"):
                            models.prepare(state)
            self.assertFalse(state.exists())

    def test_cancelled_verification_does_not_create_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "models.json"
            with patch.object(models, "required_snapshots", return_value=[]):
                with patch.object(models, "verify_in_subprocess", side_effect=KeyboardInterrupt):
                    with contextlib.redirect_stdout(io.StringIO()):
                        with self.assertRaises(KeyboardInterrupt):
                            models.prepare(state)
            self.assertFalse(state.exists())

    def test_success_writes_exact_verified_state_without_timestamps(self):
        verified = {"engine_lock": "a" * 64,
                    "models": [{"repo": "docling-project/test", "snapshot": "b" * 40}]}
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "models.json"
            stdout = io.StringIO()
            with patch.object(models, "required_snapshots", return_value=[]):
                with patch.object(models, "verify_in_subprocess", return_value=verified):
                    with contextlib.redirect_stdout(stdout):
                        models.prepare(state)
            self.assertEqual(json.loads(state.read_text()), verified)
            event = json.loads(stdout.getvalue().splitlines()[-1])
            self.assertEqual(event, {"event": "models_ready", "state": verified})
            self.assertEqual(list(Path(directory).iterdir()), [state])

    def test_verifier_child_forces_offline_and_inherits_process_group(self):
        result = subprocess.CompletedProcess([], 0, '{"event":"models_verified","state":{"ok":true}}\n', "")
        with patch.object(models.subprocess, "run", return_value=result) as run:
            self.assertEqual(models.verify_in_subprocess(), {"ok": True})
        self.assertEqual(run.call_args.kwargs["env"]["HF_HUB_OFFLINE"], "1")
        self.assertNotIn("start_new_session", run.call_args.kwargs)

    def test_snapshot_identity_uses_repository_and_commit(self):
        snapshot = "0123456789abcdef" * 2 + "01234567"
        path = Path("/cache/models--docling-project--docling-layout-heron/snapshots") / snapshot
        self.assertEqual(models.snapshot_record(path),
                         {"repo": "docling-project/docling-layout-heron", "snapshot": snapshot})


class UpdateTests(unittest.TestCase):
    def check_version(self, current, latest, available, yanked=False):
        response = io.BytesIO(json.dumps({"info": {"version": latest, "yanked": yanked}}).encode())
        stdout = io.StringIO()
        with patch.object(models, "version", return_value=current):
            with patch.object(models, "urlopen", return_value=response) as request:
                with contextlib.redirect_stdout(stdout):
                    models.updates()
        event = json.loads(stdout.getvalue())
        self.assertEqual(event["available"], available)
        self.assertEqual(event["current"], current)
        self.assertEqual(event["latest"], latest)
        self.assertEqual(event["url"], f"https://pypi.org/project/docling-slim/{latest}/")
        self.assertEqual(request.call_args.kwargs["timeout"], 15)
        self.assertEqual(request.call_args.args[0].full_url, models.PYPI_URL)

    def test_semantic_version_comparison(self):
        self.check_version("2.9.0", "2.10.0", True)

    def test_current_release_is_not_an_update(self):
        self.check_version("2.138.0", "2.138.0", False)

    def test_prerelease_and_yanked_release_are_not_offered(self):
        self.check_version("2.138.0", "2.139.0rc1", False)
        self.check_version("2.138.0", "2.139.0", False, yanked=True)


if __name__ == "__main__":
    unittest.main()
