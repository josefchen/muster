#!/bin/sh
# Record the switcher or the search scene, which Muster plays by itself in demo mode
# (Demo.swift), so this needs Screen Recording but not Accessibility. The app reports the
# area the scene uses, and the clip is cropped to it. Writes <scene>-<theme>.mp4 and .webm
# (site) and a poster .jpg, plus a .gif of the switcher (README), to the out folder.
#
#   scripts/record-scene.sh switcher|search [dark|light] [out-dir]
set -eu
SCENE="${1:?usage: scripts/record-scene.sh switcher|search [dark|light] [out-dir]}"
THEME="${2:-dark}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${3:-$HERE/docs/media}"
APP="$HOME/Applications/Muster.app"
TMP="$(mktemp -d)"
mkdir -p "$OUT"

quit() { pkill -x Muster 2>/dev/null || true; while pgrep -x Muster >/dev/null; do sleep 0.1; done; }
SCALE=$(swift -e 'import AppKit; print(Int(NSScreen.screens[0].backingScaleFactor))')
case "$SCENE" in
  switcher) LEN=10.4 POSTER=3.6 ;;
  search) LEN=6.8 POSTER=4.5 ;;
  *) echo "no scene called $SCENE" >&2; exit 1 ;;
esac

quit
LIGHT=""; [ "$THEME" = light ] && LIGHT=--light
"$APP/Contents/MacOS/Muster" --demo --backdrop --autoplay "$SCENE" $LIGHT > "$TMP/scene.txt" 2>/dev/null &
PID=$!
sleep 0.5
# ffmpeg rather than screencapture -v, which can keep recording past its time limit once the
# search panel takes the keyboard. The hardware encoder keeps up with a Retina screen.
ffmpeg -v error -y -f avfoundation -capture_cursor 0 -framerate 30 -pixel_format bgr0 -i "Capture screen 0:none" \
  -t 12 -c:v h264_videotoolbox -b:v 60M "$TMP/raw.mov" 2>/dev/null
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
open "$APP"

# The scene's area in points from the top left, with a margin of backdrop around it.
set -- $(grep '^scene ' "$TMP/scene.txt" | tail -1)
[ $# -eq 5 ] || { echo "the app didn't report the scene's area" >&2; exit 1; }
CROP=$(echo "$2 $3 $4 $5" | awk -v s="$SCALE" -v m=56 '{ w=int(($3+2*m)*s/2)*2; h=int(($4+2*m)*s/2)*2; printf "%d:%d:%d:%d", w, h, ($1-m)*s, ($2-m)*s }')

NAME="$SCENE-$THEME"
ffmpeg -v error -y -ss 0.5 -t "$LEN" -i "$TMP/raw.mov" -vf "crop=$CROP,fps=30,scale=1200:-2:flags=lanczos" \
  -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart -an "$OUT/$NAME.mp4"
ffmpeg -v error -y -i "$OUT/$NAME.mp4" -c:v libvpx-vp9 -b:v 0 -crf 34 -an "$OUT/$NAME.webm"
ffmpeg -v error -y -ss "$POSTER" -i "$OUT/$NAME.mp4" -frames:v 1 -q:v 3 "$OUT/$NAME-poster.jpg"
if [ "$SCENE" = switcher ]; then
  ffmpeg -v error -y -i "$OUT/$NAME.mp4" -vf "fps=12,scale=640:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$OUT/$NAME.gif"
fi
ls -la "$OUT/$NAME".*
