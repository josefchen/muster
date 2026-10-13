#!/bin/sh
# How Muster is doing, from numbers GitHub already keeps: downloads per release, stars,
# and the last 14 days of repo traffic and referrers. The app reports nothing.
#
#   scripts/stats.sh
set -eu
REPO=josefchen/muster

echo "Downloads"
gh api "repos/$REPO/releases" --jq '.[] | "  \(.tag_name)  " + ([.assets[] | "\(.name) \(.download_count)"] | join("  ·  "))'
gh api "repos/$REPO/releases" --jq '"  total  \([.[].assets[].download_count] | add)"'

echo
gh api "repos/$REPO" --jq '"Stars \(.stargazers_count)  ·  forks \(.forks_count)  ·  watchers \(.subscribers_count)  ·  open issues \(.open_issues_count)"'

echo
echo "Last 14 days (needs push access)"
gh api "repos/$REPO/traffic/views" --jq '"  views \(.count), from \(.uniques) people"'
gh api "repos/$REPO/traffic/clones" --jq '"  clones \(.count), from \(.uniques) people"'
echo "  referrers:"
gh api "repos/$REPO/traffic/popular/referrers" --jq '.[] | "    \(.referrer)  \(.count) (\(.uniques) people)"'
