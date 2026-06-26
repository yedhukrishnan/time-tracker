import Foundation
import SwiftData

/// Singleton settings row. Stored in SwiftData (not UserDefaults) so it syncs
/// across your Macs via CloudKit — your customized nudge message follows you.
///
/// Fetch-or-create exactly one of these on launch (see `AppModel.bootstrap`).
@Model
final class AppSettings {
    /// Minutes between nudges while idle during work hours.
    var nudgeIntervalMinutes: Int = 15

    /// The reminder text. Customizable by the user.
    var nudgeMessage: String = "You're in work hours and not tracking. What are you working on?"

    var nudgeEnabled: Bool = true

    /// Whether the app registers itself as a login item (see `LoginItem`).
    var launchAtLogin: Bool = false

    init() {}
}
