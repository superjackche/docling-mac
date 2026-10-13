"""Content-addressed local results. Never cache partial or failed conversions."""
import hashlib
import json
from pathlib import Path
import shutil
import time

FILES = ("document.md", "document.html", "document.json")


def fingerprint(source: Path):
    before = source.stat()
    digest = hashlib.sha256()
    with source.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    after = source.stat()
    revision = (before.st_size, before.st_mtime_ns)
    if revision != (after.st_size, after.st_mtime_ns):
        raise RuntimeError("文件正在被修改，请保存完成后重试。")
    return digest.hexdigest(), revision


class ResultCache:
    def __init__(self, root: Path, configuration: dict, protected=()):
        self.root = root
        self.configuration = configuration
        self.protected = {Path(path).name for path in protected}
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Only prune previous sessions before work begins; visible results stay pinned.
        self.prune()

    def key(self, content_hash, extension, ocr, models_identity=""):
        backend = Path(__file__).parent
        digest = hashlib.sha256()
        for name in ("uv.lock", "worker.py", "result_cache.py", "runtime.json"):
            digest.update((backend / name).read_bytes())
        digest.update(f"{content_hash}:{extension.lower()}:{ocr}".encode())
        digest.update(models_identity.encode())
        return digest.hexdigest()

    def lookup(self, key):
        path = self.root / key
        manifest = path / "result.json"
        if not manifest.exists():
            if path.exists():
                shutil.rmtree(path)
            return None
        try:
            record = json.loads(manifest.read_text(encoding="utf-8"))
            valid = all((path / name).stat().st_size == record["sizes"][name] for name in FILES)
        except (OSError, ValueError, KeyError):
            valid = False
        if not valid:
            # This is solely the app's regenerable cache, not a user's input/export.
            shutil.rmtree(path)
            return None
        manifest.touch()
        self.protected.add(key)
        return record

    def publish(self, staging, key, record):
        record = {**record, "sizes": {name: (staging / name).stat().st_size for name in FILES}}
        (staging / "result.json").write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        staging.rename(self.root / key)
        self.protected.add(key)

    def prune(self):
        entries = []
        for path in self.root.iterdir():
            if not path.is_dir() or path.is_symlink():
                continue
            if len(path.name) != 64 or any(c not in "0123456789abcdef" for c in path.name):
                continue
            manifest = path / "result.json"
            if not manifest.exists():
                if path.name not in self.protected:
                    shutil.rmtree(path)
                continue
            size = sum(f.stat().st_size for f in path.iterdir() if f.is_file())
            entries.append((manifest.stat().st_mtime, size, path))
        total = sum(size for _, size, _ in entries)
        cutoff = time.time() - self.configuration["cache_max_age_days"] * 86400
        for used, size, path in sorted(entries):
            if path.name in self.protected:
                continue
            if total > self.configuration["cache_max_bytes"] or used < cutoff:
                shutil.rmtree(path)
                total -= size
