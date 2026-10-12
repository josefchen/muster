<p align="center">
  <img src="docs/media/icon.png" width="112" height="112" alt="Muster">
</p>

<h1 align="center">Muster</h1>

<p align="center">
  <b>Every agent, one glance.</b><br>
  A native Mac switcher for your Claude, Codex and Cursor sessions.
</p>

<p align="center">
  <a href="https://github.com/josefchen/muster/releases/latest/download/Muster.dmg"><b>Download for Mac</b></a> ·
  <code>brew install --cask josefchen/tap/muster</code>
</p>

<p align="center">
  <img src="docs/media/hero.gif" width="640" alt="Hold ⌥ and tap Tab to switch, ⌥↩ to answer a waiting prompt">
</p>

<br>

<table>
<tr>
<td width="50%" valign="top">

**See who needs you.**<br>
A glass alert at the top of the screen the moment an agent waits on you. It stays until you answer.

</td>
<td width="50%" valign="top">

**Answer from anywhere.**<br>
Allow a command or pick an answer with <kbd>⌥</kbd><kbd>↩</kbd>, or right from the notification.

</td>
</tr>
<tr>
<td valign="top">

**<kbd>⌥</kbd><kbd>Tab</kbd> to any agent.**<br>
Most urgent first. Let go to land in its window, or the terminal it runs in.

</td>
<td valign="top">

**Know what it costs.**<br>
Tokens and API-rate cost for every session, priced per model and per message.

</td>
</tr>
</table>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/media/deck-dark.jpg">
    <img src="docs/media/deck-light.jpg" width="720" alt="Search every session with ⌃⌥Space">
  </picture>
</p>

<p align="center"><sub>Native AppKit and Liquid Glass · 2 MB · about 25 MB of memory · no accounts, no analytics · MIT</sub></p>

<br>

## Install

**[Download Muster.dmg](https://github.com/josefchen/muster/releases/latest/download/Muster.dmg)** and drag it to Applications, or:

```bash
brew install --cask josefchen/tap/muster
```

macOS 14 or later, Apple silicon or Intel. Liquid Glass needs macOS 26.

## Answer prompts from Muster

Turn it on per agent in **Settings → Answer prompts from Muster**.

| | What you can answer |
|---|---|
| **Claude Code** | Permission requests, multiple-choice questions, plan approvals |
| **Codex** | Approval requests (trust the hook once with `/hooks` in Codex) |
| **Cursor** | Opens the prompt in Cursor |

Muster adds one hook to the agent's own settings, keeps a backup, and removes exactly that when you turn it off. Claude's native dialog stays live alongside Muster, and the first answer wins. If Muster isn't running, the agent asks as usual. Hooks talk to Muster on `127.0.0.1` with a per-install token.

## Shortcuts

| Keys | |
|---|---|
| <kbd>⌥</kbd> <kbd>Tab</kbd> | Switch. Tap to step, release to open, or click a row |
| <kbd>⌥</kbd> <kbd>↩</kbd> · <kbd>⌥</kbd> <kbd>⌫</kbd> · <kbd>⌥</kbd> <kbd>1</kbd>–<kbd>9</kbd> | Allow · deny · answer the selected prompt |
| <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>Space</kbd> | Search every session |

Both shortcuts can be changed in Settings. Scripting: `muster://search`, `muster://next`, `muster://settings`, `muster://welcome`.

<details>
<summary><b>How it works</b></summary>
<br>

Muster reads the session files each app already writes. Nothing to configure.

| App | Read from |
|---|---|
| **Claude** (desktop, CLI, SSH sessions) | `~/.claude/projects` transcripts and Claude's session list |
| **Codex** (app and CLI) | `~/.codex/state_*.sqlite` threads and rollout logs |
| **Cursor** | The Agents window's chat list and agent transcripts |

Everything is opened read-only. File system events trigger a rescan, at most once a second; transcripts are read incrementally, only the bytes added since the last look.

</details>

<details>
<summary><b>Cost estimates</b></summary>
<br>

Public list prices for the standard API tier, bundled and dated in Settings. Claude is priced message by message, including subagents, with 5-minute and 1-hour cache writes kept apart. Codex is priced from its running totals; OpenAI's long-context tier isn't applied, so Codex figures are a floor. Cursor records no token counts on disk.

Use your own prices from **Settings → Use my own prices…**, which writes `~/Library/Application Support/Muster/pricing.json`.

</details>

<details>
<summary><b>Privacy</b></summary>
<br>

No accounts, no analytics. The only network request is the update check, which happens when you click Check for Updates or turn on the daily check, and asks GitHub for the latest release. The prompt server listens on `127.0.0.1` only and needs a token that lives in your user defaults and the agents' hook settings.

</details>

<details>
<summary><b>Build from source</b></summary>
<br>

```bash
git clone https://github.com/josefchen/muster.git && cd muster
./build.sh            # build, install to ~/Applications, launch
./test.sh             # reader tests against fixture files
```

`scripts/release.sh <version>` builds a universal, signed and notarized DMG. `scripts/capture.sh`, `scripts/record.sh` and `scripts/tour.sh` regenerate the screenshots, the video and the welcome tour from demo mode (`Muster --demo`).

See [CONTRIBUTING.md](CONTRIBUTING.md).

</details>

<br>

<p align="center"><sub>MIT License. Muster is independent and not affiliated with Anthropic, OpenAI or Anysphere.</sub></p>
