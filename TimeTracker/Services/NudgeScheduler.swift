import Foundation
import AppKit
import UserNotifications

/// The nudge engine (see ARCHITECTURE §7).
///
/// A static repeating notification can't satisfy the spec — it can't tell whether
/// you're tracking or whether it's even a work hour. So instead, because the app
/// is a resident menu bar agent, we run an in-process heartbeat that evaluates
/// state and fires a nudge only when eligible.
///
/// Eligible = nudges enabled AND not tracking AND within work hours AND not snoozed
///            AND at least one interval has passed since the last nudge.
@MainActor
final class NudgeScheduler: NSObject {

    // Injected reads — set by AppModel after wiring.
    var isTrackingProvider: () -> Bool = { false }
    var settingsProvider: () -> AppSettings? = { nil }
    var schedulesProvider: () -> [WorkSchedule] = { [] }
    /// Invoked when the user taps "Start tracking" on a nudge banner.
    var onStartRequested: () -> Void = {}

    private var heartbeat: Timer?
    private var lastNudgeAt: Date?
    private var snoozedUntil: Date?

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "NUDGE"
    private let startActionID = "NUDGE_START"
    private let snoozeActionID = "NUDGE_SNOOZE"
    private let snoozeDuration: TimeInterval = 30 * 60

    /// Call once at launch.
    func start() {
        center.delegate = self
        registerCategory()
        requestAuthorization()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Re-evaluate immediately on wake — timers don't fire reliably across sleep.
        // Wake notifications come through NSWorkspace's own center, not the default one.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    /// Push the next nudge out by `snoozeDuration` from now.
    func snooze() { snoozedUntil = Date.now.addingTimeInterval(snoozeDuration) }

    // MARK: - Core evaluation

    private func tick() {
        guard let settings = settingsProvider(), settings.nudgeEnabled else { resetIdleClock(); return }
        guard !isTrackingProvider() else { resetIdleClock(); return }
        guard WorkHours.isWithin(.now, schedules: schedulesProvider()) else { resetIdleClock(); return }
        if let until = snoozedUntil, Date.now < until { return }

        let interval = TimeInterval(max(1, settings.nudgeIntervalMinutes) * 60)

        // First time we become eligible, start the clock rather than nudging
        // instantly — you just stopped tracking; give it a full interval.
        guard let last = lastNudgeAt else { lastNudgeAt = .now; return }
        guard Date.now.timeIntervalSince(last) >= interval else { return }

        fire(message: settings.nudgeMessage)
        lastNudgeAt = .now
        snoozedUntil = nil
    }

    /// When ineligible, clear the idle clock so the next eligible window waits a
    /// full interval before the first nudge.
    private func resetIdleClock() { lastNudgeAt = nil }

    // MARK: - Notification plumbing

    private func fire(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Track your time"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
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
