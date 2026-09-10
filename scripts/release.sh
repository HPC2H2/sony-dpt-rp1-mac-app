#!/usr/bin/env bash
#
# Build, sign, notarize, and staple a Developer ID release of Digital Paper.
#
# Prerequisites:
#   - A "Developer ID Application" certificate in your login keychain.
#   - A notarytool keychain profile created once with:
#       xcrun notarytool store-credentials dp-notary \
#         --apple-id "you@example.com" --team-id TEAMID --password APP_SPECIFIC_PW
#
# Usage:
#   DEVELOPMENT_TEAM=TEAMID SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#     scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-dp-notary}"
CONFIG=Release
DD=build/release
APP="$DD/Build/Products/$CONFIG/DigitalPaper.app"
DIST=dist

echo "==> Generating project"
xcodegen generate

echo "==> Building ($CONFIG)"
xcodebuild -project DigitalPaper.xcodeproj -scheme DigitalPaper \
  -configuration "$CONFIG" -derivedDataPath "$DD" \
  ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM} \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  build

echo "==> Signing (hardened runtime)"
codesign --force --options runtime --timestamp \
  --entitlements DigitalPaper/DigitalPaper.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"

echo "==> Packaging"
mkdir -p "$DIST"
ZIP="$DIST/DigitalPaper.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Notarizing"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vvv "$APP" || true
stapler validate "$APP"

echo "==> Done: $ZIP"
