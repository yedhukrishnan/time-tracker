import Foundation
import AppKit
import UserNotifications

/// The nudge engine (see ARCHITECTURE §7).
///
/// At most **one** nudge is ever live at a time — one pending request, or one
/// delivered banner the user hasn't cleared. We arm the next nudge only once the
/// previous one is gone: a nudge fires, and if the user leaves it sitting in
/// Notification Center we stay quiet; when they clear it (dismiss, tap, or an
/// action), we arm the next one `interval` later. So an ignored nudge doesn't
/// pile up behind more nudges.
///
/// The single nudge is still a real notification request (a UNTimeInterval
/// trigger), so it survives App Nap. Correctness of the "one at a time" rule
/// doesn't lean on the dismiss callback firing reliably: `reschedule()` gates on
/// a *live* `getDeliveredNotifications` query, and the periodic heartbeat re-runs
/// it — so a missed dismiss event self-heals within a heartbeat instead of
/// stalling the chain.
@MainActor
final class NudgeScheduler {

    // Injected reads — set by AppModel after wiring.
    var isTrackingProvider: () -> Bool = { false }
    var settingsProvider: () -> AppSettings? = { nil }
    var schedulesProvider: () -> [WorkSchedule] = { [] }
    /// Invoked when the user taps "Start tracking" on a nudge banner.
    var onStartRequested: () -> Void = {}

    private var heartbeat: Timer?
    private var snoozedUntil: Date?
    private var scheduledIDs: [String] = []

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "NUDGE"
    private let startActionID = "NUDGE_START"
    private let snoozeActionID = "NUDGE_SNOOZE"
    private let idPrefix = "nudge."
    private let snoozeDuration: TimeInterval = 30 * 60

    /// Call once at launch, after `router.start()`.
    func start(router: NotificationRouter) {
        registerCategory(with: router)

        // Clear nudges left pending from a previous launch, then schedule fresh
        // (inside the completion, so there's no add/remove race).
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let stale = requests.map(\.identifier).filter { $0.hasPrefix(self.idPrefix) }
            Task { @MainActor in
                if !stale.isEmpty { self.center.removePendingNotificationRequests(withIdentifiers: stale) }
                self.reschedule()
            }
        }

        // Backstop: re-arm after a missed dismiss event and catch work-hours
        // boundaries. Cheap — no-ops while a nudge is pending or unread. It must
        // not replace a pending nudge, or every heartbeat would push it out a
        // full interval and nudges longer than 5 min would never fire.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reschedule(keepPending: true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reschedule(keepPending: true) } }
    }

    /// Suppress nudges for `snoozeDuration`, then rebuild.
    func snooze() {
        snoozedUntil = Date.now.addingTimeInterval(snoozeDuration)
        reschedule()
    }

    // MARK: - Scheduling

    /// Arm the next nudge — but only if none is already live. Cancels our pending
    /// request, then checks whether a nudge is still sitting in Notification
    /// Center; if one is, we leave it and stay quiet (no stacking). Otherwise we
    /// schedule a single nudge `interval` out. Safe to call on any state change.
    ///
    /// `keepPending: true` (heartbeat / wake) is the backstop mode: an already
    /// pending nudge is left untouched rather than pushed back an interval.
    func reschedule(keepPending: Bool = false) {
        if !keepPending { cancelPending() }
        guard let settings = settingsProvider(), settings.nudgeEnabled,
              !isTrackingProvider(),                   // tracking (incl. paused) ⇒ silent
              !schedulesProvider().isEmpty else {
            cancelPending()
            return
        }

        // Gate on the live pending + delivered sets: don't replace a pending
        // nudge (backstop mode) or arm another while one is unread. This is also
        // what makes a missed dismiss callback self-heal — once the user clears
        // the banner, a later reschedule() finds none and re-arms.
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }
            let hasPending = keepPending && pending.contains { $0.content.categoryIdentifier == self.categoryID }
            self.center.getDeliveredNotifications { delivered in
                let outstanding = delivered.contains { $0.request.content.categoryIdentifier == self.categoryID }
                Task { @MainActor in
                    guard !hasPending, !outstanding else { return }
                    self.armNext()
                }
            }
        }
    }

    /// Schedule one nudge `interval` from now (or from the snooze floor), if that
    /// moment lands in work hours. Re-reads state through the providers — it runs
    /// after an async hop, so tracking/settings may have changed. Cancels first so
    /// two racing reschedules can't leave two pending requests.
    private func armNext() {
        cancelPending()
        guard let settings = settingsProvider(), settings.nudgeEnabled, !isTrackingProvider() else { return }
        let schedules = schedulesProvider()
        guard !schedules.isEmpty else { return }
        let interval = TimeInterval(max(1, settings.nudgeIntervalMinutes) * 60)
        let earliest = max(Date.now.addingTimeInterval(interval), snoozedUntil ?? .distantPast)
        guard WorkHours.isWithin(earliest, schedules: schedules) else { return }
        schedule(at: earliest, message: settings.nudgeMessage)
    }

    // MARK: - Notification plumbing

    private func schedule(at date: Date, message: String) {
        let delay = date.timeIntervalSinceNow
        guard delay > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Track your time"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = categoryID
        let id = idPrefix + UUID().uuidString
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        scheduledIDs.append(id)
    }

    /// Remove the nudges we scheduled (tracked by id, so we never touch anything
    /// else and avoid the async getPending race).
    private func cancelPending() {
        guard !scheduledIDs.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: scheduledIDs)
        scheduledIDs.removeAll()
    }

    private func registerCategory(with router: NotificationRouter) {
        let start = UNNotificationAction(identifier: startActionID, title: "Start tracking", options: [.foreground])
        let snooze = UNNotificationAction(identifier: snoozeActionID, title: "Snooze 30 min", options: [])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [start, snooze],
                                              intentIdentifiers: [],
                                              // Deliver explicit dismissals so we can arm the next nudge.
                                              options: [.customDismissAction])
        // Nudges are idle-only reminders — hush them at delivery time if a
        // session is somehow running (belt to cancellation's suspenders).
        router.register(category: category, suppressWhileTracking: true) { [weak self] action in
            guard let self else { return }
            // Any response clears the banner, so arm the next nudge afterward —
            // except when the response starts a session (then reschedule() no-ops
            // on the tracking guard anyway) or snoozes (which re-arms itself).
            switch action {
            case self.snoozeActionID:
                self.snooze()
            case self.startActionID, UNNotificationDefaultActionIdentifier:
                self.onStartRequested()
            default:                       // dismiss, or any other clear
                self.reschedule()
            }
        }
    }
}
