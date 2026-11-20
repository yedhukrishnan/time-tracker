# Time Tracker — Architecture

A native macOS time tracker built as a menu bar agent with a Spotlight-style
command panel, iCloud sync, and a one-at-a-time notification engine.

> **Status:** living document — describes the app **as built** (v0.1.3).
> Started life as the pre-implementation design doc; decisions that changed on
> contact with reality are noted where they matter, and unbuilt ideas live in
> [§10 Future work](#10-future-work).

---

## 1. Design goals

- **Frictionless capture.** Starting/stopping a session and answering "what
  did you do?" must take seconds, or the tool won't survive contact with a
  real workday. This goal is why the quick panel (§2a) exists and why it grew
  into the primary surface: a global hotkey plus typing beats mousing to the
  menu bar every time.
- **Always resident.** Nudges (§5b) only work if the app is running, so the
  app is a background agent, not a windowed app you quit.
- **Single source of truth, synced.** SwiftData local store, mirrored to a
  private CloudKit database. No custom backup format.
- **Honest about constraints.** macOS gives weak guarantees about background
  execution and notification delivery. The design works *with* those limits
  (see [§7](#7-the-notification-engine) and [§9](#9-risks--constraints)).
- **Adjustable intrusiveness.** Reminders are a dial, not a policy: every
  interval is tunable per task from the keyboard (`/nudge N`, `/check N`,
  `0` = off), because the right cadence depends on what you're doing.

---

## 2. Form factor: agent with three surfaces

The app runs as an `LSUIElement` agent — no Dock icon, just a status-bar item
(`Info.plist`: `Application is agent (UIElement) = YES`). A normal windowed
app dies at Cmd+Q; an agent stays resident, which the nudge engine requires.

The UI is split across three surfaces with distinct jobs:

| Surface | Job | Implementation |
|---|---|---|
| **Quick panel** | Keyboard-first *command surface* — every action on live state | Borderless `NSPanel` + SwiftUI (§2a) |
| **Menu bar popover** | Mouse/glance surface — status, today's list, buttons | `MenuBarExtra(.window)` |
| **History window** | Data surface — review and edit everything after the fact | SwiftUI `Window` scene (§5e) |

The corollary that keeps the panel honest: anything needing more than one
line of input or more than a handful of rows opens a window instead of
growing the panel (`/history`, `/settings`).

### 2a. The quick panel (command palette)

Summoned from any app by a global hotkey (default Cmd+Shift+Return, via the
`KeyboardShortcuts` package). Owned by `QuickPanelController`: a borderless,
**non-activating** `NSPanel`, so it takes key status (receives typing) without
activating the app — the frontmost app keeps focus visually and gets it back
the instant the panel closes. Click-outside dismisses via resign-key; the
panel auto-resizes with its SwiftUI content (`NSHostingView.sizingOptions =
.preferredContentSize`) anchored to a fixed top edge, so it grows downward
like Spotlight.

Interaction grammar (`QuickPanelView`):

- **Bare text + Return** starts a session — or *switches task* if one is
  running (old session stops without wrap-up; annotate it later in History).
- **`/` enters command mode**: a prefix-filtered suggestion list, Up/Down to
  select, Tab to complete, Return to run. Commands are context-filtered —
  `/stop`, `/pause`/`/resume`, `/edit` only exist while tracking; `/start`
  only while idle. That's also what makes the `/s` alias safe: it resolves to
  start when idle and stop when running, and the two never coexist.
- **`/stop` flows into an inline wrap-up**: summary line, Return, then a 1–5
  rating previewed as filled stars and saved on Return. Esc skips either step.
- **Esc backs out one level**: clear the text, then close; cancel edit mode;
  skip wrap-up.

Two mechanisms worth knowing because they're non-obvious:

- **Keyboard shortcuts without focus.** In the rating step no text field is
  focused, so bare digit keys are carried by zero-size hidden buttons with
  `.keyboardShortcut(_, modifiers: [])` — SwiftUI resolves those at the
  key-window level, which is more reliable than `.onKeyPress` on unfocused
  views. The same trick carried the old P/S keys before commands existed.
- **Opening windows from outside a scene.** The panel is hosted in an
  `NSPanel`, outside any SwiftUI scene, so it can't read `\.openWindow` or
  `\.openSettings`. An invisible `OpenWindowBridge` view in the status-item
  label (the one SwiftUI view alive for the app's whole lifetime) captures
  both actions once and stores them on `AppModel`.

---

## 3. Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Language / UI | Swift + SwiftUI | Native, least code. |
| Status bar | `MenuBarExtra(.window)` | The designed `NSStatusItem` fallback was never needed. |
| Quick panel | AppKit `NSPanel` + `NSHostingView` | SwiftUI alone can't make a non-activating floating panel. |
| Global hotkey | [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) | Recorder UI in Settings → General. |
| Persistence | **SwiftData** | `@Model` classes; decided over Core Data (macOS 14+ accepted). |
| Sync | **CloudKit** (private DB) | `ModelConfiguration(cloudKitDatabase: .automatic)`. |
| Notifications | `UserNotifications` | §7. |
| Launch at login | `SMAppService.mainApp` | Wrapped in `LoginItem`. |
| Min OS | macOS 14 (Sonoma) | Driven by SwiftData. |

---

## 4. Data model

Three entities, all in the schema; every stored property is optional or
defaulted (CloudKit mirroring rejects required attributes without defaults).

```
WorkSchedule                TimeEntry (a session)         AppSettings (singleton)
────────────                ─────────────────────         ───────────────────────
weekday (1=Sun…7=Sat)       agenda        : String        nudgeIntervalMinutes  = 15
startMinutes : Int          startedAt     : Date          nudgeMessage          : String
endMinutes   : Int          endedAt       : Date?         nudgeEnabled          = true
isEnabled    : Bool         achievement   : String?       checkInEnabled        = false
createdAt    : Date         rating        : Int? (1–5)    checkInIntervalMinutes = 15
                            createdAt     : Date          idleDetectionEnabled  = true
                            pausedSeconds : Double        idleThresholdMinutes  = 5
                            pauseStartedAt: Date?         launchAtLogin         = false
                            modifiedAt    : Date          createdAt             : Date
```

Notes on the model as an engineering artifact:

- **`TimeEntry` is the spine.** A session is "running" iff `endedAt == nil`,
  and *paused* iff running with `pauseStartedAt != nil`. At most one entry
  runs at a time — an app-layer invariant (§8), because CloudKit can't
  enforce uniqueness.
- **Pause is two fields, not a state enum.** `pausedSeconds` accumulates
  completed pauses; `pauseStartedAt` marks an open one. Active duration =
  wall-clock span − paused time, computed on read. Deliberately not stored —
  a denormalized duration is drift waiting to happen, and it's why editing
  start/end times in History "just works".
- **Times as minutes-from-midnight** in `WorkSchedule` (not `Date`): the
  schedule recurs, and a wall-clock date carries irrelevant day/month/zone
  baggage. Overnight windows (end ≤ start) are supported (`WorkHours`).
- **`AppSettings` is a singleton row** in SwiftData (not `UserDefaults`) so
  settings sync across Macs. Fetch-or-create on launch; sync can create
  duplicates, collapsed by keeping the earliest `createdAt` (a stable key
  both devices agree on, so they converge).
- **`rating` is `Int?`** — nil means unrated; never default it to a number.
- **`modifiedAt` + `touch()`** drive last-write-wins conflict resolution for
  offline edits on two devices (§5e).
- The designed `NudgeMessage` entity (rotating message pool) was **not
  built**; a single customizable string shipped instead (§10).

---

## 5. Feature designs

### 5a. Work hours

Settings pane with a row per weekday: enable toggle + start/end time pickers,
persisted as `WorkSchedule` rows (all seven rows exist; Sat/Sun created
disabled). "Within work hours" is a pure function (`WorkHours.isWithin`) —
stateless, testable, and the gate the nudge engine checks. Overnight windows
are handled by checking both the day a window starts and the tail it spills
into.

### 5b. Nudges (idle reminders)

*While within work hours and no session is running, remind me every N minutes
(default 15) with a message I can customize.* Notification carries "Start
tracking" and "Snooze 30 min" actions. Tunable from the panel: `/nudge N`,
`/nudge 0` to disable (the stored interval survives disabling, so re-enabling
restores the old cadence). Engine in §7.

### 5c. Session lifecycle

```
  bare text ⏎ in panel (or popover Start)
       │
       ▼
  ┌─────────────┐  agenda captured at start (intent);
  │  RUNNING    │  live timer in status bar; nudges silent;
  │  ⇄ PAUSED   │  /pause⇄/resume freezes active time;
  └─────────────┘  /edit renames mid-flight
       │ /stop (panel) or Stop (popover)
       ▼
  ┌─────────────┐  panel: summary ⏎ → rating 1–5 ⏎  (Esc skips)
  │  WRAP-UP    │  popover: WrapUpForm (achievement + stars)
  └─────────────┘
       │
       ▼
  entry complete → History
```

Agenda before (intent), achievement + rating after (reflection). Wrap-up is
**skippable everywhere** — a forced modal breeds resentment — and every field
is editable later, so skipping never loses data. Typing bare text while
running is a deliberate *task switch*: the old session stops (no wrap-up),
the new one starts.

### 5d. Check-ins and away detection (`SessionMonitor`)

The mirror image of nudges: nudges watch the *idle* state, `SessionMonitor`
watches the *running* state, because a forgotten timer corrupts data as
surely as an untracked hour.

- **Check-ins** — optional "still working on this?" notification every N
  minutes of *active* tracked time (off by default; `/check N` from the
  panel, `0` disables). Like nudges, at most one is live at a time: the next
  is armed an interval out only after the previous banner is cleared (§7).
  Carries a "Stop session" action.
- **Away detection** — sleep, screen lock, and an input-idle poll (30 s,
  `CGEventSource.secondsSinceLastEventType`) mark when you left. On return
  past the threshold (default 5 min), a notification offers three repairs:
  **keep** the time, **subtract** it (fold into `pausedSeconds`), or **end
  the session when you left** (backdated stop, clamped to the session span).
  Unlike a check-in, this fixes the data retroactively. The pending prompt
  remembers *which entry* it was about, so answering late can't repair a
  newer session.

### 5e. iCloud sync

Continuous mirroring of the SwiftData store to the **private** CloudKit
database — not a manual backup. Sync is eventually consistent and
offline-tolerant, which shapes three pieces of code:

- **Last-write-wins by `modifiedAt`** for concurrent edits (no server-side
  merge rules exist).
- **Duplicate-singleton collapse** for `AppSettings` and per-weekday
  `WorkSchedule` rows (keep earliest `createdAt`; both devices converge).
- **Running-session recovery** at launch: if sync (or a crash) left several
  entries with `endedAt == nil`, keep the newest and zero-length-close the
  rest.

There is no restore button to build: reinstall, sign into iCloud, the store
repopulates. Setup mechanics live in [`BUILDING.md`](BUILDING.md).

### 5f. History window

The data surface: sessions grouped by day (newest first) with per-day totals,
text search, a minimum-rating filter, hover-to-delete with confirmation, and
click-to-edit of **every** field — agenda, achievement, rating, start/end
times — via `WrapUpForm` in edit mode. Nothing locks once saved; that
mutability is what `modifiedAt` and the §5e rules pay for. The edit form
never allows clearing `endedAt`, so an edit can't resurrect a finished
session and violate the single-running-session invariant.

Rendering is `LazyVStack` with pinned day headers over an unbounded `@Query`;
fine at personal scale, and the known scaling fix (date-range scoping) is
future work (§10).

---

## 6. Project structure

```
TimeTracker/
├── TimeTrackerApp.swift          // @main: single-instance guard, MenuBarExtra,
│                                 //   History window + Settings scenes,
│                                 //   ModelContainer, OpenWindowBridge
├── Info.plist                    // LSUIElement = YES
├── TimeTracker.entitlements      // App Sandbox, iCloud/CloudKit, push
├── Models/
│   ├── TimeEntry.swift
│   ├── WorkSchedule.swift
│   └── AppSettings.swift
├── Services/
│   ├── AppModel.swift            // coordinator: owns the services, wires them,
│   │                             //   settings singleton, panel command setters
│   ├── TrackingController.swift  // start/stop/pause/rename, elapsed ticker,
│   │                             //   "one running session" invariant, recovery
│   ├── NudgeScheduler.swift      // idle-state engine (§7)
│   ├── SessionMonitor.swift      // running-state engine: check-ins + away (§5d)
│   ├── NotificationRouter.swift  // single UNUserNotificationCenter owner (§7)
│   ├── QuickPanelController.swift// hotkey, NSPanel lifecycle, sizing/anchoring
│   ├── WorkHours.swift           // pure "within work hours?" predicate
│   └── LoginItem.swift           // SMAppService wrapper
└── Views/
    ├── QuickPanelView.swift      // the command palette (§2a)
    ├── MenuBarContentView.swift  // the popover
    ├── WrapUpForm.swift          // quick wrap-up (popover) + full edit (History)
    ├── SettingsView.swift        // work hours, nudge, session, general, about
    ├── HistoryView.swift         // §5f
    └── Components/StarRating.swift
```

---

## 7. The notification engine

### Why the naïve approach fails

"Schedule a repeating notification every 15 minutes"
(`UNTimeIntervalNotificationTrigger(repeats: true)`) can't work: a static
repeating trigger doesn't know whether you're currently tracking or within
work hours. It would nag at 3 a.m. and mid-session.

### The approach that works

Schedule the next notification as a **real one-shot request**, and
cancel/re-arm it whenever state changes. The OS delivers a scheduled
notification even if the app is suspended by **App Nap**; an in-process timer
would stall. (An earlier design fired nudges from a 30 s heartbeat — rejected
for exactly that reason.)

**At most one live notification per engine.** Each engine keeps either one
pending request or one delivered-but-unread banner, never more. When it fires
and you ignore it, the engine stays quiet; when you clear it (dismiss, tap, or
an action), the next one is armed `interval` later. Ignored reminders don't
stack up behind more reminders. (Through v0.1.3 both engines pre-scheduled a
grid of future requests — up to 32 nudges and 16 check-ins — which is exactly
what let unread banners pile up.)

How a re-arm works (`NudgeScheduler.reschedule()` /
`SessionMonitor.reschedule()`):

1. Cancel the engine's own pending request.
2. Bail if the feature is off or the state is wrong (nudges: tracking, incl.
   paused, or no work hours; check-ins: not actively tracking).
3. Query `getDeliveredNotifications`; if a banner of this engine's category
   is still sitting in Notification Center, stop — don't arm another.
4. Otherwise arm one request after the async hop (`armNext()` /
   `armCheckIn()`), re-reading state and cancelling again first so two racing
   reschedules can't leave two pending. Nudges fire at
   `max(now + interval, snoozedUntil)` and only if that lands in work hours;
   check-ins fire `interval` of active time from now.

Re-arm triggers: session start/stop/pause/resume (via
`TrackingController.onChange`), settings or work-hours edits, snooze, wake
from sleep, any response to the engine's notification — categories use
`.customDismissAction` so an explicit dismiss is delivered too — plus a
5-minute heartbeat. The rule gates on the *live* delivered set rather than on
the dismiss callback, so a missed callback (e.g. a banner cleared in bulk)
self-heals within a heartbeat instead of stalling the chain.

Both engines track their scheduled ids and only ever cancel those, so they
can't clobber each other — or anything else.

### One router, two engines

`UNUserNotificationCenter` has exactly one delegate and one category set,
both clobber-on-write — so with two schedulers, neither may own them.
`NotificationRouter` owns both: engines register a category plus an action
handler, and the router aggregates categories and dispatches responses by
`categoryIdentifier`. It also presents banners while the app is "active" (an
agent usually is; without this, notifications are silently swallowed).

At delivery time (`willPresent`) the router applies two policies:

- **Tracking guard.** A category registered with
  `suppressWhileTracking: true` (nudges) is withheld if a session is running,
  via an `isTrackingProvider` wired by `AppModel`. This is the only check
  that runs at the moment of delivery, so it closes the race cancellation
  can't — a nudge whose trigger elapses just as tracking begins.
- **Sweep.** A banner that actually presents clears every *other* delivered
  notification, across all categories, so stale banners don't linger. A
  withheld banner doesn't sweep.

---

## 8. Invariants (enforced, not assumed)

- **One running session** (`endedAt == nil` unique). Enforced by
  `TrackingController` (start stops any current session first), by launch
  recovery (§5e), and by the History editor refusing to clear `endedAt`.
- **One process per store.** Two instances sharing the SQLite store crash
  Core Data unrecoverably (observed: login-item copy + a second launch). A
  guard at the very top of `TimeTrackerApp.init` — before the
  `ModelContainer` opens the store — finds any other instance of the bundle
  id via `NSRunningApplication`, yields to it, and exits.
- **One notification owner.** All `UNUserNotificationCenter` delegate and
  category traffic goes through `NotificationRouter` (§7).
- **Settings ranges agree across surfaces.** The panel's `/nudge` and
  `/check` clamp to the same ranges as the Settings steppers (1–120 and
  1–180 minutes), so the two surfaces can't disagree.

---

## 9. Risks & constraints

- **Background execution isn't guaranteed.** Real scheduled requests (§7)
  survive App Nap, but nothing fires while the Mac is fully asleep — both engines
  re-evaluate on `NSWorkspace.didWakeNotification`.
- **No server-side uniqueness** ⇒ the single-running-session rule can
  momentarily break across synced devices; resolved at launch recovery and by
  last-write-wins (§5e).
- **Notification fatigue is a product risk**, not a technical one: a nag that
  can't be silenced gets the app muted in System Settings, which kills the
  whole feature. Hence: snooze on every nudge, check-ins off by default, and
  `0`-to-disable one keystroke away in the panel.
- **CloudKit needs a paid developer account** and correct entitlements;
  misconfiguration fails *silently*. Mechanics in [`BUILDING.md`](BUILDING.md).
- **History loads unbounded data** (§5f) — acceptable at personal scale,
  listed as future work.

---

## 10. Future work

Designed or identified, deliberately not built yet:

1. **History date-range scoping** — the originally-designed day/week/month
   stepper. Bounds the `@Query` instead of loading every entry ever; the
   principled fix for History performance at scale.
2. **Rotating nudge-message pool** — the unbuilt `NudgeMessage` entity; a
   single customizable string shipped instead.
3. **No edit audit log** — a decision, not an omission: `modifiedAt`
   last-write-wins is enough for a personal tool.
