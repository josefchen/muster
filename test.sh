#!/bin/sh
# Build the readers, the hook server and the settings edits with the test runner and run it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)/muster-tests"
swiftc -O -swift-version 5 -target arm64-apple-macos14 -o "$OUT" \
  "$HERE/Sources/Model.swift" "$HERE/Sources/Scanner.swift" "$HERE/Sources/Pricing.swift" "$HERE/Sources/Stats.swift" \
  "$HERE/Sources/History.swift" "$HERE/Sources/Hooks.swift" "$HERE/Sources/Server.swift" "$HERE/Tests/main.swift"
"$OUT"
