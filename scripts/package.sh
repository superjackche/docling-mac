#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
app="$PWD/dist/Docling Mac.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
architecture="$(uname -m)"
package="Docling-Mac-$version-$architecture"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"
# Only this newly-created staging directory is removed on exit.
dmg_stage="$(mktemp -d "$PWD/.build/dmg.XXXXXX")"
trap 'rm -r "$dmg_stage"' EXIT
ditto --norsrc --noextattr "$app" "$dmg_stage/Docling Mac.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create -volname "Docling Mac" -srcfolder "$dmg_stage" -format UDZO -ov "$PWD/dist/$package.dmg"
hdiutil verify "$PWD/dist/$package.dmg"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$PWD/dist/$package.zip"
unzip -t "$PWD/dist/$package.zip"
(
  cd dist
  shasum -a 256 "$package.dmg" "$package.zip" > "$package-SHA256SUMS.txt"
)
printf '%s\n' "$PWD/dist/$package.dmg" "$PWD/dist/$package.zip" "$PWD/dist/$package-SHA256SUMS.txt"
