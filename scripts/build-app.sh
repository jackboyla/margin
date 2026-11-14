#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
BIN_DIR="$(swift build -c release --show-bin-path "$@")"
APP_DIR="$PWD/dist/Margin.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/Margin" "$APP_DIR/Contents/MacOS/Margin"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
SIGNING_ARGS=(--force --sign "${CODE_SIGN_IDENTITY:--}" --identifier com.jackboylan.margin)
if [ -n "${CODE_SIGN_KEYCHAIN:-}" ]; then
    SIGNING_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN")
fi
codesign "${SIGNING_ARGS[@]}" "$APP_DIR"
echo "$APP_DIR"
