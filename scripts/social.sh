#!/bin/sh
# The 1280 × 640 image link previews show (Open Graph, X, the GitHub repo): the real alert
# from demo mode over its backdrop, with the name and the line under it. Needs Screen
# Recording and Google Chrome. Writes docs/media/social-preview.png.
#
#   scripts/social.sh [out-dir]
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/docs/media}"
APP="$HOME/Applications/Muster.app"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"

quit() { pkill -x Muster 2>/dev/null || true; while pgrep -x Muster >/dev/null; do sleep 0.1; done; }

# 1280 × 640 points from the top of the main screen, centred, with the alert in it.
set -- $(swift -e 'import AppKit; print(Int(NSScreen.screens[0].frame.width))')
X=$((($1 - 1280) / 2))
quit
"$APP/Contents/MacOS/Muster" --demo --backdrop --attention >/dev/null 2>&1 &
PID=$!
sleep 3.2
screencapture -x -R"$X,0,1280,640" "$TMP/shot.png"
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
open "$APP"

cp "$HERE/docs/media/icon.png" "$TMP/icon.png"
cat > "$TMP/card.html" <<'HTML'
<!doctype html><meta charset="utf-8">
<style>
  html, body { margin: 0; width: 1280px; height: 640px; overflow: hidden; }
  body { background: url(shot.png) center top / 1280px 640px no-repeat; color: #fff;
         font-family: -apple-system, "SF Pro Display", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
  .words { position: absolute; left: 0; right: 0; top: 300px; text-align: center; }
  .name { display: inline-flex; align-items: center; gap: 18px; font-size: 44px; font-weight: 700; letter-spacing: -.02em; }
  .name img { width: 64px; height: 64px; }
  h1 { margin: 22px 0 0; font-size: 76px; font-weight: 700; letter-spacing: -.035em; line-height: 1; }
  h1 span { color: #ff9f0a; }
  p { margin: 22px 0 0; font-size: 26px; color: rgba(255,255,255,.72); }
</style>
<div class="words">
  <div class="name"><img src="icon.png" alt="">Muster</div>
  <h1>Never keep an agent <span>waiting.</span></h1>
  <p>Free and open source, for Claude Code, Codex and Cursor on the Mac</p>
</div>
HTML
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1280,640 \
  --screenshot="$OUT/social-preview.png" "file://$TMP/card.html" >/dev/null 2>&1
ls -la "$OUT/social-preview.png"
