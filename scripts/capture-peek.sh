#!/bin/sh
# A still of the alert unfolded with ⌥↓ on a multiple-choice question, from demo mode
# over its backdrop. Needs Screen Recording only. Writes peek-<theme>.jpg to the out folder.
#
#   scripts/capture-peek.sh [dark|light] [out-dir]
set -eu
THEME="${1:-dark}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$HERE/docs/media}"
APP="$HOME/Applications/Muster.app"
RAW="$(mktemp -d)/peek.png"
mkdir -p "$OUT"

quit() { pkill -x Muster 2>/dev/null || true; while pgrep -x Muster >/dev/null; do sleep 0.1; done; }
set -- $(swift -e 'import AppKit; let s = NSScreen.screens[0]; print(Int(s.frame.width), Int(s.frame.maxY - s.visibleFrame.maxY))')
W=$1 BAR=$2

quit
if [ "$THEME" = light ]; then open -n "$APP" --args --demo --backdrop --attention --question --peek --light
else open -n "$APP" --args --demo --backdrop --attention --question --peek; fi
sleep 3.5
# 640 × 250 points around the unfolded alert.
screencapture -x -R"$((W / 2 - 320)),$((BAR - 18)),640,250" "$RAW"
quit
open "$APP"
sips -s format jpeg -s formatOptions 88 "$RAW" --out "$OUT/peek-$THEME.jpg" >/dev/null
ls -la "$OUT/peek-$THEME.jpg"
