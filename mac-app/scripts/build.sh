#!/bin/bash
# Builds "Dungeons II Fixer.app" (Apple Silicon + Intel) and a DMG into dist/.
#
#   VERSION=1.0.0 BUILD_NUMBER=1 scripts/build.sh
#
# Optional, for a download that opens without Gatekeeper warnings:
#   SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE    a keychain profile made with `xcrun notarytool store-credentials`
#     or NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD (an app-specific password)
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname)" == Darwin ]] || { echo "error: build on macOS." >&2; exit 1; }

APP_NAME="Dungeons II Fixer"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/DungeonsIIFixer-$VERSION.dmg"
WORK=".build/package"

echo "==> Compiling"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$DIST" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"
cp "$BIN_DIR/DungeonsFixer" "$APP/Contents/MacOS/DungeonsFixer"
# The DLL comes from this repository's src/ folder, so the app always ships the current build.
DLL="../src/xgameruntime.dll"
[[ -f "$DLL" ]] || { echo "error: $DLL is missing. Build the DLL first (see the main README)." >&2; exit 1; }
cp "$DLL" "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
# Recorded so the app can check its copy of the DLL is intact before installing it.
plutil -insert XGameRuntimeSHA256 -string "$(shasum -a 256 "$DLL" | cut -d' ' -f1)" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

swift scripts/make-icon.swift Resources/AppIcon.webp "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    # Ad-hoc: runs on this Mac; downloads need right-click > Open or Privacy & Security > Open Anyway.
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "==> Making $DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [[ -n "${SIGN_IDENTITY:-}" && ( -n "${NOTARY_PROFILE:-}" || -n "${NOTARY_APPLE_ID:-}" ) ]]; then
    echo "==> Notarizing"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
            --password "$NOTARY_PASSWORD" --wait
    fi
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
fi

echo "Built $APP and $DMG"
