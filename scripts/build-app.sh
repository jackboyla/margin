#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
BIN_DIR="$(swift build -c release --show-bin-path "$@")"
APP_DIR="$PWD/dist/Margin.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/Margin" "$APP_DIR/Contents/MacOS/Margin"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --identifier com.jackboylan.margin "$APP_DIR"
echo "$APP_DIR"
