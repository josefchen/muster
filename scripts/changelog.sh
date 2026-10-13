#!/bin/sh
# CHANGELOG.md for the places outside the app, read by the app's own parser.
#
#   scripts/changelog.sh notes 1.2.0             GitHub release notes; fails without a dated entry
#   scripts/changelog.sh page site/changelog.html  the page with <!-- releases --> filled in
#   scripts/changelog.sh feed                    an Atom feed of the released versions
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT
swiftc -swift-version 5 -o "$BIN/changelog" "$HERE/Sources/Changelog.swift" "$HERE/scripts/changelog/main.swift"
"$BIN/changelog" "$HERE/CHANGELOG.md" "$@"
