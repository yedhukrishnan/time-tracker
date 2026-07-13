import Foundation
import SwiftData

/// Singleton settings row. Stored in SwiftData (not UserDefaults) so it syncs
/// across your Macs via CloudKit — your customized nudge message follows you.
///
/// Fetch-or-create exactly one of these on launch (see `AppModel.bootstrap`).
@Model
final class AppSettings {
    /// Minutes between nudges while idle during work hours.
    var nudgeIntervalMinutes: Int = 1

    /// The reminder text. Customizable by the user.
    var nudgeMessage: String = "You're in work hours and not tracking. What are you working on?"

    var nudgeEnabled: Bool = true

    // MARK: Running-session monitoring (see `SessionMonitor`)

    /// Periodic "still working on this?" reminder while a session is running.
    var checkInEnabled: Bool = true

    /// Minutes of *active* tracked time between check-in reminders.
    var checkInIntervalMinutes: Int = 15

    /// Detect that you walked away (no input / sleep / lock) while the timer ran,
    /// and offer to repair the entry when you come back.
    var idleDetectionEnabled: Bool = true

    /// Minutes without input before you count as "away".
    var idleThresholdMinutes: Int = 5

    /// Whether the app registers itself as a login item (see `LoginItem`).
    var launchAtLogin: Bool = false

    /// Creation time. Used as a stable, cross-device key to pick a single winner
    /// when CloudKit sync has produced duplicate singleton rows (keep earliest).
    var createdAt: Date = Date.now

    init() {}
}
