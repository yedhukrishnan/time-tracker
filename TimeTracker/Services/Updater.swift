import Foundation
import AppKit
import Observation
import Sparkle
import UserNotifications

/// In-app updates via Sparkle (see ARCHITECTURE §5g).
///
/// Sparkle checks the appcast attached to the latest GitHub release once a day.
/// Nothing is ever downloaded or installed without asking: the user always
/// picks Install / Remind Me Later / Skip in Sparkle's update window.
///
/// **Gentle reminders.** A menu bar agent has no window to put in front of the
/// user, so a *scheduled* check that finds an update doesn't pop Sparkle's
/// window over whatever they're doing. Instead we post one notification and
/// show an "Update available" row in the popover; clicking either opens the
/// update window. A check the user starts themselves shows the window directly.
@MainActor
@Observable
final class Updater: NSObject {

    /// Version string of an update found but not yet dealt with — drives the
    /// popover's "Update available" row. nil when there's nothing pending.
    private(set) var availableVersion: String?

    /// Sparkle refuses a new check while one is in flight.
    private(set) var canCheckForUpdates = false

    /// Mirrors Sparkle's persisted daily-check preference (Settings toggle).
    var automaticallyChecks: Bool = true {
        didSet {
            guard let controller, controller.updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "UPDATE"
    private let reminderID = "update.available"

    /// Call once at launch, after `router.start()`.
    func start(router: NotificationRouter) {
        let category = UNNotificationCategory(identifier: categoryID, actions: [],
                                              intentIdentifiers: [], options: [])
        // Exempt from the sweep: a check-in presenting later shouldn't erase
        // the only notice that an update is waiting.
        router.register(category: category, exemptFromSweep: true) { [weak self] action in
            if action == UNNotificationDefaultActionIdentifier { self?.checkForUpdates() }
        }

        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: self)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates,
                                                         options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
    }

    /// User-initiated check ("Check for Updates…", `/update`, the popover row,
    /// or the reminder notification). If a scheduled check already found an
    /// update, this brings up its window.
    func checkForUpdates() {
        // Accessory app: activate first or Sparkle's window opens behind.
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: - Reminder notification

    private func postReminder(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Update available"
        content.body = "Time Tracker \(version) is ready to install. Click to see what's new."
        content.categoryIdentifier = categoryID
        // Fixed id: a newer reminder replaces an older one.
        center.add(UNNotificationRequest(identifier: reminderID, content: content, trigger: nil))
    }

    private func removeReminder() {
        center.removeDeliveredNotifications(withIdentifiers: [reminderID])
    }
}

// MARK: - SPUStandardUserDriverDelegate

// Sparkle calls these on the main thread.
extension Updater: SPUStandardUserDriverDelegate {

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show its window for a scheduled update only when the app is
    /// already in focus (e.g. just launched); otherwise we remind gently.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let remind = !handleShowingUpdate && !state.userInitiated
        MainActor.assumeIsolated {
            availableVersion = version
            if remind { postReminder(version: version) }
        }
    }

    /// The user brought up the update window — the reminder has done its job.
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { removeReminder() }
    }

    /// Installed, skipped, or "Remind Me Later": nothing is pending now. A
    /// later scheduled check re-finds it if the user deferred.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            availableVersion = nil
            removeReminder()
        }
    }
}
