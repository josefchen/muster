# Changelog

What changed in each release of Muster, newest first. The app shows the latest one after you update, and every release is also at [agentmuster.app/changelog](https://agentmuster.app/changelog).

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
