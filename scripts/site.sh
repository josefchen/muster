#!/bin/sh
# Build the landing page, the changelog and the guides into site/dist and deploy them to Cloudflare.
#
#   scripts/site.sh            build site/dist
#   scripts/site.sh preview    build, then serve it on http://127.0.0.1:8790 (the changelog is at
#                              /changelog.html there; Cloudflare serves it at /changelog)
#   scripts/site.sh deploy     build, then deploy agentmuster.app and the www redirect
#
# Deploying needs wrangler logged in to the Cloudflare account that holds the
# agentmuster.app zone (npx wrangler login).
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$HERE/site"
OUT="$SITE/dist"

# IndexNow's key: the file at the site's root proves the pings below come from us.
INDEXNOW=0098e4e4ada21f8e00e95ff19d4823e7

rm -rf "$OUT" && mkdir -p "$OUT/media" "$OUT/guides"
cp "$SITE/index.html" "$SITE/404.html" "$SITE/robots.txt" "$SITE/llms.txt" "$SITE/page.css" "$SITE/_headers" \
  "$SITE/$INDEXNOW.txt" "$OUT/"
cp "$SITE"/guides/*.html "$OUT/guides/"
# The changelog page and its feed from CHANGELOG.md, and the version the landing page names.
"$HERE/scripts/changelog.sh" page "$SITE/changelog.html" > "$OUT/changelog.html"
"$HERE/scripts/changelog.sh" feed > "$OUT/changelog.xml"
LATEST="$("$HERE/scripts/changelog.sh" latest)"
VERSION="${LATEST% *}"
RELEASED="${LATEST#* }"
sed -i '' "s/\"softwareVersion\": \"[0-9.]*\"/\"softwareVersion\": \"$VERSION\"/" "$OUT/index.html"

# The sitemap, each page dated by its last commit, or today while it has changes.
changed() {
  d="$(git -C "$HERE" log -1 --format=%cs -- "$1")"
  if [ -n "$d" ] && [ -z "$(git -C "$HERE" status --porcelain -- "$1")" ]; then echo "$d"; else date +%F; fi
}
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
  echo "  <url><loc>https://agentmuster.app/</loc><lastmod>$(changed site/index.html)</lastmod></url>"
  echo "  <url><loc>https://agentmuster.app/changelog</loc><lastmod>$RELEASED</lastmod></url>"
  for f in "$SITE"/guides/*.html; do
    name="$(basename "$f" .html)"
    echo "  <url><loc>https://agentmuster.app/guides/$name</loc><lastmod>$(changed "site/guides/$name.html")</lastmod></url>"
  done
  echo '</urlset>'
} > "$OUT/sitemap.xml"

# Only the media the pages use, straight from the README's media folder.
for f in $(grep -oh '/media/[A-Za-z0-9._-]*' "$SITE/index.html" "$SITE/404.html" "$SITE/changelog.html" "$SITE"/guides/*.html | sort -u); do
  cp "$HERE/docs$f" "$OUT$f"
done

case "${1:-build}" in
  build) echo "built $OUT ($(du -sh "$OUT" | cut -f1))" ;;
  preview) cd "$OUT" && exec python3 -m http.server 8790 --bind 127.0.0.1 ;;
  deploy)
    (cd "$SITE" && npx wrangler deploy) && (cd "$SITE/www" && npx wrangler deploy)
    # Tell Bing and the other IndexNow engines what changed; Google reads the sitemap.
    urls="$(grep -o '<loc>[^<]*</loc>' "$OUT/sitemap.xml" | sed 's/<[^>]*>//g; s/.*/"&"/' | paste -sd, -)"
    curl -s -o /dev/null -w "IndexNow: HTTP %{http_code}\n" -X POST https://api.indexnow.org/indexnow \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "{\"host\":\"agentmuster.app\",\"key\":\"$INDEXNOW\",\"keyLocation\":\"https://agentmuster.app/$INDEXNOW.txt\",\"urlList\":[$urls]}"
    ;;
  *) echo "usage: scripts/site.sh [build|preview|deploy]" >&2; exit 64 ;;
esac
