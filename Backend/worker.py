"""One batch per process, one reusable converter; stdout is JSON-lines events."""
import argparse
import contextlib
import html
import json
import os
from pathlib import Path
import sys
import traceback


def emit(event: str, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)


def export_html(document, destination: Path):
    from docling_core.transforms.serializer.html import HTMLDocSerializer, HTMLParams, HTMLTextSerializer
    from docling_core.types.doc import CodeItem, ImageRefMode

    class LiteralCodeSerializer(HTMLTextSerializer):
        def serialize(self, *, item, **kwargs):
            # Upstream inserts CodeItem.text verbatim; code examples must stay text.
            if isinstance(item, CodeItem):
                item = item.model_copy(update={"text": html.escape(item.text)})
            return super().serialize(item=item, **kwargs)

    policy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
    head = (
        '<head><meta charset="utf-8">'
        f'<meta http-equiv="Content-Security-Policy" content="{policy}">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<style>body{font:16px/1.7 system-ui;max-width:900px;margin:40px auto;padding:0 24px}'
        'table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:8px}'
        'img{max-width:100%;height:auto}pre{white-space:pre-wrap}</style>'
        '</head>'
    )
    rendered = HTMLDocSerializer(
        doc=document, text_serializer=LiteralCodeSerializer(),
        params=HTMLParams(image_mode=ImageRefMode.EMBEDDED, traverse_pictures=True, html_head=head),
    ).serialize().text
    destination.write_text(rendered, encoding="utf-8")


def configuration():
    return json.loads((Path(__file__).parent / "runtime.json").read_text())


def make_converter(ocr: bool):
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.accelerator_options import AcceleratorOptions
    from docling.datamodel.backend_options import ThreadedDoclingParseBackendOptions
    from docling.datamodel.pipeline_options import OcrMacOptions, PdfPipelineOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption, ImageFormatOption

    config = configuration()
    options = PdfPipelineOptions(
        do_ocr=ocr, do_table_structure=True, enable_remote_services=False,
        allow_external_plugins=False, generate_picture_images=True,
        accelerator_options=AcceleratorOptions(num_threads=config["cpu_threads"]),
        layout_batch_size=config["pipeline_batch_size"],
        table_batch_size=config["pipeline_batch_size"],
        ocr_batch_size=config["pipeline_batch_size"],
        queue_max_size=config["pipeline_queue_size"],
    )
    options.ocr_options = OcrMacOptions(lang=["zh-Hans", "zh-Hant", "en-US"])
    return DocumentConverter(
        allowed_formats=[InputFormat.PDF, InputFormat.IMAGE, InputFormat.DOCX,
                         InputFormat.PPTX, InputFormat.XLSX, InputFormat.HTML,
                         InputFormat.MD, InputFormat.CSV],
        format_options={
            InputFormat.PDF: PdfFormatOption(
                pipeline_options=options,
                backend_options=ThreadedDoclingParseBackendOptions(parser_threads=config["cpu_threads"])),
            InputFormat.IMAGE: ImageFormatOption(pipeline_options=options),
        },
    )


def convert(source: Path, output: Path, ocr: bool, converter=None, job_id=None, report=True):
    if not source.is_file():
        raise ValueError("找不到输入文件，或输入不是普通文件。")
    emit("status", id=job_id, message="正在解析文档…")
    with contextlib.redirect_stdout(sys.stderr):
        from docling.datamodel.base_models import ConversionStatus
        from docling_core.types.doc import ImageRefMode
        converter = converter if converter is not None else make_converter(ocr)
        result = converter.convert(source, raises_on_error=False)
        if result.status not in (ConversionStatus.SUCCESS, ConversionStatus.PARTIAL_SUCCESS):
            detail = "; ".join(e.error_message for e in result.errors)
            raise RuntimeError(detail or f"转换失败：{result.status.value}")
        output.mkdir(parents=True, exist_ok=False)
        result.document.save_as_markdown(output / "document.md", image_mode=ImageRefMode.EMBEDDED, traverse_pictures=True)
        export_html(result.document, output / "document.html")
        result.document.save_as_json(output / "document.json", image_mode=ImageRefMode.EMBEDDED)
    record = dict(partial=result.status == ConversionStatus.PARTIAL_SUCCESS,
                  warnings=[e.error_message for e in result.errors], pages=len(result.document.pages))
    if report:
        emit("complete", id=job_id, **record)
    return record


def run_batch(manifest_path: Path):
    import fcntl
    import time
    import uuid
    from result_cache import ResultCache, fingerprint

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    root = Path(manifest["cache"])
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / ".lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("另一个转换进程正在使用缓存，请等它结束。")
        cache = ResultCache(root, configuration(), manifest["protected"])
        converter = None
        for job in manifest["jobs"]:
            job_id = str(uuid.UUID(job["id"]))
            started = time.monotonic()
            emit("started", id=job_id, message="正在检查文件与缓存…")
            try:
                source = Path(job["source"])
                content_hash, revision = fingerprint(source)
                key = cache.key(content_hash, source.suffix, manifest["ocr"], manifest["models_identity"])
                record = cache.lookup(key)
                hit = record is not None
                destination = root / key
                if not hit:
                    if converter is None:
                        emit("status", id=job_id, message="正在加载解析模型，本批次只加载一次…")
                        with contextlib.redirect_stdout(sys.stderr):
                            converter = make_converter(manifest["ocr"])
                    destination = Path(manifest["output"]) / job_id
                    record = convert(source, destination, manifest["ocr"], converter, job_id, report=False)
                    after = source.stat()
                    if revision != (after.st_size, after.st_mtime_ns):
                        raise RuntimeError("转换期间输入文件发生变化，请保存完成后重新添加。")
                    if not record["partial"]:
                        cache.publish(destination, key, record)
                        destination = root / key
                emit("complete", id=job_id, **{k: v for k, v in record.items() if k != "sizes"},
                     cached=hit, output=str(destination), seconds=time.monotonic() - started)
            except Exception as error:
                traceback.print_exc(file=sys.stderr)
                emit("error", id=job_id, message=str(error))
        emit("batch_complete")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--ocr", action="store_true")
    parser.add_argument("--batch", type=Path)
    parser.add_argument("--prune-cache", type=Path)
    args = parser.parse_args()
    if os.getpgrp() != os.getpid():
        os.setsid()
    threads = str(configuration()["cpu_threads"])
    for name in ("DOCLING_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS"):
        os.environ[name] = threads
    try:
        if args.prune_cache:
            import fcntl
            from result_cache import ResultCache
            if args.prune_cache.exists():
                with (args.prune_cache / ".lock").open("w") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    ResultCache(args.prune_cache, configuration())
            emit("cache_pruned")
        elif args.batch:
            run_batch(args.batch)
        elif args.source is not None and args.output is not None:
            convert(args.source, args.output, args.ocr)
        else:
            parser.error("provide source and output, or --batch")
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit("error", message=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
