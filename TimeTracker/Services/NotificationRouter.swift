import Foundation
import UserNotifications

/// Single owner of the app-wide notification plumbing.
///
/// `UNUserNotificationCenter` has exactly one delegate and one category set —
/// both are clobber-on-write. With two schedulers (NudgeScheduler,
/// SessionMonitor) each posting notifications, neither can own them safely.
/// So this router owns both: schedulers `register(...)` their category plus an
/// action handler, and the router aggregates categories and dispatches
/// responses by `categoryIdentifier`.
@MainActor
final class NotificationRouter: NSObject {

    private let center = UNUserNotificationCenter.current()
    private var categories: Set<UNNotificationCategory> = []
    /// Handler per category id. Receives the action identifier
    /// (or `UNNotificationDefaultActionIdentifier` for a plain tap).
    private var handlers: [String: (String) -> Void] = [:]
    /// Category ids whose banners must be hushed while a session is tracking —
    /// the last line of defense against a reminder that slipped past
    /// cancellation (e.g. its trigger elapsed just as tracking began).
    private var suppressedWhileTracking: Set<String> = []

    /// Whether a session is currently being tracked. Set by AppModel.
    var isTrackingProvider: () -> Bool = { false }

    /// Call once at launch, before schedulers register.
    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { print("Notification auth error: \(error)") }
            else if !granted { print("Notification permission denied — reminders won't show.") }
        }
    }

    /// Register a category and its action handler. Re-sets the aggregate
    /// category set, so registration order doesn't matter.
    ///
    /// Pass `suppressWhileTracking: true` for reminders that only make sense
    /// when idle (nudges); their banners are withheld while a session runs.
    func register(category: UNNotificationCategory,
                  suppressWhileTracking: Bool = false,
                  handler: @escaping (String) -> Void) {
        categories.remove(category)   // replace if re-registered
        categories.insert(category)
        handlers[category.identifier] = handler
        if suppressWhileTracking { suppressedWhileTracking.insert(category.identifier) }
        center.setNotificationCategories(categories)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationRouter: UNUserNotificationCenterDelegate {

    /// Show banners even while the app is "active" (a menu bar agent usually
    /// is) — otherwise notifications are silently swallowed.
    ///
    /// Two policies applied here, at the moment of delivery:
    ///
    /// 1. **Tracking guard** — a suppress-while-tracking reminder (a nudge) that
    ///    slipped past cancellation is withheld while a session runs. This is the
    ///    only check that runs at delivery time, so it closes the gap that
    ///    scheduling/cancellation races can't.
    /// 2. **Sweep** — a freshly presented banner supersedes whatever was left
    ///    sitting in Notification Center: sweep every *other* delivered
    ///    notification (all categories), so stale banners don't pile up.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        let currentID = notification.request.identifier
        Task { @MainActor in
            // 1. Withhold nudges (and any other suppress-while-tracking category)
            //    while a session is running. A withheld banner isn't a "present"
            //    event, so it shouldn't sweep the others — bail before the sweep.
            if self.suppressedWhileTracking.contains(category), self.isTrackingProvider() {
                completionHandler([])
                return
            }
            // 2. This banner is presenting — clear every other delivered one.
            center.getDeliveredNotifications { delivered in
                let stale = delivered
                    .filter { $0.request.identifier != currentID }
                    .map(\.request.identifier)
                if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
            }
            completionHandler([.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        Task { @MainActor in
            self.handlers[category]?(action)
            completionHandler()
        }
    }
}
