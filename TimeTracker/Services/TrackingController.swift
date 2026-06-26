import Foundation
import SwiftData
import Observation

/// Owns the start/stop lifecycle and the live elapsed timer.
///
/// Invariant defended here: at most one running session at a time.
@MainActor
@Observable
final class TrackingController {
    /// The currently running session, or nil when idle.
    private(set) var running: TimeEntry?

    /// Live *active* elapsed seconds for the running session (excludes paused
    /// time); drives the menu bar title. Frozen while paused.
    private(set) var elapsed: TimeInterval = 0

    /// Mirror of the running entry's pause state, kept as a stored property so the
    /// UI observes pause/resume reliably.
    private(set) var isPaused: Bool = false

    private var ticker: Timer?
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        recoverRunningSession()
    }

    var isTracking: Bool { running != nil }

    /// Begin a new session. If one is somehow already running, stop it first so
    /// the single-running invariant always holds.
    func start(agenda: String) {
        if running != nil { _ = stop() }
        let entry = TimeEntry(agenda: agenda.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(entry)
        running = entry
        isPaused = false
        elapsed = 0
        save()
        startTicker()
    }

    /// Pause the running session — active time stops accumulating.
    func pause() {
        guard let entry = running, entry.pauseStartedAt == nil else { return }
        entry.pauseStartedAt = .now
        entry.touch()
        isPaused = true
        save()
    }

    /// Resume a paused session — fold the just-ended pause into the total.
    func resume() {
        guard let entry = running, let ps = entry.pauseStartedAt else { return }
        entry.pausedSeconds += Date.now.timeIntervalSince(ps)
        entry.pauseStartedAt = nil
        entry.touch()
        isPaused = false
        elapsed = entry.duration
        save()
    }

    /// End the running session and return it for wrap-up (achievement + rating).
    @discardableResult
    func stop() -> TimeEntry? {
        guard let entry = running else { return nil }
        if let ps = entry.pauseStartedAt {          // close an open pause first
            entry.pausedSeconds += Date.now.timeIntervalSince(ps)
            entry.pauseStartedAt = nil
        }
        entry.endedAt = .now
        entry.touch()
        running = nil
        elapsed = 0
        isPaused = false
        stopTicker()
        save()
        return entry
    }

    /// On launch, adopt any session left running (app was quit mid-session).
    /// If several are running (possible after a sync conflict), keep the newest
    /// and auto-close the rest — resolving the cross-device invariant violation.
    private func recoverRunningSession() {
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        guard let open = try? context.fetch(descriptor), let newest = open.first else { return }
        for stale in open.dropFirst() {
            stale.endedAt = stale.startedAt   // zero-length; it never properly closed
            stale.touch()
        }
        running = newest
        isPaused = newest.pauseStartedAt != nil   // a paused session stays paused across restart
        elapsed = newest.duration
        save()
        startTicker()
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.running else { return }
                // Active duration is constant while paused, so the timer freezes.
                self.elapsed = r.duration
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func save() {
        do { try context.save() } catch { print("TrackingController save error: \(error)") }
    }
}
