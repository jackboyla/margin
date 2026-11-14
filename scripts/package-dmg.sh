#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_DIR="$PWD/dist/Margin.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
VERSION="${MARGIN_VERSION:-$APP_VERSION}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] || [ "${VERSION%%-*}" != "$APP_VERSION" ]; then
    echo "MARGIN_VERSION must match the app built by scripts/build-app.sh" >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$APP_DIR"
STAGING="$(mktemp -d "$PWD/dist/dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_DIR" "$STAGING/Margin.app"
ln -s /Applications "$STAGING/Applications"
DMG="$PWD/dist/Margin-$VERSION-macOS.dmg"
hdiutil create -volname Margin -srcfolder "$STAGING" -format UDZO -ov "$DMG"
if [ "${MARGIN_DISTRIBUTION_SIGNING:-0}" = 1 ]; then
    SIGNING_ARGS=(--force --sign "${CODE_SIGN_IDENTITY:?Distribution signing needs CODE_SIGN_IDENTITY}" --timestamp)
    if [ -n "${CODE_SIGN_KEYCHAIN:-}" ]; then
        SIGNING_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN")
    fi
    codesign "${SIGNING_ARGS[@]}" "$DMG"
fi
if [ -n "${NOTARY_APPLE_ID:-}${NOTARY_TEAM_ID:-}${NOTARY_PASSWORD:-}" ]; then
    if [ "${MARGIN_DISTRIBUTION_SIGNING:-0}" != 1 ]; then
        echo "Notarization requires MARGIN_DISTRIBUTION_SIGNING=1 and a Developer ID certificate" >&2
        exit 1
    fi
    xcrun notarytool submit "$DMG" --wait \
        --apple-id "${NOTARY_APPLE_ID:?Missing NOTARY_APPLE_ID}" \
        --team-id "${NOTARY_TEAM_ID:?Missing NOTARY_TEAM_ID}" \
        --password "${NOTARY_PASSWORD:?Missing NOTARY_PASSWORD}"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
hdiutil verify "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
