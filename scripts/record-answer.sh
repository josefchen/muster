#!/bin/sh
# Record the alert scene in demo mode: Claude asks, then Codex, and ⌥↩ answers each.
# Muster plays it itself (--autoplay), so this needs Screen Recording but not
# Accessibility. Writes answer-<theme>.mp4, .webm and .gif (README) to the out folder.
#
#   scripts/record-answer.sh [dark|light] [out-dir]
set -eu
THEME="${1:-dark}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$HERE/docs/media}"
APP="$HOME/Applications/Muster.app"
RAW="$(mktemp -d)/raw.mov"
mkdir -p "$OUT"

quit() { pkill -x Muster 2>/dev/null || true; while pgrep -x Muster >/dev/null; do sleep 0.1; done; }

# The main screen's size, menu bar height and scale, to frame the alert and the keys.
set -- $(swift -e 'import AppKit; let s = NSScreen.screens[0]; print(Int(s.frame.width), Int(s.frame.maxY - s.visibleFrame.maxY), Int(s.backingScaleFactor))')
W=$1 BAR=$2 SCALE=$3

quit
if [ "$THEME" = light ]; then open -n "$APP" --args --demo --backdrop --attention --autoplay --light
else open -n "$APP" --args --demo --backdrop --attention --autoplay; fi
sleep 1.6
screencapture -v -V 11 -x "$RAW" >/dev/null 2>&1
quit
open "$APP"

# 720 × 270 points around the alert (top) and the keys under it.
CROP="$((720 * SCALE)):$((270 * SCALE)):$(((W / 2 - 360) * SCALE)):$(((BAR - 26) * SCALE))"
ffmpeg -v error -y -ss 0.4 -t 8.4 -i "$RAW" -vf "crop=$CROP,fps=30,scale=1440:-2:flags=lanczos" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart -an "$OUT/answer-$THEME.mp4"
ffmpeg -v error -y -i "$OUT/answer-$THEME.mp4" -c:v libvpx-vp9 -b:v 0 -crf 32 -an "$OUT/answer-$THEME.webm"
# The GIF opens on both agents waiting (2.5 s into the clip), plays to the end, then wraps
# through the calm before the first alert (from 0.9 s), so its first frame shows Muster at
# work rather than an empty backdrop. Bayer dithering keeps the gradient from bloating it.
ffmpeg -v error -y -i "$OUT/answer-$THEME.mp4" -filter_complex \
  "[0:v]trim=start=2.5,setpts=PTS-STARTPTS[a];[0:v]trim=start=0.9:end=2.5,setpts=PTS-STARTPTS[b];[a][b]concat=n=2:v=1:a=0,fps=20,scale=760:-2:flags=lanczos,split[c][d];[c]palettegen=max_colors=192:stats_mode=diff[p];[d][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  "$OUT/answer-$THEME.gif"
ls -la "$OUT"/answer-"$THEME".*
