#!/bin/sh
# Build Muster.dmg around an app: a 660 × 400 window that shows where to drag it.
#
#   scripts/dmg.sh build/Muster.app build/Muster.dmg
#
# The background comes from Resources/dmg/background.html, rendered at 1× and 2× with
# Chrome. dmgbuild lives in its own environment under ~/Library/Caches/muster-build.
set -eu
APP="${1:?usage: scripts/dmg.sh <app> <dmg>}"
DMG="${2:?usage: scripts/dmg.sh <app> <dmg>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
VENV="$HOME/Library/Caches/muster-build/venv"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q 'dmgbuild>=1.6,<2'
fi

for scale in 1 2; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=$scale --window-size=660,400 \
    --screenshot="$WORK/bg-$scale.png" "file://$HERE/Resources/dmg/background.html" >/dev/null 2>&1
done
tiffutil -cathidpicheck "$WORK/bg-1.png" "$WORK/bg-2.png" -out "$WORK/background.tiff" >/dev/null

rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$HERE/scripts/dmg-settings.py" -D app="$APP" -D background="$WORK/background.tiff" \
  -D volume_icon="$HERE/Resources/AppIcon.icns" "Muster" "$DMG" >/dev/null
echo "built $DMG"
