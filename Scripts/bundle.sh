#!/bin/bash
# Builds DiscoBreak.app from the SwiftPM binary.
# Usage: ./Scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/DiscoBreak"
APP="$ROOT/build/DiscoBreak.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/DiscoBreak"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Copy any non-plist resources (audio loop, icon) alongside the binary.
shopt -s nullglob
for f in "$ROOT"/Resources/*; do
  [[ "$(basename "$f")" == "Info.plist" ]] && continue
  cp -R "$f" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Ad-hoc signature: enough to run locally. Real signing happens at ship time.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
