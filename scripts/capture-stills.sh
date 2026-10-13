#!/bin/sh
# Stills of the real panels in demo mode, over the demo backdrop, for the README and the
# site. Needs Screen Recording only: the app opens each panel itself and reports where it
# is. Writes, in dark and light: alert-*.jpg, peek-*.jpg (the alert unfolded on a
# question), switcher-*.jpg and deck-*.jpg; then appearance.jpg, the switcher half dark
# and half light.
#
#   scripts/capture-stills.sh [out-dir]
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/docs/media}"
APP="$HOME/Applications/Muster.app"
TMP="$(mktemp -d)"
mkdir -p "$OUT"

quit() { pkill -x Muster 2>/dev/null || true; while pgrep -x Muster >/dev/null; do sleep 0.1; done; }

# shot <name> <margin> <flags…>: run demo mode with the flags, wait for the panel to report
# where it is, and capture it with a margin of backdrop around it.
shot() {
  name=$1 margin=$2; shift 2
  quit
  "$APP/Contents/MacOS/Muster" --demo --backdrop "$@" > "$TMP/where.txt" 2>/dev/null &
  pid=$!
  sleep 3.4
  set -- $(grep '^scene ' "$TMP/where.txt" | tail -1)
  [ $# -eq 5 ] || { echo "$name: the app didn't report where the panel is" >&2; kill "$pid"; exit 1; }
  screencapture -x -R"$(($2 - margin)),$(($3 - margin)),$(($4 + 2 * margin)),$(($5 + 2 * margin))" "$TMP/$name.png"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sips -s format jpeg -s formatOptions 88 "$TMP/$name.png" --out "$OUT/$name.jpg" >/dev/null
  echo "$OUT/$name.jpg"
}

for theme in dark light; do
  light=""; [ "$theme" = light ] && light=--light
  shot "alert-$theme" 40 --attention $light
  shot "peek-$theme" 40 --attention --question --peek $light
  shot "switcher-$theme" 60 --switcher $light
  shot "deck-$theme" 60 --search $light
done
quit
open "$APP"

# The switcher split down the middle: dark on the left, light on the right.
ffmpeg -v error -y -i "$OUT/switcher-dark.jpg" -i "$OUT/switcher-light.jpg" -filter_complex \
  "[0]crop=iw/2:ih:0:0[l];[1]crop=iw/2:ih:iw/2:0[r];[l][r]hstack" -q:v 3 "$OUT/appearance.jpg"
echo "$OUT/appearance.jpg"
