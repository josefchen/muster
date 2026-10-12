#!/bin/sh
# Build the landing page into site/dist and deploy it to Cloudflare.
#
#   scripts/site.sh            build site/dist
#   scripts/site.sh preview    build, then serve it on http://127.0.0.1:8790
#   scripts/site.sh deploy     build, then deploy agentmuster.app and the www redirect
#
# Deploying needs wrangler logged in to the Cloudflare account that holds the
# agentmuster.app zone (npx wrangler login).
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$HERE/site"
OUT="$SITE/dist"

rm -rf "$OUT" && mkdir -p "$OUT/media"
cp "$SITE/index.html" "$SITE/404.html" "$SITE/robots.txt" "$SITE/sitemap.xml" "$SITE/_headers" "$OUT/"
# Only the media the pages use, straight from the README's media folder.
for f in $(grep -oh '/media/[A-Za-z0-9._-]*' "$SITE/index.html" "$SITE/404.html" | sort -u); do
  cp "$HERE/docs$f" "$OUT$f"
done

case "${1:-build}" in
  build) echo "built $OUT ($(du -sh "$OUT" | cut -f1))" ;;
  preview) cd "$OUT" && exec python3 -m http.server 8790 --bind 127.0.0.1 ;;
  deploy) (cd "$SITE" && npx wrangler deploy) && (cd "$SITE/www" && npx wrangler deploy) ;;
  *) echo "usage: scripts/site.sh [build|preview|deploy]" >&2; exit 64 ;;
esac
