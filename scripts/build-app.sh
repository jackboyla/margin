#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${MARGIN_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]]; then
    echo "MARGIN_VERSION must be a version such as 0.1.0 or 0.1.0-beta.1" >&2
    exit 1
fi
APP_DIR="$PWD/dist/Margin.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
if [ "${MARGIN_UNIVERSAL:-0}" = 1 ]; then
    BINARIES=()
    for ARCH in arm64 x86_64; do
        swift build -c release --arch "$ARCH" "$@"
        BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path "$@")"
        BINARIES+=("$BIN_DIR/Margin")
    done
    lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/Margin"
    lipo "$APP_DIR/Contents/MacOS/Margin" -verify_arch arm64 x86_64
else
    swift build -c release "$@"
    BIN_DIR="$(swift build -c release --show-bin-path "$@")"
    cp "$BIN_DIR/Margin" "$APP_DIR/Contents/MacOS/Margin"
fi
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION%%-*}" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Resources"
ICONSET="$PWD/.build/Margin.iconset"
swift scripts/generate-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/Margin.icns"
SIGNING_ARGS=(--force --sign "${CODE_SIGN_IDENTITY:--}")
if [ -n "${CODE_SIGN_KEYCHAIN:-}" ]; then
    SIGNING_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN")
fi
if [ "${MARGIN_DISTRIBUTION_SIGNING:-0}" = 1 ]; then
    SIGNING_ARGS+=(--options runtime --timestamp --entitlements Resources/Margin.entitlements)
fi
codesign "${SIGNING_ARGS[@]}" --identifier com.jackboylan.margin "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
