# Changelog

What changed in each release of Muster, newest first. The app shows the latest one after you update, and every release is also at [agentmuster.app/changelog](https://agentmuster.app/changelog).

## 1.4.0 · Unreleased

Watch sessions on your SSH hosts alongside this Mac, with clearer connection states.

- <!-- network --> **Watch your other machines.** Enable hosts in Settings → Remote sessions to monitor recent Codex, Claude Code and Cursor sessions through your existing SSH access. Questions show the host where you answer; disconnected hosts keep their last summaries and reconnect automatically. Python 3 is required on each host.
- <!-- questionmark.bubble --> **Questions stay visible.** Recognizes both Codex question APIs and keeps unanswered questions through new turns and restarts. Answering one question in a batch keeps the remaining ones visible. Long remote tool output no longer pushes a waiting question out of view.
- <!-- arrow.clockwise --> **Sessions come back.** A temporary lock on Codex's or Cursor's database keeps the last known session list and retries, instead of dropping sessions or staying empty after the lock clears.
- <!-- waveform --> **Long Codex tasks stay working.** New token activity keeps a long task active without clearing an approval that still needs your answer.
- <!-- desktopcomputer --> **Intel Macs work too.** Includes the startup fix for Intel Macs; local build and test scripts now use your Mac's architecture.

## 1.3.2 · 2026-10-14

Each request reaches you once, Codex's questions show up, and answering setup checks itself.

- <!-- bell.slash --> **No more doubled alerts.** While the alert is on, Muster no longer also posts a banner for the same request. Banners when a session finishes are off unless you turn them on, since Claude's and Codex's apps already announce it.
- <!-- questionmark.bubble --> **Codex's questions show up.** When Codex asks you something, the alert and the switcher show the question, and ⌥Tab takes you to it. Codex has no hook for questions, so you answer them in Codex.
- <!-- checkmark.seal --> **Answering setup checks itself.** The tour and Settings show whether each agent's hook is really connected. For Codex, Muster reads whether its hook is enabled and trusted, and a test request confirms the whole round trip.
- <!-- arrow.down.circle --> **Hear about new versions.** The tour and What's New offer a once-a-day check, so the next fix reaches you.
- <!-- app.dashed --> **Icons without the apps.** Claude Code or Codex used only in a terminal gets a drawn icon instead of a blank space.
- <!-- macwindow --> **Cleaner on macOS 14 and 15.** The alert no longer turns brown on the glass macOS used before Liquid Glass.

## 1.3.1 · 2026-10-13

Clearer when Muster can't answer for you yet.

- <!-- gearshape --> **Where to turn answering on.** An alert that Muster can't answer, because answering is off for that agent, now says where to turn it on, next to ⌥Tab to go to the session.
- <!-- keyboard --> **The switcher's keys, as keys.** Its footer shows ⌥, Tab, ⇧Tab and Esc as keycaps, like the alert.
- <!-- list.bullet.rectangle --> **A quieter selection.** The selected row is a plain fill whatever its state, so orange only ever means an agent needs you.

## 1.3.0 · 2026-10-13

See why an agent asks before you answer, with the keys on the alert.

- <!-- text.below.photo --> **Details with ⌥↓.** The alert unfolds to show what the agent sent: its reason for asking, the whole command, the file and size of an edit, the plan, and the folder. ⌥↑ folds it away, and each new request starts folded.
- <!-- list.number --> **Choices with their notes.** A question lists every option with the agent's note on it, so you can pick one with ⌥1, ⌥2 or ⌥3 without switching.
- <!-- keyboard --> **The keys are on the alert.** Every alert shows the keys that answer it as keycaps, or ⌥Tab to go to it when there's nothing to answer from Muster.
- <!-- hand.raised --> **Your keys stay yours.** Muster takes ⌥↩, ⌥⌫, the arrows and the digits only while something on screen needs them, and only the digits a question has. While you type in another app, the alert lets go of its keys, so ⌥⌫ deletes a word there and ⌥↩ starts a new line. ⌥↑ and ⌥↓ move lines in your editor again whenever nothing is asking.
- <!-- rectangle.on.rectangle --> **One sheet of glass.** The alert is a single tinted surface now, without a card inside it.
- <!-- hand.point.up.left --> **Practice in the tour.** The welcome tour's answer step has an alert you can try the keys on.

## 1.2.1 · 2026-10-13

Installing and updating are smoother.

- <!-- arrow.down.app --> **An installer window that shows the way.** Open the disk image and Muster sits next to your Applications folder, with an arrow between them.
- <!-- arrow.triangle.2.circlepath --> **Updates take over cleanly.** Put a new Muster in place of the old one and open it: the old copy quits instead of staying in charge.
- <!-- eject --> **The disk image ejects itself.** When Muster moves itself into Applications, it ejects the disk image it came from.
- <!-- text.badge.plus --> **Nothing skipped.** If you jump past a release, What's New shows its changes too.

## 1.2.0 · 2026-10-13

Only the errors you can fix ask for you.

- <!-- hourglass --> **Usage limits wait their turn.** A session stopped by a usage limit or a sign-out moves to Recent and shows when the limit resets. You get one notification per limit instead of one per session.
- <!-- exclamationmark.bubble --> **Errors say what happened.** Connection lost, API error or a refused request, with the agent's own message when you hover.
- <!-- stop.circle --> **Cancelled isn't an error.** A turn you stop in Cursor now reads as done.
- <!-- text.badge.star --> **What's New.** After an update, Muster shows what changed, once. It's also in the menu bar menu.

## 1.1.0 · 2026-10-12

Lighter, with costs you can trust and a 30-day usage view.

- <!-- chart.bar.xaxis --> **Usage window.** Choose Usage… in the menu bar menu to see 30 days of tokens and API-rate cost by day, model and project. It reads your transcripts only while the window is open.
- <!-- dollarsign.circle --> **Costs counted once.** A resumed Claude session no longer bills the history it copies, and subagent usage counts toward the session that started it. Rows read "≈ $41 API" so nobody mistakes them for a bill.
- <!-- leaf --> **Lighter.** Muster reads only what changed. With ten busy agents it averages about 0.4% of one core and about 20 MB of memory.
- <!-- checkmark.bubble --> **Answered elsewhere, gone here.** Answer a prompt in Claude's own dialog and Muster drops it right away.
- <!-- calendar --> **This week.** Settings counts the prompts you answered without switching and the jumps you made.
- <!-- lock.shield --> **Safer hooks.** Muster keeps your original settings file as `settings.json.muster-original`, leaves symlinks and permissions as they are, and redoes its edit if Claude writes the file at the same moment.

**Codex users:** in Settings, under "Answer prompts from Muster", turn Codex off and on once to pick up the shorter wait, then run `/hooks` in Codex to trust the updated hook.

## 1.0.0 · 2026-10-12

Every agent, one glance: a native Mac menu bar app for your Claude, Codex and Cursor sessions.

- <!-- bell.badge --> **See who needs you.** A glass alert at the top of the screen the moment an agent waits on you, plus a count in the menu bar.
- <!-- arrowshape.turn.up.left --> **Answer from anywhere.** Allow a command, pick an answer or approve a plan with ⌥↩, from the alert, the switcher or the notification.
- <!-- rectangle.stack --> **⌥Tab to any agent.** Most urgent first. Let go or click to land in its window, or the terminal it runs in.
- <!-- magnifyingglass --> **Find anything.** ⌃⌥Space searches every session.
- <!-- dollarsign.circle --> **Know what it costs.** Tokens and API-rate cost per session, priced per model and per message.
- <!-- hand.point.up.left --> **A tour you do, not read.** The first run finds your agents and has you try the switcher for real.
