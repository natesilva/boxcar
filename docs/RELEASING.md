# Releasing Boxcar

`scripts/release.sh` performs every step below. This runbook lists the same steps for manual use.

## Prerequisites

- Developer ID signing identity for team `K3E5T8BDA7` in the login Keychain.
- A `notarytool` Keychain profile named `boxcar-notary`. Check with `xcrun notarytool history --keychain-profile boxcar-notary`.
- The Sparkle EdDSA private key in the login Keychain. The public key is `SUPublicEDKey` in `Boxcar/Info.plist`. Keep an offline backup. If the private key is lost, installed apps cannot accept further updates.
- `gh` authenticated for `natesilva/boxcar` (`gh auth status`).
- Push access to the Homebrew tap repository `natesilva/homebrew-tap` over SSH.
- The Sparkle tools. Xcode downloads them with the Sparkle package. Find `generate_appcast` with:

  ```sh
  find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' -print -quit
  ```

- GitHub Pages enabled for the repository: branch `gh-pages`, folder `/ (root)`. The branch exists after the first release.

## Update feed

- Feed URL: `https://natesilva.github.io/boxcar/appcast.xml` (`SUFeedURL` in `Boxcar/Info.plist`).
- The feed file is `appcast.xml` on the `gh-pages` branch.
- Release archives are GitHub release assets. Each appcast entry points to `https://github.com/natesilva/boxcar/releases/download/v<version>/Boxcar-<version>.zip`.

## Steps

1. Raise `CURRENT_PROJECT_VERSION` (Sparkle compares this number, and it must increase on every release). Set `MARKETING_VERSION` to the new version. Both are build settings of the Boxcar target.
2. Commit and push to `main`. The release tag is created on the remote default branch.
3. Run `scripts/release.sh`. To run the steps by hand, continue with steps 4 to 12.
4. Set variables:

   ```sh
   VERSION=1.2
   REPO=natesilva/boxcar
   BUILD=build
   ```

5. Archive and export:

   ```sh
   rm -rf "$BUILD" && mkdir -p "$BUILD"
   xcodebuild archive -project Boxcar.xcodeproj -scheme Boxcar -configuration Release -archivePath "$BUILD/Boxcar.xcarchive"
   xcodebuild -exportArchive -archivePath "$BUILD/Boxcar.xcarchive" -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$BUILD/export"
   ```

6. Notarize and staple:

   ```sh
   ditto -c -k --keepParent "$BUILD/export/Boxcar.app" "$BUILD/notarize.zip"
   xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile boxcar-notary --wait
   xcrun stapler staple "$BUILD/export/Boxcar.app"
   xcrun stapler validate "$BUILD/export/Boxcar.app"
   spctl --assess --type execute --verbose "$BUILD/export/Boxcar.app"
   ```

7. Create the release archive:

   ```sh
   ditto -c -k --keepParent "$BUILD/export/Boxcar.app" "$BUILD/Boxcar-$VERSION.zip"
   ```

8. Clone the feed branch. If `gh-pages` does not exist yet, create it with `git init`, `git checkout --orphan gh-pages`, and `git remote add origin git@github.com:$REPO.git`.

   ```sh
   git clone --branch gh-pages --single-branch git@github.com:$REPO.git "$BUILD/pages"
   ```

9. Generate the appcast. The tool signs the archive with the Keychain private key and keeps existing entries.

   ```sh
   mkdir -p "$BUILD/appcast"
   cp "$BUILD/Boxcar-$VERSION.zip" "$BUILD/appcast/"
   cp "$BUILD/pages/appcast.xml" "$BUILD/appcast/"   # skip on the first release
   "$GENERATE_APPCAST" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$BUILD/appcast"
   cp "$BUILD/appcast/appcast.xml" "$BUILD/pages/appcast.xml"
   ```

10. Publish the GitHub release. Do this before the feed, so the feed never points to a missing file.

    ```sh
    gh release create "v$VERSION" "$BUILD/Boxcar-$VERSION.zip" --repo "$REPO" --title "Boxcar $VERSION" --generate-notes
    ```

11. Publish the feed:

    ```sh
    git -C "$BUILD/pages" add appcast.xml
    git -C "$BUILD/pages" commit -m "chore(appcast): add $VERSION"
    git -C "$BUILD/pages" push --set-upstream origin gh-pages
    ```

12. Update the Homebrew cask in the tap `natesilva/homebrew-tap`. The cask file is `Casks/boxcar.rb`. Set `version` to the new version and `sha256` to the checksum of the release archive:

    ```sh
    SHA256="$(shasum -a 256 "$BUILD/Boxcar-$VERSION.zip" | awk '{ print $1 }')"
    git clone git@github.com:natesilva/homebrew-tap.git "$BUILD/tap"
    sed -i '' -E \
      -e "s/^( *version \").*(\")$/\1$VERSION\2/" \
      -e "s/^( *sha256 \").*(\")$/\1$SHA256\2/" \
      "$BUILD/tap/Casks/boxcar.rb"
    git -C "$BUILD/tap" commit -am "feat(cask): update boxcar to $VERSION"
    git -C "$BUILD/tap" push
    ```

## Verification

- `curl -s https://natesilva.github.io/boxcar/appcast.xml` returns the feed with an `<item>` for the new version. Pages can take a few minutes to deploy.
- The item has `sparkle:version` equal to `CURRENT_PROJECT_VERSION` and a `sparkle:edSignature` attribute.
- `brew update && brew audit --cask --online natesilva/tap/boxcar` reports no problems, and `brew info --cask natesilva/tap/boxcar` shows the new version.
- Install an older build that includes Sparkle, then choose "Check for Updates…" from the menu. The update dialog shows the new version.
