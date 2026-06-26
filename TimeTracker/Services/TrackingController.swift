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

    /// Live elapsed seconds for the running session; drives the menu bar title.
    private(set) var elapsed: TimeInterval = 0

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
        save()
        startTicker()
    }

    /// End the running session and return it for wrap-up (achievement + rating).
    @discardableResult
    func stop() -> TimeEntry? {
        guard let entry = running else { return nil }
        entry.endedAt = .now
        entry.touch()
        running = nil
        elapsed = 0
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
        elapsed = Date.now.timeIntervalSince(newest.startedAt)
        save()
        startTicker()
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.running else { return }
                self.elapsed = Date.now.timeIntervalSince(r.startedAt)
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
