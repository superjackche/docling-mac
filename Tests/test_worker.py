"""Run with the installed engine's Python; no PDF models or internet are needed."""

import json
import contextlib
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "Backend" / "worker.py"


class WorkerIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="docling mac test ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "中文文档 with spaces.html"
        self.output = self.root / "结果 with spaces"
        shutil.copyfile(ROOT / "Tests" / "fixtures" / "sample.html", self.source)

    def run_worker(self, source=None):
        result = subprocess.run(
            [sys.executable, str(WORKER), str(source or self.source), str(self.output)],
            capture_output=True,
            text=True,
            timeout=120,
        )
        events = [json.loads(line) for line in result.stdout.splitlines() if line]
        return result, events

    def test_html_exports_preserve_content_and_paths_with_spaces(self):
        original = self.source.read_bytes()
        result, events = self.run_worker()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[-1]["event"], "complete")
        self.assertFalse(events[-1]["partial"])
        markdown = (self.output / "document.md").read_text()
        self.assertIn("Docling Mac 验收文档", markdown)
        self.assertIn("保留段落结构", markdown)
        self.assertIn("HTML", markdown)
        self.assertIn("可导出", markdown)
        self.assertIn("Docling Mac 验收文档", (self.output / "document.html").read_text())
        document = json.loads((self.output / "document.json").read_text())
        self.assertTrue(document["texts"])
        self.assertEqual(original, self.source.read_bytes())

    def test_external_html_image_does_not_make_request(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(404)
                self.end_headers()

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.source.write_text(
                '<html><body><h1>Private conversion</h1>'
                f'<img src="http://127.0.0.1:{server.server_port}/private-token.png">'
                '</body></html>'
            )
            result, events = self.run_worker()
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[-1]["event"], "complete")
        self.assertEqual(requests, [])
        self.assertNotIn("private-token.png", (self.output / "document.html").read_text())

    def test_corrupted_docx_returns_error_without_output(self):
        source = self.root / "broken.docx"
        source.write_bytes(b"PK\x03\x04not-a-valid-office-archive")
        result, events = self.run_worker(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1]["event"], "error")
        self.assertNotIn("complete", [event["event"] for event in events])
        self.assertFalse(self.output.exists())

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir()
        marker = self.output / "document.md"
        marker.write_text("Keep the user's existing export.")
        result, events = self.run_worker()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1]["event"], "error")
        self.assertEqual(marker.read_text(), "Keep the user's existing export.")
        self.assertEqual(list(self.output.iterdir()), [marker])

    def test_url_is_rejected_as_input(self):
        result, events = self.run_worker("https://example.com/document.pdf")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1]["event"], "error")
        self.assertFalse(self.output.exists())

    def test_literal_code_cannot_become_active_exported_html(self):
        self.source.write_text(
            '<html><body><h1>Code example</h1><pre>'
            '&lt;script&gt;window.EXAMPLE_CODE=1&lt;/script&gt;'
            '&lt;img src="https://example.invalid/example-code.png"&gt;'
            '</pre></body></html>'
        )
        result, events = self.run_worker()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[-1]["event"], "complete")
        exported = (self.output / "document.html").read_text()
        self.assertNotIn("<script>", exported)
        self.assertNotIn('<img src="https://example.invalid', exported)
        self.assertIn("EXAMPLE_CODE", exported)

    def test_partial_result_keeps_nested_ocr_text_and_reports_warning(self):
        from docling.datamodel.base_models import ConversionStatus
        from docling_core.types.doc import DoclingDocument, DocItemLabel

        spec = importlib.util.spec_from_file_location("docling_mac_worker", WORKER)
        worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(worker)
        document = DoclingDocument(name="scan")
        picture = document.add_picture()
        document.add_text(label=DocItemLabel.TEXT, text="Scanned text remains readable", parent=picture)
        result = SimpleNamespace(
            document=document,
            status=ConversionStatus.PARTIAL_SUCCESS,
            errors=[SimpleNamespace(error_message="One page could not be parsed")],
        )
        stdout = io.StringIO()
        with patch("docling.document_converter.DocumentConverter.convert", return_value=result):
            with contextlib.redirect_stdout(stdout):
                worker.convert(self.source, self.output, ocr=True)
        events = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertTrue(events[-1]["partial"])
        self.assertEqual(events[-1]["warnings"], ["One page could not be parsed"])
        for extension in ("md", "html", "json"):
            self.assertIn("Scanned text remains readable", (self.output / f"document.{extension}").read_text())


if __name__ == "__main__":
    unittest.main()
