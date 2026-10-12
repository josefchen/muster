# Contributing to Muster

Thanks for helping. A few things keep Muster fast and trustworthy.

## Before you open a pull request

- Run `./test.sh` and `./build.sh`. Both must pass.
- If you touch a reader, add a case to `Tests/main.swift` using fixture files. Never
  commit real transcripts.
- If you change how something looks, regenerate the screenshots and video with
  `scripts/capture.sh` and `scripts/record.sh` (they run Muster in demo mode) and
  check them in light and dark mode.

## Principles

- **Native first.** AppKit for anything on screen all day. SwiftUI is fine for
  windows that open occasionally, like Settings.
- **Read-only, local only.** Muster never makes a network request, and only writes
  to another app's files when you turn on prompt answering, which edits that agent's
  hook settings with a backup.
- **Cheap when idle.** No polling where a file system event will do. Views are
  updated in place, not rebuilt. Measure memory with `footprint -p $(pgrep -x Muster)`
  before and after a change that touches scanning or drawing.

## Adding an agent app

Write a reader in `Scanner.swift` that returns `[Session]` from the app's own files,
add the app to `Agent` in `Model.swift`, a deep link in `Opener`, and tests.

## Prices

Update `Pricing.swift` from the vendors' official pricing pages only, and bump
`Pricing.retrieved`.
