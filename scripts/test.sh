#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
mkdir -p .build/checks/Backend
cp Backend/worker.py Backend/result_cache.py Backend/models.py Backend/runtime.json Backend/pyproject.toml Backend/uv.lock .build/checks/Backend/
swiftc -parse-as-library Sources/DoclingMac/ProcessRunner.swift Sources/DoclingMac/FileOperations.swift Sources/DoclingMac/AppModel.swift \
  Tests/DoclingMacTests/ClientTests.swift -o .build/checks/client-checks
.build/checks/client-checks
swiftc -parse-as-library Sources/DoclingMac/ProcessRunner.swift Sources/DoclingMac/FileOperations.swift Sources/DoclingMac/AppModel.swift \
  Tests/MetadataChecks.swift -o .build/checks/metadata-checks
.build/checks/metadata-checks
swiftc -parse-as-library Sources/DoclingMac/FileDropWebView.swift Tests/DropChecks.swift -o .build/checks/drop-checks
.build/checks/drop-checks
swiftc -parse-as-library Sources/DoclingMac/ProcessRunner.swift Sources/DoclingMac/FileOperations.swift Sources/DoclingMac/AppModel.swift \
  Tests/QueueFlowChecks.swift -o .build/checks/queue-flow-checks
.build/checks/queue-flow-checks
swiftc -parse-as-library Sources/DoclingMac/ProcessRunner.swift Sources/DoclingMac/FileOperations.swift Sources/DoclingMac/AppModel.swift \
  Tests/StorageChecks.swift -o .build/checks/storage-checks
.build/checks/storage-checks
engine_python="$HOME/Library/Application Support/Docling Mac/runtime/bin/python3"
"$engine_python" -m unittest discover -s Tests -p 'test_*.py' -v
