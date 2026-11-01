#!/bin/sh
# Builds Lilt and wraps the binary in a .app bundle (menu bar apps need one for Info.plist).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Lilt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Lilt "$APP/Contents/MacOS/Lilt"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/Lilt.icns "$APP/Contents/Resources/"  # redraw with tools/icon.swift
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"  # MIT requires the notice to travel with the app
codesign --force --sign - "$APP"
echo "built $APP"
