#!/bin/sh
# Build a universal, signed and notarized Muster.dmg and Muster.zip in build/.
#
#   scripts/release.sh 1.0.1
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode → Settings → Accounts → Manage Certificates → +).
#   2. Notarization credentials saved as the "muster" profile:
#      xcrun notarytool store-credentials muster --apple-id you@example.com --team-id TEAMID
#      (it asks for an app-specific password from appleid.apple.com).
set -eu
VERSION="${1:?usage: scripts/release.sh <version>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/build"
APP="$OUT/Muster.app"
PROFILE="${NOTARY_PROFILE:-muster}"

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [ -z "$IDENTITY" ] && [ -z "${ADHOC:-}" ]; then
  echo "No Developer ID Application certificate found. See the setup notes at the top of this script," >&2
  echo "or run with ADHOC=1 for an unsigned build that Gatekeeper will warn about." >&2
  exit 1
fi
if [ -n "$IDENTITY" ] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarization credentials in the \"$PROFILE\" keychain profile. See the setup notes at the top of this script." >&2
  exit 1
fi

rm -rf "$OUT" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14" -o "$OUT/Muster-$arch" "$HERE"/Sources/*.swift
done
lipo -create "$OUT/Muster-arm64" "$OUT/Muster-x86_64" -output "$APP/Contents/MacOS/Muster"
rm "$OUT"/Muster-arm64 "$OUT"/Muster-x86_64
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/Resources/AppIcon.icns" "$HERE/Resources/intro.mp4" "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C "$HERE" rev-list --count HEAD)" "$APP/Contents/Info.plist"

if [ -n "${ADHOC:-}" ] && [ -z "$IDENTITY" ]; then
  codesign --force --sign - "$APP"
  ditto -c -k --keepParent "$APP" "$OUT/Muster.zip"
  echo "Built unsigned $OUT/Muster.zip ($VERSION). Gatekeeper will warn on other Macs."
  exit 0
fi

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip"
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$OUT/Muster.zip"

STAGE="$OUT/dmg"
mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Muster" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/Muster.dmg" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$OUT/Muster.dmg"
notarize "$OUT/Muster.dmg"
xcrun stapler staple "$OUT/Muster.dmg"
spctl --assess --type open --context context:primary-signature -v "$OUT/Muster.dmg"

echo "Built $OUT/Muster.dmg and $OUT/Muster.zip ($VERSION)"
