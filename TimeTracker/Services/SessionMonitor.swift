import Foundation
import AppKit
import CoreGraphics
import UserNotifications

/// Watches the *running* session — the mirror image of `NudgeScheduler`, which
/// watches the idle state. Two jobs:
///
/// 1. **Check-ins** — a "still working on this?" notification while a session
///    runs (customizable interval, off-switch in Settings). Like nudges, at most
///    one is live at a time: it fires, and if you leave it unread we stay quiet;
///    when you clear it (dismiss, tap, or an action) we arm the next one an
///    interval later. The single pending request is real (survives App Nap), and
///    the "one at a time" rule gates on a live delivered-notifications query, so
///    a missed dismiss callback self-heals on the next heartbeat.
///
/// 2. **Away detection** — the timer keeps running when you walk off, which is
///    the main way entries go bad. We watch for system sleep, screen lock, and
///    input idleness while tracking; when you come back after more than the
///    threshold, we prompt with three repairs: keep the time, subtract the away
///    window (fold it into `pausedSeconds`), or end the session at the moment
///    you left. Unlike a check-in, this fixes the data retroactively.
@MainActor
final class SessionMonitor {

    // Injected reads/actions — set by AppModel after wiring.
    var settingsProvider: () -> AppSettings? = { nil }
    /// The running entry, or nil when idle.
    var runningProvider: () -> TimeEntry? = { nil }
    var isPausedProvider: () -> Bool = { false }
    /// Fold N away seconds into the running entry's paused time.
    var onSubtractAway: (TimeInterval) -> Void = { _ in }
    /// End the running session with `endedAt` backdated to the given moment.
    var onStopBackdated: (Date) -> Void = { _ in }
    /// End the running session now (check-in "Stop session" action).
    var onStopRequested: () -> Void = {}

    private let center = UNUserNotificationCenter.current()

    // MARK: Check-in constants
    private let checkInCategoryID = "CHECKIN"
    private let stopActionID = "CHECKIN_STOP"
    private let checkInIDPrefix = "checkin."
    private var scheduledIDs: [String] = []

    // MARK: Away constants
    private let awayCategoryID = "AWAY"
    private let keepActionID = "AWAY_KEEP"
    private let subtractActionID = "AWAY_SUBTRACT"
    private let stopAtActionID = "AWAY_STOP_AT"
    private var poller: Timer?
    private var heartbeat: Timer?
    private let pollInterval: TimeInterval = 30
    /// When the current away period began (sleep/lock timestamp, or now − idle
    /// when detected by polling). nil ⇒ user is present.
    private var awayStart: Date?
    /// The away window awaiting the user's keep/subtract/end decision, plus the
    /// session it belongs to — so a prompt answered late can't repair a *newer*
    /// session it was never about.
    private var pendingAway: (entry: TimeEntry, start: Date, end: Date)?

    /// Call once at launch, after `router.start()`.
    func start(router: NotificationRouter) {
        registerCategories(with: router)

        // Clear check-ins left pending from a previous launch, then schedule
        // fresh (inside the completion, so there's no add/remove race).
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let stale = requests.map(\.identifier).filter { $0.hasPrefix(self.checkInIDPrefix) }
            Task { @MainActor in
                if !stale.isEmpty { self.center.removePendingNotificationRequests(withIdentifiers: stale) }
                self.reschedule()
            }
        }

        // Backstop: re-arm the next check-in after a missed dismiss event.
        // Cheap — reschedule() no-ops while a check-in is still unread.
        // Must not disturb a check-in that's already pending — re-arming here
        // would push it out a full interval every 5 min, so with any interval
        // over 5 min it would never fire.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reschedule(keepPending: true) }
        }

        // Sleep and screen lock are definitive "walked away" signals — record
        // the moment directly instead of waiting for the idle poll to notice.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.markAway(at: .now) }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateReturn()
                self?.reschedule(keepPending: true)
            }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.markAway(at: .now) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateReturn() }
        }
    }

    // MARK: - Scheduling (call on any state or settings change)

    /// Rebuild check-in notifications and start/stop the idle poller to match
    /// current state. Call on any state or settings change.
    ///
    /// `keepPending: true` (heartbeat / wake) is the backstop mode: if a
    /// check-in is already pending it's left untouched, and one is only armed
    /// when nothing is pending or unread. The default re-arms from scratch,
    /// which is what a state change (start, pause, interval edit) wants.
    func reschedule(keepPending: Bool = false) {
        if !keepPending { cancelPendingCheckIns() }

        let settings = settingsProvider()
        let entry = runningProvider()
        let activelyTracking = entry != nil && !isPausedProvider()

        // Idle poller runs only while actively tracking with detection enabled.
        // (A paused session isn't accumulating time, so away can't hurt it.)
        if activelyTracking && (settings?.idleDetectionEnabled ?? false) {
            startPollerIfNeeded()
        } else {
            stopPoller()
            awayStart = nil
        }

        // Check-ins: arm at most one, and only if none is already unread.
        guard let settings, settings.checkInEnabled, activelyTracking else {
            cancelPendingCheckIns()
            return
        }

        // Gate on the live pending + delivered sets: don't replace a pending
        // check-in (backstop mode) or stack one behind an unread banner. This
        // also self-heals a missed dismiss callback — once the banner is
        // cleared, a later reschedule() finds none and arms the next.
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }
            let hasPending = keepPending && pending.contains { $0.content.categoryIdentifier == self.checkInCategoryID }
            self.center.getDeliveredNotifications { delivered in
                let outstanding = delivered.contains { $0.request.content.categoryIdentifier == self.checkInCategoryID }
                Task { @MainActor in
                    guard !hasPending, !outstanding else { return }
                    self.armCheckIn()
                }
            }
        }
    }

    /// Schedule one check-in `interval` from now. Re-reads state through the
    /// providers — it runs after an async hop, so the session may have paused or
    /// ended. Cancels first so two racing reschedules can't leave two pending.
    private func armCheckIn() {
        cancelPendingCheckIns()
        guard let settings = settingsProvider(), settings.checkInEnabled,
              let entry = runningProvider(), !isPausedProvider() else { return }
        let interval = TimeInterval(max(1, settings.checkInIntervalMinutes) * 60)
        scheduleCheckIn(after: interval,
                        activeAtFire: entry.duration + interval,
                        agenda: entry.agenda)
    }

    // MARK: - Check-in plumbing

    private func scheduleCheckIn(after delay: TimeInterval, activeAtFire: TimeInterval, agenda: String) {
        guard delay > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Timer still running"
        content.body = agenda.isEmpty
            ? "You've been tracking for \(Self.formatMinutes(activeAtFire))."
            : "Still on “\(agenda)”? Tracking for \(Self.formatMinutes(activeAtFire))."
        content.sound = .default
        content.categoryIdentifier = checkInCategoryID
        let id = checkInIDPrefix + UUID().uuidString
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        scheduledIDs.append(id)
    }

    private func cancelPendingCheckIns() {
        guard !scheduledIDs.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: scheduledIDs)
        scheduledIDs.removeAll()
    }

    // MARK: - Away detection

    private func startPollerIfNeeded() {
        guard poller == nil else { return }
        poller = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollIdle() }
        }
    }

    private func stopPoller() {
        poller?.invalidate()
        poller = nil
    }

    private func pollIdle() {
        guard runningProvider() != nil, !isPausedProvider(),
              let settings = settingsProvider(), settings.idleDetectionEnabled else { return }
        let threshold = TimeInterval(max(1, settings.idleThresholdMinutes) * 60)
        let idle = Self.systemIdleSeconds()

        if awayStart == nil {
            if idle >= threshold {
                // Crossed the threshold: the away period began `idle` ago.
                awayStart = Date.now.addingTimeInterval(-idle)
            }
        } else if idle < pollInterval {
            // Fresh input after being away — the user is back.
            evaluateReturn(inputAge: idle)
        }
    }

    /// Mark the away start directly (sleep/lock — no need to wait for the poll).
    private func markAway(at date: Date) {
        guard runningProvider() != nil, !isPausedProvider(),
              settingsProvider()?.idleDetectionEnabled == true,
              awayStart == nil else { return }
        awayStart = date
    }

    /// The user is back. If the away window exceeds the threshold, offer repairs.
    private func evaluateReturn(inputAge: TimeInterval = 0) {
        guard let start = awayStart else { return }
        awayStart = nil
        guard let entry = runningProvider(), !isPausedProvider(),
              let settings = settingsProvider(), settings.idleDetectionEnabled else { return }

        let end = Date.now.addingTimeInterval(-inputAge)
        let away = end.timeIntervalSince(start)
        let threshold = TimeInterval(max(1, settings.idleThresholdMinutes) * 60)
        guard away >= threshold else { return }

        pendingAway = (entry, start, end)
        postAwayPrompt(away: away)
    }

    private func postAwayPrompt(away: TimeInterval) {
        let agenda = runningProvider()?.agenda ?? ""
        let content = UNMutableNotificationContent()
        content.title = "Welcome back — timer kept running"
        content.body = agenda.isEmpty
            ? "You were away \(Self.formatMinutes(away)). Keep that time?"
            : "Away \(Self.formatMinutes(away)) while tracking “\(agenda)”. Keep that time?"
        content.sound = .default
        content.categoryIdentifier = awayCategoryID
        // Fixed identifier: a newer away prompt replaces an unanswered older one.
        center.add(UNNotificationRequest(identifier: "away.prompt", content: content, trigger: nil))
    }

    // MARK: - Notification categories

    private func registerCategories(with router: NotificationRouter) {
        let stop = UNNotificationAction(identifier: stopActionID, title: "Stop session", options: [])
        let checkIn = UNNotificationCategory(identifier: checkInCategoryID,
                                             actions: [stop],
                                             intentIdentifiers: [],
                                             // Deliver explicit dismissals so we can arm the next check-in.
                                             options: [.customDismissAction])
        router.register(category: checkIn) { [weak self] action in
            guard let self else { return }
            // "Stop session" ends tracking (reschedule then no-ops). Any other
            // response — dismiss, tap, etc. — clears the banner, so arm the next
            // check-in an interval out.
            if action == self.stopActionID { self.onStopRequested() }
            self.reschedule()
        }

        let keep = UNNotificationAction(identifier: keepActionID, title: "Keep the time", options: [])
        let subtract = UNNotificationAction(identifier: subtractActionID, title: "Subtract away time", options: [])
        let stopAt = UNNotificationAction(identifier: stopAtActionID, title: "End session when I left", options: [])
        let awayCategory = UNNotificationCategory(identifier: awayCategoryID,
                                                  actions: [keep, subtract, stopAt],
                                                  intentIdentifiers: [],
                                                  options: [])
        router.register(category: awayCategory) { [weak self] action in
            guard let self else { return }
            defer { self.pendingAway = nil }
            guard let window = self.pendingAway,
                  window.entry === self.runningProvider() else { return }   // still the same session
            switch action {
            case self.subtractActionID:
                self.onSubtractAway(window.end.timeIntervalSince(window.start))
            case self.stopAtActionID:
                self.onStopBackdated(window.start)
            default:
                break   // keep, or a plain tap — leave the entry alone
            }
        }
    }

    // MARK: - Helpers

    /// Seconds since the user last touched the machine. Checked across the
    /// common input event types (the documented "any input" sentinel for
    /// `secondsSinceLastEventType` isn't exposed to Swift cleanly).
    private static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .otherMouseDown, .scrollWheel,
                                    .leftMouseDragged, .rightMouseDragged]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    private static func formatMinutes(_ interval: TimeInterval) -> String {
        let mins = Int((interval / 60).rounded())
        let h = mins / 60, m = mins % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(m) min"
    }
}
