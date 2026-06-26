import Foundation
import SwiftData

/// One tracked work session — the spine of the app.
///
/// A session is "running" while `endedAt == nil`. The app enforces that at most
/// one session runs at a time (an app-layer invariant; CloudKit can't enforce it).
///
/// CloudKit note: every stored property is optional or has a default. CloudKit
/// mirroring rejects required attributes without defaults, so don't remove them.
@Model
final class TimeEntry {
    /// What you intend to do — captured at start.
    var agenda: String = ""

    /// When tracking began.
    var startedAt: Date = Date.now

    /// When tracking ended. `nil` means the session is still running.
    var endedAt: Date?

    /// What you actually got done — captured at stop (or edited later).
    var achievement: String?

    /// 1–5 self-rating. `nil` means unrated (do not default to a number).
    var rating: Int?

    /// Creation timestamp (immutable).
    var createdAt: Date = Date.now

    /// Last-modified timestamp. Used for last-write-wins conflict resolution
    /// when the same entry is edited on two devices offline. Bump on every edit.
    var modifiedAt: Date = Date.now

    /// Total seconds spent in *completed* pauses. Live (open) pause time is added
    /// on the fly in `duration` and folded in here when the pause ends.
    var pausedSeconds: Double = 0

    /// When the session is currently paused, the moment the pause began.
    /// `nil` means the session is actively running (or stopped).
    var pauseStartedAt: Date?

    init(agenda: String = "", startedAt: Date = .now) {
        self.agenda = agenda
        self.startedAt = startedAt
        self.createdAt = .now
        self.modifiedAt = .now
    }

    var isRunning: Bool { endedAt == nil }

    var isPaused: Bool { isRunning && pauseStartedAt != nil }

    /// Active worked time — wall-clock span minus all paused time. Derived, never
    /// stored, so editing start/end recomputes cleanly with no field to drift.
    var duration: TimeInterval {
        let endRef = endedAt ?? .now
        var paused = pausedSeconds
        if let ps = pauseStartedAt { paused += endRef.timeIntervalSince(ps) }
        return max(0, endRef.timeIntervalSince(startedAt) - paused)
    }

    /// Call after any user edit so sync can resolve conflicts correctly.
    func touch() { modifiedAt = .now }
}
