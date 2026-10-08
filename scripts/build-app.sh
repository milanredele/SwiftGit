#!/bin/bash
# Builds SwiftGit and wraps the binary into build/SwiftGit.app
#
# Usage: scripts/build-app.sh [release|debug]
# Environment:
#   VERSION=1.2.3      sets CFBundleShortVersionString (default: from Info.plist)
#   BUILD_NUMBER=42    sets CFBundleVersion
#   UNIVERSAL=1        builds an arm64 + x86_64 universal binary (needs Xcode)
#   CODESIGN_IDENTITY  signing identity (default: ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

ARCH_ARGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

APP="build/SwiftGit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SwiftGit" "$APP/Contents/MacOS/SwiftGit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Grammar query files (tree-sitter highlights.scm) ship as SwiftPM resource bundles.
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

PLIST="$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

if [ "$CONFIG" = "release" ]; then
    strip -x "$APP/Contents/MacOS/SwiftGit" 2>/dev/null || true
fi
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP" >/dev/null 2>&1 || true
echo "Built $APP ($(du -sh "$APP" | cut -f1)) $(lipo -archs "$APP/Contents/MacOS/SwiftGit" 2>/dev/null || true)"
