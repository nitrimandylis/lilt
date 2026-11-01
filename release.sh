#!/bin/sh
# Builds a universal (Apple silicon + Intel) Lilt.app, ad-hoc signs it, and packs a DMG.
# Usage: ./release.sh 0.1.0
set -e
cd "$(dirname "$0")"
VERSION=${1:?usage: ./release.sh <version>}

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
APP=build/Lilt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Lilt" "$APP/Contents/MacOS/Lilt"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Lilt.icns THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"

# Ad-hoc signature: free, no Apple account. Without it a downloaded copy says "damaged".
codesign --force --deep --sign - "$APP"

# A DMG with the app and a shortcut to Applications to drag it into.
STAGE=build/dmg
rm -rf "$STAGE" "build/Lilt-$VERSION.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Lilt $VERSION" -srcfolder "$STAGE" -format UDZO "build/Lilt-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "built build/Lilt-$VERSION.dmg"
