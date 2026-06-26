import Foundation
import AppKit
import UserNotifications

/// The nudge engine (see ARCHITECTURE §7).
///
/// Nudges are *pre-scheduled* as real notification requests (UNTimeInterval
/// triggers) rather than posted from an in-process timer. This makes them robust
/// to App Nap, which can suspend a menu bar agent and would stall a polling timer:
/// the OS still delivers a scheduled notification while the app is napped.
///
/// We cancel and rebuild the schedule whenever state changes (tracking
/// start/stop/pause, settings or work-hours edits, snooze, wake) plus periodically
/// as a backstop to extend coverage. Fire times are aligned to a fixed clock grid
/// (start-of-day + k·interval), so rebuilds are stable — an already-planned 9:15
/// nudge stays at 9:15 instead of being pushed forward on every rebuild.
@MainActor
final class NudgeScheduler: NSObject {

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
    private let maxScheduled = 32        // stay well under the OS's 64-pending cap

    /// Call once at launch.
    func start() {
        center.delegate = self
        registerCategory()
        requestAuthorization()

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

        // Backstop: extend coverage and catch work-hours boundaries. Cheap to run
        // often because the clock-aligned grid makes rebuilds idempotent.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reschedule() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reschedule() } }
    }

    /// Suppress nudges for `snoozeDuration`, then rebuild.
    func snooze() {
        snoozedUntil = Date.now.addingTimeInterval(snoozeDuration)
        reschedule()
    }

    // MARK: - Scheduling

    /// Cancel pending nudges and pre-schedule the upcoming ones. Safe to call on
    /// any state change; idempotent thanks to the fixed clock grid.
    func reschedule() {
        cancelPending()
        guard let settings = settingsProvider(), settings.nudgeEnabled else { return }
        guard !isTrackingProvider() else { return }   // tracking (incl. paused) ⇒ silent

        let interval = TimeInterval(max(1, settings.nudgeIntervalMinutes) * 60)
        let schedules = schedulesProvider()
        guard !schedules.isEmpty else { return }

        let now = Date.now
        let floor = max(now, snoozedUntil ?? now)
        let horizon = now.addingTimeInterval(24 * 3600)

        // Walk the clock grid (start-of-day + k·interval). Schedule the next
        // `maxScheduled` points that are future, past the snooze floor, in-hours.
        var t = Calendar.current.startOfDay(for: now)
        var count = 0
        while t < horizon && count < maxScheduled {
            if t > floor, WorkHours.isWithin(t, schedules: schedules) {
                schedule(at: t, message: settings.nudgeMessage)
                count += 1
            }
            t = t.addingTimeInterval(interval)
        }
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

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { print("Notification auth error: \(error)") }
            else if !granted { print("Notification permission denied — nudges won't show.") }
        }
    }

    private func registerCategory() {
        let start = UNNotificationAction(identifier: startActionID, title: "Start tracking", options: [.foreground])
        let snooze = UNNotificationAction(identifier: snoozeActionID, title: "Snooze 30 min", options: [])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [start, snooze],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NudgeScheduler: UNUserNotificationCenterDelegate {

    /// Show the banner even when the app is "active" (it's an agent, so it
    /// frequently is) — otherwise nudges would be silently swallowed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case self.snoozeActionID:
                self.snooze()
            case self.startActionID, UNNotificationDefaultActionIdentifier:
                self.onStartRequested()
            default:
                break
            }
            completionHandler()
        }
    }
}
