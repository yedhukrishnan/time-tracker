# Time Tracker

A native macOS menu bar app for tracking work sessions, with per-session agenda,
post-session reflection (achievement + 1–5 star rating), work-hours nudges, and
iCloud sync. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the design rationale.

## What it does

- Lives in the **menu bar** (no Dock icon). Click to start/stop a session.
- **Agenda** captured at start; a **live timer** shows in the menu bar while running.
- On **stop**, prompts for what you got done and a 1–5 star rating.
- While you're **within work hours and not tracking**, it nudges you every N
  minutes (default 15) with a customizable message — with "Start tracking" and
  "Snooze 30 min" actions right on the notification.
- **History** window: past sessions grouped by day; everything editable after the
  fact; delete supported.
- **iCloud sync** of all data via CloudKit (private database).

## Requirements

- macOS 14 (Sonoma) or newer — driven by SwiftData.
- Xcode 16+.
- An Apple Developer account **only for the iCloud sync step**. The app runs and
  stores data locally without one.

## Build & run

The repo holds source + an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec
rather than a checked-in `.xcodeproj` (which is noisy and merge-hostile).

```bash
brew install xcodegen      # once
cd time-tracker
xcodegen generate          # creates TimeTracker.xcodeproj from project.yml
open TimeTracker.xcodeproj
```

Then in Xcode: select the **TimeTracker** scheme and press ⌘R.

### Signing (local, no paid account)

The default `TimeTracker.entitlements` is local-only (App Sandbox + network), so it
builds with a **free personal team**. In **Signing & Capabilities**, set Team to
your personal Apple ID and let Xcode sign automatically. iCloud and push
entitlements are intentionally *not* here — they require a paid account and would
otherwise fail with *"has entitlements that require signing with a developer
certificate."* The cloud version is preserved in `TimeTracker.cloud.entitlements`
for when you're ready (see below).

### No XcodeGen? Create the project by hand

1. Xcode → New → Project → macOS → App. Product name **TimeTracker**, interface
   **SwiftUI**, language **Swift**, storage **None**.
2. Delete the template's `ContentView.swift` and the generated `App` file.
3. Drag the contents of the `TimeTracker/` folder into the project (check
   "Copy items if needed" off if it's already in place; add to the TimeTracker target).
4. In the target's **Info** tab, add `Application is agent (UIElement) = YES`.
5. Point **Build Settings → Info.plist File** at `TimeTracker/Info.plist` and
   **Code Signing Entitlements** at `TimeTracker/TimeTracker.entitlements`.

## Enable iCloud sync

Sync is wired in code (`ModelConfiguration(..., cloudKitDatabase: .automatic)` —
which uses CloudKit when the entitlement is present and falls back to a local
store otherwise), but needs a **paid** account, project capabilities, and a
container:

0. Point the build's **Code Signing Entitlements** at
   `TimeTracker/TimeTracker.cloud.entitlements` (in `project.yml`, change
   `CODE_SIGN_ENTITLEMENTS`), and uncomment the `UIBackgroundModes` block in
   `Info.plist`.
1. Set your **Team** (Signing & Capabilities, or `DEVELOPMENT_TEAM` in `project.yml`).
2. Add the **iCloud** capability → check **CloudKit** → add a container, e.g.
   `iCloud.com.yedhu.TimeTracker`.
3. Add the **Background Modes** capability → check **Remote notifications**.
4. Make sure the container id matches the one in `TimeTracker.entitlements`.
5. Build, run, sign into iCloud on two Macs to see data mirror across them.

If sync silently doesn't work, it's almost always a mismatched container id or a
missing capability — check the CloudKit Dashboard.

## Change the bundle identifier

The placeholder is `com.yedhu.TimeTracker`. To change it, update all three:
`project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`), the `iCloud.<id>` strings in
`TimeTracker.entitlements`, and the CloudKit container in Xcode.

## Known limitations / next steps

- **Background execution isn't guaranteed.** Nudges won't fire while the Mac is
  asleep; the engine re-evaluates on wake. For a long-idle agent, macOS may
  throttle timers — acceptable for this use case.
- **Single-message nudges** for now; the architecture leaves room for a rotating
  message pool.
- **No edit audit log** — `modifiedAt` drives last-write-wins, which is enough
  for a personal tool.
- Add an app icon under `TimeTracker/Resources/Assets.xcassets` before shipping.

## Project layout

```
TimeTracker/
├── TimeTrackerApp.swift        # @main: MenuBarExtra + windows + ModelContainer
├── Info.plist / *.entitlements
├── Models/                     # TimeEntry, WorkSchedule, AppSettings
├── Services/                   # WorkHours, TrackingController, NudgeScheduler,
│                               #   LoginItem, AppModel (coordinator)
└── Views/                      # MenuBar popover, WrapUpForm, History, Settings,
                                #   Components/StarRating
```
