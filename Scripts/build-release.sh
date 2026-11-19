#!/bin/bash
# Builds the Mac app in Release, runs the built-in self-check, and leaves
# dist/FlatGrid.app plus dist/FlatGrid-mac-arm64.zip. Run from the project root.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project FlatGrid.xcodeproj -scheme FlatGrid -configuration Release \
  -derivedDataPath build/dd build | grep -E "error|warning: unre|BUILD" || true

rm -rf dist/FlatGrid.app
mkdir -p dist
ditto build/dd/Build/Products/Release/FlatGrid.app dist/FlatGrid.app

echo "Running self-check (opens a window for about 40 seconds)…"
dist/FlatGrid.app/Contents/MacOS/FlatGrid --verify | grep -v '^$' > dist/verify-output.txt
tail -2 dist/verify-output.txt

rm -f dist/FlatGrid-mac-arm64.zip
ditto -c -k --keepParent dist/FlatGrid.app dist/FlatGrid-mac-arm64.zip
shasum -a 256 dist/FlatGrid-mac-arm64.zip
