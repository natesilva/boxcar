#!/usr/bin/env bash
set -euo pipefail

NOTARY_PROFILE="${NOTARY_PROFILE:-boxcar-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"

cd "$ROOT"
VERSION="$(xcodebuild -project Boxcar.xcodeproj -scheme Boxcar -showBuildSettings 2>/dev/null \
    | awk '/ MARKETING_VERSION = / { print $3; exit }')"
ZIP="$BUILD/Boxcar-$VERSION.zip"
REPO="${REPO:-natesilva/boxcar}"
TAG="v$VERSION"
PAGES="$BUILD/pages"
TAP_REPO="${TAP_REPO:-natesilva/homebrew-tap}"
TAP="$BUILD/tap"
APPCAST_STAGING="$BUILD/appcast"
GENERATE_APPCAST="${GENERATE_APPCAST:-$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' -print -quit 2>/dev/null)}"

if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" ]]; then
    echo "generate_appcast not found. Build the project in Xcode once, or set GENERATE_APPCAST." >&2
    exit 1
fi

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

if git clone --quiet --branch gh-pages --single-branch "git@github.com:$REPO.git" "$PAGES" 2>/dev/null; then
    :
else
    git init --quiet "$PAGES"
    git -C "$PAGES" checkout --quiet --orphan gh-pages
    git -C "$PAGES" remote add origin "git@github.com:$REPO.git"
fi

mkdir -p "$APPCAST_STAGING"
cp "$ZIP" "$APPCAST_STAGING/"
if [[ -f "$PAGES/appcast.xml" ]]; then
    cp "$PAGES/appcast.xml" "$APPCAST_STAGING/"
fi
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    "$APPCAST_STAGING"
cp "$APPCAST_STAGING/appcast.xml" "$PAGES/appcast.xml"

gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Boxcar $VERSION" --generate-notes

git -C "$PAGES" add appcast.xml
git -C "$PAGES" commit --quiet -m "chore(appcast): add $VERSION"
git -C "$PAGES" push --quiet --set-upstream origin gh-pages

SHA256="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
git clone --quiet "git@github.com:$TAP_REPO.git" "$TAP"
sed -i '' -E \
    -e "s/^( *version \").*(\")$/\1$VERSION\2/" \
    -e "s/^( *sha256 \").*(\")$/\1$SHA256\2/" \
    "$TAP/Casks/boxcar.rb"
git -C "$TAP" commit --quiet -am "feat(cask): update boxcar to $VERSION"
git -C "$TAP" push --quiet

echo "Released $TAG: $ZIP"
