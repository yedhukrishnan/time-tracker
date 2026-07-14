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
- A **paid Apple Developer account**. `TimeTracker.entitlements` ships with
  iCloud + Push already enabled, so even a local debug build needs a Developer
  Program team to sign — see "Signing" below if you'd rather build without one.

## Build & run

Open the project and run it:

```bash
cd time-tracker
open TimeTracker.xcodeproj
```

Then in Xcode: select the **TimeTracker** scheme and press ⌘R.

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

## iCloud sync

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

## Forking / building your own copy

This repo ships with the original author's Apple identifiers — bundle id
`com.yedhu.TimeTracker` and CloudKit container `iCloud.com.yedhu.TimeTracker` —
baked into the committed `TimeTracker.entitlements`. You **cannot** build or
sign with those: Apple registers a bundle id and a CloudKit container to a
single developer account, so Xcode will fail to provision them on your
machine. They aren't secrets (the shipped app contains the bundle id in plain
sight), and they expose no data — a CloudKit private database lives in each
user's own iCloud account. They're simply identity you must replace with your
own. And because the entitlements request iCloud + Push by default, you'll
need a **paid Apple Developer account** to get even a first build signed (see
"Signing" above).

To build your own copy:

1. **Bundle id + team** — in **Signing & Capabilities**, change the Bundle
   Identifier to your own (e.g. `com.yourname.TimeTracker`) and set your Team
   to a paid Developer Program account.
2. **iCloud container** — update the `iCloud.<id>` string in
   `TimeTracker.entitlements` to match your new bundle id, and create that
   container in your account via the iCloud capability / CloudKit Dashboard
   (see "iCloud sync" above). This isn't optional anymore — Xcode won't sign
   the app with someone else's container id.

## Known limitations / next steps

- **Background execution isn't guaranteed.** Nudges won't fire while the Mac is
  asleep; the engine re-evaluates on wake. For a long-idle agent, macOS may
  throttle timers — acceptable for this use case.
- **Single-message nudges** for now; the architecture leaves room for a rotating
  message pool.
- **No edit audit log** — `modifiedAt` drives last-write-wins, which is enough
  for a personal tool.

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
