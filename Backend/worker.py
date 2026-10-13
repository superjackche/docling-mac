"""One local document per process; stdout is a JSON-lines event stream."""
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


def convert(source: Path, output: Path, ocr: bool):
    if not source.is_file():
        raise ValueError("找不到输入文件，或输入不是普通文件。")
    # Never accept URLs. Disable remote services and plugins explicitly.
    emit("status", message="正在加载本地解析引擎…")
    with contextlib.redirect_stdout(sys.stderr):
        from docling.datamodel.base_models import ConversionStatus, InputFormat
        from docling.datamodel.pipeline_options import OcrMacOptions, PdfPipelineOptions
        from docling.document_converter import DocumentConverter, PdfFormatOption, ImageFormatOption
        from docling_core.types.doc import ImageRefMode

        options = PdfPipelineOptions(
            do_ocr=ocr,
            do_table_structure=True,
            enable_remote_services=False,
            allow_external_plugins=False,
            generate_picture_images=True,
        )
        options.ocr_options = OcrMacOptions(lang=["zh-Hans", "zh-Hant", "en-US"])
        converter = DocumentConverter(
            allowed_formats=[InputFormat.PDF, InputFormat.IMAGE, InputFormat.DOCX,
                             InputFormat.PPTX, InputFormat.XLSX, InputFormat.HTML,
                             InputFormat.MD, InputFormat.CSV],
            format_options={
                InputFormat.PDF: PdfFormatOption(pipeline_options=options),
                InputFormat.IMAGE: ImageFormatOption(pipeline_options=options),
            },
        )
    emit("status", message="正在解析文档；首次处理 PDF 或图片时会下载模型…")
    with contextlib.redirect_stdout(sys.stderr):
        result = converter.convert(source, raises_on_error=False)
        if result.status not in (ConversionStatus.SUCCESS, ConversionStatus.PARTIAL_SUCCESS):
            detail = "; ".join(e.error_message for e in result.errors)
            raise RuntimeError(detail or f"转换失败：{result.status.value}")
        output.mkdir(parents=True, exist_ok=False)
        # Embedded images keep each export self-contained when moved elsewhere.
        result.document.save_as_markdown(output / "document.md", image_mode=ImageRefMode.EMBEDDED, traverse_pictures=True)
        export_html(result.document, output / "document.html")
        result.document.save_as_json(output / "document.json", image_mode=ImageRefMode.EMBEDDED)
    warnings = [e.error_message for e in result.errors]
    emit("complete", partial=result.status == ConversionStatus.PARTIAL_SUCCESS,
         warnings=warnings, pages=len(result.document.pages))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--ocr", action="store_true")
    args = parser.parse_args()
    # Let the app cancel this conversion and any model worker children together.
    if os.getpgrp() != os.getpid():
        os.setsid()
    try:
        convert(args.source, args.output, args.ocr)
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit("error", message=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
