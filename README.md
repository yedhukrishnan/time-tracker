# Time Tracker

A keyboard-first time tracker for macOS. It lives in your menu bar, and you
drive it like Spotlight: one global hotkey, type what you're working on, hit
return. Everything else — stopping, pausing, renaming, retuning reminders —
is a slash command away.

## Install

Requires macOS 14 (Sonoma) or newer. Grab the `.dmg` from
[Releases](https://github.com/yedhukrishnan/mac-simple-time-tracker/releases),
drag the app to Applications, and enable **Launch at login** in Settings so
nudges are alive when your workday starts. Or [build from
source](BUILDING.md).

## The quick panel

Press **Cmd+Shift+Return** from any app (customizable in Settings) and the
panel appears:

- **Type what you're working on, press Return** — session started. Do the
  same mid-session to switch tasks in one stroke.
- **Type `/`** to see commands, filtered as you type. Up/Down to select, Tab
  to complete, Return to run:

| Command | Alias | What it does |
|---|---|---|
| `/start <agenda>` | `/s` | Start a session |
| `/stop` | `/s` | Stop the session, then wrap up |
| `/pause`, `/resume` | `/p`, `/r` | Pause / resume |
| `/edit` | `/e` | Rename the current session |
| `/nudge N` | `/n` | Remind me to track every N minutes (`0` = off) |
| `/check N` | `/c` | Check in on a running session every N minutes (`0` = off) |
| `/history` | | Open the History window |
| `/settings` | | Open Settings |

Esc always backs out one level: clear what you typed, then close the panel.

## As gentle or as relentless as you want

Two kinds of reminders, both tunable on the fly from the keyboard:

- **Nudges** keep you tracking. During your work hours (set per weekday in
  Settings), if no session is running, the app reminds you every N minutes
  (default 15) with a message you can customize — and a "Start tracking"
  button right on the notification. Deep-work day? `/n 60`. Don't want to be
  bothered at all? `/n 0`.
- **Check-ins** keep the timer honest. While a session runs, an optional
  "still working on this?" ping every N minutes catches the timer you forgot
  to stop. Off by default; `/c 15` turns it on. Triaging email and prone to
  drifting? `/c 5`.

The point of putting these behind two-keystroke commands: the right interval
depends on the task, so you can retune it every time you switch, not once in
a settings pane you'll never reopen.

There's also **away detection** — if you walk off (or the Mac sleeps) with the
timer running, the app notices when you return and offers to keep the time,
subtract it, or end the session at the moment you left.

## Reflect when you stop

Stopping a session flows straight into a two-step wrap-up, still all-keyboard:
type a line about what you actually got done, press Return, then rate it 1–5
with the number keys, Return to save. Both steps are skippable (Esc) — and
everything is editable later from History, so a skipped rating is never lost
data.

## History

A full window (`/history`) with every session grouped by day: per-day totals,
search, a minimum-rating filter, and after-the-fact editing of any field —
agenda, summary, rating, even the start/end times.

## The menu bar, for mouse moments

The status item shows a live timer while tracking. Clicking it opens a
popover with start/stop buttons, today's sessions and total — everything the
panel does, for the moments your hand is already on the mouse.

## Your data

Stored locally in a SwiftData database, synced through your **private**
CloudKit database when iCloud is available — your sessions and settings
follow you across Macs, and nothing is ever sent anywhere else.

## Building from source

Developer documentation — requirements, signing, iCloud/CloudKit setup,
forking, and packaging a release — lives in [`BUILDING.md`](BUILDING.md).
For the design rationale, see [`ARCHITECTURE.md`](ARCHITECTURE.md).

## License

Released under the [MIT License](LICENSE). © 2026 Yedhu Krishnan.

## Author

Yedhu Krishnan — dev@yedhu.me
