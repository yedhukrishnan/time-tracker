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
    func register(category: UNNotificationCategory, handler: @escaping (String) -> Void) {
        categories.remove(category)   // replace if re-registered
        categories.insert(category)
        handlers[category.identifier] = handler
        center.setNotificationCategories(categories)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationRouter: UNUserNotificationCenterDelegate {

    /// Show banners even while the app is "active" (a menu bar agent usually
    /// is) — otherwise notifications are silently swallowed.
    ///
    /// Also keep at most one delivered notification per category: when a new
    /// one arrives, sweep older unanswered ones from Notification Center, so
    /// ignored nudges/check-ins replace each other instead of piling up.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        let currentID = notification.request.identifier
        center.getDeliveredNotifications { delivered in
            let stale = delivered
                .filter { $0.request.content.categoryIdentifier == category
                       && $0.request.identifier != currentID }
                .map(\.request.identifier)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
        completionHandler([.banner, .sound])
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
