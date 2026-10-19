<p align="center">
  <img src="docs/media/icon.png" width="112" height="112" alt="Muster">
</p>

<h1 align="center">Muster</h1>

<p align="center">
  <b>Never keep an agent waiting.</b><br>
  A free, open-source Mac menu bar app for your Claude Code, Codex and Cursor sessions.
</p>

<p align="center">
  <a href="https://github.com/josefchen/muster/releases/latest/download/Muster.dmg"><b>Download for Mac</b></a> ·
  <code>brew install --cask josefchen/tap/muster</code> ·
  <a href="https://agentmuster.app">agentmuster.app</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/media/answer-dark.gif">
    <img src="docs/media/answer-light.gif" width="760" alt="Claude Code and then Codex ask to run a command. Muster's alert shows the newest first with its keys along the bottom; ⌥↓ unfolds why Codex asks, and ⌥↩ answers each in turn.">
  </picture>
</p>

<p align="center"><sub>Two agents ask. <kbd>⌥</kbd><kbd>↓</kbd> shows why, two presses of <kbd>⌥</kbd><kbd>↩</kbd> answer them, and you never left what you were doing. Recorded from the app.</sub></p>

If you run a few coding agents at once, the slow part isn't the agents. It's noticing which one has been waiting on you for ten minutes. Muster sits in the menu bar, tells you the moment one needs you, and lets you answer without switching apps.


<table>
<tr>
<td width="50%" valign="top">

**See who needs you.**<br>
A glass alert at the top of the screen the moment an agent waits on you. It stays until you answer.

</td>
<td width="50%" valign="top">

**Answer from anywhere.**<br>
Allow a command or pick an answer with <kbd>⌥</kbd><kbd>↩</kbd>, or right from the notification. The alert shows its keys.

</td>
</tr>
<tr>
<td valign="top">

**See why before you answer.**<br>
<kbd>⌥</kbd><kbd>↓</kbd> unfolds the agent's reason, the whole command, or every option with its note.

</td>
<td valign="top">

**Your keys stay yours.**<br>
Muster takes its keys only while something on screen needs them, and lets go while you type elsewhere.

</td>
</tr>
<tr>
<td valign="top">

**<kbd>⌥</kbd><kbd>Tab</kbd> to any agent.**<br>
Most urgent first. Let go to land in its window, or the terminal it runs in.

</td>
<td valign="top">

**Find any session.**<br>
<kbd>⌃</kbd><kbd>⌥</kbd><kbd>Space</kbd> searches the last three hours, with tokens and API-rate cost for each.

</td>
</tr>
</table>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/media/peek-dark.jpg">
    <img src="docs/media/peek-light.jpg" width="640" alt="The alert unfolded with ⌥↓ on a question from Claude Code: three options, each with the agent's note, answered with ⌥1 to ⌥3">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/media/switcher-dark.gif">
    <img src="docs/media/switcher-light.gif" width="640" alt="Hold ⌥ and tap Tab to move through sessions, most urgent first, then ⌥↩ answers the one waiting">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/media/deck-dark.jpg">
    <img src="docs/media/deck-light.jpg" width="720" alt="Search every session with ⌃⌥Space">
  </picture>
</p>

<p align="center"><sub>Native AppKit and Liquid Glass · macOS 14+ · Apple silicon and Intel · no accounts or app analytics · MIT</sub></p>

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
| **Codex** | Approval requests (enable and trust the Muster hook in Codex Settings → Hooks, or `/hooks` in the CLI) |
| **Cursor** | Opens the prompt in Cursor |

The tour and Settings show each connection's progress. For Codex, Muster reads the client's hook status when supported, so a disabled, untrusted or changed hook stays pending. It never enables or trusts hooks on your behalf.

Use **Copy check prompt**, paste it into a local agent session that asks for approval, and answer the request from Muster. The connection is verified only when the request arrives, the answer is delivered, and the same session resumes in its transcript. The sample alert in the tour is practice and does not verify anything. Full access or automatic approval can skip this test because no permission request is made.

You can choose **Set up later** and use switching and search immediately. Unfinished answering setup remains visible in Settings and the menu. Verification records the last successful check, rather than a continuous connection: changed hooks require another check, and evidence older than a day is no longer marked current.

Muster adds one hook to the agent's own settings and removes exactly that when you turn it off. Beside the file it keeps `.muster-original`, the file as it was before Muster first changed it, and `.muster-backup`, the file before the latest change. A symlinked settings file stays a link, and a file Muster can't parse is left alone. Claude's native dialog stays live alongside Muster, and the first answer wins. If Muster isn't running, the agent asks as usual. Hooks talk to Muster on `127.0.0.1` with a per-install token.

## Shortcuts

| Keys | |
|---|---|
| <kbd>⌥</kbd> <kbd>Tab</kbd> | Switch. Tap to step, release to open, or click a row |
| <kbd>⌥</kbd> <kbd>↩</kbd> · <kbd>⌥</kbd> <kbd>⌫</kbd> · <kbd>⌥</kbd> <kbd>1</kbd>–<kbd>9</kbd> | Allow · deny · answer the prompt on the alert or in the switcher |
| <kbd>⌥</kbd> <kbd>↓</kbd> · <kbd>⌥</kbd> <kbd>↑</kbd> | Unfold the alert's details · fold them |
| <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>Space</kbd> | Search every session |

Muster takes <kbd>⌥</kbd><kbd>↩</kbd>, <kbd>⌥</kbd><kbd>⌫</kbd>, the arrows and the digits only while a prompt or the switcher is on screen, and lets go of them while you type in another app, so they keep working in your editor. Both shortcuts can be changed in Settings. Scripting: `muster://search`, `muster://next`, `muster://settings`, `muster://welcome`, `muster://whats-new`.

<details>
<summary><b>Why not just a notification?</b></summary>
<br>

Claude Code can notify you on its own in some terminals, and a few lines of settings add a sound or a banner anywhere else; [this guide compares every option](https://agentmuster.app/guides/claude-code-notifications-mac). A notification tells you that something happened. With several sessions running you still have to work out which one, find its window and type the answer. Muster shows which one, answers it from where you are, and does the same for Codex and Cursor.

</details>

<details>
<summary><b>How it works</b></summary>
<br>

Muster reads the session files each app already writes. Local sessions need no configuration.

| App | Read from |
|---|---|
| **Claude** (desktop, CLI, SSH sessions) | `~/.claude/projects` transcripts and Claude's session list |
| **Codex** (app and CLI) | `~/.codex/state_*.sqlite` threads and rollout logs |
| **Cursor** | The Agents window's chat list and agent transcripts |

Everything is opened read-only. File system events trigger a rescan, at most once a second; transcripts are read incrementally, only the bytes added since the last look.

**Remote sessions (1.4, in development).** Open **Settings → Remote sessions** and enable an SSH alias, or add `user@hostname`. Muster discovers explicit aliases from your SSH config without connecting; only enabled hosts are contacted. Each host needs Python 3 and noninteractive SSH access from this Mac. If SSH needs a password, a new host key confirmation or an unlocked key, connect in Terminal first.

The remote reader runs in memory and polls every three seconds. It reads recent Codex, Claude Code and Cursor data, then sends titles, project paths, status and question previews over encrypted SSH. Summaries stay in memory on the Mac. If a connection drops, the last summaries are marked offline while Muster reconnects. Search by host name to find its sessions.

Recorded questions open in the agent on that host. Codex links include the SSH host; other agents offer an SSH command to copy. Monitoring alone installs no hooks, so it can show only requests recorded in session data. It does not report remote token costs. Recent history covers three hours, up to 500 sessions per host; read failures and truncation appear in Settings.

**Optional remote approvals.** From a source checkout on your Mac, run `python3 scripts/remote-approvals.py enable vml` (replace `vml` with an enabled host). This installs a small Python hook on that host and adds entries to Claude Code's settings and Codex's hooks, preserving other settings and saving original files beside them. Review and trust the Muster PermissionRequest hook in Codex's `/hooks` screen. Recent Claude Code versions [reload hooks when settings change](https://code.claude.com/docs/en/settings#when-edits-take-effect); older clients may need a new session.

Live requests and your answers travel over the same SSH connection. The remote hook uses a private Unix socket; no TCP listener or SSH forwarding is added. Commands and question choices are held in memory while the request waits. If Muster disconnects, the hook returns no decision and the agent asks normally. A 30-second heartbeat timeout also releases requests if the Mac stops responding while SSH remains open. Opening the remote session from Muster hands its waiting request back to the agent. Cursor requests still open in Cursor.

Run `python3 scripts/remote-approvals.py disable vml` to remove this Mac's remote hooks. The installed helper is inert without an enabled relay connection; no background service is installed on the remote host.

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

No accounts or app analytics. Optional SSH monitoring contacts only hosts you enable and transfers session summaries to this Mac; it does not copy full transcripts or raw tool payloads, forward your SSH agent, or install remote hooks. SSH keys and host trust remain managed by SSH. Host settings and read/unread timestamps keyed by session ID are saved on this Mac. Session titles, project paths and question previews stay in memory.

The update check asks GitHub for the latest release when you click Check for Updates, or once a day if you leave "Updates" on in the welcome tour (or tick it in What's New, or turn it on in Settings). The local prompt server listens on `127.0.0.1` only and needs a token that lives in your user defaults and the agents' hook settings.

The website keeps aggregate daily page-load and download-click counts, with no cookies or visitor identifiers. It honors Do Not Track and Global Privacy Control. See the [privacy page](https://agentmuster.app/privacy) and [measurement guide](docs/measurement.md).

</details>

<details>
<summary><b>Build from source</b></summary>
<br>

```bash
git clone https://github.com/josefchen/muster.git && cd muster
./build.sh            # build, install to ~/Applications, launch
./test.sh             # reader tests against fixture files
scripts/e2e.sh        # end-to-end: the real app against a fake home folder
```

`scripts/e2e.sh` drives the built app the way the agents and you would (transcripts, hook requests, the switcher, deck and alert) without touching your own agents or settings; `--soak [minutes]` checks CPU and memory under load, and `--ui` replays real keystrokes and clicks (it takes over the keyboard while it runs).

`scripts/release.sh <version>` builds a universal, signed and notarized DMG and writes its GitHub release notes from [CHANGELOG.md](CHANGELOG.md), and `scripts/site.sh deploy` publishes [agentmuster.app](https://agentmuster.app) and its changelog page to Cloudflare. `scripts/capture-stills.sh`, `scripts/record-scene.sh`, `scripts/record-answer.sh` and `scripts/tour.sh` regenerate the screenshots, the videos and the welcome tour from demo mode (`Muster --demo`). Muster opens and plays each scene itself, so they need Screen Recording and nothing else.

See [CONTRIBUTING.md](CONTRIBUTING.md).

</details>

<br>

<p align="center"><sub>MIT License. Muster is independent and not affiliated with Anthropic, OpenAI or Anysphere.</sub></p>
