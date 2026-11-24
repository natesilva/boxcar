#!/usr/bin/env bash
set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-boxcar-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"

cd "$ROOT"
VERSION="$(xcodebuild -project Boxcar.xcodeproj -scheme Boxcar -showBuildSettings 2>/dev/null \
    | awk '/ MARKETING_VERSION = / { print $3; exit }')"
ZIP="$BUILD/Boxcar-$VERSION.zip"

rm -rf "$BUILD"
mkdir -p "$BUILD"

xcodebuild archive \
    -project Boxcar.xcodeproj \
    -scheme Boxcar \
    -configuration Release \
    -archivePath "$BUILD/Boxcar.xcarchive"

xcodebuild -exportArchive \
    -archivePath "$BUILD/Boxcar.xcarchive" \
    -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" \
    -exportPath "$BUILD/export"

ditto -c -k --keepParent "$BUILD/export/Boxcar.app" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$BUILD/export/Boxcar.app"
xcrun stapler validate "$BUILD/export/Boxcar.app"
spctl --assess --type execute --verbose "$BUILD/export/Boxcar.app"

ditto -c -k --keepParent "$BUILD/export/Boxcar.app" "$ZIP"
echo "$ZIP"
