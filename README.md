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

Open the project and run it:

```bash
cd time-tracker
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

## Enable iCloud sync

Sync is wired in code (`ModelConfiguration(..., cloudKitDatabase: .automatic)` —
which uses CloudKit when the entitlement is present and falls back to a local
store otherwise), but needs a **paid** account plus capabilities, a container,
and a deployed schema:

1. Set your **Team** in **Signing & Capabilities**.
2. Add capabilities (Xcode writes the entitlements for you):
   - **iCloud** → check **CloudKit** → add container `iCloud.com.yedhu.TimeTracker`.
   - **Push Notifications** (adds `aps-environment`, for change pushes).

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

> `TimeTracker.cloud.entitlements` is a reference copy of the full entitlement
> set. Once you add the capabilities above, Xcode maintains the active
> `TimeTracker.entitlements`, so the cloud file is no longer wired into the build.

## Forking / building your own copy

This repo ships with the original author's Apple identifiers — bundle id
`com.yedhu.TimeTracker` and CloudKit container `iCloud.com.yedhu.TimeTracker`.
You **cannot** build or sign with those: Apple registers a bundle id and a
CloudKit container to a single developer account, so signing will reject them on
your machine. They aren't secrets (the shipped app contains the bundle id in
plain sight), and they expose no data — a CloudKit private database lives in each
user's own iCloud account. They're simply identity you must replace with your
own.

To build your own copy:

1. **Bundle id + team** — in **Signing & Capabilities**, change the Bundle
   Identifier to your own (e.g. `com.yourname.TimeTracker`) and set your
   Team. This alone is enough for the default local build.
2. **iCloud sync (optional)** — if you enable the cloud entitlements, also update
   the `iCloud.<id>` string in `TimeTracker.cloud.entitlements` to match your new
   bundle id, and create that container in your account via the iCloud capability
   / CloudKit Dashboard.

## Known limitations / next steps

- **Background execution isn't guaranteed.** Nudges won't fire while the Mac is
  asleep; the engine re-evaluates on wake. For a long-idle agent, macOS may
  throttle timers — acceptable for this use case.
- **Single-message nudges** for now; the architecture leaves room for a rotating
  message pool.
- **No edit audit log** — `modifiedAt` drives last-write-wins, which is enough
  for a personal tool.
- Add an app icon under `TimeTracker/Resources/Assets.xcassets` before shipping.

## Package a release (.dmg)

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

## License

Released under the [MIT License](LICENSE). © 2026 Yedhu Krishnan.

## Author

Yedhu Krishnan — dev@yedhu.me
