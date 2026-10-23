#!/bin/bash
# Builds dist/Mike.app, dist/Mike-<version>.zip and .dmg from app/. Apple Silicon only (the speech model runs on
# the Neural Engine).
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  sign for distribution with the hardened runtime
#                                                             (default: ad-hoc, which runs only on this Mac)
#   NOTARY_PROFILE=<name>   also notarize and staple, using credentials saved with `xcrun notarytool store-credentials`
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
IDENTITY=${SIGN_IDENTITY:--}

swift build -c release --arch arm64 --product Mike
swift build -c release --arch arm64 --product Listen
BIN=$(swift build -c release --arch arm64 --show-bin-path)

APP=dist/Mike.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Mike" "$BIN/Listen" "$APP/Contents/MacOS/"
cp -R "$BIN/Mike_MikeKit.bundle" "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Inside out: the Listen helper first, then the app, whose signature seals everything in Contents/Resources (the
# resource bundle is data, not code, and older SwiftPM builds it flat, which codesign rejects as a bundle). The hardened
# runtime (--options runtime) is what notarization requires; ad-hoc signatures skip it so the app runs locally.
RUNTIME=(); [ "$IDENTITY" != "-" ] && RUNTIME=(--options runtime --timestamp)
codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements Resources/Mike.entitlements "$APP/Contents/MacOS/Listen"
codesign --force --sign "$IDENTITY" ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements Resources/Mike.entitlements "$APP"
codesign --verify --strict --deep "$APP"

ZIP="dist/Mike-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    [ "$IDENTITY" = "-" ] && { echo "notarizing needs SIGN_IDENTITY set to a Developer ID" >&2; exit 1; }
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"  # re-zip so the download carries the stapled ticket
fi

# The DMG: the app beside an Applications link, nothing else (no background art; hdiutil ships with macOS).
DMG="dist/Mike-$VERSION.dmg"; STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"; hdiutil create -quiet -volname Mike -srcfolder "$STAGE" -format UDZO "$DMG"; rm -rf "$STAGE"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
echo "built $APP ($VERSION, build $BUILD, signed: $IDENTITY), $ZIP and $DMG"
