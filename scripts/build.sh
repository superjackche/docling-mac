#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/dist/Docling Mac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Backend"
cp .build/release/DoclingMac "$app/Contents/MacOS/DoclingMac"
cp Backend/worker.py Backend/pyproject.toml Backend/uv.lock "$app/Contents/Resources/Backend/"
cp Info.plist "$app/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
