#!/bin/sh
# Record the hero video in demo mode: switch, answer a prompt, search.
# Produces docs/media/hero.mp4 (site), hero.webm (site) and hero.gif (README).
#
#   scripts/record.sh [out-dir] [dark|light]
set -eu
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/docs/media}"
THEME="${2:-dark}"
APP="$HOME/Applications/Muster.app"
RAW="$(mktemp -d)/raw.mov"
mkdir -p "$OUT"

quit() { pkill -x Muster 2>/dev/null || true; while pgrep -x Muster >/dev/null; do sleep 0.1; done; }
keys() { osascript -e 'tell application "System Events"' "$@" -e 'end tell'; }
rect() {
  osascript -e 'tell application "System Events" to tell process "Muster"
    set best to ""
    set bestArea to 100000000
    repeat with w in windows
      set {x, y} to position of w
      set {ww, hh} to size of w
      if ww * hh < bestArea then
        set bestArea to ww * hh
        set best to (x as text) & " " & (y as text) & " " & (ww as text) & " " & (hh as text)
      end if
    end repeat
    return best
  end tell'
}

quit
if [ "$THEME" = light ]; then open -n "$APP" --args --demo --backdrop --light; else open -n "$APP" --args --demo --backdrop; fi
sleep 3

# Measure a panel so the crop frames it.
keys -e 'key down option' -e 'key code 48'
sleep 0.5; S=$(rect)
keys -e 'key code 53' -e 'key up option'
sleep 0.4
keys -e 'key code 49 using {control down, option down}'
sleep 0.6; D=$(rect)
keys -e 'key code 53'
sleep 0.8

SCALE=$(system_profiler SPDisplaysDataType | grep -q Retina && echo 2 || echo 1)
crop() {  # "x y w h" in points, margin in points -> ffmpeg crop in pixels
  echo "$1" | awk -v s="$SCALE" -v m="$2" '{ w=int(($3+2*m)*s/2)*2; h=int(($4+2*m)*s/2)*2; printf "%d:%d:%d:%d", w, h, ($1-m)*s, ($2-m)*s }'
}

record() {  # seconds, then the scene runs in the caller
  rm -f "$RAW"
  screencapture -v -V "$1" -x -k "$RAW" >/dev/null 2>&1 &
  REC=$!
}

# Scene 1: a prompt is waiting; switch, answer it, see it resolved.
record 9
sleep 1.0
keys -e 'key down option' -e 'key code 48'
sleep 1.4; keys -e 'key code 48'
sleep 0.7; keys -e 'key code 48'
sleep 0.7; keys -e 'key code 48 using shift down'
sleep 0.7; keys -e 'key code 48 using shift down'
sleep 1.1; keys -e 'key code 36'
sleep 0.2; keys -e 'key up option'
sleep 0.9; keys -e 'key down option' -e 'key code 48'
sleep 1.6; keys -e 'key code 53' -e 'key up option'
wait $REC
ffmpeg -v error -y -i "$RAW" -vf "crop=$(crop "$S" 80),fps=30,scale=1200:-2:flags=lanczos" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart -an "$OUT/hero.mp4"

# Scene 2: search.
record 5
sleep 0.8; keys -e 'key code 49 using {control down, option down}'
sleep 1.0; keys -e 'keystroke "r"'
sleep 0.15; keys -e 'keystroke "u"'
sleep 0.15; keys -e 'keystroke "s"'
sleep 0.15; keys -e 'keystroke "t"'
sleep 1.5; keys -e 'key code 53'
wait $REC
ffmpeg -v error -y -i "$RAW" -vf "crop=$(crop "$D" 80),fps=30,scale=1200:-2:flags=lanczos" -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart -an "$OUT/search.mp4"
quit
open "$APP"

for v in hero search; do
  ffmpeg -v error -y -i "$OUT/$v.mp4" -c:v libvpx-vp9 -b:v 0 -crf 34 -an "$OUT/$v.webm"
done
ffmpeg -v error -y -i "$OUT/hero.mp4" -vf "fps=12,scale=640:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$OUT/hero.gif"
ls -la "$OUT"/hero.* "$OUT"/search.*
