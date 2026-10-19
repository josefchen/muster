# Contributing to Muster

Thanks for helping. A few things keep Muster fast and trustworthy.

## Before you open a pull request

- Run `./test.sh` and `./build.sh`. Both must pass.
- If you touch a reader, add a case to `Tests/main.swift` using fixture files. Never
  commit real transcripts.
- If you change how something looks, regenerate the screenshots and videos with
  `scripts/capture-stills.sh`, `scripts/record-scene.sh`, `scripts/record-answer.sh` and
  `scripts/tour.sh`, and check them in light and dark mode. They run Muster in demo mode,
  which opens and plays each panel itself, so they need Screen Recording and nothing else.

## Principles

- **Native first.** AppKit for anything on screen all day. SwiftUI is fine for
  windows that open occasionally, like Settings.
- **Read-only, private by default.** Local agent data stays on the Mac. Opt-in SSH monitoring transfers
  summaries from enabled hosts over existing SSH access; it installs no hooks or helper files remotely.
  The other network feature is the opt-in GitHub update check. Writing another app's files requires
  turning on local prompt answering, which edits that agent's hook settings with a backup.
- **Cheap when idle.** No polling where a file system event will do. Views are
  updated in place, not rebuilt. Measure memory with `footprint -p $(pgrep -x Muster)`
  before and after a change that touches scanning or drawing.

## The changelog

Every change people would notice gets a line in `CHANGELOG.md`, under the top entry.
That one file becomes What's New in the app (once after an update, and in the menu bar
menu), the changelog page and feed on agentmuster.app, and the GitHub release notes.

```markdown
## 1.3.0 · Unreleased

One sentence on what this release is about.

- <!-- bolt --> **A short title.** What changed for you, in a sentence or two.
```

- The comment names an [SF Symbol](https://developer.apple.com/sf-symbols/) for What's
  New. GitHub doesn't show it. `./test.sh` fails on a name that doesn't exist.
- Write what someone using Muster will see or stop seeing, not what the code does.
  Lead with the change that matters most, and keep a release to about five items.
- Paragraphs after the items are notes, such as a step the update needs.
- Starting a new version: add its entry and set the same version in
  `Resources/Info.plist`. `./test.sh` checks that they match.
- Releasing it: replace `Unreleased` with the date (`2026-10-14`). `scripts/release.sh`
  refuses a version without a dated entry.

## Adding an agent app

Write a reader in `Scanner.swift` that returns `[Session]` from the app's own files,
add the app to `Agent` in `Model.swift`, a deep link in `Opener`, and tests.

## Prices

Update `Pricing.swift` from the vendors' official pricing pages only, and bump
`Pricing.retrieved`.
