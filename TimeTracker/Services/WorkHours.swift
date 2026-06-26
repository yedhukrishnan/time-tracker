import Foundation

/// Pure logic for "are we within work hours right now?" — no state, easy to test.
enum WorkHours {

    /// True if `date` falls inside any enabled schedule window.
    static func isWithin(_ date: Date,
                         schedules: [WorkSchedule],
                         calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let minutes = minutesIntoDay(date, calendar: calendar)

        for s in schedules where s.isEnabled {
            if s.isOvernight {
                // Window spans midnight. It "belongs" to the day it starts on, but
                // the tail (after midnight) lands on the next weekday. Check both.
                let startsToday = (s.weekday == weekday) && (minutes >= s.startMinutes)
                let prevWeekday = (weekday + 5) % 7 + 1            // yesterday in 1...7
                let tailFromYesterday = (s.weekday == prevWeekday) && (minutes < s.endMinutes)
                if startsToday || tailFromYesterday { return true }
            } else {
                if s.weekday == weekday, minutes >= s.startMinutes, minutes < s.endMinutes {
                    return true
                }
            }
        }
        return false
    }

    private static func minutesIntoDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
