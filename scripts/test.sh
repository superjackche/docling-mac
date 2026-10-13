#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
mkdir -p .build/checks/Backend
cp Backend/worker.py Backend/pyproject.toml Backend/uv.lock .build/checks/Backend/
swiftc -parse-as-library Sources/DoclingMac/ProcessRunner.swift Sources/DoclingMac/AppModel.swift \
  Tests/DoclingMacTests/ClientTests.swift -o .build/checks/client-checks
.build/checks/client-checks
engine_python="$HOME/Library/Application Support/Docling Mac/runtime/bin/python3"
"$engine_python" -m unittest discover -s Tests -p 'test_*.py' -v
