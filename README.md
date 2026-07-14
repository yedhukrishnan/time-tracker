# Time Tracker

A keyboard-first time tracker for macOS. It lives in your menu bar, and you
drive it like Spotlight: one global hotkey, type what you're working on, hit
return. Everything else — stopping, pausing, renaming, retuning reminders —
is a slash command away.

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
everything is
editable later from History, so a skipped rating is never lost data.

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

## Install

Requires macOS 14 (Sonoma) or newer. Grab the `.dmg` from
[Releases](https://github.com/yedhukrishnan/mac-simple-time-tracker/releases),
drag the app to Applications, and enable **Launch at login** in Settings so
nudges are alive when your workday starts. Or build from source, below.

---

## Building from source

Developer-facing from here down. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for
the design rationale.

### Requirements

- macOS 14 (Sonoma) or newer — driven by SwiftData.
- Xcode 16+.
- A **paid Apple Developer account**. `TimeTracker.entitlements` ships with
  iCloud + Push already enabled, so even a local debug build needs a Developer
  Program team to sign — see "Signing" below if you'd rather build without one.

### Build & run

```bash
cd time-tracker
open TimeTracker.xcodeproj
```

Then in Xcode: select the **TimeTracker** scheme and press Cmd+R.

### Signing

`TimeTracker.entitlements` ships with iCloud + Push Notifications already
enabled (App Sandbox, network, CloudKit, `aps-environment`). That means **a
paid Apple Developer account is required even for a local debug build** — a
free personal team can't sign entitlements that request iCloud/push and will
fail with *"has entitlements that require signing with a developer
certificate."*

In **Signing & Capabilities**, set Team to your Developer Program account and
let Xcode sign automatically. See "iCloud sync" below for the container setup
that goes with it.

If you'd rather build without a paid account, strip the
`com.apple.developer.icloud-*` and `aps-environment` keys from
`TimeTracker.entitlements` — the app falls back to a local-only SwiftData store
when the entitlement isn't present.

### iCloud sync

Sync is wired in code (`ModelConfiguration(..., cloudKitDatabase: .automatic)` —
which uses CloudKit when the entitlement is present and falls back to a local
store otherwise). The entitlements are already declared in
`TimeTracker.entitlements`, but the container and schema still need to exist
under **your** Apple Developer account:

1. Set your **Team** in **Signing & Capabilities** to a paid Developer Program
   account (see "Signing" above).
2. Confirm iCloud → CloudKit and Push Notifications show up in **Signing &
   Capabilities** (Xcode reads them from the committed entitlements) and that
   the container `iCloud.com.yedhu.TimeTracker` resolves under your account.
   If you're forking this repo, change that container id first — see
   "Forking" below.

   That's the full macOS set. The iOS "Background Modes → Remote notifications"
   mode does **not** apply to macOS — CloudKit push here comes from the Push
   Notifications capability.
3. **Deploy the schema to Production.** A debug build uses the CloudKit
   *Development* environment; a notarized Developer ID build uses *Production*.
   In the CloudKit Dashboard, promote your schema from Development → Production,
   or release builds sync nothing while your dev build works fine.
4. Build, run, sign into iCloud on two Macs to see data mirror across them.

If sync silently does nothing, the usual causes are: schema not deployed to
Production, a mismatched container id, or a missing capability — check the
CloudKit Dashboard.

> `TimeTracker.cloud.entitlements` is currently identical to the active
> `TimeTracker.entitlements` — a leftover reference file from when cloud
> entitlements were opt-in. Worth deleting if it's no longer serving a purpose.

### Forking / building your own copy

This repo ships with the original author's Apple identifiers — bundle id
`com.yedhu.TimeTracker` and CloudKit container `iCloud.com.yedhu.TimeTracker` —
baked into the committed `TimeTracker.entitlements`. You **cannot** build or
sign with those: Apple registers a bundle id and a CloudKit container to a
single developer account, so Xcode will fail to provision them on your
machine. They aren't secrets (the shipped app contains the bundle id in plain
sight), and they expose no data — a CloudKit private database lives in each
user's own iCloud account. They're simply identity you must replace with your
own.

To build your own copy:

1. **Bundle id + team** — in **Signing & Capabilities**, change the Bundle
   Identifier to your own (e.g. `com.yourname.TimeTracker`) and set your Team
   to a paid Developer Program account.
2. **iCloud container** — update the `iCloud.<id>` string in
   `TimeTracker.entitlements` to match your new bundle id, and create that
   container in your account via the iCloud capability / CloudKit Dashboard
   (see "iCloud sync" above).

### Known limitations / next steps

- **Background execution isn't guaranteed.** Nudges won't fire while the Mac is
  asleep; the engine re-evaluates on wake. For a long-idle agent, macOS may
  throttle timers — acceptable for this use case.
- **Single-message nudges** for now; the architecture leaves room for a rotating
  message pool.
- **No edit audit log** — `modifiedAt` drives last-write-wins, which is enough
  for a personal tool.

### Package a release (.dmg)

On macOS with Xcode installed, from the repo root:

```bash
./scripts/build-dmg.sh           # → dist/TimeTracker.dmg
```

This builds the Release configuration and packages the app into a drag-to-install
disk image. The default build runs on **your** Mac but Gatekeeper will block it on
others. To distribute, sign and notarize with a paid Apple Developer account:

```bash
DEVELOPER_ID="Developer ID Application: Yedhu Krishnan (TEAMID)" ./scripts/build-dmg.sh
xcrun notarytool submit dist/TimeTracker.dmg \
  --apple-id <id> --team-id <TEAMID> --password <app-specific-pw> --wait
xcrun stapler staple dist/TimeTracker.dmg
```

### Project layout

```
TimeTracker/
├── TimeTrackerApp.swift        # @main: MenuBarExtra + windows + ModelContainer
├── Info.plist / *.entitlements
├── Models/                     # TimeEntry, WorkSchedule, AppSettings
├── Services/                   # WorkHours, TrackingController, NudgeScheduler,
│                               #   SessionMonitor, QuickPanelController, AppModel
└── Views/                      # QuickPanel, MenuBar popover, WrapUpForm,
                                #   History, Settings, Components/StarRating
```

## License

Released under the [MIT License](LICENSE). © 2026 Yedhu Krishnan.

## Author

Yedhu Krishnan — dev@yedhu.me
