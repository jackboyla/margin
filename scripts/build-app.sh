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
        swift build -c release --arch "$ARCH" -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' "$@"
        BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path "$@")"
        BINARIES+=("$BIN_DIR/Margin")
    done
    lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/Margin"
    lipo "$APP_DIR/Contents/MacOS/Margin" -verify_arch arm64 x86_64
else
    swift build -c release -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' "$@"
    BIN_DIR="$(swift build -c release --show-bin-path "$@")"
    cp "$BIN_DIR/Margin" "$APP_DIR/Contents/MacOS/Margin"
fi
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION%%-*}" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Resources"
# SwiftPM emits flat privacy bundles; macOS resource bundles use Contents.
for MANIFEST in "$BIN_DIR"/*.bundle/PrivacyInfo.xcprivacy; do
    [ -f "$MANIFEST" ] || continue
    BUNDLE_NAME="$(basename "$(dirname "$MANIFEST")" .bundle)"
    RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/$BUNDLE_NAME.bundle"
    mkdir -p "$RESOURCE_BUNDLE/Contents/Resources"
    cp "$MANIFEST" "$RESOURCE_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleIdentifier string com.jackboylan.margin.resources.${BUNDLE_NAME//_/-}" \
        -c "Add :CFBundleName string $BUNDLE_NAME" \
        -c 'Add :CFBundlePackageType string BNDL' \
        -c 'Add :CFBundleVersion string 1' \
        "$RESOURCE_BUNDLE/Contents/Info.plist"
done
ICONSET="$PWD/.build/Margin.iconset"
swift scripts/generate-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/Margin.icns"
FRAMEWORKS="$APP_DIR/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
xcrun swift-stdlib-tool --copy --scan-executable "$APP_DIR/Contents/MacOS/Margin" \
    --platform macosx --destination "$FRAMEWORKS"
SIGNING_ARGS=(--force --sign "${CODE_SIGN_IDENTITY:--}")
if [ -n "${CODE_SIGN_KEYCHAIN:-}" ]; then
    SIGNING_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN")
fi
if [ "${MARGIN_DISTRIBUTION_SIGNING:-0}" = 1 ]; then
    SIGNING_ARGS+=(--options runtime --timestamp)
fi
read -ra ARCHITECTURES <<< "$(lipo -archs "$APP_DIR/Contents/MacOS/Margin")"
for LIBRARY in "$FRAMEWORKS"/*.dylib; do
    [ -f "$LIBRARY" ] || continue
    lipo "$LIBRARY" -verify_arch "${ARCHITECTURES[@]}"
    codesign "${SIGNING_ARGS[@]}" "$LIBRARY"
    codesign --verify --strict "$LIBRARY"
done
if [ "${MARGIN_DISTRIBUTION_SIGNING:-0}" = 1 ]; then
    SIGNING_ARGS+=(--entitlements Resources/Margin.entitlements)
fi
codesign "${SIGNING_ARGS[@]}" --identifier com.jackboylan.margin "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
