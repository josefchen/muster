#!/bin/sh
# Screenshot every step of the welcome tour from demo mode, in dark and light.
#
#   scripts/tour.sh [out-dir]
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/build/tour}"
APP="$HERE/build/MusterTour.app"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14 -o "$APP/Contents/MacOS/Muster" "$HERE"/Sources/*.swift
cp "$HERE/Resources/Info.plist" "$APP/Contents/"
cp "$HERE/Resources/AppIcon.icns" "$HERE/Resources/intro.mp4" "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1

rect() {
  swift -e '
import CoreGraphics
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in info where (w[kCGWindowName as String] as? String) == "Welcome to Muster" {
  let b = w[kCGWindowBounds as String] as! [String: Double]
  print("\(Int(b["X"]!)),\(Int(b["Y"]!)),\(Int(b["Width"]!)),\(Int(b["Height"]!))")
  break
}'
}

for look in dark light; do
  flag=""; [ "$look" = light ] && flag="--light"
  "$APP/Contents/MacOS/Muster" --demo --backdrop $flag --welcome -launched NO >/dev/null 2>&1 &
  pid=$!
  sleep 2.5
  for step in 1 2 3 4 5; do
    screencapture -x -R "$(rect)" "$OUT/$step-$look.png"
    [ "$step" -lt 5 ] && osascript -e 'tell application "System Events" to key code 36' && sleep 0.9
  done
  kill "$pid"
  wait "$pid" 2>/dev/null || true
done
echo "$OUT"
