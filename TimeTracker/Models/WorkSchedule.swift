import Foundation
import SwiftData

/// A working-hours window for a single weekday.
///
/// One row per active weekday (e.g. Mon–Fri 9–18 = five rows). Times are stored
/// as minutes-from-midnight rather than `Date` because the schedule recurs and a
/// wall-clock date carries irrelevant day/month/timezone baggage.
///
/// `weekday` follows Apple's `Calendar` convention: 1 = Sunday … 7 = Saturday.
@Model
final class WorkSchedule {
    var weekday: Int = 2            // default Monday
    var startMinutes: Int = 9 * 60 // 09:00
    var endMinutes: Int = 18 * 60  // 18:00
    var isEnabled: Bool = true

    /// Creation time — stable key to keep one row per weekday when sync produces
    /// duplicates (keep earliest).
    var createdAt: Date = Date.now

    init(weekday: Int, startMinutes: Int = 9 * 60, endMinutes: Int = 18 * 60, isEnabled: Bool = true) {
        self.weekday = weekday
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.isEnabled = isEnabled
        self.createdAt = .now
    }

    /// True if this row's window spans midnight (e.g. 22:00 → 02:00).
    var isOvernight: Bool { endMinutes <= startMinutes }
}
