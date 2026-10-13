"""Explicit model preparation, offline verification, and read-only update checks."""

import argparse
import contextlib
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import traceback
from urllib.request import Request, urlopen

from worker import configuration, emit, make_converter


BACKEND = Path(__file__).resolve().parent
PYPI_URL = "https://pypi.org/pypi/docling-slim/json"


def configure_threads():
    threads = str(configuration()["cpu_threads"])
    for name in ("DOCLING_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS"):
        os.environ[name] = threads


def snapshot_record(path):
    path = Path(path)
    repository = path.parent.parent.name
    if (path.parent.name != "snapshots" or not repository.startswith("models--")
            or re.fullmatch(r"[0-9a-f]{40,64}", path.name) is None):
        raise ValueError(f"无法识别模型缓存快照：{path}")
    return {"repo": repository.removeprefix("models--").replace("--", "/", 1),
            "snapshot": path.name}


def required_snapshots():
    # These two helpers use the existing HF_HOME cache when local_dir is None.
    with contextlib.redirect_stdout(sys.stderr):
        from docling.datamodel.base_models import InputFormat
        from docling.models.stages.table_structure.table_structure_model import TableStructureModel
        from docling.models.utils.hf_model_download import download_hf_model

        converter = make_converter(True)
        options = converter.format_to_options[InputFormat.PDF].pipeline_options
        layout = options.layout_options
        engine = layout.engine_options.engine_type
        layout_path = download_hf_model(
            repo_id=layout.model_spec.get_repo_id(engine),
            revision=layout.model_spec.get_revision(engine),
            local_dir=None, force=False, progress=True,
        )
        snapshots = [snapshot_record(layout_path)]
        if options.do_table_structure:
            snapshots.append(snapshot_record(TableStructureModel.download_models(
                local_dir=None, force=False, progress=True,
            )))
    return sorted(snapshots, key=lambda item: item["repo"])


def verify():
    emit("status", message="正在离线加载模型，验证本地引擎…")
    snapshots = required_snapshots()
    with contextlib.redirect_stdout(sys.stderr):
        from docling.datamodel.base_models import InputFormat
        make_converter(True).initialize_pipeline(InputFormat.PDF)
    state = {"engine_lock": hashlib.sha256((BACKEND / "uv.lock").read_bytes()).hexdigest(),
             "models": snapshots}
    emit("models_verified", state=state)
    return state


def verify_in_subprocess():
    # Keep this child in our process group so cancelling preparation stops both.
    result = subprocess.run(
        [sys.executable, str(BACKEND / "models.py"), "--verify"],
        env={**os.environ, "HF_HUB_OFFLINE": "1"},
        capture_output=True, text=True,
    )
    sys.stderr.write(result.stderr)
    if result.returncode != 0:
        raise RuntimeError("模型离线加载失败，请查看运行日志。")
    events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    verified = next((event for event in events if event["event"] == "models_verified"), None)
    if verified is None:
        raise RuntimeError("模型验证进程没有返回完整结果。")
    return verified["state"]


def write_state(destination, state):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=destination.parent,
                                         prefix=f".{destination.name}.", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(state, stream, ensure_ascii=False, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def prepare(destination):
    emit("status", message="正在准备版式与表格模型，首次下载需要一些时间…")
    required_snapshots()
    emit("status", message="模型已缓存，正在启动独立离线验证…")
    state = verify_in_subprocess()
    write_state(destination, state)
    emit("models_ready", state=state)


def updates():
    from packaging.version import Version

    current = Version(version("docling-slim"))
    request = Request(PYPI_URL, headers={"Accept": "application/json", "User-Agent": "Docling-Mac"})
    with urlopen(request, timeout=15) as response:
        info = json.load(response)["info"]
    latest = Version(info["version"])
    emit("update", current=str(current), latest=str(latest),
         url=f"https://pypi.org/project/docling-slim/{latest}/",
         available=latest > current and not latest.is_prerelease and not info.get("yanked", False))


def main():
    parser = argparse.ArgumentParser()
    command = parser.add_mutually_exclusive_group(required=True)
    command.add_argument("--prepare", action="store_true")
    command.add_argument("--verify", action="store_true")
    command.add_argument("--updates", action="store_true")
    parser.add_argument("--state", type=Path)
    args = parser.parse_args()
    if args.prepare and args.state is None:
        parser.error("--prepare requires --state PATH")
    if args.prepare and os.getpgrp() != os.getpid():
        os.setsid()
    if args.verify:
        # The Hub reads its environment at import time.
        os.environ["HF_HUB_OFFLINE"] = "1"
    try:
        configure_threads()
        if args.prepare:
            prepare(args.state)
        elif args.verify:
            verify()
        else:
            updates()
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit("error", message=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
