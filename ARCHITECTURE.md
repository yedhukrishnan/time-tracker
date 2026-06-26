# Time Tracker — Architecture Plan

A native macOS time-tracking app built as a menu bar agent, with iCloud sync and a nudge-notification engine.

> **Status:** design document, pre-implementation. One decision still open (see [§10](#10-open-decisions)). Everything else is settled enough to start building from.

---

## 1. Design goals

- **Frictionless capture.** Starting/stopping a session and answering "what did you do?" must take seconds, or the tool won't survive contact with a real workday.
- **Always resident.** The nudge feature (§5b) only works if the app is running, so the app is a background agent, not a windowed app you quit.
- **Single source of truth, synced.** SwiftData local store, mirrored to a private CloudKit database. No custom backup format.
- **Honest about constraints.** macOS gives you weak guarantees about background execution and notification delivery. The design works *with* those limits rather than pretending they don't exist (see [§7](#7-the-notification-engine-the-hard-part) and [§9](#9-risks--constraints)).

---

## 2. Form factor: menu bar agent

The app runs as an `LSUIElement` (a.k.a. "agent") — no Dock icon, no menu bar (the app menu), just a status-bar item. This is set in `Info.plist` with `Application is agent (UIElement) = YES`.

Why this matters for *your* feature set: the 15-minute nudge can only fire if the process is alive. A normal windowed app dies when the user hits ⌘Q. A status-bar agent stays running in the background indefinitely, which is exactly what a "remind me to track time" feature needs.

```
┌─ macOS status bar ──────────────────── ⏱ 00:42 ─┐   ← live timer when tracking
└─────────────────────────────────────────────────┘
                                          │ click
                                          ▼
                              ┌───────────────────────┐
                              │  ▶ Start session       │
                              │  Agenda: [__________]  │
                              │  ───────────────────   │
                              │  Today: 3h 12m         │
                              │  • 09:30 Standup  ★★★★ │
                              │  • 10:05 Spec     ★★★  │
                              │  ───────────────────   │
                              │  ⚙ Settings   History  │
                              └───────────────────────┘
```

Interaction model:
- **Status item** shows a live elapsed-time string while a session runs, and a neutral icon when idle.
- **Click** opens an `NSPopover` (or a SwiftUI `MenuBarExtra`, see below) for start/stop, today's sessions, and quick entry.
- **Settings** and **History** open as separate ordinary windows on demand (the agent can still open windows when needed).

### SwiftUI vs AppKit for the status item

`MenuBarExtra` (SwiftUI, macOS 13+) gives you the status item declaratively and is the least code. It's slightly limited for rich popovers and live-updating titles. The fallback is a small AppKit `NSStatusItem` + `NSPopover` hosting a SwiftUI view, which is more control for marginally more code.

**Recommendation:** start with `MenuBarExtra(.window)` and drop to `NSStatusItem` only if the live-timer title or popover behavior fights you.

---

## 3. Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Language / UI | Swift + SwiftUI | Native, modern, least code. |
| Status bar | `MenuBarExtra` → fallback `NSStatusItem` | §2. |
| Persistence | **SwiftData** | `@Model` classes, `ModelContainer`. |
| Sync | **CloudKit** (private DB) | One flag on the container. |
| Notifications | `UserNotifications` (`UNUserNotificationCenter`) | §5b, §7. |
| Launch at login | `SMAppService.mainApp` | So the agent is actually running when work starts. |
| Min OS | macOS 14 (Sonoma) | Driven by SwiftData. See §10. |

---

## 4. Data model

Four entities. All attributes are optional or defaulted, per the CloudKit constraint noted in the intro.

```
WorkSchedule        TimeEntry (a session)      AppSettings (singleton)
───────────         ─────────────────────      ──────────────────────
id                  id                         id
weekday (0–6)       agenda      : String       nudgeIntervalMinutes : Int = 15
startTime           startedAt   : Date         nudgeMessage         : String
endTime             endedAt     : Date?        nudgeEnabled         : Bool = true
isEnabled           achievement : String?      launchAtLogin        : Bool
                    rating      : Int?  (1–5)
                    createdAt   : Date
                    modifiedAt  : Date   ← for last-write-wins on edits (§5e)

NudgeMessage (optional, if you want a rotating pool instead of one string)
────────────
id
text
isActive
```

Notes on the model as an engineering artifact:

- **`TimeEntry` is the spine.** A session is "running" iff `endedAt == nil`. There should be at most one running entry at a time — enforce this in the app layer, because CloudKit won't enforce uniqueness for you.
- **`WorkSchedule` is per-weekday** so you can say "Mon–Fri 9–6, Sat off." A row per active weekday is simpler to reason about than a single blob with seven nested ranges.
- **`AppSettings` is a singleton row.** Fetch-or-create on launch. Storing it in SwiftData (rather than `UserDefaults`) means it syncs across your Macs via CloudKit — your customized nudge message follows you.
- **`rating` is `Int?`** — nil until the user rates. Don't default it to a number, or you can't tell "unrated" from "rated 0/1".
- **Derived values are not stored.** Duration = `endedAt − startedAt`, computed on read. Don't persist it; it's a denormalization waiting to drift.

---

## 5. Feature designs

### 5a. Entering work hours

A Settings pane with a row per weekday: an enable toggle and two time pickers (start/end). Persisted as `WorkSchedule` rows. "Work hours" is the union of enabled weekdays' ranges; it's the gate the nudge engine checks against (§5b/§7).

Edge cases to decide explicitly: overnight shifts (end < start), and whether a running session that crosses out of work hours should keep nudging (it shouldn't — nudges only fire when *not* tracking).

### 5b. The 15-minute nudge

Plain-English spec: *while it's currently within my work hours, and no session is running, remind me every N minutes (default 15) to start tracking, using a message I can customize.*

This is the hardest part of the app and gets its own section — see [§7](#7-the-notification-engine-the-hard-part). The customizable message reads from `AppSettings.nudgeMessage` (with a `%@`-style token if you want to interpolate, e.g. elapsed idle time).

### 5c. Session lifecycle: agenda → work → achievement + rating

```
   user clicks Start
        │
        ▼
   ┌─────────────┐   captures agenda (what you intend to do)
   │  RUNNING    │   status bar shows live timer; nudges suppressed
   └─────────────┘
        │ user clicks Stop
        ▼
   ┌─────────────┐   modal/popover prompts:
   │  WRAP-UP    │   • achievement: "what did you actually get done?"
   └─────────────┘   • rating: 1–5 stars
        │ save
        ▼
   entry has endedAt, achievement, rating → appears in History
```

The agenda is captured *before/at start* (intent); the achievement and rating *at stop* (reflection). Keep the wrap-up prompt skippable — a forced modal you can't dismiss is how people learn to resent their own tools — but nudge gently if left blank.

### 5d. iCloud sync

Not a manual "backup" — continuous sync of the SwiftData store to your **private** CloudKit database. Enabled by configuring the `ModelContainer` with a `cloudKitDatabase` option and adding the iCloud + CloudKit capability and a container identifier in entitlements.

What this gives you: data is on Apple's servers (covered by your iCloud backup) and mirrors across your signed-in Macs automatically. What you must design for: sync is **eventually consistent and offline-tolerant** — two devices can create entries while offline and reconcile later. Because there are no server-side unique constraints, your "only one running session" rule can briefly be violated across devices; resolve by treating the most recent `startedAt` as authoritative and auto-closing stragglers on sync.

There's no "restore from backup" button to build — reinstall, sign into iCloud, and the store repopulates.

### 5e. History window: reviewing and editing past days

The popover is the control surface; this is the **data surface** — a full, resizable, normal app window opened from the popover's "History" button. The agent keeps running in the background whether this window is open or closed.

```
┌─ History ─────────────────────────────────────── ⌕ ───┐
│  ◀ This week ▶        Filter: ★≥ [any ▾]  [all ▾]     │
│ ───────────────────────────────────────────────────── │
│  Thu Jun 25 ····························· 6h 40m  Σ     │
│   09:30–10:00  Standup            ★★★★☆   ✎  🗑        │
│   10:05–11:30  Spec draft         ★★★☆☆   ✎  🗑        │
│   ...                                                  │
│  Wed Jun 24 ····························· 5h 12m  Σ     │
│   ...                                                  │
└───────────────────────────────────────────────────────┘
```

- **Grouped by day**, newest first, with a per-day total. A date-range stepper (day / week / month) scopes the list; filters by minimum rating and by text.
- **Every field is editable after the fact** — agenda, achievement, rating, and the start/end times. Click a row to open the same `WrapUpView` in edit mode. This is the mutability decision: nothing locks once saved.
- **Delete** is per-session, with a confirm (it's destructive and syncs).

#### What mutability obligates in the model (the non-obvious part)

Allowing post-hoc edits isn't free — it interacts with sync and with the tracking invariant:

- **Add `modifiedAt: Date` to `TimeEntry`.** With CloudKit, the same session can be edited on two Macs while offline. There are no server-side merge rules, so resolve conflicts **last-write-wins by `modifiedAt`**. Without this field you can't tell which edit is newer, and sync silently picks one for you.
- **Guard the edit path against reopening a session.** Editing `endedAt` back to `nil` would resurrect a finished session and could create *two* running sessions, violating the "one running session" invariant (§5d). Either forbid clearing `endedAt` in the editor, or treat it as an explicit "resume" action that first stops any active session.
- **Editing times recomputes duration, not stores it.** Since duration is derived (§4), edits to `startedAt`/`endedAt` just flow through to totals — no denormalized field to keep in sync. This is the payoff for not storing duration.
- **No edit audit log.** For a personal tool, tracking *who changed what when* is overkill; `modifiedAt` is enough. Noting the call so it's a decision, not an omission.

---

## 6. Project structure

```
TimeTracker/
├── TimeTrackerApp.swift          // @main, MenuBarExtra, ModelContainer + CloudKit config
├── Info.plist                    // LSUIElement = YES
├── TimeTracker.entitlements      // iCloud, CloudKit container, App Sandbox
├── Models/
│   ├── TimeEntry.swift
│   ├── WorkSchedule.swift
│   ├── AppSettings.swift
│   └── NudgeMessage.swift
├── Services/
│   ├── TrackingController.swift  // start/stop, "one running session" invariant
│   ├── NudgeScheduler.swift      // the §7 engine
│   ├── WorkHours.swift           // "are we within work hours right now?"
│   └── LoginItem.swift           // SMAppService wrapper
├── Views/
│   ├── MenuBarContentView.swift  // the popover
│   ├── WrapUpView.swift          // achievement + star rating
│   ├── SettingsView.swift        // work hours, nudge message/interval, launch-at-login
│   ├── HistoryView.swift         // past sessions, edit/delete
│   └── Components/StarRating.swift
└── Resources/
```

---

## 7. The notification engine (the hard part)

### Why the naïve approach fails

The obvious idea — "schedule a repeating notification every 15 minutes" via `UNTimeIntervalNotificationTrigger(repeats: true)` — **does not work for this spec**, because a static repeating trigger can't know whether you're *currently tracking* or *currently within work hours*. It would nag you at 3 a.m. and while you're mid-session.

### The approach that works

Because the app is a resident agent (§2), you don't need the OS to schedule far-future notifications blindly. You run an **in-process scheduler** that holds at most one pending "nudge" notification and recomputes it whenever state changes.

State that triggers a recompute:
- a session **starts** → cancel any pending nudge (you're tracking now)
- a session **stops** → schedule the next nudge
- the **work-hours boundary** is crossed (start of day → begin nudging; end of day → stop)
- settings change (interval or enabled toggle)

Core logic, in pseudocode:

```
func reschedule():
    cancelPendingNudge()
    guard settings.nudgeEnabled else { return }
    guard noSessionRunning else { return }          // tracking ⇒ silence
    guard withinWorkHoursNow() else {
        scheduleWakeupAt(nextWorkHoursStart())       // re-evaluate at 9:00
        return
    }
    let fireAt = nextQuarterBoundary(from: now)      // or now + interval
    if fireAt <= todaysWorkHoursEnd:
        scheduleNudge(at: fireAt, body: settings.nudgeMessage)
    // when it fires, the notification handler calls reschedule() again → chain
```

Each fired nudge re-arms the next one, so you get a self-perpetuating chain that automatically stops when you start tracking or leave work hours. A lightweight repeating `Timer` (every 30–60 s) acts as a backstop to catch work-hours boundaries and clock changes.

### Delivery details

- **Authorization:** request `.alert + .sound` on first launch via `UNUserNotificationCenter`.
- **Foreground presentation:** implement `UNUserNotificationCenterDelegate.willPresent` to return `.banner` so nudges show even when the app is "active."
- **Actionable nudges:** add a "Start tracking" action button to the notification category, so the user can start a session straight from the banner without opening the popover.
- **Customizable message:** body = `AppSettings.nudgeMessage`. Optionally support a `%@` token (e.g. minutes idle) or a rotating pool via `NudgeMessage`.

---

## 8. Build phases

A suggested order that keeps you with a runnable app at every step:

1. **Skeleton.** `MenuBarExtra` agent that shows a static icon and an empty popover. Confirm it runs with no Dock icon.
2. **Tracking core.** `TimeEntry` model + `TrackingController`: start/stop, live timer in the status item, "one running session" invariant.
3. **Wrap-up.** Agenda on start; achievement + star rating on stop; History list.
4. **Work hours.** Settings pane + `WorkSchedule` + `WorkHours.withinWorkHoursNow()`.
5. **Nudge engine.** `NudgeScheduler` (§7), authorization, customizable message, actionable banner. *Test this hard — it's the subtle part.*
6. **iCloud.** Add CloudKit capability + entitlements; flip the container to sync; test on two Macs.
7. **Polish.** Launch-at-login, empty states, edit/delete history, clock-change/sleep handling.

---

## 9. Risks & constraints

- **Background execution isn't guaranteed.** macOS can deprioritize a long-idle agent, and notifications won't fire while the Mac is asleep. The nudge engine must re-evaluate on wake (`NSWorkspace.didWakeNotification`) and not assume timers fired on schedule.
- **CloudKit needs a paid Apple Developer account** and a provisioned container. Local-only SwiftData works without it, so build phases 1–5 need no account; only phase 6 does.
- **App Sandbox + entitlements** must be correct for CloudKit; misconfiguration fails silently (data just doesn't sync). Verify with the CloudKit Dashboard.
- **No server-side uniqueness** ⇒ the "single running session" rule is an app-layer invariant that can momentarily break across synced devices (§5d).
- **Notification fatigue** is a product risk, not a technical one: a 15-minute nag that can't be snoozed gets the app muted in System Settings, which silently kills the whole feature. Consider a "snooze 30 min" action.

---

## 10. Open decisions

1. **SwiftData vs Core Data** *(the one real fork).* Plan assumes SwiftData + CloudKit (macOS 14+). Switch to Core Data only if you need macOS 12–13 support; the rest of this design is unchanged either way.
2. **`MenuBarExtra` vs `NSStatusItem`** — start with the former, fall back if the live timer/popover fights you (§2). Low-stakes, reversible.
3. **Single nudge message vs rotating pool** — model supports both; ship single first.

---

## Appendix: how each of your requirements maps here

| Your requirement | Where it lives |
|---|---|
| Enter my work hours | §5a, `WorkSchedule`, Settings pane |
| Nudge every 15 min during work hours when not tracking, customizable | §5b + §7, `NudgeScheduler`, `AppSettings.nudgeMessage` |
| Agenda per tracked session | §5c, `TimeEntry.agenda` |
| Record achievement + 1–5 star rating on end | §5c, `TimeEntry.achievement` / `.rating`, `WrapUpView` |
| iCloud backup | §5d, SwiftData + CloudKit private DB |
