#!/bin/bash
# Builds GitUI and wraps the binary into build/GitUI.app
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/GitUI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GitUI" "$APP/Contents/MacOS/GitUI"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ "$CONFIG" = "release" ]; then
    strip -x "$APP/Contents/MacOS/GitUI" 2>/dev/null || true
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
