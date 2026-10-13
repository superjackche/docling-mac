#!/usr/bin/env python3
"""Run with Docling Mac's runtime Python. Downloads PDF models on first use."""

import argparse
from datetime import datetime, timezone
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time

from docx import Document
from openpyxl import Workbook
from PIL import Image, ImageDraw, ImageFont
from pptx import Presentation
from pptx.util import Inches


ROOT = Path(__file__).resolve().parents[1]
MODEL_HOME = Path.home() / "Library/Application Support/Docling Mac/models"
EXPECTED = ["Docling Mac acceptance", "文档转换测试", "本地处理保护隐私"]


def make_fixtures(directory, formats):
    document = Document()
    document.add_heading(EXPECTED[0], 0)
    document.add_heading(EXPECTED[1], 1)
    document.add_paragraph(EXPECTED[2])
    table = document.add_table(rows=2, cols=2)
    for row, cells in zip(table.rows, [("Format", "Status"), ("DOCX", "Ready")]):
        for cell, text in zip(row.cells, cells):
            cell.text = text
    document.save(directory / "sample.docx")

    presentation = Presentation()
    slide = presentation.slides.add_slide(presentation.slide_layouts[6])
    textbox = slide.shapes.add_textbox(Inches(1), Inches(1), Inches(8), Inches(4))
    textbox.text_frame.text = "\n".join(EXPECTED)
    presentation.save(directory / "sample.pptx")

    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "Acceptance"
    for text in EXPECTED:
        sheet.append([text])
    workbook.save(directory / "sample.xlsx")

    # macOS ships this CJK font; missing font is a setup error, not a silent substitution.
    font = ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", 64)
    scan = Image.new("RGB", (1800, 1000), "white")
    draw = ImageDraw.Draw(scan)
    for index, text in enumerate(EXPECTED):
        draw.text((120, 120 + index * 180), text, font=font, fill="black")
    scan.save(directory / "sample.png")
    # Pillow writes a raster-only PDF, so success requires actual OCR.
    scan.save(directory / "sample.pdf", resolution=150)
    if "native-pdf" in formats:
        subprocess.run(["swift", str(ROOT / "scripts/make-text-pdf.swift"),
                        str(directory / "native.pdf")], check=True)


def fingerprint(path):
    data = path.read_bytes()
    return {"path": str(path), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def save_receipt(receipt, directory, latest):
    text = json.dumps(receipt, ensure_ascii=False, indent=2)
    (directory / "receipt.json").write_text(text, encoding="utf-8")
    latest.write_text(text, encoding="utf-8")


def verify_one(extension, directory):
    source = directory / ("native.pdf" if extension == "native-pdf" else f"sample.{extension}")
    output = directory / f"export-{extension}"
    expected = EXPECTED if extension != "native-pdf" else [
        "Docling Mac PDF Check 1", "Docling Mac PDF Check 2",
        "Native PDF text remains searchable.", "本地文档转换验收",
    ]
    ocr = extension in {"png", "pdf"}
    record = {"format": extension, "source": fingerprint(source), "expected_text": expected, "ocr": ocr}
    command = [sys.executable, str(ROOT / "Backend/worker.py"), str(source), str(output)]
    if ocr:
        command.append("--ocr")
    env = {**os.environ, "HF_HOME": str(MODEL_HOME)}
    started = time.monotonic()
    print(f"Converting {source.name} ...", flush=True)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    try:
        stdout, stderr = process.communicate(timeout=1200)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        record["error"] = "Conversion exceeded 1200 seconds; process group terminated."
    record.update(returncode=process.returncode, elapsed_seconds=round(time.monotonic() - started, 3))
    for name, content in [("stdout", stdout), ("stderr", stderr)]:
        path = directory / f"{extension}-{name}.log"
        path.write_text(content, encoding="utf-8")
        record[name] = str(path)
    try:
        events = [json.loads(line) for line in stdout.splitlines() if line.strip()]
        record["events"] = events
        if process.returncode != 0:
            detail = next((event["message"] for event in events if event["event"] == "error"), stderr[-4000:])
            raise RuntimeError(detail)
        if not events or events[-1]["event"] != "complete" or events[-1]["partial"]:
            raise RuntimeError("Conversion did not report complete, non-partial success.")
        if extension == "native-pdf" and events[-1]["pages"] != 2:
            raise AssertionError("Expected both pages of the native PDF.")
        markdown = (output / "document.md").read_text(encoding="utf-8")
        normalized = "".join(markdown.split()).casefold()
        missing = [text for text in expected if "".join(text.split()).casefold() not in normalized]
        record["markdown_text_verified"] = not missing
        if missing:
            raise AssertionError(f"Markdown is missing expected text: {missing}")
        exports = [output / f"document.{suffix}" for suffix in ("md", "html", "json")]
        record["exports"] = [fingerprint(path) for path in exports]
        if any(item["bytes"] == 0 for item in record["exports"]):
            raise AssertionError("An export is empty.")
        doc = json.loads(exports[2].read_text(encoding="utf-8"))
        if doc.get("schema_name") != "DoclingDocument":
            raise AssertionError("JSON export does not contain a DoclingDocument.")
        record["status"] = "passed"
    except Exception as error:
        record.update(status="failed", error=str(error))
    print(f"{extension}: {record['status']} ({record['elapsed_seconds']} s)", flush=True)
    if record["status"] == "failed":
        print(record["error"], flush=True)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--formats", nargs="+", choices=["docx", "pptx", "xlsx", "png", "pdf", "native-pdf"],
                        default=["docx", "pptx", "xlsx", "png", "pdf", "native-pdf"])
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    directory = ROOT / ".build/acceptance-fixtures" / stamp
    directory.mkdir(parents=True)
    receipt_path = ROOT / ".build/engine-acceptance.json"
    receipt = {
        "started_at": stamp, "python": sys.executable, "platform": platform.platform(),
        "versions": {name: version(name) for name in ["docling-slim", "docling-core", "python-docx", "python-pptx", "openpyxl", "Pillow"]},
        "model_home": str(MODEL_HOME), "hf_hub_offline": os.environ.get("HF_HUB_OFFLINE") == "1",
        "fixtures": str(directory), "results": [], "status": "running",
    }
    try:
        make_fixtures(directory, args.formats)
        for extension in args.formats:
            receipt["results"].append(verify_one(extension, directory))
            save_receipt(receipt, directory, receipt_path)
            if receipt["results"][-1]["status"] == "failed":
                break
        receipt["status"] = "passed" if len(receipt["results"]) == len(args.formats) and all(
            result["status"] == "passed" for result in receipt["results"]) else "failed"
    except Exception as error:
        receipt.update(status="failed", error=str(error))
        print(f"Acceptance failed: {error}", flush=True)
    finally:
        receipt["finished_at"] = datetime.now(timezone.utc).isoformat()
        save_receipt(receipt, directory, receipt_path)
    print(f"Evidence: {receipt_path}", flush=True)
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
