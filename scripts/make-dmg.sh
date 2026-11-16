#!/bin/zsh
# Build Release and pack it into build/ImmichViewer-<version>.dmg with a drag-to-Applications window.
# Needs uv (brew install uv); uvx fetches dmgbuild on first run. Layout lives in dmg-settings.py.
set -euo pipefail
cd "${0:A:h}/.."

xcodebuild -project ImmichViewer.xcodeproj -scheme ImmichViewer -configuration Release -derivedDataPath build build | grep -E " error|BUILD"
app=build/Build/Products/Release/ImmichViewer.app
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
dmg=build/ImmichViewer-$version.dmg

# The .app inside is named with a space, so Finder and /Applications show "Immich Viewer"
rm -rf build/dmg "$dmg"
mkdir -p build/dmg
ditto "$app" "build/dmg/Immich Viewer.app"

uvx dmgbuild -s scripts/dmg-settings.py -D app="build/dmg/Immich Viewer.app" "Immich Viewer" "$dmg"

rm -rf build/dmg
echo "$dmg"
