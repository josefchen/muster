#!/bin/sh
# Capture real screenshots of the glass UI in demo mode, over a generated
# wallpaper, for the README and the website. Needs Screen Recording permission
# for the terminal app and Accessibility for System Events.
#
#   scripts/capture.sh [out-dir]
set -eu
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/docs/media}"
APP="$HOME/Applications/Muster.app"
mkdir -p "$OUT"

quit() { pkill -x Muster 2>/dev/null || true; while pgrep -x Muster >/dev/null; do sleep 0.1; done; }

panel_rect() {
  # The smallest Muster window on screen is the panel; pad it so the wallpaper frames it.
  osascript -e 'tell application "System Events" to tell process "Muster"
    set best to ""
    set bestArea to 100000000
    repeat with w in windows
      set {x, y} to position of w
      set {ww, hh} to size of w
      if ww * hh < bestArea then
        set bestArea to ww * hh
        set best to ((x - 90) as text) & "," & ((y - 70) as text) & "," & ((ww + 180) as text) & "," & ((hh + 140) as text)
      end if
    end repeat
    return best
  end tell'
}

for theme in dark light; do
  quit
  if [ "$theme" = light ]; then open -n "$APP" --args --demo --backdrop --light; else open -n "$APP" --args --demo --backdrop; fi
  sleep 3

  osascript -e 'tell application "System Events"' -e 'key down option' -e 'key code 48' -e 'end tell'
  sleep 0.6
  screencapture -x -R"$(panel_rect)" "$OUT/switcher-$theme.png"
  osascript -e 'tell application "System Events"' -e 'key code 53' -e 'key up option' -e 'end tell'
  sleep 0.4

  osascript -e 'tell application "System Events" to key code 49 using {control down, option down}'
  sleep 0.8
  screencapture -x -R"$(panel_rect)" "$OUT/deck-$theme.png"
  osascript -e 'tell application "System Events" to key code 53'
  sleep 0.3
done
quit
open "$APP"
echo "captured into $OUT"
