#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v uv >/dev/null
engine_support="$HOME/Library/Application Support/Docling Mac"
mkdir -p "$engine_support"
# A failed sync must not leave an older environment marked ready.
rm -f "$engine_support/engine.lock"
UV_PROJECT_ENVIRONMENT="$engine_support/runtime" uv sync --project Backend --locked --no-dev --python 3.12
lock_digest="$(shasum -a 256 Backend/uv.lock)"
printf '%s' "${lock_digest%% *}" > "$engine_support/engine.lock"
printf '%s\n' "Engine ready: $engine_support/runtime"
