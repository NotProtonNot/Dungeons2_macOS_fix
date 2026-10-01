#!/bin/bash
# Signs and notarizes a Dungeons II Fixer build downloaded from GitHub Actions.
# No compiler needed: it takes the newest DungeonsIIFixer-*.dmg (or .zip) in ~/Downloads
# and puts a notarized DMG on the Desktop.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/NotProtonNot/Dungeons2_macOS_fix/main/mac-app/scripts/notarize.sh)
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-dungeons-notary}"
APP_NAME="Dungeons II Fixer"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(uname)" == Darwin ]] || fail "Run this on your Mac."
xcrun --find notarytool >/dev/null 2>&1 || fail "Apple's command line tools are missing. Run: xcode-select --install"

step "Finding your signing certificate"
IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
[[ -n "$IDENTITY" ]] || fail "No 'Developer ID Application' certificate was found.
In Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application. Then run this again."
TEAM_ID="$(sed -E 's/.*\(([A-Z0-9]+)\)$/\1/' <<<"$IDENTITY")"
echo "$IDENTITY"

step "Finding the build you downloaded"
shopt -s nullglob
candidates=(~/Downloads/DungeonsIIFixer-*.dmg ~/Downloads/DungeonsIIFixer-*.zip)
[[ ${#candidates[@]} -gt 0 ]] || fail "No DungeonsIIFixer download was found in your Downloads folder. Download the latest build from GitHub first."
SRC="$(ls -t "${candidates[@]}" | head -1)"
echo "$SRC"

WORK="$(mktemp -d)"
MNT=""
cleanup() {
    [[ -n "$MNT" ]] && hdiutil detach "$MNT" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

DMG="$SRC"
if [[ "$SRC" == *.zip ]]; then
    ditto -x -k "$SRC" "$WORK/zip"
    DMG="$(find "$WORK/zip" -name 'DungeonsIIFixer-*.dmg' | head -1)"
    [[ -n "$DMG" ]] || fail "That zip doesn't contain the app's DMG."
fi
VERSION="$(basename "$DMG" .dmg)"
VERSION="${VERSION#DungeonsIIFixer-}"

MNT="$WORK/mnt"
mkdir -p "$MNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet
[[ -d "$MNT/$APP_NAME.app" ]] || fail "The DMG doesn't contain $APP_NAME.app."
APP="$WORK/$APP_NAME.app"
ditto "$MNT/$APP_NAME.app" "$APP"
hdiutil detach "$MNT" -quiet
MNT=""
xattr -cr "$APP"

step "Signing the app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

step "Making the DMG"
OUT="$HOME/Desktop/DungeonsIIFixer-$VERSION.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT" -quiet
codesign --force --timestamp --sign "$IDENTITY" "$OUT"

step "Sending it to Apple for notarization (usually a few minutes)"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "First time only: sign in for notarization."
    read -r -p "Apple ID email: " APPLE_ID </dev/tty
    echo "Next, enter an app-specific password (made at appleid.apple.com > Sign-In and Security)."
    xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID"
fi
RESULT="$(xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)"
if ! grep -q "status: Accepted" <<<"$RESULT"; then
    ID="$(grep -m1 -E '^\s*id:' <<<"$RESULT" | awk '{print $2}')"
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
    fail "Apple didn't accept the build. The details are above."
fi

step "Attaching Apple's approval"
xcrun stapler staple "$OUT"
spctl -a -t open --context context:primary-signature "$OUT"

printf '\n\033[32mDone! Your notarized app is on the Desktop: %s\033[0m\n' "$(basename "$OUT")"
open -R "$OUT"
