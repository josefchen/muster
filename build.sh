#!/bin/sh
# Build Muster.app into ~/Applications and (re)launch it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HOME/Applications/Muster.app}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14" -o "$APP/Contents/MacOS/Muster" "$HERE"/Sources/*.swift
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/Resources/AppIcon.icns" "$HERE/Resources/intro.mp4" "$HERE/CHANGELOG.md" "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

pkill -x Muster 2>/dev/null || true
while pgrep -x Muster >/dev/null; do sleep 0.1; done
open "$APP"
echo "built and launched $APP"
