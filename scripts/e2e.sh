#!/bin/sh
# End-to-end tests: the real app against a fake home folder, driven the way the
# agents and you would. Everything lives in a temp folder: the app runs as
# dev.muster.e2e (its own settings), on ports of its own, reading only the
# fixture home, so your ~/.claude, ~/.codex, Cursor data and running Muster are
# never touched. Run one at a time: runs share the dev.muster.e2e settings.
#
#   scripts/e2e.sh                headless suite, then again as x86_64 if Rosetta is installed
#   scripts/e2e.sh --soak [min]   CPU and memory with ten busy agents and a 500 MB transcript (default 10);
#                                 MUSTER_SOAK_CPU_LIMIT overrides the 1.5 % average CPU limit
#   scripts/e2e.sh --ui           real keystrokes and clicks; see below
#   scripts/e2e.sh --build-only   compile everything, run nothing
#
# --ui posts real key and mouse events, so it takes over your keyboard, pointer
# and screen while it runs. It needs Accessibility for the terminal (to post events
# and read the accessibility tree), Screen Recording too with --baselines <dir>,
# and Muster quit so ⌥Tab and ⌃⌥Space are free.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODE=headless
MINUTES=10
ROSETTA=1
BASELINES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --soak) MODE=soak; if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then MINUTES="$2"; shift; fi ;;
    --ui) MODE=ui ;;
    --baselines) BASELINES="${2:?--baselines needs a folder}"; shift ;;
    --build-only) MODE=build ;;
    --no-rosetta) ROSETTA=0 ;;
    *) echo "usage: scripts/e2e.sh [--soak [minutes]] [--ui [--baselines dir]] [--build-only] [--no-rosetta]" >&2; exit 64 ;;
  esac
  shift
done

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/muster-e2e.XXXXXX")" && pwd -P)"
mkdir "$WORK/tmp"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  # Only processes started from this run's temp folder; never the real Muster.
  pkill -9 -f "$WORK/" 2>/dev/null || true
  for bundle in "$WORK"/*/MusterE2E.app; do
    if [ -d "$bundle" ]; then "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true; fi
  done
  defaults delete dev.muster.e2e >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

HOST="$(uname -m)"

# The app as a dev.muster.e2e bundle that claims no muster:// links.
build_app() {
  bundle="$WORK/$1/MusterE2E.app"
  mkdir -p "$bundle/Contents/MacOS"
  swiftc -O -swift-version 5 -target "$1-apple-macos14" -o "$bundle/Contents/MacOS/MusterE2E" "$HERE"/Sources/*.swift
  plist="$bundle/Contents/Info.plist"
  cp "$HERE/Resources/Info.plist" "$plist"
  plutil -replace CFBundleIdentifier -string dev.muster.e2e "$plist"
  plutil -replace CFBundleExecutable -string MusterE2E "$plist"
  plutil -replace CFBundleName -string MusterE2E "$plist"
  plutil -replace CFBundleDisplayName -string MusterE2E "$plist"
  plutil -remove CFBundleURLTypes "$plist"
  codesign --force --sign - "$bundle" >/dev/null 2>&1
  echo "$bundle"
}

# Fixture homes go under $WORK too, so nothing outlives the run.
drive() { TMPDIR="$WORK/tmp/" "$WORK/driver" "$@"; }

rosetta() { [ "$ROSETTA" = 1 ] && [ "$HOST" = arm64 ] && /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; }

echo "Building Muster and the e2e driver ($HOST)…"
APP="$(build_app "$HOST")"
swiftc -O -swift-version 5 -target "$HOST-apple-macos14" -o "$WORK/driver" "$HERE"/Tests/e2e/*.swift

case "$MODE" in
  build)
    if rosetta; then build_app x86_64 >/dev/null; fi
    echo "Built."
    ;;
  headless)
    status=0
    drive headless --app "$APP" --label "$HOST" || status=1
    if rosetta; then
      echo
      echo "Building for x86_64…"
      X86="$(build_app x86_64)"
      drive headless --app "$X86" --label "x86_64 under Rosetta" || status=1
    fi
    exit $status
    ;;
  soak)
    drive soak --app "$APP" --minutes "$MINUTES"
    ;;
  ui)
    if [ -n "$BASELINES" ]; then
      drive ui --app "$APP" --baselines "$BASELINES"
    else
      drive ui --app "$APP"
    fi
    ;;
esac
